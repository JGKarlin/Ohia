import Foundation

/// Whether queuing a message into the Composer also brings the Composer window
/// to the front, focused on that message.
///
/// Default **on**: sending a message to the Composer opens it. Holding ⌥ at
/// click time inverts the decision for that single send — so with the default
/// on, ⌥ queues quietly (no window switch); with it off, ⌥ opens. The visual
/// send cue fires either way; this preference governs only the window fronting.
///
/// Read as a bare `UserDefaults` value (not `@AppStorage`) so non-View call
/// sites — the Constellation action sinks, the Compose disc's live relabel, the
/// AppKit context-menu builder — can resolve the same decision the Settings
/// toggle writes.
enum ComposerOpenOnQueuePreference {
    static let storageKey = "openComposerOnQueue"
    static let defaultValue = true

    /// The persisted setting, defaulting to `true` when unset.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? defaultValue
    }

    /// Whether a send should front the Composer, given whether ⌥ was held at
    /// click time. The setting is the default; ⌥ inverts it for that one send.
    static func opensComposer(optionHeld: Bool) -> Bool {
        isEnabled != optionHeld
    }
}
