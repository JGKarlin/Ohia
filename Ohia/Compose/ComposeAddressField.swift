import SwiftUI
import OhiaCore

/// Chip-based recipient input. Type freely; on `,` or Return, the buffer is
/// committed to chips via the bound state's commit closure. Click a chip to
/// remove. Unparseable pieces render under the input as red-underlined text.
struct ComposeAddressField: View {
    let label: String
    @Binding var input: String
    let chips: [ComposeAddressEncoding.ParsedAddress]
    let invalidPieces: [String]
    let onCommit: () -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
                .textCase(.uppercase)

            // Chips + input share a single wrapped row.
            AddressFlowLayout(spacing: 4) {
                // Stable identity by address — index-based id would recycle
                // the wrong chip view on a mid-list removal and could fire
                // onRemove with a stale captured offset during animations.
                ForEach(chips, id: \.asciiAddress) { addr in
                    chipView(addr.asciiAddress) {
                        if let i = chips.firstIndex(where: { $0.asciiAddress == addr.asciiAddress }) {
                            onRemove(i)
                        }
                    }
                }
                TextField("", text: $input, prompt: Text(chips.isEmpty ? "name@example.com" : "+ add"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .frame(minWidth: 120)
                    .onSubmit(onCommit)
                    .onChange(of: input) { _, newValue in
                        if newValue.contains(",") { onCommit() }
                    }
            }
            if !invalidPieces.isEmpty {
                Text(invalidPieces.joined(separator: ", "))
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.frameUrgencyHigh)
                    .underline()
            }
        }
    }

    private func chipView(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.chipActiveForeground)
            Button {
                onRemove()
            } label: {
                Label("Remove \(text)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(OhiaColors.chipActiveBackground)
        .overlay(
            Capsule().strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

/// Minimal flow layout — wraps children to next line when they overflow.
/// SwiftUI's HStack doesn't wrap; Layout protocol gives us the freedom.
/// Named `AddressFlowLayout` to avoid a redeclaration conflict with the
/// `FlowLayout` that already exists in `LanguageSelectionStepView.swift`.
/// Internal (not private) so `ComposeRecipientField` can reuse the same wrap.
struct AddressFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
