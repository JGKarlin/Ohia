import Foundation

public enum MailCredentialKind: String, Codable, CaseIterable, Sendable {
    case oauthAccessToken
    case oauthIMAPAccessToken
    case oauthIMAPScopeStatus
    case imapPassword
    case smtpPassword

    public var expectsSecret: Bool {
        self != .oauthIMAPScopeStatus
    }

    public var isPassword: Bool {
        self == .imapPassword || self == .smtpPassword
    }
}

public struct MailCredentialRequest: Codable, Equatable, Sendable {
    public let kind: MailCredentialKind
    public let keychainReference: String
    public let providerID: MailProvider.OAuthProviderID?
    public let forceRefresh: Bool

    public init(
        kind: MailCredentialKind,
        keychainReference: String,
        providerID: MailProvider.OAuthProviderID? = nil,
        forceRefresh: Bool = false
    ) {
        self.kind = kind
        self.keychainReference = keychainReference
        self.providerID = providerID
        self.forceRefresh = forceRefresh
    }
}

public enum MailCredentialValue: Codable, Equatable, Sendable {
    case secret(String)
    case optionalScopeStatus(Bool?)
}

public protocol MailCredentialRequesting: Sendable {
    func request(_ request: MailCredentialRequest) async throws -> MailCredentialValue
}

public protocol MailPasswordResolving: Sendable {
    func password(
        kind: MailCredentialKind,
        keychainReference: String
    ) async throws -> String
}

public struct UnavailableMailCredentialResolver:
    MailCredentialRequesting,
    MailPasswordResolving,
    Sendable {
    public init() {}

    public func request(_ request: MailCredentialRequest) async throws -> MailCredentialValue {
        throw MailCredentialBrokerError.unavailable
    }

    public func password(
        kind: MailCredentialKind,
        keychainReference: String
    ) async throws -> String {
        throw MailCredentialBrokerError.unavailable
    }
}

public struct BrokeredMailPasswordResolver: MailPasswordResolving, Sendable {
    private let requester: any MailCredentialRequesting

    public init(requester: any MailCredentialRequesting) {
        self.requester = requester
    }

    public func password(
        kind: MailCredentialKind,
        keychainReference: String
    ) async throws -> String {
        guard kind.isPassword else {
            throw MailCredentialBrokerError.invalidRequest
        }
        let value = try await requester.request(MailCredentialRequest(
            kind: kind,
            keychainReference: keychainReference
        ))
        guard case .secret(let password) = value else {
            throw MailCredentialBrokerError.incompatibleResponse
        }
        return password
    }
}

public enum MailCredentialBrokerError: Int, Error, Equatable, Sendable, LocalizedError {
    case unavailable = 1
    case invalidRequest = 2
    case missingCredential = 3
    case accessDenied = 4
    case insufficientIMAPScope = 5
    case refreshRejected = 6
    case incompatibleResponse = 7

    public static let errorDomain = "org.jgkarlin.Ohia.MailCredentialBroker"

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The mail credential broker is unavailable."
        case .invalidRequest:
            return "The mail credential request is invalid."
        case .missingCredential:
            return "The requested mail credential is not stored."
        case .accessDenied:
            return "Access to the requested mail credential was denied."
        case .insufficientIMAPScope:
            return "The stored OAuth credential is missing IMAP permission."
        case .refreshRejected:
            return "The OAuth credential must be reauthorized."
        case .incompatibleResponse:
            return "The mail credential broker returned an incompatible response."
        }
    }

    public var nsError: NSError {
        NSError(
            domain: Self.errorDomain,
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: errorDescription ?? "Mail credential request failed."]
        )
    }

    public static func decode(_ error: NSError) -> Self {
        guard error.domain == errorDomain,
              let brokerError = Self(rawValue: error.code) else {
            return .unavailable
        }
        return brokerError
    }
}
