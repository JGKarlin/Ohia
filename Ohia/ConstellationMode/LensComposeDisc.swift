import AppKit
import SwiftUI

/// Tracks whether the Option (⌥) key is currently held, app-wide, so Compose
/// affordances can still front the Composer on click while the gloss stays
/// fixed at "Compose" (see `ComposerOpenOnQueuePreference`).
///
/// Backed by a single local `NSEvent` flags-changed monitor (AppKit delivers
/// these on the main thread while the app is active). Observed by SwiftUI through
/// `@Observable`: any view that reads `isOptionHeld` in its body re-renders when
/// the key state flips. Mirrors the `NewMailArrivalLedger.shared` singleton idiom.
@Observable @MainActor
final class OptionKeyMonitor {
    static let shared = OptionKeyMonitor()

    private(set) var isOptionHeld = false
    private var monitor: Any?

    private init() {
        // Seed from the current hardware state so ⌥-gated fronting is correct
        // before the first flags-change event arrives.
        isOptionHeld = NSEvent.modifierFlags.contains(.option)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            // AppKit delivers flags-changed on the main thread; assert that for
            // Swift 6 isolation rather than hopping (which would lag the relabel).
            MainActor.assumeIsolated {
                self?.isOptionHeld = held
            }
            return event
        }
    }
}

/// The Compose action disc shared by every lens control column and the
/// hover/lock Compose rail. The gloss is always "Compose"; ⌥ and the
/// `ComposerOpenOnQueuePreference` setting still decide whether the click also
/// fronts the Composer — reflected in the accessibility string, not the label.
struct LensComposeDisc: View {
    var isActive: Bool = false
    var isEnabled: Bool = true
    var capturesPressDown: Bool = false
    /// VoiceOver text at rest (no ⌥), e.g. "Send to Composer" or, when the
    /// column has nothing to send, "Select messages to send to Composer".
    var restAccessibility: String = "Send to Composer"
    let action: () -> Void

    /// Observed (not a raw `UserDefaults` read) so a mid-session Settings change
    /// re-renders the disc and the label never lags behind the action.
    @AppStorage(ComposerOpenOnQueuePreference.storageKey)
    private var opensOnQueueSetting = ComposerOpenOnQueuePreference.defaultValue

    var body: some View {
        let opens = (opensOnQueueSetting != OptionKeyMonitor.shared.isOptionHeld) && isEnabled
        LensActionDisc(
            glyph: .native("square.and.pencil.circle.fill"),
            label: "Compose",
            accessibility: opens ? "Compose and open" : restAccessibility,
            isActive: isActive,
            isEnabled: isEnabled,
            tint: MessageStatusColors.pendingReply,
            capturesPressDown: capturesPressDown,
            action: action
        )
    }
}

/// The Compose button in the Front Page card hover cluster (a `ClusterButtonChip`
/// rather than a 38pt disc). Same ⌥ fronting behaviour as `LensComposeDisc`;
/// the gloss stays "Compose" and the tooltip describes whether the click opens.
/// Encapsulated as its own view so the live ⌥ relabel re-renders only this chip,
/// not the whole article card.
struct ComposeClusterButton: View {
    let isInQueue: Bool
    var capturesPressDown: Bool = false
    let action: () -> Void

    @AppStorage(ComposerOpenOnQueuePreference.storageKey)
    private var opensOnQueueSetting = ComposerOpenOnQueuePreference.defaultValue

    var body: some View {
        let opens = opensOnQueueSetting != OptionKeyMonitor.shared.isOptionHeld
        // Already-queued keeps its status hint at rest regardless of the open
        // decision; the label is only advisory (this chip always opens on click).
        let help = isInQueue
            ? "In Composer queue"
            : (opens ? "Compose and open" : "Send to Composer")
        ClusterButtonChip(
            glyph: .native("square.and.pencil.circle.fill"),
            tint: MessageStatusColors.pendingReply,
            help: help,
            capturesPressDown: capturesPressDown,
            action: action
        )
    }
}
