import AppKit
import SwiftUI
import OhiaCore

/// First-ingestion witness overlay. Sits on top of `ConstellationModeView`
/// (in onboardingMode) and hosts the "Your constellation is forming..."
/// copy + Enter button. The button enables only after the Metal scene has
/// drawn at least one visible node.
///
/// Numeric pipeline counts live in `ActivityStripView` at the bottom of
/// the shell; duplicating them here would only drift between the two
/// surfaces during heavy ingest.
struct OnboardingWitnessPanel: View {
    let hasRenderedNode: Bool
    let onEnter: () -> Void

    var body: some View {
        VStack {
            transitionPanel
                .padding(.top, 32)
            Spacer()
        }
        .background {
            OnboardingReturnKeyCatcher(
                isEnabled: enterEnabled,
                onEnter: onEnter
            )
            .frame(width: 0, height: 0)
        }
    }

    private var transitionPanel: some View {
        VStack(spacing: 10) {
            Text(titleText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OhiaColors.textPrimary)
            Text(subtitleText)
                .font(OhiaTypography.bodySecondary)
                .foregroundStyle(OhiaColors.textPrimary)
            Button {
                onEnter()
            } label: {
                Text("Enter")
                    .font(OhiaTypography.button)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 24, verticalPadding: 8))
            .keyboardShortcut(.defaultAction)
            .disabled(!enterEnabled)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OhiaColors.spaceBackground.opacity(0.7))
                .background(.ultraThinMaterial.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OhiaColors.chipActiveForeground.opacity(0.12), lineWidth: 1)
        )
    }

    private var enterEnabled: Bool {
        OnboardingEnterGate.isEnabled(hasRenderedNode: hasRenderedNode)
    }

    private var titleText: String {
        "Your constellation is forming..."
    }

    private var subtitleText: String {
        enterEnabled
            ? "Ohia is processing your email history. You can use it now, but it works best once finished — for large mailboxes, consider letting it run overnight."
            : "Please wait for your first node to appear"
    }
}

/// The onboarding Metal scene deliberately owns first responder while its
/// camera input is disabled, so a SwiftUI default-action shortcut cannot rely
/// on the responder chain. This window-scoped monitor exists only with the
/// witness panel and consumes bare Return before the scene or global commands
/// can see it.
private struct OnboardingReturnKeyCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let onEnter: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.isEnabled = isEnabled
        view.onEnter = onEnter
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onEnter = onEnter
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.removeMonitor()
    }

    @MainActor
    final class CatcherView: NSView {
        var isEnabled = false
        var onEnter: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window else {
                    return event
                }
                return OnboardingWitnessKeyboard.handle(
                    event,
                    isEnabled: self.isEnabled,
                    onEnter: self.onEnter
                )
            }
        }
    }
}

enum OnboardingWitnessKeyboard {
    @MainActor
    static func handle(
        _ event: NSEvent,
        isEnabled: Bool,
        onEnter: (() -> Void)?
    ) -> NSEvent? {
        guard isEnabled, isBareEnter(event) else { return event }
        if !event.isARepeat {
            onEnter?()
        }
        return nil
    }

    private static func isBareEnter(_ event: NSEvent) -> Bool {
        let isEnter = event.keyCode == 0x24 || event.keyCode == 0x4C
        guard isEnter else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let blocked: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return flags.intersection(blocked).isEmpty
    }
}
