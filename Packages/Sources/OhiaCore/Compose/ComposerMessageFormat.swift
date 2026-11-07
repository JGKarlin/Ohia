import Foundation

/// Wire format for a Composer draft body.
///
/// Rich text is persisted as HTML beside the authoritative plain-text
/// alternative. Plain text deliberately carries no HTML part.
public enum ComposerMessageFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case richText

    public static let newMessageStorageKey = "ohia.composerNewMessageFormat"
    public static let defaultNewMessageFormat: ComposerMessageFormat = .richText

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .plainText: return "Plain Text"
        case .richText: return "Rich Text"
        }
    }

    public static func storedNewMessageFormat(
        in defaults: UserDefaults = .standard
    ) -> ComposerMessageFormat {
        guard let raw = defaults.string(forKey: newMessageStorageKey),
              let format = ComposerMessageFormat(rawValue: raw) else {
            return defaultNewMessageFormat
        }
        return format
    }
}
