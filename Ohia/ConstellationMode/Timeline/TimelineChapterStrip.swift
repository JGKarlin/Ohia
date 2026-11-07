import SwiftUI
import OhiaCore

/// Chapter ribbon shown directly below the ruler when conversation mode is
/// ON. Renders per-chapter truncated subject labels at each chapter's
/// start x-position. The chapter-skip ⏮ / ⏭ controls live in
/// `TimelineRightControlColumn` now — they used to duplicate at the
/// leading edge of this strip, but that was redundant once the right
/// column landed.
///
/// Click a label → playhead snaps to that chapter's first message.
/// Hover a label → a custom popover (matching the citation / annotation
/// hover-card grammar elsewhere in the app — accent stripe, gradient
/// surface, hairline border) opens instantly with subject, from, to,
/// date, and message count. The system NSToolTip path via `.help()`
/// produces both the wrong visual register and a multi-second delay,
/// so we drive the popover ourselves via `.onHover` + `.popover`.
struct TimelineChapterStrip: View {

    @Bindable var workspace: TimelineWorkspaceState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let snapshot = workspace.currentSnapshot {
                    ForEach(snapshot.chapters, id: \.id) { chapter in
                        ChapterLabel(
                            chapter: chapter,
                            snapshot: snapshot,
                            isActive: workspace.activeChapter?.id == chapter.id,
                            onTap: {
                                if let date = chapter.messageIDs.first
                                    .flatMap({ workspace.currentSnapshot?.messageDateLookup[$0] }) {
                                    workspace.setPlayhead(date)
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 22)
        .background(OhiaColors.glassPanel.opacity(0.5))
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }
}

private struct ChapterLabel: View {

    let chapter: TimelineChapter
    let snapshot: TimelineLayoutSnapshot
    let isActive: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(chapter.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .frame(maxWidth: isActive ? 220 : 80, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                // The active chapter illuminates in `ohiaYellow` to
                // match the multitrack's chip-active treatment —
                // tells the user at a glance which thread the
                // playhead is currently inside as they advance with
                // ⌘← / ⌘→ or click between chapters.
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive
                          ? OhiaColors.ohiaYellow.opacity(0.32)
                          : OhiaColors.chipRestBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isActive ? OhiaColors.ohiaYellow : OhiaColors.chipRestBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .foregroundStyle(isActive ? OhiaColors.ohiaYellow : OhiaColors.textPrimary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hovering = isHovering
        }
        // SwiftUI's `.popover` opens immediately on the `isPresented`
        // edge — no NSToolTip multi-second debounce — and the content
        // inside is fully custom, so we get the gradient / accent /
        // hairline grammar shared by the citation, annotation, and
        // locked-overlay hover cards.
        .popover(isPresented: $hovering, arrowEdge: .top) {
            ChapterHoverPopover(chapter: chapter, snapshot: snapshot, isActive: isActive)
        }
    }
}

private struct ChapterHoverPopover: View {

    let chapter: TimelineChapter
    let snapshot: TimelineLayoutSnapshot
    let isActive: Bool

    private var tint: Color { isActive ? OhiaColors.ohiaYellow : OhiaColors.chipActiveBorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(OhiaColors.glassBorder)
            VStack(alignment: .leading, spacing: 5) {
                row(label: "subject", value: chapter.title.isEmpty ? "(no subject)" : chapter.title, lineLimit: 2)
                if let sender = sendersLine {
                    row(label: "from", value: sender, lineLimit: 2)
                }
                if let recipient = recipientsLine {
                    row(label: "to", value: recipient, lineLimit: 2)
                }
                row(label: "date", value: dateLine, lineLimit: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320, alignment: .topLeading)
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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        // `.transient` popovers automatically pass mouse events back
        // to the anchor; sized as a hover card, this acts as a fast,
        // non-interactive tooltip.
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text("thread")
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.4)
                .foregroundStyle(tint)
            Spacer(minLength: 4)
            Text("\(messages.count) message\(messages.count == 1 ? "" : "s")")
                .font(OhiaTypography.telemetryEmphasis)
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textSecondary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(label: String, value: String, lineLimit: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(OhiaTypography.telemetryLabel)
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(OhiaTypography.telemetryValue)
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Derived content

    private var messages: [TimelineLayoutSnapshot.MessageMeta] {
        chapter.messageIDs.compactMap { snapshot.messageMetadata[$0] }
    }

    private var sendersLine: String? {
        var seen = Set<String>()
        var out: [String] = []
        for meta in messages {
            let label: String
            if !meta.fromName.isEmpty, !meta.fromAddress.isEmpty {
                label = "\(meta.fromName) <\(meta.fromAddress)>"
            } else if !meta.fromName.isEmpty {
                label = meta.fromName
            } else if !meta.fromAddress.isEmpty {
                label = meta.fromAddress
            } else {
                continue
            }
            if seen.insert(label).inserted { out.append(label) }
        }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }

    private var recipientsLine: String? {
        var seen = Set<String>()
        var out: [String] = []
        for meta in messages {
            for recipient in meta.recipients {
                let label: String
                if !recipient.displayName.isEmpty, !recipient.email.isEmpty {
                    label = "\(recipient.displayName) <\(recipient.email)>"
                } else if !recipient.displayName.isEmpty {
                    label = recipient.displayName
                } else if !recipient.email.isEmpty {
                    label = recipient.email
                } else {
                    continue
                }
                if seen.insert(label).inserted { out.append(label) }
            }
        }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }

    private var dateLine: String {
        let startStr = Self.dateFormatter.string(from: chapter.start)
        // Multi-message threads always show the full span from first to
        // last message, even when both timestamps land in the same
        // minute. Single-message (orphan) chapters render one date.
        if messages.count <= 1 {
            return startStr
        }
        return "\(startStr) → \(Self.dateFormatter.string(from: chapter.end))"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
