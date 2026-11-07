// ActivityStripGauge.swift
// The single SwiftUI subview that renders the activity strip's tempo
// gauge in any of three visual modes: Mass (initial IMAP acquisition), Flow
// (later historical backfill), Signal (IMAP steady state with discrete events).
//
// All time→shape math lives in ActivityStripGaugeMath so this view is
// concerned only with composition, color resolution, and TimelineView
// scheduling. Behavior is fully driven by the upstream `mode` parameter
// — no state of its own beyond derived display values.
//
// Spec: docs/superpowers/specs/2026-05-03-activity-strip-progress-bar-design.md

import SwiftUI
import OhiaCore

enum GaugeMode: Equatable {
    /// Determinate first IMAP acquisition, driven by persisted UID work.
    case mass(fraction: Double)
    /// Indeterminate acquisition of an older range after initial import.
    case flow
    /// An actively transmitting outbox message. The comet uses the sending
    /// account's persisted palette color.
    case sending(accountColorIndex: Int)
    case signal(SignalState)
    /// Account-memory consolidation. Never renders a determinate fill — only
    /// the mass (importing) and kindle (downloading) lanes do — and the
    /// determinate/steady forms are visually identical, so both share one
    /// `ActivityStripTempoTransitionIdentity`. `fraction` is whatever the
    /// upstream backfill/steady computation produces; it has no rendering
    /// effect. `nil` is the steady incremental form.
    case dreaming(fraction: Double?)
    /// Reply-model personalization. Never renders a determinate fill — only
    /// the mass (importing) and kindle (downloading) lanes do. `fraction` is
    /// step/total during a stepping run — it still drives the spectrum's
    /// settling jitter and the transition identity, a real visual distinction
    /// unlike dreaming/distill/precis; `nil` is the steady
    /// preparing/checkpointing form.
    case training(fraction: Double?)
    /// Semantic clustering — scattered message points gather around three
    /// centroids, hold as stable groups, then release and reform.
    case clustering
    /// Datafying (interpretation) — a field of body marks compresses inward into
    /// a short bright essence over the faint baseline lane (never a determinate
    /// fill — only the mass/kindle lanes fill). `fraction` still drives the
    /// pipeline's tempo-readout percentage.
    case distill(fraction: Double)
    /// Summarizing — two curved arcs close inward, meeting to ring the dense
    /// core over the faint baseline lane (never a determinate fill, and the
    /// pipeline/on-demand forms are visually identical, so both share one
    /// transition identity). Used by both the pipeline summarizing stage
    /// (`fraction` drives the tempo-readout percentage) and the on-demand
    /// summary generation (`nil`).
    case precis(fraction: Double?)
    /// Digesting — an attachment sheet is scanned into evidence marks, which
    /// resolve into one compact abstract. Indeterminate attachment-summary
    /// activity, distinct from the message-summary Precis motif.
    case digest
    /// Translating — scrambled source marks resolve into clean target marks.
    /// Indeterminate generative-model activity (no fraction) in indigo→cyan.
    case cipher
    /// Asking — a question dot and an answer dot lean in and link. Indeterminate.
    case converse
    /// Categorizing — a pass attaches a tag-cap to each mark. Indeterminate.
    case tag
    /// Resolving — candidates are compared with canonical tags, then either
    /// settle into a matching identity or establish a provisional identity.
    /// Indeterminate.
    case resolve
    /// Drafting — word-marks appear one by one behind a blinking caret. Indeterminate.
    case typewriter
    /// Compiling — a gate sweeps across candidate marks, splitting each into a
    /// kept track (rising, brightened) or a discarded track (dropping, fading).
    /// Indeterminate.
    case sift
    /// Questioning — a lens sweeps the source, raising a question at each point. Indeterminate.
    case probe
    /// Extracting — marks are drawn out of a container one by one. Indeterminate.
    case pull
    /// Remembering — scattered traces drift inward and merge into a core. Indeterminate.
    case consolidate
    /// Refining — a jittery spread tightens and sharpens into a clean line. Indeterminate.
    case hone
    /// Learning — a row of bars adjusts its heights toward a learned profile. Indeterminate.
    case weights
    /// Embedding — a sweep quantizes irregular source marks into uniform points. Indeterminate.
    case encode
    /// Captioning — an outline traces a shape, then caption words emit from it. Indeterminate.
    case trace
    /// Model warm-up (loading / downloading an on-device model at startup, when
    /// it outlasts the splash). A spark sweeps a band of filaments, kindling each
    /// into a unified "online" glow, then holds and re-arms — a one-time
    /// warm-up read. `fraction == nil` is the indeterminate in-memory load;
    /// `fraction` present drives a determinate fill lane beneath (downloading).
    case kindling(fraction: Double?)
    /// Model loading into memory (the indeterminate warm-up). Parameter blocks
    /// fly in from outside the band and lock into a fixed layout in scattered
    /// order until the model is resident, then dim and re-load. The chosen
    /// loading motif; `.kindling` is retained for the determinate downloading
    /// state. Phase envelope: `ActivityStripGaugeMath.dockingFrame`.
    case docking
}

extension GaugeMode {
    /// The shortest complete visual turn for this gauge. Transitions use this
    /// value as their boundary so a newly selected state never cuts through a
    /// motif partway through its loop. Static gauges and Reduce Motion retain
    /// a one-second readability floor because they have no moving cycle.
    func presentationCycleDuration(reduceMotion: Bool) -> TimeInterval {
        guard reduceMotion == false else { return 1 }
        switch self {
        case .mass:
            return 1
        case .flow:
            return ActivityStripGauge.flowCycleSeconds
        case .sending:
            return ActivityStripGauge.sendingCycleSeconds
        case .signal(let state):
            switch state {
            case .watching:
                return ActivityStripGauge.heartbeatCycleSeconds
            case .ready:
                return 1
            case .pending:
                return ActivityStripGauge.pendingHoldCycleSeconds
            case .connecting, .authing:
                return ActivityStripGauge.connectPulseCycleSeconds
            case .syncing:
                return ActivityStripGauge.syncPulseCycleSeconds
            case .checkingGaps, .verifyingDeletions:
                return ActivityStripGauge.gapCheckCycleSeconds
            case .polling:
                return ActivityStripGauge.pollPingCycleSeconds
            case .newMail:
                return ActivityStripGauge.newMailEventDuration
            case .deletionsPending:
                return ActivityStripGauge.reconcileTallyCycle
            case .deletionsUpdated:
                return ActivityStripGauge.deletionUpdatedEventDuration
            case .reconnecting:
                return ActivityStripGauge.reconnectCycleSeconds
            case .needsAttention:
                return ActivityStripGauge.attentionPulseCycleSeconds
            }
        case .dreaming, .training:
            return ActivityStripGauge.coalescenceCycleSeconds
        case .clustering:
            return ActivityStripGauge.clusteringCycleSeconds
        case .distill:
            return ActivityStripGauge.distillCycleSeconds
        case .precis:
            return ActivityStripGauge.precisCycleSeconds
        case .digest:
            return ActivityStripGauge.digestCycleSeconds
        case .cipher:
            return ActivityStripGauge.cipherCycleSeconds
        case .converse:
            return ActivityStripGauge.converseCycleSeconds
        case .tag:
            return ActivityStripGauge.tagCycleSeconds
        case .resolve:
            return ActivityStripGauge.resolvingCycleSeconds
        case .typewriter:
            return ActivityStripGauge.typewriterCycleSeconds
        case .sift:
            return ActivityStripGauge.siftCycleSeconds
        case .probe:
            return ActivityStripGauge.probeCycleSeconds
        case .pull:
            return ActivityStripGauge.pullCycleSeconds
        case .consolidate:
            return ActivityStripGauge.consolidateCycleSeconds
        case .hone:
            return ActivityStripGauge.honeCycleSeconds
        case .weights:
            return ActivityStripGauge.weightsCycleSeconds
        case .encode:
            return ActivityStripGauge.encodeCycleSeconds
        case .trace:
            return ActivityStripGauge.traceCycleSeconds
        case .kindling:
            return ActivityStripGauge.kindleCycleSeconds
        case .docking:
            return ActivityStripGauge.dockingCycleSeconds
        }
    }

    /// One-shot events begin when their queued presentation actually becomes
    /// visible, rather than expiring while another state finishes its cycle.
    func startingTransient(at startedAt: Date) -> GaugeMode {
        guard case .signal(let state) = self else { return self }
        switch state {
        case .newMail(_, let count):
            return .signal(.newMail(eventStart: startedAt, count: count))
        case .deletionsUpdated(_, let count):
            return .signal(.deletionsUpdated(eventStart: startedAt, count: count))
        default:
            return self
        }
    }
}

enum SignalState: Equatable {
    case watching
    case ready
    /// A relevant IMAP job is queued but not yet running. Carries the "Hold"
    /// motif — a charged dot that swells blue→green, holds at the ready, then
    /// releases — instead of borrowing the watching heartbeat / static ready dot.
    case pending
    case connecting
    case authing
    case syncing(folder: String?)
    case checkingGaps(folder: String?)
    /// A running (non-gap-check) IMAP poll job. Radar-ping motif: a baseline dot
    /// emits an expanding ring that fades as it grows, then a short listen pause
    /// before the next ping — a periodic "ask the server, listen for a reply"
    /// probe, distinct from `.syncing`'s one-way traveling sweep.
    case polling(folder: String?)
    case newMail(eventStart: Date, count: Int)
    case deletionsPending(count: Int)
    case deletionsUpdated(eventStart: Date, count: Int)
    /// A running deletion-watch job. SELECT-only, no body fetches, no remote
    /// delete command. Uses a compact verification pulse instead of the
    /// destructive event-horizon collapse.
    case verifyingDeletions(folder: String?)
    case reconnecting(attempt: Int)
    case needsAttention
}

struct ActivityStripGauge: View {
    let mode: GaugeMode
    let animationStartedAt: Date?

    init(mode: GaugeMode, animationStartedAt: Date? = nil) {
        self.mode = mode
        self.animationStartedAt = animationStartedAt
    }

    /// Animation durations for Signal vocabulary transient states.
    /// Single-sourced in OhiaCore so the event-stamping window in
    /// ActivityStripView stays in sync with the animation length here.
    static let newMailEventDuration: TimeInterval = PipelineActivityPresentation.activityNewMailEventDuration
    static let deletionUpdatedEventDuration: TimeInterval = PipelineActivityPresentation.activityDeletionUpdatedEventDuration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localAnimationStartedAt = Date.now

    private func cyclePhase(at date: Date, cycleSeconds: TimeInterval) -> Double {
        return Self.presentationCyclePhase(
            at: date,
            startedAt: animationStartedAt ?? localAnimationStartedAt,
            cycleSeconds: cycleSeconds
        )
    }

    nonisolated static func presentationCyclePhase(
        at date: Date,
        startedAt: Date,
        cycleSeconds: TimeInterval
    ) -> Double {
        guard cycleSeconds > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        let remainder = elapsed.truncatingRemainder(dividingBy: cycleSeconds)
        let normalized = remainder < 0 ? remainder + cycleSeconds : remainder
        return normalized / cycleSeconds
    }

    nonisolated static func massAccessibilityPercent(fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    var body: some View {
        switch mode {
        case .mass(let fraction):
            massGauge(fraction: fraction)
        case .flow:
            flowGauge
        case .sending(let accountColorIndex):
            sendingGauge(accountColorIndex: accountColorIndex)
        case .signal(let state):
            signalGauge(state: state)
        case .dreaming(let fraction):
            dreamingGauge(fraction: fraction)
        case .training(let fraction):
            trainingGauge(fraction: fraction)
        case .clustering:
            clusteringGauge
        case .distill(let fraction):
            distillGauge(fraction: fraction)
        case .precis(let fraction):
            precisGauge(fraction: fraction)
        case .digest:
            digestGauge
        case .cipher:
            cipherGauge
        case .converse:
            converseGauge
        case .tag:
            tagGauge
        case .resolve:
            resolvingGauge
        case .typewriter:
            typewriterGauge
        case .sift:
            siftGauge
        case .probe:
            probeGauge
        case .pull:
            pullGauge
        case .consolidate:
            consolidateGauge
        case .hone:
            honeGauge
        case .weights:
            weightsGauge
        case .encode:
            encodeGauge
        case .trace:
            traceGauge
        case .kindling(let fraction):
            kindleGauge(fraction: fraction)
        case .docking:
            dockingGauge()
        }
    }

    // MARK: - Mass mode (initial IMAP acquisition fill)
    @ViewBuilder
    private func massGauge(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.trackSurface)
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [Self.mockupBlue, Self.mockupGreen],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * clamped, height: 4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: clamped)
            }
            .clipShape(.rect(cornerRadius: 2))
        }
        .frame(height: 4)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Initial mail import")
        .accessibilityValue("\(Self.massAccessibilityPercent(fraction: fraction)) percent")
    }

    // MARK: - Flow mode (later historical IMAP backfill packets)
    fileprivate static let flowCycleSeconds: TimeInterval = 2.6
    private static let flowPacketWidthFraction: Double = 0.14
    private static let flowPacketCount: Int = 3

    // MARK: - Signal mode constants
    /// Ordinary Signal states use the compact 4 px slot. The creation and
    /// deletion event animations use the 36 px lane from ActivityStripView.html.
    private static let steadySignalSlotHeight: CGFloat = 4
    private static let eventSignalSlotHeight: CGFloat = 36
    private static let baselineHeight: CGFloat = 1
    private static let trackMinWidth: CGFloat = 40
    fileprivate static let heartbeatCycleSeconds: TimeInterval = 3.2
    fileprivate static let attentionPulseCycleSeconds: TimeInterval = 1.6
    /// Pending "Hold" cycle — swell, hold at the ready, release.
    fileprivate static let pendingHoldCycleSeconds: TimeInterval = 2.4
    /// Continuous-animation TimelineView cadence — used for breathing dots,
    /// traveling pulses, and flow packets. Targeting 60 fps keeps the tiny
    /// Signal marks from reading as steppy on Retina displays.
    private static let steadyStateAnimationInterval: TimeInterval = OhiaAnimationCadence.frameInterval
    /// Event-animation TimelineView cadence — used for the short Signal
    /// transient marks in `progress-bar-states.html` and ActivityStripView.html.
    private static let eventAnimationInterval: TimeInterval = OhiaAnimationCadence.frameInterval
    fileprivate static let connectPulseCycleSeconds: TimeInterval = 0.9
    fileprivate static let syncPulseCycleSeconds: TimeInterval = 2.2
    /// Radar-ping cadence: one ping ring per cycle with a short listen pause.
    fileprivate static let pollPingCycleSeconds: TimeInterval = 2.0
    fileprivate static let gapCheckCycleSeconds: TimeInterval = 2.6
    fileprivate static let reconnectCycleSeconds: TimeInterval = 2.8
    fileprivate static let sendingCycleSeconds: TimeInterval = 2.4
    private static let sendingTailLength: CGFloat = 92
    private static let sendingParticleSpacing: CGFloat = 4

    private static let mockupBlue = Color(.sRGB, red: 0x4a / 255, green: 0x9e / 255, blue: 0xff / 255, opacity: 1)
    private static let mockupGreen = OhiaColors.ohiaGreen
    private static let mockupCyan = Color(.sRGB, red: 140 / 255, green: 242 / 255, blue: 242 / 255, opacity: 1)
    private static let mockupRed = Color(.sRGB, red: 255 / 255, green: 102 / 255, blue: 80 / 255, opacity: 1)
    private static let mockupAmber = Color(.sRGB, red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255, opacity: 1)
    /// Lighter amber for the "server" side of a reconcile tally pair, so the two
    /// converging beads read as distinct ledgers against `mockupAmber`.
    private static let mockupAmberSoft = Color(.sRGB, red: 0xf5 / 255, green: 0xc6 / 255, blue: 0x5a / 255, opacity: 1)
    private static let mockupGray = Color(.sRGB, red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255, opacity: 1)
    private static let trackSurface = Color.white.opacity(0.08)
    private static let signalRule = Color.white.opacity(0.18)
    /// Soft periwinkle "night" tint paired with green for the dreaming gauge.
    private static let mockupIndigo = Color(.sRGB, red: 124 / 255, green: 131 / 255, blue: 253 / 255, opacity: 1)
    /// Cool near-white for the distilled "essence" / knot core in the stage
    /// motifs, used sparingly.
    private static let mockupEssence = Color(.sRGB, red: 0.94, green: 1.0, blue: 0.97, opacity: 1)

    // MARK: - Sending mode (account-color comet)
    @ViewBuilder
    private func sendingGauge(accountColorIndex: Int) -> some View {
        let accountColor = AccountColorPalette
            .color(forIndex: accountColorIndex)
            .swiftUIColor

        if reduceMotion {
            sendingCometCanvas(accountColor: accountColor, phase: 0.65)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let startedAt = animationStartedAt ?? localAnimationStartedAt
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                let phase = elapsed.truncatingRemainder(dividingBy: Self.sendingCycleSeconds)
                    / Self.sendingCycleSeconds
                sendingCometCanvas(accountColor: accountColor, phase: phase)
            }
        }
    }

    private func sendingCometCanvas(accountColor: Color, phase: Double) -> some View {
        Canvas { canvas, size in
            let centerY = size.height / 2
            // Begin on the track so even a fast SMTP transaction visibly
            // presents the sending state before it transitions to `.sent`.
            let headX = size.width * phase

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: centerY))
            baseline.addLine(to: CGPoint(x: size.width, y: centerY))
            canvas.stroke(baseline, with: .color(OhiaColors.glassBorder), lineWidth: 1)

            let particleCount = Int(Self.sendingTailLength / Self.sendingParticleSpacing)
            for index in stride(from: particleCount, through: 1, by: -1) {
                let distance = CGFloat(index) * Self.sendingParticleSpacing
                let x = headX - distance
                guard x >= -4, x <= size.width + 4 else { continue }

                let tailProgress = distance / Self.sendingTailLength
                let strength = pow(1 - tailProgress, 2)
                let radius = 0.45 + 1.55 * strength
                let rect = CGRect(
                    x: x - radius,
                    y: centerY - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                canvas.fill(
                    Path(ellipseIn: rect),
                    with: .color(accountColor.opacity(0.12 + 0.68 * strength))
                )
            }

            let headLayers: [(radius: CGFloat, opacity: Double)] = [
                (8.0, 0.10), (5.0, 0.22), (2.6, 0.95),
            ]
            for (radius, opacity) in headLayers {
                let rect = CGRect(
                    x: headX - radius,
                    y: centerY - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                canvas.fill(
                    Path(ellipseIn: rect),
                    with: .color(accountColor.opacity(opacity))
                )
            }
        }
        .frame(height: Self.eventSignalSlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sending mail")
    }

    // MARK: - Clustering mode

    fileprivate static let clusteringCycleSeconds: TimeInterval = 4.2
    private static let clusteringPoints: [ClusteringPoint] = [
        .init(start: .init(x: 0.03, y: 0.24), cluster: 0, offset: .init(x: -0.040, y: -0.09)),
        .init(start: .init(x: 0.10, y: 0.74), cluster: 2, offset: .init(x: -0.038, y: 0.08)),
        .init(start: .init(x: 0.18, y: 0.44), cluster: 1, offset: .init(x: -0.035, y: -0.10)),
        .init(start: .init(x: 0.26, y: 0.78), cluster: 0, offset: .init(x: 0.036, y: 0.08)),
        .init(start: .init(x: 0.32, y: 0.18), cluster: 2, offset: .init(x: 0.035, y: -0.08)),
        .init(start: .init(x: 0.39, y: 0.61), cluster: 1, offset: .init(x: 0.000, y: 0.11)),
        .init(start: .init(x: 0.46, y: 0.31), cluster: 0, offset: .init(x: 0.000, y: -0.12)),
        .init(start: .init(x: 0.53, y: 0.82), cluster: 2, offset: .init(x: 0.000, y: 0.12)),
        .init(start: .init(x: 0.59, y: 0.19), cluster: 1, offset: .init(x: 0.039, y: -0.08)),
        .init(start: .init(x: 0.66, y: 0.68), cluster: 0, offset: .init(x: -0.034, y: 0.09)),
        .init(start: .init(x: 0.74, y: 0.36), cluster: 2, offset: .init(x: -0.034, y: -0.09)),
        .init(start: .init(x: 0.81, y: 0.75), cluster: 1, offset: .init(x: -0.038, y: 0.08)),
        .init(start: .init(x: 0.88, y: 0.22), cluster: 0, offset: .init(x: 0.038, y: -0.07)),
        .init(start: .init(x: 0.94, y: 0.58), cluster: 2, offset: .init(x: 0.040, y: 0.07)),
        .init(start: .init(x: 0.98, y: 0.35), cluster: 1, offset: .init(x: 0.000, y: -0.12)),
    ]

    @ViewBuilder
    private var clusteringGauge: some View {
        Group {
            if reduceMotion {
                clusteringCanvas(phase: 0.68)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let phase = cyclePhase(
                        at: timeline.date,
                        cycleSeconds: Self.clusteringCycleSeconds
                    )
                    clusteringCanvas(phase: phase)
                }
            }
        }
        .frame(height: Self.eventSignalSlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clustering messages")
        .accessibilityValue("Message points gather into three semantic clusters")
    }

    private func clusteringCanvas(phase: Double) -> some View {
        Canvas { context, size in
            let bandWidth = min(size.width * 0.42, 300)
            let bandOrigin = (size.width - bandWidth) / 2
            let centerY = size.height / 2 - 1
            let bandHeight = max(16, size.height - 8)
            let gather = Self.clusteringGatherProgress(phase: phase)
            let gatherCGFloat = CGFloat(gather)
            let centroidVisibility = Self.clusteringSmoothstep(
                min(max((gather - 0.45) / 0.55, 0), 1)
            )
            let pulse = 0.5 + 0.5 * sin(phase * .pi * 8)
            let centroids = [
                CGPoint(x: bandOrigin + bandWidth * 0.27, y: centerY - 2),
                CGPoint(x: bandOrigin + bandWidth * 0.50, y: centerY + 2),
                CGPoint(x: bandOrigin + bandWidth * 0.73, y: centerY - 1),
            ]

            var baseline = Path()
            baseline.move(to: CGPoint(x: bandOrigin, y: centerY))
            baseline.addLine(to: CGPoint(x: bandOrigin + bandWidth, y: centerY))
            context.stroke(
                baseline,
                with: .color(OhiaColors.glassBorderBright),
                lineWidth: 1
            )

            for (index, point) in Self.clusteringPoints.enumerated() {
                let start = CGPoint(
                    x: bandOrigin + point.start.x * bandWidth,
                    y: centerY + (point.start.y - 0.5) * bandHeight
                )
                let centroid = centroids[point.cluster]
                let target = CGPoint(
                    x: centroid.x + point.offset.x * bandWidth,
                    y: centroid.y + point.offset.y * bandHeight
                )
                let wobble = CGFloat(sin(phase * .pi * 10 + Double(index) * 1.7))
                    * 0.7
                    * CGFloat(gather * (1 - gather))
                let position = CGPoint(
                    x: start.x + (target.x - start.x) * gatherCGFloat,
                    y: start.y + (target.y - start.y) * gatherCGFloat + wobble
                )

                if centroidVisibility > 0.1 {
                    var relationship = Path()
                    relationship.move(to: position)
                    relationship.addLine(to: centroid)
                    context.stroke(
                        relationship,
                        with: .color(
                            OhiaColors.accentBlueGlow.opacity(0.16 * centroidVisibility)
                        ),
                        lineWidth: 0.7
                    )
                }

                let diameter = CGFloat(3.4 + 1.2 * gather)
                let pointRect = CGRect(
                    x: position.x - diameter / 2,
                    y: position.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: pointRect),
                    with: .color(OhiaColors.accentPurple.opacity(0.80))
                )
                context.fill(
                    Path(ellipseIn: pointRect.insetBy(dx: 0.8, dy: 0.8)),
                    with: .color(OhiaColors.accentBlueGlow.opacity(0.25 + 0.65 * gather))
                )
            }

            for centroid in centroids {
                let ringDiameter = CGFloat(8 + 2 * pulse)
                let ringRect = CGRect(
                    x: centroid.x - ringDiameter / 2,
                    y: centroid.y - ringDiameter / 2,
                    width: ringDiameter,
                    height: ringDiameter
                )
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(
                        OhiaColors.accentBlueGlow.opacity(0.35 * centroidVisibility)
                    ),
                    lineWidth: 1
                )
                let coreDiameter = CGFloat(3.5 + pulse)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: centroid.x - coreDiameter / 2,
                        y: centroid.y - coreDiameter / 2,
                        width: coreDiameter,
                        height: coreDiameter
                    )),
                    with: .color(
                        OhiaColors.chipActiveForeground.opacity(centroidVisibility)
                    )
                )
            }
        }
    }

    private static func clusteringGatherProgress(phase: Double) -> Double {
        let raw: Double
        switch phase {
        case ..<0.14:
            raw = 0
        case ..<0.56:
            raw = (phase - 0.14) / 0.42
        case ..<0.78:
            raw = 1
        default:
            raw = 1 - (phase - 0.78) / 0.22
        }
        return clusteringSmoothstep(min(max(raw, 0), 1))
    }

    private static func clusteringSmoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private nonisolated struct ClusteringPoint {
        let start: CGPoint
        let cluster: Int
        let offset: CGPoint
    }

    // MARK: - Background-activity gauge constants (dreaming / training)
    /// Both background-activity gauges use a slightly taller lane than the 4 px
    /// steady slot so the coalescing node and the spectrum bars have headroom,
    /// while staying far shorter than the 36 px event lane.
    private static let backgroundActivitySlotHeight: CGFloat = 14
    fileprivate static let coalescenceCycleSeconds: TimeInterval = 3.6
    private static let coalescenceMoteCount = 5
    /// Bar-to-bar spacing target for the weight spectrum; the actual count is
    /// derived from the spectrum band width (not the full track).
    private static let spectrumBarPitch: CGFloat = 7
    private static let spectrumMaxBarHeight: CGFloat = 10
    /// All band-based motifs — the stage motifs (distill / fold / précis) and
    /// every generation motif — draw inside a compact, centered band so the
    /// animated content reads as a substantial, consistent share of the bar rather
    /// than sprawling edge-to-edge or hiding in a tiny center cluster. The
    /// determinate progress lane beneath still spans the full slot. The band is a
    /// fixed fraction of the live track width (`motifBandFraction`) so it stays
    /// the same proportion of the bar at any window size; a small floor keeps it
    /// legible on a squeezed strip. Training's weight spectrum shares this width.
    private static let motifBandFraction: CGFloat = 0.4
    private static let motifBandMinWidth: CGFloat = 40
    /// The centered animated-band width for a given track width — a uniform ~40%
    /// of the bar, floored so it never collapses on a narrow strip and capped at
    /// the track width itself.
    static func motifBandWidth(_ trackWidth: CGFloat) -> CGFloat {
        guard trackWidth.isFinite, trackWidth > 0 else { return motifBandMinWidth }
        return min(trackWidth, max(motifBandMinWidth, trackWidth * motifBandFraction))
    }
    fileprivate static let distillCycleSeconds: TimeInterval = 2.8
    fileprivate static let precisCycleSeconds: TimeInterval = 3.0
    fileprivate static let digestCycleSeconds: TimeInterval = 3.4
    fileprivate static let cipherCycleSeconds: TimeInterval = 3.0
    fileprivate static let converseCycleSeconds: TimeInterval = 3.0
    fileprivate static let tagCycleSeconds: TimeInterval = 3.0
    fileprivate static let resolvingCycleSeconds: TimeInterval = 3.4
    fileprivate static let typewriterCycleSeconds: TimeInterval = 3.2
    fileprivate static let siftCycleSeconds: TimeInterval = 3.0
    fileprivate static let probeCycleSeconds: TimeInterval = 3.0
    fileprivate static let pullCycleSeconds: TimeInterval = 3.0
    fileprivate static let consolidateCycleSeconds: TimeInterval = 3.2
    fileprivate static let honeCycleSeconds: TimeInterval = 3.0
    fileprivate static let weightsCycleSeconds: TimeInterval = 3.0
    fileprivate static let encodeCycleSeconds: TimeInterval = 3.0
    fileprivate static let traceCycleSeconds: TimeInterval = 3.2
    /// Slightly slower than the gerunds: the kindle's long lit-hold should feel
    /// like a calm one-time warm-up, not a busy loop.
    fileprivate static let kindleCycleSeconds: TimeInterval = 2.8
    /// Blocks-docking (model loading) cadence + layout.
    fileprivate static let dockingCycleSeconds: TimeInterval = 2.9
    private static let dockingSlots = 5
    /// Scattered order in which the slots dock (not left→right).
    private static let dockingOrder: [Int] = [2, 4, 0, 3, 1]

    @ViewBuilder
    private var flowGauge: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.trackSurface)
                    .frame(height: 4)
                if reduceMotion {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [Self.mockupBlue, Self.mockupGreen],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * 0.28, height: 4)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        flowPackets(context: context, geo: geo)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 2))
        }
        .frame(height: 4)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .alignmentGuide(VerticalAlignment.center) { dimension in
            // Lifts the gauge to the cap-height midline of the neighboring
            // "IMAP backfilling/polling mail" text — SwiftUI's geometric
            // center sits below uppercase visual midline by ~6 pt at this
            // font size.
            dimension[VerticalAlignment.center] + 6
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Historical mail backfill")
        .accessibilityValue("In progress")
    }

    @ViewBuilder
    private func flowPackets(context: TimelineViewDefaultContext, geo: GeometryProxy) -> some View {
        let trackWidth = geo.size.width
        let packetWidth = trackWidth * Self.flowPacketWidthFraction
        ForEach(0..<Self.flowPacketCount, id: \.self) { i in
            let offsetSeconds = TimeInterval(i) * Self.flowCycleSeconds / Double(Self.flowPacketCount)
            let particleTime = context.date.addingTimeInterval(-offsetSeconds)
            let phase = cyclePhase(at: particleTime, cycleSeconds: Self.flowCycleSeconds)
            let offsetFraction = ActivityStripGaugeMath.flowParticleOffset(
                phase: phase,
                packetWidthFraction: Self.flowPacketWidthFraction
            )
            let opacity = ActivityStripGaugeMath.flowParticleOpacity(phase: phase)
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(
                    stops: [
                        Gradient.Stop(color: .clear, location: 0.00),
                        Gradient.Stop(color: Self.mockupBlue, location: 0.35),
                        Gradient.Stop(color: Self.mockupGreen, location: 0.75),
                        Gradient.Stop(color: .clear, location: 1.00),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: packetWidth, height: 4)
                .opacity(opacity)
                // .position centers the view at (x, y) in the parent's
                // coordinate space — independent of any ZStack alignment.
                // Packet's leading edge sits at trackWidth * offsetFraction
                // when its center is at offsetFraction * trackWidth + packetWidth/2.
                .position(
                    x: trackWidth * offsetFraction + packetWidth / 2,
                    y: geo.size.height / 2
                )
        }
    }

    // MARK: - Background lane (shared by dreaming / training)

    /// The base lane the background-activity motifs sit on: a thin baseline rule
    /// when steady, or a track + determinate gradient fill when a fraction is
    /// known. Mirrors mass mode's track/fill so progress reads the same way.
    /// Only `kindleGauge` (downloading) still calls this with a real fraction;
    /// `dreamingGauge`, `trainingGauge`, `stageMotifGauge` (distill/precis),
    /// and `dockingGauge` always pass `fraction: nil` — those lanes never fill.
    @ViewBuilder
    private func backgroundLane(
        width w: CGFloat,
        centerY cy: CGFloat,
        fraction: Double?,
        fillColors: [Color]
    ) -> some View {
        if let fraction {
            let clamped = min(max(fraction, 0), 1)
            let fillWidth = max(3, w * CGFloat(clamped))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.trackSurface)
                    .frame(width: w, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: fillColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: fillWidth, height: 4)
            }
            .frame(width: w, alignment: .leading)
            .position(x: w / 2, y: cy)
        } else {
            Rectangle()
                .fill(Self.signalRule)
                .frame(width: w, height: Self.baselineHeight)
                .position(x: w / 2, y: cy)
        }
    }

    // MARK: - Dreaming gauge (coalescence)

    @ViewBuilder
    private func dreamingGauge(fraction: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = Self.backgroundActivitySlotHeight / 2
            ZStack {
                // Dreaming never renders a determinate fill — only the mass
                // (importing) and kindle (downloading) lanes do. `fraction` is
                // retained upstream for step/progress bookkeeping only.
                backgroundLane(width: w, centerY: cy, fraction: nil, fillColors: [])
                if reduceMotion {
                    // Frozen mid-cycle: motes condensed into the bright node.
                    coalescenceMotes(phase: 0.5, width: w, centerY: cy)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        let phase = cyclePhase(
                            at: context.date, cycleSeconds: Self.coalescenceCycleSeconds
                        )
                        coalescenceMotes(phase: phase, width: w, centerY: cy)
                    }
                }
            }
            .frame(width: w, height: Self.backgroundActivitySlotHeight)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func coalescenceMotes(phase: Double, width w: CGFloat, centerY cy: CGFloat) -> some View {
        let conv = ActivityStripGaugeMath.coalescenceConvergence(phase: phase)
        let flash = max(0, (conv - 0.8) / 0.2)
        let beadDiameter = CGFloat(4.0 + 5.0 * conv)
        ZStack {
            ForEach(0..<Self.coalescenceMoteCount, id: \.self) { i in
                let baseFrac = (Double(i) + 0.5) / Double(Self.coalescenceMoteCount)
                let x = CGFloat(ActivityStripGaugeMath.lerp(Double(w) * baseFrac, Double(w) / 2, conv))
                let yOff = CGFloat((baseFrac - 0.5) * 2.0) * 3.0 * CGFloat(1 - conv)
                let dim = 1 - 0.5 * conv
                let moteColor = i.isMultiple(of: 2) ? Self.mockupGreen : Self.mockupIndigo
                let moteOpacity = 0.35 + 0.5 * dim
                Circle()
                    .fill(moteColor)
                    .frame(width: 3, height: 3)
                    .opacity(moteOpacity)
                    .shadow(color: moteColor.opacity(0.6 * moteOpacity), radius: 2)
                    .position(x: x, y: cy + yOff)
            }
            ZStack {
                Circle()
                    .fill(Self.mockupGreen)
                    .frame(width: beadDiameter, height: beadDiameter)
                    .opacity(0.25 + 0.75 * conv)
                    .shadow(color: Self.mockupGreen.opacity(0.7 * conv), radius: 4)
                if flash > 0 {
                    Circle()
                        .fill(Color.white)
                        .frame(width: beadDiameter * 0.55, height: beadDiameter * 0.55)
                        .opacity(0.85 * flash)
                        .blur(radius: 1)
                }
            }
            .position(x: w / 2, y: cy)
        }
    }

    // MARK: - Training gauge (weight spectrum)

    /// Number of spectrum bars that fill the live track width, so the spectrum
    /// spans most of the gauge rather than sitting in a centered cluster.
    static func spectrumBarCount(trackWidth: CGFloat) -> Int {
        guard trackWidth.isFinite, trackWidth > 0 else { return 6 }
        return min(64, max(6, Int((trackWidth / spectrumBarPitch).rounded(.down))))
    }

    @ViewBuilder
    private func trainingGauge(fraction: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = Self.backgroundActivitySlotHeight / 2
            let jitter = fraction.map { 1 - min(max($0, 0), 1) } ?? 1.0
            ZStack {
                // Training never renders a determinate fill — only the mass
                // (importing) and kindle (downloading) lanes do. `fraction`
                // still drives the spectrum's settling jitter above.
                backgroundLane(width: w, centerY: cy, fraction: nil, fillColors: [])
                if reduceMotion {
                    spectrumBars(at: Date(timeIntervalSinceReferenceDate: 0), width: w, centerY: cy, jitter: jitter)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        spectrumBars(at: context.date, width: w, centerY: cy, jitter: jitter)
                    }
                }
            }
            .frame(width: w, height: Self.backgroundActivitySlotHeight)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func spectrumBars(at date: Date, width w: CGFloat, centerY cy: CGFloat, jitter: Double) -> some View {
        // The pips occupy the standard centered ~40% motif band (shared with
        // every other gerund), not the full track, so the weight spectrum reads
        // as a focused cluster the same width as the rest.
        let bandWidth = Self.motifBandWidth(w)
        let originX = (w - bandWidth) / 2
        let count = Self.spectrumBarCount(trackWidth: bandWidth)
        let pitch = bandWidth / CGFloat(count)
        let barWidth = min(3, pitch * 0.5)
        // The bars must live inside an explicit ZStack (matching
        // `coalescenceMotes`). A bare `ForEach` of `.position` views is not
        // reliably bounded by the enclosing frame in every container context —
        // without the ZStack the positioned bars can cascade out of the lane
        // instead of overlaying within it.
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let cycle = 1.6 + Double(i) * 0.21
                let phase = cyclePhase(at: date, cycleSeconds: cycle)
                let hNorm = ActivityStripGaugeMath.spectrumBarHeight(phase: phase, index: i, jitter: jitter)
                let barHeight = Self.spectrumMaxBarHeight * CGFloat(0.2 + 0.85 * hNorm)
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Self.mockupCyan)
                    .frame(width: barWidth, height: barHeight)
                    .opacity(0.45 + 0.45 * hNorm)
                    .shadow(color: Self.mockupCyan.opacity(0.4), radius: 2)
                    .position(x: originX + pitch * (CGFloat(i) + 0.5), y: cy)
            }
        }
    }

    // MARK: - Stage motif gauges (datafying / summarizing)
    //
    // Ported from the ActivityStripGuide decision gallery. Each motif draws inside a
    // compact centered band over the shared `backgroundLane`, in the gauge
    // family's blue→green, so the stage reads as a sibling of the mass fill
    // while carrying its own identity. Neither stage renders a determinate
    // fill — only the mass (importing) and kindle (downloading) lanes do; the
    // pipeline's real fraction still drives the tempo readout's percentage
    // text. Phase math lives in ActivityStripGaugeMath.{distill,precis}Frame.

    @ViewBuilder
    private func distillGauge(fraction: Double) -> some View {
        stageMotifGauge(cycleSeconds: Self.distillCycleSeconds, fraction: fraction) { phase, w, h in
            distillMotif(phase: phase, width: w, height: h)
        }
    }

    @ViewBuilder
    private func precisGauge(fraction: Double?) -> some View {
        stageMotifGauge(cycleSeconds: Self.precisCycleSeconds, fraction: fraction) { phase, w, h in
            precisMotif(phase: phase, width: w, height: h)
        }
    }

    /// Shared scaffold: a blue→green lane + a time-driven motif in the compact
    /// centered band, both centered on the same `cy` so the motif always sits on
    /// its lane. The lane always renders as the faint baseline — datafying and
    /// summarizing never fill, whether driven by real pipeline progress or the
    /// nil on-demand form — while the motif keeps its own cyclic animation.
    /// Centering the baseline — rather than pinning it low — keeps the
    /// datafying / summarizing stages vertically aligned with each other and
    /// with the centered import mass fill, and matches the generation motifs'
    /// centered baseline. Freezes at a representative mid-cycle phase under
    /// Reduce Motion. `fraction` is accepted only so callers can keep passing
    /// the real pipeline progress through for non-visual bookkeeping
    /// (transition identity, tempo-readout percentage); it no longer affects
    /// this view's rendering.
    @ViewBuilder
    private func stageMotifGauge<Motif: View>(
        cycleSeconds: TimeInterval,
        fraction: Double?,
        @ViewBuilder motif: @escaping (Double, CGFloat, CGFloat) -> Motif
    ) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = Self.backgroundActivitySlotHeight
            // Lane is always the faint baseline; the motif's `cy = h / 2 - 1`
            // still anchors the dots/arcs/core to it.
            let laneCenterY = h / 2 - 1
            ZStack {
                backgroundLane(width: w, centerY: laneCenterY, fraction: nil, fillColors: [])
                if reduceMotion {
                    motif(0.6, w, h)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        let phase = cyclePhase(at: context.date, cycleSeconds: cycleSeconds)
                        motif(phase, w, h)
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func distillMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let centerX = w / 2
        let stage = ActivityStripGaugeMath.distillFrame(phase: phase)
        let appear = stage.appear
        let c = stage.compression
        let n = 9
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let baseX = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: 12)
                let x = baseX + (centerX - baseX) * CGFloat(c)
                let op = (1 - c) * 0.45 * appear
                if op > 0.01 {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(Self.mockupBlue)
                        .frame(width: 1.5, height: 6)
                        .opacity(op)
                        .position(x: x, y: cy)
                }
            }
            let essenceWidth = max(0.001, CGFloat(20) * CGFloat(c))
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(
                    colors: [Self.mockupBlue, Self.mockupGreen],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: essenceWidth, height: 4)
                .opacity((0.45 + 0.55 * c) * stage.fade * appear)
                .shadow(color: Self.mockupGreen.opacity(0.6 * c), radius: 3)
                .position(x: centerX, y: cy)
            if stage.flash > 0 {
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .opacity(0.85 * stage.flash)
                    .blur(radius: 0.6)
                    .position(x: centerX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    /// Arc radius stays small and fixed regardless of row width — only the
    /// arc's *position* (`gap`, below) travels across the band. Open radius
    /// matches the motif's original small hook footprint. Ring radius (at
    /// full squeeze, where each arc's vertical extent from `cy` equals the
    /// radius itself, since `halfSweep` reaches 90°) has to clear two
    /// bounds at once: it must sit outside the core dot's max radius (4.5,
    /// from `coreD` maxing at 9), and its painted stroke must still fit
    /// inside the row — `cy` sits only `backgroundActivitySlotHeight / 2 - 1`
    /// = 6pt below the row's top edge, leaving `6 - lineWidth / 2` ≈ 5.2pt
    /// of headroom. 4.8 clears both with a small margin.
    private static let precisOpenHookRadius: CGFloat = 6
    private static let precisRingRadius: CGFloat = 4.8

    @ViewBuilder
    private func precisMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let centerX = w / 2
        let stage = ActivityStripGaugeMath.precisFrame(phase: phase)
        let appear = stage.appear
        let squeeze = stage.squeeze
        // `gap` is a *position* (how far each hook sits from center) that
        // closes all the way to 0 so the two hooks' centers coincide at full
        // squeeze. `radius` is the hook's own size and stays small and
        // fixed the whole time, independent of row width.
        let gap = CGFloat(ActivityStripGaugeMath.lerp(Double(max(13, bandW / 2 - 10)), 0, squeeze))
        let radius = CGFloat(ActivityStripGaugeMath.lerp(
            Double(Self.precisOpenHookRadius), Double(Self.precisRingRadius), squeeze
        ))
        let leftCenter = CGPoint(x: centerX - gap, y: cy)
        let rightCenter = CGPoint(x: centerX + gap, y: cy)
        let coreD = CGFloat(2 + 7 * squeeze)
        ZStack {
            let m = 6
            ForEach(0..<m, id: \.self) { i in
                let f = (CGFloat(i) + 0.5) / CGFloat(m)
                let x = leftCenter.x + 2 * gap * f
                let op = 0.30 * (1 - 0.6 * squeeze) * appear
                Circle()
                    .fill(Self.mockupBlue)
                    .frame(width: 2.2, height: 2.2)
                    .opacity(op)
                    .position(x: x, y: cy)
            }
            PrecisArcShape(leading: true, center: leftCenter, radius: radius, squeeze: squeeze)
                .stroke(Self.mockupBlue.opacity(appear),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            PrecisArcShape(leading: false, center: rightCenter, radius: radius, squeeze: squeeze)
                .stroke(Self.mockupBlue.opacity(appear),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(Self.mockupGreen)
                .frame(width: coreD, height: coreD)
                .opacity((0.35 + 0.65 * squeeze) * appear)
                .shadow(color: Self.mockupGreen.opacity(0.6 * squeeze), radius: 3)
                .position(x: centerX, y: cy)
            if stage.flash > 0 {
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                    .opacity(0.85 * stage.flash)
                    .blur(radius: 0.5)
                    .position(x: centerX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - Digest gauge (attachment summarization)

    /// A small attachment sheet is read line by line; lifted evidence marks
    /// cross the lane and settle into a shorter abstract. The left-to-right
    /// document grammar stays visibly distinct from Precis, whose arcs
    /// squeeze inward to ring a center.
    private var digestGauge: some View {
        TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
            Canvas { canvas, size in
                let phase = reduceMotion
                    ? 0.72
                    : cyclePhase(
                        at: context.date,
                        cycleSeconds: Self.digestCycleSeconds
                    )
                Self.drawDigest(in: &canvas, size: size, phase: phase)
            }
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Digesting an attachment")
    }

    private static func drawDigest(
        in canvas: inout GraphicsContext,
        size: CGSize,
        phase: Double
    ) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let centerY = height / 2 - 1
        let bandWidth = motifBandWidth(width)
        let bandX = (width - bandWidth) / 2
        let cycleEnvelope = digestRamp(phase, from: 0.00, to: 0.08)
            * (1 - digestRamp(phase, from: 0.91, to: 1.00))

        let baseline = CGRect(x: 0, y: centerY - 0.5, width: width, height: 1)
        canvas.fill(
            Path(roundedRect: baseline, cornerRadius: 0.5),
            with: .color(OhiaColors.glassBorder.opacity(0.85))
        )

        let documentCenterX = bandX + min(12, bandWidth * 0.24)
        let abstractCenterX = bandX + bandWidth - min(12, bandWidth * 0.24)
        let documentRect = CGRect(
            x: documentCenterX - 5,
            y: centerY - 6,
            width: 10,
            height: 12
        )
        let documentFade = 1 - digestRamp(phase, from: 0.64, to: 0.82)
        let documentOpacity = cycleEnvelope * documentFade

        for offset in stride(from: 2, through: 0, by: -1) {
            let sheet = documentRect.offsetBy(
                dx: CGFloat(-offset) * 1.25,
                dy: CGFloat(offset) * 0.7
            )
            canvas.stroke(
                Path(roundedRect: sheet, cornerRadius: 1.4),
                with: .color(OhiaColors.accentBlue.opacity(
                    documentOpacity * (offset == 0 ? 0.90 : 0.28)
                )),
                lineWidth: offset == 0 ? 1.1 : 0.7
            )
        }

        let scanProgress = digestSmoothstep(digestRamp(phase, from: 0.10, to: 0.52))
        if documentOpacity > 0.01 {
            let scanY = documentRect.minY
                + 2
                + CGFloat(scanProgress) * (documentRect.height - 4)
            let scanRect = CGRect(
                x: documentRect.minX + 1.5,
                y: scanY,
                width: 7,
                height: 1
            )
            canvas.fill(
                Path(roundedRect: scanRect, cornerRadius: 0.5),
                with: .color(OhiaColors.ohiaGreen.opacity(documentOpacity * 0.85))
            )
        }

        let sourceOffsets: [CGFloat] = [-3.6, -1.2, 1.2, 3.6]
        for index in sourceOffsets.indices {
            let local = digestRamp(
                phase,
                from: 0.18 + Double(index) * 0.07,
                to: 0.61 + Double(index) * 0.07
            )
            guard local > 0, local < 1 else { continue }
            let travel = digestSmoothstep(local)
            let travelEnvelope = sin(travel * .pi) * cycleEnvelope
            let x = digestLerp(documentRect.maxX + 2, abstractCenterX - 8, travel)
            let y = digestLerp(centerY + sourceOffsets[index], centerY, travel)
            let markWidth = digestLerp(4.8, 2.0, travel)
            let markRect = CGRect(
                x: x - markWidth / 2,
                y: y - 0.8,
                width: markWidth,
                height: 1.6
            )
            canvas.fill(
                Path(roundedRect: markRect, cornerRadius: 0.8),
                with: .color(OhiaColors.accentBlueGlow.opacity(travelEnvelope * 0.90))
            )
        }

        let abstractWidths: [CGFloat] = [12, 8.5, 6]
        let abstractOffsets: [CGFloat] = [-3, 0, 3]
        let abstractFade = cycleEnvelope
            * (1 - digestRamp(phase, from: 0.93, to: 1.00))
        for index in abstractWidths.indices {
            let drawProgress = digestSmoothstep(digestRamp(
                phase,
                from: 0.48 + Double(index) * 0.08,
                to: 0.66 + Double(index) * 0.08
            ))
            let lineWidth = abstractWidths[index] * CGFloat(drawProgress)
            guard lineWidth > 0.01 else { continue }
            let lineRect = CGRect(
                x: abstractCenterX - abstractWidths[index] / 2,
                y: centerY + abstractOffsets[index] - 0.85,
                width: lineWidth,
                height: 1.7
            )
            canvas.fill(
                Path(roundedRect: lineRect, cornerRadius: 0.85),
                with: .color(OhiaColors.ohiaGreen.opacity(
                    abstractFade * (0.65 + 0.30 * drawProgress)
                ))
            )
        }

        let completion = digestSmoothstep(digestRamp(phase, from: 0.72, to: 0.84))
        if completion > 0 {
            let glowRect = CGRect(
                x: abstractCenterX - 8,
                y: centerY - 5,
                width: 16,
                height: 10
            )
            canvas.stroke(
                Path(roundedRect: glowRect, cornerRadius: 2),
                with: .color(OhiaColors.ohiaGreen.opacity(
                    cycleEnvelope * completion * 0.35
                )),
                lineWidth: 0.8
            )
        }
    }

    private static func digestRamp(
        _ value: Double,
        from start: Double,
        to end: Double
    ) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }

    private static func digestSmoothstep(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }

    private static func digestLerp(
        _ start: CGFloat,
        _ end: CGFloat,
        _ progress: Double
    ) -> CGFloat {
        start + (end - start) * CGFloat(progress)
    }

    /// Evenly distribute `count` marks across `width` with side margins.
    private static func stageMarkX(_ i: Int, count n: Int, width w: CGFloat, margin: CGFloat) -> CGFloat {
        guard n > 0 else { return w / 2 }
        let usable = max(0, w - 2 * margin)
        return margin + usable * CGFloat((Double(i) + 0.5) / Double(n))
    }

    // MARK: - Kindle gauge (model loading / downloading)
    //
    // The startup warm-up motif, shown when an on-device model load or download
    // outlasts the 12 s splash. A spark sweeps a band of dim filaments, kindling
    // each into a held "online" glow, then dims and re-arms — a one-time warm-up
    // read distinct from the cyclic gerund motifs and the determinate stages.
    // When `fraction` is known (downloading) it rides a determinate fill lane in
    // the same gray→green family; when `nil` (in-memory loading) it sits over the
    // faint baseline. Phase math lives in ActivityStripGaugeMath.kindleFrame.

    @ViewBuilder
    private func kindleGauge(fraction: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = Self.backgroundActivitySlotHeight
            let laneCenterY = h / 2 - 1
            ZStack {
                backgroundLane(
                    width: w, centerY: laneCenterY, fraction: fraction,
                    fillColors: [Self.mockupGray.opacity(0.45), Self.mockupGreen.opacity(0.6)]
                )
                if reduceMotion {
                    // Freeze fully-lit, mid-glow — the representative "online" frame.
                    kindleMotif(phase: 0.72, width: w, height: h)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        let phase = cyclePhase(at: context.date, cycleSeconds: Self.kindleCycleSeconds)
                        kindleMotif(phase: phase, width: w, height: h)
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func kindleMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.kindleFrame(phase: phase)
        let appear = stage.appear
        let glow = stage.glow
        let spark = stage.spark
        let n = 5
        let margin: CGFloat = 8
        // The kindling head sweeps the band; a filament kindles as the head
        // reaches it (ramping over ~6 pt so the lights come on softly, not snap).
        let headX = bandX0 + margin + (bandW - 2 * margin) * CGFloat(stage.sweep)
        ZStack {
            // Unified "online" glow under the whole band once the sweep lands.
            if glow > 0.01 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [Self.mockupGreen, Self.mockupEssence],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(0.001, bandW - 2 * margin + 6), height: 3)
                    .opacity(0.5 * glow * appear)
                    .shadow(color: Self.mockupGreen.opacity(0.6 * glow), radius: 3)
                    .position(x: w / 2, y: cy)
            }
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: margin)
                let litAmount = min(1, max(0, (headX - x) / 6))
                let barHeight = 4 + 6 * litAmount
                // Cold filament (dim gray) crossfades into a kindled green one.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.mockupGray)
                    .frame(width: 2, height: 4)
                    .opacity(0.4 * appear * Double(1 - litAmount))
                    .position(x: x, y: cy)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.mockupGreen)
                    .frame(width: 2.4, height: barHeight)
                    .opacity((0.5 + 0.45 * glow) * appear * Double(litAmount))
                    .shadow(color: Self.mockupGreen.opacity(0.5 * Double(litAmount)), radius: 2)
                    .position(x: x, y: cy)
            }
            // Kindling-head spark, only while the sweep is still travelling.
            if spark > 0.01 && stage.sweep < 1 {
                Circle()
                    .fill(Self.mockupEssence)
                    .frame(width: 5, height: 5)
                    .opacity(0.9 * spark * appear)
                    .blur(radius: 0.5)
                    .shadow(color: Self.mockupGreen.opacity(0.7), radius: 3)
                    .position(x: headX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - Docking gauge (model loading into memory)
    //
    // The chosen loading motif (ported from the ActivityStripGuide candidate study).
    // Parameter blocks fly in from outside the band and lock into fixed slots in
    // scattered order until the model's layout is resident, then a dim reset and
    // re-load. Indeterminate — loading only; downloading keeps the determinate
    // `.kindling` motif. Sits over the same faint centered baseline as the other
    // motifs. Phase envelope lives in ActivityStripGaugeMath.dockingFrame.

    @ViewBuilder
    private func dockingGauge() -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = Self.backgroundActivitySlotHeight
            let laneCenterY = h / 2 - 1
            ZStack {
                // Loading is indeterminate — the faint baseline, no determinate fill.
                backgroundLane(width: w, centerY: laneCenterY, fraction: nil, fillColors: [])
                if reduceMotion {
                    dockingMotif(phase: 0.7, width: w, height: h)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        let phase = cyclePhase(at: context.date, cycleSeconds: Self.dockingCycleSeconds)
                        dockingMotif(phase: phase, width: w, height: h)
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func dockingMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let frame = ActivityStripGaugeMath.dockingFrame(phase: phase)
        let loaded = frame.loaded
        let env = frame.env
        let n = Self.dockingSlots
        let margin: CGFloat = 8
        let blk = min((bandW - 2 * margin) / CGFloat(n) * 0.62, 5)
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let order = Self.dockingOrder[i]
                let start = Double(order) / Double(n)
                let local = min(max((loaded - start) / (1.0 / Double(n)), 0), 1)
                let slotX = bandX0Docking(i, bandW: bandW, width: w, margin: margin, count: n)
                let fromY = cy + (i % 2 == 0 ? -9 : 9)
                let y = fromY + (cy - fromY) * CGFloat(local)
                // Empty slot outline (the layout the block docks into).
                RoundedRectangle(cornerRadius: 1)
                    .stroke(Self.mockupGray.opacity(0.4 * env), lineWidth: 1)
                    .frame(width: blk, height: blk)
                    .position(x: slotX, y: cy)
                if local > 0.001 {
                    let docked = local >= 1
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Self.mockupGreen)
                        .frame(width: blk, height: blk)
                        .opacity((0.5 + 0.5 * local) * env)
                        .shadow(color: Self.mockupGreen.opacity((docked ? 0.5 : 0.2) * env), radius: docked ? 2 : 1)
                        .position(x: slotX, y: y)
                    if i % 2 == 1 {
                        // The two blocks that rise from below (the 2nd and 4th from
                        // the left) light to a white orb as they lock in and hold it
                        // for the rest of the cycle, so both read as a matched round
                        // pair. Blocks dropping in from above keep the brief round
                        // snap-in flash (the `else` branch) and stay green.
                        let whiteness = ActivityStripGaugeMath.dockLockWhiteness(local: local)
                        if whiteness > 0.001 {
                            Circle()
                                .fill(Self.mockupEssence)
                                .frame(width: blk + 3, height: blk + 3)
                                .opacity(whiteness * env)
                                .shadow(color: Self.mockupEssence.opacity(0.5 * whiteness * env), radius: 2)
                                .position(x: slotX, y: y)
                        }
                    } else if local > 0.82 && local < 1 {
                        Circle().fill(Self.mockupEssence)
                            .frame(width: blk + 3, height: blk + 3)
                            .opacity(0.7 * (local - 0.82) / 0.18 * env)
                            .position(x: slotX, y: cy)
                    }
                }
            }
        }
        .frame(width: w, height: h)
    }

    /// Slot x for the docking motif — evenly spread across the centered band,
    /// matching the other band motifs' `stageMarkX` distribution.
    private func bandX0Docking(_ i: Int, bandW: CGFloat, width w: CGFloat, margin: CGFloat, count: Int) -> CGFloat {
        let bandX0 = (w - bandW) / 2
        return bandX0 + Self.stageMarkX(i, count: count, width: bandW, margin: margin)
    }

    // MARK: - Generation motif gauges (translating / asking / categorizing / resolving / drafting)
    //
    // Indeterminate generative-model activities — no progress fraction, so the
    // motif sits over a faint centered baseline (like the steady dreaming /
    // training forms) in the generative indigo→cyan accent. Ported from the
    // ActivityStripGuide candidate study; phase math lives in
    // ActivityStripGaugeMath.{cipher,converse,tag,typewriter}Frame.

    private var cipherGauge: some View {
        generationMotifGauge(cycleSeconds: Self.cipherCycleSeconds) { phase, w, h in
            cipherMotif(phase: phase, width: w, height: h)
        }
    }

    private var converseGauge: some View {
        generationMotifGauge(cycleSeconds: Self.converseCycleSeconds) { phase, w, h in
            converseMotif(phase: phase, width: w, height: h)
        }
    }

    private var tagGauge: some View {
        generationMotifGauge(cycleSeconds: Self.tagCycleSeconds) { phase, w, h in
            tagMotif(phase: phase, width: w, height: h)
        }
    }

    private var resolvingGauge: some View {
        generationMotifGauge(cycleSeconds: Self.resolvingCycleSeconds) { phase, w, h in
            resolvingMotif(phase: phase, width: w, height: h)
        }
    }

    private var typewriterGauge: some View {
        generationMotifGauge(cycleSeconds: Self.typewriterCycleSeconds) { phase, w, h in
            typewriterMotif(phase: phase, width: w, height: h)
        }
    }

    /// Shared scaffold for the indeterminate generation motifs: a faint centered
    /// baseline + a phase-driven motif in the compact band. Freezes at a
    /// representative mid-cycle phase under Reduce Motion.
    @ViewBuilder
    private func generationMotifGauge<Motif: View>(
        cycleSeconds: TimeInterval,
        @ViewBuilder motif: @escaping (Double, CGFloat, CGFloat) -> Motif
    ) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = Self.backgroundActivitySlotHeight
            let cy = h / 2 - 1
            ZStack {
                Rectangle()
                    .fill(Self.signalRule)
                    .frame(width: w, height: Self.baselineHeight)
                    .position(x: w / 2, y: cy)
                if reduceMotion {
                    motif(0.6, w, h)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                        let phase = cyclePhase(at: context.date, cycleSeconds: cycleSeconds)
                        motif(phase, w, h)
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: Self.backgroundActivitySlotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
    }

    @ViewBuilder
    private func cipherMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.cipherFrame(phase: phase)
        let appear = stage.appear
        let resolve = stage.resolve
        let n = 7
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let baseX = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: 10)
                let jitter = CGFloat(sin(phase * .pi * 6 + Double(i) * 1.7)) * 4 * CGFloat(1 - resolve)
                ZStack {
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo)
                        .frame(width: 1.5, height: 6).opacity(1 - resolve)
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupCyan)
                        .frame(width: 2, height: 8).opacity(resolve)
                }
                .opacity((0.45 + 0.4 * resolve) * appear)
                .shadow(color: Self.mockupCyan.opacity(0.5 * resolve), radius: 2)
                .position(x: baseX + jitter, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func converseMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let centerX = w / 2
        let stage = ActivityStripGaugeMath.converseFrame(phase: phase)
        let appear = stage.appear
        let lean = stage.lean
        let margin: CGFloat = 12
        let qStart = bandX0 + margin
        let aStart = bandX0 + bandW - margin
        let qx = qStart + (centerX - 6 - qStart) * CGFloat(lean)
        let ax = aStart + (centerX + 6 - aStart) * CGFloat(lean)
        ZStack {
            RoundedRectangle(cornerRadius: 1)
                .fill(LinearGradient(colors: [Self.mockupIndigo, Self.mockupCyan], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(0.001, ax - qx), height: 2)
                .opacity(0.85 * lean * appear)
                .position(x: (qx + ax) / 2, y: cy)
            Circle().fill(Self.mockupIndigo)
                .frame(width: 5, height: 5).opacity(appear)
                .shadow(color: Self.mockupIndigo.opacity(0.6), radius: 2)
                .position(x: qx, y: cy)
            Circle().fill(Self.mockupCyan)
                .frame(width: 5, height: 5).opacity(appear)
                .shadow(color: Self.mockupCyan.opacity(0.6), radius: 2)
                .position(x: ax, y: cy)
            if lean > 0.85 {
                Circle().fill(Color.white)
                    .frame(width: 4, height: 4).opacity(0.7 * (lean - 0.85) / 0.15).blur(radius: 0.5)
                    .position(x: centerX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func tagMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.tagFrame(phase: phase)
        let appear = stage.appear
        let sweep = stage.sweep
        let margin: CGFloat = 10
        let sweepX = bandX0 + margin + (bandW - 2 * margin) * CGFloat(sweep)
        let n = 7
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: margin)
                let tagged = x <= sweepX
                RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo)
                    .frame(width: 2, height: 6).opacity((tagged ? 0.7 : 0.45) * appear)
                    .position(x: x, y: cy + 1.5)
                if tagged {
                    RoundedRectangle(cornerRadius: 0.5).fill(Self.mockupCyan)
                        .frame(width: 4, height: 2.5).opacity(0.9 * appear)
                        .shadow(color: Self.mockupCyan.opacity(0.5), radius: 1.5)
                        .position(x: x, y: cy - 3.5)
                }
            }
            if sweep < 1 {
                RoundedRectangle(cornerRadius: 1).fill(Self.mockupCyan)
                    .frame(width: 1.5, height: 11).opacity(0.7 * appear)
                    .position(x: sweepX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    /// A comparison sweep passes over the canonical row while two candidates
    /// settle: one is absorbed by an existing identity, while the other becomes
    /// a new outlined provisional identity. This stays visually distinct from
    /// categorizing's tag caps and IMAP reconciliation's opposing bead pairs.
    @ViewBuilder
    private func resolvingMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.tagFrame(phase: phase)
        let outro = ActivityStripGaugeMath.distillFrame(phase: phase)
        let settle = CGFloat(stage.sweep)
        let opacity = stage.appear * outro.fade
        let margin: CGFloat = 8
        let topY = cy - 3
        let bottomY = cy + 3
        let scanX = bandX0 + margin + (bandW - 2 * margin) * settle
        let winnerX = bandX0 + bandW * 0.48
        let provisionalX = bandX0 + bandW * 0.90
        let matchedStartX = bandX0 + bandW * 0.12
        let provisionalStartX = bandX0 + bandW * 0.62
        let matchedX = matchedStartX + (winnerX - matchedStartX) * settle
        let matchedY = bottomY + (topY - bottomY) * settle
        let newX = provisionalStartX + (provisionalX - provisionalStartX) * settle
        let newY = bottomY + (topY - bottomY) * settle

        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let x = bandX0 + bandW * (0.18 + CGFloat(index) * 0.30)
                ZStack {
                    Circle()
                        .fill(Self.mockupIndigo)
                        .frame(width: 4, height: 4)
                        .opacity(opacity * (index == 1 ? 1 - stage.sweep : 0.55))
                    if index == 1 {
                        Circle()
                            .fill(Self.mockupCyan)
                            .frame(width: 5, height: 5)
                            .opacity(opacity * stage.sweep)
                            .shadow(color: Self.mockupCyan.opacity(0.55 * stage.sweep), radius: 2)
                    }
                }
                .position(x: x, y: topY)
            }

            RoundedRectangle(cornerRadius: 0.5)
                .fill(Self.mockupCyan)
                .frame(width: 1, height: 12)
                .opacity(opacity * (1 - stage.sweep))
                .position(x: scanX, y: cy)

            Circle()
                .fill(Self.mockupIndigo)
                .frame(width: 4, height: 4)
                .opacity(opacity * (1 - stage.sweep))
                .position(x: matchedX, y: matchedY)

            ZStack {
                Circle()
                    .fill(Self.mockupIndigo)
                    .frame(width: 4, height: 4)
                    .opacity(opacity * (1 - stage.sweep))
                Circle()
                    .stroke(Self.mockupCyan, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
                    .opacity(opacity * stage.sweep)
                    .shadow(color: Self.mockupCyan.opacity(0.45 * stage.sweep), radius: 2)
            }
            .position(x: newX, y: newY)

            Circle()
                .fill(Color.white)
                .frame(width: 4, height: 4)
                .opacity(opacity * outro.flash * 0.75)
                .blur(radius: 0.4)
                .position(x: winnerX, y: topY)
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func typewriterMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.typewriterFrame(phase: phase)
        let appear = stage.appear
        let n = 7
        let revealed = Int(Double(n + 1) * stage.reveal)
        let blink = phase.truncatingRemainder(dividingBy: 0.5) < 0.25
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                if i < revealed {
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo)
                        .frame(width: 5, height: 3).opacity(0.7 * appear)
                        .position(x: bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: 10), y: cy)
                }
            }
            let caretIdx = min(revealed, n - 1)
            let caretX = bandX0 + Self.stageMarkX(caretIdx, count: n, width: bandW, margin: 10) + 4
            RoundedRectangle(cornerRadius: 0.5).fill(Self.mockupCyan)
                .frame(width: 1.5, height: 8)
                .opacity((blink ? 1.0 : 0.3) * appear)
                .position(x: caretX, y: cy)
        }
        .frame(width: w, height: h)
    }

    // MARK: - Generation motif gauges II (questioning / extracting / remembering / refining / learning / embedding / describing)
    //
    // The seven model activities that previously fell back to the training
    // spectrum, now each with its own indeterminate indigo→cyan motif over the
    // faint baseline. Ported from the ActivityStripGuide candidate study; phase math
    // lives in ActivityStripGaugeMath.{probe,pull,consolidate,hone,weights,encode,trace}Frame.

    private var siftGauge: some View {
        generationMotifGauge(cycleSeconds: Self.siftCycleSeconds) { phase, w, h in
            siftMotif(phase: phase, width: w, height: h)
        }
    }

    private var probeGauge: some View {
        generationMotifGauge(cycleSeconds: Self.probeCycleSeconds) { phase, w, h in
            probeMotif(phase: phase, width: w, height: h)
        }
    }

    private var pullGauge: some View {
        generationMotifGauge(cycleSeconds: Self.pullCycleSeconds) { phase, w, h in
            pullMotif(phase: phase, width: w, height: h)
        }
    }

    private var consolidateGauge: some View {
        generationMotifGauge(cycleSeconds: Self.consolidateCycleSeconds) { phase, w, h in
            consolidateMotif(phase: phase, width: w, height: h)
        }
    }

    private var honeGauge: some View {
        generationMotifGauge(cycleSeconds: Self.honeCycleSeconds) { phase, w, h in
            honeMotif(phase: phase, width: w, height: h)
        }
    }

    private var weightsGauge: some View {
        generationMotifGauge(cycleSeconds: Self.weightsCycleSeconds) { phase, w, h in
            weightsMotif(phase: phase, width: w, height: h)
        }
    }

    private var encodeGauge: some View {
        generationMotifGauge(cycleSeconds: Self.encodeCycleSeconds) { phase, w, h in
            encodeMotif(phase: phase, width: w, height: h)
        }
    }

    private var traceGauge: some View {
        generationMotifGauge(cycleSeconds: Self.traceCycleSeconds) { phase, w, h in
            traceMotif(phase: phase, width: w, height: h)
        }
    }

    /// Sift (compiling) — a gate sweeps the band; each candidate mark it passes
    /// forks onto a kept track (rises, brightens to cyan, stays) or a discarded
    /// track (drops, fades out), reading as source triage rather than probe's
    /// uniform "mark everything" sweep.
    @ViewBuilder
    private func siftMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.siftFrame(phase: phase)
        let appear = stage.appear
        let margin: CGFloat = 10
        let gateX = bandX0 + margin + (bandW - 2 * margin) * CGFloat(stage.sweep)
        let n = 7
        let keptIndices: Set<Int> = [0, 1, 3, 4, 6]
        ZStack {
            if stage.sweep < 1 {
                RoundedRectangle(cornerRadius: 0.6).fill(Self.mockupCyan.opacity(0.6 * appear))
                    .frame(width: 1, height: 13)
                    .position(x: gateX, y: cy)
            }
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: margin)
                let sifted = x <= gateX
                let kept = keptIndices.contains(i)
                let dy: CGFloat = sifted ? (kept ? -3 : 3) : 0
                let opacity = sifted ? (kept ? 0.9 : 0.0) : 0.45
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(kept && sifted ? Self.mockupCyan : Self.mockupIndigo)
                    .frame(width: 2, height: 6)
                    .opacity(opacity * appear)
                    .position(x: x, y: cy + dy)
            }
        }
        .frame(width: w, height: h)
    }

    /// Probe (questioning) — a lens sweeps the band; each mark it passes raises a
    /// cyan question dot above the line, with a ring at the moving lens.
    @ViewBuilder
    private func probeMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.probeFrame(phase: phase)
        let appear = stage.appear
        let margin: CGFloat = 10
        let lensX = bandX0 + margin + (bandW - 2 * margin) * CGFloat(stage.sweep)
        let n = 7
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: margin)
                let probed = x <= lensX
                RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo)
                    .frame(width: 2, height: 6).opacity((probed ? 0.7 : 0.4) * appear)
                    .position(x: x, y: cy + 1)
                if probed {
                    Circle().fill(Self.mockupCyan)
                        .frame(width: 2.5, height: 2.5).opacity(0.9 * appear)
                        .shadow(color: Self.mockupCyan.opacity(0.5), radius: 1.5)
                        .position(x: x, y: cy - 4.5)
                }
            }
            if stage.sweep < 1 {
                Circle().stroke(Self.mockupCyan.opacity(0.85 * appear), lineWidth: 1.2)
                    .frame(width: 9, height: 9).position(x: lensX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    /// Pull (extracting) — marks are drawn one by one out of a left container and
    /// line up to the right, crossfading indigo → cyan as they extract.
    @ViewBuilder
    private func pullMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.pullFrame(phase: phase)
        let appear = stage.appear
        let margin: CGFloat = 10
        let containerX = bandX0 + margin + 4
        let n = 5
        // Lay the extracted marks in a row to the RIGHT of the container,
        // distributed across the remaining band, so they always pull outward
        // (never back through the box) and fill the same ~40% width as the other
        // motifs. The pitch is floored so the marks stay distinct on a narrow
        // strip where the band is at its minimum.
        let rowStart = containerX + 9
        let rowEnd = bandX0 + bandW - margin
        let slotPitch = max(6, (rowEnd - rowStart) / CGFloat(n - 1))
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .stroke(Self.mockupIndigo.opacity(0.5 * appear), lineWidth: 1)
                .frame(width: 8, height: 11)
                .position(x: containerX, y: cy)
            ForEach(0..<n, id: \.self) { i in
                let slotX = rowStart + CGFloat(i) * slotPitch
                let drawn = ActivityStripGaugeMath.smoothstep(
                    ActivityStripGaugeMath.clamp((stage.progress - Double(i) * 0.13) / 0.55, 0, 1)
                )
                let x = containerX + (slotX - containerX) * CGFloat(drawn)
                ZStack {
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo).opacity(1 - drawn)
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupCyan).opacity(drawn)
                }
                .frame(width: 4, height: 3).opacity(appear)
                .shadow(color: Self.mockupCyan.opacity(0.4 * drawn), radius: 1.5)
                .position(x: x, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    /// Consolidate (remembering) — scattered indigo traces orbit inward and merge
    /// into a single brightening cyan core.
    @ViewBuilder
    private func consolidateMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let centerX = w / 2
        // Spread the orbiting traces across the standard ~40% band (its
        // horizontal radius is half the band) so remembering reads at the same
        // width as the other motifs rather than a tiny fixed cluster.
        let orbitRX = max(6, (Self.motifBandWidth(w) - 4) / 2)
        let stage = ActivityStripGaugeMath.consolidateFrame(phase: phase)
        let appear = stage.appear
        let gather = stage.gather
        let merged = stage.merged
        let n = 6
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let ang = Double(i) / Double(n) * 2 * Double.pi
                let sx = centerX + CGFloat(cos(ang)) * orbitRX
                let sy = cy + CGFloat(sin(ang)) * 5
                let x = sx + (centerX - sx) * CGFloat(gather)
                let y = sy + (cy - sy) * CGFloat(gather)
                Circle().fill(Self.mockupIndigo)
                    .frame(width: 3, height: 3).opacity((1 - merged) * appear)
                    .position(x: x, y: y)
            }
            let coreD = CGFloat(3 + 5 * gather)
            Circle().fill(Self.mockupCyan)
                .frame(width: coreD, height: coreD)
                .opacity((0.3 + 0.7 * gather) * appear)
                .shadow(color: Self.mockupCyan.opacity(0.7 * gather), radius: 3)
                .position(x: centerX, y: cy)
        }
        .frame(width: w, height: h)
    }

    /// Hone (refining) — a jittery indigo spread tightens, lengthens, and
    /// crossfades to crisp cyan marks on a clean line.
    @ViewBuilder
    private func honeMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.honeFrame(phase: phase)
        let appear = stage.appear
        let sharp = stage.sharp
        let n = 9
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: 10)
                let jitter = CGFloat(sin(phase * .pi * 6 + Double(i) * 1.3)) * 4 * CGFloat(1 - sharp)
                ZStack {
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupIndigo).opacity(1 - sharp)
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupCyan).opacity(sharp)
                }
                .frame(width: 1.5 + 0.5 * CGFloat(sharp), height: 6 + 3 * CGFloat(sharp))
                .opacity((0.5 + 0.4 * sharp) * appear)
                .shadow(color: Self.mockupCyan.opacity(0.4 * sharp), radius: 1.5)
                .position(x: x, y: cy + jitter)
            }
        }
        .frame(width: w, height: h)
    }

    /// Weights (learning) — a row of bars wobbles, then settles its heights into
    /// a learned profile, filling bottom-to-top indigo → cyan.
    @ViewBuilder
    private func weightsMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.weightsFrame(phase: phase)
        let appear = stage.appear
        let adjust = stage.adjust
        let n = 7
        let target: [CGFloat] = [4, 8, 5, 10, 6, 9, 5]
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: 12)
                let h0: CGFloat = 5
                let wob = CGFloat(sin(phase * .pi * 6 + Double(i))) * 1.5 * CGFloat(1 - adjust)
                let barH = max(1, h0 + (target[i % target.count] - h0) * CGFloat(adjust) + wob)
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(LinearGradient(colors: [Self.mockupIndigo, Self.mockupCyan], startPoint: .bottom, endPoint: .top))
                    .frame(width: 2.5, height: barH)
                    .opacity((0.6 + 0.4 * adjust) * appear)
                    .shadow(color: Self.mockupCyan.opacity(0.4 * adjust), radius: 1.5)
                    .position(x: x, y: cy + 6 - barH / 2)
            }
        }
        .frame(width: w, height: h)
    }

    /// Encode (embedding) — a sweep converts irregular indigo source blocks into
    /// uniform cyan points as it advances across the band.
    @ViewBuilder
    private func encodeMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.encodeFrame(phase: phase)
        let appear = stage.appear
        let margin: CGFloat = 10
        let sweepX = bandX0 + margin + (bandW - 2 * margin) * CGFloat(stage.sweep)
        let n = 8
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let x = bandX0 + Self.stageMarkX(i, count: n, width: bandW, margin: margin)
                if x <= sweepX {
                    Circle().fill(Self.mockupCyan)
                        .frame(width: 3, height: 3).opacity(0.9 * appear)
                        .shadow(color: Self.mockupCyan.opacity(0.5), radius: 1.5)
                        .position(x: x, y: cy)
                } else {
                    let barH = CGFloat(5 + (i * 37) % 5)
                    RoundedRectangle(cornerRadius: 0.5).fill(Self.mockupIndigo)
                        .frame(width: 3, height: barH).opacity(0.55 * appear)
                        .position(x: x, y: cy)
                }
            }
            if stage.sweep < 1 {
                RoundedRectangle(cornerRadius: 1).fill(Self.mockupCyan)
                    .frame(width: 1.5, height: 11).opacity(0.8 * appear)
                    .shadow(color: Self.mockupCyan.opacity(0.6), radius: 2)
                    .position(x: sweepX, y: cy)
            }
        }
        .frame(width: w, height: h)
    }

    /// Trace (captioning) — an indigo outline draws around a shape, then cyan
    /// caption words emit from it one by one.
    @ViewBuilder
    private func traceMotif(phase: Double, width w: CGFloat, height h: CGFloat) -> some View {
        let cy = h / 2 - 1
        let bandW = Self.motifBandWidth(w)
        let bandX0 = (w - bandW) / 2
        let stage = ActivityStripGaugeMath.traceFrame(phase: phase)
        let appear = stage.appear
        let emit = stage.emit
        let margin: CGFloat = 12
        let boxX = bandX0 + margin + 6
        let words = 4
        // Emit the caption words across the full band so the trace motif fills
        // the same ~40% width as the others instead of clustering by the box.
        let wordStep = max(7, (bandW - 2 * margin - 16) / CGFloat(words - 1))
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .trim(from: 0, to: CGFloat(stage.drawn))
                .stroke(Self.mockupIndigo.opacity(0.85 * appear), lineWidth: 1.2)
                .frame(width: 10, height: 10)
                .position(x: boxX, y: cy)
            ForEach(0..<words, id: \.self) { i in
                let prog = ActivityStripGaugeMath.clamp((emit - Double(i) * 0.18) / 0.5, 0, 1)
                if prog > 0.001 {
                    let wx = boxX + 8 + CGFloat(i) * wordStep * CGFloat(prog)
                    RoundedRectangle(cornerRadius: 0.75).fill(Self.mockupCyan)
                        .frame(width: 4, height: 2.5).opacity(prog * appear)
                        .shadow(color: Self.mockupCyan.opacity(0.4), radius: 1)
                        .position(x: wx, y: cy)
                }
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - Signal mode (baseline + dispatcher)
    @ViewBuilder
    private func signalGauge(state: SignalState) -> some View {
        let slotHeight = Self.signalSlotHeight(for: state)
        GeometryReader { geo in
            ZStack {
                signalBaseline(state: state, width: geo.size.width, slotHeight: slotHeight)
                signalElement(state: state, width: geo.size.width, slotHeight: slotHeight)
            }
            .frame(width: geo.size.width, height: slotHeight, alignment: .center)
        }
        .frame(height: slotHeight)
        .frame(minWidth: Self.trackMinWidth, maxWidth: .infinity)
        .alignmentGuide(VerticalAlignment.center) { dimension in
            // Polling-mail traveling pulse otherwise sits below the cap-height
            // midline of neighboring "IMAP" — SwiftUI centers Text on its
            // geometric midline, not cap-height. Nudge up only in `.syncing`.
            let offset: CGFloat = if case .syncing = state { 6 } else { 0 }
            return dimension[VerticalAlignment.center] + offset
        }
    }

    private static func signalSlotHeight(for state: SignalState) -> CGFloat {
        switch state {
        case .newMail:
            // The formation motif uses the tall event lane. Deletion-watch and
            // deletion-updated states stay on the compact steady lane because
            // they are verification/reconcile signals, not destructive collapse.
            return eventSignalSlotHeight
        default:
            return steadySignalSlotHeight
        }
    }

    private func signalBaselineColor(for state: SignalState) -> Color {
        if case .needsAttention = state {
            return Self.mockupAmber.opacity(0.28)
        }
        return Self.signalRule
    }

    @ViewBuilder
    private func signalBaseline(state: SignalState, width: CGFloat, slotHeight: CGFloat) -> some View {
        Rectangle()
            .fill(signalBaselineColor(for: state))
            .frame(width: width, height: Self.baselineHeight)
            .position(x: width / 2, y: slotHeight / 2)
    }

    @ViewBuilder
    private func signalElement(state: SignalState, width: CGFloat, slotHeight: CGFloat) -> some View {
        ZStack {
            switch state {
            case .watching:
                watchingDot
            case .ready:
                readyDot
            case .pending:
                pendingDot
            case .deletionsPending(let count):
                reconcileTally(count: count, width: width, slotHeight: slotHeight)
            case .needsAttention:
                needsAttentionDot
            case .connecting:
                travelingPulse(
                    cycleSeconds: Self.connectPulseCycleSeconds,
                    color: Self.mockupGreen,
                    width: width,
                    slotHeight: slotHeight
                )
            case .authing:
                authingPulse(width: width, slotHeight: slotHeight)
            case .syncing:
                travelingPulse(
                    cycleSeconds: Self.syncPulseCycleSeconds,
                    color: Self.mockupGreen,
                    width: width,
                    slotHeight: slotHeight
                )
            case .checkingGaps:
                checkingGapsPulse(width: width, slotHeight: slotHeight)
            case .polling:
                pollingPing(width: width, slotHeight: slotHeight)
            case .newMail(let eventStart, let count):
                newMailEvent(eventStart: eventStart, count: count, width: width, slotHeight: slotHeight)
            case .deletionsUpdated(let eventStart, let count):
                deletionsUpdatedReconcile(eventStart: eventStart, count: count, width: width, slotHeight: slotHeight)
            case .verifyingDeletions:
                deletionWatchPulse(width: width, slotHeight: slotHeight)
            case .reconnecting:
                reconnectPulse(width: width, slotHeight: slotHeight)
            }
        }
        .frame(width: width, height: slotHeight, alignment: .center)
    }

    @ViewBuilder
    private var watchingDot: some View {
        if reduceMotion {
            Circle()
                .fill(Self.mockupBlue)
                .frame(width: 6, height: 6)
                .shadow(color: Self.mockupBlue.opacity(0.5), radius: 4)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.heartbeatCycleSeconds)
                let breath = ActivityStripGaugeMath.heartbeatBreathe(phase: phase)
                Circle()
                    .fill(Self.mockupBlue)
                    .frame(width: 6, height: 6)
                    .scaleEffect(breath.scale)
                    .opacity(breath.opacity)
                    .shadow(
                        color: Self.mockupBlue.opacity(0.25 + 0.40 * breath.unit),
                        radius: 4 + 6 * breath.unit
                    )
            }
        }
    }

    @ViewBuilder
    private var readyDot: some View {
        Circle()
            .fill(Self.mockupGray)
            .frame(width: 5, height: 5)
            .opacity(0.6)
    }

    /// Pending — a queued IMAP job. The "Hold" motif: a dot swells blue→green to
    /// the ready, holds at the peak, then releases, with a faint ring breathing
    /// out at the hold. Anticipatory rhythm (charged, waiting its turn), distinct
    /// from the watching heartbeat's smooth sinusoid. Frozen at the held peak
    /// under Reduce Motion.
    @ViewBuilder
    private var pendingDot: some View {
        if reduceMotion {
            Circle()
                .fill(Self.mockupGreen)
                .frame(width: 8, height: 8)
                .shadow(color: Self.mockupGreen.opacity(0.55), radius: 2)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.pendingHoldCycleSeconds)
                let charge = ActivityStripGaugeMath.holdCharge(phase: phase)
                let d = CGFloat(4.5 + 3.5 * charge)
                ZStack {
                    if charge > 0.5 {
                        let r = CGFloat(7 + 5 * charge)
                        Circle()
                            .stroke(Self.mockupGreen.opacity((charge - 0.5) * 0.9), lineWidth: 1)
                            .frame(width: r, height: r)
                    }
                    Circle()
                        .fill(Self.mockupBlue)
                        .frame(width: d, height: d)
                        .opacity(1 - charge)
                    Circle()
                        .fill(Self.mockupGreen)
                        .frame(width: d, height: d)
                        .opacity(charge)
                        .shadow(color: Self.mockupGreen.opacity(0.55 * charge), radius: 2)
                }
            }
        }
    }

    // MARK: - Reconcile tally (deletions reconciling)
    //
    // Steady reconciling state (`pendingDeletionCount > 0`): pending items stream
    // in from both lane edges — "local" from the left, "server" from the right —
    // meet on the baseline, and clear in a soft white spark with an expanding
    // amber ring. The pending count drives how many pairs are in flight.
    fileprivate static let reconcileTallyCycle: TimeInterval = 2.4
    private static let reconcileTallyMaxPairs = 10

    @ViewBuilder
    private func reconcileTally(count: Int, width: CGFloat, slotHeight: CGFloat) -> some View {
        if reduceMotion {
            reconcileTallyFrame(at: Date(timeIntervalSinceReferenceDate: 0), count: count, width: width, slotHeight: slotHeight)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                reconcileTallyFrame(at: context.date, count: count, width: width, slotHeight: slotHeight)
            }
        }
    }

    @ViewBuilder
    private func reconcileTallyFrame(at date: Date, count: Int, width w: CGFloat, slotHeight: CGFloat) -> some View {
        let pairs = min(max(count, 1), Self.reconcileTallyMaxPairs)
        let cy = slotHeight / 2
        let centerX = w / 2
        let leftStart: CGFloat = 6
        let rightStart = max(leftStart, w - 6)
        ForEach(0..<pairs, id: \.self) { i in
            let phase = cyclePhase(
                at: date.addingTimeInterval(Double(i) * Self.reconcileTallyCycle / Double(pairs)),
                cycleSeconds: Self.reconcileTallyCycle
            )
            if let spark = ActivityStripGaugeMath.reconcileTallySpark(phase: phase) {
                Circle()
                    .fill(Color.white)
                    .frame(width: CGFloat(3 + 5 * spark), height: CGFloat(3 + 5 * spark))
                    .opacity(0.9 * (1 - spark))
                    .blur(radius: 0.5)
                    .position(x: centerX, y: cy)
                Circle()
                    .strokeBorder(Self.mockupAmber.opacity(0.7 * (1 - spark)), lineWidth: 1)
                    .frame(width: CGFloat(4 + 10 * spark), height: CGFloat(4 + 10 * spark))
                    .position(x: centerX, y: cy)
            } else {
                let travel = CGFloat(ActivityStripGaugeMath.reconcileTallyTravel(phase: phase))
                reconcileTallyBead(color: Self.mockupAmber, x: leftStart + (centerX - leftStart) * travel, y: cy)
                reconcileTallyBead(color: Self.mockupAmberSoft, x: rightStart - (rightStart - centerX) * travel, y: cy)
            }
        }
    }

    private func reconcileTallyBead(color: Color, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: 4, height: 4)
            .shadow(color: color.opacity(0.6), radius: 3)
            .position(x: x, y: y)
    }

    @ViewBuilder
    private var needsAttentionDot: some View {
        if reduceMotion {
            Circle()
                .fill(Self.mockupAmber)
                .frame(width: 6, height: 6)
                .opacity(0.55)
                .scaleEffect(0.85)
                .shadow(color: Self.mockupAmber.opacity(0.7), radius: 4)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.attentionPulseCycleSeconds)
                let pulse = ActivityStripGaugeMath.attentionPulse(phase: phase)
                Circle()
                    .fill(Self.mockupAmber)
                    .frame(width: 6, height: 6)
                    .opacity(pulse.opacity)
                    .scaleEffect(pulse.scale)
                    .shadow(color: Self.mockupAmber.opacity(0.7 * pulse.opacity), radius: 4)
            }
        }
    }

    // MARK: - Signal mode traveling-pulse helpers

    @ViewBuilder
    private func travelingPulse(
        cycleSeconds: TimeInterval,
        color: Color,
        width: CGFloat,
        slotHeight: CGFloat,
        pulseWidth: CGFloat = 10,
        glowOpacity: Double = 0.6
    ) -> some View {
        if reduceMotion {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(glowOpacity), radius: 3)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: cycleSeconds)
                let pulse = ActivityStripGaugeMath.syncPulse(phase: phase)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: pulseWidth, height: 4)
                    .opacity(pulse.opacity)
                    .shadow(color: color.opacity(glowOpacity * pulse.opacity), radius: 4)
                    .position(
                        x: pulseWidth / 2 + CGFloat(pulse.position) * max(0, width - pulseWidth),
                        y: slotHeight / 2
                    )
            }
        }
    }

    @ViewBuilder
    private func authingPulse(width: CGFloat, slotHeight: CGFloat) -> some View {
        if reduceMotion {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.mockupGreen.opacity(0.55))
                    .frame(width: 10, height: 4)
                    .position(x: width / 2, y: slotHeight / 2)
                Circle()
                    .stroke(Self.mockupGreen.opacity(0.9), lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .position(x: width / 2, y: slotHeight / 2)
            }
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.connectPulseCycleSeconds)
                let pulse = ActivityStripGaugeMath.syncPulse(phase: phase)
                let gate = ActivityStripGaugeMath.authGatePulse(phase: phase)
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.mockupGreen)
                        .frame(width: 8, height: 4)
                        .opacity(pulse.opacity * 0.75)
                        .shadow(color: Self.mockupGreen.opacity(0.45 * pulse.opacity), radius: 4)
                        .position(
                            x: 4 + CGFloat(pulse.position) * max(0, width - 8),
                            y: slotHeight / 2
                        )
                    Circle()
                        .stroke(Self.mockupGreen.opacity(0.85 * gate.opacity), lineWidth: 1)
                        .frame(width: 6, height: 6)
                        .scaleEffect(gate.scale)
                        .opacity(gate.opacity)
                        .shadow(color: Self.mockupGreen.opacity(0.65 * gate.opacity), radius: 5)
                        .position(x: width / 2, y: slotHeight / 2)
                }
            }
        }
    }

    @ViewBuilder
    private func checkingGapsPulse(width: CGFloat, slotHeight: CGFloat) -> some View {
        ZStack {
            travelingPulse(
                cycleSeconds: Self.gapCheckCycleSeconds,
                color: Self.mockupBlue,
                width: width,
                slotHeight: slotHeight,
                pulseWidth: 8,
                glowOpacity: 0.55
            )
            if !reduceMotion {
                TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                    let phase = cyclePhase(at: context.date, cycleSeconds: Self.gapCheckCycleSeconds)
                    let ripple = ActivityStripGaugeMath.gapRipple(phase: phase)
                    if ripple.opacity > 0 {
                        Circle()
                            .stroke(Self.mockupBlue.opacity(0.7 * ripple.opacity), lineWidth: 1)
                            .frame(width: 4, height: 4)
                            .scaleEffect(ripple.scale)
                            .opacity(ripple.opacity)
                            .position(x: width - 4, y: slotHeight / 2)
                    }
                }
            }
        }
    }

    /// Deletion-watch verification — a running SELECT-only check for server-side
    /// disappearances. The amber probe keeps the deletion-sync color family but
    /// avoids the destructive black-hole/event-horizon motif.
    @ViewBuilder
    private func deletionWatchPulse(width: CGFloat, slotHeight: CGFloat) -> some View {
        ZStack {
            travelingPulse(
                cycleSeconds: Self.gapCheckCycleSeconds,
                color: Self.mockupAmberSoft,
                width: width,
                slotHeight: slotHeight,
                pulseWidth: 8,
                glowOpacity: 0.5
            )
            if !reduceMotion {
                TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                    let phase = cyclePhase(at: context.date, cycleSeconds: Self.gapCheckCycleSeconds)
                    let ripple = ActivityStripGaugeMath.gapRipple(phase: phase)
                    if ripple.opacity > 0 {
                        Circle()
                            .stroke(Self.mockupAmber.opacity(0.7 * ripple.opacity), lineWidth: 1)
                            .frame(width: 4, height: 4)
                            .scaleEffect(ripple.scale)
                            .opacity(ripple.opacity)
                            .position(x: width - 4, y: slotHeight / 2)
                    }
                }
            }
        }
    }

    /// Polling — a running IMAP poll job. Radar-ping motif: a green dot on the
    /// baseline flashes as it emits an expanding ring that fades while it grows,
    /// then a brief listen pause before the next ping. Distinct from `.syncing`'s
    /// one-way traveling sweep and `.pending`'s small breathing hold-ring by the
    /// large outward ring + the quiet gap. Frozen mid-expansion under Reduce
    /// Motion. Phase math lives in ActivityStripGaugeMath.pollFrame.
    @ViewBuilder
    private func pollingPing(width: CGFloat, slotHeight: CGFloat) -> some View {
        let cx = width / 2
        let cy = slotHeight / 2
        if reduceMotion {
            let frame = ActivityStripGaugeMath.pollFrame(phase: 0.4)
            ZStack {
                Circle()
                    .stroke(Self.mockupGreen.opacity(0.7 * frame.ringOpacity), lineWidth: 1)
                    .frame(width: 5 + 13 * frame.ringExpansion, height: 5 + 13 * frame.ringExpansion)
                    .position(x: cx, y: cy)
                Circle()
                    .fill(Self.mockupGreen)
                    .frame(width: 5, height: 5)
                    .opacity(frame.dot)
                    .shadow(color: Self.mockupGreen.opacity(0.55), radius: 3)
                    .position(x: cx, y: cy)
            }
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.pollPingCycleSeconds)
                let frame = ActivityStripGaugeMath.pollFrame(phase: phase)
                let ringD = 5 + 13 * frame.ringExpansion
                ZStack {
                    if frame.ringOpacity > 0.001 {
                        Circle()
                            .stroke(Self.mockupGreen.opacity(0.75 * frame.ringOpacity), lineWidth: 1)
                            .frame(width: ringD, height: ringD)
                            .shadow(color: Self.mockupGreen.opacity(0.4 * frame.ringOpacity), radius: 2)
                            .position(x: cx, y: cy)
                    }
                    Circle()
                        .fill(Self.mockupGreen)
                        .frame(width: 5, height: 5)
                        .opacity(frame.dot)
                        .shadow(color: Self.mockupGreen.opacity(0.6 * frame.dot), radius: 3)
                        .position(x: cx, y: cy)
                }
            }
        }
    }

    @ViewBuilder
    private func reconnectPulse(width: CGFloat, slotHeight: CGFloat) -> some View {
        if reduceMotion {
            Circle()
                .fill(Self.mockupAmber)
                .frame(width: 6, height: 6)
                .opacity(0.7)
                .shadow(color: Self.mockupAmber.opacity(0.5), radius: 3)
        } else {
            TimelineView(.periodic(from: .now, by: Self.steadyStateAnimationInterval)) { context in
                let phase = cyclePhase(at: context.date, cycleSeconds: Self.reconnectCycleSeconds)
                let pulse = ActivityStripGaugeMath.reconnectPulse(phase: phase)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.mockupAmber)
                    .frame(width: 8, height: 4)
                    .opacity(pulse.opacity)
                    .position(
                        x: min(width - 4, max(4, CGFloat(pulse.left) * width + 4)),
                        y: slotHeight / 2
                    )
            }
        }
    }

    // MARK: - Signal mode formation / deletion events

    @ViewBuilder
    private func newMailEvent(eventStart: Date, count: Int, width: CGFloat, slotHeight: CGFloat) -> some View {
        if reduceMotion {
            countBeadTrain(
                kind: .newMail,
                count: max(count, 1),
                width: width,
                slotHeight: slotHeight,
                phase: 0.25
            )
        } else {
            TimelineView(.periodic(from: .now, by: Self.eventAnimationInterval)) { context in
                let phase = ActivityStripGaugeMath.animationPhase(
                    at: context.date,
                    eventStart: eventStart,
                    durationSeconds: Self.newMailEventDuration
                )
                if let phase {
                    ZStack {
                        supernovaCometView(phase: phase, width: width, slotHeight: slotHeight)
                        countBeadTrain(kind: .newMail, count: count, width: width, slotHeight: slotHeight, phase: phase)
                        supernovaFlashCoreView(phase: phase, width: width, slotHeight: slotHeight)
                        supernovaShockwaveView(phase: phase, color: .inner, swiftColor: Self.mockupRed, width: width, slotHeight: slotHeight)
                        supernovaShockwaveView(phase: phase, color: .center, swiftColor: .white, width: width, slotHeight: slotHeight)
                        supernovaShockwaveView(phase: phase, color: .outer, swiftColor: Self.mockupCyan, width: width, slotHeight: slotHeight)
                        supernovaSettledBodyView(phase: phase, width: width, slotHeight: slotHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func supernovaCometView(phase: Double, width: CGFloat, slotHeight: CGFloat) -> some View {
        if let comet = ActivityStripGaugeMath.supernovaCometFrame(
            phase: phase,
            trackWidth: Double(width),
            baseWidth: 14
        ) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(
                    stops: [
                        Gradient.Stop(color: .clear, location: 0.00),
                        Gradient.Stop(color: Self.mockupGreen.opacity(0.6), location: 0.60),
                        Gradient.Stop(color: .white, location: 1.00),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: max(0.001, comet.width), height: 4)
                .opacity(comet.opacity)
                .shadow(color: Self.mockupGreen.opacity(0.7 * comet.opacity), radius: 4)
                .position(x: comet.leadingX + comet.width / 2, y: slotHeight / 2)
        }
    }

    @ViewBuilder
    private func supernovaFlashCoreView(phase: Double, width: CGFloat, slotHeight: CGFloat) -> some View {
        let core = ActivityStripGaugeMath.supernovaFlashCore(phase: phase)
        if core.opacity > 0 {
            let baseDiameter: CGFloat = 14
            Circle()
                .fill(RadialGradient(
                    colors: [.white, .white.opacity(0.8), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: (baseDiameter / 2) * core.scale + 0.001
                ))
                .frame(width: baseDiameter * core.scale, height: baseDiameter * core.scale)
                .opacity(core.opacity)
                .blur(radius: 1)
                .position(x: width, y: slotHeight / 2)
        }
    }

    @ViewBuilder
    private func supernovaShockwaveView(
        phase: Double,
        color: ActivityStripGaugeMath.SupernovaShockColor,
        swiftColor: Color,
        width: CGFloat,
        slotHeight: CGFloat
    ) -> some View {
        if let ring = ActivityStripGaugeMath.supernovaShockwave(phase: phase, color: color) {
            let baseDiameter: CGFloat = 12
            Circle()
                .strokeBorder(swiftColor, lineWidth: ring.lineWidth)
                .frame(width: baseDiameter, height: baseDiameter)
                .scaleEffect(ring.scale)
                .opacity(ring.opacity)
                .shadow(color: swiftColor.opacity(0.7 * ring.opacity), radius: 4)
                .position(x: width, y: slotHeight / 2)
        }
    }

    @ViewBuilder
    private func supernovaSettledBodyView(phase: Double, width: CGFloat, slotHeight: CGFloat) -> some View {
        let body = ActivityStripGaugeMath.supernovaSettledBody(phase: phase)
        if body.opacity > 0 {
            let diameter: CGFloat = 7
            Circle()
                .fill(Self.mockupCyan)
                .frame(width: diameter, height: diameter)
                .scaleEffect(body.scale)
                .opacity(body.opacity)
                .shadow(color: Self.mockupCyan.opacity(0.7 * body.opacity), radius: 3)
                .position(x: width, y: slotHeight / 2)
        }
    }

    /// "deletions updated" / "reconciling" transient — a deletion sync just
    /// completed. A single, quick converge-and-clear of the reconcile beads
    /// (local from the left, server from the right) over the event window —
    /// differentiated from the steady `.deletionsPending` reconcile (a continuous
    /// multi-pair loop) by being one synchronized pass keyed to the event.
    @ViewBuilder
    private func deletionsUpdatedReconcile(eventStart: Date, count: Int, width w: CGFloat, slotHeight: CGFloat) -> some View {
        if reduceMotion {
            deletionsUpdatedReconcileFrame(phase: 0.5, count: count, width: w, slotHeight: slotHeight)
        } else {
            TimelineView(.periodic(from: .now, by: Self.eventAnimationInterval)) { context in
                if let phase = ActivityStripGaugeMath.animationPhase(
                    at: context.date,
                    eventStart: eventStart,
                    durationSeconds: Self.deletionUpdatedEventDuration
                ) {
                    deletionsUpdatedReconcileFrame(phase: phase, count: count, width: w, slotHeight: slotHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func deletionsUpdatedReconcileFrame(phase: Double, count: Int, width w: CGFloat, slotHeight: CGFloat) -> some View {
        let beads = min(max(count, 1), Self.reconcileTallyMaxPairs)
        let cy = slotHeight / 2
        let centerX = w / 2
        let edge: CGFloat = 6
        ZStack {
            if let spark = ActivityStripGaugeMath.reconcileTallySpark(phase: phase) {
                Circle()
                    .fill(Color.white)
                    .frame(width: CGFloat(3 + 6 * spark), height: CGFloat(3 + 6 * spark))
                    .opacity(0.95 * (1 - spark))
                    .blur(radius: 0.5)
                    .position(x: centerX, y: cy)
                Circle()
                    .strokeBorder(Self.mockupAmber.opacity(0.8 * (1 - spark)), lineWidth: 1)
                    .frame(width: CGFloat(5 + 16 * spark), height: CGFloat(5 + 16 * spark))
                    .position(x: centerX, y: cy)
            } else {
                let travel = CGFloat(ActivityStripGaugeMath.reconcileTallyTravel(phase: phase))
                ForEach(0..<beads, id: \.self) { i in
                    let frac = beads > 1 ? CGFloat(i) / CGFloat(beads - 1) : 0
                    let leftX0 = edge + (centerX - edge) * (0.15 + 0.7 * frac)
                    let rightX0 = (w - edge) - ((w - edge) - centerX) * (0.15 + 0.7 * frac)
                    let lx = leftX0 + (centerX - leftX0) * travel
                    let rx = rightX0 - (rightX0 - centerX) * travel
                    reconcileTallyBead(color: Self.mockupAmber, x: lx, y: cy)
                    reconcileTallyBead(color: Self.mockupAmberSoft, x: rx, y: cy)
                }
            }
        }
        .frame(width: w, height: slotHeight)
    }

    // MARK: - Signal count bead train

    private enum CountTrainKind {
        case newMail
        case deletionsPending
        case deletionsUpdated
    }

    private static let countTrainMaxVisible = 18
    private static let countTrainMinimumSpacing: CGFloat = 5
    private static let countTrainTravelAllowance: CGFloat = 16

    @ViewBuilder
    private func countBeadTrain(
        kind: CountTrainKind,
        count: Int,
        width: CGFloat,
        slotHeight: CGFloat,
        phase: Double
    ) -> some View {
        let visibleCount = Self.visibleCount(for: count, trackWidth: width)
        if visibleCount > 0 {
            let dotSize = Self.countTrainDotSize(for: visibleCount)
            let spacing = countTrainSpacing(visibleCount: visibleCount, trackWidth: width)
            let envelope = countTrainEnvelope(kind: kind, phase: phase)

            ForEach(0..<visibleCount, id: \.self) { index in
                let rawX = countTrainX(
                    kind: kind,
                    index: index,
                    visibleCount: visibleCount,
                    spacing: spacing,
                    trackWidth: width,
                    phase: phase
                )
                let x = min(width - dotSize / 2, max(dotSize / 2, rawX))
                let breathe = 0.75 + 0.25 * sin((phase * 2 * .pi) + Double(index) * 0.7)
                let visibility = countTrainVisibility(rawX: rawX, dotSize: dotSize, trackWidth: width)
                let opacity = envelope * visibility * (0.55 + 0.45 * breathe)
                Circle()
                    .fill(countTrainDotColor(kind: kind, index: index))
                    .frame(width: dotSize * (0.82 + 0.18 * breathe), height: dotSize * (0.82 + 0.18 * breathe))
                    .opacity(opacity)
                    .shadow(color: countTrainGlowColor(kind: kind).opacity(0.65 * opacity), radius: 3)
                    .position(x: x, y: slotHeight / 2)
            }
        }
    }

    static func visibleCount(for count: Int, trackWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let cappedCount = min(count, countTrainMaxVisible)
        guard trackWidth.isFinite, trackWidth > 0 else {
            return min(cappedCount, 1)
        }

        let widthCapacity = Int(
            ((trackWidth + countTrainTravelAllowance) / countTrainMinimumSpacing)
                .rounded(.down)
        ) + 1
        return min(cappedCount, max(1, widthCapacity))
    }

    private static func countTrainDotSize(for visibleCount: Int) -> CGFloat {
        switch visibleCount {
        case 1...3:
            return 4
        case 4...8:
            return 3.2
        default:
            return 2.6
        }
    }

    private func countTrainSpacing(visibleCount: Int, trackWidth: CGFloat) -> CGFloat {
        min(8.0, max(Self.countTrainMinimumSpacing, (trackWidth - 28) / CGFloat(max(1, visibleCount + 1))))
    }

    private func countTrainX(
        kind: CountTrainKind,
        index: Int,
        visibleCount: Int,
        spacing: CGFloat,
        trackWidth: CGFloat,
        phase: Double
    ) -> CGFloat {
        let direction = countTrainDirection(kind: kind)
        let trail = CGFloat(index) * spacing
        let ripple = CGFloat(1.2 * sin((phase * 2 * .pi) + Double(index) * 0.4))

        let headX: CGFloat
        switch kind {
        case .newMail, .deletionsUpdated:
            let p = min(max(phase / 0.33, 0), 1)
            let eased = CGFloat(p * p * p)
            let startX = direction > 0 ? -8 : trackWidth + 8
            let endX = direction > 0 ? trackWidth : 0
            headX = startX + (endX - startX) * eased
        case .deletionsPending:
            let trainLength = CGFloat(max(visibleCount - 1, 0)) * spacing
            let margin: CGFloat = 8
            let travel = trackWidth + trainLength + margin * 2
            headX = direction > 0
                ? -margin + travel * CGFloat(phase)
                : trackWidth + margin - travel * CGFloat(phase)
        }

        return headX - CGFloat(direction) * trail + ripple
    }

    private func countTrainDirection(kind: CountTrainKind) -> Int {
        switch kind {
        case .newMail:
            return 1
        case .deletionsPending, .deletionsUpdated:
            return -1
        }
    }

    private func countTrainVisibility(rawX: CGFloat, dotSize: CGFloat, trackWidth: CGFloat) -> Double {
        let margin = max(dotSize, 1)
        if rawX < -margin || rawX > trackWidth + margin { return 0 }
        if rawX < 0 { return Double((rawX + margin) / margin) }
        if rawX > trackWidth { return Double((trackWidth + margin - rawX) / margin) }
        return 1
    }

    private func countTrainEnvelope(kind: CountTrainKind, phase: Double) -> Double {
        let p = min(max(phase, 0), 1)
        switch kind {
        case .newMail, .deletionsUpdated:
            if p < 0.08 { return p / 0.08 }
            if p < 0.33 { return 1 }
            if p < 0.36 { return max(0, 1 - (p - 0.33) / 0.03) }
            return 0
        case .deletionsPending:
            if p < 0.08 { return p / 0.08 }
            if p > 0.92 { return max(0, (1 - p) / 0.08) }
            return 1
        }
    }

    private func countTrainDotColor(kind: CountTrainKind, index: Int) -> Color {
        switch kind {
        case .newMail:
            if index == 0 { return .white }
            return index.isMultiple(of: 3) ? Self.mockupGreen : Self.mockupCyan
        case .deletionsPending, .deletionsUpdated:
            return Self.mockupAmber
        }
    }

    private func countTrainGlowColor(kind: CountTrainKind) -> Color {
        switch kind {
        case .newMail:
            return Self.mockupCyan
        case .deletionsPending, .deletionsUpdated:
            return Self.mockupAmber
        }
    }

}

/// One half of the Précis ring — a circular arc centered on its own hook
/// position. `leading` picks which side (left/right) it sweeps around; the
/// sweep grows from a short outward hook (`squeeze` 0) to an exact
/// half-circle (`squeeze` 1), so `leading` and its trailing counterpart —
/// whose centers have by then converged to the same point — meet edge-to-edge
/// and trace one continuous ring outlining the core dot. Replaces the earlier
/// square-bracket (`[` / `]`) path, which read as keyboard punctuation rather
/// than a graphic. Uses `addRelativeArc` (start angle + explicit delta)
/// rather than `addArc`'s `clockwise` flag so the swept direction is
/// unambiguous regardless of SwiftUI's flipped-y angle convention.
private struct PrecisArcShape: Shape {
    let leading: Bool
    let center: CGPoint
    let radius: CGFloat
    let squeeze: Double

    // Ignores the incoming rect — `center`/`radius` are already absolute
    // points in the enclosing ZStack's coordinate space (which is explicitly
    // sized to match via `.frame(width:height:)` in `precisMotif`).
    func path(in _: CGRect) -> Path {
        var path = Path()
        let angles = ActivityStripGaugeMath.precisArcAngles(leading: leading, squeeze: squeeze)
        path.addRelativeArc(
            center: center,
            radius: radius,
            startAngle: Angle(degrees: angles.start),
            delta: Angle(degrees: angles.delta)
        )
        return path
    }
}

// MARK: - ReduceMotionStaticDot

private struct ReduceMotionStaticDot: View {
    let color: Color
    let eventStart: Date
    let duration: TimeInterval
    enum Anchor { case leading, trailing }
    let anchor: Anchor
    let width: CGFloat
    let slotHeight: CGFloat

    private static let fadeInterval: TimeInterval = OhiaAnimationCadence.frameInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.fadeInterval)) { context in
            let elapsed = context.date.timeIntervalSince(eventStart)
            if elapsed >= 0 && elapsed <= duration {
                let opacity = max(0, 1.0 - elapsed / duration)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(opacity)
                    .shadow(color: color.opacity(0.6 * opacity), radius: 3)
                    .position(
                        x: anchor == .leading ? 0 : width,
                        y: slotHeight / 2
                    )
            }
        }
    }
}
