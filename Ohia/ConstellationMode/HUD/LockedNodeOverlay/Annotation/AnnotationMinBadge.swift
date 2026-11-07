import SwiftUI

struct AnnotationMinBadge: View {
    let item: AnnotationItem
    let anchor: CGPoint
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(item.kind.accent)
                    .frame(width: 2)
                Text(item.badgeText)
                    .font(.system(size: 9))
                    .tracking(0.1)
                    .foregroundStyle(item.kind.accent)
                    .lineLimit(1)
            }
            // Intrinsic width — badge sizes to its text. The 8pt trailing
            // padding visually matches the 2pt stripe + 5pt HStack
            // spacing on the left (~7pt), so the text sits with equal
            // breathing room on both sides of the rounded border.
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(
                LinearGradient(
                    colors: [
                        OhiaColors.hoverReadoutGradientTop,
                        OhiaColors.hoverReadoutGradientBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(item.kind.accent.opacity(0.65), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .position(anchor)
        .help("Open \(item.kind.contextLabel)")
        .accessibilityLabel("Closed context: \(item.kind.contextLabel). Click to reopen.")
    }
}
