// Ohia/Composer/ComposerKeyboardHandler.swift
import SwiftUI

struct ComposerKeyboardHandler: ViewModifier {
    let session: ComposerSession?
    let onSend: () -> Void
    /// Request deletion of the selected queue draft. Both ⌫ and ⌘⌫ route
    /// through the same confirmation. Returns whether an item was found so
    /// the key is consumed only when it acted.
    let onDeleteSelected: () -> Bool

    func body(content: Content) -> some View {
        content
            .onKeyPress(.escape) { handleEscape() }
            // ⌘Return — Send (with the diff-analysis gate when edited).
            // ⌫ / ⌘⌫ — delete the selected queue draft. A focused text editor
            // consumes Backspace first, so this only fires off the text fields.
            .onKeyPress(phases: .down) { press in
                if press.key == .return && press.modifiers.contains(.command) {
                    onSend()
                    return .handled
                }
                if press.key == .delete {
                    let blocked: EventModifiers = [.option, .control, .shift]
                    guard press.modifiers.intersection(blocked).isEmpty else { return .ignored }
                    return onDeleteSelected() ? .handled : .ignored
                }
                return .ignored
            }
    }

    /// Escape dismisses transient Composer chrome only. Window-level closing
    /// stays with the standard macOS close command instead of navigating to
    /// another app surface.
    private func handleEscape() -> KeyPress.Result {
        if let session, session.showDiffAnalysis {
            withAnimation { session.showDiffAnalysis = false }
            return .handled
        } else {
            return .ignored
        }
    }
}

extension View {
    func composerKeyboardHandler(
        session: ComposerSession?,
        onSend: @escaping () -> Void,
        onDeleteSelected: @escaping () -> Bool
    ) -> some View {
        modifier(ComposerKeyboardHandler(
            session: session,
            onSend: onSend,
            onDeleteSelected: onDeleteSelected
        ))
    }
}
