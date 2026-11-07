import SwiftUI

struct LockedEmailCardBody: View {
    enum Presentation {
        case standalone
        case inline
        case continuousHostScroll
    }

    struct HTMLLayout: Equatable {
        let verticalScrollOwnership: LockedEmailHTMLView.VerticalScrollOwnership
        let constrainsToMaximumHeight: Bool
        let drawsPaneFrame: Bool
    }

    let bodyState: LockedEmailCardContent.BodyState
    /// Maximum height the body region is allowed to take. The overlay computes this
    /// from the live scene height (window height minus the card's header, footer, and
    /// outer margins), so on a tall window the body grows to use the available room
    /// before falling back to scrolling.
    let maxBodyHeight: CGFloat
    /// The message's sender address, used to key the per-sender remote-image
    /// allowlist. `nil` (e.g. sent mail / unknown) keeps remote images blocked
    /// with no unblock chip.
    var senderAddress: String? = nil
    var searchHighlight: SearchMatchHighlight? = nil
    /// When true, rich HTML email bodies are re-themed to sit on Ohia's dark
    /// canvas instead of preserving bright sender backgrounds.
    var blendsHTMLWithCanvas: Bool = false
    /// Standalone mode owns its own adaptive scroll/frame behavior. Inline mode
    /// keeps the existing attachment-card HTML pane while rendering plain text
    /// at natural height. Continuous-host mode lets an enclosing reader own the
    /// scroll for both plain text and rich HTML.
    var presentation: Presentation = .standalone

    @Environment(\.readingTextSize) private var readingTextSize

    /// Whether this sender's remote images load automatically. Reading the
    /// shared allowlist here registers observation, so trusting a sender
    /// live-reloads the body with its images.
    private var loadsRemoteImages: Bool {
        RemoteImageSenderAllowlist.shared.isAllowed(senderAddress)
    }

    var body: some View {
        if Self.usesHTMLRenderer(for: bodyState, presentation: presentation),
           case .loaded(let content) = bodyState,
           let htmlDocument = content.htmlDocument,
           !content.isEmpty {
            htmlBodyView(htmlDocument)
        } else if presentation == .standalone {
            fittingTextBody
        } else {
            bodyView
        }
    }

    static func usesHTMLRenderer(
        for bodyState: LockedEmailCardContent.BodyState,
        presentation _: Presentation
    ) -> Bool {
        guard case .loaded(let content) = bodyState,
              content.htmlDocument != nil,
              !content.isEmpty else {
            return false
        }
        return true
    }

    static func htmlLayout(for presentation: Presentation) -> HTMLLayout {
        switch presentation {
        case .standalone, .inline:
            HTMLLayout(
                verticalScrollOwnership: .webView,
                constrainsToMaximumHeight: true,
                drawsPaneFrame: true
            )
        case .continuousHostScroll:
            HTMLLayout(
                verticalScrollOwnership: .host,
                constrainsToMaximumHeight: false,
                drawsPaneFrame: false
            )
        }
    }

    private var fittingTextBody: some View {
        // ViewThatFits picks the first child whose ideal size fits the proposed space.
        // Inside the dynamic `maxHeight: maxBodyHeight` frame:
        //   - short emails  → unscrolled `bodyView` fits, card shrinks to content
        //   - long emails on small windows  → ScrollView fallback takes the cap and scrolls
        //   - long emails on tall windows   → cap grows with the window so more body fits
        // This makes the card content-driven for short messages while still bounded
        // for long ones, without a fixed empty-bottom region in either case.
        ViewThatFits(in: .vertical) {
            bodyView
            ScrollView {
                bodyView
            }
        }
        .frame(maxHeight: max(1, maxBodyHeight), alignment: .top)
    }

    @ViewBuilder
    private func htmlBodyView(_ document: LockReadoutHTMLDocument) -> some View {
        let layout = Self.htmlLayout(for: presentation)
        if layout.constrainsToMaximumHeight {
            let outerHeight = max(1, maxBodyHeight)
            let verticalPadding = min(24, max(0, outerHeight - 1))
            let webHeight = max(1, outerHeight - verticalPadding)
            LockedEmailHTMLView(
                document: document,
                blendsWithCanvas: blendsHTMLWithCanvas,
                loadsRemoteImages: loadsRemoteImages,
                searchHighlight: searchHighlight,
                verticalScrollOwnership: layout.verticalScrollOwnership
            )
                .frame(height: webHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    if layout.drawsPaneFrame {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, verticalPadding / 2)
                .frame(height: outerHeight, alignment: .top)
                .accessibilityLabel("HTML email body")
        } else {
            LockedEmailHTMLView(
                document: document,
                blendsWithCanvas: blendsHTMLWithCanvas,
                loadsRemoteImages: loadsRemoteImages,
                searchHighlight: searchHighlight,
                verticalScrollOwnership: layout.verticalScrollOwnership
            )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityLabel("HTML email body")
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch bodyState {
            case .loading:
                loadingDots
            case .failed:
                Text("(body could not be loaded)")
                    .font(readingTextSize.font(base: 12).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
            case .loaded(let content):
                if content.isEmpty {
                    Text("(no message body)")
                        .font(readingTextSize.font(base: 12).italic())
                        .foregroundStyle(OhiaColors.textTertiary)
                } else {
                    bodyContentView(content)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(OhiaColors.textTertiary)
                    .frame(width: 3, height: 3)
                    .opacity(index == 1 ? 0.7 : 0.45)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Loading message body")
    }

    private func bodyContentView(_ content: LockReadoutBodyContent) -> some View {
        Group {
            if let attributedText = content.attributedText {
                Text(SearchMatchTextHighlighter.highlighted(attributedText, highlight: searchHighlight))
            } else {
                Text(SearchMatchTextHighlighter.highlighted(content.plainText, highlight: searchHighlight))
            }
        }
        .font(readingTextSize.font(base: 12.5))
        .lineSpacing(readingTextSize.spacing(2))
        .foregroundStyle(OhiaColors.textPrimary)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
