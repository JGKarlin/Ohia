// Ohia/Components/HistoryIngestionSlider.swift
// Shared slider for picking a HistoryIngestionPreset. Used in:
//   - Onboarding account selection (any preset selectable)
//   - Settings → Accounts → expand history (narrower presets disabled)
//   - Settings → Add another account (any preset selectable)

import OhiaCore
import SwiftUI

struct HistoryIngestionSlider: View {
    @Binding var selection: HistoryIngestionPreset

    /// When set, presets that would narrow the window relative to this value
    /// are disabled. Used in Account Settings, where we cannot shorten an
    /// already-applied window without destructive deletion.
    var minimumWidening: HistoryIngestionPreset?

    /// Label rendered above the track. Defaults to "Import mail history".
    /// Pass an empty string to omit it (e.g. when a surrounding title already
    /// names the control).
    var caption: String = "Import mail history"

    private let presets = HistoryIngestionPreset.allCases

    private var currentIndex: Int {
        presets.firstIndex(of: selection) ?? 0
    }

    private var minimumEnabledIndex: Int {
        guard let floor = minimumWidening,
              let floorIndex = presets.firstIndex(of: floor)
        else { return 0 }
        return floorIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !caption.isEmpty {
                Text(caption)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }

            GeometryReader { proxy in
                let leftPad: CGFloat = 26
                let rightPad: CGFloat = 26
                let usable = max(0, proxy.size.width - leftPad - rightPad)
                let step = usable / CGFloat(max(presets.count - 1, 1))
                let trackY: CGFloat = 44
                let bubbleY: CGFloat = 14
                let tickColumnCenterY: CGFloat = 72
                let thumbX = leftPad + CGFloat(currentIndex) * step

                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(OhiaColors.surface(0.18))
                        .frame(width: usable, height: 5)
                        .position(x: leftPad + usable / 2, y: trackY)

                    Capsule()
                        .fill(OhiaColors.chipActiveForeground.opacity(0.5))
                        .frame(width: max(0, thumbX - leftPad), height: 5)
                        .position(x: leftPad + max(0, thumbX - leftPad) / 2, y: trackY)

                    ForEach(Array(presets.enumerated()), id: \.element.id) { idx, preset in
                        let x = leftPad + CGFloat(idx) * step
                        let enabled = idx >= minimumEnabledIndex
                        HistoryIngestionTickButton(
                            preset: preset,
                            isSelected: idx == currentIndex,
                            isReached: idx <= currentIndex,
                            isEnabled: enabled
                        ) {
                            if enabled {
                                selection = preset
                            }
                        }
                        .position(x: x, y: tickColumnCenterY)
                    }

                    valueBubble
                        .position(
                            x: bubbleClampedX(thumbX: thumbX, usable: usable, leftPad: leftPad),
                            y: bubbleY
                        )

                    Path { path in
                        path.move(to: CGPoint(x: thumbX - 4, y: bubbleY + 14))
                        path.addLine(to: CGPoint(x: thumbX + 4, y: bubbleY + 14))
                        path.addLine(to: CGPoint(x: thumbX, y: bubbleY + 22))
                        path.closeSubpath()
                    }
                    .fill(OhiaColors.glassPanel)

                    Circle()
                        .fill(OhiaColors.ohiaGreen)
                        .overlay(Circle().strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1.5))
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1.5)
                        .position(x: thumbX, y: trackY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let local = value.location.x - leftPad
                            let raw = max(0, min(usable, local)) / max(step, 0.0001)
                            let snapped = max(Int(round(raw)), minimumEnabledIndex)
                            if snapped != currentIndex {
                                selection = presets[snapped]
                            }
                        }
                )
            }
            .frame(height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption.isEmpty ? "Import mail history" : caption)
            .accessibilityValue(selection.title)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    moveSelection(by: 1)
                case .decrement:
                    moveSelection(by: -1)
                @unknown default:
                    break
                }
            }
        }
    }

    private func moveSelection(by offset: Int) {
        let nextIndex = min(
            presets.count - 1,
            max(minimumEnabledIndex, currentIndex + offset)
        )
        selection = presets[nextIndex]
    }

    private var valueBubble: some View {
        Text(selection.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OhiaColors.textPrimary)
            .monospacedDigit()
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OhiaColors.glassPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                    )
            )
    }

    private func bubbleClampedX(thumbX: CGFloat, usable: CGFloat, leftPad: CGFloat) -> CGFloat {
        let half: CGFloat = 38
        let low = leftPad + half
        let high = leftPad + usable - half
        return min(max(thumbX, low), high)
    }
}

private struct HistoryIngestionTickButton: View {
    let preset: HistoryIngestionPreset
    let isSelected: Bool
    let isReached: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Rectangle()
                    .fill(stemFill)
                    .frame(width: 1, height: 10)

                Circle()
                    .fill(dotFill)
                    .frame(
                        width: isSelected ? 10 : 7,
                        height: isSelected ? 10 : 7
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isSelected ? OhiaColors.ohiaYellow : Color.clear,
                                lineWidth: 1.2
                            )
                    )

                Text(preset.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(labelColor)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverFill)
            )
            .opacity(isEnabled ? 1.0 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .help(helpText)
        .accessibilityLabel("Set history to \(preset.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var helpText: String {
        if !isEnabled { return "Cannot shorten the history window" }
        return preset.title
    }

    private var stemFill: Color {
        if isSelected { return OhiaColors.ohiaYellow }
        if isReached { return OhiaColors.chipActiveForeground.opacity(0.6) }
        return OhiaColors.textSecondary.opacity(0.45)
    }

    private var dotFill: Color {
        if isSelected { return OhiaColors.ohiaYellow }
        if isReached { return OhiaColors.chipActiveForeground.opacity(0.8) }
        return OhiaColors.textSecondary.opacity(0.8)
    }

    private var labelColor: Color {
        if isSelected { return OhiaColors.textPrimary }
        if isHovering { return OhiaColors.textPrimary }
        return OhiaColors.textSecondary
    }

    private var hoverFill: Color {
        if isSelected { return Color.clear }
        if isHovering { return OhiaColors.surface(0.10) }
        return Color.clear
    }
}

struct HistoryIngestionCautionNote: View {
    enum Variant {
        /// Full explanation shown during onboarding / first account setup.
        case full
        /// Short form for expanding history from Account Settings.
        case expansion
    }

    var variant: Variant = .full

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaYellow)
                .padding(.top, 1)
            Text(copy)
                .font(.system(size: 11.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OhiaColors.surface(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var copy: String {
        switch variant {
        case .full: Self.fullCopy
        case .expansion: Self.expansionCopy
        }
    }

    static let fullCopy: String = "Larger windows give the model more email history to learn your voice and surface older threads, but the initial ingestion runs in the background and can take many hours or days at the widest settings. Smaller windows are usable within minutes and let Ohia start learning from your most-recent patterns first. You can expand the history later from Account Settings."

    static let expansionCopy: String = "Expanding the history window ingests older email in the background. The wider the window, the longer it takes to process in the background."
}
