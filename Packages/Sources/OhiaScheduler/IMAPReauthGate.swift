import Foundation
import OhiaCore
import OhiaMail

enum IMAPReauthGate {
    static let onboardingCredentialRaceWindow: TimeInterval = 15 * 60

    @MainActor
    static func shouldMarkNeedsImapReauth(
        account: Account,
        error: IMAPError,
        now: Date = Date()
    ) -> Bool {
        switch error {
        case .authFailed:
            return true
        case .reauthRequired(let message):
            return shouldMarkNeedsImapReauth(
                account: account,
                reauthMessage: message,
                now: now
            )
        default:
            return false
        }
    }

    @MainActor
    static func shouldMarkNeedsImapReauth(
        account: Account,
        reason: IMAPSessionHaltReason,
        now: Date = Date()
    ) -> Bool {
        switch reason {
        case .authFailed:
            return true
        case .reauthRequired(let message):
            return shouldMarkNeedsImapReauth(
                account: account,
                reauthMessage: message,
                now: now
            )
        case .certMismatch, .tlsError, .protocolViolation:
            return false
        }
    }

    static func isMissingOAuthTokenReauth(_ error: IMAPError) -> Bool {
        guard case .reauthRequired(let message) = error else { return false }
        return isMissingOAuthTokenMessage(message)
    }

    private static func shouldMarkNeedsImapReauth(
        account: Account,
        reauthMessage: String,
        now: Date
    ) -> Bool {
        if isInitialOAuthTokenRace(account: account, message: reauthMessage, now: now) {
            return false
        }
        return true
    }

    private static func isInitialOAuthTokenRace(
        account: Account,
        message: String,
        now: Date
    ) -> Bool {
        guard isMissingOAuthTokenMessage(message),
              hasOAuthReference(account),
              isInitialIngestionHandoff(account, now: now)
        else {
            return false
        }
        return true
    }

    private static func isMissingOAuthTokenMessage(_ message: String) -> Bool {
        message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("no OAuth token stored")
    }

    private static func hasOAuthReference(_ account: Account) -> Bool {
        guard account.imapAuthMethod == .oauth2 || account.smtpAuthMethod == .oauth2 else {
            return false
        }
        let ref = account.imapKeychainRef ?? account.smtpKeychainRef
        return ref?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func isInitialIngestionHandoff(
        _ account: Account,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(account.createdAt) <= onboardingCredentialRaceWindow
    }
}
