import Foundation

public enum IMAPConnectionVerificationError: Error, Sendable, Equatable {
    case actionRequired(IMAPSessionHaltReason)
    case transient(String)
}

public enum IMAPConnectionVerifier {
    public static func verify(configuration: IMAPConnectionConfiguration) async throws {
        try await verify(configuration: configuration, makeClient: { IMAPClient() })
    }

    static func verify(
        configuration: IMAPConnectionConfiguration,
        makeClient: IMAPClientFactory
    ) async throws {
        let client = makeClient()
        do {
            try Task.checkCancellation()
            try await client.connect(
                host: configuration.host,
                port: configuration.port,
                security: configuration.security,
                pinnedCertSHA256: configuration.pinnedCertSHA256
            )
            _ = try await client.capability()
            try await configuration.authenticate(client)
            _ = try await client.list()
            try Task.checkCancellation()
            await client.logout()
            await client.close()
        } catch {
            await client.close()
            if IMAPConnectionErrorClassifier.isCancellation(error) {
                throw CancellationError()
            }
            if let reason = IMAPConnectionErrorClassifier.actionRequiredReason(error) {
                throw IMAPConnectionVerificationError.actionRequired(reason)
            }
            throw IMAPConnectionVerificationError.transient(
                IMAPConnectionErrorClassifier.diagnostic(error)
            )
        }
    }
}

enum IMAPConnectionErrorClassifier {
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? IMAPError).map {
            if case .cancelled = $0 { return true }
            return false
        } == true
    }

    static func actionRequiredReason(_ error: any Error) -> IMAPSessionHaltReason? {
        guard let error = error as? IMAPError else { return nil }
        switch error {
        case .authFailed(let text):
            return .authFailed(text)
        case .reauthRequired(let text):
            return .reauthRequired(text)
        case .mailStream(.certPinMismatch(let presented)):
            return .certMismatch(presented: presented)
        case .mailStream(.tlsHandshakeFailed(let underlying)):
            return .tlsError(underlying.map { ($0 as NSError).localizedDescription } ?? "TLS handshake failed")
        case .notImapServer:
            return .protocolViolation("not an IMAP server")
        case .protocolViolation(let text):
            return .protocolViolation(text)
        case .transient, .cancelled, .mailStream, .serverTemporary,
             .serverClosedConnection, .notConnected:
            return nil
        }
    }

    static func diagnostic(_ error: any Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false {
            return description
        }
        return (error as NSError).localizedDescription
    }
}
