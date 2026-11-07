// Ohia/Composer/ComposerSendTakeoverOverlay.swift
// Full-composer takeover played from the moment Send is tapped until the
// message is actually confirmed sent — or the wait times out or fails. Two
// motifs, chosen by the user's configured sent-mail sound
// (SentMailSoundPreference): Coqui Chorus when that sound is "coqui.caf",
// Warp Bolide otherwise. Ported from the candidates explored in the DEBUG-only
// Ohia/Previews/ComposerSendAnimationSandbox.swift mockup — this file is the
// real, production-wired version, rendered as a live overlay over the
// existing Composer content (dimmed in place), not a snapshot or stand-in.
//
// Timing: the flourish resolves on the earliest durable evidence of the send
// — the tracked OutboxItem flipping `.sent` (seen by ComposerView's
// lightweight status poll, which owns the ModelContext) or the
// `.ohiaMailSendConfirmed` hint, whichever lands first. The hint fires only
// after the outbox worker's post-send housekeeping (sent-message ingestion,
// feedback recording), which can trail SMTP acceptance by many seconds, so
// it must never be the flourish's anchor. For both motifs the confirm
// resolution arms the configured call and the overlay itself fires it: the
// per-frame trigger evaluates the same flash formula the Canvas renders, so
// the audible attack lands exactly as the animation washes the screen all
// white — sound follows pixels, with a wall-clock backstop only for when no
// frame can fire (closed or stalled window). The app-wide consumer
// (OhiaApp.consumeSentConfirmation) retires the durable playback flag
// silently for rows this takeover owns (`claimChime`), so the call never
// double-plays however late the hint straggles in — the animation stays
// gated on genuine send evidence and the sound belongs to the animation,
// never the other way around. A bounded grace period covers the send never
// even reaching acceptance (still queued/retrying in
// the background — OutboxWorker's transient-error backoff can run up to an
// hour): past that window the takeover fades out quietly rather than
// implying success or hanging indefinitely, and the poll's fast-failure
// check fades it early when the row lands `.failed`/`.cancelled`.

import SwiftUI
import AppKit
import Observation
import OhiaCore

// MARK: - Candidate selection

enum ComposerSendTakeoverCandidate: Equatable {
    case warpBolide
    case coquiChorus

    /// coqui → Coqui Chorus; every other configured sent-mail sound (including
    /// "No Sound") → Warp Bolide.
    static func resolve(sentMailSoundFilename: String?) -> Self {
        let resolved = SentMailSoundPreference.resolvedFilename(from: sentMailSoundFilename)
        return resolved.caseInsensitiveCompare("coqui.caf") == .orderedSame ? .coquiChorus : .warpBolide
    }
}

private enum TakeoverTiming {
    static let confirmDuration: Double = 0.85
    static let confirmSettleHold: Double = 0.5
    static let quickFadeHold: Double = 0.5
    /// Keep the takeover alive through the outbox worker's full retry window
    /// so a slow genuine confirmation extends the sending field instead of
    /// allowing a later sent-mail sound to arrive without its white-out.
    /// Failure/cancellation still resolves immediately through the status poll.
    static let gracePeriod: Double = 60 * 60
    /// Seconds after confirmation at which each full-motion motif first
    /// reaches full white. Closed forms of the shared flash math, used only
    /// to pace the wall-clock backstop; the live beat reads the rendered
    /// envelope itself.
    static let warpFullWhiteDelay: Double = confirmDuration * 0.8
    static let coquiFullWhiteDelay: Double = confirmDuration * 0.75
    /// Both reduce-motion ramps peak at p = 0.6 of their 0.6 s confirm.
    static let reducedMotionFullWhiteDelay: Double = 0.6 * 0.6
    /// How far (in time) ahead of full white the chime must start.
    /// Compensates the audio-output path: `play` still buffers through the
    /// system mixer before anything is audible (~20–50 ms on built-in
    /// output), so the call starts this much before the rendered flash
    /// peaks for the *audible* attack to land on it. Sized from the
    /// 2026-07-30 field report ("slightly after the white flash" when
    /// started at plateau onset). The frame trigger applies it as a
    /// lookahead into `composerSendConfirmFlashLevel`; tune this constant,
    /// not the flash math, if output hardware changes the feel.
    static let chimeOutputLead: Double = 0.08
    /// Seconds from the confirm beat to the nominal chime beat — the
    /// closed-form twin of the frame trigger's lookahead, used to pace the
    /// wall-clock backstop.
    static func chimeBeatDelay(
        candidate: ComposerSendTakeoverCandidate,
        reduceMotion: Bool
    ) -> Double {
        let fullWhiteDelay: Double
        if reduceMotion {
            fullWhiteDelay = reducedMotionFullWhiteDelay
        } else {
            switch candidate {
            case .warpBolide: fullWhiteDelay = warpFullWhiteDelay
            case .coquiChorus: fullWhiteDelay = coquiFullWhiteDelay
            }
        }
        return max(0, fullWhiteDelay - chimeOutputLead)
    }
    /// Backstop margin past the nominal chime beat. Generous enough that
    /// the frame trigger always wins while frames are flowing; small enough
    /// that a stalled or closed window still chimes near its flourish.
    static let chimeBackstopSlack: Double = 0.25
}

// MARK: - Coordinator

@Observable @MainActor
final class ComposerSendTakeoverCoordinator {
    enum Resolution: Equatable {
        case confirmed(Date)
        case failed(Date)
        case timedOut(Date)

        var date: Date {
            switch self {
            case .confirmed(let d), .failed(let d), .timedOut(let d): return d
            }
        }
    }

    struct Takeover: Equatable {
        let outboxItemID: UUID
        let candidate: ComposerSendTakeoverCandidate
        let start: Date
        var resolution: Resolution?
        /// The sending account's `Account.colorIndex` — both motifs key off
        /// this (resolved to a `Color` at draw time via `AccountColorPalette`)
        /// rather than a fixed app tint, so the confirmation carries the
        /// identity of the account that sent it: Warp Bolide's comet/nucleus
        /// and arrival flash, Coqui Chorus's call rings, coalescing rings,
        /// and arrival flash. `AccountColorPalette.color(forIndex:)` already
        /// falls back to the default color for nil/out-of-range, so no
        /// further nil handling is needed here.
        let accountColorIndex: Int?
    }

    static let gracePeriod = TakeoverTiming.gracePeriod

    /// Sound-sync registry: which outbox rows currently have a live takeover,
    /// and which motif it is. Entries live from `begin` until failure,
    /// timeout, dismissal, or coordinator teardown.
    private static var soundSyncRegistry: [UUID: ComposerSendTakeoverCandidate] = [:]

    /// Outbox rows whose configured call this takeover has claimed (armed or
    /// already fired), so the app-wide consumer stays silent when the
    /// worker's hint finally arrives — however long after the flourish that
    /// is. Never pruned: a session's sends are a handful of 16-byte IDs, and
    /// keeping them all is what guarantees a hint that straggles in minutes
    /// later (or after the overlay is long dismissed) cannot double-play.
    private static var chimeClaimedRows: Set<UUID> = []

    /// Chimes armed and waiting for their beat. `fireChime` pops the entry,
    /// so the call plays exactly once however many triggers race — the
    /// overlay's frame trigger and the wall-clock backstop both fire it.
    private struct ArmedChime {
        let sound: NSSound?
        let filename: String
    }
    private static var armedChimes: [UUID: ArmedChime] = [:]

    /// Player for the takeover-owned sent-mail call. Static so an armed call
    /// still sounds (and its NSSound stays retained through playback) even
    /// if the composer window — and with it the coordinator — is torn down
    /// between the confirm beat and the white-out.
    private static let chimePlayer = NewStarAlertSoundPlayer()

    /// Called by the app-wide consumer (`OhiaApp.playSentMailSound`) at hint
    /// time. Returns true when this takeover owns the row's audible chime —
    /// the consumer must then stay silent, because the call is (or already
    /// was) armed for the takeover's white-out beat. When the owning
    /// takeover is live but not yet resolved (hint-first ordering), the
    /// claim arms the chime *here, in the consumer's own turn*, not on the
    /// coordinator's hopped confirm resolution: the durable flag is retired
    /// in this same turn, so arming must be atomic with that — otherwise a
    /// deadline timeout sneaking into the hop gap would strand the row with
    /// its flag retired and no chime ever played.
    static func claimChime(forOutboxItemID id: UUID) -> Bool {
        if chimeClaimedRows.contains(id) { return true }
        guard let candidate = soundSyncRegistry[id] else { return false }
        armChime(forOutboxItemID: id, candidate: candidate)
        return true
    }

    /// Arm the configured call for `outboxItemID`: mark the row claimed, prepare
    /// the sound fully in memory so firing is nothing but `play`, and start
    /// the wall-clock backstop. The beat itself is fired by the overlay's
    /// per-frame trigger, which reads the exact flash formula the Canvas
    /// renders (`composerSendConfirmFlashLevel`) — the sound follows the pixels.
    /// The backstop only wins when no frame can fire (window closed
    /// mid-flourish, occluded/stalled rendering, or a takeover that never
    /// resolved because a deadline timeout raced the hint): late in those
    /// cases, but a sent mail never loses its chime. The filename resolves
    /// at arm time: flipped to No Sound mid-flight → the row is still
    /// claimed (consumer stays silent, No Sound honored) but nothing is
    /// armed; flipped to a different sound → that sound fires on the beat.
    private static func armChime(
        forOutboxItemID id: UUID,
        candidate: ComposerSendTakeoverCandidate
    ) {
        guard chimeClaimedRows.contains(id) == false else { return }
        chimeClaimedRows.insert(id)
        let filename = SentMailSoundPreference.resolvedFilename(
            from: UserDefaults.standard.string(forKey: SentMailSoundPreference.storageKey)
        )
        guard filename != SentMailSoundPreference.noSoundFilename else { return }
        armedChimes[id] = ArmedChime(
            sound: NewStarAlertSoundPlayer.prepare(filename: filename),
            filename: filename
        )
        let backstop = TakeoverTiming.chimeBeatDelay(
            candidate: candidate,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) + TakeoverTiming.chimeBackstopSlack
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(backstop))
            fireChime(forOutboxItemID: id)
        }
    }

    /// Play the armed call for `outboxItemID` now. No-op when nothing is
    /// armed: already fired, never claimed, or No Sound.
    static func fireChime(forOutboxItemID id: UUID) {
        guard let armed = armedChimes.removeValue(forKey: id) else { return }
        if let sound = armed.sound {
            chimePlayer.play(prepared: sound)
        } else {
            chimePlayer.play(filename: armed.filename)
        }
    }

    private(set) var active: Takeover?
    /// `deinit` is non-isolated even on a @MainActor class, so it cannot
    /// touch actor-isolated state directly. Safe unchecked here: the token is
    /// write-once at init and only ever read/cleared once, at deinit.
    nonisolated(unsafe) private var notificationToken: NSObjectProtocol?
    /// Mirror of the registered `soundSyncRegistry` key so `deinit` can
    /// schedule its removal. Same justification as `notificationToken`:
    /// written only on the main actor (begin/dismiss/resolve), and by the
    /// time `deinit` reads it no other reference to the coordinator exists.
    nonisolated(unsafe) private var soundSyncID: UUID?

    init() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: .ohiaMailSendConfirmed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let idString = notification.userInfo?[MailSendNotificationUserInfoKey.outboxItemID] as? String,
                  let id = UUID(uuidString: idString) else { return }
            Task { @MainActor [weak self] in
                self?.resolveConfirmed(outboxItemID: id)
            }
        }
    }

    deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
        if let soundSyncID {
            Task { @MainActor in
                ComposerSendTakeoverCoordinator.soundSyncRegistry[soundSyncID] = nil
            }
        }
    }

    func begin(outboxItemID: UUID, candidate: ComposerSendTakeoverCandidate, accountColorIndex: Int?) {
        unregisterSoundSync()
        active = Takeover(
            outboxItemID: outboxItemID, candidate: candidate, start: Date(), resolution: nil,
            accountColorIndex: accountColorIndex
        )
        Self.soundSyncRegistry[outboxItemID] = candidate
        soundSyncID = outboxItemID
    }

    func resolveConfirmed(outboxItemID: UUID) {
        guard active?.outboxItemID == outboxItemID, active?.resolution == nil else { return }
        active?.resolution = .confirmed(Date())
        // Arm on the same turn that starts the confirmation animation clock;
        // the overlay's frame trigger fires the call when the rendered
        // flash reaches the beat, whichever signal (status poll or worker
        // hint) confirmed the send.
        if let candidate = active?.candidate {
            Self.armChime(forOutboxItemID: outboxItemID, candidate: candidate)
        }
    }

    func resolveFailed(outboxItemID: UUID) {
        guard active?.outboxItemID == outboxItemID, active?.resolution == nil else { return }
        active?.resolution = .failed(Date())
        // No white-out is coming, so this takeover no longer owns the row's
        // chime: if a confirm hint still lands later anyway, the app-wide
        // consumer must play it immediately rather than stay silent forever.
        unregisterSoundSync()
    }

    func resolveTimedOut(outboxItemID: UUID) {
        guard active?.outboxItemID == outboxItemID, active?.resolution == nil else { return }
        active?.resolution = .timedOut(Date())
        unregisterSoundSync()
    }

    func dismiss() {
        unregisterSoundSync()
        active = nil
    }

    private func unregisterSoundSync() {
        if let soundSyncID {
            Self.soundSyncRegistry[soundSyncID] = nil
        }
        soundSyncID = nil
    }
}

// MARK: - Overlay

struct ComposerSendTakeoverOverlay: View {
    let coordinator: ComposerSendTakeoverCoordinator
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let active = coordinator.active {
                GeometryReader { proxy in
                    TimelineView(.animation) { timeline in
                        let chimeBeatReached = chimeBeatReached(active: active, now: timeline.date)
                        Canvas { ctx, canvasSize in
                            draw(ctx: &ctx, size: canvasSize, active: active, now: timeline.date)
                        }
                        .onChange(of: chimeBeatReached) { _, reached in
                            // Runs on the commit of the frame whose rendered
                            // flash crossed the beat — the sound follows the
                            // pixels, not a parallel timer.
                            guard reached else { return }
                            ComposerSendTakeoverCoordinator.fireChime(forOutboxItemID: active.outboxItemID)
                        }
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .onChange(of: coordinator.active?.resolution) { _, newValue in
            guard let newValue else { return }
            // A guard against a second send starting during this hold is
            // enforced upstream (see ComposerView.enqueueSendAndAdvance /
            // handleComposeSend). This identity check is defense in depth:
            // without it, a stale dismiss from this resolution would call
            // onFinished() unconditionally and could tear down whatever
            // takeover is active by the time the hold elapses.
            let trackedID = coordinator.active?.outboxItemID
            let hold: Double
            switch newValue {
            case .confirmed: hold = TakeoverTiming.confirmDuration + TakeoverTiming.confirmSettleHold
            case .failed, .timedOut: hold = TakeoverTiming.quickFadeHold
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(hold))
                guard coordinator.active?.outboxItemID == trackedID else { return }
                onFinished()
            }
        }
    }

    /// True once the rendered confirmation is within one audio-output lead
    /// of full white — the frame on which the configured call must start so
    /// its audible attack lands on the white-out. Evaluates the exact flash
    /// formula the Canvas draws (`composerSendConfirmFlashLevel`) with the
    /// lookahead question: "will the flash be at full white one output-lead
    /// from this frame?" Rising once per takeover (the envelope is a single
    /// rise-plateau-decay), and `fireChime` pops its armed entry, so re-fires
    /// are impossible.
    private func chimeBeatReached(
        active: ComposerSendTakeoverCoordinator.Takeover,
        now: Date
    ) -> Bool {
        guard case .confirmed(let resolvedAt)? = active.resolution else { return false }
        let lookahead = now.timeIntervalSince(resolvedAt) + TakeoverTiming.chimeOutputLead
        return composerSendConfirmFlashLevel(
            candidate: active.candidate,
            confirmElapsed: lookahead,
            reduceMotion: reduceMotion
        ) >= 1
    }

    private func draw(
        ctx: inout GraphicsContext,
        size: CGSize,
        active: ComposerSendTakeoverCoordinator.Takeover,
        now: Date
    ) {
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let sendingElapsed = now.timeIntervalSince(active.start)
        let resolvedAt = active.resolution?.date
        let confirmElapsed = resolvedAt.map { now.timeIntervalSince($0) }
        let isConfirmed: Bool = {
            if case .confirmed = active.resolution { return true }
            return false
        }()
        let isUnsuccessful: Bool = {
            switch active.resolution {
            case .failed, .timedOut: return true
            default: return false
            }
        }()

        // Scrim: the live composer recedes in place behind the effect —
        // never swapped for a snapshot, per the app's single-scene lock idiom.
        let scrimIn = min(1, sendingElapsed / 0.28)
        let scrimFade: Double
        if isConfirmed, let confirmElapsed {
            scrimFade = max(0, 1 - clampD((confirmElapsed - 0.55) / 0.35))
        } else if isUnsuccessful, let confirmElapsed {
            scrimFade = max(0, 1 - confirmElapsed / TakeoverTiming.quickFadeHold)
        } else {
            scrimFade = 1
        }
        let scrimAlpha = 0.82 * scrimIn * scrimFade
        if scrimAlpha > 0.01 {
            ctx.fill(Path(rect), with: .color(OhiaColors.spaceBackground.opacity(scrimAlpha)))
        }

        switch active.candidate {
        case .warpBolide:
            drawWarpBolideTakeover(
                &ctx, rect, center,
                sendingElapsed: sendingElapsed,
                confirmElapsed: confirmElapsed,
                isConfirmed: isConfirmed,
                isUnsuccessful: isUnsuccessful,
                reduceMotion: reduceMotion,
                accountColor: sendTakeoverAccountColor(colorIndex: active.accountColorIndex)
            )
        case .coquiChorus:
            drawCoquiChorusTakeover(
                &ctx, rect,
                sendingElapsed: sendingElapsed,
                confirmElapsed: confirmElapsed,
                isConfirmed: isConfirmed,
                isUnsuccessful: isUnsuccessful,
                reduceMotion: reduceMotion,
                accountColor: sendTakeoverAccountColor(colorIndex: active.accountColorIndex)
            )
        }
    }
}

// MARK: - Warp Bolide

/// Near-white-blue: the point directly ahead, where the field converges and
/// light concentrates — a stand-in for the vanishing point.
private let warpCoreRGB: (Double, Double, Double) = (0.78, 0.87, 1.0)
/// Warm amber: streaks passing closest and fastest, off to the side — a
/// simple, readable stand-in for Doppler beaming under acceleration.
private let warpRimRGB: (Double, Double, Double) = (1.0, 0.78, 0.32)

private func warpPerspectiveColor(_ t: Double) -> Color {
    let tt = clampD(t)
    return Color(
        red: warpCoreRGB.0 + (warpRimRGB.0 - warpCoreRGB.0) * tt,
        green: warpCoreRGB.1 + (warpRimRGB.1 - warpCoreRGB.1) * tt,
        blue: warpCoreRGB.2 + (warpRimRGB.2 - warpCoreRGB.2) * tt
    )
}

/// Resolves a stored `Account.colorIndex` to the same SwiftUI `Color` the
/// rest of the app's account-color UI uses (`AccountColorMenu`, the People
/// lens, Front Page's account dots) — both motifs' nucleus/dots and arrival
/// flash carry the sending account's own identity rather than a fixed app
/// tint.
private func sendTakeoverAccountColor(colorIndex: Int?) -> Color {
    let entry = AccountColorPalette.color(forIndex: colorIndex)
    let rgb = AccountColorPalette.rgb(for: entry, brightness: 1.0)
    return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
}

private func warpStreakField(
    _ ctx: inout GraphicsContext, _ rect: CGRect, _ center: CGPoint,
    elapsed: Double, alphaScale: Double
) {
    let clearRadius: CGFloat = 40
    let streakCount = 40
    let diag = Double(hypot(rect.width, rect.height))
    let period = 0.9
    let maxTravel = diag * 0.52
    let outerR = Double(clearRadius) + maxTravel
    for i in 0..<streakCount {
        let phase = (elapsed + candHash(i, 5) * period).truncatingRemainder(dividingBy: period) / period
        let angle = candHash(i, 3) * 2 * Double.pi
        let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
        let accel = easeInD(phase)
        // A little per-lane depth jitter so streaks don't all appear born
        // on one perfect ring around the vanishing point.
        let laneJitter = CGFloat((candHash(i, 21) - 0.5) * 10)
        let innerR = clearRadius + laneJitter + CGFloat(accel * maxTravel)
        // 0 at the vanishing point (dead ahead, barely moving), 1 at the
        // tunnel's outer edge (closest, fastest) — real perspective
        // foreshortening instead of a uniform sunburst: streaks near center
        // stay short and dim, streaks near the rim stretch long and bright,
        // exactly how star-lines read at speed.
        let perspectiveT = clampD(Double(innerR) / outerR)
        let length = CGFloat(6 + 150 * pow(perspectiveT, 1.6))
        let coreWidth = CGFloat(0.8 + 1.0 * perspectiveT)
        let fadeIn = min(1, phase / 0.12)
        let fadeOut = 1 - max(0, (phase - 0.82) / 0.18)
        let alpha = fadeIn * fadeOut * (0.35 + 0.5 * perspectiveT) * alphaScale
        guard alpha > 0.02 else { continue }
        var line = Path()
        line.move(to: CGPoint(x: center.x + dx * innerR, y: center.y + dy * innerR))
        line.addLine(to: CGPoint(x: center.x + dx * (innerR + length), y: center.y + dy * (innerR + length)))
        // A soft outer glow beneath a thin bright core reads as a streaking
        // star rather than a hard spark line; color grades cool-to-warm
        // with depth, the simplest readable Doppler cue.
        let streakColor = warpPerspectiveColor(perspectiveT)
        ctx.stroke(line, with: .color(streakColor.opacity(alpha * 0.4)), lineWidth: coreWidth + 2)
        ctx.stroke(line, with: .color(streakColor.opacity(alpha)), lineWidth: coreWidth)
    }
}

private func warpNucleus(_ ctx: inout GraphicsContext, _ center: CGPoint, elapsed: Double, alphaScale: Double, tint: Color) {
    let breathe = 0.6 + 0.4 * sin(elapsed * 2 * .pi / 1.3)
    ctx.fill(circleP(center, CGFloat(4 + 2 * breathe)), with: .color(tint.opacity((0.5 + 0.3 * breathe) * alphaScale)))
}

private func warpConfirmBurst(_ ctx: inout GraphicsContext, _ rect: CGRect, _ center: CGPoint, confirmElapsed: Double, accountColor: Color) {
    let p = min(1, confirmElapsed / TakeoverTiming.confirmDuration)
    let clearRadius: CGFloat = 40
    let streakCount = 40
    let diag = Double(hypot(rect.width, rect.height))
    let maxTravel = diag * 0.75
    let outerR = Double(clearRadius) + maxTravel
    for i in 0..<streakCount {
        let localPhase = clampD(p * 1.6 + candHash(i, 5) * 0.3)
        let angle = candHash(i, 3) * 2 * Double.pi
        let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
        let accel = easeInD(localPhase)
        let innerR = clearRadius + CGFloat(accel * maxTravel)
        let perspectiveT = clampD(Double(innerR) / outerR)
        let length = CGFloat(20 + 130 * pow(localPhase, 1.2))
        let coreWidth = CGFloat(1.2 + 1.4 * perspectiveT)
        let alpha = (1 - clampD((p - 0.6) / 0.4)) * 0.85
        guard alpha > 0.02 else { continue }
        var line = Path()
        line.move(to: CGPoint(x: center.x + dx * innerR, y: center.y + dy * innerR))
        line.addLine(to: CGPoint(x: center.x + dx * (innerR + length), y: center.y + dy * (innerR + length)))
        let streakColor = warpPerspectiveColor(perspectiveT)
        ctx.stroke(line, with: .color(streakColor.opacity(alpha * 0.45)), lineWidth: coreWidth + 2)
        ctx.stroke(line, with: .color(streakColor.opacity(alpha)), lineWidth: coreWidth)
    }

    // The comet itself closing the last of the distance — the camera
    // catching up to it, not a screen-wide wash appearing on its own.
    // Grows with accelerating speed, the way an approaching object's
    // apparent size actually accelerates as the remaining distance closes,
    // reaching full screen coverage right as the flash below peaks — so
    // the white-out reads as the moment of impact with the comet's own
    // nucleus, not an unrelated event. Tinted with the sending account's
    // own color, matching the nucleus throughout the rest of the takeover.
    let approach = easeInD(min(1, p / 0.80))
    if approach > 0.02 {
        let nucleusR = 10 + CGFloat(diag) * 1.3 * CGFloat(approach)
        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(circleP(center, nucleusR), with: .radialGradient(
                Gradient(colors: [accountColor.opacity(0.9 * approach), accountColor.opacity(0.2 * approach), .clear]),
                center: center, startRadius: 0, endRadius: nucleusR))
            layer.fill(circleP(center, nucleusR * 0.3), with: .color(accountColor.opacity(0.95 * approach)))
        }
    }

    let flash = composerSendConfirmFlashLevel(
        candidate: .warpBolide,
        confirmElapsed: confirmElapsed,
        reduceMotion: false
    )
    if flash > 0.01 {
        ctx.fill(Path(rect), with: .color(accountColor.opacity(flash)))
    }
}

private func drawWarpBolideTakeover(
    _ ctx: inout GraphicsContext, _ rect: CGRect, _ center: CGPoint,
    sendingElapsed: Double, confirmElapsed: Double?,
    isConfirmed: Bool, isUnsuccessful: Bool, reduceMotion: Bool,
    accountColor: Color
) {
    let tint = MessageStatusColors.pendingReply

    if reduceMotion {
        if isConfirmed, let confirmElapsed {
            let flash = composerSendConfirmFlashLevel(
                candidate: .warpBolide,
                confirmElapsed: confirmElapsed,
                reduceMotion: true
            )
            if flash > 0.01 {
                ctx.fill(Path(rect), with: .color(.white.opacity(flash * 0.8)))
            }
        } else if isUnsuccessful, let confirmElapsed {
            let fade = max(0, 1 - confirmElapsed / TakeoverTiming.quickFadeHold)
            warpNucleus(&ctx, center, elapsed: sendingElapsed, alphaScale: fade, tint: tint)
        } else {
            warpNucleus(&ctx, center, elapsed: sendingElapsed, alphaScale: 1, tint: tint)
        }
        return
    }

    if isConfirmed, let confirmElapsed {
        warpConfirmBurst(&ctx, rect, center, confirmElapsed: confirmElapsed, accountColor: accountColor)
    } else if isUnsuccessful, let confirmElapsed {
        let fade = max(0, 1 - confirmElapsed / TakeoverTiming.quickFadeHold)
        warpStreakField(&ctx, rect, center, elapsed: sendingElapsed, alphaScale: fade)
        warpNucleus(&ctx, center, elapsed: sendingElapsed, alphaScale: fade, tint: accountColor)
    } else {
        warpStreakField(&ctx, rect, center, elapsed: sendingElapsed, alphaScale: 1)
        warpNucleus(&ctx, center, elapsed: sendingElapsed, alphaScale: 1, tint: accountColor)
    }
}

// MARK: - Coqui Chorus

private func chorusDotPosition(_ i: Int, in rect: CGRect) -> CGPoint {
    let marginX = rect.width * 0.12
    let marginY = rect.height * 0.14
    let x = rect.minX + marginX + CGFloat(candHash(i, 3)) * (rect.width - 2 * marginX)
    let y = rect.minY + marginY + CGFloat(candHash(i, 7)) * (rect.height - 2 * marginY)
    return CGPoint(x: x, y: y)
}

/// Each "frog" node calls on its own asynchronous tempo — a coqui chorus is
/// never in unison — so both the call period and its phase offset are
/// per-dot.
private func chorusField(
    _ ctx: inout GraphicsContext, _ rect: CGRect,
    elapsed: Double, alphaScale: Double, dotCount: Int, tint: Color, accountColor: Color
) {
    let fadeIn = min(1, elapsed / 0.3) * alphaScale
    for i in 0..<dotCount {
        let p = chorusDotPosition(i, in: rect)
        let period = 1.1 + candHash(i, 11) * 0.9
        let offset = candHash(i, 17) * period
        let localT = (elapsed + offset).truncatingRemainder(dividingBy: period)
        let callProgress = localT / period

        // Eased attack instead of a linear blink, so a call's pop reads as
        // a soft pulse of light rather than a hard on/off flicker.
        let pop = callProgress < 0.12 ? 1 - easeOutD(callProgress / 0.12) : 0
        let dotRadius = CGFloat(2.6 + 1.8 * pop)
        if pop > 0.02 {
            let glowR = dotRadius * 4.5
            ctx.fill(circleP(p, glowR), with: .radialGradient(
                Gradient(colors: [tint.opacity(fadeIn * 0.3 * pop), tint.opacity(0)]),
                center: p, startRadius: 0, endRadius: glowR
            ))
        }
        ctx.fill(circleP(p, dotRadius), with: .color(tint.opacity(fadeIn * (0.55 + 0.4 * pop))))

        let maxRadius = Double(min(rect.width, rect.height)) * 0.12
        let ringRadius = CGFloat(easeOutD(callProgress) * maxRadius)
        // A nonlinear falloff — light and sound both dissipate faster than
        // they travel — reads as a ring fading into the dark rather than a
        // hard-edged circle sliding outward at constant opacity.
        let ringAlpha = pow(1 - callProgress, 1.8) * 0.55 * fadeIn
        guard ringAlpha > 0.02 else { continue }
        ctx.stroke(circleP(p, ringRadius), with: .color(accountColor.opacity(ringAlpha * 0.5)), lineWidth: 3.4)
        ctx.stroke(circleP(p, ringRadius), with: .color(accountColor.opacity(ringAlpha)), lineWidth: 1.2)
    }
}

/// Every call synchronizes into one shared, ever-growing ring per dot; as
/// they overlap they wash the whole takeover into one giant flash of light.
private func chorusCoalesce(
    _ ctx: inout GraphicsContext, _ rect: CGRect,
    confirmElapsed: Double, dotCount: Int, accountColor: Color
) {
    let p = min(1, confirmElapsed / TakeoverTiming.confirmDuration)
    let diag = Double(hypot(rect.width, rect.height))
    // Same nonlinear release as each call's own ring, so the coalesced wave
    // dissipates with the same character rather than clipping off in a
    // straight line.
    let release = pow(1 - clampD((p - 0.7) / 0.3), 1.6)
    for i in 0..<dotCount {
        let dotP = chorusDotPosition(i, in: rect)
        let radius = CGFloat(easeOutD(p) * diag * 0.6)
        let alpha = (0.5 + 0.5 * p) * release
        guard alpha > 0.01 else { continue }
        ctx.stroke(circleP(dotP, radius), with: .color(accountColor.opacity(alpha * 0.22)), lineWidth: 4)
        ctx.stroke(circleP(dotP, radius), with: .color(accountColor.opacity(alpha * 0.4)), lineWidth: 1.6)
        ctx.fill(circleP(dotP, radius * 0.3), with: .color(accountColor.opacity(alpha * 0.2)))
    }
    let flash = composerSendConfirmFlashLevel(
        candidate: .coquiChorus,
        confirmElapsed: confirmElapsed,
        reduceMotion: false
    )
    if flash > 0.01 {
        ctx.fill(Path(rect), with: .color(accountColor.opacity(flash)))
    }
}

private func drawCoquiChorusTakeover(
    _ ctx: inout GraphicsContext, _ rect: CGRect,
    sendingElapsed: Double, confirmElapsed: Double?,
    isConfirmed: Bool, isUnsuccessful: Bool, reduceMotion: Bool,
    accountColor: Color
) {
    let tint = OhiaColors.ohiaGreen
    let ringTint = OhiaColors.ohiaYellow
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let dotCount = 22

    if reduceMotion {
        if isConfirmed, let confirmElapsed {
            let flash = composerSendConfirmFlashLevel(
                candidate: .coquiChorus,
                confirmElapsed: confirmElapsed,
                reduceMotion: true
            )
            if flash > 0.01 {
                ctx.fill(Path(rect), with: .color(.white.opacity(flash * 0.8)))
            }
        } else if isUnsuccessful, let confirmElapsed {
            let fade = max(0, 1 - confirmElapsed / TakeoverTiming.quickFadeHold)
            let breathe = 0.5 + 0.5 * sin(sendingElapsed * 2 * .pi / 1.2)
            ctx.fill(circleP(center, CGFloat(3 + 2 * breathe)), with: .color(tint.opacity(0.5 * fade)))
        } else {
            let breathe = 0.5 + 0.5 * sin(sendingElapsed * 2 * .pi / 1.2)
            ctx.fill(circleP(center, CGFloat(3 + 2 * breathe)), with: .color(tint.opacity(0.5)))
            ctx.stroke(circleP(center, CGFloat(20 + 6 * breathe)), with: .color(ringTint.opacity(0.3)), lineWidth: 1.2)
        }
        return
    }

    if isConfirmed, let confirmElapsed {
        chorusField(&ctx, rect, elapsed: sendingElapsed, alphaScale: max(0, 1 - confirmElapsed / 0.4), dotCount: dotCount, tint: tint, accountColor: accountColor)
        chorusCoalesce(&ctx, rect, confirmElapsed: confirmElapsed, dotCount: dotCount, accountColor: accountColor)
    } else if isUnsuccessful, let confirmElapsed {
        let fade = max(0, 1 - confirmElapsed / TakeoverTiming.quickFadeHold)
        chorusField(&ctx, rect, elapsed: sendingElapsed, alphaScale: fade, dotCount: dotCount, tint: tint, accountColor: accountColor)
    } else {
        chorusField(&ctx, rect, elapsed: sendingElapsed, alphaScale: 1, dotCount: dotCount, tint: tint, accountColor: accountColor)
    }
}

// MARK: - Confirm flash levels (single source of truth)

/// Drawn envelope of the selected motif's confirm white-out at
/// `confirmElapsed`, 0…1. The Canvas and chime trigger both read this
/// function, so sound and pixels cannot drift apart.
private func composerSendConfirmFlashLevel(
    candidate: ComposerSendTakeoverCandidate,
    confirmElapsed: Double,
    reduceMotion: Bool
) -> Double {
    if reduceMotion {
        let p = min(1, confirmElapsed / 0.6)
        return clampD((p - 0.3) / 0.3) * (1 - clampD((p - 0.75) / 0.25))
    }

    switch candidate {
    case .warpBolide:
        let p = min(1, confirmElapsed / TakeoverTiming.confirmDuration)
        return clampD((p - 0.55) / 0.25) * (1 - clampD((p - 0.85) / 0.15))
    case .coquiChorus:
        let p = min(1, confirmElapsed / TakeoverTiming.confirmDuration)
        return clampD((p - 0.45) / 0.3) * (1 - clampD((p - 0.85) / 0.15))
    }
}

// MARK: - Math helpers

private func clampD(_ x: Double) -> Double { min(1, max(0, x)) }
private func easeOutD(_ t: Double) -> Double { let x = clampD(t); return 1 - pow(1 - x, 3) }
private func easeInD(_ t: Double) -> Double { let x = clampD(t); return x * x }
private func circleP(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}
/// Deterministic 0...1 hash so per-frame redraws keep each particle's jitter
/// stable instead of flickering.
private func candHash(_ i: Int, _ salt: Int) -> Double {
    let x = sin(Double(i) * 127.1 + Double(salt) * 311.7) * 43758.5453
    return x - x.rounded(.down)
}
