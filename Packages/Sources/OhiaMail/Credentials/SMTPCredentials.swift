import Foundation
import OhiaCore

public struct SMTPCredentials: Sendable {
    public enum Error: Swift.Error { case missingKeychainRef, missingData, wrongAuthMethod }

    public static let service = "com.ohia.smtp"

    public init() {}

    /// Validate password authentication and return only the opaque Keychain
    /// reference. The main app's credential broker performs the actual read.
    public func keychainReference(for account: Account) throws -> String {
        guard account.smtpAuthMethod == .password else { throw Error.wrongAuthMethod }
        guard let ref = account.smtpKeychainRef else { throw Error.missingKeychainRef }
        return ref
    }

    /// Store a password for the account; sets `smtpKeychainRef` if unset.
    public func storePassword(_ password: String, for account: Account) throws {
        let ref = account.smtpKeychainRef ?? "smtp-password-\(account.id.uuidString)"
        try KeychainHelpers.set(data: Data(password.utf8), service: Self.service, account: ref)
        account.smtpKeychainRef = ref
    }
}
