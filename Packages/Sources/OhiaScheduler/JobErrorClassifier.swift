import Foundation
import OhiaMail

/// Classifies errors raised by `PipelineRunner.runJob` (and the workers it
/// delegates to) as permanent vs. transient with respect to the job-queue
/// retry budget.
///
/// Mirrors the halt-vs-backoff partition `IMAPSession.handleError` already
/// uses for the live IDLE session and the partition `OutboxWorker` uses for
/// SMTP. Without this, every error went through `JobQueue.fail`'s blind 3x
/// retry — which turned one TLS handshake or auth failure into 3 noise rows
/// in the dev panel and burned scheduler ticks waking only to re-fail.
public enum JobErrorClassifier {
    public static func isPermanent(
        _ error: Error,
        allowMissingOAuthTokenRetry: Bool = false
    ) -> Bool {
        if let imap = error as? IMAPError {
            return isPermanent(
                imap,
                allowMissingOAuthTokenRetry: allowMissingOAuthTokenRetry
            )
        }
        if let broker = error as? MailCredentialBrokerError {
            switch broker {
            case .unavailable:
                return false
            case .invalidRequest,
                 .missingCredential,
                 .accessDenied,
                 .insufficientIMAPScope,
                 .refreshRejected,
                 .incompatibleResponse:
                return true
            }
        }
        if let smtp = error as? SMTPError {
            switch smtp {
            case .permanent, .protocolViolation, .transportFailed, .authFailed:
                return true
            case .transient:
                return false
            }
        }
        if let pipeline = error as? PipelineError {
            switch pipeline {
            case .invalidPayload, .notImplemented:
                return true
            case .summaryUnavailable, .semanticTagResolutionDeferred:
                return false
            }
        }
        return false
    }

    private static func isPermanent(
        _ imap: IMAPError,
        allowMissingOAuthTokenRetry: Bool
    ) -> Bool {
        switch imap {
        case .authFailed, .protocolViolation, .notImapServer:
            return true
        case .reauthRequired:
            if allowMissingOAuthTokenRetry,
               IMAPReauthGate.isMissingOAuthTokenReauth(imap) {
                return false
            }
            return true
        case .mailStream(let inner):
            switch inner {
            case .tlsHandshakeFailed, .certPinMismatch:
                return true
            case .notConnected, .connectionClosed, .stream, .invalidUTF8, .wrongState:
                return false
            }
        case .transient, .serverTemporary, .serverClosedConnection, .notConnected, .cancelled:
            return false
        }
    }
}
