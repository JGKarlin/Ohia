import Foundation
import OhiaCore

/// Discovers configured email-account metadata without reading message data.
///
/// Mail.app AppleScript metadata is authoritative when available. macOS
/// Internet Accounts is a best-effort supplementary source for identities and
/// server hints. Mail.app Automation denial, a missing Mail.app installation,
/// and empty results all leave provider sign-in and manual setup available to
/// the caller.
public final class AccountDiscoveryService: Sendable {
    typealias MailAppAccountsProvider = @Sendable () -> [DiscoveredAccount]
    typealias InternetAccountsProvider = @Sendable () async -> [DiscoveredAccount]

    private let mailAppAccountsProvider: MailAppAccountsProvider
    private let internetAccountsProvider: InternetAccountsProvider

    public init() {
        self.mailAppAccountsProvider = Self.discoverViaAppleScript
        self.internetAccountsProvider = {
            await SystemAccountsProvider().discover()
        }
    }

    init(
        mailAppAccountsProvider: @escaping MailAppAccountsProvider,
        internetAccountsProvider: @escaping InternetAccountsProvider
    ) {
        self.mailAppAccountsProvider = mailAppAccountsProvider
        self.internetAccountsProvider = internetAccountsProvider
    }

    /// Returns Mail.app and Internet Accounts metadata merged by overlapping
    /// normalized identity addresses. No local Mail store is inspected.
    public func discoverAccounts() async -> [DiscoveredAccount] {
        let mailAppAccounts = mailAppAccountsProvider()
        let internetAccounts = await internetAccountsProvider()
        return Self.mergeAccounts(mailApp: mailAppAccounts, system: internetAccounts)
    }

    // MARK: - Mail.app AppleScript metadata

    /// Queries Mail.app for configured account and server metadata.
    /// NSAppleScript execution is synchronized onto the main thread.
    static func discoverViaAppleScript() -> [DiscoveredAccount] {
        let script = """
        set output to ""
        tell application "Mail"
            repeat with a in every account
                set n to name of a
                set t to account type of a as string
                set fullName to ""
                try
                    set fullName to full name of a
                end try
                set addrs to email addresses of a
                set addrStr to ""
                repeat with addr in addrs
                    if addrStr is not "" then set addrStr to addrStr & "|"
                    set addrStr to addrStr & addr
                end repeat
                set incomingUser to ""
                set incomingHost to ""
                set incomingPort to ""
                set incomingSSL to ""
                set smtpUser to ""
                set smtpHost to ""
                set smtpPort to ""
                set smtpSSL to ""
                try
                    set incomingUser to user name of a
                end try
                try
                    set incomingHost to server name of a
                end try
                try
                    set incomingPort to port of a as string
                end try
                try
                    set incomingSSL to uses ssl of a as string
                end try
                try
                    set d to delivery account of a
                    if d is not missing value then
                        try
                            set smtpUser to user name of d
                        end try
                        try
                            set smtpHost to server name of d
                        end try
                        try
                            set smtpPort to port of d as string
                        end try
                        try
                            set smtpSSL to uses ssl of d as string
                        end try
                    end if
                end try
                set output to output & n & "\t" & t & "\t" & fullName & "\t" & addrStr & "\t" & incomingUser & "\t" & incomingHost & "\t" & incomingPort & "\t" & incomingSSL & "\t" & smtpUser & "\t" & smtpHost & "\t" & smtpPort & "\t" & smtpSSL & linefeed
            end repeat
        end tell
        return output
        """

        if Thread.isMainThread {
            return executeAppleScript(script)
        }
        return DispatchQueue.main.sync {
            executeAppleScript(script)
        }
    }

    private static func executeAppleScript(_ source: String) -> [DiscoveredAccount] {
        guard let appleScript = NSAppleScript(source: source) else { return [] }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = result.stringValue else { return [] }

        return parseAppleScriptOutput(output)
    }

    /// Parses tab-separated Mail.app AppleScript metadata.
    static func parseAppleScriptOutput(_ output: String) -> [DiscoveredAccount] {
        var accounts: [DiscoveredAccount] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { continue }

            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }

            let accountDisplayName = nilIfBlank(parts[0])
            let hasIdentityNameColumn = looksLikeEmailList(part(parts, 2)) == false
                && looksLikeEmailList(part(parts, 3))
            let identityDisplayName = hasIdentityNameColumn
                ? nilIfBlank(part(parts, 2))
                : nil
            let emailsString = hasIdentityNameColumn ? (part(parts, 3) ?? "") : parts[2]
            let serverOffset = hasIdentityNameColumn ? 1 : 0
            let incomingUsername = nilIfBlank(part(parts, 3 + serverOffset))
            let incomingHost = nilIfBlank(part(parts, 4 + serverOffset))
            let incomingPort = intIfPresent(part(parts, 5 + serverOffset))
            let incomingSecurity = imapSecurity(
                usesSSL: part(parts, 6 + serverOffset),
                port: incomingPort
            )
            let smtpUsername = nilIfBlank(part(parts, 7 + serverOffset))
            let smtpHost = nilIfBlank(part(parts, 8 + serverOffset))
            let smtpPort = intIfPresent(part(parts, 9 + serverOffset))
            let smtpSecurity = smtpSecurity(usesSSL: part(parts, 10 + serverOffset))

            let emails = emailsString.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
            guard let primaryEmail = emails.first else { continue }

            accounts.append(DiscoveredAccount(
                emailAddress: primaryEmail,
                identityEmailAddresses: emails,
                displayName: accountDisplayName ?? primaryEmail,
                identityDisplayName: identityDisplayName,
                source: .mailApp,
                imapHost: incomingHost,
                imapPort: incomingPort,
                imapUsername: incomingUsername,
                imapSecurity: incomingSecurity,
                smtpHost: smtpHost,
                smtpPort: smtpPort,
                smtpUsername: smtpUsername,
                smtpSecurity: smtpSecurity
            ))
        }

        return accounts
    }

    private static func part(_ parts: [String], _ index: Int) -> String? {
        guard parts.indices.contains(index) else { return nil }
        return parts[index]
    }

    private static func nilIfBlank(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeEmailList(_ raw: String?) -> Bool {
        guard let raw = nilIfBlank(raw) else { return false }
        return raw.components(separatedBy: "|").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
        }
    }

    private static func intIfPresent(_ raw: String?) -> Int? {
        guard let value = nilIfBlank(raw) else { return nil }
        return Int(value)
    }

    private static func boolIfPresent(_ raw: String?) -> Bool? {
        guard let value = nilIfBlank(raw)?.lowercased() else { return nil }
        if ["true", "yes", "1"].contains(value) { return true }
        if ["false", "no", "0"].contains(value) { return false }
        return nil
    }

    private static func imapSecurity(usesSSL raw: String?, port _: Int?) -> IMAPSecurity? {
        guard let usesSSL = boolIfPresent(raw) else { return nil }
        return usesSSL ? .tls : .starttls
    }

    private static func smtpSecurity(usesSSL raw: String?) -> SMTPSecurity? {
        guard let usesSSL = boolIfPresent(raw) else { return nil }
        // A server without implicit TLS is reached over STARTTLS. Ohia never
        // configures an unencrypted SMTP session from discovered settings.
        return usesSSL ? .tls : .starttls
    }

    // MARK: - Metadata merge

    /// Merges in deterministic source order. The earliest Mail.app account in
    /// an overlap component remains authoritative; later sources add aliases
    /// and fill nil server/identity metadata only.
    static func mergeAccounts(
        mailApp: [DiscoveredAccount],
        system: [DiscoveredAccount]
    ) -> [DiscoveredAccount] {
        var result: [DiscoveredAccount] = []

        for account in mailApp + system {
            merge(account, into: &result)
        }

        return result
    }

    private static func merge(
        _ account: DiscoveredAccount,
        into result: inout [DiscoveredAccount]
    ) {
        let overlapIndexes = result.indices.filter {
            result[$0].identityOverlaps(with: account)
        }
        guard let preferredIndex = overlapIndexes.first else {
            result.append(account)
            return
        }

        var merged = result[preferredIndex]
        for index in overlapIndexes.dropFirst() {
            merged = merged.mergedKeepingPreferredMetadata(with: result[index])
        }
        merged = merged.mergedKeepingPreferredMetadata(with: account)

        for index in overlapIndexes.dropFirst().reversed() {
            result.remove(at: index)
        }
        result[preferredIndex] = merged
    }
}

private extension DiscoveredAccount {
    func mergedIdentityEmailAddresses(with other: DiscoveredAccount) -> [String] {
        Self.normalizedIdentityEmailAddresses(
            primaryEmailAddress: emailAddress,
            identityEmailAddresses: identityEmailAddresses + other.identityEmailAddresses
        )
    }

    func identityOverlaps(with other: DiscoveredAccount) -> Bool {
        identityEmailAddressSet.isDisjoint(with: other.identityEmailAddressSet) == false
    }

    func mergedKeepingPreferredMetadata(with other: DiscoveredAccount) -> DiscoveredAccount {
        DiscoveredAccount(
            id: id,
            emailAddress: emailAddress,
            identityEmailAddresses: mergedIdentityEmailAddresses(with: other),
            displayName: displayName,
            identityDisplayName: identityDisplayName ?? other.identityDisplayName,
            source: source,
            imapHost: imapHost ?? other.imapHost,
            imapPort: imapPort ?? other.imapPort,
            imapUsername: imapUsername ?? other.imapUsername,
            imapSecurity: imapSecurity ?? other.imapSecurity,
            smtpHost: smtpHost ?? other.smtpHost,
            smtpPort: smtpPort ?? other.smtpPort,
            smtpUsername: smtpUsername ?? other.smtpUsername,
            smtpSecurity: smtpSecurity ?? other.smtpSecurity
        )
    }
}
