import AppKit
import SwiftUI

/// Transparent gesture capture overlay for the multitrack area. Carries
/// keyboard navigation (←/→ step messages, shift-±1d, opt-±1w, cmd-±chapter)
/// and ruler shift-drag for bracket setting.
///
/// Initial implementation focuses on keyboard navigation; drag-to-scrub is
/// handled by `TimelineCanvasView`'s `DragGesture`. Shift-drag bracketing
/// is a follow-up.
struct TimelinePlayheadInput: View {

    @Bindable var workspace: TimelineWorkspaceState
    @SwiftUI.FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.leftArrow) {
                if isCommandPressed() {
                    workspace.skipToPreviousChapter()
                } else if isShiftPressed() {
                    workspace.stepPlayheadByDays(-1)
                } else if isOptionPressed() {
                    workspace.stepPlayheadByDays(-7)
                } else {
                    workspace.stepPlayhead(direction: .backward)
                }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                if isCommandPressed() {
                    workspace.skipToNextChapter()
                } else if isShiftPressed() {
                    workspace.stepPlayheadByDays(1)
                } else if isOptionPressed() {
                    workspace.stepPlayheadByDays(7)
                } else {
                    workspace.stepPlayhead(direction: .forward)
                }
                return .handled
            }
            .onKeyPress("[") {
                // Only consume the unmodified `[` — leaves `cmd-[`, `opt-[`,
                // `shift-[`, etc. free for menu shortcuts and text input
                // when a downstream editable field gets focus.
                guard plainKeyModifiers() else { return .ignored }
                workspace.setBracketStartAtPlayhead()
                return .handled
            }
            .onKeyPress("]") {
                guard plainKeyModifiers() else { return .ignored }
                workspace.setBracketEndAtPlayhead()
                return .handled
            }
            .onKeyPress("\\") {
                guard plainKeyModifiers() else { return .ignored }
                workspace.applyBracket(nil)
                return .handled
            }
            .onKeyPress("0") {
                guard plainKeyModifiers() else { return .ignored }
                workspace.resetZoom()
                return .handled
            }
    }

    private func isCommandPressed() -> Bool {
        NSEvent.modifierFlags.contains(.command)
    }
    private func isShiftPressed() -> Bool {
        NSEvent.modifierFlags.contains(.shift)
    }
    private func isOptionPressed() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }
    /// True when no command-class modifier is held — guards single-key
    /// shortcuts so they don't fight macOS / app-level cmd combinations.
    private func plainKeyModifiers() -> Bool {
        let flags = NSEvent.modifierFlags
        return flags.intersection([.command, .option, .control]).isEmpty
    }
}
