import SwiftUI
import OhiaCore
import OhiaML

/// 66pt control column matching `ProjectsRightControlColumn` chrome: the
/// new-arrivals starburst (apt for a front page), a legend popover, and
/// focused-article / bulk-selection actions.
struct FrontPageRightControlColumn: View {
    @Bindable var workspace: FrontPageWorkspaceState
    let onLeading: Bool
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    /// Bulk action closures applied to the current selection.
    let actions: FrontPageMessageActionHandlers

    @State private var legendPresented = false

    static let columnWidth: CGFloat = 66

    var body: some View {
        VStack(spacing: 14) {
            if showsThreadClose {
                controlDisc(
                    glyph: .native("xmark.circle.fill"),
                    label: "Close",
                    help: "Close thread",
                    isActive: false,
                    isEnabled: true,
                    action: closeThread
                )
            } else {
                StarburstLabelSlot()
            }
            controlDisc(
                glyph: .native("questionmark.circle.fill"),
                label: "Legend",
                help: "Legend",
                isActive: true,
                isEnabled: !legendPresented,
                action: { legendPresented.toggle() }
            )
            .popover(isPresented: $legendPresented, arrowEdge: onLeading ? .trailing : .leading) {
                FrontPageLegendView()
                    .frame(width: 380)
            }

            actionGroup

            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: Self.columnWidth)
        .background(OhiaColors.glassPanel)
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
        .overlay(alignment: onLeading ? .topLeading : .topTrailing) {
            if !showsThreadClose {
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
    }

    private var showsThreadClose: Bool {
        workspace.openThreadID != nil && workspace.focusedArticleID == nil
    }

    private func closeThread() {
        withAnimation(.smooth(duration: 0.34)) {
            workspace.closeThread()
        }
    }

    // MARK: - Focused article / bulk selection actions

    private var targets: [FrontPageArticle] {
        if let focused = workspace.focusedArticle {
            return [focused]
        }
        return workspace.selectedArticles
    }

    private var hasTargets: Bool { !targets.isEmpty }
    private var targetCount: Int { targets.count }
    private var targetIDs: [UUID] { targets.map(\.id) }
    private var actionableIDs: [UUID] { targets.filter(\.isActionable).map(\.id) }
    /// Any inbound target can be sent to the Composer — needs-reply is no longer
    /// required. Sent mail is excluded: there is no inbound message to draft a
    /// reply to, and `sendToComposer` no-ops on it.
    private var composerEligibleIDs: [UUID] { targets.filter { !$0.isSentByUser }.map(\.id) }
    private var composerActionIDs: [UUID] {
        targets.filter { !$0.isSentByUser && !$0.isInComposerQueue }.map(\.id)
    }
    private var confirmationIDs: [UUID] { targets.filter(\.requiresConfirmation).map(\.id) }
    private var confirmedIDs: [UUID] { targets.filter(\.isConfirmed).map(\.id) }
    private var repliedIDs: [UUID] { targets.filter(\.isReplied).map(\.id) }
    private var replyActionMarksReplied: Bool { !actionableIDs.isEmpty }
    private var replyActionIDs: [UUID] { replyActionMarksReplied ? actionableIDs : targetIDs }
    /// The reply disc shows its "done" glyph (reply arrow + check) and lights only
    /// when nothing in the selection still needs a reply and at least one target is
    /// replied; every other state shows the bare arrow.
    private var replyIsDone: Bool { actionableIDs.isEmpty && !repliedIDs.isEmpty }
    private var confirmationActionMode: ConfirmationActionMode {
        if !confirmationIDs.isEmpty { return .confirm(confirmationIDs) }
        if !confirmedIDs.isEmpty { return .confirmed(confirmedIDs) }
        return .markNeeded(targetIDs)
    }
    /// Majority flag state: when most of the targets are already flagged the
    /// button unflags, so a single click always changes something (mirrors the
    /// bulk menu and the Projects bulk toggles).
    private var flagMostlyOn: Bool {
        hasTargets && targets.filter(\.isFlagged).count > targetCount / 2
    }
    private var resolvedMostlyOn: Bool {
        hasTargets && targets.filter(\.isResolved).count > targetCount / 2
    }
    /// Ignore is intentionally single-message only: its confirmation sheet is
    /// inferred from one message's list identity and semantic evidence.
    private var ignoreTarget: FrontPageArticle? {
        guard targets.count == 1, targets[0].isListIgnoreEligible else { return nil }
        return targets[0]
    }

    /// Target-scoped action discs. In focused reader mode the target is the
    /// open article; on the grid the targets are the selected cards.
    @ViewBuilder
    private var actionGroup: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 26, height: 1)
            .padding(.vertical, 2)

        // Dispatch group: compose · resolve · delete. The selection count now
        // lives in the masthead's stat row; the divider above separates the
        // navigation discs from the selection-scoped action discs. Compose leads
        // whenever the selection includes inbound mail; lit when every eligible
        // target is already in the Composer queue.
        LensComposeDisc(
            isActive: !composerEligibleIDs.isEmpty && composerActionIDs.isEmpty,
            isEnabled: !composerActionIDs.isEmpty,
            capturesPressDown: true,
            restAccessibility: composerHelp,
            action: { actions.sendToComposer(composerActionIDs) }
        )
        controlDisc(
            glyph: .native(resolvedMostlyOn ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"),
            label: "Resolved",
            help: hasTargets
                ? (resolvedMostlyOn ? "Reopen" : "Resolved")
                : "Select messages to resolve",
            isActive: resolvedMostlyOn,
            isEnabled: hasTargets,
            tint: MessageStatusColors.resolved,
            action: { actions.setResolved(targetIDs, !resolvedMostlyOn) }
        )
        controlDisc(
            glyph: .native("xmark.bin.circle.fill"),
            label: "Delete",
            help: hasTargets ? "Delete" : "Select messages to delete",
            isActive: false,
            isEnabled: hasTargets,
            destructive: true,
            action: { actions.delete(targetIDs) }
        )

        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 26, height: 1)
            .padding(.vertical, 2)

        // Status-mark group: confirmation · reply · flag. Labels describe the
        // action available for the current selection: complete a pending
        // confirmation / reply, request one, or remove an existing flag.
        controlDisc(
            glyph: confirmationActionMode.glyph,
            label: confirmationActionMode.label,
            help: confirmationHelp,
            isActive: confirmationActionMode.isActive,
            isEnabled: hasTargets,
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
            label: replyActionMarksReplied ? "Replied" : "Reply",
            help: replyHelp,
            isActive: replyIsDone,
            isEnabled: hasTargets,
            tint: MessageStatusColors.pendingReply,
            action: {
                if replyActionMarksReplied {
                    actions.setReplied(replyActionIDs, true)
                } else {
                    actions.setReplyNeeded(replyActionIDs, true)
                }
            }
        )
        // Flag stays tinted (never dimmed) the moment any card is selected, and
        // flips to a distinct remove-flag affordance once the selection is
        // flagged.
        controlDisc(
            glyph: flagMostlyOn ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
            label: flagMostlyOn ? "Unflag" : "Flag",
            help: !hasTargets ? "Select messages to flag" : (flagMostlyOn ? "Unflag" : "Flag"),
            isActive: flagMostlyOn,
            isEnabled: hasTargets,
            tint: MessageStatusColors.flagged,
            action: { actions.setFlagged(targetIDs, !flagMostlyOn) }
        )
        if let ignoreTarget {
            controlDisc(
                glyph: .native("eye.slash.circle.fill"),
                label: "Ignore",
                help: "Ignore",
                isActive: false,
                isEnabled: true,
                tint: OhiaColors.ohiaYellow,
                action: { actions.ignore(ignoreTarget.id) }
            )
        }
    }

    private var replyHelp: String {
        guard hasTargets else { return "Select messages to set reply state" }
        return replyActionMarksReplied ? "Mark replied" : "Mark reply needed"
    }

    private var composerHelp: String {
        guard !composerEligibleIDs.isEmpty else { return "Select messages to send to Composer" }
        if composerActionIDs.isEmpty {
            return "Already in Composer queue"
        }
        return "Send to Composer"
    }

    private var confirmationHelp: String {
        guard hasTargets else { return "Select messages to set confirmation state" }
        switch confirmationActionMode {
        case .confirm:
            return "Mark confirmed"
        case .confirmed:
            return "Mark unconfirmed"
        case .markNeeded:
            return "Mark confirmation needed"
        }
    }

    private func controlDisc(
        glyph: ActionDiscGlyph,
        label: String,
        help: String,
        isActive: Bool,
        isEnabled: Bool,
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
            capturesPressDown: true,
            action: action
        )
    }

    private var starburstCapsuleText: String? {
        if manualRefresh.state.isFailure { return manualRefresh.state.capsuleText }
        if let live = newStarNavigator.formationNoticeText { return live }
        return manualRefresh.state.capsuleText
    }

    private var starburstFailureKind: NewStarFormationNoticeView.FailureKind? {
        switch manualRefresh.state {
        case .transientFailure: return .transient
        case .authFailure: return .auth
        case .idle, .searching, .newMail, .empty: return nil
        }
    }
}

private enum ConfirmationActionMode {
    case confirm([UUID])
    case confirmed([UUID])
    case markNeeded([UUID])

    /// The confirmation state reads through the seal: the check appears only once
    /// the selection is confirmed; the pending / mark-needed states show the bare
    /// seal. The separate, always-present Resolve disc owns the circle-check.
    var glyph: ActionDiscGlyph {
        switch self {
        case .confirmed: return .knockout("checkmark.seal.fill")
        case .confirm, .markNeeded: return .knockout("seal.fill")
        }
    }

    var label: String {
        switch self {
        case .confirm: return "Confirmed"
        case .confirmed, .markNeeded: return "Confirm"
        }
    }

    var isActive: Bool {
        switch self {
        case .confirmed:
            return true
        case .confirm, .markNeeded:
            return false
        }
    }
}

/// Front Page legend. Its message-status rows use the same shared marks as
/// Projects so a reply/confirmation/deadline signal reads identically across
/// the two non-Metal lenses.
struct FrontPageLegendView: View {
    private static let sampleColumnWidth: CGFloat = 150

    var body: some View {
        ConstellationLegendScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)

                ConstellationShortcutLegendSection()

                Divider().background(OhiaColors.glassBorder)

                sectionTitle("Message Status")
                row(detail: "received mail") {
                    MessageReadStateDot(descriptor: .receivedMail, size: 14)
                }
                row(detail: "sent mail") {
                    MessageReadStateDot(descriptor: .sentMail, size: 14)
                }
                row(detail: "needs reply") {
                    MessageStatusActionGlyph(action: .pendingReply, size: 14)
                }
                row(detail: "replied") {
                    MessageStatusActionGlyph(action: .replied, size: 14)
                }
                row(detail: "needs confirmation") {
                    MessageStatusActionGlyph(action: .needsConfirmation, size: 14)
                }
                row(detail: "confirmed") {
                    MessageStatusActionGlyph(action: .confirmed, size: 14)
                }
                row(detail: "concrete deadline") {
                    MessageStatusActionGlyph(action: .deadline, size: 14)
                }
                row(detail: "flagged") {
                    MessageStatusFlaggedGlyph(size: 14)
                }
                row(detail: "revived after an inactive gap") {
                    MessageStatusRevivedGlyph(size: 14)
                }
                row(detail: "cc'd or bcc'd") {
                    MessageStatusSharedEvidenceGlyph(size: 14)
                }

                Divider().background(OhiaColors.glassBorder)

                sectionTitle("Layout")
                textRow(detail: "the lead story — most urgent, above the fold")
                textRow(detail: "feature stories follow by priority")
                textRow(detail: "Purpose sections recede down the page")
                textRow(detail: "hover a brief card to reveal its summary")

                Divider().background(OhiaColors.glassBorder)

                sectionTitle("Sections")
                textRow(detail: "a section’s “More” link reveals overflow up to the time window")
                textRow(detail: "narrow the Moments range to focus the page")
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.telemetrySectionCaps)
            .tracking(0.6)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private func row<Sample: View>(detail: String, @ViewBuilder sample: () -> Sample) -> some View {
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

    private func textRow(detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 14, height: 1)
                .frame(width: Self.sampleColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func shortcutRow(keys: [String], detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: Self.sampleColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(nil)
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
