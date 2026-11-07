import SwiftUI
import OhiaCore
import OhiaScheduler

/// Resolved single-message target for a vertical action-disc rail. Shared by
/// the Meaning lens locked-main-email column and the People correspondent-lock
/// ring-node column (`RingNodeActionDiscGroup`); both render the same disc set
/// against one message's status.
struct MessageActionDiscTarget: Equatable {
    let messageID: UUID
    let statusDescriptor: MessageStatusDescriptor
    let isInComposerQueue: Bool
    let isListIgnoreEligible: Bool
}

struct MeaningClusterHUDPresentation: Equatable {
    enum ProgressPlacement: Equatable {
        case belowPrimaryControl
    }

    let sliderIsEnabled: Bool
    let sliderIsDimmed: Bool
    let progressPlacement: ProgressPlacement?
    let snapshotInteractionsAreEnabled: Bool
    let helpText: String?

    var showsProgressSpinner: Bool {
        progressPlacement != nil
    }

    init(status: MeaningClusterPipelineStatus) {
        switch status {
        case .processing:
            sliderIsEnabled = false
            sliderIsDimmed = true
            progressPlacement = nil
            snapshotInteractionsAreEnabled = false
            helpText = "Waiting for ingestion and placement to complete."
        case .detecting:
            sliderIsEnabled = false
            sliderIsDimmed = true
            progressPlacement = .belowPrimaryControl
            snapshotInteractionsAreEnabled = false
            helpText = "Discovering clusters from your complete mail corpus."
        case .refreshing:
            sliderIsEnabled = true
            sliderIsDimmed = false
            progressPlacement = .belowPrimaryControl
            snapshotInteractionsAreEnabled = true
            helpText = "Refreshing clusters from your complete current corpus."
        case .incrementalProcessing:
            sliderIsEnabled = true
            sliderIsDimmed = false
            progressPlacement = nil
            snapshotInteractionsAreEnabled = true
            helpText = "Current clusters remain available while new mail settles."
        case .ready:
            sliderIsEnabled = true
            sliderIsDimmed = false
            progressPlacement = nil
            snapshotInteractionsAreEnabled = true
            helpText = nil
        }
    }
}

/// Meaning-lens analog of `TimelineRightControlColumn`. Same 70pt
/// width / full-height grammar — starburst + recenter + legend at the
/// top (same `NewStarFormationNoticeView` the other lenses use via
/// the shared edge column), and the cluster-display slider
/// underneath instead of timeline transport. Replaces the old floating
/// `MeaningClusterResolutionControl` panel that lived at the bottom
/// corner of the lens.
struct MeaningRightControlColumn: View {

    /// Which side of the window this column sits on. Mirrors the
    /// constellation-wide sidebar-side preference (`onLeading == true`
    /// when the search/ask sidebar is on the right, so the controls
    /// hug the far *left* edge).
    let onLeading: Bool

    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    let onRecenter: () -> Void
    let recenterEnabled: Bool

    /// Parameters for the constellation legend popover. Sourced from
    /// ConstellationModeView's existing computed properties so the
    /// Meaning column shows the same legend content as the shared edge
    /// column in other lenses.
    let hasSearch: Bool
    let hasCitations: Bool
    let hasSelection: Bool
    let hasNebulae: Bool
    let hasFibers: Bool

    /// Cluster-display slider state.
    @Binding var clusterValue: Double
    let clusterStatus: MeaningClusterPipelineStatus
    let clusterAvailableCount: Int
    let clusterVisibleCount: Int

    /// When non-nil, a meaning cluster filter is engaged: the cluster-display
    /// slider is replaced by a removable filter chip showing the live count of
    /// messages in the cluster (respecting every other active filter).
    let activeClusterFilter: MeaningClusterFilterDescriptor?
    /// Clears the cluster filter and restores the slider.
    let onClearClusterFilter: () -> Void
    /// Hover enter/exit on the cluster chip — drives the rich cluster popup.
    let onClusterChipHover: (Bool) -> Void
    /// Every displayed cluster, by semantic title, for the legend-style
    /// cluster list popover. Empty outside the Meaning lens (the disc hides).
    let clusterListEntries: [MeaningClusterListEntry]
    /// Multi-select toggle: adds or removes one cluster from the scope.
    let onToggleClusterInScope: (Int64) -> Void
    /// Hover enter/exit on a list row — drives the rich cluster popup for
    /// that cluster, like hovering its nucleus in the scene.
    let onClusterRowHover: (Int64, Bool) -> Void
    /// The list popover closed (Esc, outside click, or programmatic
    /// unmount). SwiftUI does not reliably deliver `.onHover(false)` to
    /// rows removed under the pointer, so the host dismisses any row-driven
    /// cluster popup here — otherwise the card and the renderer's nucleus
    /// flare stay latched until the pointer next crosses the scene.
    let onClusterListClosed: () -> Void

    let showsMessageActions: Bool
    let messageActionTarget: MessageActionDiscTarget?
    let actions: FrontPageMessageActionHandlers
    let onReleaseLock: (() -> Void)?

    @State private var legendPresented = false
    @State private var clusterListPresented = false
    @State private var recenterCooldownActive = false
    @State private var recenterCooldownSeq = 0

    static let columnWidth: CGFloat = 70

    var body: some View {
        VStack(spacing: 14) {
            if showsMessageActions {
                controlDisc(
                    glyph: .native("xmark.circle.fill"),
                    label: "Close",
                    help: "Release lock",
                    isEnabled: onReleaseLock != nil,
                    action: { onReleaseLock?() }
                )
                controlDisc(
                    glyph: .knockout("scope"),
                    label: "Recenter",
                    help: "Recenter",
                    isEnabled: recenterEnabled && !recenterCooldownActive
                ) {
                    beginRecenterCooldown()
                    onRecenter()
                }
                lockedOverlayLegendDisc
            } else {
                // Reserve a 38pt slot at the top of the column for the
                // overlaid starburst (mounted as an `.overlay` so its
                // capsule can extend past the column's 70pt frame), plus the
                // "Beacon" gloss label beneath it.
                StarburstLabelSlot()

                controlDisc(
                    glyph: .knockout("scope"),
                    label: "Recenter",
                    help: "Recenter",
                    isEnabled: recenterEnabled && !recenterCooldownActive
                ) {
                    beginRecenterCooldown()
                    onRecenter()
                }
                constellationLegendDisc
            }

            divider

            if showsMessageActions {
                actionGroup
            } else {
                clusterControls
            }

            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: Self.columnWidth)
        .background(OhiaColors.glassPanel)
        .overlay(
            // Hairline divider on the column's body-facing edge.
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
        .overlay(alignment: onLeading ? .topLeading : .topTrailing) {
            // Starburst — overlaid so the capsule text grows beyond the
            // 70pt column into the content body, matching the shared edge
            // column behavior in other lenses. The
            // padding centers the 38pt disc on the column's centerline.
            if !showsMessageActions {
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

    // MARK: - Cluster controls

    private var targetIDs: [UUID] {
        messageActionTarget.map { [$0.messageID] } ?? []
    }

    private var hasMessageTarget: Bool {
        messageActionTarget != nil
    }

    private var targetStatus: MessageStatusDescriptor? {
        messageActionTarget?.statusDescriptor
    }

    private var replyActionMarksReplied: Bool {
        targetStatus?.needsReply == true
    }

    /// The reply disc shows its "done" glyph (reply arrow + check) and lights only
    /// when the message is actually replied; every other state shows the bare arrow.
    private var replyIsDone: Bool {
        targetStatus?.isReplied == true
    }

    private var composerActionIDs: [UUID] {
        guard let target = messageActionTarget,
              !target.statusDescriptor.isSentByUser,
              !target.isInComposerQueue else {
            return []
        }
        return [target.messageID]
    }

    private var confirmationActionMode: MeaningConfirmationActionMode {
        guard let target = messageActionTarget else { return .disabled }
        if target.statusDescriptor.needsConfirmation { return .confirm(target.messageID) }
        if target.statusDescriptor.isConfirmed { return .confirmed(target.messageID) }
        return .markNeeded(target.messageID)
    }

    private var readActionMarksRead: Bool {
        targetStatus.map { !$0.isRead } ?? true
    }

    @ViewBuilder
    private var actionGroup: some View {
        // Dispatch group: compose · resolve · delete.
        if let target = messageActionTarget, !target.statusDescriptor.isSentByUser {
            controlDisc(
                glyph: .native("square.and.pencil.circle.fill"),
                label: "Compose",
                help: composerHelp,
                isActive: target.isInComposerQueue,
                isEnabled: !target.isInComposerQueue,
                tint: MessageStatusColors.pendingReply,
                action: { actions.sendToComposer(composerActionIDs) }
            )
        }
        let isResolved = messageActionTarget?.statusDescriptor.isResolved == true
        controlDisc(
            glyph: .native(isResolved ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"),
            label: "Resolved",
            help: hasMessageTarget
                ? (isResolved ? "Reopen" : "Resolved")
                : "Select the main email to resolve",
            isActive: isResolved,
            isEnabled: hasMessageTarget,
            tint: MessageStatusColors.resolved,
            action: { actions.setResolved(targetIDs, !isResolved) }
        )
        controlDisc(
            glyph: .native("xmark.bin.circle.fill"),
            label: "Delete",
            help: hasMessageTarget ? "Delete main email" : "Select the main email to delete",
            isActive: false,
            isEnabled: hasMessageTarget,
            destructive: true,
            action: { actions.delete(targetIDs) }
        )

        divider

        // Status-mark group: confirmation · reply · flag · read. The confirm and
        // reply discs keep a fixed label and swap their glyph to reflect the
        // message's current state (bare seal / seal-with-check, plain reply arrow /
        // reply-with-check).
        controlDisc(
            glyph: confirmationActionMode.glyph,
            label: confirmationActionMode.label,
            help: confirmationHelp,
            isActive: confirmationActionMode.isActive,
            isEnabled: confirmationActionMode.isEnabled,
            tint: MessageStatusColors.confirmation,
            action: {
                switch confirmationActionMode {
                case .confirm(let id):
                    actions.setConfirmed([id], true)
                case .confirmed(let id):
                    actions.setConfirmed([id], false)
                case .markNeeded(let id):
                    actions.setConfirmationNeeded([id], true)
                case .disabled:
                    break
                }
            }
        )
        controlDisc(
            glyph: replyIsDone ? .markReplied : .native("arrowshape.turn.up.left.circle.fill"),
            label: "Replied",
            help: replyHelp,
            isActive: replyIsDone,
            isEnabled: hasMessageTarget,
            tint: MessageStatusColors.pendingReply,
            action: {
                if replyActionMarksReplied {
                    actions.setReplied(targetIDs, true)
                } else {
                    actions.setReplyNeeded(targetIDs, true)
                }
            }
        )
        controlDisc(
            glyph: targetStatus?.isFlagged == true ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
            label: targetStatus?.isFlagged == true ? "Unflag" : "Flag",
            help: flagHelp,
            isActive: targetStatus?.isFlagged == true,
            isEnabled: hasMessageTarget,
            tint: MessageStatusColors.flagged,
            action: { actions.setFlagged(targetIDs, !(targetStatus?.isFlagged ?? false)) }
        )
        controlDisc(
            glyph: readActionMarksRead ? .knockout("envelope.open.fill") : .native("envelope.circle.fill"),
            label: readActionMarksRead ? "Read" : "Unread",
            help: readHelp,
            isActive: targetStatus?.isRead == false,
            isEnabled: hasMessageTarget,
            tint: MessageReadStateMarkStyle.unreadGloss,
            action: { actions.setRead(targetIDs, readActionMarksRead) }
        )
        if let target = messageActionTarget, target.isListIgnoreEligible {
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

    private var readHelp: String {
        guard hasMessageTarget else { return "Select the main email to set read state" }
        return readActionMarksRead ? "Mark main email read" : "Mark main email unread"
    }

    private var replyHelp: String {
        guard hasMessageTarget else { return "Select the main email to set reply state" }
        return replyActionMarksReplied ? "Mark main email replied" : "Mark main email reply needed"
    }

    private var composerHelp: String {
        guard let target = messageActionTarget,
              !target.statusDescriptor.isSentByUser else {
            return "Select the main email to send to Composer"
        }
        return target.isInComposerQueue ? "Already in Composer queue" : "Send main email to Composer"
    }

    private var confirmationHelp: String {
        switch confirmationActionMode {
        case .confirm:
            return "Mark main email confirmed"
        case .confirmed:
            return "Mark main email unconfirmed"
        case .markNeeded:
            return "Mark main email confirmation needed"
        case .disabled:
            return "Select the main email to set confirmation state"
        }
    }

    private var flagHelp: String {
        guard hasMessageTarget else { return "Select the main email to flag" }
        return targetStatus?.isFlagged == true ? "Unflag main email" : "Flag main email"
    }

    @ViewBuilder
    private var clusterControls: some View {
        clusterPrimaryControl

        // The list disc stays visible in every state. It remains usable while
        // an established snapshot refreshes or new mail settles, and disabled
        // with the same status explanation before the first snapshot exists.
        if clusterPresentation.snapshotInteractionsAreEnabled {
            if !clusterListEntries.isEmpty {
                clusterListDisc.padding(.top, 8)
            }
        } else {
            clusterListDisc.padding(.top, 8)
        }
    }

    private var clusterPresentation: MeaningClusterHUDPresentation {
        MeaningClusterHUDPresentation(status: clusterStatus)
    }

    @ViewBuilder
    private var clusterPrimaryControl: some View {
        let content = VStack(spacing: 8) {
            Group {
                if let activeClusterFilter, clusterPresentation.snapshotInteractionsAreEnabled {
                    clusterFilterChip(activeClusterFilter)
                } else {
                    clusterSliderControls
                        .opacity(clusterPresentation.sliderIsDimmed ? 0.35 : 1)
                }
            }

            if clusterPresentation.progressPlacement == .belowPrimaryControl {
                ProgressView()
                    .controlSize(.mini)
                    .tint(OhiaColors.chipActiveBorder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }

        if let helpText = clusterPresentation.helpText {
            content
                .help(helpText)
                .accessibilityHint(helpText)
        } else {
            content
        }
    }

    /// Legend-style disc opening the cluster list popover — exactly the
    /// displayed clusters, multi-select toggled into the filter scope.
    private var clusterListDisc: some View {
        controlDisc(
            glyph: .native("list.bullet.circle.fill"),
            label: "Filter",
            help: clusterPresentation.helpText ?? "Filter the displayed clusters by name",
            isActive: clusterPresentation.snapshotInteractionsAreEnabled && clusterListPresented,
            isEnabled: clusterPresentation.snapshotInteractionsAreEnabled
        ) {
            clusterListPresented.toggle()
        }
        .popover(
            isPresented: clusterListPresentation,
            arrowEdge: onLeading ? .trailing : .leading
        ) {
            MeaningClusterListView(
                entries: clusterListEntries,
                scopeEngaged: activeClusterFilter != nil,
                onToggle: onToggleClusterInScope,
                onRowHover: onClusterRowHover,
                onClearAll: onClearClusterFilter
            )
            .onDisappear(perform: onClusterListClosed)
        }
    }

    /// Removable cluster-filter chip displayed in place of the slider while a
    /// cluster is in scope. Reads as the "filter chip" the user expects: an
    /// accent-tinted count pill with an inline ✕. The full (often long)
    /// cluster title stays out of the narrow column — it surfaces on hover via
    /// the `.help` tooltip and the rich cluster popup (`onClusterChipHover`).
    private func clusterFilterChip(_ filter: MeaningClusterFilterDescriptor) -> some View {
        VStack(spacing: 6) {
            Text("Cluster")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textSecondary)

            // Vertically stacked badge — cluster glyph over the live count.
            // The narrow column reads top-to-bottom instead of cramming a wide
            // horizontal pill; the clear control sits below the bubble.
            VStack(spacing: 6) {
                // Cluster glyph in the cluster's own accent — three connected
                // nodes, matching the rendered orb's tint so the badge reads as
                // "this cluster."
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(filter.tintColor)
                Text(filter.messageCount.map { "\($0)" } ?? "—")
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OhiaColors.chipActiveBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(filter.tintColor.opacity(0.5), lineWidth: 1)
            )

            Text("filtered")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(OhiaColors.textTertiary)

            // Clear control sits outside and below the bubble, in the ʻōhiʻa
            // stamen-yellow accent so it reads as the removable affordance.
            Button(action: onClearClusterFilter) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(OhiaColors.ohiaYellow)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Clear cluster filter")
            .accessibilityLabel("Clear cluster filter")
        }
        .help(filter.title)
        .onHover { onClusterChipHover($0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Cluster filter: \(filter.title), "
                + (filter.messageCount.map { "\($0) messages" } ?? "counting messages")
        )
    }

    private var clusterSliderControls: some View {
        VStack(spacing: 4) {
            Text("Clusters")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textSecondary)

            Text(clusterPresentation.snapshotInteractionsAreEnabled ? "\(clusterAvailableCount)" : "—")
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textPrimary)

            Text("\(clusterVisibleCount) visible")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .opacity(clusterPresentation.snapshotInteractionsAreEnabled ? 1 : 0)
                .accessibilityHidden(!clusterPresentation.snapshotInteractionsAreEnabled)

            // Vertical slider — 140pt long, matching Timeline's zoom
            // slider visual length. Two-frame trick: the inner frame is
            // the slider's intrinsic horizontal size; the rotation
            // turns it vertical; the outer frame reserves matching
            // vertical layout space.
            Slider(
                value: $clusterValue,
                in: clusterSliderRange,
                step: 1
            )
            .controlSize(.small)
            .tint(OhiaColors.chipActiveBorder)
            .frame(width: 140, height: 16)
            .rotationEffect(.degrees(-90))
            .frame(width: 16, height: 140)
            .padding(.top, 6)
            .disabled(!clusterPresentation.sliderIsEnabled || clusterAvailableCount == 0)
            .accessibilityLabel("Meaning cluster display limit")
            .accessibilityValue(clusterAccessibilityValue)
            .accessibilityHint(clusterPresentation.helpText ?? "")
        }
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder.opacity(0.6))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    /// Focused Meaning lock uses the same rail-hosted shortcut legend as the
    /// People focus rail, so the context summary pane can keep its header clean.
    private var lockedOverlayLegendDisc: some View {
        controlDisc(
            glyph: .native("questionmark.circle.fill"),
            label: "Legend",
            help: "Locked node shortcuts",
            isActive: true,
            isEnabled: !legendPresented
        ) {
            legendPresented.toggle()
        }
        .popover(
            isPresented: $legendPresented,
            arrowEdge: onLeading ? .trailing : .leading
        ) {
            LockedNodeOverlayLegendView()
                .frame(width: 440)
        }
    }

    /// Unfocused Meaning keeps the constellation-wide legend used by the
    /// other lens-level rails.
    private var constellationLegendDisc: some View {
        controlDisc(
            glyph: .native("questionmark.circle.fill"),
            label: "Legend",
            help: "Legend",
            isActive: true,
            isEnabled: !legendPresented
        ) {
            legendPresented.toggle()
        }
        .popover(
            isPresented: $legendPresented,
            arrowEdge: onLeading ? .trailing : .leading
        ) {
            ConstellationLegendView(
                hasSearch: hasSearch,
                hasCitations: hasCitations,
                hasSelection: hasSelection,
                hasNebulae: hasNebulae,
                hasFibers: hasFibers,
                showsClusterActions: true
            )
            .frame(width: 400)
        }
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

    private func beginRecenterCooldown() {
        recenterCooldownSeq &+= 1
        let mySeq = recenterCooldownSeq
        recenterCooldownActive = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if mySeq == recenterCooldownSeq {
                recenterCooldownActive = false
            }
        }
    }

    private var starburstCapsuleText: String? {
        if manualRefresh.state.isFailure { return manualRefresh.state.capsuleText }
        if let live = newStarNavigator.formationNoticeText { return live }
        return manualRefresh.state.capsuleText
    }

    private var starburstFailureKind: NewStarFormationNoticeView.FailureKind? {
        switch manualRefresh.state {
        case .transientFailure: return .transient
        case .authFailure:      return .auth
        case .idle, .searching, .newMail, .empty: return nil
        }
    }

    private var clusterSliderRange: ClosedRange<Double> {
        0 ... Double(max(1, clusterAvailableCount))
    }

    private var clusterListPresentation: Binding<Bool> {
        Binding(
            get: { clusterPresentation.snapshotInteractionsAreEnabled && clusterListPresented },
            set: { clusterListPresented = clusterPresentation.snapshotInteractionsAreEnabled && $0 }
        )
    }

    private var clusterAccessibilityValue: String {
        guard clusterPresentation.snapshotInteractionsAreEnabled else { return "Unavailable" }
        return clusterAvailableCount == 0
            ? "No clusters detected"
            : "\(clusterVisibleCount) of \(clusterAvailableCount) visible"
    }
}

private enum MeaningConfirmationActionMode {
    case confirm(UUID)
    case confirmed(UUID)
    case markNeeded(UUID)
    case disabled

    /// The confirmation state reads through the seal: the check appears only once
    /// the message is confirmed; the pending / mark-needed / disabled states show
    /// the bare seal. The dedicated Resolve disc owns the circle-check.
    var glyph: ActionDiscGlyph {
        switch self {
        case .confirmed: return .knockout("checkmark.seal.fill")
        case .confirm, .markNeeded, .disabled: return .knockout("seal.fill")
        }
    }

    /// Fixed label across every state — the disc names the confirmation axis and
    /// the glyph carries the state.
    var label: String { "Confirmed" }

    var isActive: Bool {
        switch self {
        case .confirmed:
            return true
        case .confirm, .markNeeded, .disabled:
            return false
        }
    }

    var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }
}

/// Snapshot of the engaged meaning-cluster filter the column renders in place
/// of the cluster-display slider. Built by `ConstellationModeView` from the
/// live `VectorFilter.clusterIds` scope.
struct MeaningClusterFilterDescriptor: Equatable {
    /// The single focused cluster, or `nil` when more than one cluster is in
    /// scope (the chip then shows a generic "N clusters" title).
    let clusterId: Int64?
    /// Full cluster title — available on hover (tooltip / popup), not inline.
    let title: String
    /// Live count of messages in scope, already respecting every other
    /// filter; `nil` while the first count for a new scope is in flight.
    let messageCount: Int?
    /// Meaning-lens accent, matching the rendered cluster orb.
    let tint: SIMD3<Float>

    var tintColor: Color {
        Color(red: Double(tint.x), green: Double(tint.y), blue: Double(tint.z))
    }
}

/// One row in the cluster list popover: a cluster's semantic title, its
/// rendered ramp tint, its visible message count in the current scope, and
/// whether it is currently part of the filter scope.
struct MeaningClusterListEntry: Identifiable, Equatable {
    let clusterId: Int64
    let title: String
    let visibleMessageCount: Int
    let tint: SIMD3<Float>
    let isActive: Bool

    var id: Int64 { clusterId }

    var tintColor: Color {
        Color(red: Double(tint.x), green: Double(tint.y), blue: Double(tint.z))
    }
}

/// Cluster filter popover, in the ConstellationTopBar category-filter
/// idiom: an uppercase tracked eyebrow header over left-edge square
/// checkboxes (`MenuRowCheckbox`, the same chrome the toolbar's toggle
/// menus paint), one row per displayed cluster. Checking a row scopes
/// the scene to that cluster (multi-select), letting the user inspect
/// one cluster's semantically linked nodes without the clutter of the
/// rest of the scene. The hue dot in the row's icon slot matches the
/// rendered gas exactly, so the list doubles as a legend for the scene's
/// colors. A footer Clear row drops the whole scope.
struct MeaningClusterListView: View {
    let entries: [MeaningClusterListEntry]
    /// True while a cluster filter is applied. Keeps the Clear affordance
    /// enabled even when the scope holds only stale ids from a superseded
    /// detection run (no listed row would show as active).
    let scopeEngaged: Bool
    let onToggle: (Int64) -> Void
    let onRowHover: (Int64, Bool) -> Void
    let onClearAll: () -> Void

    private var canClear: Bool { scopeEngaged || entries.contains(where: \.isActive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Displayed clusters")
                .font(.system(size: 9.5))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(OhiaColors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        clusterRow(entry)
                    }
                }
            }
            .frame(maxHeight: 360)

            clearRow
        }
        .padding(.bottom, 4)
        .frame(width: 300)
    }

    /// One cluster row: left-edge checkbox, hue dot, title with inline
    /// count. Mirrors the toolbar's `MenuRow` chrome (spacing, padding,
    /// fonts) and adds the scene-hover bridge.
    private func clusterRow(_ entry: MeaningClusterListEntry) -> some View {
        MenuRow(
            name: "\(entry.title) (\(entry.visibleMessageCount.formatted(.number)))",
            isChecked: entry.isActive,
            iconWidth: 12,
            action: { onToggle(entry.clusterId) },
            icon: {
                Circle()
                    .fill(entry.tintColor)
                    .frame(width: 9, height: 9)
            }
        )
        .onHover { onRowHover(entry.clusterId, $0) }
        .help(entry.title)
        .accessibilityLabel(
            "\(entry.title), \(entry.visibleMessageCount) visible messages"
                + (entry.isActive ? ", in scope" : "")
        )
    }

    /// Footer Clear action, matching the category filter's Clear-all row:
    /// hairline separator, `xmark.circle`, quiet when it would be a no-op.
    private var clearRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
                .padding(.top, 4)
            Button(action: onClearAll) {
                HStack(spacing: 9) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(clearForeground)
                        .frame(width: 13, height: 13)
                    Text("Clear scope")
                        .font(.system(size: 11.5))
                        .foregroundStyle(clearForeground)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canClear)
            .help("Clear the cluster scope")
            .accessibilityLabel("Clear cluster scope")
        }
    }

    private var clearForeground: Color {
        canClear ? OhiaColors.textSecondary : OhiaColors.textTertiary
    }
}
