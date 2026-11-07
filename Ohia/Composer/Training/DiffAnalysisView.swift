// Ohia/FocusMode/Training/DiffAnalysisView.swift
import SwiftUI
import OhiaML

struct DiffAnalysisView: View {
    @Binding var signals: [TrainingSignal]
    let onCancel: () -> Void

    /// Closed by default; only the chevron or the Space key toggles it open.
    @State private var isPinnedOpen = false
    @FocusState private var isFocused: Bool

    private var isExpanded: Bool { isPinnedOpen }

    var body: some View {
        GlassPane(accentColor: OhiaColors.chipActiveForeground, isForeground: true) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if isExpanded {
                    expandedContent
                        .transition(ComposerDisclosureState.transition)
                }
            }
            .animation(ComposerDisclosureState.animation, value: isExpanded)
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard isFocused, press.key == .space else { return .ignored }
                toggleOpen()
                return .handled
            }
        }
    }

    private func toggleOpen() {
        withAnimation(ComposerDisclosureState.animation) {
            isFocused = true
            isPinnedOpen.toggle()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                toggleOpen()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                    ComposerSectionHeader(title: "Training Signals", symbolName: "waveform.path.ecg")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinnedOpen ? "Collapse Training Signals" : "Expand Training Signals")
            .accessibilityLabel(isPinnedOpen ? "Collapse Training Signals" : "Expand Training Signals")

            Spacer()

            Text("\(signals.count) signal\(signals.count == 1 ? "" : "s")")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(OhiaTypography.button)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 6))
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if signals.isEmpty {
                Text("All signals dismissed")
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textDim)
                    .padding(.vertical, 4)
            } else {
                ForEach(signals) { signal in
                    TrainingSignalCard(signal: signal) {
                        withAnimation {
                            signals.removeAll { $0.id == signal.id }
                        }
                    }
                }
            }

            Text(signals.isEmpty
                ? "Sending will not use this edit for elevated personalization."
                : "After the message sends, these approved edits can refine your draft model.")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
        }
    }
}
