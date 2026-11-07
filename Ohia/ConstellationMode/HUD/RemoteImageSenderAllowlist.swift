import Foundation
import Observation

/// Persisted set of sender addresses the user has chosen to auto-load remote
/// images from ("Always from this sender"). Remote images are blocked by
/// default for privacy (remote loads leak open-time and IP to the sender); a
/// sender on this list has that block lifted for all of their mail, now and
/// going forward.
///
/// Backed by `UserDefaults` so the choice survives launches. Addresses are
/// normalized (trimmed, lowercased, angle-brackets stripped) so display-name
/// variations collapse to the same key. `@Observable` so the body view and the
/// header chip re-render the moment a sender is allowed.
@MainActor
@Observable
final class RemoteImageSenderAllowlist {
    static let shared = RemoteImageSenderAllowlist()

    private let defaults: UserDefaults
    private let defaultsKey: String
    private(set) var allowedSenders: Set<String>

    init(defaults: UserDefaults = .standard, defaultsKey: String = "ohia.remoteImageAllowedSenders") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.allowedSenders = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    /// True when the sender's mail should load remote images automatically.
    /// A blank/unknown sender is never auto-allowed.
    func isAllowed(_ sender: String?) -> Bool {
        guard let key = Self.normalize(sender) else { return false }
        return allowedSenders.contains(key)
    }

    /// Trust a sender's remote images from now on. No-op for a blank sender.
    func allow(_ sender: String?) {
        guard let key = Self.normalize(sender) else { return }
        guard allowedSenders.contains(key) == false else { return }
        allowedSenders.insert(key)
        persist()
    }

    /// Revoke a previously trusted sender (for a future Settings affordance).
    func disallow(_ sender: String?) {
        guard let key = Self.normalize(sender),
              allowedSenders.contains(key) else { return }
        allowedSenders.remove(key)
        persist()
    }

    private func persist() {
        // Sorted for a stable on-disk representation.
        defaults.set(allowedSenders.sorted(), forKey: defaultsKey)
    }

    /// Normalizes a raw sender/from value to an allowlist key, or `nil` when it
    /// carries no usable address. Extracts the address from a
    /// `Display Name <addr@host>` form when present.
    static func normalize(_ sender: String?) -> String? {
        guard let sender else { return nil }
        var value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = value.lastIndex(of: "<"),
           let close = value[open...].firstIndex(of: ">"),
           value.index(after: open) < close {
            value = String(value[value.index(after: open)..<close])
        }
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' ").union(.whitespacesAndNewlines))
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
