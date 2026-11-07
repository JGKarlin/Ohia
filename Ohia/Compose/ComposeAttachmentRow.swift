import SwiftUI

struct ComposeAttachmentRow: View {
    let paths: [String]
    let onRemove: (Int) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("ATTACH")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
            // Stable identity by path string — index-based id would recycle
            // the wrong chip on a mid-list removal.
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                chip(path: path) { onRemove(index) }
            }
            Button(action: onAdd) {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip").font(.system(size: 9))
                    Text("Attach")
                        .font(OhiaTypography.cardDetail)
                }
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
            Spacer()
        }
    }

    private func chip(path: String, onRemove: @escaping () -> Void) -> some View {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        // Synchronous stat is acceptable: attachment lists are small (≤ a few
        // items) and paths are local. ByteCountFormatter handles the sub-KB
        // case correctly ("512 bytes" instead of "0 KB").
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return HStack(spacing: 4) {
            Text("\(name) · \(sizeLabel)")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
            Button {
                onRemove()
            } label: {
                Label("Remove attachment \(name)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(OhiaColors.chipRestBackground)
        .overlay(
            Capsule().strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}
