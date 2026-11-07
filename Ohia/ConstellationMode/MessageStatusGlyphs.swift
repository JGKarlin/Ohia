import SwiftUI
import OhiaML

/// Shared message-status palette for Constellation-adjacent surfaces.
/// Projects and Front Page both render reply, confirmation, and deadline
/// signals through these tokens so the same message state carries the same
/// color in each lens.
enum MessageStatusColors {
    static let pendingReply: Color = OhiaColors.chipActiveForeground
    static let confirmation: Color = OhiaColors.confirmationSignal
    /// A satisfied reply obligation. Rendered in ʻōhiʻa green (the "done"
    /// hue) so the reply arrow reads as resolved and never mimics the pending
    /// (yellow) `pendingReply` state.
    static let replied: Color = OhiaColors.ohiaGreen
    static let resolved: Color = OhiaColors.ohiaGreen
    static let deadline: Color = OhiaColors.ohiaRed
    static let flagged: Color = OhiaColors.chipActiveForeground

    static func color(for kind: ProjectOpenObligation.Kind) -> Color {
        switch kind {
        case .pendingReply: return pendingReply
        case .confirmation: return confirmation
        }
    }

    /// When a message carries both kinds, pending-reply wins so the at-rest
    /// signal mirrors the pip column's pending-before-confirmation ordering.
    static func dominantColor(for kinds: Set<ProjectOpenObligation.Kind>) -> Color? {
        if kinds.contains(.pendingReply) { return pendingReply }
        if kinds.contains(.confirmation) { return confirmation }
        return nil
    }

    /// Resolve the SwiftUI color for a pure-value tint produced by
    /// `ProjectsHoverVerb`.
    static func color(for tint: ProjectsHoverVerb.Tint) -> Color {
        switch tint {
        case .pendingReply: return pendingReply
        case .confirmation: return confirmation
        case .deadline: return deadline
        case .neutral: return OhiaColors.textSecondary
        }
    }
}

/// Compatibility alias for existing Projects files. New shared surfaces should
/// use `MessageStatusColors` directly.
typealias ObligationKindColor = MessageStatusColors

enum MessageReadStateMarkStyle {
    static let unreadFill: Color = OhiaColors.chipActiveForeground
    static let unreadStroke: Color = OhiaColors.chipActiveBorder
    static let unreadGloss: Color = OhiaColors.chipActiveForeground
    static let readStroke: Color = OhiaColors.textSecondary.opacity(0.86)
    static let readHoverStroke: Color = OhiaColors.textPrimary.opacity(0.92)

    static func fillColor(isRead: Bool) -> Color? {
        isRead ? nil : unreadFill
    }

    static func strokeColor(isRead: Bool, isHovered: Bool = false) -> Color {
        if isRead {
            return isHovered ? readHoverStroke : readStroke
        }
        return isHovered ? unreadFill : unreadStroke
    }

    static func strokeWidth(isRead: Bool, isHovered: Bool = false) -> CGFloat {
        isRead ? (isHovered ? 2 : 1.35) : (isHovered ? 2 : 1.2)
    }
}

enum MessageStatusSymbols {
    static let pendingReply = "arrowshape.turn.up.left.fill"
    static let confirmation = "eye.fill"
    static let confirmed = "checkmark.seal.fill"
    static let resolved = "checkmark.circle.fill"
    static let deadline = "calendar.badge.clock"
    static let flagged = "flag.fill"
    static let revived = "arrow.triangle.2.circlepath"
    static let sharedEvidence = "point.3.connected.trianglepath.dotted"

    static func obligationSymbol(needsReply: Bool, needsConfirmation: Bool) -> String? {
        if needsReply { return pendingReply }
        if needsConfirmation { return confirmation }
        return nil
    }

    static func statusSymbol(
        needsReply: Bool,
        needsConfirmation: Bool,
        isReplied: Bool,
        isConfirmed: Bool
    ) -> String? {
        if needsReply { return pendingReply }
        if needsConfirmation { return confirmation }
        if isReplied { return pendingReply }
        if isConfirmed { return confirmed }
        return nil
    }
}

/// Reply and confirmation are mutually exclusive: a message either needs a
/// reply or needs confirmation, never both. The binary invariant is enforced
/// upstream by `TriageVerdict.enforcingBinaryObligation()` and the attention
/// resolver, so there is deliberately no combined case here.
enum MessageStatusObligation: Equatable, Sendable {
    case none
    case pendingReply
    case confirmation

    var needsReply: Bool {
        self == .pendingReply
    }

    var needsConfirmation: Bool {
        self == .confirmation
    }
}

enum MessageStatusActionState: String, Identifiable, Sendable {
    case pendingReply
    case needsConfirmation
    case replied
    case confirmed
    case resolved
    case deadline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pendingReply: return "Needs reply"
        case .needsConfirmation: return "Needs confirmation"
        case .replied: return "Replied"
        case .confirmed: return "Confirmed"
        case .resolved: return "Resolved"
        case .deadline: return "Deadline"
        }
    }

    var symbolName: String {
        switch self {
        case .pendingReply, .replied:
            return MessageStatusSymbols.pendingReply
        case .needsConfirmation:
            return MessageStatusSymbols.confirmation
        case .confirmed:
            return MessageStatusSymbols.confirmed
        case .resolved:
            return MessageStatusSymbols.resolved
        case .deadline:
            return MessageStatusSymbols.deadline
        }
    }

    var tint: Color {
        switch self {
        case .pendingReply:
            return MessageStatusColors.pendingReply
        case .replied:
            return MessageStatusColors.replied
        case .needsConfirmation, .confirmed:
            return MessageStatusColors.confirmation
        case .resolved:
            return MessageStatusColors.resolved
        case .deadline:
            return MessageStatusColors.deadline
        }
    }
}

struct MessageStatusDescriptor: Equatable, Sendable {
    let isSentByUser: Bool
    let isRead: Bool
    let isReplied: Bool
    let isConfirmed: Bool
    let isResolved: Bool
    let obligation: MessageStatusObligation
    let hasDeadline: Bool
    let deadlineText: String?
    let isFlagged: Bool
    let isRevivedAfterInactiveGap: Bool
    let sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
    let paintedSharedEvidenceKinds: Set<MessageSharedEvidenceKind>

    init(
        isSentByUser: Bool,
        isRead: Bool,
        isReplied: Bool = false,
        isConfirmed: Bool = false,
        isResolved: Bool = false,
        needsReply: Bool,
        needsConfirmation: Bool,
        hasDeadline: Bool = false,
        deadlineText: String? = nil,
        isFlagged: Bool = false,
        isRevivedAfterInactiveGap: Bool = false,
        sharedEvidenceKinds: Set<MessageSharedEvidenceKind> = [],
        paintedSharedEvidenceKinds: Set<MessageSharedEvidenceKind>? = nil
    ) {
        self.isSentByUser = isSentByUser
        self.isRead = isRead
        self.isReplied = isReplied
        self.isConfirmed = isConfirmed
        self.isResolved = isResolved
        self.hasDeadline = hasDeadline
        let trimmedDeadline = deadlineText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deadlineText = hasDeadline && trimmedDeadline?.isEmpty == false ? trimmedDeadline : nil
        self.isFlagged = isFlagged
        self.isRevivedAfterInactiveGap = isRevivedAfterInactiveGap
        self.sharedEvidenceKinds = sharedEvidenceKinds
        self.paintedSharedEvidenceKinds = paintedSharedEvidenceKinds
            ?? MessageStatusSignalIndex.paintedSharedEvidenceKinds(sharedEvidenceKinds)
        switch (needsReply, needsConfirmation && !isReplied) {
        case (true, true):
            // Defensive backstop: the binary invariant is enforced upstream,
            // so both should never arrive together. If they do, a pending
            // reply subsumes the confirmation, so reply wins.
            self.obligation = .pendingReply
        case (true, false):
            self.obligation = .pendingReply
        case (false, true):
            self.obligation = .confirmation
        case (false, false):
            self.obligation = .none
        }
    }

    init(mark: ProjectMessageMark, hasDeadline: Bool = false, deadlineText: String? = nil) {
        self.init(
            isSentByUser: mark.isSentByUser,
            isRead: mark.isRead,
            isReplied: mark.isReplied,
            isConfirmed: mark.isConfirmed,
            isResolved: mark.isResolvedByUser,
            needsReply: mark.obligationKinds.contains(.pendingReply),
            needsConfirmation: mark.obligationKinds.contains(.confirmation),
            hasDeadline: hasDeadline || mark.hasDeadline,
            deadlineText: deadlineText ?? mark.deadlineText,
            isFlagged: mark.isFlagged,
            isRevivedAfterInactiveGap: mark.isRevivedAfterInactiveGap,
            sharedEvidenceKinds: mark.sharedEvidenceKinds
        )
    }

    static let receivedMail = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: false,
        needsReply: false,
        needsConfirmation: false
    )

    static let sentMail = MessageStatusDescriptor(
        isSentByUser: true,
        isRead: true,
        needsReply: false,
        needsConfirmation: false
    )

    static let pendingReply = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: false,
        needsReply: true,
        needsConfirmation: false
    )

    static let confirmation = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: false,
        needsReply: false,
        needsConfirmation: true
    )

    static let replied = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: true,
        isReplied: true,
        needsReply: false,
        needsConfirmation: false
    )

    static let confirmed = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: true,
        isConfirmed: true,
        needsReply: false,
        needsConfirmation: false
    )

    static let flagged = MessageStatusDescriptor(
        isSentByUser: false,
        isRead: true,
        needsReply: false,
        needsConfirmation: false,
        isFlagged: true
    )

    var needsReply: Bool { obligation.needsReply }
    var needsConfirmation: Bool { obligation.needsConfirmation }
    private var recipientSharedEvidenceKinds: Set<MessageSharedEvidenceKind> {
        Set(sharedEvidenceKinds.filter { $0 == .ccOrBcc })
    }

    var hasSharedEvidence: Bool { recipientSharedEvidenceKinds.isEmpty == false }
    var paintsSharedEvidenceGlyph: Bool { paintedSharedEvidenceKinds.isEmpty == false }

    var readStateLabel: String {
        if isSentByUser { return "Sent" }
        return isRead ? "Read" : "Unread"
    }

    var deadlineGloss: String {
        guard let deadlineText else { return MessageStatusActionState.deadline.label }
        return "\(MessageStatusActionState.deadline.label) (\(deadlineText))"
    }

    var actionStates: [MessageStatusActionState] {
        var states: [MessageStatusActionState] = []
        if needsReply {
            states.append(.pendingReply)
        } else if isReplied {
            states.append(.replied)
        }
        if needsConfirmation {
            states.append(.needsConfirmation)
        } else if isConfirmed {
            states.append(.confirmed)
        }
        if isResolved {
            states.append(.resolved)
        }
        if hasDeadline {
            states.append(.deadline)
        }
        return states
    }

    var textGloss: String {
        var parts = [readStateLabel]
        parts.append(contentsOf: actionStates.map(actionLabel))
        if isFlagged { parts.append("Flagged") }
        if isRevivedAfterInactiveGap { parts.append("Revived") }
        if hasSharedEvidence { parts.append(sharedEvidenceGloss) }
        return parts.joined(separator: " · ")
    }

    func actionLabel(_ action: MessageStatusActionState) -> String {
        action == .deadline ? deadlineGloss : action.label
    }

    /// The spoken status summary. `includingDeadline` is `false` for surfaces
    /// that suppress the in-line deadline (Front Page card / Timeline pass
    /// `showsDeadlineSignal: false`) and render a separate trailing deadline
    /// mark that carries the deadline announcement itself — dropping the clause
    /// here keeps VoiceOver from announcing the deadline twice.
    func accessibilityLabel(includingDeadline: Bool = true) -> String {
        let direction = isSentByUser ? "sent mail" : "received mail"
        var parts: [String] = [direction, readStateLabel.lowercased()]
        // Reply and confirmation are mutually exclusive (binary invariant).
        if needsReply {
            parts.append("pending reply")
        } else if needsConfirmation {
            parts.append("confirmation")
        }
        if isReplied { parts.append("replied") }
        if isConfirmed { parts.append("confirmed") }
        if isResolved { parts.append("resolved") }
        if includingDeadline, hasDeadline {
            if let deadlineText {
                parts.append("concrete deadline: \(deadlineText)")
            } else {
                parts.append("concrete deadline")
            }
        }
        if isFlagged { parts.append("flagged") }
        if isRevivedAfterInactiveGap { parts.append("revived after an inactive gap") }
        if hasSharedEvidence { parts.append(sharedEvidenceAccessibilityText) }
        return parts.joined(separator: ", ")
    }

    var sharedEvidenceGloss: String {
        let labels = recipientSharedEvidenceKinds.sortedForDisplay.map(\.label)
        guard labels.isEmpty == false else { return "Shared evidence" }
        return "Shared: \(labels.joined(separator: ", "))"
    }

    private var sharedEvidenceAccessibilityText: String {
        let labels = recipientSharedEvidenceKinds.sortedForDisplay.map(\.label)
        guard labels.isEmpty == false else { return "shared evidence" }
        return "shared evidence: \(labels.joined(separator: ", "))"
    }
}

extension MessageStatusDescriptor {
    static func constellationRow(
        _ row: MessageFilterRow,
        messageID: UUID? = nil,
        statusSignals: MessageStatusSignalIndex = .empty,
        sharedEvidenceDensity: ProjectsDensityTier = .full,
        includeAmbientSharedEvidence: Bool = false
    ) -> MessageStatusDescriptor {
        let directSharedRecipientEvidence = Set(row.recipientAddresses).subtracting(row.toAddresses).isEmpty == false
        var sharedEvidenceKinds = messageID.map { statusSignals.sharedEvidenceKinds(for: $0) } ?? []
        if directSharedRecipientEvidence {
            sharedEvidenceKinds.insert(.ccOrBcc)
        }
        let paintedSharedEvidenceKinds = MessageStatusSignalIndex.paintedSharedEvidenceKinds(
            sharedEvidenceKinds,
            density: sharedEvidenceDensity,
            includeAmbient: includeAmbientSharedEvidence
        )
        return MessageStatusDescriptor(
            isSentByUser: row.isSentByUser,
            isRead: row.isRead,
            isReplied: row.isReplied,
            isConfirmed: row.isConfirmed,
            isResolved: row.isResolved,
            needsReply: row.isActionable == true,
            needsConfirmation: row.requiresConfirmation == true,
            hasDeadline: row.dimensions?.deadlines.isEmpty == false,
            deadlineText: row.dimensions?.primaryDeadlineDisplayText,
            isFlagged: row.flagged,
            isRevivedAfterInactiveGap: messageID.map { statusSignals.isRevivedAfterInactiveGap($0) } ?? false,
            sharedEvidenceKinds: sharedEvidenceKinds,
            paintedSharedEvidenceKinds: paintedSharedEvidenceKinds
        )
    }
}

private extension Set where Element == MessageSharedEvidenceKind {
    var sortedForDisplay: [MessageSharedEvidenceKind] {
        sorted { lhs, rhs in
            Self.displayRank(lhs) < Self.displayRank(rhs)
        }
    }

    static func displayRank(_ kind: MessageSharedEvidenceKind) -> Int {
        switch kind {
        case .ccOrBcc: return 0
        case .sameMessage: return 1
        case .replyReference: return 2
        case .responseChain: return 3
        case .sameThread: return 4
        case .sharedCorrespondent: return 5
        }
    }
}

struct MessageStatusMark: View {
    let descriptor: MessageStatusDescriptor
    var size: CGFloat = 18
    var showsDeadlineSignal = true
    var showsTextGloss = false
    var showsAmbientSharedEvidence = false
    var glossFont: Font = .system(size: 10, weight: .semibold)
    /// Active action-response gesture for this message, when one is in flight.
    /// `nil` (the default) renders the mark exactly as before, so Projects and
    /// Timeline are unaffected; the Front Page passes a live gesture so the
    /// obligation / flag glyph animates in place while the mutation lands.
    var gesture: MessageStatusGesture? = nil

    var body: some View {
        glossContainer
            .help(descriptor.accessibilityLabel(includingDeadline: showsDeadlineSignal))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(descriptor.accessibilityLabel(includingDeadline: showsDeadlineSignal))
    }

    /// Gloss mode lays the segments out through `StatusGlossLayout`, which keeps
    /// each chip's label while the row fits and drops trailing labels to
    /// icon-only when space runs short — so a cramped grid card shows clean
    /// icons instead of a truncated "Deadline…". Icon-only mode keeps the
    /// content-sized `HStack`.
    @ViewBuilder
    private var glossContainer: some View {
        let spacing = max(4, size * 0.28)
        if showsTextGloss {
            StatusGlossLayout(spacing: spacing) {
                segments
            }
        } else {
            HStack(spacing: spacing) {
                segments
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var segments: some View {
        statusSegment(
            label: descriptor.readStateLabel,
            tint: readStateGlossColor
        ) {
            MessageReadStateDot(descriptor: descriptor, size: size)
        }
        if displaysSharedEvidenceGlyph {
            statusSegment(label: "Shared", tint: OhiaColors.chipActiveForeground) {
                MessageStatusSharedEvidenceGlyph(size: size)
            }
        }
        ForEach(displayedActionStates) { action in
            statusSegment(label: descriptor.actionLabel(action), tint: action.tint) {
                GestureObligationGlyph(
                    action: action,
                    gesture: gesture?.action.targetObligation == action ? gesture : nil,
                    size: size
                )
            }
        }
        if showsFlagGlyph {
            flagSegment
        }
        if descriptor.isRevivedAfterInactiveGap {
            statusSegment(label: "Revived", tint: OhiaColors.chipActiveForeground) {
                MessageStatusRevivedGlyph(size: size)
            }
        }
    }

    private var displayedActionStates: [MessageStatusActionState] {
        let base = showsDeadlineSignal
            ? descriptor.actionStates
            : descriptor.actionStates.filter { $0 != .deadline }
        // During an obligation gesture, optimistically show the action's target
        // obligation glyph (so a "done" action reads as done from the first
        // frame); keep any deadline glyph alongside it.
        guard let target = gesture?.action.targetObligation else { return base }
        return [target] + base.filter { $0 == .deadline }
    }

    /// The active gesture only when it drives the flag glyph.
    private var flagGesture: MessageStatusGesture? {
        guard let gesture, gesture.action.isFlag else { return nil }
        return gesture
    }

    /// Show the flag glyph when the message is flagged, and throughout any flag
    /// gesture. The raise wave plays over the already-true flag; the strike must
    /// keep rendering the glyph to animate it away even though the snapshot has
    /// optimistically cleared the flag — so a live flag gesture forces the glyph
    /// for its (brief, floor-bounded) duration regardless of direction.
    private var showsFlagGlyph: Bool {
        if descriptor.isFlagged { return true }
        return flagGesture != nil
    }

    /// The flag chip (icon + "Flagged" gloss). The gesture animates only the
    /// icon, so on a strike (unflag) the whole chip is faded out in lockstep with
    /// the icon's bottom-up erase — otherwise the label would sit static and
    /// linger after the icon is pulled down. Icon and label leave together.
    @ViewBuilder
    private var flagSegment: some View {
        let chip = statusSegment(label: "Flagged", tint: MessageStatusColors.flagged) {
            GestureFlagGlyph(gesture: flagGesture, size: size)
        }
        if let flagGesture, case .flag(let raising) = flagGesture.action, !raising {
            TimelineView(.animation) { timeline in
                chip.opacity(Self.strikeChipOpacity(flagGesture.phase(now: timeline.date)))
            }
        } else {
            chip
        }
    }

    /// Fades the flag chip in lockstep with the strike's bottom-up erase (shares
    /// the easeOut spine of `messageStatusFlagMotion`), reaching zero exactly as
    /// the icon finishes coming down the flagpole.
    private static func strikeChipOpacity(_ phase: MessageStatusGesturePhase) -> Double {
        1 - messageStatusEaseOut(min(1, max(0, phase.elapsed / phase.floor)))
    }

    private var displaysSharedEvidenceGlyph: Bool {
        descriptor.paintsSharedEvidenceGlyph
            || (showsAmbientSharedEvidence && descriptor.hasSharedEvidence)
    }

    private var readStateGlossColor: Color {
        if !descriptor.isSentByUser && !descriptor.isRead {
            return MessageReadStateMarkStyle.unreadGloss
        }
        return OhiaColors.textSecondary
    }

    @ViewBuilder
    private func statusSegment<Icon: View>(
        label: String,
        tint: Color,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        if showsTextGloss {
            // Prefer the icon + full label; fall back to the bare icon when the
            // layout hands this segment less than its natural width. The label is
            // `.fixedSize()` so it never truncates — it is shown in full or not at
            // all. `StatusGlossLayout` decides which by the width it proposes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: max(3, size * 0.2)) {
                    icon()
                    Text(label)
                        .font(glossFont)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                }
                icon()
            }
        } else {
            icon()
        }
    }
}

/// Standalone deadline segment, styled to match `MessageStatusMark`'s gloss
/// segment (calendar glyph + red "Deadline (…)" label). Front Page and Timeline
/// render this *after* the category chip so the long, variable-width deadline
/// trails the entire header line, while the shared status mark suppresses its
/// own in-line deadline via `showsDeadlineSignal: false`. Renders nothing when
/// the message carries no deadline, and — like the in-line segment — sheds its
/// label to the bare calendar glyph when the row runs out of horizontal room.
struct MessageStatusDeadlineMark: View {
    let descriptor: MessageStatusDescriptor
    var size: CGFloat = 13
    var glossFont: Font = .system(size: 10, weight: .semibold)

    var body: some View {
        if descriptor.hasDeadline {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: max(3, size * 0.2)) {
                    glyph
                    Text(descriptor.actionLabel(.deadline))
                        .font(glossFont)
                        .foregroundStyle(MessageStatusActionState.deadline.tint)
                        .lineLimit(1)
                        .fixedSize()
                }
                glyph
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(descriptor.actionLabel(.deadline))
        }
    }

    private var glyph: some View {
        MessageStatusActionGlyph(action: .deadline, size: size)
    }
}

/// Lays status-gloss segments out left to right, handing each its full
/// (icon + label) width while the row fits and collapsing the trailing
/// segments to their compact (icon-only) width when space runs short — never
/// truncating a label. Each segment is a `ViewThatFits` that renders its label
/// only when given at least its full width, so the proposal this layout makes
/// per segment decides label-vs-icon. When the proposed width is unspecified
/// (a content-sized context) every segment gets its full label, preserving the
/// prior behaviour; only a width-constrained row (e.g. a narrow grid card)
/// sheds labels.
struct StatusGlossLayout: Layout {
    var spacing: CGFloat

    struct Cache {
        var fullSizes: [CGSize]?
        var compactSizes: [CGSize]?
        var compactHeight: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Labels, glyphs, font metrics and environment changes must all be
        // measured again. Width proposals alone can reuse these measurements.
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        resolve(availableWidth: proposal.width, height: proposal.height, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let plan = resolve(availableWidth: bounds.width, height: proposal.height, subviews: subviews, cache: &cache)
        var x = bounds.minX
        for index in subviews.indices {
            let width = plan.widths[index]
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: plan.size.height)
            )
            x += width + spacing
        }
    }

    private struct Plan {
        var widths: [CGFloat]
        var size: CGSize
    }

    private func resolve(
        availableWidth: CGFloat?, height: CGFloat?, subviews: Subviews, cache: inout Cache
    ) -> Plan {
        guard !subviews.isEmpty else { return Plan(widths: [], size: .zero) }

        if cache.fullSizes == nil {
            cache.fullSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        }
        // Compact measurements depend on height, but not on the row's width.
        // Keep only the latest height so resize proposals cannot grow the cache.
        if cache.compactSizes == nil || cache.compactHeight != height {
            cache.compactSizes = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: 0, height: height))
            }
            cache.compactHeight = height
        }
        let fullSizes = cache.fullSizes ?? []
        let compactSizes = cache.compactSizes ?? []
        let widths = Self.resolvedSegmentWidths(
            full: fullSizes.map(\.width),
            compact: compactSizes.map(\.width),
            spacing: spacing,
            // No width constraint (content-sized host) → every segment keeps its label.
            available: availableWidth ?? .infinity
        )
        let height = zip(fullSizes, compactSizes)
            .map { max($0.height, $1.height) }
            .max() ?? 0
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(subviews.count - 1)
        return Plan(widths: widths, size: CGSize(width: totalWidth, height: height))
    }

    /// Greedy left-to-right label fitting, factored out as a pure function so the
    /// label-shedding rule is unit-testable without a view host. Every segment
    /// starts at its `compact` (icon-only) width; segments are upgraded to their
    /// `full` (icon + label) width from the leading edge while the row still fits
    /// `available`, stopping at the first that would overflow so the labelled
    /// chips stay contiguous on the left. Returns the chosen width per segment.
    ///
    /// `tolerance` is a sub-pixel slack on the fit test. `sizeThatFits` reports
    /// the *exact* full-row width, but the width this layout is then placed in
    /// (`bounds.width`) can come back a rounding ULP smaller. Without slack the
    /// final segment fails a strict `<=` by that ULP and sheds its label — while
    /// the frame still reserves the label's width, leaving a visible gap. One
    /// point of tolerance absorbs that rounding without ever upgrading a segment
    /// that is genuinely a point or more too wide.
    static func resolvedSegmentWidths(
        full: [CGFloat],
        compact: [CGFloat],
        spacing: CGFloat,
        available: CGFloat,
        tolerance: CGFloat = 1.0
    ) -> [CGFloat] {
        guard !full.isEmpty else { return [] }
        let gaps = spacing * CGFloat(full.count - 1)
        var widths = compact
        var used = compact.reduce(0, +) + gaps
        for index in full.indices {
            let delta = full[index] - compact[index]
            guard used + delta <= available + tolerance else { break }
            widths[index] = full[index]
            used += delta
        }
        return widths
    }
}

struct MessageReadStateDot: View {
    let descriptor: MessageStatusDescriptor
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            if let fillColor {
                Circle().fill(fillColor)
            }
            Circle()
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
        }
        .frame(width: size, height: size)
    }

    private var fillColor: Color? {
        descriptor.isSentByUser ? nil : MessageReadStateMarkStyle.fillColor(isRead: descriptor.isRead)
    }

    private var strokeColor: Color {
        MessageReadStateMarkStyle.strokeColor(isRead: descriptor.isRead)
    }

    private var strokeWidth: CGFloat {
        MessageReadStateMarkStyle.strokeWidth(isRead: descriptor.isRead)
    }
}

struct MessageStatusDot: View {
    let descriptor: MessageStatusDescriptor
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            if !isHollow, let fillColor {
                Circle().fill(fillColor)
            }
            Circle()
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
            if let symbolName = MessageStatusSymbols.statusSymbol(
                needsReply: descriptor.needsReply,
                needsConfirmation: descriptor.needsConfirmation,
                isReplied: descriptor.isReplied,
                isConfirmed: descriptor.isConfirmed
            ) {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.43, weight: .bold))
                    .foregroundStyle(innerGlyphColor)
            }
        }
        .frame(width: size, height: size)
    }

    private var isHollow: Bool {
        if descriptor.needsReply || descriptor.needsConfirmation {
            return descriptor.isSentByUser
        }
        return descriptor.isSentByUser || descriptor.isRead || descriptor.isReplied || descriptor.isConfirmed
    }

    private var fillColor: Color? {
        if descriptor.needsReply { return MessageStatusColors.pendingReply }
        if descriptor.needsConfirmation { return MessageStatusColors.confirmation }
        if descriptor.isSentByUser || descriptor.isReplied || descriptor.isConfirmed { return nil }
        return MessageReadStateMarkStyle.fillColor(isRead: descriptor.isRead)
    }

    private var strokeColor: Color {
        // Reply and confirmation are mutually exclusive (binary invariant);
        // reply dominates. A pending reply is yellow; a satisfied one is the
        // done-green `replied` hue so the two never read alike.
        if descriptor.needsReply { return MessageStatusColors.pendingReply }
        if descriptor.isReplied { return MessageStatusColors.replied }
        if descriptor.needsConfirmation || descriptor.isConfirmed { return MessageStatusColors.confirmation }
        return MessageReadStateMarkStyle.strokeColor(isRead: descriptor.isRead)
    }

    private var strokeWidth: CGFloat {
        if descriptor.needsReply || descriptor.needsConfirmation || descriptor.isReplied || descriptor.isConfirmed {
            return 1
        }
        return MessageReadStateMarkStyle.strokeWidth(isRead: descriptor.isRead)
    }

    private var innerGlyphColor: Color {
        if isHollow {
            if descriptor.needsReply { return MessageStatusColors.pendingReply }
            if descriptor.isReplied { return MessageStatusColors.replied }
            return MessageStatusColors.confirmation
        }
        return Color.black.opacity(0.78)
    }
}

struct MessageStatusActionGlyph: View {
    let action: MessageStatusActionState
    var size: CGFloat = 14

    var body: some View {
        MessageStatusSymbolGlyph(
            name: action.symbolName,
            tint: action.tint,
            size: size
        )
    }
}

struct MessageStatusDeadlineGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        MessageStatusSymbolGlyph(
            name: MessageStatusSymbols.deadline,
            tint: MessageStatusColors.deadline,
            size: size
        )
    }
}

struct MessageStatusFlaggedGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        MessageStatusSymbolGlyph(
            name: MessageStatusSymbols.flagged,
            tint: MessageStatusColors.flagged,
            size: size
        )
    }
}

struct MessageStatusRevivedGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        MessageStatusSymbolGlyph(name: MessageStatusSymbols.revived, size: size)
    }
}

struct MessageStatusSharedEvidenceGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        MessageStatusSymbolGlyph(name: MessageStatusSymbols.sharedEvidence, size: size)
    }
}

private struct MessageStatusSymbolGlyph: View {
    let name: String
    var tint: Color = OhiaColors.chipActiveForeground
    var size: CGFloat

    var body: some View {
        Image(systemName: name)
            .font(.system(size: max(11, size * 0.86), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: max(18, size * 1.25), alignment: .leading)
    }
}
