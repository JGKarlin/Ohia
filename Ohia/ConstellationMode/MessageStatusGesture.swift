import AppKit
import Foundation
import CoreGraphics
import Observation
import SwiftUI

// Action-response gestures for message status chrome — the production form of
// the motions prototyped in `Previews/DesignSandbox1.swift`.
//
// When the user triggers a message action (from a Front Page card's hover
// cluster or the right control column), the real mutation round-trips through
// the dispatcher → repository → SwiftData and the page only updates when the
// rebuilt `FrontPageSnapshot` lands. That async gap is an unavoidable delay.
// Rather than lengthen it, a gesture fires the instant the control is tapped and
// plays OVER the in-flight work, so the user gets an immediate, action-typed
// response while the real mutation lands underneath.
//
// Each action has a DISTINCT motion sharing one timing spine:
//   • In-place (reply / confirm and their needed-markers, flag) animate the
//     card's REAL status-cluster glyph — the glyph that already encodes that
//     state — via `MessageStatusMark`'s gesture hook.
//   • Departing (delete / resolve / ignore / send-to-Composer) transform the
//     whole card into one of four real astrophysical phenomena, each a single
//     continuous body that never fragments into disconnected shards: delete
//     falls into a Black hole (spacetime lensing, an accretion disk, redshift
//     to black, one horizon-crossing flash — no bounce); resolve mirrors the
//     same gravitational gathering into a Protostar's ignition flash instead;
//     ignore cools along a real Blackbody colour-temperature curve to a dim
//     ember; send-to-Composer launches a Comet — the card collapses into a
//     nucleus trailing dust and ion tails and fires at the viewer. The
//     snapshot then drops the card and the row reflows.
//
// The coordinator below owns the transient per-message gesture state. It is
// started when an action is dispatched and cleared when the refreshed snapshot
// reflects the change (or after a safety window if the mutation never lands).

// MARK: - Action

/// The action a status gesture expresses. Mirrors the Front Page action set.
enum MessageStatusGestureAction: Equatable, Sendable {
    case markReplied
    case markConfirmed
    case replyNeeded
    case confirmationNeeded
    /// `raising` is captured at trigger time (the inverse of the message's
    /// current flagged state) so the motion direction is stable across commit.
    case flag(raising: Bool)
    /// The card is swallowed by a forming Black hole: spacetime warps and
    /// lenses around it, an accretion disk spins up and rotates, the
    /// infalling material redshifts toward black, and a single flash marks
    /// the event-horizon crossing — one-way, no bounce-back.
    case delete
    /// The mirror of delete: the same gravitational gathering, but a
    /// Protostar ignites instead of a horizon closing — creation, not
    /// destruction. Fusion catches in a bright flash and the card settles
    /// into a small, steady point of new light.
    case resolve
    /// The message and future semantic matches are ignored. It departs by
    /// Blackbody cooling — the card's surface cools continuously along a
    /// real stellar colour-temperature curve to a dim ember — rather than
    /// the Black hole / Protostar delete / resolve play.
    case ignore
    /// The user queued this message into the Composer. Like delete / resolve
    /// it removes the card from the feed, but instead of imploding to a core
    /// its box shape collapses into a small comet nucleus, which then fires
    /// straight at the viewer trailing separated dust and ion tails,
    /// foreshortened, growing as if flying directly at them, standing in for
    /// the Composer window opening.
    case sentToComposer

    /// Departing actions remove the card from the page; the rest transform the
    /// card's chrome in place.
    var isDeparting: Bool {
        switch self {
        case .delete, .resolve, .ignore, .sentToComposer: return true
        default: return false
        }
    }

    var isFlag: Bool {
        if case .flag = self { return true }
        return false
    }

    /// The obligation state this action settles the glyph to (optimistically
    /// shown for the gesture's duration). `nil` for flag / departing actions,
    /// which do not drive the obligation glyph.
    var targetObligation: MessageStatusActionState? {
        switch self {
        case .markReplied: return .replied
        case .replyNeeded: return .pendingReply
        case .markConfirmed: return .confirmed
        case .confirmationNeeded: return .needsConfirmation
        case .flag, .delete, .resolve, .ignore, .sentToComposer: return nil
        }
    }

    /// Delete, resolve, ignore, and send-to-Composer each play their own
    /// centred departing overlay (Black hole / Protostar / Blackbody cooling
    /// / the launch Comet); every other action animates the in-place status
    /// glyph via the mark.
    var usesDepartingOverlay: Bool { isDeparting }
}

// MARK: - Gesture descriptor + timing

/// One active gesture: which action, and when it began. The floor is the minimum
/// time the motion plays before it can settle.
struct MessageStatusGesture: Equatable, Sendable {
    let action: MessageStatusGestureAction
    let start: Date
    var floor: Double = MessageStatusGesturePhase.defaultFloor
    /// Optional tint override — the send-to-Composer comet is always passed
    /// the fixed Ohia yellow accent (not the account colour the Metal lenses'
    /// comet carries), so it reads as the app's own send confirmation rather
    /// than a per-account hue. Nil for every other gesture (they derive their
    /// tint from the action).
    var tintOverride: Color? = nil
    var composerDeparture: ComposerCardDeparture? = nil

    func phase(now: Date) -> MessageStatusGesturePhase {
        MessageStatusGesturePhase(elapsed: max(0, now.timeIntervalSince(start)), floor: floor)
    }
}

/// The shared timing spine every gesture reads, derived purely from elapsed time
/// so it survives ancestor `.animation(_:value:)` modifiers (the same reason the
/// Front Page glisten uses `TimelineView`). Production form is floor-based: the
/// motion completes by `floor` and then holds (breathing) until the coordinator
/// clears the gesture when the snapshot catches up.
struct MessageStatusGesturePhase: Equatable, Sendable {
    let elapsed: Double
    let floor: Double

    static let defaultFloor: Double = 0.45
    /// Departing actions play the grander teardown, which wants a longer
    /// motion span than the in-place glyph gestures. Ignore / send-to-Composer
    /// use this shared floor directly; delete and resolve each get their own
    /// longer floor below.
    static let departingFloor: Double = 0.9
    /// Delete's Black hole collapse alone plays longer than the other three
    /// departing phenomena: the infall needs enough visible time to read as
    /// a gradually-accelerating pull into the horizon rather than a near-
    /// instant snap that reads as a flash. See `begin(_:for:now:tintOverride:)`.
    static let blackHoleFloor: Double = 1.6
    /// Resolve's Protostar ignition is built to mirror Black hole's rhythm
    /// (gather → payoff → settle, see `ProtostarDepartingField`'s doc
    /// comment) and needs the same longer span to read that way rather than
    /// racing through gather-and-ignite in the time the snappier ignore /
    /// send-to-Composer motions get. See `begin(_:for:now:tintOverride:)`.
    static let protostarFloor: Double = 1.6
    static let onset: Double = 0.12

    /// The floor `action` plays at — the single source of truth both
    /// `MessageStatusGestureCoordinator.begin(_:for:now:tintOverride:)` and the
    /// Design Sandbox's live gallery tiles read, so the two can never drift
    /// apart the way the sandbox once did (it hardcoded every departing
    /// action onto the shared `departingFloor`, understating how much longer
    /// delete's Black hole and resolve's Protostar actually run).
    static func floor(for action: MessageStatusGestureAction) -> Double {
        if action == .delete {
            return blackHoleFloor
        } else if action == .resolve {
            return protostarFloor
        } else if action.isDeparting {
            return departingFloor
        } else {
            return defaultFloor
        }
    }

    /// Snappy press at the very start — the universal "registered" beat.
    var onsetProgress: Double { clamp(elapsed / Self.onset) }
    /// Primary motion, complete by the floor.
    var mid: Double { clamp((elapsed - Self.onset) / max(0.001, floor - Self.onset)) }
    /// True once the motion has played in full and is waiting for the snapshot.
    var isHolding: Bool { elapsed > floor }
    /// Gentle breathing for the holding tail.
    var breath: Double { 0.5 + 0.5 * sin((elapsed - floor) * 2 * .pi / 0.9) }

    /// Opacity envelope: ramps in over the motion, breathes during the hold.
    var sustain: Double {
        isHolding ? 0.82 + 0.18 * breath : clamp(mid * 1.4)
    }

    /// A looping 0→1 ramp for continuously-emitted pulse rings.
    func pulse(period: Double, offset: Double) -> Double {
        (((elapsed / period) + offset).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - Resolved glyph motion

/// Resolved transform for a status glyph at a moment in its gesture. View code
/// (`MessageStatusMark`) applies these to the real glyph.
struct MessageStatusGlyphMotion: Equatable, Sendable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1
    var rotation: Double = 0
    var opacity: Double = 1
    /// Visible fraction from the top (1 = whole glyph; <1 erases from the bottom
    /// up, for the flag "coming down a flagpole" strike).
    var maskTopFraction: CGFloat = 1
}

/// Motion for the obligation glyph (reply / replied / confirmation / confirmed) —
/// the glyph itself, no halo ring. Reply *sends* horizontally (the arrow);
/// confirm *stamps / watches* vertically (the seal / eye).
func messageStatusObligationMotion(
    _ action: MessageStatusGestureAction,
    _ phase: MessageStatusGesturePhase,
    size: CGFloat
) -> MessageStatusGlyphMotion {
    let mid = phase.mid
    let appear = min(1, mid * 1.9)

    var motion = MessageStatusGlyphMotion()
    switch action {
    case .replyNeeded:
        // Arrow arrives from the RIGHT and slides left to settle (right-to-left,
        // matching the reply arrow's leftward point).
        motion.offsetX = size * 0.9 * CGFloat(1 - messageStatusEaseOut(mid))
        motion.opacity = appear
    case .markReplied:
        // Arrow sweeps in from the RIGHT and "sends" leftward (overshooting past
        // centre in its pointing direction) as the green glyph settles.
        motion.offsetX = size * 0.7 * CGFloat(1 - messageStatusEaseOutBack(mid))
    case .confirmationNeeded:
        // Eye drops in from above with a watchful blink.
        motion.offsetY = -size * 0.6 * CGFloat(1 - messageStatusEaseOutBack(mid))
        motion.opacity = appear
        motion.scale = CGFloat(1 + 0.08 * sin(phase.elapsed * 5) * phase.sustain)
    case .markConfirmed:
        // Seal stamps down (large → settled).
        motion.scale = CGFloat(max(1, 1.8 - 0.8 * messageStatusEaseOutBack(mid)))
    case .flag, .delete, .resolve, .ignore, .sentToComposer:
        break
    }
    return motion
}

/// Motion for the flag glyph — the flag itself, no halo ring. Raise: the flag
/// waves in place. Strike (unflag): the flag is pulled straight DOWN — no
/// tipping — and erased from the bottom up, like a flag coming down a flagpole.
func messageStatusFlagMotion(
    raising: Bool,
    _ phase: MessageStatusGesturePhase,
    size: CGFloat
) -> MessageStatusGlyphMotion {
    var motion = MessageStatusGlyphMotion()
    if raising {
        motion.rotation = sin(phase.elapsed * 7) * 9 * messageStatusClusterWobble(phase)
    } else {
        let lower = messageStatusEaseOut(min(1, max(0, phase.elapsed / phase.floor)))
        motion.maskTopFraction = CGFloat(1 - lower)
        motion.offsetY = size * 0.85 * CGFloat(lower)
        motion.opacity = 1 - 0.25 * lower
    }
    return motion
}

/// Wobble strength: a firm sway on arrival that eases toward the floor, a gentle
/// persistent sway through the holding tail.
func messageStatusClusterWobble(_ phase: MessageStatusGesturePhase) -> Double {
    if phase.isHolding { return 0.4 }
    return 0.35 + 0.65 * (1 - phase.mid)
}

// MARK: - Easing

func messageStatusEaseOut(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return 1 - pow(1 - x, 3)
}

func messageStatusEaseOutBack(_ t: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let x = min(1, max(0, t))
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}

func messageStatusLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * min(1, max(0, t))
}

// MARK: - Coordinator

/// Owns the transient per-message gesture state. A gesture is begun when an
/// action is dispatched and cleared when the refreshed snapshot reflects the
/// change (`reconcile`) or after a safety window if the mutation never lands.
///
/// `@MainActor` because it is read by SwiftUI views and mutated from main-actor
/// action handlers. Multiple messages can hold gestures at once (the right
/// column acts on a whole selection).
@Observable @MainActor
final class MessageStatusGestureCoordinator {
    typealias FlagSettleWait = @MainActor (Duration) async throws -> Void

    private(set) var gestures: [UUID: MessageStatusGesture] = [:]
    private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let flagSettleWait: FlagSettleWait

    init(
        flagSettleWait: @escaping FlagSettleWait = { delay in
            try await Task.sleep(for: delay)
        }
    ) {
        self.flagSettleWait = flagSettleWait
    }

    /// Safety ceiling: a gesture never outlives this even if the snapshot never
    /// reflects it (e.g. a failed mutation), so the optimistic glyph reverts.
    static let maxLifetime: Double = 4.0

    func begin(
        _ action: MessageStatusGestureAction,
        for ids: [UUID],
        now: Date = .now,
        tintOverride: Color? = nil,
        composerDeparture: ComposerCardDeparture? = nil
    ) {
        guard !ids.isEmpty else { return }
        let floor = MessageStatusGesturePhase.floor(for: action)
        for id in ids {
            gestures[id] = MessageStatusGesture(action: action, start: now, floor: floor, tintOverride: tintOverride, composerDeparture: composerDeparture)
        }
        scheduleExpirySweep()
        // A flag toggle confirms synchronously (the Front Page reflects it
        // optimistically the instant it is tapped), so its gesture should play
        // the place/strike motion to the floor and then settle — it must NOT
        // hold for the async snapshot rebuild the way the obligation gestures
        // do, or it loops until the safety expiry. Settle each flag gesture once
        // its motion completes, giving a brief bounded flourish.
        if action.isFlag {
            scheduleFlagSettle(for: ids, startedAt: now)
        }
    }

    /// Clears flag gestures once their motion reaches the floor, so a flag /
    /// unflag plays its full place / strike animation and then settles to the
    /// (already optimistically updated) persistent state. The guard keys on the
    /// gesture's `start`, which uniquely identifies the begin that scheduled this
    /// settle — so a re-toggle that replaced the gesture in flight (even in the
    /// same direction) is left to its own settle and never cut short by a stale
    /// task.
    private func scheduleFlagSettle(for ids: [UUID], startedAt: Date) {
        let flagSettleWait = flagSettleWait
        Task { @MainActor [weak self, flagSettleWait] in
            do {
                try await flagSettleWait(
                    .seconds(MessageStatusGesturePhase.defaultFloor)
                )
            } catch {
                return
            }
            guard let self else { return }
            for id in ids where self.gestures[id]?.start == startedAt {
                self.clear(id)
            }
        }
    }

    /// Clears a departing gesture after its motion has played plus a brief hold —
    /// for surfaces (the Timeline reader) where the acted-on message stays in the
    /// snapshot (resolve / send-to-Composer don't remove it), so the
    /// snapshot-driven `reconcile` never fires and would otherwise leave the
    /// overlay humming until the 4s safety expiry. Guarded on `start` so a re-fire
    /// that replaced the gesture in flight is never cut short by a stale task.
    func scheduleDepartingSettle(for ids: [UUID], startedAt: Date, hold: Double) {
        let departures = ids.compactMap { id -> (ComposerCardDeparture, UUID)? in
            guard let departure = gestures[id]?.composerDeparture else { return nil }
            return (departure, departure.retainPresentation())
        }
        Task { @MainActor [weak self] in
            do {
                if departures.isEmpty {
                    try await Task.sleep(for: .seconds(hold))
                } else {
                    for (departure, _) in departures { try await departure.waitForMotion() }
                    let floor = departures.map { $0.0.floor }.max() ?? 0
                    try await Task.sleep(for: .seconds(max(0, hold - floor)))
                }
            } catch {
                for (departure, lease) in departures { departure.releasePresentation(lease) }
                return
            }
            guard !departures.isEmpty else {
                guard let self else { return }
                for id in ids where self.gestures[id]?.start == startedAt { self.clear(id) }
                return
            }
            withAnimation(.easeOut(duration: 0.28), completionCriteria: .removed) {
                guard let self else { return }
                for id in ids where self.gestures[id]?.start == startedAt {
                    self.clear(id)
                }
            } completion: {
                for (departure, lease) in departures { departure.releasePresentation(lease) }
            }
        }
    }

    func gesture(for id: UUID) -> MessageStatusGesture? { gestures[id] }

    /// Longest time still owed to an active animation whose backing card can be
    /// removed by the refresh it triggers. Full-card departing gestures always
    /// qualify; `.markConfirmed` also qualifies because confirmed mail leaves the
    /// Front Page even though its stamp animates in place. `0` when no qualifying
    /// gesture is active or all have already passed their motion floor.
    func remainingDepartingHold(now: Date = .now) -> Double {
        gestures.values.reduce(0) { longest, gesture in
            guard gesture.action.isDeparting || gesture.action == .markConfirmed else {
                return longest
            }
            if gesture.composerDeparture?.presentationComplete == false {
                return max(longest, 0.016, gesture.floor - now.timeIntervalSince(gesture.start))
            }
            return max(longest, gesture.floor - now.timeIntervalSince(gesture.start))
        }
    }

    func clear(_ id: UUID) {
        guard gestures[id] != nil else { return }
        gestures[id] = nil
        if gestures.isEmpty {
            cancelExpirySweep()
        } else {
            scheduleExpirySweep()
        }
    }

    func clearAll() {
        guard !gestures.isEmpty else { return }
        gestures.removeAll()
        cancelExpirySweep()
    }

    /// Clear gestures the snapshot has caught up to, or that have outlived the
    /// safety window. `isResolved(id, gesture)` returns true when the live state
    /// already reflects the gesture's target (or the card is gone). Called after
    /// every snapshot refresh.
    func reconcile(now: Date = .now, isResolved: (UUID, MessageStatusGesture) -> Bool) {
        guard !gestures.isEmpty else { return }
        let idsToClear = gestures.compactMap { id, gesture in
            if gesture.composerDeparture?.presentationComplete == false { return nil as UUID? }
            if now.timeIntervalSince(gesture.start) >= Self.maxLifetime {
                return id
            }
            return isResolved(id, gesture) ? id : nil
        }
        for id in idsToClear {
            gestures[id] = nil
        }
        if gestures.isEmpty {
            cancelExpirySweep()
        } else {
            scheduleExpirySweep()
        }
    }

    private func scheduleExpirySweep() {
        expiryTask?.cancel()
        guard let nextExpiration = gestures.values
            .map({ gesture in
                let expiry = gesture.start.addingTimeInterval(Self.maxLifetime)
                return gesture.composerDeparture?.presentationComplete == false
                    ? max(expiry, Date().addingTimeInterval(0.25)) : expiry
            })
            .min()
        else {
            expiryTask = nil
            return
        }
        let delay = max(0, nextExpiration.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.expiryTask = nil
            self?.expireAndReschedule(now: .now)
        }
    }

    private func cancelExpirySweep() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func expireAndReschedule(now: Date) {
        guard !gestures.isEmpty else { return }
        let expiredIds = gestures.compactMap { id, gesture in
            gesture.composerDeparture?.presentationComplete != false
                && now.timeIntervalSince(gesture.start) >= Self.maxLifetime ? id : nil
        }
        for id in expiredIds {
            gestures[id] = nil
        }
        if gestures.isEmpty {
            expiryTask = nil
        } else {
            scheduleExpirySweep()
        }
    }
}

// MARK: - Animated glyph wrappers

/// Track the existing source before the action begins. An absent departure
/// renderer can mean either off-screen bulk mail or a visible card whose first
/// overlay frame has not mounted yet; only the former may bypass playback.
struct ComposerDepartureSource: ViewModifier {
    let messageIDs: Set<UUID>
    var inScrollView = false
    @State private var surfaceID = UUID()
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !inScrollView { visible = true }
                updateSource()
            }
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                if inScrollView {
                    visible = isVisible
                    updateSource()
                }
            }
            .onChange(of: messageIDs) { updateSource() }
            .onDisappear {
                visible = false
                ComposerCardDeparture.setSource(surfaceID, messageIDs: [], visible: false)
            }
    }

    private func updateSource() {
        ComposerCardDeparture.setSource(surfaceID, messageIDs: messageIDs, visible: visible)
    }
}

/// The obligation glyph, animated when an obligation gesture is active. Renders
/// the action's SF Symbol with the gesture motion plus a layout-neutral pulse
/// ring overlay (so the badge — and the card — never shift). With no gesture it
/// renders the plain glyph, identical to `MessageStatusActionGlyph`.
struct GestureObligationGlyph: View {
    let action: MessageStatusActionState
    let gesture: MessageStatusGesture?
    var size: CGFloat = 18

    var body: some View {
        if let gesture, gesture.action.targetObligation != nil {
            TimelineView(.animation) { timeline in
                animatedGlyph(motion: messageStatusObligationMotion(
                    gesture.action,
                    gesture.phase(now: timeline.date),
                    size: size
                ))
            }
        } else {
            // No gesture → render the plain glyph exactly as before, so the
            // non-Front-Page lenses (Projects, Timeline) are unchanged.
            MessageStatusActionGlyph(action: action, size: size)
        }
    }

    private func animatedGlyph(motion: MessageStatusGlyphMotion) -> some View {
        MessageStatusActionGlyph(action: action, size: size)
            .contentTransition(.symbolEffect(.replace))
            .scaleEffect(motion.scale)
            .rotationEffect(.degrees(motion.rotation))
            .offset(x: motion.offsetX, y: motion.offsetY)
            .opacity(motion.opacity)
    }
}

/// The flag glyph, animated when a flag gesture is active: raise waves it in;
/// strike pulls it straight down and erases it bottom-up. No halo ring. With no
/// gesture it renders the plain flag glyph.
struct GestureFlagGlyph: View {
    let gesture: MessageStatusGesture?
    var size: CGFloat = 18

    var body: some View {
        if let gesture, case .flag(let raising) = gesture.action {
            TimelineView(.animation) { timeline in
                animatedGlyph(motion: messageStatusFlagMotion(
                    raising: raising,
                    gesture.phase(now: timeline.date),
                    size: size
                ))
            }
        } else {
            // No gesture → render the plain flag glyph exactly as before.
            MessageStatusFlaggedGlyph(size: size)
        }
    }

    private func animatedGlyph(motion: MessageStatusGlyphMotion) -> some View {
        MessageStatusFlaggedGlyph(size: size)
            .mask { Rectangle().scaleEffect(x: 1, y: motion.maskTopFraction, anchor: .top) }
            .rotationEffect(.degrees(motion.rotation), anchor: .bottom)
            .offset(x: motion.offsetX, y: motion.offsetY)
            .opacity(motion.opacity)
    }
}

// MARK: - Departing overlay

/// Centred overlay for the departing actions (delete / resolve / ignore /
/// send-to-Composer), drawn on a card while the mutation is in flight — the
/// four astrophysical candidates chosen in `Previews/DesignSandbox1.swift`.
/// The host card hides its own chrome for the gesture's duration
/// (`FrontPageArticleCard.departingGestureActive`), so this overlay BECOMES
/// the card: it dispatches to the action's own field —
/// `BlackHoleDepartingField` (delete), `ProtostarDepartingField` (resolve),
/// `BlackbodyDepartingField` (ignore), or `BolideDepartingField`
/// (send-to-Composer) — each a single continuous body that never fragments,
/// drawn deliberately *past* the card edge into a surrounding margin (the
/// host raises the card's `zIndex` so this floats over its neighbours). The
/// production phase is floor-then-hold, so each field plays its motion to
/// completion by the floor and then holds a small, dim, breathing remnant in
/// place until the refreshed snapshot drops the card and the row reflows.
/// Every field is sized to the host card via `cardSize` / `coreSize`, so
/// every layout tier reads.
struct DepartingGestureOverlay: View {
    /// Must be `.delete`, `.resolve`, `.ignore`, or `.sentToComposer`.
    let action: MessageStatusGestureAction
    let gesture: MessageStatusGesture
    var cornerRadius: CGFloat = 8
    /// Unused by every current field (none of the four redesigned phenomena
    /// reads a medallion reference the way the retired Collapse did) — kept,
    /// defaulted, and accepted only so `Previews/DesignSandbox1.swift`'s
    /// existing live-tile call sites keep compiling unmodified.
    var medallion: CGFloat = 54
    var iconSize: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerRendererID = UUID()

    /// The drawing surface inflates the card by this fraction of its short side on
    /// every edge, giving the flash, disk, and lensed arcs room to expand beyond
    /// the card before they fade.
    private static let overflowFactor: CGFloat = 0.62
    /// The launch Comet's nucleus grows to fill the viewer's sight before the
    /// arrival flash, so it wants a page-scale margin rather than the centred
    /// bloom's card-relative one. This cannot scale from the card's short side:
    /// small Front Page mosaic cards would then run out of canvas at their own
    /// edge instead of the flash filling the screen.
    private static let bolideOverflowFactor: CGFloat = 0.95
    private static let bolideOverflowMinimum: CGFloat = 1_180
    private static let bolideOverflowMaximum: CGFloat = 1_600

    private var tint: Color {
        switch action {
        case .delete: return OhiaColors.ohiaRed
        case .ignore: return OhiaColors.ohiaYellow
        case .sentToComposer: return gesture.tintOverride ?? MessageStatusColors.pendingReply
        default: return MessageStatusColors.confirmation   // .resolve
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cardSize = geo.size
            let overflow = Self.overflow(for: action, cardSize: cardSize)
            TimelineView(.animation) { timeline in
                let phase = gesture.composerDeparture?.phase(at: timeline.date)
                    ?? gesture.phase(now: timeline.date)
                switch action {
                case .delete:
                    BlackHoleDepartingField(
                        tint: tint,
                        phase: phase,
                        cardSize: cardSize,
                        overflow: overflow,
                        cornerRadius: cornerRadius,
                        coreSize: iconSize,
                        reduceMotion: reduceMotion
                    )
                case .resolve:
                    ProtostarDepartingField(
                        tint: tint,
                        phase: phase,
                        cardSize: cardSize,
                        overflow: overflow,
                        cornerRadius: cornerRadius,
                        coreSize: iconSize,
                        reduceMotion: reduceMotion
                    )
                case .ignore:
                    BlackbodyDepartingField(
                        tint: tint,
                        phase: phase,
                        cardSize: cardSize,
                        overflow: overflow,
                        cornerRadius: cornerRadius,
                        coreSize: iconSize,
                        reduceMotion: reduceMotion
                    )
                case .sentToComposer:
                    BolideDepartingField(
                        tint: tint,
                        phase: phase,
                        cardSize: cardSize,
                        overflow: overflow,
                        cornerRadius: cornerRadius,
                        coreSize: iconSize,
                        reduceMotion: reduceMotion,
                        onRendered: {
                            gesture.composerDeparture?.didRender(at: timeline.date, elapsed: phase.elapsed)
                        }
                    )
                default:
                    // Invariant: callers only ever drive this overlay with one
                    // of the four departing actions above (see the doc
                    // comment). Anything else renders nothing rather than
                    // guessing at a motion for an action that isn't departing.
                    EmptyView()
                }
            }
            // Inflate the canvas around the card and re-centre it on the card, so
            // the field can draw into the margin. GeometryReader does not clip, and
            // the host card root has no clip, so the overflow shows.
            .frame(width: cardSize.width + overflow * 2,
                   height: cardSize.height + overflow * 2)
            .position(x: cardSize.width / 2, y: cardSize.height / 2)
        }
        .allowsHitTesting(false)
        .onChange(of: gesture.composerDeparture, initial: true) { old, new in
            old?.unmount(composerRendererID)
            new?.mount(composerRendererID)
        }
        .onDisappear { gesture.composerDeparture?.unmount(composerRendererID) }
    }

    private static func overflow(
        for action: MessageStatusGestureAction,
        cardSize: CGSize
    ) -> CGFloat {
        let shortSide = min(cardSize.width, cardSize.height)
        guard action == .sentToComposer else {
            return shortSide * overflowFactor
        }

        let cardScaled = shortSide * bolideOverflowFactor
        return min(bolideOverflowMaximum, max(bolideOverflowMinimum, cardScaled))
    }
}

// MARK: - Departing field shared helpers

/// Piecewise-linear walk across a real blackbody colour-temperature curve —
/// the sequence a glowing body's colour actually passes through as its
/// surface temperature changes: hot blue-white, white, pale yellow, amber,
/// deep red, and finally a near-black ember. `t` is 0 (hottest) → 1
/// (coldest); every departing field that needs "glowing material at a
/// temperature" reads from this rather than a flat two-colour lerp.
///
/// Internal (not private) and distinctly named from `Previews/DesignSandbox1
/// .swift`'s own file-scoped `Blackbody` enum — that sandbox file is
/// intentionally never edited to match production, so this is named
/// `DepartingBlackbody` to guarantee no name collision, and exposed so
/// `MessageStatusGestureTests` can verify the ramp directly.
enum DepartingBlackbody {
    static let stops: [(Double, Double, Double)] = [
        (0.75, 0.85, 1.00),
        (1.00, 0.98, 0.92),
        (1.00, 0.86, 0.48),
        (0.95, 0.45, 0.14),
        (0.82, 0.10, 0.09),   // true red — green pulled below/near blue so it reads red, not rust/orange
        (0.12, 0.015, 0.015), // near-black ember — green and blue kept balanced so it stays red-black, not brown
    ]

    static func color(_ t: Double, opacity: Double) -> Color {
        let x = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, max(0, Int(x)))
        let f = x - Double(i)
        let a = stops[i]
        let b = stops[i + 1]
        return Color(.sRGB,
                     red: a.0 + (b.0 - a.0) * f,
                     green: a.1 + (b.1 - a.1) * f,
                     blue: a.2 + (b.2 - a.2) * f,
                     opacity: min(1, max(0, opacity)))
    }
}

func departingClamp(_ x: Double) -> Double { min(1, max(0, x)) }

func departingEaseIn(_ t: Double) -> Double {
    let x = departingClamp(t)
    return x * x
}

func departingEaseInOut(_ t: Double) -> Double {
    let x = departingClamp(t)
    return x * x * (3 - 2 * x)
}

func departingEaseOut(_ t: Double) -> Double {
    let x = departingClamp(t)
    return 1 - pow(1 - x, 3)
}

func departingCircle(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// Deterministic per-particle hash so each Canvas's per-frame redraw keeps
/// jitter / placement stable instead of flickering.
func departingHash(_ i: Int, _ salt: Int) -> Double {
    let x = sin(Double(i) * 127.1 + Double(salt) * 311.7) * 43758.5453
    return x - x.rounded(.down)
}

/// The continuous morph several departing fields share: the card's own
/// rounded rect shrinks smoothly toward a small point over `collapseFrac` of
/// the motion — one connected body throughout, never fracturing into
/// disconnected shards. What the point becomes afterward (swallowed,
/// ignited, cooled, launched) is entirely up to the caller.
func departingMorphPath(_ x: Double, cardRect: CGRect, cornerRadius cr: CGFloat, collapseFrac: Double, dotDiameter: CGFloat) -> Path {
    let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
    let c = departingEaseInOut(min(1, x / collapseFrac))
    let w = cardRect.width + (dotDiameter - cardRect.width) * CGFloat(c)
    let h = cardRect.height + (dotDiameter - cardRect.height) * CGFloat(c)
    let r = min(cr + (dotDiameter / 2 - cr) * CGFloat(c), min(w, h) / 2)
    let bodyRect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    return Path(roundedRect: bodyRect, cornerRadius: max(0, r))
}

/// Evenly arc-length-spaced points around a rounded rect's true perimeter
/// (straight edges + quarter-circle corners), traced clockwise starting just
/// after the top-left corner. The substrate Black Hole, Protostar, and
/// Blackbody warp point-by-point into their own non-uniform deformation —
/// spaghettification, accretion ripples, a cooling front's curl — instead of
/// scaling the whole card uniformly toward a point the way `departingMorphPath`
/// does. Keeping the corners genuinely rounded (not squared off) matters
/// because the resting, not-yet-departed card must still read as the same
/// rounded card the rest of the app uses. Ported from the round-2 candidates
/// prototyped in `Previews/DesignSandbox1.swift`.
func departingRoundedRectPerimeterPoints(_ rect: CGRect, cornerRadius: CGFloat, samples: Int) -> [CGPoint] {
    let r = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
    guard samples > 0 else { return [] }
    let straightW = Double(rect.width) - 2 * Double(r)
    let straightH = Double(rect.height) - 2 * Double(r)
    let arcLen = Double(r) * .pi / 2
    let segLengths = [straightW, arcLen, straightH, arcLen, straightW, arcLen, straightH, arcLen]
    let total = segLengths.reduce(0, +)
    guard total > 0 else {
        return Array(repeating: CGPoint(x: rect.midX, y: rect.midY), count: samples)
    }

    let trC = CGPoint(x: rect.maxX - r, y: rect.minY + r)
    let brC = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
    let blC = CGPoint(x: rect.minX + r, y: rect.maxY - r)
    let tlC = CGPoint(x: rect.minX + r, y: rect.minY + r)

    func point(forSegment seg: Int, localT: Double) -> CGPoint {
        switch seg {
        case 0: return CGPoint(x: rect.minX + r + CGFloat(localT) * CGFloat(straightW), y: rect.minY)
        case 1: return departingArcPoint(center: trC, radius: r, startAngle: -.pi / 2, sweep: .pi / 2, t: localT)
        case 2: return CGPoint(x: rect.maxX, y: rect.minY + r + CGFloat(localT) * CGFloat(straightH))
        case 3: return departingArcPoint(center: brC, radius: r, startAngle: 0, sweep: .pi / 2, t: localT)
        case 4: return CGPoint(x: rect.maxX - r - CGFloat(localT) * CGFloat(straightW), y: rect.maxY)
        case 5: return departingArcPoint(center: blC, radius: r, startAngle: .pi / 2, sweep: .pi / 2, t: localT)
        case 6: return CGPoint(x: rect.minX, y: rect.maxY - r - CGFloat(localT) * CGFloat(straightH))
        default: return departingArcPoint(center: tlC, radius: r, startAngle: .pi, sweep: .pi / 2, t: localT)
        }
    }

    var points: [CGPoint] = []
    points.reserveCapacity(samples)
    for i in 0..<samples {
        let target = total * Double(i) / Double(samples)
        var acc = 0.0
        for (seg, length) in segLengths.enumerated() {
            if target < acc + length || seg == segLengths.count - 1 {
                let localT = length > 0 ? departingClamp((target - acc) / length) : 0
                points.append(point(forSegment: seg, localT: localT))
                break
            }
            acc += length
        }
    }
    return points
}

func departingArcPoint(center: CGPoint, radius: CGFloat, startAngle: Double, sweep: Double, t: Double) -> CGPoint {
    let angle = startAngle + sweep * t
    return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
}

/// One perimeter point's position after the Black hole's point-by-point
/// infall warp — a real logarithmic inspiral: radius shrinks per-point
/// (points nearer the centre fall first, softened via the `0.55` floor
/// below so near/far fall rates stay within a modest ratio of each other
/// rather than splitting the boundary into a fast half and a near-static
/// half) and the winding angle is driven directly by how much THAT point
/// has itself already shrunk (`log(dist / newDist)`) — the actual
/// angle-vs-radius relationship of an inspiral trajectory, so winding and
/// falling are the same motion instead of two independently-tuned ones.
/// Two earlier formulas both produced a readable non-spiral artifact
/// instead of a vortex: swirl keyed to a point's *starting* distance
/// (`converge * k * (1 - normalized)`) zeroed rotation exactly at the
/// corners, the slowest-falling and most visually prominent points, so
/// they travelled in dead-straight radial lines while the rest of the
/// perimeter had already collapsed — a static X/asterisk. The follow-up
/// fix, swirl keyed to `localFall` but still a bounded linear term
/// (`localFall * k`), rotated every point but only by a fixed maximum
/// swing — with the near-center points falling in fast while barely
/// turning and the far corners lagging as slow, nearly straight prongs,
/// it still read as two static lobes joined by a pinched, twisting
/// waist — a bowtie, not infall. Winding logarithmically in the point's
/// own shrink ratio raises that ceiling (from a fixed ~149° to ~212°,
/// via the `dist * 0.04` floor below that keeps `log`'s argument safely
/// away from zero) and reaches it continuously and asymptotically rather
/// than linearly, so material deep in the well keeps winding noticeably
/// longer than material still near the rim, the way a real accretion
/// spiral tightens as it falls — not an unbounded number of turns.
/// `converge` is the shared 0→1 collapse progress (`departingEaseIn` of
/// `m / collapseFrac`); `maxDist` is the farthest perimeter point's
/// distance from `center`, used to normalize each point's fall rate by
/// its position. At `converge == 0` this is the identity (every point
/// returns exactly where it started), so the resting card is unwarped.
func departingBlackHoleWarpedPoint(_ p0: CGPoint, center: CGPoint, maxDist: Double, converge: Double) -> CGPoint {
    let dx = Double(p0.x - center.x), dy = Double(p0.y - center.y)
    let dist = max(1, hypot(dx, dy))
    let normalized = dist / max(1, maxDist)
    let localFall = departingClamp(converge / max(0.55, normalized))
    let newDist = dist * (1 - localFall)
    let shrinkRatio = dist / max(newDist, dist * 0.04)
    let windAngle = log(shrinkRatio) * 1.15
    let angle = atan2(dy, dx) + windAngle
    return CGPoint(x: center.x + CGFloat(cos(angle) * newDist), y: center.y + CGFloat(sin(angle) * newDist))
}

/// Rebuilds a closed path from a displaced point cloud — the counterpart to
/// `departingRoundedRectPerimeterPoints` once every point has been warped
/// toward wherever its phenomenon pulls it.
func departingPathFromPoints(_ points: [CGPoint]) -> Path {
    guard let first = points.first else { return Path() }
    var path = Path()
    path.move(to: first)
    for p in points.dropFirst() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

/// A point's position along a rect's top-left → bottom-right diagonal,
/// 0...1 — lets Blackbody express its cooling front as a single scalar
/// threshold sweeping across the card instead of a uniform state applied to
/// the whole surface at once.
func departingAlongDiagonal(_ p: CGPoint, rect: CGRect) -> Double {
    let axisX = Double(rect.width), axisY = Double(rect.height)
    let axisLenSq = axisX * axisX + axisY * axisY
    guard axisLenSq > 0 else { return 0 }
    let relX = Double(p.x - rect.minX), relY = Double(p.y - rect.minY)
    return departingClamp((relX * axisX + relY * axisY) / axisLenSq)
}

/// The wash-out envelope every "must fully clear before the hold" element in
/// this file shares: full strength until `cutoff`, then linearly fading to
/// exactly 0 by `cutoff + window` and staying there for any `x` beyond it.
/// Every departing field's primary body-alpha (and several of their
/// disk / ember windows) reads from this rather than each re-deriving its
/// own `1 - clamp(...)` — so a regression test can lock the "the exit always
/// reads as closed by the hold" invariant once, here, instead of trusting
/// four independently-typed formulas to stay in sync.
func departingWashOut(_ x: Double, from cutoff: Double, over window: Double) -> Double {
    1 - departingClamp((x - cutoff) / window)
}

/// A brief pause, as a fraction of `mid`, that every departing field's main
/// (non-reduced) path holds on its resting shape before any motion begins —
/// on top of the universal onset flash's own 0.12s window. The registered
/// beat needs a moment to actually land before the exit starts visibly
/// moving, or the whole thing reads as starting mid-stride. Reduced Motion
/// paths don't use this — they stay on their own simpler, faster pacing.
let departingHoldFraction: Double = 0.15

// MARK: - Departing field: Black hole (delete)

/// Red "Black hole" departure field for delete. Pure `Canvas`, driven
/// entirely by the elapsed `MessageStatusGesturePhase` (so it survives
/// ancestor `.animation` modifiers and keeps redrawing through the holding
/// tail). Spacetime warps and lenses around the card as it falls in — the
/// surface stays one connected body, continuously shrinking and redshifting
/// toward black, never fracturing into shards — a Doppler-brightened
/// accretion disk spins up around the forming horizon, and a single sharp
/// flash marks the event-horizon crossing: one-way, no bounce, no
/// shockwave. The holding tail fades to a small, dim, breathing point of
/// residual light around an otherwise invisible hole. Ported from the Black
/// hole collapse candidate prototyped in `Previews/DesignSandbox1.swift`.
private struct BlackHoleDepartingField: View {
    let tint: Color
    let phase: MessageStatusGesturePhase
    /// The host card's size. The infall is drawn into the centred sub-rect of
    /// the inflated canvas, so it stays card-sized while the disk / lensed
    /// arcs reach into the margin.
    let cardSize: CGSize
    /// Margin added on every edge of the card to form the canvas.
    let overflow: CGFloat
    let cornerRadius: CGFloat
    /// The gesture's tier icon size; scales the horizon so a lead card closes
    /// to a bigger point than a brief.
    let coreSize: CGFloat
    let reduceMotion: Bool

    /// Where the horizon closes and the crossing flash fires, as a fraction of
    /// `mid`. Matches the old Collapse's facet-crumple span (`0.62`) rather
    /// than firing early: the infall, lensing, and disk spin-up need to
    /// visibly fill most of the floor, not flash almost immediately and
    /// leave a long, quiet tail — the exit must read as a legible beginning,
    /// not just an abrupt bang.
    private static let collapseFrac = 0.62

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard size.width > 0, size.height > 0, cardSize.width > 0, cardSize.height > 0 else { return }
        let cardRect = CGRect(x: overflow, y: overflow, width: cardSize.width, height: cardSize.height)
        let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
        let cardMin = Double(min(cardRect.width, cardRect.height))
        let horizonDiameter = CGFloat(max(6, Double(coreSize) * 0.29))
        var m = phase.mid
        let holdBreath = phase.isHolding ? 0.86 + 0.14 * phase.breath : 1

        // Universal onset edge-flash — the "registered" beat shared with the
        // other departing fields.
        let onset = sin(min(1, phase.onsetProgress) * .pi) * 0.85
        if onset > 0.01 {
            ctx.stroke(Path(roundedRect: cardRect, cornerRadius: cornerRadius),
                       with: .color(tint.opacity(onset)), lineWidth: 2)
        }

        if reduceMotion {
            let alpha = departingWashOut(m, from: 0, over: 1)
            let cardPath = Path(roundedRect: cardRect, cornerRadius: cornerRadius)
            ctx.fill(cardPath, with: .color(OhiaColors.spaceBackground.opacity(alpha)))
            ctx.fill(cardPath, with: .color(OhiaColors.glassPanel.opacity(alpha)))
            let r = max(2, horizonDiameter / 2) * CGFloat(holdBreath)
            let coreAlpha = phase.isHolding ? 0.7 * holdBreath : departingClamp(m)
            ctx.fill(departingCircle(center, r), with: .color(.black.opacity(coreAlpha)))
            ctx.stroke(departingCircle(center, r * 1.7), with: .color(DepartingBlackbody.color(0.85, opacity: coreAlpha * 0.5)), lineWidth: 1)
            return
        }

        // A brief pause after the registered flash before the exit visibly
        // starts moving, so the flash reads as its own beat rather than the
        // motion starting mid-stride.
        m = departingClamp((m - departingHoldFraction) / (1 - departingHoldFraction))

        let hasCollapsed = m > Self.collapseFrac
        let converge = departingEaseIn(min(1, m / Self.collapseFrac))
        let bodyAlpha = departingWashOut(m, from: 0.94, over: 0.06)

        // The infalling card, warped point-by-point around its own true
        // perimeter into a logarithmic inspiral rather than scaled
        // uniformly toward the collapse point — one continuous surface,
        // never fragmenting, redshifting smoothly toward black as it nears
        // the horizon. Faded trailing echoes of the same warp at slightly
        // earlier convergence (the same technique the Bolide's dust tail
        // uses) are layered behind the current frame, so the spiral leaves
        // a visible winding trail — reading as an actual vortex in motion,
        // not a single static warped outline.
        if bodyAlpha > 0.01 {
            let corners = departingRoundedRectPerimeterPoints(cardRect, cornerRadius: cornerRadius, samples: 56)
            let maxDist = corners.map { Double(hypot($0.x - center.x, $0.y - center.y)) }.max() ?? 1

            for e in stride(from: 5, through: 1, by: -1) {
                let echoConverge = max(0, converge - Double(e) * 0.05)
                guard echoConverge > 0.01 else { continue }
                let echoAlpha = bodyAlpha * (0.16 / Double(e))
                guard echoAlpha > 0.01 else { continue }
                let echoWarped = corners.map {
                    departingBlackHoleWarpedPoint($0, center: center, maxDist: maxDist, converge: echoConverge)
                }
                let echoPath = departingPathFromPoints(echoWarped)
                ctx.fill(echoPath, with: .color(DepartingBlackbody.color(0.3 + 0.5 * echoConverge, opacity: echoAlpha)))
            }

            let warped = corners.map {
                departingBlackHoleWarpedPoint($0, center: center, maxDist: maxDist, converge: converge)
            }
            let path = departingPathFromPoints(warped)
            ctx.fill(path, with: .color(OhiaColors.spaceBackground.opacity(bodyAlpha)))
            ctx.fill(path, with: .color(OhiaColors.glassPanel.opacity(bodyAlpha)))
            ctx.fill(path, with: .color(DepartingBlackbody.color(0.35 + 0.55 * converge, opacity: 0.4 * bodyAlpha)))
            ctx.stroke(path, with: .color(DepartingBlackbody.color(0.2 + 0.6 * converge, opacity: 0.6 * bodyAlpha)), lineWidth: 1)
        }

        // Lensed light — a few thin arcs of the card's own light bent around
        // the forming horizon, shrinking in as the hole tightens its pull.
        // Gated barely above zero so the pull is legible almost immediately,
        // not hidden behind a quiet run-up.
        if converge > 0.02 && converge < 1 {
            let maxR = cardMin / 2
            let bendR = Double(horizonDiameter) / 2 + (maxR - Double(horizonDiameter) / 2) * (1 - converge)
            let alpha = 0.55 * converge * (1 - converge)
            if alpha > 0.02 {
                for i in 0..<4 {
                    let start = departingHash(i, 41) * 2 * Double.pi
                    let sweep = 0.8 + departingHash(i, 43) * 0.7
                    var arc = Path()
                    arc.addArc(center: center, radius: CGFloat(bendR * (0.85 + departingHash(i, 45) * 0.3)),
                               startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
                    ctx.stroke(arc, with: .color(DepartingBlackbody.color(0.1, opacity: alpha)), lineWidth: 0.8)
                }
            }
        }

        // Accretion disk — a rotating, Doppler-brightened ring of infalling
        // material, foreshortened to an ellipse, spinning up early and
        // continuously rather than snapping in late — it needs to read as
        // forming throughout the infall, not only right before the flash.
        // Only visible while material is actively spinning in right after
        // the horizon forms: `diskWindow` collapses it to nothing well
        // before the hold begins, so the exit reads as genuinely closed
        // rather than leaving an open ring behind.
        let diskWindow = hasCollapsed ? departingWashOut(m, from: Self.collapseFrac, over: 1 - Self.collapseFrac) : 0
        let diskAlpha = hasCollapsed
            ? 0.55 * diskWindow * diskWindow
            : max(0, converge - 0.15) / 0.85 * 0.6
        if diskAlpha > 0.02 {
            let diskScale = hasCollapsed ? (0.4 + 0.6 * diskWindow) : 1
            let diskW = CGFloat(cardMin) * 1.2 * diskScale
            let diskH = diskW * 0.32
            let diskRect = CGRect(x: center.x - diskW / 2, y: center.y - diskH / 2, width: diskW, height: diskH)
            let spin = Angle(radians: phase.elapsed * 1.1)
            let diskGradient = Gradient(stops: [
                .init(color: DepartingBlackbody.color(0.02, opacity: diskAlpha), location: 0.0),
                .init(color: DepartingBlackbody.color(0.35, opacity: diskAlpha * 0.65), location: 0.5),
                .init(color: DepartingBlackbody.color(0.7, opacity: diskAlpha * 0.3), location: 0.85),
                .init(color: DepartingBlackbody.color(0.02, opacity: diskAlpha), location: 1.0),
            ])
            ctx.stroke(Path(ellipseIn: diskRect), with: .conicGradient(diskGradient, center: center, angle: spin), lineWidth: 3)
        }

        // The horizon itself — a crisp, growing black disk with a thin,
        // near-black rim. Sharp-edged, unlike a soft glow: past this line
        // nothing escapes.
        let horizonR = (hasCollapsed ? horizonDiameter / 2 : horizonDiameter / 2 * CGFloat(converge)) * holdBreath
        if horizonR > 0.4 {
            ctx.fill(departingCircle(center, horizonR), with: .color(.black.opacity(0.94)))
            ctx.stroke(departingCircle(center, horizonR), with: .color(DepartingBlackbody.color(0.05, opacity: 0.65)), lineWidth: 0.6)
        }

        // A small, dim, breathing point of residual light — the disk itself
        // is long gone by the time the hold settles in (it crossfades into
        // this as `diskWindow` closes), so what's left echoes every other
        // exit's small hold ember instead of a lingering ring.
        if hasCollapsed {
            let emberAlpha = phase.isHolding ? 0.22 * holdBreath : 0.3 * (1 - diskWindow)
            if emberAlpha > 0.01 {
                let emberR = horizonR * 1.6
                ctx.fill(departingCircle(center, emberR), with: .radialGradient(
                    Gradient(colors: [DepartingBlackbody.color(0.85, opacity: emberAlpha), .clear]),
                    center: center, startRadius: 0, endRadius: emberR))
            }
        }

        // Horizon-crossing flash — one sharp beat exactly at collapse, then
        // gone. No shockwave, no bounce: it does not come back.
        let crossing = 1 - departingClamp(abs(m - Self.collapseFrac) / 0.07)
        if crossing > 0.02 {
            ctx.fill(departingCircle(center, CGFloat(2 + 9 * crossing)), with: .color(.white.opacity(crossing * 0.95)))
            ctx.fill(departingCircle(center, CGFloat(4 + 20 * crossing)), with: .color(tint.opacity(crossing * 0.4)))
        }
    }
}

// MARK: - Departing field: Protostar (resolve)

/// Green "Protostar" departure field for resolve / confirm. Pure `Canvas`,
/// driven entirely by the elapsed `MessageStatusGesturePhase`. The same
/// gravitational gathering as the Black hole, mirrored into creation instead
/// of destruction: the card's material condenses under its own compression
/// heat — one continuous body, never fracturing — fusion ignites in a bright
/// flash, and it settles into a small, steady, breathing point of new light.
/// Ported from the Protostar ignition candidate prototyped in
/// `Previews/DesignSandbox1.swift`; an earlier settled state also emitted a
/// sparse outward solar-wind drift of particles, removed as visual noise
/// once the point of light itself was reading clearly.
private struct ProtostarDepartingField: View {
    let tint: Color
    let phase: MessageStatusGesturePhase
    let cardSize: CGSize
    let overflow: CGFloat
    let cornerRadius: CGFloat
    let coreSize: CGFloat
    let reduceMotion: Bool

    private static let collapseFrac = 0.50
    /// Matches Black Hole's later climax so the two mirrored fields share a
    /// rhythm: the gathering needs to visibly fill the floor before the
    /// payoff, not fire early and leave a long, quiet settle behind it.
    private static let ignition = 0.72

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard size.width > 0, size.height > 0, cardSize.width > 0, cardSize.height > 0 else { return }
        let cardRect = CGRect(x: overflow, y: overflow, width: cardSize.width, height: cardSize.height)
        let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
        var m = phase.mid
        let holdBreath = phase.isHolding ? 0.86 + 0.14 * phase.breath : 1

        let onset = sin(min(1, phase.onsetProgress) * .pi) * 0.85
        if onset > 0.01 {
            ctx.stroke(Path(roundedRect: cardRect, cornerRadius: cornerRadius),
                       with: .color(tint.opacity(onset)), lineWidth: 2)
        }

        if reduceMotion {
            let alpha = departingWashOut(m, from: 0, over: 1)
            let cardPath = Path(roundedRect: cardRect, cornerRadius: cornerRadius)
            ctx.fill(cardPath, with: .color(OhiaColors.spaceBackground.opacity(alpha)))
            ctx.fill(cardPath, with: .color(OhiaColors.glassPanel.opacity(alpha)))
            let glowAlpha = phase.isHolding ? 0.6 * holdBreath : departingClamp((m - 0.35) / 0.65)
            ctx.fill(departingCircle(center, CGFloat(3 + 2 * holdBreath)), with: .color(tint.opacity(glowAlpha)))
            return
        }

        // A brief pause after the registered flash before the exit visibly
        // starts moving, so the flash reads as its own beat rather than the
        // motion starting mid-stride.
        m = departingClamp((m - departingHoldFraction) / (1 - departingHoldFraction))

        let gather = departingEaseIn(min(1, m / Self.collapseFrac))
        let bodyAlpha = departingWashOut(m, from: 0.92, over: 0.08)

        // Gathering — the card's own boundary draws inward as a rippling
        // density wave rather than a smooth uniform scale (a few clumped
        // spiral arms of infalling material, the way real accretion isn't a
        // perfectly even contraction), dimming as it compresses; the light
        // hasn't turned on yet. Carries a wash of the confirmation green
        // throughout the compression (not just once the corona lights), so
        // the shrinking body itself reads as green the whole way in, not
        // neutral glass.
        if bodyAlpha > 0.01 {
            let corners = departingRoundedRectPerimeterPoints(cardRect, cornerRadius: cornerRadius, samples: 56)
            let warped = corners.map { p0 -> CGPoint in
                let dx = Double(p0.x - center.x), dy = Double(p0.y - center.y)
                let dist = hypot(dx, dy)
                let angle = atan2(dy, dx)
                let ripple = 1 + 0.14 * sin(angle * 3 + phase.elapsed * 2.6) * gather
                let newDist = dist * (1 - gather) * ripple
                return CGPoint(x: center.x + CGFloat(cos(angle) * newDist), y: center.y + CGFloat(sin(angle) * newDist))
            }
            let path = departingPathFromPoints(warped)
            let dimmedAlpha = bodyAlpha * (1 - 0.35 * gather)
            ctx.fill(path, with: .color(OhiaColors.spaceBackground.opacity(dimmedAlpha)))
            ctx.fill(path, with: .color(OhiaColors.glassPanel.opacity(dimmedAlpha)))
            ctx.fill(path, with: .color(tint.opacity(0.24 * dimmedAlpha)))
            ctx.stroke(path, with: .color(tint.opacity(0.5 * dimmedAlpha)), lineWidth: 1)
        }

        // A warming inner glow builds through compression — gravitational
        // potential energy turning to heat — starting almost as soon as the
        // gathering begins rather than waiting for it to be well underway,
        // so the buildup reads from the first frames instead of arriving
        // late.
        let preGlow = departingClamp((gather - 0.05) / 0.95) * (1 - departingClamp((m - Self.ignition) / 0.05))
        if preGlow > 0.02 {
            let r = CGFloat(4 + 6 * gather)
            ctx.fill(departingCircle(center, r), with: .radialGradient(
                Gradient(colors: [Color(.sRGB, red: 0.95, green: 0.6, blue: 0.28, opacity: 0.55 * preGlow), .clear]),
                center: center, startRadius: 0, endRadius: r))
        }

        // Ignition — fusion catches: fast rise, slow decay, and sized off
        // the card itself rather than a handful of fixed pixels, so the
        // payoff actually reads as a burst of light against any card size
        // instead of a small blip. Additively blended so the core and halo
        // accumulate brightness the way real light does, with a shockwave
        // ring racing outward and a few radiating burst spikes riding the
        // same envelope — a real release of energy, not a pulsing dot.
        let cardMin = Double(min(cardRect.width, cardRect.height))
        let ignitionOffset = m - Self.ignition
        let ignite = ignitionOffset < 0
            ? departingClamp(1 - (-ignitionOffset) / 0.05)
            : departingClamp(1 - ignitionOffset / 0.30)
        if ignite > 0.02 {
            let coreR = cardMin * (0.05 + 0.12 * ignite)
            let haloR = cardMin * (0.10 + 0.30 * ignite)
            ctx.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(departingCircle(center, CGFloat(haloR)), with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.6 * ignite), .clear]),
                    center: center, startRadius: 0, endRadius: CGFloat(haloR)))
                layer.fill(departingCircle(center, CGFloat(coreR)), with: .color(.white.opacity(ignite * 0.95)))
            }

            if ignite > 0.12 {
                for i in 0..<7 {
                    let angle = Double(i) / 7 * 2 * .pi + departingHash(i, 161) * 0.3
                    let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
                    let length = cardMin * (0.10 + 0.30 * ignite)
                    var ray = Path()
                    ray.move(to: CGPoint(x: center.x + dx * CGFloat(coreR * 0.6), y: center.y + dy * CGFloat(coreR * 0.6)))
                    ray.addLine(to: CGPoint(x: center.x + dx * CGFloat(length), y: center.y + dy * CGFloat(length)))
                    ctx.stroke(ray, with: .color(tint.opacity(ignite * 0.5)), lineWidth: 1.3)
                }
            }
        }
        let shockT = departingClamp(max(0, ignitionOffset) / 0.30)
        if shockT > 0.001 && shockT < 1 {
            let shockR = cardMin * (0.12 + 0.45 * departingEaseOut(shockT))
            ctx.stroke(departingCircle(center, CGFloat(shockR)), with: .color(tint.opacity((1 - shockT) * 0.55)), lineWidth: 2.2 * (1 - shockT) + 0.5)
        }

        // Settled corona — a small, steady, breathing point of new light once
        // ignition has passed, calm rather than violent.
        if m > Self.ignition {
            let settle = departingClamp((m - Self.ignition) / 0.20)
            let coreR = CGFloat(2 + 2 * settle) * CGFloat(holdBreath)
            let haloR = coreR * 4.4
            let alpha = phase.isHolding ? 0.85 * holdBreath : (0.5 + 0.5 * settle)
            ctx.fill(departingCircle(center, haloR), with: .radialGradient(
                Gradient(colors: [tint.opacity(0.4 * alpha), .clear]),
                center: center, startRadius: 0, endRadius: haloR))
            ctx.fill(departingCircle(center, coreR), with: .color(.white.opacity(alpha)))
        }
    }
}

// MARK: - Departing field: Blackbody cooling (ignore)

/// Yellow "Blackbody cooling" departure field for list-ignore. The card
/// neither launches nor tears: its surface cools continuously along a real
/// stellar colour-temperature curve — white-yellow through amber to deep
/// ember-red — as ONE unbroken, continuously shrinking body (no faceted
/// shatter), granulating and limb-darkening as it condenses to a small, dim,
/// breathing ember. "Ignored" reads as turned down, not thrown out. Ported
/// from the Blackbody cooling candidate prototyped in
/// `Previews/DesignSandbox1.swift`, replacing the earlier faceted Cinder.
/// Reduced Motion keeps the semantics with a bounded fade to a static ember
/// and no surface motion.
private struct BlackbodyDepartingField: View {
    let tint: Color
    let phase: MessageStatusGesturePhase
    let cardSize: CGSize
    let overflow: CGFloat
    let cornerRadius: CGFloat
    let coreSize: CGFloat
    let reduceMotion: Bool

    private static let collapseFrac = 0.88

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard size.width > 0, size.height > 0, cardSize.width > 0, cardSize.height > 0 else { return }
        let cardRect = CGRect(x: overflow, y: overflow, width: cardSize.width, height: cardSize.height)
        let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
        let cardMin = Double(min(cardRect.width, cardRect.height))
        let emberDiameter = CGFloat(max(8, Double(coreSize) * 0.67))
        var m = phase.mid
        let holdBreath = phase.isHolding ? 0.86 + 0.14 * phase.breath : 1

        let onset = sin(min(1, phase.onsetProgress) * .pi) * 0.85
        if onset > 0.01 {
            ctx.stroke(Path(roundedRect: cardRect, cornerRadius: cornerRadius),
                       with: .color(tint.opacity(onset)), lineWidth: 2)
        }

        if reduceMotion {
            let surfaceAlpha = departingWashOut(m, from: 0, over: 1)
            let cardPath = Path(roundedRect: cardRect, cornerRadius: cornerRadius)
            ctx.fill(cardPath, with: .color(OhiaColors.spaceBackground.opacity(surfaceAlpha)))
            ctx.fill(cardPath, with: .color(OhiaColors.glassPanel.opacity(surfaceAlpha)))
            let emberAlpha = phase.isHolding ? 0.45 * holdBreath : departingClamp(m) * 0.55
            ctx.fill(departingCircle(center, max(2, emberDiameter * 0.22)), with: .color(DepartingBlackbody.color(0.82, opacity: emberAlpha)))
            return
        }

        // A brief pause after the registered flash before the exit visibly
        // starts moving, so the flash reads as its own beat rather than the
        // motion starting mid-stride.
        m = departingClamp((m - departingHoldFraction) / (1 - departingHoldFraction))
        let cool = departingClamp(m)

        let bodyAlpha = departingWashOut(m, from: 0.95, over: 0.05)
        let frontFrac = departingClamp(m / Self.collapseFrac)
        let sweepWindow = 0.22
        let sweepMax = 1 + sweepWindow
        let sweepT = frontFrac * sweepMax

        // The card's own boundary, curling inward only behind a cooling
        // front as it sweeps the top-left → bottom-right diagonal — the
        // shape buckles as it cools instead of shrinking everywhere at
        // once, and every point has fully collapsed to the centre exactly
        // when the front finishes its sweep. The front itself is rendered
        // as a gradient along the same diagonal: still warmly lit ahead of
        // the line, already cold and dark behind it.
        if bodyAlpha > 0.01 {
            let corners = departingRoundedRectPerimeterPoints(cardRect, cornerRadius: cornerRadius, samples: 56)
            let warped = corners.map { p0 -> CGPoint in
                let along = departingAlongDiagonal(p0, rect: cardRect)
                let behind = departingClamp((sweepT - along) / sweepWindow)
                guard behind > 0.001 else { return p0 }
                let dx = Double(p0.x - center.x), dy = Double(p0.y - center.y)
                let remain = 1 - behind
                return CGPoint(x: center.x + CGFloat(dx * remain), y: center.y + CGFloat(dy * remain))
            }
            let path = departingPathFromPoints(warped)
            ctx.fill(path, with: .color(OhiaColors.spaceBackground.opacity(bodyAlpha)))
            ctx.fill(path, with: .color(OhiaColors.glassPanel.opacity(bodyAlpha)))

            let edgeLo = max(0, CGFloat(frontFrac) - 0.08)
            let edgeHi = min(1, CGFloat(frontFrac) + 0.08)
            let gradient = Gradient(stops: [
                .init(color: DepartingBlackbody.color(0.78, opacity: 0.5 * bodyAlpha), location: 0),
                .init(color: DepartingBlackbody.color(0.78, opacity: 0.5 * bodyAlpha), location: edgeLo),
                .init(color: DepartingBlackbody.color(0.05, opacity: 0.5 * bodyAlpha), location: edgeHi),
                .init(color: DepartingBlackbody.color(0.05, opacity: 0.5 * bodyAlpha), location: 1),
            ])
            ctx.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: cardRect.minX, y: cardRect.minY), endPoint: CGPoint(x: cardRect.maxX, y: cardRect.maxY)))
            ctx.stroke(path, with: .color(DepartingBlackbody.color(cool * 0.9, opacity: 0.6 * bodyAlpha)), lineWidth: 1)
        }

        // Granulation — a handful of soft, uneven convection cells mottling
        // the cooling surface, the texture of a real stellar photosphere
        // rather than a flat tint. Only on the still-warm side, ahead of
        // the front.
        if bodyAlpha > 0.15 {
            for i in 0..<7 {
                let gx = cardRect.minX + CGFloat(departingHash(i, 61)) * cardRect.width
                let gy = cardRect.minY + CGFloat(departingHash(i, 63)) * cardRect.height
                guard departingAlongDiagonal(CGPoint(x: gx, y: gy), rect: cardRect) > frontFrac - 0.1 else { continue }
                let gr = max(0.6, min(cardRect.width, cardRect.height) * CGFloat(0.10 + 0.08 * departingHash(i, 67)))
                let flicker = 0.5 + 0.5 * sin(phase.elapsed * (1.5 + departingHash(i, 71)) + Double(i))
                let a = bodyAlpha * 0.18 * flicker
                guard a > 0.015 else { continue }
                ctx.fill(departingCircle(CGPoint(x: gx, y: gy), gr), with: .color(DepartingBlackbody.color(cool * 0.6, opacity: a)))
            }
        }

        // The condensed ember — limb-darkened (brighter core, dimmer edge)
        // and legible through the whole holding tail.
        let emberGrow = departingClamp((m - 0.5) / 0.4)
        if emberGrow > 0 || phase.isHolding {
            let r = (Double(emberDiameter) * 0.24 + cardMin * 0.05 * emberGrow) * holdBreath
            let alpha = phase.isHolding ? 0.55 * holdBreath : 0.3 + 0.5 * emberGrow
            ctx.fill(departingCircle(center, CGFloat(r)), with: .radialGradient(
                Gradient(colors: [DepartingBlackbody.color(0.85, opacity: alpha), DepartingBlackbody.color(0.97, opacity: alpha * 0.12)]),
                center: center, startRadius: 0, endRadius: CGFloat(r)))

            // A rare bright prominence lick at the limb — real cooling stars
            // still flare briefly even as their overall output fades.
            let flarePeriod = 2.4
            let flareT = (phase.elapsed + 0.6).truncatingRemainder(dividingBy: flarePeriod) / flarePeriod
            let flare = max(0, 1 - abs(flareT - 0.5) / 0.06)
            if flare > 0.05 {
                let angle = departingHash(3, 77) * 2 * Double.pi
                let p = CGPoint(x: center.x + CGFloat(cos(angle)) * CGFloat(r), y: center.y + CGFloat(sin(angle)) * CGFloat(r))
                ctx.fill(departingCircle(p, CGFloat(1.2 * flare)), with: .color(DepartingBlackbody.color(0.3, opacity: flare * alpha)))
            }
        }
    }
}

// MARK: - Departing field: Comet (send to Composer)

/// The launch Comet field for the `sentToComposer` departing action. Pure
/// `Canvas`, driven entirely by the elapsed `MessageStatusGesturePhase` (so
/// it survives ancestor `.animation` modifiers and keeps redrawing through
/// the holding tail). The whole card's box shape rounds and shrinks in place
/// into a small comet nucleus; once that nucleus ignites the body is
/// **always a circle** — it never reverts to a box — and it fires straight
/// at the viewer, foreshortened, growing in size as if flying directly at
/// them, trailing separated dust (broad, warm) and ion (thin, straighter,
/// blue) tails through a ram-pressure plasma coma, with motion-streak warp
/// lines and a brief airburst ring, before flashing to white as it arrives,
/// standing in for the Composer window opening. Ported from the Bolide
/// candidate prototyped in `Previews/DesignSandbox1.swift`, refined with
/// real cometary structure. Tint is the pending-reply accent, matching the
/// Metal lenses' own comet.
private struct BolideDepartingField: View {
    let tint: Color
    let phase: MessageStatusGesturePhase
    /// The host card's size. The collapse is drawn into the centred sub-rect of
    /// the inflated canvas, so it stays card-sized before the nucleus grows.
    let cardSize: CGSize
    /// Margin added on every edge of the card to form the canvas; the growing
    /// nucleus and the arrival flash fill out into it.
    let overflow: CGFloat
    let cornerRadius: CGFloat
    /// The gesture's tier icon size; scales the collapsed nucleus so a lead
    /// card collapses to a bigger dot than a brief.
    let coreSize: CGFloat
    let reduceMotion: Bool
    var onRendered: @MainActor @Sendable () -> Void = {}

    /// Fraction of `mid` spent collapsing the box down to the comet nucleus.
    private static let collapseFrac = 0.30
    /// Where the arrival flash begins, matching the launch's end.
    private static let flashStart = 0.84

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            draw(&ctx, size)
            // Report after the Canvas draw, outside SwiftUI's view update.
            // Merely evaluating a TimelineView body is not a rendered frame.
            let onRendered = onRendered
            Task { @MainActor in onRendered() }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard size.width > 0, size.height > 0, cardSize.width > 0, cardSize.height > 0 else { return }
        let cardRect = CGRect(x: overflow, y: overflow, width: cardSize.width, height: cardSize.height)
        let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
        let dotDiameter = CGFloat(max(8, Double(coreSize) * 0.4))
        let launchMaxRadius = Double(overflow) * 0.92
        var m = phase.mid

        // Universal onset edge-flash around the card — the "registered" beat
        // shared with the in-place glyph gestures and the other departing
        // fields.
        let onset = sin(min(1, phase.onsetProgress) * .pi) * 0.85
        if onset > 0.01 {
            ctx.stroke(Path(roundedRect: cardRect, cornerRadius: cornerRadius),
                       with: .color(tint.opacity(onset)), lineWidth: 2)
        }

        func nucleusRadius(_ l: Double) -> CGFloat {
            let ll = departingEaseIn(departingClamp(l))
            return dotDiameter / 2 + (CGFloat(launchMaxRadius) - dotDiameter / 2) * CGFloat(ll)
        }

        // The body's shape at collapse/launch progress `x` (0...1 across
        // `mid`): the card rectangle rounds and shrinks toward a small circle
        // through the collapse fraction; past that point the shape is always
        // a circle, simply growing — never a box again.
        func bodyPath(_ x: Double) -> Path {
            if x <= Self.collapseFrac {
                return departingMorphPath(x, cardRect: cardRect, cornerRadius: cornerRadius, collapseFrac: Self.collapseFrac, dotDiameter: dotDiameter)
            }
            let l = departingClamp((x - Self.collapseFrac) / max(0.001, Self.flashStart - Self.collapseFrac))
            return departingCircle(center, nucleusRadius(l))
        }

        if reduceMotion {
            // Bounded echo of the same beat — the box rounds into a small dot,
            // then that dot pushes modestly toward the viewer — heavily
            // dampened for comfort. The dot never reverts to a box once
            // collapsed. `phase.mid` clamps to 1 for the rest of the holding
            // tail (the snapshot hasn't caught up yet — e.g. Timeline's and
            // Projects' explicit settle windows), so the motion-driven alpha
            // would otherwise wash out to exactly 0 and leave the row visibly
            // blank; hold on a small breathing ember instead, matching every
            // other departing field's holding tail in this file.
            if phase.isHolding {
                let holdBreath = 0.86 + 0.14 * phase.breath
                let reducedDiameter = max(10, dotDiameter * 0.8)
                ctx.fill(departingCircle(center, reducedDiameter / 2 * CGFloat(holdBreath)), with: .color(tint.opacity(0.5 * holdBreath)))
                return
            }
            let reducedDiameter = max(10, dotDiameter * 0.8)
            let reducedMaxRadius = CGFloat(min(70.0, launchMaxRadius * 0.25))
            let bodyAlpha = departingWashOut(m, from: 0.72, over: 0.28)
            let path: Path
            if m <= Self.collapseFrac {
                let c = departingEaseInOut(m / Self.collapseFrac)
                let w = cardRect.width + (reducedDiameter - cardRect.width) * CGFloat(c)
                let h = cardRect.height + (reducedDiameter - cardRect.height) * CGFloat(c)
                let r = min(cornerRadius + (reducedDiameter / 2 - cornerRadius) * CGFloat(c), min(w, h) / 2)
                path = Path(roundedRect: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), cornerRadius: max(0, r))
            } else {
                let l = departingEaseIn(departingClamp((m - Self.collapseFrac) / (1 - Self.collapseFrac)))
                let radius = reducedDiameter / 2 + (reducedMaxRadius - reducedDiameter / 2) * CGFloat(l)
                path = departingCircle(center, radius)
            }
            ctx.fill(path, with: .color(tint.opacity(bodyAlpha * 0.85)))
            ctx.stroke(path, with: .color(tint.opacity(bodyAlpha * 0.75)), lineWidth: 1.5)
            let flash = min(1, departingClamp((m - 0.74) / 0.14)) * (1 - departingClamp((m - 0.92) / 0.08))
            if flash > 0.01 {
                ctx.fill(Path(cardRect.insetBy(dx: -60, dy: -60)), with: .color(.white.opacity(flash)))
            }
            return
        }

        // A brief pause after the registered flash before the exit visibly
        // starts moving, so the flash reads as its own beat rather than the
        // motion starting mid-stride.
        m = departingClamp((m - departingHoldFraction) / (1 - departingHoldFraction))

        let hasIgnited = m > Self.collapseFrac
        let launchProgress = departingClamp((m - Self.collapseFrac) / max(0.001, Self.flashStart - Self.collapseFrac))
        let bodyAlpha = departingWashOut(m, from: 0.86, over: 0.10)   // the surface washes out just ahead of the flash

        // Motion streaks — faint lines converging on the nucleus from well
        // beyond the card, intensifying with speed: the cue of closing
        // distance fast, layered behind everything else.
        if hasIgnited && launchProgress > 0.05 {
            let streakAlpha = launchProgress * bodyAlpha * 0.32
            if streakAlpha > 0.02 {
                let farR = Double(overflow) * 1.4
                let nearR = Double(nucleusRadius(launchProgress)) * 1.6
                for i in 0..<10 {
                    let angle = Double(i) / 10 * 2 * .pi + departingHash(i, 81) * 0.3
                    let p0 = CGPoint(x: center.x + CGFloat(cos(angle) * farR), y: center.y + CGFloat(sin(angle) * farR))
                    let p1 = CGPoint(x: center.x + CGFloat(cos(angle) * nearR), y: center.y + CGFloat(sin(angle) * nearR))
                    var line = Path()
                    line.move(to: p0)
                    line.addLine(to: p1)
                    ctx.stroke(line, with: .color(tint.opacity(streakAlpha * (0.5 + 0.5 * departingHash(i, 83)))), lineWidth: 0.75)
                }
            }
        }

        // Dust tail — broad, warm echoes of the body's own recent shape,
        // trailing behind as it collapses and then fires toward the viewer.
        if bodyAlpha > 0.01 {
            for e in stride(from: 6, through: 1, by: -1) {
                let echoM = m - Double(e) * 0.045
                guard echoM > 0.01 else { continue }
                let echoAlpha = (0.20 / Double(e)) * bodyAlpha
                guard echoAlpha > 0.006 else { continue }
                ctx.fill(bodyPath(echoM), with: .color(tint.opacity(echoAlpha)))
            }
        }

        // Ion tail — thinner, cooler, straighter streaks interleaved with the
        // dust tail: real comets show two visually distinct tails, a curved
        // dust trail and a straighter, bluer ion trail pushed by solar wind.
        if hasIgnited && bodyAlpha > 0.01 {
            let ionTint = Color(.sRGB, red: 0.55, green: 0.75, blue: 1.0, opacity: 1)
            for i in 0..<5 {
                let echoM = m - (0.05 + Double(i) * 0.035)
                guard echoM > Self.collapseFrac else { continue }
                let l = departingClamp((echoM - Self.collapseFrac) / max(0.001, Self.flashStart - Self.collapseFrac))
                let r = nucleusRadius(l) * 0.5
                let jitter = CGFloat(departingHash(i, 87) - 0.5) * r * 0.7
                let p = CGPoint(x: center.x + jitter, y: center.y + jitter * 0.4)
                let a = bodyAlpha * (0.16 / Double(i + 1))
                guard a > 0.008 else { continue }
                ctx.fill(departingCircle(p, max(0.6, r * 0.16)), with: .color(ionTint.opacity(a)))
            }
        }

        // The body — before ignition it is the card's own glass material
        // collapsing in place; past ignition it is a single glowing comet
        // nucleus (a hot core, a bright centre, and a soft coma glow) — never
        // a box again — its heat rising as speed builds. Additive blend on
        // the ignited layers so overlapping glow accumulates brightness the
        // way real light does, instead of flattening under plain alpha
        // compositing.
        if bodyAlpha > 0.01 {
            let path = bodyPath(m)
            if hasIgnited {
                let heat = 0.4 + 0.5 * launchProgress
                let nucleusR = nucleusRadius(launchProgress)
                ctx.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.fill(departingCircle(center, nucleusR * 1.7), with: .radialGradient(
                        Gradient(colors: [tint.opacity(0.28 * bodyAlpha), .clear]),
                        center: center, startRadius: 0, endRadius: nucleusR * 1.7))
                    layer.fill(path, with: .color(tint.opacity(0.85 * bodyAlpha)))
                    layer.fill(departingCircle(center, nucleusR * 0.55), with: .color(.white.opacity(0.55 * bodyAlpha)))
                }
                ctx.stroke(path, with: .color(tint.opacity((0.7 + 0.3 * heat) * bodyAlpha)), lineWidth: 1.5)
            } else {
                ctx.fill(path, with: .color(OhiaColors.spaceBackground.opacity(bodyAlpha)))
                ctx.fill(path, with: .color(OhiaColors.glassPanel.opacity(bodyAlpha)))
                ctx.stroke(path, with: .color(tint.opacity(0.85 * bodyAlpha)), lineWidth: 1.5)
            }
        }

        // Ignition — a brief bright core flare at the moment collapse
        // completes, the spark that lights the launch.
        let ignition = 1 - departingClamp(abs(m - Self.collapseFrac) / 0.08)
        if ignition > 0.02 {
            ctx.fill(departingCircle(center, CGFloat(2 + 10 * ignition)), with: .color(.white.opacity(ignition * 0.9)))
            ctx.fill(departingCircle(center, CGFloat(4 + 22 * ignition)), with: .color(tint.opacity(ignition * 0.5)))
        }

        // Debris — before ignition, embers are drawn inward, swallowed into
        // the collapsing point; after, they shed outward off the launching
        // comet, drifting further out and fading: the fiery wake trailing a
        // fast-closing body.
        if !hasIgnited {
            let collapseIn = departingEaseIn(min(1, m / Self.collapseFrac))
            let alpha = (1 - collapseIn) * 0.7
            if alpha > 0.03 {
                for i in 0..<10 {
                    let angle = departingHash(i, 23) * 2 * Double.pi
                    // Radius follows the card's own aspect (half-width /
                    // half-height per axis, not a single scalar), so embers
                    // stay bound to the card silhouette itself whatever its
                    // aspect ratio.
                    let frac = (1 - collapseIn) * (0.5 + 0.5 * departingHash(i, 29)) * 0.9
                    guard frac > 0.02 else { continue }
                    let rx = Double(cardRect.width) / 2 * frac
                    let ry = Double(cardRect.height) / 2 * frac
                    let p = CGPoint(x: center.x + CGFloat(cos(angle) * rx), y: center.y + CGFloat(sin(angle) * ry))
                    let particleSize = CGFloat(1 + 1.2 * departingHash(i, 31))
                    let a = alpha * (0.4 + 0.4 * departingHash(i, 37))
                    guard a > 0.01 else { continue }
                    ctx.fill(departingCircle(p, particleSize), with: .color(tint.opacity(a)))
                }
            }
        } else {
            let emberAlpha = launchProgress * bodyAlpha
            if emberAlpha > 0.03 {
                let nucleusR = Double(nucleusRadius(launchProgress))
                for i in 0..<14 {
                    let angle = departingHash(i, 11) * 2 * Double.pi
                    let drift = 0.5 + 0.5 * departingHash(i, 13)
                    let baseR = nucleusR * 0.95
                    let r = baseR * (0.65 + 0.55 * drift)
                    let p = CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                    let particleSize = CGFloat((1.1 + 1.5 * departingHash(i, 17)) * (1 - 0.4 * drift))
                    let a = emberAlpha * (0.32 + 0.4 * departingHash(i, 19)) * (1 - drift)
                    guard a > 0.01, particleSize > 0.2 else { continue }
                    ctx.fill(departingCircle(p, particleSize), with: .color(tint.opacity(a)))
                }
            }
        }

        // Airburst — a fast, thin expanding ring right before the whiteout,
        // the flash structure real bolides show at terminus rather than a
        // flat screen-wipe.
        let ringP = departingClamp((m - (Self.flashStart - 0.05)) / 0.08)
        if ringP > 0 && ringP < 1 {
            let ringR = cardRect.width * 0.15 + overflow * 0.4 * CGFloat(messageStatusEaseOut(ringP))
            ctx.stroke(departingCircle(center, ringR), with: .color(.white.opacity((1 - ringP) * 0.5)), lineWidth: 2.5 * (1 - ringP) + 0.5)
        }

        // Arrival — the frame flashes to white as the comet fills the
        // viewer's sight, standing in for the Composer window opening, then
        // clears to a faint breathing ember for the hold.
        let flashOnset = departingClamp((m - Self.flashStart) / 0.12)
        if flashOnset > 0.01 {
            let flash = flashOnset * (1 - departingClamp((m - 0.98) / 0.02))
            ctx.fill(Path(cardRect.insetBy(dx: -overflow * 3, dy: -overflow * 3)), with: .color(.white.opacity(min(1, flash))))
        }

        if phase.isHolding {
            let holdBreath = 0.86 + 0.14 * phase.breath
            ctx.fill(departingCircle(center, CGFloat(3 + 2 * holdBreath)), with: .color(tint.opacity(0.16 * holdBreath)))
        }
    }
}
