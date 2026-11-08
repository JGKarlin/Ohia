import Foundation
import OhiaCore

/// Queries macOS Internet Accounts for configured email accounts.
///
/// Uses dynamic access to the deprecated `Accounts.framework` (`ACAccountStore`)
/// so the package can build cleanly even as Apple phases the framework out.
/// Returns an empty array if the framework is unavailable or access is denied.
///
/// Accounts.framework is deprecated and no longer exposes mail accounts in
/// every process context, so this is strictly best-effort supplementary
/// metadata. The Mail.app scripting path remains authoritative because it
/// exposes the same accounts the user sees in Mail. This provider reads no
/// OAuth tokens, passwords, or reusable credentials.
///
/// This is Tier 2 of the 3-tier account discovery strategy:
/// - Tier 1: Mail.app AppleScript metadata
/// - Tier 2: macOS Internet Accounts (this provider)
/// - Tier 3: Manual account entry by user
public struct SystemAccountsProvider: Sendable {

    public init() {}

    /// Discovers email accounts from macOS Internet Accounts.
    /// Returns empty if the API is unavailable or access is denied.
    public func discover() async -> [DiscoveredAccount] {
        guard let store = Self.makeAccountStore() else { return [] }
        let typeIdentifiers = [
            "com.apple.account.Google",
            "com.apple.account.IMAPMail",
            "com.apple.account.IMAP",
            "com.apple.account.Exchange",
            "com.apple.account.Hotmail",
            "com.apple.account.Yahoo",
            "com.apple.account.Aol",
        ]

        var results: [DiscoveredAccount] = []
        for identifier in typeIdentifiers {
            guard let accountType = Self.accountType(identifier, in: store) else { continue }
            for account in Self.accounts(with: accountType, in: store) {
                guard let discovered = Self.discoveredAccount(from: account) else { continue }
                results.append(discovered)
            }
        }

        return AccountDiscoveryService.mergeAccounts(mailApp: [], system: results)
    }

    private static func makeAccountStore() -> NSObject? {
        Bundle(path: "/System/Library/Frameworks/Accounts.framework")?.load()
        guard let storeClass = NSClassFromString("ACAccountStore") as? NSObject.Type else {
            return nil
        }
        return storeClass.init()
    }

    private static func accountType(_ identifier: String, in store: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString("accountTypeWithAccountTypeIdentifier:")
        guard store.responds(to: selector) else { return nil }
        return store.perform(selector, with: identifier as NSString)?.takeUnretainedValue()
    }

    private static func accounts(with accountType: AnyObject, in store: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accountsWithAccountType:")
        guard store.responds(to: selector),
              let value = store.perform(selector, with: accountType)?.takeUnretainedValue() else {
            return []
        }
        return (value as? [NSObject]) ?? []
    }

    private static func discoveredAccount(from account: NSObject) -> DiscoveredAccount? {
        let properties = (account.value(forKey: "properties") as? [String: Any]) ?? [:]
        let username = normalizedString(account.value(forKey: "username") as? String)
        let identityEmail = normalizedString(properties["IdentityEmailAddress"] as? String)
        let normalizedAliases = normalizedEmailAliases(properties["EmailAliases"])
        let aliasEmail = normalizedAliases
            .first(where: { $0.contains("@") })
        let email = [identityEmail, username, aliasEmail]
            .compactMap { $0 }
            .first(where: { $0.contains("@") })

        guard let email else { return nil }

        let accountDescription = normalizedString(account.value(forKey: "accountDescription") as? String)
        let identityDisplayName = normalizedString(properties["FullName"] as? String)
        let displayName = accountDescription ?? identityDisplayName ?? email

        let imapHost = normalizedString(properties["imapHostname"] as? String)
            ?? normalizedString(properties["Hostname"] as? String)
        let imapPort = intValue(properties["imapPort"])
        let imapSecurity = securityFromBool(properties["imapRequiresSSL"], defaultPort: imapPort)
        let smtpHost = normalizedString(properties["smtpHostname"] as? String)
        let smtpPort = intValue(properties["smtpPort"])
        let smtpSecurity = smtpSecurityFromBool(properties["smtpRequiresSSL"])

        return DiscoveredAccount(
            emailAddress: email,
            identityEmailAddresses: [identityEmail, username].compactMap { $0 } + normalizedAliases,
            displayName: displayName,
            identityDisplayName: identityDisplayName,
            source: .internetAccounts,
            imapHost: imapHost,
            imapPort: imapPort,
            imapUsername: username ?? email,
            imapSecurity: imapSecurity,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpUsername: username ?? email,
            smtpSecurity: smtpSecurity
        )
    }

    private static func normalizedEmailAliases(_ value: Any?) -> [String] {
        if let aliases = value as? [String] {
            return aliases
                .compactMap(normalizedString)
                .filter { $0.contains("@") }
        }

        guard let raw = normalizedString(value as? String) else { return [] }
        return raw
            .split { separator in
                separator == "," || separator == "|" || separator == ";" || separator.isWhitespace
            }
            .compactMap { normalizedString(String($0)) }
            .filter { $0.contains("@") }
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = normalizedString(value as? String) { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = normalizedString(value as? String)?.lowercased() else { return nil }
        if ["true", "yes", "1"].contains(string) { return true }
        if ["false", "no", "0"].contains(string) { return false }
        return nil
    }

    private static func securityFromBool(_ value: Any?, defaultPort: Int?) -> IMAPSecurity? {
        guard let usesSSL = boolValue(value) else { return nil }
        if usesSSL { return .tls }
        return defaultPort == 143 ? .starttls : .starttls
    }

    private static func smtpSecurityFromBool(_ value: Any?) -> SMTPSecurity? {
        guard let usesSSL = boolValue(value) else { return nil }
        // A server without implicit TLS is reached over STARTTLS. Ohia never
        // configures an unencrypted SMTP session from discovered settings.
        return usesSSL ? .tls : .starttls
    }
}
