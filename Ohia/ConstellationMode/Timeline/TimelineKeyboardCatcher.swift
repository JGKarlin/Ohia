import AppKit
import SwiftUI

/// Bridges `NSEvent.keyDown` to a SwiftUI surface. Mirrors
/// `TimelineScrollCatcher` — installs an `NSEvent` local monitor while
/// the catcher is in the window and forwards arrow-key presses to the
/// parent. Mounted as a `.background` of the Timeline workspace so it
/// stays active as long as the lens is showing.
///
/// Key events don't carry a screen location, so the catcher filters
/// only on the responder + modifier-flag axis:
///   - Pass through (don't intercept) if the window's first responder
///     is a text-input view — typing in the search field or compose
///     area still moves the caret left / right.
///   - Pass through if any modifier flags are held — leaves `⌘←`,
///     `⌥→`, etc. wired up to whatever else owns them.
struct TimelineKeyboardCatcher: NSViewRepresentable {

    let onLeftArrow: @MainActor () -> Void
    let onRightArrow: @MainActor () -> Void
    /// Return-key handler. Returns `true` if the action was taken (the
    /// monitor then consumes the event); returns `false` to pass the
    /// keystroke through to whatever else might be listening (default
    /// dialog buttons, etc.). Used for the "commit bracket → viewport"
    /// gesture, which is a no-op when no bracket is active.
    let onReturn: @MainActor () -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        // Suppress the AppKit system focus ring — the catcher only
        // exists to install an NSEvent monitor; it's never a real
        // first-responder target, and the default ring otherwise
        // bleeds blue around the timeline workspace.
        view.focusRingType = .none
        view.onLeftArrow = onLeftArrow
        view.onRightArrow = onRightArrow
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onLeftArrow = onLeftArrow
        nsView.onRightArrow = onRightArrow
        nsView.onReturn = onReturn
    }

    final class CatcherView: NSView {

        var onLeftArrow: (@MainActor () -> Void)?
        var onRightArrow: (@MainActor () -> Void)?
        var onReturn: (@MainActor () -> Bool)?

        private var monitor: Any?
        private var monitorAttempted = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !monitorAttempted {
                monitorAttempted = true
                installMonitor()
            } else if window == nil {
                if let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
                monitorAttempted = false
            }
        }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let window = self.window, event.window === window else { return event }

                // Don't shadow text-field editing. If a text input view is
                // the first responder, arrows belong to the caret.
                if Self.firstResponderIsTextInput(in: window) {
                    return event
                }

                // Leave modified arrows (⌘← / ⌥← / ⇧← / ⌃←) to the rest
                // of the responder chain — they typically mean "previous
                // chapter" / word-jump / select / etc., not "scrub one
                // message."
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let blocking: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
                if !mods.isDisjoint(with: blocking) {
                    return event
                }

                switch event.keyCode {
                case 123:  // left arrow
                    if let handler = self.onLeftArrow {
                        handler()
                        return nil
                    }
                case 124:  // right arrow
                    if let handler = self.onRightArrow {
                        handler()
                        return nil
                    }
                case 36, 76:  // Return / numeric-keypad Enter
                    if let handler = self.onReturn, handler() {
                        return nil
                    }
                default:
                    break
                }
                return event
            }
        }

        /// Walk the first-responder chain looking for any of the standard
        /// AppKit text-input classes. Catches `NSTextView` (used by
        /// `TextEditor`), `NSTextField` and `NSSearchField` field editors
        /// (which the system represents as an `NSTextView` whose delegate
        /// is the field), and the `NSTextField` itself when it claims
        /// first-responder before vending its field editor.
        private static func firstResponderIsTextInput(in window: NSWindow) -> Bool {
            var responder: NSResponder? = window.firstResponder
            while let r = responder {
                if r is NSTextView || r is NSTextField || r is NSSearchField {
                    return true
                }
                responder = r.nextResponder
            }
            return false
        }
    }
}
