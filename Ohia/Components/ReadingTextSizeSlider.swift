// Ohia/Components/ReadingTextSizeSlider.swift
// Discrete step slider for ReadingTextSize. Mirrors HistoryIngestionSlider's
// track, bubble, and tick affordances used during onboarding.

import SwiftUI

struct ReadingTextSizeSlider: View {
    @Binding var selection: ReadingTextSize

    /// Optional label rendered above the track. Empty by default — the
    /// Settings screen names the control with its own section-matching label.
    var caption: String = ""

    private let sizes = ReadingTextSize.allCases

    private var currentIndex: Int {
        sizes.firstIndex(of: selection) ?? ReadingTextSize.allCases.firstIndex(of: .standard) ?? 0
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
                let step = usable / CGFloat(max(sizes.count - 1, 1))
                let trackY: CGFloat = 12
                let tickColumnCenterY: CGFloat = 40
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

                    ForEach(Array(sizes.enumerated()), id: \.element.id) { idx, size in
                        let x = leftPad + CGFloat(idx) * step
                        ReadingTextSizeTickButton(
                            size: size,
                            isSelected: idx == currentIndex,
                            isReached: idx <= currentIndex
                        ) {
                            selection = size
                        }
                        .position(x: x, y: tickColumnCenterY)
                    }

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
                            let snapped = Int(round(raw))
                            if snapped != currentIndex {
                                selection = sizes[snapped]
                            }
                        }
                )
            }
            .frame(height: 68)
        }
    }
}

private struct ReadingTextSizeTickButton: View {
    let size: ReadingTextSize
    let isSelected: Bool
    let isReached: Bool
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

                Text(size.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(labelColor)
                    .fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(size.label)
        .accessibilityLabel("Set reading text to \(size.label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
