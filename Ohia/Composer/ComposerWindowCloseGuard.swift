import AppKit
import SwiftUI

/// Flush before AppKit destroys Composer's view state. A failed save leaves
/// the window and its editor buffer available for retry. App quit has its own
/// termination flush because AppKit does not ask windowShouldClose on quit.
struct ComposerWindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> WindowCloseHidingDelegate {
        WindowCloseHidingDelegate()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.closeDecision = shouldClose
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.closeDecision = shouldClose
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: WindowCloseHidingDelegate) {
        coordinator.closeDecision = nil
    }
}
