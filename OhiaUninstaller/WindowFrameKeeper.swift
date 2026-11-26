import AppKit
import OhiaUninstallKit
import SwiftUI

/// Gives the uninstaller's view what only its window knows, and keeps that
/// window on its own screen. SwiftUI sizes the window from its content
/// (contentSize resizability) but has no API to read the window's screen or
/// title-bar inset, or to move a window after it opened; a window that grows
/// near the bottom of the screen would put its buttons out of reach.
///
/// It reports the outcome's content-height cap for the window's screen when
/// the window appears, becomes key or changes screens, and after every
/// resize moves the window back inside that screen's visible frame.
struct WindowFrameKeeper: NSViewRepresentable {
    let onCapChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> KeeperView {
        KeeperView(onCapChange: onCapChange)
    }

    func updateNSView(_ nsView: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        private let onCapChange: (CGFloat) -> Void
        private var observers: [NSObjectProtocol] = []
        private var reportedCap: CGFloat?

        init(onCapChange: @escaping (CGFloat) -> Void) {
            self.onCapChange = onCapChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keepOnScreen() }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCap() }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCap() }
                },
            ]
            reportCap()
        }

        private func reportCap() {
            // Before the window is first shown it may have no screen yet; the
            // main screen stands in until it becomes key on its own.
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let cap = FinishedWindowLayout.contentHeightCap(
                visibleHeight: screen.visibleFrame.height,
                titleBarInset: window.frame.height - window.contentLayoutRect.height)
            guard cap != reportedCap else { return }
            reportedCap = cap
            onCapChange(cap)
        }

        private func keepOnScreen() {
            guard let window, let screen = window.screen else { return }
            let kept = FinishedWindowLayout.keptInside(window.frame, visible: screen.visibleFrame)
            if kept.origin != window.frame.origin {
                window.setFrameOrigin(kept.origin)
            }
        }
    }
}
