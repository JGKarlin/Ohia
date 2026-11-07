import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transparent AppKit drop receiver used over the shared Constellation pane.
/// SwiftUI's typed drop modifiers are unreliable over the Metal-backed scene,
/// so this view registers directly for the Withheld pasteboard type while a
/// Withheld row drag is active.
struct WithheldDropReceiverView: NSViewRepresentable {
    @Binding var isTargeted: Bool

    var onDrop: ([WithheldRowDragPayload]) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes([WithheldRowDragPayload.pasteboardType])
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onTargetedChange = { isTargeted = $0 }
        nsView.onDrop = onDrop
        nsView.onEnded = onEnded
    }

    final class DropView: NSView {
        var onTargetedChange: (Bool) -> Void = { _ in }
        var onDrop: ([WithheldRowDragPayload]) -> Void = { _ in }
        var onEnded: () -> Void = {}

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard hasPayload(sender.draggingPasteboard) else {
                onTargetedChange(false)
                return []
            }
            onTargetedChange(true)
            return .move
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard hasPayload(sender.draggingPasteboard) else {
                onTargetedChange(false)
                return []
            }
            onTargetedChange(true)
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let hasPayload = hasPayload(sender.draggingPasteboard)
            if !hasPayload {
                finishDragTargeting()
            }
            return hasPayload
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let payloads = payloads(from: sender.draggingPasteboard)
            defer { finishDragTargeting() }
            guard !payloads.isEmpty else { return false }
            onDrop(payloads)
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            finishDragTargeting()
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            finishDragTargeting()
        }

        private func finishDragTargeting() {
            onTargetedChange(false)
            onEnded()
        }

        private func hasPayload(_ pasteboard: NSPasteboard) -> Bool {
            WithheldRowDragPayload.hasPayload(pasteboard)
        }

        private func payloads(from pasteboard: NSPasteboard) -> [WithheldRowDragPayload] {
            WithheldRowDragPayload.payloads(from: pasteboard)
        }
    }
}
