import Foundation
import OhiaCore

public struct MailProvider: Sendable {
    // SMTP (existing)
    public let smtpHost: String
    public let smtpPort: Int
    public let security: SMTPSecurity
    public let authHint: AuthHint
    public let displayName: String

    // IMAP (NEW)
    public let imapHost: String
    public let imapPort: Int
    public let imapSecurity: IMAPSecurity
    public let imapAuthHint: AuthHint

    public enum AuthHint: Sendable, Equatable {
        case password
        case oauth2(OAuthProviderID)
    }

    public enum OAuthProviderID: String, Codable, Sendable {
        case gmail
        case microsoft
    }
}

public enum MailProviderRegistry {
    public static func lookup(email: String) -> MailProvider? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...]).lowercased()
        return table[domain]
    }

    public static func lookup(
        email: String,
        smtpHost: String?,
        imapHost: String?
    ) -> MailProvider? {
        if let exact = lookup(email: email) {
            return exact
        }
        return lookupByHost(smtpHost) ?? lookupByHost(imapHost)
    }

    public static func lookupByHost(_ host: String?) -> MailProvider? {
        guard let normalized = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        if normalized == "smtp.gmail.com"
            || normalized == "imap.gmail.com"
            || normalized == "smtp.googlemail.com"
            || normalized == "imap.googlemail.com" {
            return gmail(display: "Google Workspace")
        }

        if normalized == "smtp-mail.outlook.com"
            || normalized == "smtp.office365.com"
            || normalized == "outlook.office365.com"
            || normalized == "imap-mail.outlook.com" {
            return outlook(display: "Microsoft 365")
        }

        if normalized == "smtp.mail.me.com" || normalized == "imap.mail.me.com" {
            return icloud(display: "iCloud")
        }

        if normalized == "smtp.fastmail.com" || normalized == "imap.fastmail.com" {
            return fastmail(display: "Fastmail")
        }

        if normalized == "smtp.mail.yahoo.com" || normalized == "imap.mail.yahoo.com" {
            return table["yahoo.com"]
        }

        if normalized == "smtp.aol.com" || normalized == "imap.aol.com" {
            return table["aol.com"]
        }

        if normalized == "smtp.zoho.com" || normalized == "imap.zoho.com" {
            return table["zoho.com"]
        }

        return nil
    }

    /// Every provider label the app may surface (e.g. "Gmail", "iCloud"),
    /// including the `providerName(_:)` variant ("Proton Bridge"). Used to
    /// detect identity display names that were mistakenly seeded with the
    /// provider label instead of a person's name.
    public static let providerDisplayNames: Set<String> = {
        var names = Set(table.values.map(\.displayName))
        names.insert("Proton Bridge")
        names.insert("Google Workspace")
        names.insert("Microsoft 365")
        return names
    }()

    /// True when `name` matches a known provider label (case-insensitive,
    /// trimmed). A provider label is never a valid `From:` display name.
    public static func isProviderDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return providerDisplayNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func gmail(display: String) -> MailProvider {
        .init(smtpHost: "smtp.gmail.com", smtpPort: 587, security: .starttls, authHint: .oauth2(.gmail), displayName: display,
              imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .oauth2(.gmail))
    }

    private static func icloud(display: String) -> MailProvider {
        .init(smtpHost: "smtp.mail.me.com", smtpPort: 587, security: .starttls, authHint: .password, displayName: display,
              imapHost: "imap.mail.me.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .password)
    }

    private static func outlook(display: String) -> MailProvider {
        .init(smtpHost: "smtp-mail.outlook.com", smtpPort: 587, security: .starttls, authHint: .oauth2(.microsoft), displayName: display,
              imapHost: "outlook.office365.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .oauth2(.microsoft))
    }

    private static func fastmail(display: String) -> MailProvider {
        .init(smtpHost: "smtp.fastmail.com", smtpPort: 465, security: .tls, authHint: .password, displayName: display,
              imapHost: "imap.fastmail.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .password)
    }

    private static let table: [String: MailProvider] = [
        "gmail.com":      gmail(display: "Gmail"),
        "googlemail.com": gmail(display: "Gmail"),
        "icloud.com":     icloud(display: "iCloud"),
        "me.com":         icloud(display: "iCloud"),
        "mac.com":        icloud(display: "iCloud"),
        "outlook.com":    outlook(display: "Outlook"),
        "hotmail.com":    outlook(display: "Outlook"),
        "live.com":       outlook(display: "Outlook"),
        "msn.com":        outlook(display: "Outlook"),
        "fastmail.com":   fastmail(display: "Fastmail"),
        "fastmail.fm":    fastmail(display: "Fastmail"),
        "yahoo.com":      .init(smtpHost: "smtp.mail.yahoo.com", smtpPort: 587, security: .starttls, authHint: .password, displayName: "Yahoo",
                                imapHost: "imap.mail.yahoo.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .password),
        "aol.com":        .init(smtpHost: "smtp.aol.com", smtpPort: 587, security: .starttls, authHint: .password, displayName: "AOL",
                                imapHost: "imap.aol.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .password),
        "proton.me":      .init(smtpHost: "127.0.0.1", smtpPort: 1025, security: .starttls, authHint: .password, displayName: "Proton (Bridge)",
                                imapHost: "127.0.0.1", imapPort: 1143, imapSecurity: .starttls, imapAuthHint: .password),
        "zoho.com":       .init(smtpHost: "smtp.zoho.com", smtpPort: 465, security: .tls, authHint: .password, displayName: "Zoho",
                                imapHost: "imap.zoho.com", imapPort: 993, imapSecurity: .tls, imapAuthHint: .password),
    ]
}

/// Bridges MailProviderRegistry → OhiaCore's MigrationProviderLookup
/// contract so AccountMigrationDecider can run without importing OhiaMail.
public struct MailProviderRegistryLookup: MigrationProviderLookup {
    public init() {}
    public func authKindForEmail(_ email: String) -> MigrationProviderAuthKind? {
        guard let provider = MailProviderRegistry.lookup(email: email) else { return nil }
        switch provider.imapAuthHint {
        case .oauth2(.gmail):     return .oauth2Gmail
        case .oauth2(.microsoft): return .oauth2Microsoft
        case .password:           return .password
        }
    }
}
