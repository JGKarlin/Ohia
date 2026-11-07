import Foundation

public enum ComposerQueueIntakePreference: String, CaseIterable, Identifiable, Sendable {
    case manual
    case automatic

    public static let storageKey = "ohia.composerQueueIntakePreference"
    public static let defaultPreference: ComposerQueueIntakePreference = .manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .automatic: return "Automatic"
        }
    }

    public var detail: String {
        switch self {
        case .manual:
            return "Messages that need a reply wait for you to send them to Composer."
        case .automatic:
            return "Newly triaged needs-reply messages join the Composer queue automatically."
        }
    }

    public static func sharedDefaults() -> UserDefaults {
        OhiaSharedDefaults.store
    }

    public static func stored(in defaults: UserDefaults = sharedDefaults()) -> ComposerQueueIntakePreference {
        guard let raw = defaults.string(forKey: storageKey),
              let preference = ComposerQueueIntakePreference(rawValue: raw) else {
            return defaultPreference
        }
        return preference
    }

    public static func automaticTriageQueueingEnabled(defaults: UserDefaults = sharedDefaults()) -> Bool {
        stored(in: defaults) == .automatic
    }
}
