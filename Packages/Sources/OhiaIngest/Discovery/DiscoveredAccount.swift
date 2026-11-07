import Foundation
import OhiaCore

// MARK: - DiscoverySource

public enum DiscoverySource: String, Sendable {
    case mailApp
    case internetAccounts
    case manual
}

// MARK: - DiscoveredAccount

public struct DiscoveredAccount: Identifiable, Sendable {
    public let id: UUID
    public let emailAddress: String
    /// All addresses that Mail.app / Internet Accounts reports as belonging
    /// to this mailbox, including the primary `emailAddress` and send-as
    /// aliases. Ingestion uses these as account identities, not separate
    /// accounts.
    public let identityEmailAddresses: [String]
    /// User-visible account label/description, such as the label shown in
    /// Internet Accounts or Mail.app.
    public let displayName: String
    /// Person/organization name configured for outgoing `From:` headers.
    /// This is intentionally separate from `displayName`: an account can be
    /// labeled "University" while sending as "Alex R. Morgan".
    public let identityDisplayName: String?
    public let source: DiscoverySource
    public let imapHost: String?
    public let imapPort: Int?
    public let imapUsername: String?
    public let imapSecurity: IMAPSecurity?
    public let smtpHost: String?
    public let smtpPort: Int?
    public let smtpUsername: String?
    public let smtpSecurity: SMTPSecurity?
    public init(
        id: UUID = UUID(),
        emailAddress: String,
        identityEmailAddresses: [String] = [],
        displayName: String,
        identityDisplayName: String? = nil,
        source: DiscoverySource,
        imapHost: String? = nil,
        imapPort: Int? = nil,
        imapUsername: String? = nil,
        imapSecurity: IMAPSecurity? = nil,
        smtpHost: String? = nil,
        smtpPort: Int? = nil,
        smtpUsername: String? = nil,
        smtpSecurity: SMTPSecurity? = nil
    ) {
        self.id = id
        self.emailAddress = emailAddress
        self.identityEmailAddresses = Self.normalizedIdentityEmailAddresses(
            primaryEmailAddress: emailAddress,
            identityEmailAddresses: identityEmailAddresses
        )
        self.displayName = displayName
        self.identityDisplayName = Self.normalizedOptionalString(identityDisplayName)
        self.source = source
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUsername = imapUsername
        self.imapSecurity = imapSecurity
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpSecurity = smtpSecurity
    }
}

public extension DiscoveredAccount {
    var identityEmailAddressSet: Set<String> {
        Set(identityEmailAddresses)
    }

    static func normalizedIdentityEmailAddresses(
        primaryEmailAddress: String,
        identityEmailAddresses: [String]
    ) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        func append(_ raw: String) {
            let value = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !value.isEmpty, value.contains("@"), seen.insert(value).inserted else {
                return
            }
            normalized.append(value)
        }

        append(primaryEmailAddress)
        for address in identityEmailAddresses {
            append(address)
        }
        return normalized
    }

    private static func normalizedOptionalString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
