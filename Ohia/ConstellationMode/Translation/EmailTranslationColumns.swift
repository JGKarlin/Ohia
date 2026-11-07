import SwiftUI

/// Two-column reading layout used by the Front Page reader and the Timeline
/// viewport: the original body on the left, the generated translation on the
/// right, each under a small language-name header. Collapses to a stacked
/// (original-over-translation) layout when the pane is too narrow for two
/// readable columns.
struct EmailTranslationColumns<Leading: View, Trailing: View>: View {
    let leadingHeader: String
    let trailingHeader: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    /// Below this width two columns would each be too narrow to read, so the
    /// layout stacks vertically instead.
    private static var sideBySideMinimumWidth: CGFloat { 640 }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideMinimumWidth {
                HStack(spacing: 0) {
                    column(header: leadingHeader) { leading() }
                    Divider().overlay(OhiaColors.glassBorder)
                    column(header: trailingHeader) { trailing() }
                }
            } else {
                VStack(spacing: 0) {
                    column(header: leadingHeader) { leading() }
                    Divider().overlay(OhiaColors.glassBorder)
                    column(header: trailingHeader) { trailing() }
                }
            }
        }
        // A bare GeometryReader proposes nothing to itself; the floor guarantees
        // the columns stay readable even if a parent ever offers little height.
        .frame(minHeight: 200)
    }

    private func column<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isJapaneseHeader = header == LanguageAutonym.name(forCode: "ja")

        return VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased())
                .font(.system(size: isJapaneseHeader ? 11.5 : 10, weight: .heavy))
                .tracking(isJapaneseHeader ? 0.4 : 1.1)
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The trailing-column content: the summarization loading animation while the
/// translation is generating, then the translated text in a scroll view once it
/// lands. `font` matches the host surface's body typography.
struct TranslationColumnBody: View {
    @Bindable var model: EmailTranslationModel
    var baseFontSize: CGFloat = 15

    var body: some View {
        if model.isTranslating {
            AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 320, slotHeight: 32)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .accessibilityLabel("Translation loading")
        } else if let text = model.translatedText {
            ScrollView {
                TranslatedBodyText(text: text, baseFontSize: baseFontSize)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }
        }
    }
}

/// Plain-text rendering of a generated translation, with selection enabled.
/// Shared by the two-column surfaces and the pane-lens toggle so translated
/// prose reads consistently wherever it appears.
struct TranslatedBodyText: View {
    let text: String
    var baseFontSize: CGFloat = 12.5

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        Text(text)
            .font(readingTextSize.font(base: baseFontSize))
            .lineSpacing(readingTextSize.spacing(2))
            .foregroundStyle(OhiaColors.textPrimary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
