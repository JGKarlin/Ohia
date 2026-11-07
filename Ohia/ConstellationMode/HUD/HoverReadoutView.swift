// HoverReadoutView.swift
// The compact, transient popup shown when the cursor lands on a node in
// Constellation Mode. Tethered annotation chrome (accent left-border +
// dashed tether drawn by the parent) carrying orientation content:
// subject, sender / time / role, italic summary, and top tags.
//
// All content is built from a `HoverReadoutContext` value type — the
// view itself is pure presentation, so reads stay cheap on every cursor
// move.

import Foundation
import SwiftUI
import OhiaCore

public struct HoverReadoutView: View {
    public let context: HoverReadoutContext
    /// `true` when the popup sits to the LEFT of the hovered node. Flips the
    /// `annotationMark` row so the direction-label pill (where the yellow
    /// leader line lands) is on the trailing edge — the icon always faces
    /// the node.
    public let mirrored: Bool

    @Environment(\.readingTextSize) private var readingTextSize

    public init(
        context: HoverReadoutContext,
        mirrored: Bool = false
    ) {
        self.context = context
        self.mirrored = mirrored
    }

    public var body: some View {
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 5) {
            annotationMark
            popupBody
        }
        // Without `.fixedSize(vertical:)` the surrounding ZStack /
        // `.position()` modifier hands the popup unbounded vertical space
        // and the accent stripe Rectangle stretches to fill it, dragging
        // the surrounding rounded surface with it. Pinning vertical sizing
        // to the content size keeps the popup compact regardless of how
        // much room the host gives it.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Annotation mark
    //
    // Direction-label pill ([icon] [label]) at the popup's leading or trailing
    // edge depending on `mirrored`. The previous in-pane 18pt yellow dash was
    // retired when the parent overlay started drawing a full yellow leader line
    // from the hovered node to this pill's near edge.
    private var annotationMark: some View {
        HStack(spacing: 6) {
            if mirrored {
                Text(directionLabel)
                    .font(OhiaTypography.annotationBody)
                    .tracking(0.6)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Image(systemName: directionSymbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            } else {
                Image(systemName: directionSymbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Text(directionLabel)
                    .font(OhiaTypography.annotationBody)
                    .tracking(0.6)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
        }
    }

    // MARK: - Popup body
    //
    // Layout: a horizontal pair — accent stripe on the left, content
    // VStack on the right. Sizing is content-driven from the VStack
    // upward; the stripe stretches to whatever height the content
    // settles on. Background and rounded corners are applied once, on
    // the outer HStack, so the stripe's left edge meets the rounded
    // corner cleanly.
    private var popupBody: some View {
        let envelope = HoverPopupPlacement.emailEnvelope(for: readingTextSize)
        return HStack(spacing: 0) {
            Rectangle()
                .fill(OhiaColors.chipActiveBorder)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 0) {
                metaRow
                subjectLine
                if let summary = context.summary, !summary.isEmpty {
                    summaryLine(summary)
                } else if context.summaryIsLoading {
                    SummaryLoadingPlaceholderView(contentWidth: max(120, envelope.width - 28))
                        .padding(.top, 7)
                } else if let reason = context.summaryUnavailableReason, !reason.isEmpty {
                    summaryUnavailableLine(reason)
                }
                if hasTagRow {
                    hairline
                    tagRow
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(width: envelope.width - 2, alignment: .leading)
        }
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
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    // MARK: - Meta row (sender · time)
    private var metaRow: some View {
        HStack(spacing: 6) {
            if let account = context.account {
                accountMark(account)
                if displayFromName != nil || relativeTime != nil {
                    separatorDot
                }
            }
            if let display = displayFromName {
                Text(display)
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
            }
            if displayFromName != nil, relativeTime != nil {
                separatorDot
            }
            if let when = relativeTime {
                Text(when)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .tracking(0.1)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    private func accountMark(_ account: HoverAccountContext) -> some View {
        AccountGlyphImage(glyph: AccountIcon.style(forEmail: account.emailAddress).glyph, size: 10)
            .foregroundStyle(account.accountColor.swiftUIColor)
            .frame(width: 12, height: 12)
            .help("Account: \(account.resolvedDisplayName)")
            .accessibilityLabel(Text("Account \(account.resolvedDisplayName)"))
    }

    private var separatorDot: some View {
        Circle()
            .fill(OhiaColors.textDim)
            .frame(width: 3, height: 3)
    }

    // MARK: - Subject
    private var subjectLine: some View {
        Text(displaySubject)
            .font(readingTextSize.font(base: 14, weight: .semibold, maximumScale: 1.35))
            .foregroundStyle(context.subject.isEmpty ? OhiaColors.textTertiary : OhiaColors.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }

    // MARK: - Summary
    //
    // Generated summaries are rendered in full; the prompt controls length,
    // not the hover chrome.
    private func summaryLine(_ summary: String) -> some View {
        Text(summary)
            .font(readingTextSize.font(base: 12.5))
            .lineSpacing(readingTextSize.spacing(1.5))
            .foregroundStyle(OhiaColors.textSecondary)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private func summaryUnavailableLine(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(reason)
                .font(readingTextSize.font(base: 11.5))
                .foregroundStyle(OhiaColors.textTertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
        .accessibilityLabel(reason)
    }

    private var directionLabel: String {
        // When the hover is rendered inside a People-lens lock, the
        // hovered satellite sits on one of the 4 ring tiers — surface
        // the matching tier label so a Cc'd inbound message reads as
        // "received cc'd" rather than the generic "received". Outside
        // People focus the binary sent/received label still applies.
        if let tier = context.peopleRingTier {
            return tier.hoverDirectionLabel
        }
        return context.isSentByUser ? "sent" : "received"
    }

    private var directionSymbolName: String {
        if let tier = context.peopleRingTier {
            return tier.directionSymbolName
        }
        return context.isSentByUser ? "paperplane.fill" : "tray.and.arrow.down"
    }

    // MARK: - Tag row
    private var hasTagRow: Bool {
        context.summaryPurpose != nil
            || context.isActionable == true
            || context.requiresConfirmation == true
            || context.deadlineLabel != nil
            || !context.topTags.isEmpty
    }

    private var hasDescriptiveTags: Bool {
        context.summaryPurpose != nil
            || !context.topTags.isEmpty
            || context.deadlineLabel != nil
    }

    // The tag area is two stacked rows: the action state stands alone on the
    // top row so the obligation signal reads first, then Purpose,
    // keywords, and (when present) the extracted deadline wrap together on the
    // descriptive row below.
    private var tagRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Binary-obligation invariant (reply XOR confirmation): if a stale
            // snapshot ever carries both, a pending reply subsumes the
            // confirmation, matching MessageStatusDescriptor's collapse rule and
            // every other surface that renders this state.
            if context.isActionable == true {
                actionMark(.pendingReply)
            } else if context.requiresConfirmation == true {
                actionMark(.needsConfirmation)
            }
            if hasDescriptiveTags {
                WrappingChipStack(horizontalSpacing: 5, verticalSpacing: 5) {
                    if let purpose = context.summaryPurpose {
                        tagChip(label: purpose.displayLabel, kind: .purpose)
                    }
                    ForEach(context.topTags, id: \.self) { tag in
                        tagChip(label: tag.lowercased(), kind: .neutral)
                    }
                    if let deadline = context.deadlineLabel {
                        tagChip(label: deadline, kind: .warn)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Triage obligation signal — rendered as a bare tinted icon + label
    /// (no pill), reusing the Front Page / Projects color, name, and glyph so a
    /// given message state reads the same in every surface. The label weight
    /// tracks the surrounding chip text; only the icon and tint are borrowed
    /// from the canonical mark. Distinct from the boxed Purpose / topic chips
    /// so it reads as an action signal, not another tag.
    private func actionMark(_ action: MessageStatusActionState) -> some View {
        HStack(spacing: 4) {
            MessageStatusActionGlyph(action: action, size: 13)
            Text(action.label)
                .font(OhiaTypography.legendLine)
                .tracking(0.1)
                .foregroundStyle(action.tint)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.label)
    }

    private enum TagKind { case purpose, neutral, warn }

    private func tagChip(label: String, kind: TagKind) -> some View {
        let bg: Color
        let fg: Color
        let stroke: Color
        let dotColor: Color
        switch kind {
        case .purpose:
            bg = Color(NSColor.controlAccentColor).opacity(0.10)
            fg = OhiaColors.textSecondary
            stroke = Color(NSColor.controlAccentColor).opacity(0.40)
            dotColor = Color(NSColor.controlAccentColor).opacity(0.85)
        case .neutral:
            bg = .clear
            fg = OhiaColors.textSecondary
            stroke = OhiaColors.glassBorder
            dotColor = .clear
        case .warn:
            bg = OhiaColors.accentOrange.opacity(0.10)
            fg = OhiaColors.accentOrange
            stroke = OhiaColors.accentOrange.opacity(0.45)
            dotColor = OhiaColors.accentOrange
        }
        return HStack(spacing: 5) {
            if dotColor != .clear {
                Circle().fill(dotColor).frame(width: 5, height: 5)
            }
            Text(label)
                .font(OhiaTypography.legendLine)
                .tracking(0.1)
                .foregroundStyle(fg)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(bg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        }
    }

    // MARK: - Hairline divider
    private var hairline: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(height: 1)
            .padding(.vertical, 9)
            .padding(.horizontal, -13)
    }

    // MARK: - Derived display strings
    private var displayFromName: String? {
        if let name = context.fromName, !name.isEmpty { return name }
        if !context.fromAddress.isEmpty { return context.fromAddress }
        return nil
    }

    private var displaySubject: String {
        context.subject.isEmpty ? "(no subject)" : context.subject
    }

    /// Compact relative-time string: "now" / "12m ago" / "3h ago" /
    /// "2d ago" / "Apr 14" / "Apr 14, 2025". Computed on every body
    /// invocation rather than stored — the popup re-renders on each
    /// hover anyway.
    private var relativeTime: String? {
        guard let when = context.receivedAt else { return nil }
        return Self.relativeTimeLabel(for: when)
    }

    @MainActor
    static func relativeTimeLabel(for when: Date, now: Date = Date.now, calendar: Calendar = .current) -> String {
        let interval = now.timeIntervalSince(when)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        if interval < 86_400 * 7 { return "\(Int(interval / 86_400))d ago" }
        if interval < 86_400 * 30 { return "\(Int(interval / (86_400 * 7)))w ago" }
        let formatter = calendar.isDate(when, equalTo: now, toGranularity: .year)
            ? Self.shortDateFormatter
            : Self.longDateFormatter
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: when)
    }

    /// `DateFormatter` is expensive to allocate; the popup re-renders on
    /// every cursor move while a node is hovered, so we hold one of each
    /// (same-year vs. cross-year) and re-tag the calendar/timeZone in
    /// `relativeTimeLabel(for:)`. The "y" pattern (not "yyyy") is required
    /// for correct localization of the year value. Both formatters are
    /// MainActor-isolated because the hover popup body and the test suite
    /// are MainActor-bound, so this never observes concurrent mutation.
    @MainActor
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    @MainActor
    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, y"
        return f
    }()
}
