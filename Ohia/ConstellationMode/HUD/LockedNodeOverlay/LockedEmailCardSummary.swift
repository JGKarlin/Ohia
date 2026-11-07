import SwiftUI

struct LockedEmailCardSummary: View {
    let summary: String?

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        if let summary {
            Text(summary)
                .font(readingTextSize.font(base: 12.5).italic())
                .foregroundStyle(OhiaColors.textSecondary)
                .lineSpacing(readingTextSize.spacing(1.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
                }
        }
    }
}
