import AppKit
import SwiftUI

extension View {
    func hidesWindowInsteadOfClosing() -> some View {
        modifier(WindowCloseHidesSceneModifier())
    }

    func suppressesWindowVisibility(while isSuppressed: Bool) -> some View {
        modifier(WindowVisibilitySuppressionModifier(isSuppressed: isSuppressed))
    }
}

private struct WindowCloseHidesSceneModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            WindowCloseHidingAccessor()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct WindowVisibilitySuppressionModifier: ViewModifier {
    let isSuppressed: Bool

    func body(content: Content) -> some View {
        content.background(
            WindowVisibilitySuppressionAccessor(isSuppressed: isSuppressed)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct WindowVisibilitySuppressionAccessor: NSViewRepresentable {
    let isSuppressed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(isSuppressed: isSuppressed, from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isSuppressed: isSuppressed, from: nsView)
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var suppressedWindowNumber: Int?
        private var shouldRestoreWhenUnsuppressed = false
        private var shouldMakeKeyWhenRestored = false
        private var pendingVisibilityRetry = false
        private var visibilityRetryCount = 0
        private var currentSuppressionRequested = false

        func update(isSuppressed: Bool, from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.apply(isSuppressed: isSuppressed, to: view.window)
            }
        }

        private func apply(isSuppressed: Bool, to currentWindow: NSWindow?) {
            guard let currentWindow else { return }
            window = currentWindow
            currentSuppressionRequested = isSuppressed

            if isSuppressed {
                suppressedWindowNumber = currentWindow.windowNumber
                guard currentWindow.isVisible else {
                    scheduleVisibilityRetry(for: currentWindow)
                    return
                }
                visibilityRetryCount = 0
                shouldRestoreWhenUnsuppressed = true
                shouldMakeKeyWhenRestored = shouldMakeKeyWhenRestored || currentWindow.isKeyWindow
                currentWindow.orderOut(nil)
                return
            }

            pendingVisibilityRetry = false
            visibilityRetryCount = 0
            guard shouldRestoreWhenUnsuppressed,
                  suppressedWindowNumber == currentWindow.windowNumber
            else {
                suppressedWindowNumber = nil
                shouldMakeKeyWhenRestored = false
                return
            }

            shouldRestoreWhenUnsuppressed = false
            suppressedWindowNumber = nil
            if shouldMakeKeyWhenRestored {
                currentWindow.makeKeyAndOrderFront(nil)
            } else {
                currentWindow.orderFront(nil)
            }
            shouldMakeKeyWhenRestored = false
        }

        private func scheduleVisibilityRetry(for window: NSWindow) {
            guard !pendingVisibilityRetry, visibilityRetryCount < 20 else { return }
            pendingVisibilityRetry = true
            visibilityRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard let self, let window else { return }
                self.pendingVisibilityRetry = false
                guard self.currentSuppressionRequested,
                      self.suppressedWindowNumber == window.windowNumber
                else { return }
                self.apply(isSuppressed: true, to: window)
            }
        }
    }
}

private struct WindowCloseHidingAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator: WindowCloseHidingDelegate {}
}

class WindowCloseHidingDelegate: NSObject, NSWindowDelegate {
    /// Composer supplies a save gate and then closes normally. Without one,
    /// the Constellation lifecycle window retains its existing hide behavior.
    var closeDecision: (() -> Bool)?
    private weak var window: NSWindow?
    private weak var previousDelegate: (any NSWindowDelegate)?
    private var isResolvingForwardedResponse = false
    private var isForwardingWindowShouldClose = false

    override init() {
        super.init()
    }

    init(currentDelegate: (any NSWindowDelegate)?) {
        super.init()
        capturePreviousDelegate(from: currentDelegate)
    }

    deinit {
        if window?.delegate === self {
            window?.delegate = previousDelegate
        }
    }

    func attach(to view: NSView) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let window = view?.window else { return }
            self.install(on: window)
        }
    }

    func install(on window: NSWindow) {
        guard window.delegate !== self else {
            self.window = window
            return
        }

        self.window = window
        capturePreviousDelegate(from: window.delegate)
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let forwardedDelegate, !isForwardingWindowShouldClose {
            isForwardingWindowShouldClose = true
            defer { isForwardingWindowShouldClose = false }
            if let shouldClose = forwardedDelegate.windowShouldClose?(sender),
               shouldClose == false {
                return false
            }
        }
        if let closeDecision { return closeDecision() }
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) {
            return true
        }
        guard let forwardedDelegate, !isResolvingForwardedResponse else {
            return false
        }
        isResolvingForwardedResponse = true
        defer { isResolvingForwardedResponse = false }
        return forwardedDelegate.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        guard let forwardedDelegate, !isResolvingForwardedResponse else {
            return super.forwardingTarget(for: selector)
        }
        isResolvingForwardedResponse = true
        defer { isResolvingForwardedResponse = false }
        if forwardedDelegate.responds(to: selector) {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    private var forwardedDelegate: (any NSWindowDelegate)? {
        guard let previousDelegate, previousDelegate !== self else { return nil }
        return previousDelegate
    }

    private func capturePreviousDelegate(from currentDelegate: (any NSWindowDelegate)?) {
        if let existingCloseHidingDelegate = currentDelegate as? WindowCloseHidingDelegate {
            previousDelegate = existingCloseHidingDelegate.previousDelegate
        } else {
            previousDelegate = currentDelegate
        }
    }
}
