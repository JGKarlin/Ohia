// NewStarFormationNoticeView.swift
// Top-right Constellation notice for newly-arrived message stars and the
// manual IMAP-refresh button. State precedence (highest first):
//   1. manual arrival — exact IDs found by a user-initiated beacon check
//   2. searching      — driven by isSearching (manual refresh in flight)
// Plus a transient capsule message (formationText) for live formation. Manual
// new-mail discovery suppresses its early "forming" copy and loops Nova Fade
// until the unified arrival completes. Failures stay inside the Beacon: one
// red pulse, then a solid red latch whose state-specific copy appears on hover.

import SwiftUI

enum NewStarFormationMotion: Equatable {
    case novaFade
    case collapse
    case idle
}

struct NewStarFormationAnimationLatch {
    private(set) var isActive = false
    private(set) var startedAt: Date?
    private var pendingMessageIDs: Set<UUID> = []

    static func isManualArrivalSignal(
        formationText: String?,
        isSearching: Bool,
        hasFailure: Bool,
        formingCount: Int
    ) -> Bool {
        formationText != nil
            && !isSearching
            && !hasFailure
            && formingCount == 0
    }

    mutating func synchronizePendingMessageIDs(
        _ messageIDs: Set<UUID>,
        startsManualAnimation: Bool = false,
        now: Date = .now
    ) {
        let wasEmpty = pendingMessageIDs.isEmpty
        pendingMessageIDs = messageIDs
        if pendingMessageIDs.isEmpty {
            isActive = false
            startedAt = nil
        } else if startsManualAnimation && wasEmpty {
            isActive = true
            startedAt = now
        }
    }

    func visibleFormationText(
        _ formationText: String?,
        manualArrivalDetected: Bool,
        hasFailure: Bool = false
    ) -> String? {
        if hasFailure { return nil }
        return manualArrivalDetected || isActive ? nil : formationText
    }

    func motion(collapseActive: Bool) -> NewStarFormationMotion {
        if isActive { return .novaFade }
        return collapseActive ? .collapse : .idle
    }
}

/// Commands on the Beacon's right-click menu. The menu exists only while new
/// mail is badged.
enum BeaconArrivalMenuCommand: Equatable, Sendable {
    case goToNewest
    case goToOldest
    case clear
    case clearAndMarkRead
    case clearAndMarkUnread
}

/// A menu command plus the exact badged arrivals the menu described when it
/// was built. Commands act only on these, so mail that arrives while the
/// menu is open is never cleared or marked read by a choice made before the
/// person saw it.
struct BeaconArrivalMenuRequest: Equatable, Sendable {
    let command: BeaconArrivalMenuCommand
    /// Ledger message IDs in badge order.
    let arrivalIds: [String]
}

/// Copy and targeting rules for the Beacon's right-click menu, kept apart
/// from the view so they are testable.
enum BeaconArrivalMenuPolicy {
    /// The arrivals a command may act on: those the menu showed that are
    /// still badged when the command runs, in the menu's order.
    static func stillBadged(
        capturedArrivalIds: [String],
        currentlyBadgedIds: [String]
    ) -> [String] {
        let current = Set(currentlyBadgedIds)
        return capturedArrivalIds.filter { current.contains($0) }
    }

    /// Orders Go To candidates oldest first by received date. After a
    /// successful store lookup, an arrival that still has no date no longer
    /// exists, so it is dropped instead of being treated as the newest.
    /// Without a lookup, undated arrivals keep the click path's order: after
    /// every dated arrival, in badge order.
    static func oldestFirstTargets(
        arrivalIds: [String],
        receivedAtByMessageId: [String: Date],
        dropsUndated: Bool
    ) -> [String] {
        let candidates = dropsUndated
            ? arrivalIds.filter { receivedAtByMessageId[$0] != nil }
            : arrivalIds
        return StarburstArrivalOrderingPolicy.oldestFirst(
            unvisitedArrivalIds: candidates,
            receivedAtByMessageId: receivedAtByMessageId
        )
    }

    /// Section header naming how many emails the menu acts on, or nil when
    /// nothing is badged and the menu must not appear.
    static func headerTitle(badgeCount: Int) -> String? {
        guard badgeCount > 0 else { return nil }
        return badgeCount == 1 ? "1 New Email" : "\(badgeCount) New Emails"
    }

    /// With one badged email, newest and oldest are the same message, so the
    /// menu offers a single Go to Email item instead of two identical ones.
    static func offersNewestAndOldest(badgeCount: Int) -> Bool {
        badgeCount > 1
    }

    /// The badged arrival a Go To command opens; nil for the Clear commands.
    static func navigationTarget(
        for command: BeaconArrivalMenuCommand,
        oldestFirstArrivalIds: [String]
    ) -> String? {
        switch command {
        case .goToOldest: oldestFirstArrivalIds.first
        case .goToNewest: oldestFirstArrivalIds.last
        case .clear, .clearAndMarkRead, .clearAndMarkUnread: nil
        }
    }

    /// The read state a Clear command applies after clearing the badge; nil
    /// when the command leaves read state alone.
    static func readStateAfterClearing(for command: BeaconArrivalMenuCommand) -> Bool? {
        switch command {
        case .clearAndMarkRead: true
        case .clearAndMarkUnread: false
        case .goToNewest, .goToOldest, .clear: nil
        }
    }
}

private struct NewStarFormationPresentationFingerprint: Equatable {
    let visibleText: String?
    let manualArrivalDetected: Bool
}

struct NewStarFormationNoticeView: View {
    enum FailureKind: Equatable, Sendable {
        case transient
        case auth
    }

    let formingCount: Int
    let badgeCount: Int
    let formationText: String?
    let isNavigable: Bool
    let isSearching: Bool
    let failureKind: FailureKind?
    let ackFlickerSeq: Int
    /// Fires the no-new-mail collapsing-star motion. Bumped by the coordinator
    /// each time a manual check lands on the empty outcome; the starburst
    /// implodes once, entirely inside the icon — no text capsule accompanies it.
    let emptySignalSeq: Int
    let action: () -> Void
    /// Runs a right-click menu command. The menu only appears while new mail
    /// is badged.
    let menuAction: (BeaconArrivalMenuRequest) -> Void

    @State private var flickerScale: CGFloat = 1.0
    @State private var failurePulseScale: CGFloat = 1.0
    /// The last `emptySignalSeq` the collapse played for. Compared against the
    /// incoming `emptySignalSeq` so a bump is always seen — never coalesced
    /// away. nil until the first sequence value is observed.
    @State private var playedCollapseSeq: Int? = nil
    /// When the active collapse began. nil at rest. A non-nil value switches the
    /// glyph to a TimelineView that reads elapsed time each frame, so the fold
    /// is driven by wall-clock time — guaranteed to advance every frame for the
    /// full 1.1s, independent of how the trigger update was batched.
    @State private var collapseStart: Date? = nil
    /// Internal mirror of `formationText`. We assign to this inside an
    /// explicit `withAnimation { ... }` block so the bloom transition
    /// always fires with the slow spring — relying on
    /// `.animation(_:value:)` or `AnyTransition.animation(_:)` is
    /// unreliable when the parent view's state change isn't itself
    /// wrapped in an animation context.
    @State private var displayedFormationText: String? = nil
    /// Exact IDs discovered by a user-initiated beacon check. The request
    /// survives lens remounts; intersecting it with the canonical arrival
    /// ledger ends the animation only after those messages complete their
    /// unified placement, badge, sound, and notification.
    @State private var manualArrivalRequest = ManualRefreshArrivalAnimationRequest.shared
    @State private var arrivalAnimationLatch = NewStarFormationAnimationLatch()

    private var isForming: Bool { formingCount > 0 }
    private var hasBadge: Bool { badgeCount > 0 }
    /// "Active" means the icon illuminates. Forming/ready states flip it
    /// bright; the searching state has its own brighter-yellow pulse driven
    /// by a TimelineView (see `sunburstButton`) and is intentionally not
    /// folded into `isActive` so the steady-state forming/ready chrome
    /// (capsule fill, ring opacity) doesn't latch on during a refresh sweep.
    private var isActive: Bool { isForming || hasBadge }

    private var displayCount: String {
        badgeCount > 99 ? "99+" : "\(badgeCount)"
    }

    private var hasDisplayedText: Bool { displayedFormationText != nil }

    private var pendingManualArrivalMessageIDs: Set<UUID> {
        manualArrivalRequest.pendingMessageIDs(
            in: NewMailArrivalLedger.shared.pendingArrivalMessageIDs
        )
    }

    private var formationPresentationFingerprint: NewStarFormationPresentationFingerprint {
        let manualArrivalDetected = NewStarFormationAnimationLatch.isManualArrivalSignal(
            formationText: formationText,
            isSearching: isSearching,
            hasFailure: failureKind != nil,
            formingCount: formingCount
        )
        return NewStarFormationPresentationFingerprint(
            visibleText: arrivalAnimationLatch.visibleFormationText(
                formationText,
                manualArrivalDetected: manualArrivalDetected,
                hasFailure: failureKind != nil
            ),
            manualArrivalDetected: manualArrivalDetected
        )
    }

    private var capsuleBorderColor: Color {
        if !hasDisplayedText { return .clear }
        return failureKind != nil
            ? OhiaColors.accentOrange.opacity(0.85)
            : OhiaColors.glassBorder
    }

    private var capsuleFillColor: Color {
        if !hasDisplayedText { return .clear }
        return failureKind != nil
            ? OhiaColors.accentOrange.opacity(0.10)
            : OhiaColors.surface(0.10)
    }

    var body: some View {
        // Shared-capsule layout (matches the early commits 559c3b6 / ccf5c5c):
        // the formation text and the starburst button live inside one capsule
        // background, which expands leftward when the message appears and
        // collapses to a clear chrome when it disappears. The button is the
        // trailing item of an HStack right-anchored in its parent, so its
        // screen position stays stable across the expand/collapse — same
        // visual goal b41042a's sibling-pill layout was reaching for, but
        // achieved with one capsule instead of two.
        //
        // Chrome (padding, fill, border, shadow) is keyed off the local
        // `displayedFormationText` mirror — the same mirror the conditional
        // text uses — so the capsule's grow/shrink animates in sync with the
        // text's bloom transition rather than snapping ahead of it.
        HStack(spacing: 9) {
            if let displayedFormationText {
                Text(displayedFormationText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // Emerge from the starburst: scale anchored at the
                    // trailing edge (which sits flush against the button) so
                    // the text appears to bloom out of the circle.
                    .transition(
                        .scale(scale: 0.001, anchor: .trailing)
                            .combined(with: .opacity)
                    )
            }

            beaconButtonWithHelp
        }
        .padding(.leading, hasDisplayedText ? 12 : 0)
        .padding(.trailing, hasDisplayedText ? 6 : 0)
        .padding(.vertical, hasDisplayedText ? 5 : 0)
        .background(
            Capsule(style: .continuous).fill(capsuleFillColor)
        )
        .overlay {
            Capsule(style: .continuous).strokeBorder(capsuleBorderColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hasDisplayedText ? 0.25 : 0), radius: 10, x: 0, y: 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isActive)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: formingCount)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: badgeCount)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isSearching)
        .animation(.easeInOut(duration: 0.32), value: failureKind)
        .onAppear {
            // Initial sync — no animation, the capsule should be in its
            // settled state on first display.
            arrivalAnimationLatch.synchronizePendingMessageIDs(
                pendingManualArrivalMessageIDs,
                startsManualAnimation: true
            )
            displayedFormationText = formationPresentationFingerprint.visibleText
        }
        .onChange(of: formationPresentationFingerprint) { _, newValue in
            // Drive the bloom transition explicitly: the parent
            // (ConstellationModeView) updates `formationText` via
            // observable state without wrapping the change in
            // `withAnimation`, so the transition would otherwise have no
            // animation context and snap. Mirroring into local @State and
            // assigning inside `withAnimation` guarantees the spring.
            withAnimation(.spring(response: 0.65, dampingFraction: 0.78)) {
                displayedFormationText = newValue.visibleText
            }
        }
        .onChange(of: pendingManualArrivalMessageIDs) { _, messageIDs in
            arrivalAnimationLatch.synchronizePendingMessageIDs(
                messageIDs,
                startsManualAnimation: true
            )
            withAnimation(.spring(response: 0.65, dampingFraction: 0.78)) {
                displayedFormationText = formationPresentationFingerprint.visibleText
            }
        }
        .onChange(of: ackFlickerSeq) { _, _ in
            // 0.95× pulse on click-while-searching — quick contract, snap back.
            withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
                flickerScale = 0.95
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65).delay(0.08)) {
                flickerScale = 1.0
            }
        }
        .onChange(of: failureKind) { oldValue, newValue in
            if newValue == nil {
                withAnimation(.easeOut(duration: 0.18)) {
                    failurePulseScale = 1.0
                }
                return
            }
            guard oldValue == nil else { return }
            failurePulseScale = 1.0
            withAnimation(.easeOut(duration: 0.28)) {
                failurePulseScale = 1.18
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58).delay(0.28)) {
                failurePulseScale = 1.0
            }
        }
        .onChange(of: emptySignalSeq) { _, newValue in
            // Fire the collapse the instant the coordinator reports an empty
            // result. Stamping a start date and letting the TimelineView read
            // elapsed time each frame makes the fold deterministic — it cannot
            // be coalesced away the way a one-shot withAnimation on @State can.
            guard newValue != playedCollapseSeq else { return }
            playedCollapseSeq = newValue
            collapseStart = Date.now
        }
        .onAppear {
            // First mount: adopt the current seq as the baseline without
            // firing, so a result that landed before this instance appeared
            // doesn't replay a stale collapse. Later remounts keep the played
            // seq, so a genuine new empty still fires via the onChange above.
            if playedCollapseSeq == nil {
                playedCollapseSeq = emptySignalSeq
            }
        }
    }

    private var beaconButton: some View {
        Button(action: action) {
            sunburstButton
        }
        .buttonStyle(.plain)
        // Empty menu content deactivates the context menu, so right-click
        // does nothing until mail is badged.
        .contextMenu { arrivalMenu }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var arrivalMenu: some View {
        // The menu names and acts on exactly these arrivals; see
        // `BeaconArrivalMenuRequest`.
        let arrivalIds = NewMailArrivalLedger.shared.unvisitedArrivalIds
        if let headerTitle = BeaconArrivalMenuPolicy.headerTitle(badgeCount: arrivalIds.count) {
            Section(headerTitle) {
                if BeaconArrivalMenuPolicy.offersNewestAndOldest(badgeCount: arrivalIds.count) {
                    Button("Go to Newest") { requestMenuCommand(.goToNewest, arrivalIds) }
                    Button("Go to Oldest") { requestMenuCommand(.goToOldest, arrivalIds) }
                } else {
                    Button("Go to Email") { requestMenuCommand(.goToOldest, arrivalIds) }
                }
            }
            Section {
                Button("Clear") { requestMenuCommand(.clear, arrivalIds) }
                Button("Clear and Mark as Read") { requestMenuCommand(.clearAndMarkRead, arrivalIds) }
                Button("Clear and Mark as Unread") { requestMenuCommand(.clearAndMarkUnread, arrivalIds) }
            }
        }
    }

    private func requestMenuCommand(_ command: BeaconArrivalMenuCommand, _ arrivalIds: [String]) {
        menuAction(BeaconArrivalMenuRequest(command: command, arrivalIds: arrivalIds))
    }

    @ViewBuilder
    private var beaconButtonWithHelp: some View {
        if let failureHoverText {
            beaconButton.help(failureHoverText)
        } else {
            beaconButton
        }
    }

    private var failureHoverText: String? {
        failureKind == nil ? nil : formationText
    }

    /// Total wall-clock duration of the collapse motion.
    private static let collapseDuration: TimeInterval = 1.1
    /// Exact outcome duration of Nova Fade in Beacon Empty Signals.
    private static let novaFadeDuration: TimeInterval = 0.9

    /// Collapse progress 0…1 from elapsed wall-clock time, or nil at rest.
    /// Read from a TimelineView each frame so it advances deterministically.
    private func collapseProgress(now: Date) -> CGFloat? {
        guard let start = collapseStart else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed < Self.collapseDuration else { return nil }
        return CGFloat(elapsed / Self.collapseDuration)
    }

    /// Repeats Nova Fade from its first frame while the exact messages found
    /// by a user-initiated beacon check remain embargoed or staged.
    private func novaFadeProgress(now: Date) -> Double? {
        guard
            arrivalAnimationLatch.isActive,
            let start = arrivalAnimationLatch.startedAt
        else {
            return nil
        }
        let elapsed = max(0, now.timeIntervalSince(start))
        return elapsed.truncatingRemainder(dividingBy: Self.novaFadeDuration)
            / Self.novaFadeDuration
    }

    // MARK: Collapsing-star (no-new-mail) motion

    /// Depth of the collapse for a given progress: 0 at both ends, a held
    /// plateau at the trough. The plateau (not a bare sine peak) keeps the fold
    /// fully collapsed for a beat so it reads as a deliberate implosion, not a
    /// flicker — the same held trough the sandbox tile shows.
    private func collapseDepth(progress p: CGFloat) -> CGFloat {
        guard p > 0, p < 1 else { return 0 }
        // Ramp in 0→0.3, hold 0.3→0.7, ramp out 0.7→1. Smoothstep the ramps.
        if p < 0.3 {
            let x = p / 0.3
            return x * x * (3 - 2 * x)
        } else if p > 0.7 {
            let x = (1 - p) / 0.3
            return x * x * (3 - 2 * x)
        } else {
            return 1
        }
    }

    @ViewBuilder
    private var sunburstButton: some View {
        // While the no-new-mail collapse is active, drive the whole emblem off
        // a per-frame wall-clock TimelineView so the fold advances every frame
        // for the full duration — the deterministic fix for the collapse never
        // appearing when the trigger update was coalesced. At rest it's static.
        if failureKind != nil {
            sunburstButtonBody(collapseProgress: nil, novaFadeProgress: nil)
        } else {
            switch arrivalAnimationLatch.motion(collapseActive: collapseStart != nil) {
            case .novaFade:
                TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
                    sunburstButtonBody(
                        collapseProgress: nil,
                        novaFadeProgress: novaFadeProgress(now: timeline.date)
                    )
                }
            case .collapse:
                TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
                    sunburstButtonBody(
                        collapseProgress: collapseProgress(now: timeline.date),
                        novaFadeProgress: nil
                    )
                }
            case .idle:
                sunburstButtonBody(collapseProgress: nil, novaFadeProgress: nil)
            }
        }
    }

    private func sunburstButtonBody(
        collapseProgress: CGFloat?,
        novaFadeProgress: Double?
    ) -> some View {
        ZStack {
            // Searching overlay — orbiting probe. A faint guide ring + one
            // bright dot completing a full orbit every 1.4s. Reads as
            // "scanning / telescope sweep."
            if isSearching {
                ZStack {
                    Circle()
                        .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.18), lineWidth: 1)
                        .scaleEffect(1.18)

                    TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let degrees = (t.truncatingRemainder(dividingBy: 1.4) / 1.4) * 360
                        Circle()
                            .fill(OhiaColors.chipActiveBorder.opacity(0.95))
                            .frame(width: 4, height: 4)
                            .shadow(color: OhiaColors.chipActiveBorder.opacity(0.7), radius: 3)
                            .offset(y: -19 * 1.18)
                            .rotationEffect(.degrees(degrees))
                    }
                }
                .allowsHitTesting(false)
                // Fade the orbiting probe (guide ring + moon dot) in and out
                // independently of the rest of the sunburst chrome — the
                // sun.max icon stays put, only the search overlay breathes.
                .transition(
                    .opacity.animation(.easeInOut(duration: 0.55))
                )
            }

            // Nova Fade — copied from the Beacon Empty Signals sandbox and
            // replayed as a continuous 0.9s loop while discovered mail moves
            // through the pipeline toward its unified arrival moment.
            if let novaFadeProgress {
                let eased = 1 - pow(1 - novaFadeProgress, 2)
                Circle()
                    .strokeBorder(
                        OhiaColors.chipActiveBorder.opacity(0.55 * (1 - novaFadeProgress)),
                        lineWidth: 2.5
                    )
                    .scaleEffect(1 + eased * 0.9)
                    .allowsHitTesting(false)
            }

            // Colored fill only when there's something to show (forming or
            // badged) — matches the `chipActiveBackground` fill every other
            // lit `LensActionDisc` takes on for its active state. Idle stays
            // on the neutral dim wash so "nothing new" keeps reading as such.
            Circle()
                .fill(
                    failureKind != nil
                        ? OhiaColors.ohiaRed.opacity(0.18)
                        : (isActive ? OhiaColors.chipActiveBackground : OhiaColors.surface(0.16))
                )

            // Searching → use the filled glyph and modulate its opacity
            // sinusoidally between a dim base and full brightness on the
            // saturated ohia yellow (`chipActiveForeground`). Period 1.4s
            // matches the orbiting probe so the moon and the pulse share
            // one rhythm rather than beating against each other.
            // Otherwise: badged → full yellow; forming-without-badge → mid
            // yellow; idle → muted. A no-new-mail collapse rides on top: the
            // glyph crossfades filled → outline and dims as the star folds in.
            if failureKind != nil {
                ActionDiscGlyphView(
                    glyph: .knockout("sun.max.fill"),
                    tint: OhiaColors.ohiaRed,
                    size: 26
                )
            } else if isSearching {
                TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 2 * .pi / 1.4) + 1) / 2  // 0...1
                    let opacity = 0.55 + phase * 0.45             // 0.55...1.0
                    ActionDiscGlyphView(
                        glyph: .knockout("sun.max.fill"),
                        tint: OhiaColors.chipActiveForeground.opacity(opacity),
                        size: 26
                    )
                }
            } else if let novaFadeProgress {
                let opacity = 0.95 - novaFadeSmooth(novaFadeProgress) * 0.55
                ActionDiscGlyphView(
                    glyph: .knockout("sun.max.fill"),
                    tint: OhiaColors.chipActiveForeground.opacity(max(0.35, opacity)),
                    size: 26
                )
                .scaleEffect(novaFadeGlyphScale(progress: novaFadeProgress))
            } else {
                ActionDiscGlyphView(
                    glyph: .knockout(starGlyphName(progress: collapseProgress)),
                    tint: idleGlyphTint.opacity(glyphOpacity(progress: collapseProgress)),
                    size: 26
                )
            }
        }
        .frame(width: 38, height: 38)
        .scaleEffect(
            flickerScale
                * failurePulseScale
                * collapseScale(progress: collapseProgress)
        )
        .overlay {
            Circle()
                .strokeBorder(
                    (failureKind != nil ? OhiaColors.ohiaRed : OhiaColors.chipActiveBorder)
                        .opacity(
                            failureKind != nil
                                ? 0.95
                                : ringOpacity(
                                    collapseProgress: collapseProgress,
                                    novaFadeProgress: novaFadeProgress
                                )
                        ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .topTrailing) {
            if hasBadge {
                Text(displayCount)
                    .font(.system(size: badgeCount > 99 ? 8 : 10.5, weight: .bold))
                    .foregroundStyle(Color.black)
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                    .padding(.horizontal, displayCount.count > 1 ? 4 : 3)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OhiaColors.chipActiveBorder.opacity(0.95))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(OhiaColors.surface(0.78), lineWidth: 1)
                    }
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Circle())
    }

    /// The starburst scale during the collapse — folds all the way to zero at
    /// the trough so the icon vanishes, then regrows. Identity (1) at rest.
    private func collapseScale(progress: CGFloat?) -> CGFloat {
        guard let progress else { return 1 }
        return 1 - collapseDepth(progress: progress)
    }

    /// Glyph opacity during the collapse — dims toward the trough, then
    /// recovers only part-way so the resting read is the dim idle outline.
    private func glyphOpacity(progress: CGFloat?) -> Double {
        guard let progress else { return 1 }
        return 0.72 - Double(collapseDepth(progress: progress)) * 0.40
    }

    /// Glyph choice across the whole control: once the collapse reaches its
    /// trough the outline takes over and holds through recovery into rest;
    /// otherwise the usual active/idle rule applies.
    private func starGlyphName(progress: CGFloat?) -> String {
        if let progress, progress >= 0.3 { return "sun.max" }
        return isActive ? "sun.max.fill" : "sun.max"
    }

    private var idleGlyphTint: Color {
        if hasBadge {
            return OhiaColors.chipActiveForeground
        }
        if isActive {
            return OhiaColors.chipActiveBorder.opacity(0.82)
        }
        return OhiaColors.chipActiveForeground.opacity(0.72)
    }

    private func ringOpacity(
        collapseProgress: CGFloat?,
        novaFadeProgress: Double?
    ) -> Double {
        if let novaFadeProgress {
            return 0.78 - novaFadeSmooth(novaFadeProgress) * 0.4
        }
        let base = isActive ? 0.78 : 0.56
        // Dip the ring with the collapsing star so the whole emblem folds in.
        guard let collapseProgress else { return base }
        return base - Double(collapseDepth(progress: collapseProgress)) * 0.3
    }

    private func novaFadeSmooth(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    /// Contracts the inner starburst once per Nova Fade ring, then restores it
    /// to full size as the ring finishes expanding. Squaring the sine keeps the
    /// looping endpoints smooth while reaching a visible 70% trough mid-cycle.
    private func novaFadeGlyphScale(progress: Double) -> CGFloat {
        let pulse = sin(.pi * progress)
        return 1 - CGFloat(pulse * pulse) * 0.30
    }

    private var accessibilityLabel: String {
        if failureKind != nil {
            return formationText ?? "Mailbox check failed"
        }
        if isSearching { return "Checking for new nodes" }
        if arrivalAnimationLatch.isActive { return "Preparing new mail" }
        guard isActive else { return "Check for new nodes" }
        if isForming, hasBadge {
            return "\(formingCount) forming, \(badgeCount) ready new nodes"
        }
        if isForming {
            return formingCount == 1 ? "One new node forming" : "\(formingCount) new nodes forming"
        }
        return badgeCount == 1 ? "One new node ready" : "\(badgeCount) new nodes ready"
    }

    private var accessibilityValue: String {
        if let failureKind {
            return failureKind == .auth ? "Sign in again to recheck" : "Tap to retry"
        }
        if isSearching { return "Searching" }
        if arrivalAnimationLatch.isActive { return "Waiting for arrival" }
        if isForming, hasBadge {
            return "\(formingCount) forming, \(badgeCount) ready"
        }
        if isForming {
            return "\(formingCount) forming"
        }
        if hasBadge {
            return "\(badgeCount) ready"
        }
        return "Idle"
    }
}
