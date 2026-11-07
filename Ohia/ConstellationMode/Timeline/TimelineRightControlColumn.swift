import SwiftUI
import OhiaCore

/// Vertical control column for Timeline. Hosts the lens-level chrome
/// (starburst / legend — matching the position used by every other
/// Constellation lens) over the Timeline-specific transport (Threads
/// toggle, magnification slider, message / chapter arrows). In the
/// app shell it mounts at the far window border.
struct TimelineRightControlColumn: View {

    @Bindable var workspace: TimelineWorkspaceState
    @Binding var conversationModeOn: Bool

    /// Which side of the window this column sits on. Mirrors the
    /// constellation-wide sidebar-side preference (`onLeading == true`
    /// when the search/ask sidebar is on the right, so the controls
    /// hug the far *left* edge). When `onLeading == true` the hairline
    /// divider, starburst overlay, legend popover, and 2×2 grid all
    /// flip to read coherently from the leading edge.
    let onLeading: Bool

    /// Beacon state for the starburst. Same `NewStarFormationNoticeView`
    /// the other lenses use — passing the coordinators in directly
    /// (rather than rebuilding a fake "sparkles" disc) means Timeline
    /// surfaces the same forming-count pulse, ready-count badge,
    /// capsule text, and failure tint as People / Meanings.
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator

    /// Click action for the starburst. Constructed in `ConstellationModeView`
    /// where the manual-refresh + Territory account scope live; same
    /// closure used by the shared edge column.
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    /// Message actions applied to the email currently under the Timeline
    /// playhead.
    let actions: FrontPageMessageActionHandlers

    @State private var legendPresented = false

    /// Width of the column. Sized so a 38pt disc + 4pt margin on each
    /// side fits comfortably, with room for the 2×2 arrow grid (24pt
    /// buttons × 2 + 6pt gap = 54pt) without crowding.
    static let columnWidth: CGFloat = 70

    var body: some View {
        VStack(spacing: 14) {
            // Reserve a 38pt slot at the top of the column for the
            // overlaid starburst. The view itself is mounted as an
            // `.overlay(alignment: .topTrailing)` below so its capsule
            // can grow leftward over the content body without forcing the
            // column to widen and shoving the disc off-screen.
            StarburstLabelSlot()

            controlDisc(
                glyph: .native("questionmark.circle.fill"),
                label: "Legend",
                help: "Legend",
                isActive: true,
                isEnabled: !legendPresented
            ) {
                legendPresented.toggle()
            }
            // Popover arrow points back toward the column. When the
            // column hugs the leading edge, the popover swings out to
            // the right (arrowEdge: .trailing → arrow on the popover's
            // trailing side, which means it sits to the right of the
            // disc and points left back at it). When the column hugs
            // the trailing edge, it swings to the left.
            .popover(
                isPresented: $legendPresented,
                arrowEdge: onLeading ? .trailing : .leading
            ) {
                TimelineLegendView()
                    .frame(width: 400)
            }

            divider

            // Transport block. Everything above it (starburst slot, legend)
            // is fixed-height, so anchoring the navigation controls here
            // keeps them pinned: the prev/next arrows never move as the
            // playhead crosses messages whose action group grows or shrinks
            // (the Ignore disc only exists for list mail). Threads rides with
            // them because it decides what the arrows step through, and the
            // zoom slider follows so the whole transport reads as one block.
            threadsToggle

            scopePositionLabel

            arrowGrid

            zoomSlider

            divider

            // Per-message action discs are the last group in the column, so
            // their variable height (Ignore appears only for list mail)
            // displaces nothing above them.
            actionGroup

            // Bracket-active badge trails the actions so the user can see
            // "scope is narrowed" without having to glance at the ruler,
            // without its appearance shoving the transport controls. Vanishes
            // when no bracket is set; tapping the ✕ inside the badge clears it.
            if workspace.bracketedRange != nil {
                bracketBadge
            }

            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: Self.columnWidth)
        .background(OhiaColors.glassPanel)
        .overlay(
            // Hairline divider on the column's body-facing edge.
            // Column on the right → divider on the left (between column
            // and the multitrack canvas). Column on the left → divider
            // on the right.
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
        .overlay(alignment: onLeading ? .topLeading : .topTrailing) {
            // Starburst lives in an overlay so its capsule text ("3
            // forming…", "No new stars…") can extend over the top of
            // the content body — matching the shared edge column in other
            // lenses. `.fixedSize` lets the view
            // claim its intrinsic width without being squeezed into the
            // column's 70pt frame.
            //
            // When the column hugs the trailing edge (default), the
            // overlay anchors topTrailing and the trailing padding
            // centers the 38pt disc on the column's centerline; the
            // capsule grows leftward toward the content body.
            //
            // When the column hugs the leading edge, the overlay
            // anchors topLeading, the leading padding centers the
            // disc, and the capsule grows rightward.
            NewStarFormationNoticeView(
                formingCount: newStarNavigator.formingCount,
                badgeCount: NewMailArrivalLedger.shared.unvisitedCount,
                formationText: starburstCapsuleText,
                isNavigable: NewMailArrivalLedger.shared.unvisitedCount > 0,
                isSearching: manualRefresh.state == .searching,
                failureKind: starburstFailureKind,
                ackFlickerSeq: manualRefresh.ackFlickerSeq,
                emptySignalSeq: manualRefresh.emptySignalSeq,
                action: onStarburstClick,
                menuAction: onBeaconMenuCommand
            )
            .fixedSize()
            .padding(.top, 14)
            .padding(.leading, onLeading ? (Self.columnWidth - 38) / 2 : 0)
            .padding(.trailing, onLeading ? 0 : (Self.columnWidth - 38) / 2)
        }
    }

    // MARK: - Sub-views

    private var divider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder.opacity(0.6))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private func controlDisc(
        glyph: ActionDiscGlyph,
        label: String,
        help: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        tint: Color? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        LensActionDisc(
            glyph: glyph,
            label: label,
            accessibility: help,
            isActive: isActive,
            isEnabled: isEnabled,
            tint: tint,
            destructive: destructive,
            action: action
        )
    }

    // MARK: - Current-message actions

    private var target: TimelineLayoutSnapshot.MessageMeta? {
        workspace.playheadMessage
    }

    private var hasTarget: Bool {
        target != nil
    }

    private var targetIDs: [UUID] {
        guard let target else { return [] }
        return [target.messageID]
    }

    private var actionableIDs: [UUID] {
        guard let target, target.isActionable else { return [] }
        return [target.messageID]
    }

    private var composerActionIDs: [UUID] {
        guard let target, !target.isSentByUser, !target.isInComposerQueue else { return [] }
        return [target.messageID]
    }

    private var confirmationIDs: [UUID] {
        guard let target, target.requiresConfirmation else { return [] }
        return [target.messageID]
    }

    private var confirmedIDs: [UUID] {
        guard let target, target.isConfirmed else { return [] }
        return [target.messageID]
    }

    private var replyActionMarksReplied: Bool {
        actionableIDs.isEmpty == false
    }

    private var replyActionIDs: [UUID] {
        replyActionMarksReplied ? actionableIDs : targetIDs
    }

    /// The reply disc shows its "done" glyph (reply arrow + check) and lights only
    /// when the playhead email is actually replied; every other state shows the
    /// bare arrow.
    private var replyIsDone: Bool {
        target?.isReplied == true
    }

    private var confirmationActionMode: TimelineConfirmationActionMode {
        if confirmationIDs.isEmpty == false { return .confirm(confirmationIDs) }
        if confirmedIDs.isEmpty == false { return .confirmed(confirmedIDs) }
        return .markNeeded(targetIDs)
    }

    private var flagIsOn: Bool {
        target?.isFlagged == true
    }

    private var resolvedIsOn: Bool {
        target?.isResolved == true
    }

    @ViewBuilder
    private var actionGroup: some View {
        VStack(spacing: 8) {
            // No leading separator: the column's wide divider above already
            // separates this group from the transport block.
            //
            // Dispatch group: compose · resolve · delete. Keep Compose in
            // the fixed HUD even when the playhead target is sent mail or absent;
            // eligibility controls whether the affordance is enabled.
            LensComposeDisc(
                isActive: target?.isInComposerQueue == true,
                isEnabled: !composerActionIDs.isEmpty,
                restAccessibility: composerHelp,
                action: { actions.sendToComposer(composerActionIDs) }
            )
            controlDisc(
                glyph: .native("checkmark.circle.fill"),
                label: "Resolved",
                help: resolvedHelp,
                isActive: resolvedIsOn,
                isEnabled: hasTarget,
                tint: MessageStatusColors.confirmation,
                action: { actions.setResolved(targetIDs, !resolvedIsOn) }
            )
            controlDisc(
                glyph: .native("xmark.bin.circle.fill"),
                label: "Delete",
                help: hasTarget ? "Delete" : "Select an email to delete",
                isActive: false,
                isEnabled: hasTarget,
                destructive: true,
                action: { actions.delete(targetIDs) }
            )

            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 26, height: 1)
                .padding(.vertical, 2)

            // Status-mark group: confirmation · reply · flag. The confirm and reply
            // discs keep a fixed label and swap their glyph to reflect the playhead
            // email's current state — bare seal vs. seal-with-check, plain reply
            // arrow vs. reply-with-check — lit only once confirmed / replied.
            controlDisc(
                glyph: confirmationActionMode.glyph,
                label: confirmationActionMode.label,
                help: confirmationHelp,
                isActive: confirmationActionMode.isActive,
                isEnabled: hasTarget,
                tint: MessageStatusColors.confirmation,
                action: {
                    switch confirmationActionMode {
                    case .confirm(let ids):
                        actions.setConfirmed(ids, true)
                    case .confirmed(let ids):
                        actions.setConfirmed(ids, false)
                    case .markNeeded(let ids):
                        actions.setConfirmationNeeded(ids, true)
                    }
                }
            )
            controlDisc(
                glyph: replyIsDone ? .markReplied : .native("arrowshape.turn.up.left.circle.fill"),
                label: "Replied",
                help: replyHelp,
                isActive: replyIsDone,
                isEnabled: hasTarget,
                tint: MessageStatusColors.pendingReply,
                action: {
                    if replyActionMarksReplied {
                        actions.setReplied(replyActionIDs, true)
                    } else {
                        actions.setReplyNeeded(replyActionIDs, true)
                    }
                }
            )
            controlDisc(
                glyph: flagIsOn ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
                label: flagIsOn ? "Unflag" : "Flag",
                help: !hasTarget ? "Select an email to flag" : (flagIsOn ? "Unflag" : "Flag"),
                isActive: flagIsOn,
                isEnabled: hasTarget,
                tint: MessageStatusColors.flagged,
                action: { actions.setFlagged(targetIDs, !flagIsOn) }
            )
            if let target, target.isListIgnoreEligible {
                controlDisc(
                    glyph: .native("eye.slash.circle.fill"),
                    label: "Ignore",
                    help: "Ignore",
                    isActive: false,
                    isEnabled: true,
                    tint: OhiaColors.ohiaYellow,
                    action: { actions.ignore(target.messageID) }
                )
            }
        }
    }

    private var replyHelp: String {
        guard hasTarget else { return "Select an email to set reply state" }
        return replyActionMarksReplied ? "Mark replied" : "Mark reply needed"
    }

    private var composerHelp: String {
        guard hasTarget else { return "Select an email to send to Composer" }
        guard let target, !target.isSentByUser else { return "Select a received email to send to Composer" }
        return target.isInComposerQueue ? "Already in Composer queue" : "Send to Composer"
    }

    private var confirmationHelp: String {
        guard hasTarget else { return "Select an email to set confirmation state" }
        switch confirmationActionMode {
        case .confirm:
            return "Mark confirmed"
        case .confirmed:
            return "Mark unconfirmed"
        case .markNeeded:
            return "Mark confirmation needed"
        }
    }

    private var resolvedHelp: String {
        guard hasTarget else { return "Select an email to resolve" }
        return resolvedIsOn ? "Reopen" : "Resolved"
    }

    private var threadsToggle: some View {
        let on = conversationModeOn
        return controlDisc(
            glyph: .native("list.bullet.circle.fill"),
            label: "Threads",
            help: "Threads",
            isActive: on
        ) {
            conversationModeOn.toggle()
            workspace.conversationModeEnabled = conversationModeOn
        }
    }

    private var zoomSlider: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)

            // Two-frame trick: the inner frame is the slider's intrinsic
            // (horizontal) size; the rotation puts it on its side; the
            // outer frame reserves vertical layout space matching the
            // rotated bounds. Bottom of the column = fit (fraction 0);
            // top = max zoom (fraction 1).
            Slider(value: zoomBinding, in: 0...1)
                .controlSize(.mini)
                .tint(OhiaColors.ohiaYellow)
                .frame(width: 80, height: 16)
                .rotationEffect(.degrees(-90))
                .frame(width: 16, height: 80)
                .accessibilityLabel("Zoom")

            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)
        }
    }

    /// Yellow pill summarizing the active bracket — visible only when
    /// `workspace.bracketedRange != nil`. Surfaces the otherwise
    /// invisible state ("the bracket I painted on the ruler is now
    /// scoping ← / → and Ask") and gives a one-click clear via the ✕
    /// at the bottom. Tap "↵" hint reminds the user that Return
    /// commits the bracket to the viewport.
    @ViewBuilder
    private var bracketBadge: some View {
        if let range = workspace.bracketedRange {
            let count = bracketMessageCount(in: range)
            let duration = bracketDurationText(for: range)
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.ohiaYellow)
                Text(duration)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.ohiaYellow.opacity(0.8))
                Text("↵ fit")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(OhiaColors.ohiaYellow.opacity(0.7))
                Button {
                    workspace.applyBracket(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(OhiaColors.ohiaYellow)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .strokeBorder(OhiaColors.ohiaYellow.opacity(0.6), lineWidth: 1)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear bracket")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OhiaColors.ohiaYellow.opacity(0.12))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OhiaColors.ohiaYellow.opacity(0.55), lineWidth: 1)
            }
            .padding(.horizontal, 6)
        }
    }

    private func bracketMessageCount(in range: ClosedRange<Date>) -> Int {
        guard let entries = workspace.currentSnapshot?.sortedEligibleEntries else { return 0 }
        return entries.reduce(into: 0) { count, entry in
            if range.contains(entry.date) { count += 1 }
        }
    }

    private func bracketDurationText(for range: ClosedRange<Date>) -> String {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        if span >= 365 * 86_400 {
            return String(format: "%.1fy", span / (365 * 86_400))
        } else if span >= 30 * 86_400 {
            return String(format: "%.1fmo", span / (30 * 86_400))
        } else if span >= 86_400 {
            return String(format: "%.0fd", span / 86_400)
        } else if span >= 3_600 {
            return String(format: "%.0fh", span / 3_600)
        } else {
            return String(format: "%.0fm", span / 60)
        }
    }

    @ViewBuilder
    private var scopePositionLabel: some View {
        if let scope = workspace.playheadScopePosition {
            VStack(spacing: 2) {
                Text(scope.index.formatted(.number))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textPrimary)
                Text("of \(scope.total.formatted(.number))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(conversationModeOn ? "Thread position" : "Message position")
        } else {
            Text("—")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textPrimary.opacity(0.4))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(conversationModeOn ? "Thread position" : "Message position")
        }
    }

    private var arrowGrid: some View {
        let scope = workspace.playheadScopePosition
        let chapter = workspace.playheadChapterPosition
        let threadMessage = workspace.playheadMessagePositionInActiveThread
        let canStepBack = conversationModeOn
            ? ((threadMessage?.index ?? 0) > 1 || (chapter?.index ?? 0) > 0)
            : (scope?.index ?? 0) > 1
        let canStepForward = conversationModeOn
            ? ((threadMessage.map { $0.index < $0.total } ?? false)
                || (chapter.map { $0.index + 1 < $0.total } ?? false))
            : (scope.map { $0.index < $0.total } ?? false)
        let canChapterBack = conversationModeOn && (chapter?.index ?? 0) > 0
        let canChapterForward = conversationModeOn
            && (chapter.map { $0.index + 1 < $0.total } ?? false)

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                arrowButton(
                    symbol: "backward.end",
                    help: "Prev thread",
                    enabled: canChapterBack
                ) {
                    workspace.skipToPreviousChapter()
                }
                arrowButton(
                    symbol: "forward.end",
                    help: "Next thread",
                    enabled: canChapterForward
                ) {
                    workspace.skipToNextChapter()
                }
            }
            HStack(spacing: 6) {
                arrowButton(
                    symbol: "chevron.left",
                    help: "Prev email",
                    enabled: canStepBack
                ) {
                    workspace.stepPlayhead(direction: .backward)
                }
                arrowButton(
                    symbol: "chevron.right",
                    help: "Next email",
                    enabled: canStepForward
                ) {
                    workspace.stepPlayhead(direction: .forward)
                }
            }
        }
    }

    private func arrowButton(
        symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Emblem grammar (CLAUDE.md §3.7): buttonBackground fill with
        // ohiaYellow ring + ohiaGreen glyph. The disc shape matches the
        // sibling controls in this column (legend, threads)
        // rather than the standard rounded-rect emblem so the column
        // reads as one consistent button stack.
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(OhiaColors.buttonBackground)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(enabled ? OhiaColors.ohiaGreen : OhiaColors.ohiaGreen.opacity(0.35))
            }
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .strokeBorder(
                        enabled ? OhiaColors.ohiaYellow : OhiaColors.ohiaYellow.opacity(0.35),
                        lineWidth: 1
                    )
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(help)
    }

    /// Same precedence as `ConstellationModeView.starburstCapsuleText`: a
    /// latched failure owns hover text; otherwise live formation text wins.
    private var starburstCapsuleText: String? {
        if manualRefresh.state.isFailure { return manualRefresh.state.capsuleText }
        if let live = newStarNavigator.formationNoticeText { return live }
        return manualRefresh.state.capsuleText
    }

    /// Maps the coordinator's terminal-failure states to the view's
    /// `FailureKind`, mirroring `ConstellationModeView.starburstFailureKind`.
    private var starburstFailureKind: NewStarFormationNoticeView.FailureKind? {
        switch manualRefresh.state {
        case .transientFailure: return .transient
        case .authFailure:      return .auth
        case .idle, .searching, .newMail, .empty: return nil
        }
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { workspace.zoomFraction },
            set: { newValue in
                workspace.applyZoomFraction(newValue, centeredOn: workspace.playhead)
            }
        )
    }
}

private enum TimelineConfirmationActionMode {
    case confirm([UUID])
    case confirmed([UUID])
    case markNeeded([UUID])

    /// The confirmation state reads through the seal: the check appears only once
    /// the email is confirmed; the pending / mark-needed states show the bare seal.
    /// The dedicated Resolve disc owns the circle-check.
    var glyph: ActionDiscGlyph {
        switch self {
        case .confirmed: return .knockout("checkmark.seal.fill")
        case .confirm, .markNeeded: return .knockout("seal.fill")
        }
    }

    /// Fixed label across every state — the disc names the confirmation axis and
    /// the glyph carries the state.
    var label: String { "Confirmed" }

    var isActive: Bool {
        switch self {
        case .confirmed:
            return true
        case .confirm, .markNeeded:
            return false
        }
    }
}

/// Timeline-lens analog of `ConstellationLegendView`. Same title +
/// section-titled key-cap grid layout the People / Meaning legends
/// use, with the Timeline's keyboard + mouse/trackpad gestures in
/// place of the 3D flight controls. Surfaced by the legend disc in
/// `TimelineRightControlColumn`.
private struct TimelineLegendView: View {
    private static let keyColumnWidth: CGFloat = 132
    private static let sampleColumnWidth: CGFloat = 132

    var body: some View {
        ConstellationLegendScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                ConstellationShortcutLegendSection()
                Divider().background(OhiaColors.glassBorder)
                keyboardSection
                Divider().background(OhiaColors.glassBorder)
                statusSection
                Divider().background(OhiaColors.glassBorder)
                currentEmailButtonSection
                Divider().background(OhiaColors.glassBorder)
                pointerSection
            }
        }
    }

    @ViewBuilder
    private var keyboardSection: some View {
        sectionTitle("Keyboard")
        shortcutRow(keys: ["←", "→"], detail: "previous · next email")
        shortcutRow(keys: ["⌘ ←", "⌘ →"], detail: "previous · next thread")
        shortcutRow(keys: ["↵"], detail: "fit viewport to bracket")
    }

    @ViewBuilder
    private var statusSection: some View {
        sectionTitle("Message Status")
        sampleRow(detail: "received mail") {
            MessageReadStateDot(descriptor: .receivedMail, size: 14)
        }
        sampleRow(detail: "sent mail") {
            MessageReadStateDot(descriptor: .sentMail, size: 14)
        }
        sampleRow(detail: "needs reply") {
            MessageStatusActionGlyph(action: .pendingReply, size: 14)
        }
        sampleRow(detail: "replied") {
            MessageStatusActionGlyph(action: .replied, size: 14)
        }
        sampleRow(detail: "needs confirmation") {
            MessageStatusActionGlyph(action: .needsConfirmation, size: 14)
        }
        sampleRow(detail: "confirmed") {
            MessageStatusActionGlyph(action: .confirmed, size: 14)
        }
        sampleRow(detail: "concrete deadline") {
            MessageStatusActionGlyph(action: .deadline, size: 14)
        }
        sampleRow(detail: "flagged") {
            MessageStatusFlaggedGlyph(size: 14)
        }
        sampleRow(detail: "revived after an inactive gap") {
            MessageStatusRevivedGlyph(size: 14)
        }
        sampleRow(detail: "cc'd or bcc'd") {
            MessageStatusSharedEvidenceGlyph(size: 14)
        }
    }

    @ViewBuilder
    private var currentEmailButtonSection: some View {
        sectionTitle("Current Email Buttons")
        sampleRow(detail: "reply state") {
            ActionDiscGlyphView(glyph: .markReplied, tint: MessageStatusColors.pendingReply, size: 16)
        }
        sampleRow(detail: "confirmation state") {
            ActionDiscGlyphView(glyph: .knockout("checkmark.seal.fill"), tint: MessageStatusColors.confirmation, size: 16)
        }
        sampleRow(detail: "resolved state") {
            ActionDiscGlyphView(glyph: .native("checkmark.circle.fill"), tint: MessageStatusColors.confirmation, size: 16)
        }
        sampleRow(detail: "flag") {
            ActionDiscGlyphView(glyph: .native("flag.circle.fill"), tint: MessageStatusColors.flagged, size: 16)
        }
        sampleRow(detail: "delete") {
            ActionDiscGlyphView(glyph: .native("xmark.bin.circle.fill"), tint: OhiaColors.ohiaRed, size: 16)
        }
    }

    @ViewBuilder
    private var pointerSection: some View {
        sectionTitle("Mouse & Trackpad")
        shortcutRow(keys: ["scroll"], detail: "forward · back in time")
        shortcutRow(keys: ["⇧ scroll"], detail: "zoom in · out")
        shortcutRow(keys: ["⌥ scroll"], detail: "zoom in · out")
        shortcutRow(keys: ["drag"], detail: "scrub playhead on the ruler")
        shortcutRow(keys: ["⇧ drag"], detail: "paint a time bracket on the ruler")
        shortcutRow(keys: ["⌘ click"], detail: "clear the time bracket")
        shortcutRow(keys: ["drag window"], detail: "pan viewport · minimap")
        shortcutRow(keys: ["drag edge"], detail: "zoom viewport · minimap")
        shortcutRow(keys: ["click outside"], detail: "recenter window · minimap")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.telemetrySectionCaps)
            .tracking(0.6)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private func shortcutRow(keys: [String], detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: Self.keyColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func sampleRow<Sample: View>(
        detail: String,
        @ViewBuilder sample: () -> Sample
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack { sample() }
                .frame(width: Self.sampleColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(OhiaTypography.legendLine)
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(OhiaColors.surface(0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            }
    }
}
