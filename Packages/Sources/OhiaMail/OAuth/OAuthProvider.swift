import Foundation

public struct OAuthProvider: Sendable {
    public let id: MailProvider.OAuthProviderID
    public let authorizeURL: URL
    public let tokenURL: URL
    public let scope: String
    public let clientIDInfoPlistKey: String

    public static let gmail = OAuthProvider(
        id: .gmail,
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scope: "https://mail.google.com/",
        clientIDInfoPlistKey: "OHIA_GOOGLE_OAUTH_CLIENT_ID"
    )

    public static let microsoft = OAuthProvider(
        id: .microsoft,
        authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scope: "https://outlook.office.com/SMTP.Send "
             + "https://outlook.office.com/IMAP.AccessAsUser.All "
             + "offline_access",
        clientIDInfoPlistKey: "OHIA_MS_OAUTH_CLIENT_ID"
    )

    public static func forID(_ id: MailProvider.OAuthProviderID) -> OAuthProvider {
        switch id {
        case .gmail: .gmail
        case .microsoft: .microsoft
        }
    }

    /// Whether this build ships a client ID for the provider. A build without
    /// one (a build from the public source, which carries no registered OAuth
    /// clients) offers password sign-in only for that provider.
    public var isConfigured: Bool { clientID != nil }

    public var clientID: String? {
        // Xcode's INFOPLIST_KEY_* auto-propagation only works for Apple's
        // documented well-known keys; custom keys never reach the generated
        // Info.plist. Read from a bundled Configuration.plist resource
        // instead — and keep the Info.plist lookup as a forward-compatible
        // fallback in case Apple changes the rules or a fork decides to
        // inject the value via a build-phase script.
        if let v = Bundle.main.object(forInfoDictionaryKey: clientIDInfoPlistKey) as? String,
           !v.isEmpty {
            return v
        }
        guard let v = OAuthProvider.configurationPlist[clientIDInfoPlistKey],
              !v.isEmpty else {
            return nil
        }
        return v
    }

    /// Lazy-loaded string map from `Configuration.plist`. Typed as
    /// `[String: String]` (rather than `[String: Any]`) to satisfy Swift 6
    /// strict-concurrency `Sendable` requirements on module-level statics.
    /// Returns an empty dictionary if the file is missing or unparseable.
    private static let configurationPlist: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else {
            return [:]
        }
        return plist.compactMapValues { $0 as? String }
    }()

    /// Per-provider OAuth redirect URI. Google iOS clients require a reversed-client-ID
    /// scheme that Google validates against the registered client; Microsoft accepts the
    /// arbitrary custom scheme registered on the Azure app's Authentication page.
    public func redirectURI(for clientID: String) -> String {
        switch id {
        case .gmail:
            let suffix = ".apps.googleusercontent.com"
            let bare = clientID.hasSuffix(suffix)
                ? String(clientID.dropLast(suffix.count))
                : clientID
            return "com.googleusercontent.apps.\(bare):/oauth2redirect"
        case .microsoft:
            return "com.ohia.app:/oauth/redirect"
        }
    }
}
