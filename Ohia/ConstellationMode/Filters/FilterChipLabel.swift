// Ohia/ConstellationMode/Filters/FilterChipLabel.swift
import SwiftUI

/// Shared visual primitive for every filter chip in the Constellation
/// toolbar. Renders an unambiguous on/off state: pressed chips adopt
/// the canonical Ohia accent (green on light, yellow on dark) sourced
/// from `OhiaColors.chipActive*`; unpressed chips read as dim neutral
/// text on a quiet surface tint.
public struct FilterChipLabel: View {
    public let text: String
    public let systemImage: String?
    public let isOn: Bool
    public let size: CGFloat
    public let height: CGFloat
    public let horizontalPadding: CGFloat

    public init(
        text: String,
        systemImage: String? = nil,
        isOn: Bool,
        size: CGFloat = 11,
        height: CGFloat = 22,
        horizontalPadding: CGFloat = 8
    ) {
        self.text = text
        self.systemImage = systemImage
        self.isOn = isOn
        self.size = size
        self.height = height
        self.horizontalPadding = horizontalPadding
    }

    public var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
            .font(.system(size: size, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn
                ? OhiaColors.chipActiveForeground
                : OhiaColors.textSecondary)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn
                        ? OhiaColors.chipActiveBackground
                        : OhiaColors.chipRestBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isOn
                        ? OhiaColors.chipActiveBorder
                        : OhiaColors.chipRestBorder,
                        lineWidth: 1)
            }
    }
}
