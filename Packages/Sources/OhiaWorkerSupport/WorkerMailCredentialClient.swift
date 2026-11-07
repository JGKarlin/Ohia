import Foundation
import OhiaCore
import OhiaMail

public final class WorkerMailCredentialClient:
    MailCredentialRequesting,
    MailPasswordResolving,
    @unchecked Sendable {
    public typealias RequestHandler = @Sendable (
        Data,
        @escaping @Sendable (Data?, NSError?) -> Void
    ) -> Void

    private let requestHandler: RequestHandler

    public init(connection: NSXPCConnection) {
        let connectionBox = WorkerMailCredentialConnectionBox(connection)
        self.requestHandler = { requestData, reply in
            guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ error in
                reply(nil, error as NSError)
            }) as? any WorkerXPCCommandBrokerProtocol else {
                reply(nil, MailCredentialBrokerError.unavailable.nsError)
                return
            }
            proxy.requestMailCredential(requestData, withReply: reply)
        }
    }

    init(requestHandler: @escaping RequestHandler) {
        self.requestHandler = requestHandler
    }

    public func request(_ request: MailCredentialRequest) async throws -> MailCredentialValue {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw MailCredentialBrokerError.invalidRequest
        }

        return try await withCheckedThrowingContinuation { continuation in
            let reply = WorkerMailCredentialReplyOnce(continuation)
            requestHandler(requestData) { responseData, error in
                if let error {
                    reply.resume(throwing: MailCredentialBrokerError.decode(error))
                    return
                }
                guard let responseData,
                      let value = try? JSONDecoder().decode(
                        MailCredentialValue.self,
                        from: responseData
                      ),
                      Self.isCompatible(value, with: request.kind) else {
                    reply.resume(throwing: MailCredentialBrokerError.incompatibleResponse)
                    return
                }
                reply.resume(returning: value)
            }
        }
    }

    public func password(
        kind: MailCredentialKind,
        keychainReference: String
    ) async throws -> String {
        guard kind.isPassword else {
            throw MailCredentialBrokerError.invalidRequest
        }
        let value = try await request(MailCredentialRequest(
            kind: kind,
            keychainReference: keychainReference
        ))
        guard case .secret(let password) = value else {
            throw MailCredentialBrokerError.incompatibleResponse
        }
        return password
    }

    private static func isCompatible(
        _ value: MailCredentialValue,
        with kind: MailCredentialKind
    ) -> Bool {
        switch (kind, value) {
        case (.oauthIMAPScopeStatus, .optionalScopeStatus):
            return true
        case (_, .secret) where kind.expectsSecret:
            return true
        default:
            return false
        }
    }
}

private final class WorkerMailCredentialConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class WorkerMailCredentialReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MailCredentialValue, any Error>?

    init(_ continuation: CheckedContinuation<MailCredentialValue, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: MailCredentialValue) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<MailCredentialValue, any Error>? {
        lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
    }
}
