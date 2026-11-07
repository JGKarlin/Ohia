import Foundation

/// The external app-backed Composer source providers the user can switch on
/// or off in Settings → Sources: the outside-the-mailbox evidence readers
/// offered in the Composer's "Add" popover (and, for Calendar, the automatic
/// availability source compiled into every scheduling reply).
///
/// Mailbox-internal evidence — thread history, past replies, memories,
/// attachments, semantic retrieval — is not listed here; it is always
/// compiled.
public enum ComposerSourceProvider: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case contacts
    case appleNotes
    case website
    case screenshot
    case messages

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .calendar:   return "Calendar"
        case .contacts:   return "Contacts"
        case .appleNotes: return "Apple Notes"
        case .website:    return "Website"
        case .screenshot: return "Screenshot"
        case .messages:   return "Messages"
        }
    }
}

/// Enablement storage for `ComposerSourceProvider`, shared across processes.
///
/// The app and generative worker use the App Group defaults suite, so
/// `ComposerSourceCompiler` honors the same toggles in both processes.
public enum ComposerSourceProviderPreference {

    /// Every provider ships enabled; a toggle-off is the stored exception.
    public static let defaultEnabled = true

    /// The UserDefaults key backing one provider's switch.
    public static func storageKey(for provider: ComposerSourceProvider) -> String {
        "ohia.sourceProvider.\(provider.rawValue)"
    }

    public static func isEnabled(
        _ provider: ComposerSourceProvider,
        defaults: UserDefaults = OhiaSharedDefaults.store
    ) -> Bool {
        defaults.object(forKey: storageKey(for: provider)) as? Bool ?? defaultEnabled
    }

    public static func setEnabled(
        _ enabled: Bool,
        for provider: ComposerSourceProvider,
        defaults: UserDefaults = OhiaSharedDefaults.store
    ) {
        defaults.set(enabled, forKey: storageKey(for: provider))
    }
}
