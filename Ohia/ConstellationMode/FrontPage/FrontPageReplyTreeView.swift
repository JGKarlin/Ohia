import Foundation
import SwiftUI
import OhiaML

/// The focused article's conversation, rendered as a newspaper-style thread
/// section beneath the body. Nodes arrive in the composer's canonical
/// oldest-first tree order; this view reverses them so the newest thread
/// message sits directly beneath the focused email.
struct FrontPageReplyTreeView: View {
    let nodes: [FrontPageReplyNode]
    var searchHighlight: SearchMatchHighlight? = nil

    /// Per-nesting-level indentation. Each level also draws a left thread rule,
    /// so depth reads as both an indent and a tethering bar (the reference's
    /// blue side bars). Capped so a deep chain never runs off the right edge.
    private let indentStep: CGFloat = 20
    private let maxIndentDepth = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                ForEach(displayNodes) { node in
                    FrontPageReplyComment(node: node, searchHighlight: searchHighlight)
                        .padding(.leading, CGFloat(min(node.depth, maxIndentDepth)) * indentStep)
                }
            }
            .padding(.top, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
            Text(headerLabel)
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(OhiaColors.textSecondary)
        }
    }

    private var headerLabel: String {
        nodes.count == 1 ? "1 THREAD MESSAGE" : "\(nodes.count) THREAD MESSAGES"
    }

    private var displayNodes: [FrontPageReplyNode] {
        Array(nodes.reversed())
    }
}

/// One message in the thread: a quiet text byline (`Name — relative time`) over
/// the message's own content (its quotes already stripped), shown in full.
private struct FrontPageReplyComment: View {
    let node: FrontPageReplyNode
    let searchHighlight: SearchMatchHighlight?

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The thread rule — a thin tethering bar on the comment's left edge.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(railColor)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(SearchMatchTextHighlighter.highlighted(bylineText, highlight: nodeSearchHighlight))
                    .font(readingTextSize.font(base: 12, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(node.isSentByUser ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                    .lineLimit(1)
                if node.bodyText.isEmpty == false {
                    FrontPageLinkedPlainTextView(
                        text: node.bodyText,
                        searchHighlight: nodeSearchHighlight,
                        font: .systemFont(ofSize: readingTextSize.pointSize(base: 14)),
                        lineSpacing: readingTextSize.spacing(1.5),
                        paragraphSpacing: readingTextSize.spacing(6)
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
    }

    private var railColor: Color {
        node.isSentByUser
            ? OhiaColors.chipActiveForeground.opacity(0.45)
            : OhiaColors.glassBorder
    }

    private var nodeSearchHighlight: SearchMatchHighlight? {
        guard let id = UUID(uuidString: node.id) else { return nil }
        return searchHighlight?.scoped(to: id)
    }

    private var bylineText: String {
        let name = node.author ?? "Earlier message"
        guard let time = timeText else { return name }
        return "\(name) — \(time)"
    }

    private var timeText: String? {
        if let date = node.date {
            return FrontPageRelativeDate.string(for: date, relativeTo: .now)
        }
        if let raw = node.rawDateText?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.isEmpty == false {
            return raw
        }
        return nil
    }
}
