// Ohia/FocusMode/Training/TrainingSignalCard.swift
import SwiftUI
import OhiaML

struct TrainingSignalCard: View {
    let signal: TrainingSignal
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(signalColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(signal.description)
                    .font(OhiaTypography.diffSignal)
                    .foregroundStyle(OhiaColors.textPrimary)

                if let original = signal.originalSpan, let edited = signal.editedSpan {
                    HStack(spacing: 4) {
                        Text("\"\(original.prefix(30))\"")
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.frameUrgencyHigh.opacity(0.6))
                            .strikethrough()
                        Text("→")
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.textTertiary)
                        Text("\"\(edited.prefix(30))\"")
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.statusReady.opacity(0.8))
                    }
                }
            }

            Spacer()

            Button(action: onDismiss) {
                Label("Dismiss training signal", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaRed, horizontalPadding: 4, verticalPadding: 4))
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var signalColor: Color {
        switch signal.type {
        case .toneShift: OhiaColors.chipActiveForeground
        case .contentAdded: OhiaColors.chipActiveForeground
        case .contentRemoved: OhiaColors.frameUrgencyHigh
        case .rewrite: OhiaColors.iconPillForeground
        case .sourceOverride: OhiaColors.chipActiveForeground
        }
    }
}
