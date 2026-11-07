import AppKit
import SwiftData
import SwiftUI
import os
import simd
import OhiaCore
import OhiaML
import OhiaScheduler

private let lockedOverlayLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "locked-node-overlay"
)

struct LockedOverlayFocalResolution: Equatable {
    let focalPoint: CGPoint
    let usesLiveProjection: Bool
}

struct LockedNodeRelatedSummaryPrewarm: Sendable {
    let messageId: String
    let row: MessageFilterRow
}

struct PeopleAnnotationRefreshKey: Equatable {
    let scopeFingerprint: String
    let contextMessageID: String?
}

@MainActor
enum LockedNodeRelatedSummaryPrewarmPlanner {
    static func targets(for loaded: LockedNodeContext) -> [LockedNodeRelatedSummaryPrewarm] {
        let neighbourTargets = loaded.neighbours
            .sorted { $0.bestSimilarity > $1.bestSimilarity }
            .map { LockedNodeRelatedSummaryPrewarm(messageId: $0.messageId, row: $0.row) }
        // `AnnotationItemFactory.threadItem` only emits popups for siblings
        // within +/-2 of the locked message; mirror that bound so prewarm
        // matches the rendered set without speculatively summarizing the
        // whole thread.
        let threadTargets = loaded.thread
            .filter { abs($0.position) <= 2 }
            .map { LockedNodeRelatedSummaryPrewarm(messageId: $0.messageId, row: $0.row) }
        var seenMessageIds = Set<String>()
        return (neighbourTargets + threadTargets).filter { target in
            seenMessageIds.insert(target.messageId).inserted
        }
    }
}

/// Cadence policy for the locked overlay's single body timeline. The
/// timeline exists to keep SwiftUI chrome anchored while the camera
/// flies with no `@State` mutating — so it only needs frame cadence
/// while the camera is actually producing frames (latched by
/// `LockedOverlayProjectionActivity` from the projection driver's
/// invalidation stream) or while a time-interpolated wormhole phase,
/// dial travel, or the entry ramp is in flight. At rest it drops to a
/// slow idle tick — never fully parked, because popup grace windows
/// sample `Date.now` per tick and must still make progress.
///
/// This changes ONLY the tick interval. The body, its view tree, and
/// every geometry input stay identical per tick, so the dial-wedge
/// coherence contract (see PeopleDialGeometryCoherenceTests) is
/// preserved by construction at either cadence.
enum LockedOverlayCadencePolicy {
    static let frameInterval: TimeInterval = 1.0 / 60.0
    static let idleInterval: TimeInterval = 0.5

    static func timelineInterval(needsFrameCadence: Bool) -> TimeInterval {
        needsFrameCadence ? frameInterval : idleInterval
    }
}

enum LockedOverlayFocalResolver {
    static func resolve(
        liveProjection: CGPoint?,
        initialProjectionFallback: CGPoint?,
        sceneSize: CGSize
    ) -> LockedOverlayFocalResolution {
        let anchor = liveProjection ?? initialProjectionFallback
        return LockedOverlayFocalResolution(
            focalPoint: FocusedOverlayPaneLayoutCoordinator.focalPoint(
                projected: anchor,
                sceneSize: sceneSize
            ),
            usesLiveProjection: liveProjection != nil
        )
    }
}

enum LockedOverlayAttachmentPlacement {
    static func showsLockedMessageAttachmentsInTelemetry(
        activeFrame: FrameKey,
        personFocus: LockedPersonFocus?
    ) -> Bool {
        switch activeFrame.spatialLens {
        case .people:
            return personFocus == nil
        case .meaning:
            return false
        default:
            return true
        }
    }
}

private struct PositionedAnnotationBadge: Identifiable {
    var id: String { screenItem.id }
    let screenItem: ScreenAnnotationItem
    let center: CGPoint
    let frame: CGRect
}

struct LockedNodeOverlay: View {
    let lockedVectorId: Int64
    let record: VectorRecord
    let row: MessageFilterRow
    let activeFrame: FrameKey
    let renderPacket: ConstellationRenderPacket
    @ObservedObject var cameraController: CameraController
    let viewSize: CGSize
    let vectorStore: VectorStore
    let vectorNeighborsStore: VectorNeighborsStore
    let vectorFrameLayoutStore: VectorFrameLayoutStore
    let messageIndex: [String: MessageFilterRow]
    let modelContext: ModelContext
    /// Optional preloaded context supplied by the isolated focused scene.
    /// When present, the overlay installs it directly instead of loading the
    /// neighborhood against the global constellation scene.
    let contextOverride: LockedNodeContext?
    /// Optional People-hub focus supplied by the isolated focused scene. The
    /// telemetry strip uses this to label the CORRESPONDENT pane with the
    /// exact person the user entered.
    var personFocus: LockedPersonFocus? = nil
    /// Every message id the focused correspondent appears on, sourced from
    /// the parent's filter-scope index. Drives the People-focus annotation
    /// item set so Sent / Sent·Included / Received / Included chip counts reflect the full
    /// ring (all 158 emails in a busy correspondent), not the top-K
    /// neighbour cap baked into `LockedNodeContext`. Empty in non-People
    /// modes — the standard Meanings flow keeps the in-context neighbour
    /// shape.
    var peopleRingMessageIds: Set<String> = []
    let summaryOverride: String?
    /// Canonical override pushed down from the parent so a fresh edit shows
    /// up before the snapshot rebuilds.
    let classificationOverride: MailClassification?
    /// Custom-key counterpart of `classificationOverride`.
    var summaryCustomKeysOverride: Set<String>? = nil
    /// Live custom-category catalog for the email card's category picker
    /// rows and chip strip.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []
    /// Live per-message body-summary cache from `ConstellationModeView`. The
    /// overlay reads this to decorate neighbour popups with summaries that
    /// the lock-time pre-warm pipeline produces, without waiting for the
    /// snapshot rebuild that would normally republish `row.bodySummary`.
    let summaryByMessageId: [String: String]
    /// Project-derived per-message signals (revived / shared evidence) when
    /// the active host has already built them. Direct row fields still carry
    /// read, reply, confirmation, deadline, and flag state.
    var messageStatusSignals: MessageStatusSignalIndex = .empty
    /// Message ids whose generated summary is being intentionally replaced.
    /// These render the summary loading affordance even if a previous summary
    /// is still cached.
    let regeneratingSummaryMessageIds: Set<String>
    let focusWorldOverride: SIMD3<Float>?
    /// Optional scene-space point captured from the click that opened the
    /// focused scene. This is only a fallback for pane layout while live
    /// projection is unavailable. The reticle/tether always re-project
    /// `lockedWorldPosition` so they share the renderer's world source.
    let layoutFocalPointOverride: CGPoint?
    let projectionDriver: LockedOverlayProjectionDriver
    /// Latches camera liveness from `projectionDriver` invalidations so
    /// the body timeline runs frame cadence only while the camera is
    /// actually moving. Attached/detached with the overlay lifecycle.
    @StateObject private var projectionActivity = LockedOverlayProjectionActivity()
    let lockedAccountColor: AccountColor
    /// People-lens Saturn ring band colors for the focused correspondent
    /// hub, keyed by `PersonRingInstance.Tier.insideOutIndex`
    /// (`receivedDirect`, `included`, `sentDirect`, `sentIncluded`). The
    /// host computes these via `AccountColorPalette.tierBandColorsRGB`
    /// using the same active-account context that drives the Metal
    /// renderer, so the chip strip in the CORRESPONDENT pane reads as a
    /// one-to-one legend for the rings the user sees in space. Empty
    /// outside the People lens — `SurveyTelemetryStrip` only forwards it
    /// to `LockedPanesIndex` which gates the lookup on `personRingTier`.
    var peopleRingTierColors: [Color] = []
    /// Preferred side for the email card's orbital label position and the dashed-leader
    /// fallback when the locked node's screen projection is unavailable.
    let defaultCardSide: HorizontalEdge
    /// Side the search/ask sidebar lives on. Drives the telemetry strip's
    /// default corner — leading sidebar → top-left strip, trailing sidebar
    /// → top-right strip — independent of the email card's placement so
    /// changes to one don't silently swap the other.
    let sidebarSide: HorizontalEdge
    /// Lowercased addresses that belong to the local user (every Account / Identity
    /// address). Forwarded into `LockedEmailCardContent` so the header can omit the
    /// user themselves from the recipients line.
    let userAddresses: Set<String>
    /// Account-owner identity forwarded into the generated CONTEXT paragraph so
    /// the model can resolve "you" and named references to the local account owner.
    let userIdentity: SummarizationUserIdentity?
    /// LLM service that generates the CONTEXT pane's orientation paragraph when the
    /// lock view opens. Same Apple-primary / MLX-fallback shape as the hover summary.
    let contextOrientationService: ContextOrientationService
    /// Account-memory provider used by People focus to inject durable
    /// correspondent memories into the CORRESPONDENT relationship summary.
    let askMemoryProvider: (any AskMemoryProvider)?
    /// Lazy attachment summarizer. Generation only fires when the user expands
    /// the chevron on an attachment popup; the result is cached per
    /// (attachmentID, fingerprint) so repeat expands are instant.
    let attachmentSummaryService: AttachmentSummaryService
    /// Broadcaster used to listen for `.extractAttachments` completions so the
    /// orientation paragraph can regenerate after deferred attachment text
    /// extraction lands for the locked message.
    let jobCompletionBroadcaster: JobCompletionBroadcaster
    /// Becomes non-nil only after the lock-entry camera transition and overlay
    /// reveal have settled. Rich model work waits for this token so lock entry
    /// stays animation-first.
    let enrichmentSequence: Int?
    /// 0...1 reveal phase supplied by the focused-entry transition. The
    /// node/tether appear first, then the email card, then the surrounding
    /// context/annotation panes.
    let entryPhase: Double
    /// True while the People-lens correspondent-focus entry transition is
    /// still running (camera fly-in through the background-recede dim ramp).
    /// The ring-node hover tracker is held inert until this clears so the
    /// transient dial card can't flicker onto nodes that are still sliding
    /// into place under the settling camera. Only meaningful in People focus;
    /// `false` for every other lens and for the settled steady state.
    var peopleFocusEntering: Bool = false
    /// Presents the app-wide message menu for the message currently shown in
    /// the locked card, including People-ring selections.
    let onPresentMessageContextMenu: (String, NSPoint, NSView) -> Void
    let onRelease: () -> Void
    /// Persists the shared purpose plus independent custom-category keys and
    /// refreshes the in-memory overrides immediately.
    let onClassificationChanged: (MailClassification?, Set<String>) -> Void
    /// Whether the locked email's sender is currently pinned as an
    /// "always major" correspondent. Drives the context-menu checkmark
    /// on the sender row.
    let isSenderPinned: Bool
    /// Flip the sender's pinned state. Inserts a `PinnedCorrespondent`
    /// row when not pinned; deletes it when pinned. Caller owns the
    /// SwiftData transaction so the `@Query`-backed pinned set in the
    /// host view rebuilds automatically.
    let onToggleSenderPinned: () -> Void
    /// Asks the parent to kick off background summarization for the supplied
    /// neighbour/thread rows (in priority/affinity order). The parent is
    /// expected to call `OnDemandSummarizer.summary(...)` for each entry
    /// that doesn't already have a cached summary. Fired once after the
    /// lock context loads so the ranked neighbour set warms up while the
    /// user reads the locked email — by the time they press `n`/`p` and
    /// space, the popup's expanded section has summary text waiting.
    let onPrewarmRelatedSummaries: ([LockedNodeRelatedSummaryPrewarm]) -> Void
    /// High-priority fallback for the exact pane the user expands. Lock-time
    /// prewarm is opportunistic; a space-toggle on a focused thread/neighbour
    /// pane is explicit demand and should use the interactive Qwen lane.
    let onRequestRelatedSummary: @MainActor @Sendable (LockedNodeRelatedSummaryPrewarm) async -> String?
    /// Warps the camera to a world position. Used by the rank-step navigator
    /// (`Tab` / `Shift+Tab`) to bring the focused neighbour's star into view
    /// before opening its annotation popup. Owned by `ConstellationModeView`,
    /// which already runs the same warp animation for citation jumps.
    ///
    /// Async: returns when the warp has settled, so the rank-step orchestrator
    /// can sequence close → warp → open without overlap. Implementations should
    /// engage the warp synchronously and then await its measured duration.
    let onWarpToWorld: (SIMD3<Float>) async -> Void
    /// Outer-owned controller for the affinity-rank step mode. Driven by the
    /// app's `onKeyDown` chain (`Tab` / `Shift+Tab` / `esc`) and observed here
    /// so the overlay can warp + auto-open the focused neighbour and decorate
    /// its leader as a `AffinityRankLeader` gauge.
    var rankController: LockNeighbourRankController
    /// Host-owned selection of the People-lens ring satellite the user clicked.
    /// Stores the satellite's message id (`AnnotationItem.anchorMessageId`). The
    /// host sets it from the Metal view's onClick; the overlay reads it to draw
    /// the selection highlight and pin the dial card. Cleared on Esc /
    /// empty-click / lock release.
    var selectedRingMessageId: Binding<String?> = .constant(nil)
    @State private var context: LockedNodeContext?
    @State private var loadFailed = false
    @State private var orientation: LockOrientationDisplayState = .pending
    @State private var orientationRequestID = UUID()
    @State private var annotationStates = AnnotationStates()
    @State private var annotationItems: [AnnotationItem] = []
    @State private var rankedAnnotationItems: [AnnotationItem] = []
    /// User-positioned card offset from the overlay's live focal point. `nil`
    /// means "use the orbital label default". Keeping this relative to the
    /// projected node lets manual placement travel with the locked star
    /// during camera movement.
    @State private var cardCenterOffset: CGSize?
    /// Card center captured at the start of the current drag gesture. Drag translations
    /// are read in global space, then applied to this stable scene-space snapshot.
    @State private var moveSession: LockedCardMoveSession?
    /// Live card width. Defaults to `LockedNodeOverlayMetrics.defaultCardWidth` until
    /// the user resizes; clamped to [`minCardWidth`, `maxCardWidth`].
    @State private var cardWidth: CGFloat = LockedNodeOverlayMetrics.defaultCardWidth
    /// Manual card height. `nil` means "size to content"; a value pins the card and
    /// lets its body scroll inside. Set when the user drags the corner handle.
    @State private var manualCardHeight: CGFloat?
    @State private var resizeSession: LockedCardResizeSession?
    @State private var cardInteraction: LockedOverlayLayoutCoordinator.CardInteraction = .idle
    @State private var measuredCardSize: CGSize = .zero
    @State private var cardChromeHeight: CGFloat = LockedEmailCardLayoutMetrics.fallbackChromeHeight
    @State private var measuredTelemetryContentHeight: CGFloat = 0
    @State private var settledCardFrame: CGRect?
    @State private var paneCenterOffsets: [String: CGSize] = [:]
    @State private var paneMoveSession: LockedOverlayPaneMoveSession?
    /// Per-attachment summary fetch state. Missing key = idle (request not
    /// yet kicked off); `.loading` while generation is in flight; `.loaded`
    /// once the service returns text; `.failed` when both engines refuse.
    /// Reset whenever a new lock context loads — the attachment ids in the
    /// previous context may not appear in the new one.
    @State private var attachmentSummaryStates: [UUID: AttachmentSummaryFetchState] = [:]
    /// Per-related-message summary request state for thread/neighbour panes
    /// that the user explicitly expands before lock-time prewarm finishes.
    @State private var relatedSummaryStates: [String: RelatedSummaryFetchState] = [:]
    /// Per-related-message original-body request state for Shift-Space /
    /// Shift-click expansion. Body artifacts are loaded only on demand so
    /// tabbing through panes still stays animation-first.
    @State private var relatedMessageBodyStates: [String: RelatedMessageBodyFetchState] = [:]
    /// Latest scene size observed by the body's `GeometryReader`. Cached so
    /// the latch refresher and `applyRankFocus` can project world anchors
    /// without re-evaluating the body geometry.
    @State private var lastSceneSize: CGSize = .zero
    /// Screen-space anchor latched at each annotation's current wormhole
    /// phase install. Keyed by annotation id. Read every frame by the body
    /// (and the projection layer) so the wormhole + leader stay put while
    /// the camera warps; cleared when the phase completes or is replaced.
    @State private var latchedAnchorByID: [String: LatchedAnnotationAnchor] = [:]
    /// Monotonic counter bumped on every rank-focus dispatch. The async
    /// orchestrator captures the current value and bails at each phase
    /// boundary if a newer dispatch has superseded it. This replaces the
    /// previous `Task.cancel()`-based scheme — `Task.cancel()` only
    /// throws at cooperative points (`Task.sleep`), so a rapid second
    /// Tab could cancel the first orchestration's sleep but leave its
    /// final `open(...)` running unconditionally, or — worse — the new
    /// orchestration's open could be lost if its own `Task.isCancelled`
    /// observation latched the old cancellation flag. A simple
    /// generation check is monotonic and unambiguous.
    @State private var rankFocusGeneration: UInt64 = 0
    /// Body-collapsed state for the lock card. Owned at the overlay
    /// level so two paths can flip it: the header chevron (user click)
    /// and the rank-step expansion toggle (space key while the main
    /// email pane is focused). Default false → body shown; space-toggle
    /// hides it. Reset to default when the lock context changes.
    @State private var lockedEmailBodyCollapsed: Bool = false

    // MARK: People-lens dial wedge state
    //
    // Drives `PeopleDialWedge` — the polar wedge that replaces
    // `AnnotationWormhole` + `AnnotationPopup` for the four People-kind
    // annotations in the People-focus overlay. The wedge orbits the
    // outside of the focused Saturn and connects to the active satellite
    // via a spoke; one wedge at a time tracks whichever satellite is
    // currently active. A selected satellite is pinned; otherwise hover
    // previews win over rank focus. State changes are observed via
    // `.onChange`, which calls `triggerPeopleDialTransition`. Pinned
    // selections retract their leader into the old node, orbit the pane
    // around the dial while the leader is hidden, then extend outward
    // from the destination node; transient hover/focus previews use the
    // original 3-phase contract → travel → extend animation.

    /// Annotation id of the People-kind satellite the user's `Tab` /
    /// `Shift+Tab` rank step currently lands on. Synced from
    /// `applyPeopleFocusRankFocus` so chip clicks and keyboard stepping
    /// share one source of truth.
    @State private var dialFocusedItemID: String?

    /// Annotation id of the People-kind satellite the pointer is currently
    /// over. Set / cleared by the window-level hover tracker rendered above
    /// the Metal layer. Wins over focus when no satellite is selected so the
    /// wedge tracks the user's gaze immediately.
    @State private var dialHoveredItemID: String?

    /// Annotation id the wedge is presently rendering content for. Lags
    /// transitions: during the 3-phase animation the displayed id stays
    /// on the OUTGOING item until the spoke begins extending in phase 3,
    /// at which point it swaps to the INCOMING item — so the slide reads
    /// as one continuous motion rather than a crossfade. `nil` hides the
    /// wedge entirely (initial state, and the state we return to when
    /// neither hover nor focus designates a People satellite).
    @State private var dialDisplayedItemID: String?

    /// Destination the dial is currently animating toward. During id → id'
    /// travel, `dialDisplayedItemID` intentionally remains on the outgoing
    /// item until phase 3; duplicate state updates for the same destination
    /// must not supersede/cancel that in-flight transition.
    @State private var dialTransitionTargetItemID: String?

    /// Animatable polar coordinates of the wedge's anchor satellite,
    /// keyed to the hub center (the locked Saturn's screen projection).
    /// Driven by `withAnimation` blocks inside
    /// `triggerPeopleDialTransition`; consumed by `PeopleDialWedge` which
    /// declares `Animatable` so the Canvas re-draws at intermediate
    /// values rather than snapping.
    @State private var dialAnchorAngle: CGFloat = 0
    @State private var dialAnchorRX: CGFloat = 0
    /// Animatable draw fraction for the People dial leader. `0` means the
    /// line is collapsed into the selected satellite node; `1` reaches
    /// the email pane's near edge. Selection / Tab transitions collapse
    /// this while the pane orbits around the dial, then extend it again
    /// from the new node to the pane edge.
    @State private var dialLeaderProgress: CGFloat = 1

    /// True while the 3-phase id → id' dial transition (contract → sweep
    /// → extend) is in flight. Steady state and the nil↔id fade
    /// transitions leave this false. The wedge instantiation uses this
    /// to decide whether to feed `liveSatelliteAnchor` (steady — spoke
    /// tracks the real projected node every frame, immune to stale
    /// polar reconstruction) or `nil` (in transition — polar drives the
    /// designed shrink/sweep/extend motion).
    @State private var dialIsTransitioning: Bool = false

    /// Monotonic counter bumped on every transition dispatch. Each phase
    /// captures the value and bails when it's been superseded, so a
    /// rapid second hover / Tab doesn't run two transitions concurrently.
    @State private var dialTransitionGeneration: UInt64 = 0

    /// Snapshot of an in-flight phase-2 angle sweep. Set the moment
    /// phase 2's `withAnimation` commits and cleared after the phase 2
    /// sleep settles (or when a superseding transition consumes the
    /// snapshot). Lets a superseding transition estimate the
    /// render-thread visual angle — without this, the new
    /// `shortestArcDelta` computes against `dialAnchorAngle`, which the
    /// previous animation jumped to but the screen hasn't reached, and
    /// the wedge can sweep the long way (>π) across the disc.
    @State private var dialPhase2Snapshot: DialPhase2Snapshot?

    private struct DialPhase2Snapshot: Equatable {
        let startAt: Date
        let startAngle: CGFloat
        let targetAngle: CGFloat
        let duration: TimeInterval
    }

    private struct LatchedAnnotationAnchor: Equatable {
        let phaseStartedAt: Date
        let direction: WormholePhase.Direction
        let anchor: CGPoint
    }

    private struct LockedWorldResolution {
        let world: SIMD3<Float>
    }

    private let overlayCoordinator = LockedOverlayLayoutCoordinator()
    private let paneCoordinator = FocusedOverlayPaneLayoutCoordinator()
    private static let orientationGenerationDelay = Duration.milliseconds(420)
    private static let peopleSatelliteSelectionRadius: CGFloat = 30

    private var clampedEntryPhase: Double {
        min(max(entryPhase, 0), 1)
    }

    private var entryLockOpacity: Double {
        smoothstep(clampedEntryPhase / 0.18)
    }

    private var entryCardOpacity: Double {
        smoothstep((clampedEntryPhase - 0.10) / 0.38)
    }

    private var entrySecondaryOpacity: Double {
        smoothstep((clampedEntryPhase - 0.38) / 0.44)
    }

    private var isPeopleFocusOverlay: Bool {
        activeFrame.spatialLens == .people && personFocus != nil
    }

    private var focalPaneKind: AnnotationKind {
        isPeopleFocusOverlay ? .correspondent : .mainEmail
    }

    /// In People focus the user is inspecting a correspondent (a Saturn), not
    /// a single email. The Meanings-style email card is suppressed entirely —
    /// the per-ring-email inspection surface is a Meanings-style
    /// `AnnotationPopup` with a leader line back to the ring node (see
    /// `showsPeopleFocusRingPopups`), so the bulky lock card would only
    /// duplicate what the popup already presents.
    private var showsEmailCard: Bool {
        if isPeopleFocusOverlay {
            return false
        }
        return true
    }

    /// The ring email the user has tab-focused inside the People overlay.
    /// Index 0 is the focal portrait (just the Saturn); indices 1..N map
    /// chronologically (oldest → newest, clockwise) to the correspondent's
    /// ring emails. Returns nil whenever the user is on the Saturn pane
    /// or when no annotation is available — both of which surface as
    /// "no card, just the planet" in the body.
    private var peopleFocusRingItem: AnnotationItem? {
        guard isPeopleFocusOverlay else { return nil }
        return focusedAnnotationItem
    }

    /// The People-ring annotation item the user has click-selected, resolved
    /// from the host-owned `selectedRingMessageId`. `nil` when nothing is
    /// selected or the selected message has left the scene (e.g. after a
    /// delete) — both resolve to "no highlight, no pinned card, no action
    /// column."
    private var selectedRingItem: AnnotationItem? {
        guard isPeopleFocusOverlay,
              let messageId = selectedRingMessageId.wrappedValue else { return nil }
        return annotationItems.first {
            $0.anchorMessageId == messageId && $0.kind.personRingTier != nil
        }
    }

    /// Accent ring + soft halo drawn over the click-selected ring satellite.
    @ViewBuilder
    private func ringSelectionHighlight(accent: Color) -> some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.35), lineWidth: 6)
                .frame(width: 30, height: 30)
                .blur(radius: 4)
            Circle()
                .stroke(accent.opacity(0.95), lineWidth: 2.5)
                .frame(width: 30, height: 30)
        }
    }

    /// In People focus we suppress the tether / reticle inherited from the
    /// Meanings overlay so the Saturn stays visually isolated. Leader lines
    /// and ring-email popups are gated separately by
    /// `showsPeopleFocusRingPopups` — they're explicitly desired in the
    /// People portrait so the user can step around the ring and see each
    /// email's summary/text without losing the Saturn portrait.
    private var showsMeaningsChrome: Bool {
        !isPeopleFocusOverlay
    }

    /// People-focus uses its own pane treatment — the `PeopleDialWedge`
    /// orbits the focused Saturn and connects to the active ring satellite
    /// via a spoke drawn inside the wedge's own Canvas. The Meanings-style
    /// `AnnotationWormhole` + `AnnotationPopup` flow and the AppKit
    /// projection layer's annotation-leader rendering are therefore both
    /// suppressed in People focus — kept as a constant `false` so call
    /// sites that historically branched on this flag still compile while
    /// the dial wedge takes over.
    private var showsPeopleFocusRingPopups: Bool { false }

    private static let offscreenAvoidanceFrame = CGRect(
        x: -10_000,
        y: -10_000,
        width: 1,
        height: 1
    )

    /// Per-frame layout derivation hoisted out of `body`. Produces the card
    /// frame, telemetry pane frame, focal point, and layer plan for the
    /// current scene size. Pure derivation from instance state and
    /// camera projection — see [LockedOverlayLayoutResolution].
    private func resolveOverlayLayout(sceneSize: CGSize) -> LockedOverlayLayoutResolution {
        let telemetryAttachments = lockedTelemetryAttachments
        let telemetryPaneSize = telemetryPaneSize(
            sceneSize: sceneSize,
            orientation: orientation,
            attachments: telemetryAttachments
        )
        let world = lockedWorldResolution?.world
        let projected = world.flatMap {
            projectToOverlay(world: $0, sceneSize: sceneSize)
        }
        let focalResolution = LockedOverlayFocalResolver.resolve(
            liveProjection: projected,
            initialProjectionFallback: layoutFocalPointOverride,
            sceneSize: sceneSize
        )
        let focalPoint = focalResolution.focalPoint
        let autoCardHeight = LockedEmailCardLayoutMetrics.automaticCardHeightLimit(
            sceneHeight: sceneSize.height
        )
        let liveHeight = cardHeight(fallback: autoCardHeight)
        let defaultCenter = defaultCardCenter(
            in: sceneSize,
            focalPoint: focalPoint,
            cardSize: CGSize(width: cardWidth, height: liveHeight)
        )
        let cardSceneRect = cardSceneRect(sceneSize: sceneSize)
        let liveCenter = clampedCardCenter(
            manualCenter(offset: cardCenterOffset, focalPoint: focalPoint) ?? defaultCenter,
            sceneRect: cardSceneRect,
            cardWidth: cardWidth,
            cardHeight: liveHeight
        )
        let lockCardFrame = CGRect(
            x: liveCenter.x - cardWidth / 2,
            y: liveCenter.y - liveHeight / 2,
            width: cardWidth,
            height: liveHeight
        )
        let activeCardFrame = showsEmailCard ? lockCardFrame : Self.offscreenAvoidanceFrame
        let defaultTelemetryPaneFrame = context?.surveyTelemetry == nil
            ? nil
            : makeDefaultTelemetryFrame(
                in: sceneSize,
                size: telemetryPaneSize,
                focalPoint: focalPoint,
                avoidanceFrames: showsEmailCard ? [lockCardFrame] : []
            )
        let telemetryFrame = defaultTelemetryPaneFrame.map {
            paneFrame(
                key: LockedOverlayPaneKey.telemetry,
                defaultFrame: $0,
                sceneSize: sceneSize,
                focalPoint: focalPoint
            )
        }
        var reservedFrames: [CGRect] = []
        if let telemetryFrame {
            reservedFrames.append(telemetryFrame)
        }
        let layerPlan = overlayCoordinator.plan(
            liveCardFrame: activeCardFrame,
            settledCardFrame: interactionSettledCardFrame ?? settledCardFrame,
            reservedFrames: reservedFrames,
            interaction: cardInteraction
        )
        return LockedOverlayLayoutResolution(
            sceneSize: sceneSize,
            world: world,
            focalPoint: focalPoint,
            telemetryAttachments: telemetryAttachments,
            telemetryPaneSize: telemetryPaneSize,
            liveCenter: liveCenter,
            lockCardFrame: lockCardFrame,
            telemetryFrame: telemetryFrame,
            layerPlan: layerPlan
        )
    }

    var body: some View {
        // `cameraController.state` is intentionally imperative — it isn't a
        // `@Published` value, so reading it inside the body only refreshes
        // when something else triggers a re-render. The reticle and tether
        // are drawn live by an AppKit projection layer that ticks every
        // camera frame. To keep the rich SwiftUI lock card and annotation
        // panes anchored to the locked node during free camera flight
        // (WASD / scroll / aperture / roll, where no `@State` mutates),
        // wrap the geometry in a `TimelineView` with a periodic schedule
        // so the body re-evaluates unconditionally at frame cadence.
        // The main lock anchor must stay live-projected from world space;
        // do not restore cached screen-space anchors for the lock reticle
        // or leader, or it will detach from the rendered node when the
        // camera moves.
        GeometryReader { proxy in
            // Frame cadence only while something time-continuous is in
            // flight: live camera motion (projection-driver latch), a
            // wormhole phase interpolating popup opacity, dial travel, or
            // the entry ramp. A settled lock drops to the idle tick —
            // reading these observable values here re-evaluates the body
            // (and swaps the schedule) exactly when any of them flips.
            let overlayNeedsFrameCadence = projectionActivity.isLive
                || annotationStates.hasActivePhases
                || dialIsTransitioning
                || clampedEntryPhase < 1
            TimelineView(.periodic(
                from: .now,
                by: LockedOverlayCadencePolicy.timelineInterval(
                    needsFrameCadence: overlayNeedsFrameCadence
                )
            )) { _ in
            let resolution = resolveOverlayLayout(sceneSize: proxy.size)
            let sceneSize = resolution.sceneSize
            let autoCardHeight = LockedEmailCardLayoutMetrics.automaticCardHeightLimit(
                sceneHeight: sceneSize.height
            )
            let telemetryAttachments = resolution.telemetryAttachments
            let telemetryPaneSize = resolution.telemetryPaneSize
            let world = resolution.world
            let focalPoint = resolution.focalPoint
            let liveCenter = resolution.liveCenter
            let lockCardFrame = resolution.lockCardFrame
            let telemetryFrame = resolution.telemetryFrame
            let layerPlan = resolution.layerPlan
            // Sample state-machine inputs once per body rebuild so all subviews see a
            // consistent view of "open vs. badge". Calling `Date.now` repeatedly inside the
            // ForEach blocks below caused per-frame disagreement between popup and badge
            // visibility, which manifested as flicker.
            let stateNow = Date.now
            let liveScreenItems = projectedAnnotationItems(sceneSize: sceneSize)
            // People focus renders the dial wedge, not the Meaning annotation
            // panes, so its per-frame layout / badge / projection-snapshot work
            // is pure waste in that lens (all of it is gated behind
            // `showsMeaningsChrome`, which is false here). Skip the computation
            // — not just the rendering — so the focused correspondent body
            // stays cheap during camera steering. The dial below keeps using
            // `liveScreenItems` + `focalPoint` directly and is untouched.
            // Meaning locks run the full pipeline unchanged
            // (`isPeopleFocusOverlay == false`).
            //
            // Non-People path substitutes the latched screen anchor for any
            // annotation in a wormhole phase so the wormhole, leader, and pane
            // rect all stay put while the camera warps.
            let screenItems = isPeopleFocusOverlay ? [] : anchorsLatched(liveScreenItems)
            let peopleScreenItems = isPeopleFocusOverlay ? liveScreenItems : screenItems
            let openScreenItems = isPeopleFocusOverlay
                ? []
                : screenItems.filter { annotationStates.shouldShowPopup($0.id, now: stateNow) }
            let layout: AnnotationLayoutResolver.LayoutSolution? = isPeopleFocusOverlay
                ? nil
                : AnnotationLayoutResolver().layout(
                    items: openScreenItems,
                    avoidanceFrames: layerPlan.annotationAvoidanceFrames,
                    sceneSize: sceneSize,
                    focalPoint: focalPoint,
                    preferredSide: defaultCardSide,
                    manualCenters: annotationManualCenters(for: openScreenItems, focalPoint: focalPoint)
                )
            let positionedBadges: [PositionedAnnotationBadge] = {
                guard let layout else { return [] }
                let badgeItems = visibleBadgeItems(from: screenItems, now: stateNow)
                return positionedBadgeItems(
                    from: badgeItems,
                    telemetryFrame: telemetryFrame,
                    lockCardFrame: lockCardFrame,
                    annotationFrames: Array(layout.framesByID.values),
                    sceneSize: sceneSize
                )
            }()
            let projectionLayerSnapshot = layout.map { layoutValue in
                projectionSnapshot(
                    lockedWorld: world,
                    lockCardFrame: lockCardFrame,
                    layout: layoutValue,
                    layerPlan: layerPlan,
                    stateNow: stateNow,
                    sceneSize: sceneSize,
                    focalPoint: focalPoint
                )
            }

            ZStack(alignment: .topLeading) {
                if isPeopleFocusOverlay {
                    // Sandbox-style space backdrop — radial gradient
                    // graduating from near-black at the edges to a
                    // slightly warmer midnight at the centre, with a
                    // sparse twinkling star field on top. Matches the
                    // `SpaceBackground` + `BackdropStarField` from
                    // `Ohia/Previews/DesignSandbox.swift` so the
                    // People-focus overlay reads as the same visual
                    // universe as the sandbox study.
                    PeopleFocusSpaceBackdrop(
                        // The twinkle settles whenever the overlay itself is
                        // at rest — the same settled-ambience language as the
                        // Metal pulses' rest damp. A static star pattern reads
                        // as a natural night sky; what it no longer does is
                        // drag the overlay's full layout graph through a
                        // re-evaluation ten times a second forever.
                        twinklePaused: !overlayNeedsFrameCadence
                    )
                        .frame(width: sceneSize.width, height: sceneSize.height)
                        .allowsHitTesting(false)
                        .zIndex(-1)

                    // Faint accent-tinted halo around the locked
                    // correspondent's Saturn — the SwiftUI equivalent of
                    // the locked email card's
                    // `.shadow(color: accentColor.opacity(0.08), radius: 30)`
                    // accent halo. Rendered as a screen-space radial
                    // gradient with 0 alpha across the Saturn body (so
                    // the rendered Metal Saturn isn't tinted) and a
                    // soft Gaussian-feathered crest just outside the
                    // outermost ring, fading to 0 over ~30pt of further
                    // outward reach. Lives behind the projection layer
                    // and all chrome panes so it never occludes UI.
                    saturnAuraOverlay(sceneSize: sceneSize)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(-0.5)
                }

                if showsMeaningsChrome, let projectionLayerSnapshot {
                    // Mounted only for the Meanings flow — it draws the
                    // lock reticle, card tether, and per-annotation leader
                    // lines. People focus runs a different pane treatment
                    // (`PeopleDialWedge` draws its own spoke inside its
                    // Canvas), so the projection layer would have nothing
                    // to draw in that lens.
                    LockedOverlayProjectionLayer(
                        driver: projectionDriver,
                        snapshot: projectionLayerSnapshot,
                        initialCamera: cameraController.state
                    )
                    .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(0)
                }

                if let telemetry = context?.surveyTelemetry,
                   let telemetryFrame {
                    let paneKey = LockedOverlayPaneKey.telemetry
                    let isMoving = paneMoveSession?.id == paneKey
                    SurveyTelemetryStrip(
                        telemetry: telemetry,
                        orientation: orientation,
                        attachments: telemetryAttachments,
                        size: telemetryPaneSize,
                        activeFrame: activeFrame,
                        panesIndex: panesIndexData,
                        focusedGlobalIndex: rankController.currentIndex,
                        lockAccent: lockAccentColor,
                        correspondentIdentityLine: correspondentIdentityLine,
                        peopleRingTierColors: peopleRingTierColors,
                        onCitationSelected: openCitation,
                        annotationLookup: { targetID in
                            annotationItems.first(where: { $0.id == targetID })
                        },
                        anchorReceivedAt: row.receivedAt,
                        onContentSizeChange: updateTelemetryContentSize,
                        onMoveBy: { translation in
                            movePane(
                                id: paneKey,
                                by: translation,
                                liveFrame: telemetryFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                        },
                        onMoveEnded: { translation in
                            let finalFrame = movePane(
                                id: paneKey,
                                by: translation,
                                liveFrame: telemetryFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                            endPaneInteraction(id: paneKey, liveFrame: finalFrame, focalPoint: focalPoint)
                        },
                        onChipClick: cycleWithinKind,
                        // People focus and Meaning lock/focus move the
                        // lock-overlay shortcut legend into their vertical
                        // action rails, so the summary card drops its trailing
                        // help disc; other lenses keep it in the strip.
                        showsLegendButton: !isPeopleFocusOverlay && activeFrame.spatialLens != .meaning
                    )
                        .position(x: telemetryFrame.midX, y: telemetryFrame.midY)
                        .opacity(entrySecondaryOpacity * (isMoving ? 1 : layerPlan.secondaryOpacity(for: telemetryFrame)))
                        .zIndex(isMoving ? 90 : layerPlan.secondaryZIndex)
                }

                if showsMeaningsChrome {
                    ForEach(positionedBadges) { badge in
                        if annotationStates.shouldShowBadge(badge.id, now: stateNow) {
                            AnnotationMinBadge(
                                item: badge.screenItem.item,
                                anchor: badge.center,
                                onOpen: { annotationStates.open(badge.id) }
                            )
                            .opacity(entrySecondaryOpacity * layerPlan.secondaryOpacity(for: badge.frame))
                            .zIndex(layerPlan.secondaryZIndex + 2)
                        }
                    }
                }

                if showsMeaningsChrome, let layout {
                    ForEach(layout.visibleItems) { screenItem in
                    if let rect = layout.framesByID[screenItem.id],
                       annotationStates.shouldShowPopup(screenItem.id, now: stateNow) {
                        let paneKey = LockedOverlayPaneKey.annotation(screenItem.id)
                        let baseRect = paneFrame(
                            key: paneKey,
                            defaultFrame: rect,
                            sceneSize: sceneSize,
                            focalPoint: focalPoint
                        )
                        let expandedMode = annotationStates.expandedMode(for: screenItem.id)
                        let isExpanded = expandedMode != nil
                        let isMoving = paneMoveSession?.id == paneKey
                        let resolvedRect = annotationDisplayFrame(
                            baseFrame: baseRect,
                            item: screenItem.item,
                            expanded: isExpanded,
                            sceneSize: sceneSize
                        )
                        AnnotationWormhole(
                            anchor: screenItem.anchor,
                            rect: resolvedRect,
                            phase: annotationStates.phase(for: screenItem.id),
                            palette: lockedAccountWormholePalette
                        ) {
                            AnnotationPopup(
                                item: screenItem.item,
                                expanded: isExpanded,
                                expandedMode: expandedMode ?? .summary,
                                onToggleExpanded: { mode in
                                    toggleExpandedAnnotation(screenItem.item, requestedMode: mode)
                                },
                                onClose: { annotationStates.close(screenItem.id) },
                                onMoveBy: { translation in
                                    movePane(
                                        id: paneKey,
                                        by: translation,
                                        liveFrame: resolvedRect,
                                        sceneSize: sceneSize,
                                        focalPoint: focalPoint
                                    )
                                },
                                onMoveEnded: { translation in
                                    let finalFrame = movePane(
                                        id: paneKey,
                                        by: translation,
                                        liveFrame: resolvedRect,
                                        sceneSize: sceneSize,
                                        focalPoint: focalPoint
                                    )
                                    endPaneInteraction(id: paneKey, liveFrame: finalFrame, focalPoint: focalPoint)
                                },
                                summaryDisplay: summaryDisplay(for: screenItem.item),
                                messageDisplay: messageDisplay(for: screenItem.item),
                                messageAttachments: messageAttachments(for: screenItem.item),
                                showsHeaderAccentRule: activeFrame.spatialLens != .meaning,
                                heightLimit: resolvedRect.height,
                                isRankFocused: focusedAnnotationItem?.id == screenItem.id
                            )
                        }
                        .opacity(entrySecondaryOpacity * (isMoving ? 1 : layerPlan.secondaryOpacity(for: resolvedRect)))
                        .zIndex(isMoving ? 90 : layerPlan.secondaryZIndex + 3)
                    }
                    }
                }

                if isPeopleFocusOverlay {
                    // Hover-only tracker (drives the transient dial-card
                    // preview). Click-to-select and right-click-to-menu for ring
                    // satellites are handled by the Metal view's onClick /
                    // onRightClick in the host, so the Metal view keeps keyboard
                    // focus and Tab / Esc keep working during the lock.
                    PeopleSatelliteHoverTracker(
                        items: peopleSatelliteHitZones(screenItems: peopleScreenItems),
                        hoverRadius: Self.peopleSatelliteSelectionRadius,
                        // Hover is inert until the entry transition settles;
                        // when it flips back on, the tracker re-resolves the
                        // pointer's current position so a parked cursor lights
                        // its node immediately (no jiggle required).
                        isEnabled: !peopleFocusEntering,
                        onHoverIDChanged: { dialHoveredItemID = $0 }
                    )
                    .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(layerPlan.secondaryZIndex + 3)

                    // Persistent selection highlight on the click-selected ring
                    // satellite — an accent ring with a soft halo so the
                    // selection reads clearly against the Saturn backdrop while
                    // the action column is open. Tracks the live projected
                    // anchor so it stays on the node as the camera settles.
                    if let selected = selectedRingItem,
                       let anchor = peopleScreenItems.first(where: { $0.id == selected.id })?.anchor {
                        ringSelectionHighlight(accent: selected.kind.accent)
                            .position(anchor)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .zIndex(layerPlan.secondaryZIndex + 3.5)
                    }

                    if let displayedID = dialDisplayedItemID,
                       let displayedItem = annotationItems.first(where: { $0.id == displayedID }) {
                        let dialInnerRadius = peopleDialInnerRadius(
                            hubCenter: focalPoint,
                            screenItems: peopleScreenItems
                        )
                        // Live per-frame screen projection of the satellite
                        // anchored by the displayed item. The wedge's spoke
                        // uses this directly so it tracks the visible node
                        // even when the @State polar values have gone stale
                        // (e.g., camera frame shift after the transition
                        // committed, or the `polarCoords` `max(1, hypot)`
                        // floor collapsing to ~hubCenter for a satellite
                        // that briefly projects on top of the hub).
                        //
                        // Suppressed during the 3-phase contract/sweep/extend
                        // travel so the polar reconstruction governs the
                        // spoke through the choreographed motion (otherwise
                        // an inner-tier outgoing satellite's live anchor
                        // would make the spoke stretch outward instead of
                        // contracting during phase 1).
                        let liveSatelliteAnchor: CGPoint? = dialIsTransitioning
                            ? nil
                            : peopleScreenItems
                                .first(where: { $0.id == displayedID })?
                                .anchor
                        PeopleDialWedge(
                            hubCenter: focalPoint,
                            anchorAngle: dialAnchorAngle,
                            anchorRX: dialAnchorRX,
                            leaderProgress: dialLeaderProgress,
                            dialInnerRadius: dialInnerRadius,
                            ringPolyline: peopleRingPolyline(),
                            // Wedge chrome (inner-arc accent, spoke, tick
                            // marks) uses the per-kind PALETTE accent
                            // (Capella Gold / Ohia Green / Trapezium
                            // Violet / Cygnus Cyan) — the same color
                            // system the sandbox study at
                            // `Previews/DesignSandbox.swift` uses. That's
                            // intentionally distinct from
                            // `peopleChipAccent` (the muted Cosmic Dust
                            // tier color that matches the ring band) so
                            // the wedge's chrome stays legible against
                            // the navy backdrop.
                            accent: displayedItem.kind.accent,
                            item: displayedItem,
                            expanded: annotationStates.expandedMode(for: displayedItem.id) != nil,
                            expandedMode: annotationStates.expandedMode(for: displayedItem.id) ?? .summary,
                            onToggleExpanded: { mode in
                                toggleExpandedAnnotation(displayedItem, requestedMode: mode)
                            },
                            onClose: { annotationStates.close(displayedItem.id) },
                            summaryDisplay: summaryDisplay(for: displayedItem),
                            messageDisplay: messageDisplay(for: displayedItem),
                            messageAttachments: messageAttachments(for: displayedItem),
                            sceneBounds: CGRect(origin: .zero, size: sceneSize),
                            liveSatelliteAnchor: liveSatelliteAnchor
                        )
                        .opacity(entrySecondaryOpacity)
                        .transition(.opacity)
                        .zIndex(layerPlan.secondaryZIndex + 4)
                    }
                }

                if showsEmailCard {
                    LockedEmailCard(
                        content: cardContent,
                        attachments: emailCardAttachments,
                        width: cardWidth,
                        manualHeight: manualCardHeight,
                        maxAutomaticHeight: autoCardHeight,
                        // Body grows with the window but is bounded so the
                        // card never exceeds the available scene height — when
                        // the user toggles the body with space, the re-expanded
                        // card has to fit the viewport, otherwise the bottom
                        // edge crops. The measured chrome keeps the body cap
                        // aligned with the same automatic card height used for
                        // placement.
                        maxBodyHeight: LockedEmailCardLayoutMetrics.automaticBodyHeightLimit(
                            maxCardHeight: autoCardHeight,
                            chromeHeight: cardChromeHeight
                        ),
                        onPresentMessageContextMenu: onPresentMessageContextMenu,
                        onRelease: onRelease,
                        onMoveBy: { translation in
                            moveCard(
                                by: translation,
                                liveCenter: liveCenter,
                                liveFrame: lockCardFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                        },
                        onMoveEnded: { translation in
                            let finalFrame = moveCard(
                                by: translation,
                                liveCenter: liveCenter,
                                liveFrame: lockCardFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                            endCardInteraction(
                                liveFrame: finalFrame
                            )
                        },
                        onResizeBy: { translation in
                            resizeCard(
                                by: translation,
                                liveFrame: lockCardFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                        },
                        onResizeEnded: { translation in
                            let finalFrame = resizeCard(
                                by: translation,
                                liveFrame: lockCardFrame,
                                sceneSize: sceneSize,
                                focalPoint: focalPoint
                            )
                            endCardInteraction(
                                liveFrame: finalFrame
                            )
                        },
                        onChromeHeightChange: { height in
                            updateCardChromeHeight(height)
                        },
                        accentColor: lockAccentColor,
                        isRankFocused: isMainEmailRankFocused,
                        bodyCollapsed: $lockedEmailBodyCollapsed,
                        onClassificationChanged: onClassificationChanged,
                        customCategoryCatalog: customCategoryCatalog,
                        isSenderPinned: isSenderPinned,
                        onToggleSenderPinned: onToggleSenderPinned,
                        showsHeaderReleaseButton: activeFrame.spatialLens != .meaning,
                        showsHeaderAccentRule: activeFrame.spatialLens != .meaning
                    )
                    .background(
                        GeometryReader { cardProxy in
                            Color.clear.preference(
                                key: LockedEmailCardSizePreferenceKey.self,
                                value: cardProxy.size
                            )
                        }
                    )
                    .onPreferenceChange(LockedEmailCardSizePreferenceKey.self) { size in
                        updateMeasuredCardSize(size)
                    }
                    .position(liveCenter)
                    .scaleEffect(0.965 + entryCardOpacity * 0.035)
                    .opacity(entryCardOpacity)
                    .allowsHitTesting(true)
                    .zIndex(layerPlan.cardZIndex)
                }
            }
            .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
            .onAppear {
                projectionDriver.attachInvalidationSink(projectionActivity)
                projectionDriver.update(camera: cameraController.state)
                if lastSceneSize != sceneSize {
                    lastSceneSize = sceneSize
                    // First hover or rank-focus dispatch may have landed
                    // before the scene size settled. `triggerPeopleDialTransition`
                    // bails when `lastSceneSize` is `.zero`; replay the
                    // active-item evaluation now that geometry is valid.
                    updatePeopleDialActive()
                }
            }
            .onChange(of: sceneSize) { _, newSize in
                if lastSceneSize != newSize {
                    lastSceneSize = newSize
                    updatePeopleDialActive()
                }
            }
            }
        }
        .task(id: contextLoadKey) {
            await loadOrInstallContext()
        }
        .task(id: orientationGenerationKey) {
            guard let key = orientationGenerationKey,
                  let loaded = context else {
                return
            }
            do {
                try await Task.sleep(for: Self.orientationGenerationDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  enrichmentSequence == key.sequence,
                  context?.center.messageId == key.messageId else {
                return
            }
            await runOrientationGeneration(for: loaded, sequence: key.sequence)
        }
        .task(id: lockedVectorId) {
            guard contextOverride == nil else { return }
            await observeExtractionCompletions()
        }
        // The regenerate arbiter in `ConstellationModeView` re-dispatches this
        // scoped notification only when the locked inspector is the chosen
        // surface, so context regeneration never races the user command with
        // the other summary surfaces.
        .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateLockedContext)) { _ in
            Task { await regenerateVisibleContextOrientation() }
        }
        // Each step from `Tab` / `Shift+Tab` bumps `stepTick`, even when the
        // index itself doesn't change (single-element loop, wrap-around to
        // the same rank). React to the tick — not the index — so we always
        // re-warp + re-open even on no-op rank changes.
        .onChange(of: rankController.stepTick) { _, _ in
            applyRankFocus()
        }
        // Option+Tab / Option+Shift+Tab in People focus: step strictly
        // chronologically across the correspondent's entire ring. The
        // overlay owns the chronological ↔ bucketed mapping, so we
        // resolve the destination index here and forward to
        // `rankController.setIndex` — which bumps the standard step tick
        // and re-enters `applyRankFocus` with the new index.
        .onChange(of: rankController.chronologicalStepTick) { _, _ in
            applyChronologicalStep()
        }
        // Space-key toggles the focused rank popup's chevron. Reacting to
        // the controller's tick rather than the popup's local state keeps
        // the keyboard shortcut working without giving the AppKit key
        // handler direct access to `annotationStates`.
        .onChange(of: rankController.expansionToggleTick) { _, _ in
            applyRankExpansionToggle()
        }
        // When the parent's summary cache picks up a freshly-generated
        // entry for one of our ranked neighbours or thread siblings, rebuild
        // annotation items so the popup's expanded section renders the new
        // summary without waiting for a snapshot rebuild. Fingerprint
        // observation keeps the rebuild scoped — unrelated cache writes
        // don't trigger it.
        .onChange(of: annotatedSummaryFingerprint) { _, _ in
            rebuildAnnotationItemsAfterSummaryUpdate()
        }
        // People-focus rings are live-filtered by the parent render packet.
        // Include context installation in the task identity so a packet
        // update that arrives while context is still loading is not lost:
        // the task reruns once context exists and materializes the latest
        // Sent / Sent·Included / Received / Included ring annotations.
        .task(id: peopleAnnotationRefreshKey) {
            guard peopleAnnotationRefreshKey != nil else { return }
            rebuildAnnotationItemsAfterPeopleScopeUpdate()
        }
        // Capture a fresh latched screen anchor for every wormhole phase
        // the moment it appears, and drop latches when phases complete.
        // The state machine bumps `phasesGeneration` on every install /
        // removal, so this runs exactly once per phase change.
        .onChange(of: annotationStates.phasesGeneration) { _, _ in
            refreshAnnotationAnchorLatches()
        }
        // People-lens dial: re-evaluate the active satellite (hover > rank
        // focus) whenever either input changes, and dispatch a transition
        // if it differs from what the wedge is currently showing.
        .onChange(of: dialHoveredItemID) { _, _ in
            updatePeopleDialActive()
        }
        .onChange(of: dialFocusedItemID) { _, _ in
            updatePeopleDialActive()
        }
        .onChange(of: selectedRingMessageId.wrappedValue) { _, _ in
            // A click-selected ring node pins the dial card; repin when the
            // selection changes (set on click, cleared on deselect).
            updatePeopleDialActive()
            // Sync the rank cursor (chip-strip highlight + Tab origin) to the
            // clicked satellite WITHOUT moving the camera. The dial card,
            // highlight ring, and action column are already driven above; this
            // only aligns the SurveyTelemetryStrip chip and the next Tab step.
            syncRankFocusToSelectedRing()
        }
        .onDisappear {
            projectionDriver.detachInvalidationSink(projectionActivity)
            // Bumping the generation supersedes any in-flight orchestration
            // so its phase-2/3 work no-ops once the overlay is gone. We
            // don't need to track the Task itself — the generation guard
            // already short-circuits stale work.
            rankFocusGeneration &+= 1
        }
    }

    @MainActor
    private func regenerateVisibleContextOrientation() async {
        guard let loaded = context,
              let sequence = enrichmentSequence else {
            return
        }
        await contextOrientationService.invalidate(vectorId: lockedVectorId)
        await runOrientationGeneration(for: loaded, sequence: sequence, forceRefresh: true)
    }

    /// Listens for document and visual attachment extraction completions while
    /// this lock is open. Whenever one fires, checks whether the locked message
    /// had pending work for that queue and reloads the context if so — the fresh
    /// fetch picks up newly-extracted paths or terminal status, the orientation
    /// cache is invalidated so the paragraph regenerates with attachment text,
    /// and any per-attachment summary the user already requested is dropped so
    /// the next chevron expand re-runs against the new extraction.
    @MainActor
    private func observeExtractionCompletions() async {
        for await event in jobCompletionBroadcaster.events() {
            if event.type == .extractCaptureMetadata {
                // Capture time / place and a Mail Drop file's real size land
                // without changing extraction state. Swap in rows that
                // actually changed; never reset the lock (cards, popups and
                // Tab position stay where the user left them).
                refreshAttachmentRowsInPlace()
                continue
            }
            guard event.type == .extractAttachments || event.type == .extractVisualAttachments else { continue }
            guard let context else { continue }
            // Only act when the locked message actually had pending work
            // before the worker tick. Otherwise every batch tick on every other
            // message would invalidate this lock's orientation.
            let pendingAttachments = context.attachments.filter { attachment in
                let status = LockedAttachmentExtractionStatus.classify(attachment)
                switch event.type {
                case .extractAttachments:
                    return status.pendingQueue == .document
                case .extractVisualAttachments:
                    return status.pendingQueue == .visual
                default:
                    return false
                }
            }
            guard !pendingAttachments.isEmpty else { continue }
            await contextOrientationService.invalidate(vectorId: lockedVectorId)
            for pending in pendingAttachments {
                await attachmentSummaryService.invalidate(attachmentID: pending.id)
                attachmentSummaryStates[pending.id] = nil
            }
            await loadContext()
        }
    }

    @MainActor
    private func refreshAttachmentRowsInPlace() {
        guard let current = context?.attachments, !current.isEmpty else { return }
        let ids = current.map(\.id)
        let rows = (try? modelContext.fetch(FetchDescriptor<OhiaCore.Attachment>(
            predicate: #Predicate<OhiaCore.Attachment> { ids.contains($0.id) }
        ))) ?? []
        let fresh = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, LockedAttachmentSummary(attachment: $0)) })
        let refreshed = current.map { row in
            guard let latest = fresh[row.id],
                  latest.captureLine != row.captureLine || latest.sizeBytes != row.sizeBytes else {
                return row
            }
            return latest
        }
        if refreshed != current {
            context?.attachments = refreshed
        }
    }

    private func defaultCardCenter(
        in sceneSize: CGSize,
        focalPoint: CGPoint,
        cardSize: CGSize
    ) -> CGPoint {
        // Use the focused node as the orbital center, but place the email as a
        // large label on the ring. The user can still drag it anywhere afterwards.
        let frame = paneCoordinator.primaryFrame(
            id: LockedOverlayPaneKey.primaryEmail,
            size: cardSize,
            manualCenter: nil,
            focalPoint: focalPoint,
            sceneSize: sceneSize,
            preferredSide: defaultCardSide
        )
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private var interactionSettledCardFrame: CGRect? {
        moveSession?.settledFrame ?? resizeSession?.settledFrame
    }

    private func cardHeight(fallback autoCardHeight: CGFloat) -> CGFloat {
        if let manualCardHeight {
            return max(1, min(manualCardHeight, autoCardHeight))
        }
        return LockedEmailCardLayoutMetrics.automaticCardHeight(
            measuredHeight: measuredCardSize.height,
            fallbackHeight: autoCardHeight
        )
    }

    private func projectionSnapshot(
        lockedWorld: SIMD3<Float>?,
        lockCardFrame: CGRect,
        layout: AnnotationLayoutResolver.LayoutSolution,
        layerPlan: LockedOverlayLayoutCoordinator.LayerPlan,
        stateNow: Date,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> LockedOverlayProjectionSnapshot {
        // In People focus the reticle / tether / coord-readout cluster
        // around the locked vertex is intentionally suppressed — the
        // Saturn portrait is the focal anchor and the user doesn't need a
        // box drawn around it. Passing `nil` for `lockedWorld` short-
        // circuits the reticle/tether/coord-readout branch inside
        // `LockedOverlayProjectionLayer.draw` while still letting the
        // ring-email leader lines render.
        let effectiveLockedWorld = isPeopleFocusOverlay ? nil : lockedWorld
        return LockedOverlayProjectionSnapshot(
            lockedWorld: effectiveLockedWorld,
            coordReadout: effectiveLockedWorld.map {
                LockNodeCoordReadoutFormatter.string(world: $0, vectorId: lockedVectorId)
            },
            cardFrame: lockCardFrame,
            showsCardTether: showsEmailCard,
            lockAccent: lockAccentNSColor,
            lockOpacity: entryLockOpacity,
            annotationOpacity: entrySecondaryOpacity,
            annotationLeaders: projectionAnnotationLeaders(
                layout: layout,
                layerPlan: layerPlan,
                stateNow: stateNow,
                sceneSize: sceneSize,
                focalPoint: focalPoint
            ),
            projectionViewport: LockedOverlayProjectionViewport.aligned(
                metalViewSize: viewSize,
                overlaySceneSize: sceneSize
            )
        )
    }

    /// Projects a world point into overlay-local screen space using the
    /// Metal view's viewport when it differs from the overlay bounds.
    private func projectToOverlay(world: SIMD3<Float>, sceneSize: CGSize) -> CGPoint? {
        if let viewport = LockedOverlayProjectionViewport.aligned(
            metalViewSize: viewSize,
            overlaySceneSize: sceneSize
        ) {
            return viewport.project(
                world: world,
                camera: cameraController.state
            )
        }
        return ScreenProjection.project(
            world: world,
            camera: cameraController.state,
            viewSize: sceneSize,
            fovYRadians: .pi / 3
        )
    }

    private func projectionAnnotationLeaders(
        layout: AnnotationLayoutResolver.LayoutSolution,
        layerPlan: LockedOverlayLayoutCoordinator.LayerPlan,
        stateNow: Date,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> [LockedOverlayProjectionSnapshot.AnnotationLeader] {
        layout.visibleItems.compactMap { screenItem in
            guard let rect = layout.framesByID[screenItem.id],
                  annotationStates.shouldShowPopup(screenItem.id, now: stateNow) else {
                return nil
            }
            let paneKey = LockedOverlayPaneKey.annotation(screenItem.id)
            let baseRect = paneFrame(
                key: paneKey,
                defaultFrame: rect,
                sceneSize: sceneSize,
                focalPoint: focalPoint
            )
            let isExpanded = annotationStates.isExpanded(screenItem.id)
            let resolvedRect = annotationDisplayFrame(
                baseFrame: baseRect,
                item: screenItem.item,
                expanded: isExpanded,
                sceneSize: sceneSize
            )
            let focusedRank: LockedOverlayProjectionSnapshot.AnnotationLeader.Rank? = {
                guard let focusedNeighbour,
                      screenItem.id == "neighbor:\(focusedNeighbour.messageId)" else {
                    return nil
                }
                return .init(
                    bestSimilarity: focusedNeighbour.bestSimilarity,
                    threshold: LockNeighbourRankConstants.affinityFloor
                )
            }()
            // If the wormhole is mid-phase the projection layer should draw
            // the leader from the latched screen anchor and skip per-frame
            // reprojection; otherwise fall through to the world-anchored path
            // it already uses for steady state.
            let latchedAnchor: CGPoint? = {
                guard let phase = annotationStates.phase(for: screenItem.id),
                      let latched = latchedAnchorByID[screenItem.id],
                      latched.phaseStartedAt == phase.startedAt,
                      latched.direction == phase.direction else {
                    return nil
                }
                return latched.anchor
            }()
            return .init(
                id: screenItem.id,
                anchorWorld: screenItem.item.anchorWorld,
                latchedScreenAnchor: latchedAnchor,
                rect: resolvedRect,
                accent: LockedOverlayProjectionColors.accent(for: screenItem.item.kind),
                opacity: layerPlan.secondaryOpacity(for: resolvedRect),
                phase: annotationStates.phase(for: screenItem.id),
                rank: focusedRank
            )
        }
    }

    private func cardSceneRect(sceneSize: CGSize) -> CGRect {
        var rect = CGRect(origin: .zero, size: sceneSize)
        guard reservesSideControlRail else { return rect }

        let reserve = LockedNodeOverlayMetrics.sideControlRailWidth
            + LockedNodeOverlayMetrics.sideControlRailGutter
        switch defaultCardSide {
        case .leading:
            rect.origin.x += reserve
            rect.size.width = max(1, rect.width - reserve)
        case .trailing:
            rect.size.width = max(1, rect.width - reserve)
        }
        return rect
    }

    private var reservesSideControlRail: Bool {
        switch activeFrame.spatialLens {
        case .meaning, .people:
            return true
        default:
            return false
        }
    }

    private func clampedCardCenter(
        _ point: CGPoint,
        sceneRect: CGRect,
        cardWidth: CGFloat,
        cardHeight: CGFloat
    ) -> CGPoint {
        LockedCardGeometry.clampedCenter(
            point,
            cardSize: CGSize(width: cardWidth, height: cardHeight),
            sceneRect: sceneRect
        )
    }

    private func positionedBadgeItems(
        from items: [ScreenAnnotationItem],
        telemetryFrame: CGRect?,
        lockCardFrame: CGRect,
        annotationFrames: [CGRect],
        sceneSize: CGSize
    ) -> [PositionedAnnotationBadge] {
        var placedFrames: [CGRect] = []
        let baseAvoidanceFrames = ([telemetryFrame].compactMap { $0 }
            + [lockCardFrame]
            + annotationFrames)
            .map { $0.insetBy(dx: -6, dy: -6) }

        return items.map { item in
            let frame = badgeFrame(
                anchor: item.anchor,
                item: item.item,
                sceneSize: sceneSize,
                avoidanceFrames: baseAvoidanceFrames + placedFrames
            )
            placedFrames.append(frame.insetBy(dx: -6, dy: -6))
            return PositionedAnnotationBadge(
                screenItem: item,
                center: CGPoint(x: frame.midX, y: frame.midY),
                frame: frame
            )
        }
    }

    private func badgeFrame(
        anchor: CGPoint,
        item: AnnotationItem,
        sceneSize: CGSize,
        avoidanceFrames: [CGRect]
    ) -> CGRect {
        let size = badgeSize(for: item)
        let direct = clampedBadgeFrame(center: anchor, size: size, sceneSize: sceneSize)
        guard badgeOverlapArea(direct, avoidanceFrames: avoidanceFrames) > 0 else {
            return direct
        }

        let candidates = badgePlacementCandidates(
            anchor: anchor,
            size: size,
            sceneSize: sceneSize,
            avoidanceFrames: avoidanceFrames,
            directFrame: direct
        )
        return candidates.min {
            badgePlacementScore($0, anchor: anchor, avoidanceFrames: avoidanceFrames)
                < badgePlacementScore($1, anchor: anchor, avoidanceFrames: avoidanceFrames)
        } ?? direct
    }

    private func badgeSize(for item: AnnotationItem) -> CGSize {
        let font = NSFont.systemFont(ofSize: 9)
        let textWidth = ceil((item.badgeText as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: min(max(textWidth + 17, 46), 118), height: 20)
    }

    private func badgePlacementCandidates(
        anchor: CGPoint,
        size: CGSize,
        sceneSize: CGSize,
        avoidanceFrames: [CGRect],
        directFrame: CGRect
    ) -> [CGRect] {
        let gap: CGFloat = 10
        let nearbyFrames = avoidanceFrames.filter {
            directFrame.intersects($0) || $0.contains(anchor)
        }
        var centers: [CGPoint] = [
            anchor,
            CGPoint(x: anchor.x + size.width / 2 + gap, y: anchor.y),
            CGPoint(x: anchor.x - size.width / 2 - gap, y: anchor.y),
            CGPoint(x: anchor.x, y: anchor.y + size.height / 2 + gap),
            CGPoint(x: anchor.x, y: anchor.y - size.height / 2 - gap)
        ]

        for frame in nearbyFrames {
            centers.append(contentsOf: [
                CGPoint(x: frame.maxX + gap + size.width / 2, y: anchor.y),
                CGPoint(x: frame.minX - gap - size.width / 2, y: anchor.y),
                CGPoint(x: anchor.x, y: frame.maxY + gap + size.height / 2),
                CGPoint(x: anchor.x, y: frame.minY - gap - size.height / 2)
            ])
        }

        return uniquedBadgeFrames(
            centers.map { clampedBadgeFrame(center: $0, size: size, sceneSize: sceneSize) }
        )
    }

    private func clampedBadgeFrame(center: CGPoint, size: CGSize, sceneSize: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let minX = margin
        let maxX = max(minX, sceneSize.width - size.width - margin)
        let minY = margin
        let maxY = max(minY, sceneSize.height - size.height - margin)
        return CGRect(
            x: min(maxX, max(minX, center.x - size.width / 2)),
            y: min(maxY, max(minY, center.y - size.height / 2)),
            width: size.width,
            height: size.height
        )
    }

    private func badgePlacementScore(
        _ frame: CGRect,
        anchor: CGPoint,
        avoidanceFrames: [CGRect]
    ) -> CGFloat {
        let overlap = badgeOverlapArea(frame, avoidanceFrames: avoidanceFrames)
        let dx = frame.midX - anchor.x
        let dy = frame.midY - anchor.y
        return overlap * 5_000 + hypot(dx, dy)
    }

    private func badgeOverlapArea(_ frame: CGRect, avoidanceFrames: [CGRect]) -> CGFloat {
        avoidanceFrames.reduce(CGFloat(0)) { total, avoid in
            let overlap = frame.intersection(avoid)
            guard !overlap.isNull, !overlap.isEmpty else { return total }
            return total + overlap.width * overlap.height
        }
    }

    private func uniquedBadgeFrames(_ frames: [CGRect]) -> [CGRect] {
        var seen = Set<String>()
        return frames.filter { frame in
            let key = "\(Int(frame.minX.rounded())):\(Int(frame.minY.rounded()))"
            return seen.insert(key).inserted
        }
    }

    private func updateMeasuredCardSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let widthDelta = abs(measuredCardSize.width - size.width)
        let heightDelta = abs(measuredCardSize.height - size.height)
        guard widthDelta > 0.5 || heightDelta > 0.5 else { return }
        measuredCardSize = size
    }

    private func updateCardChromeHeight(_ height: CGFloat) {
        guard height > 1, abs(cardChromeHeight - height) > 0.5 else { return }
        cardChromeHeight = height
    }

    private func telemetryPaneSize(
        sceneSize: CGSize,
        orientation: LockOrientationDisplayState,
        attachments: [LockedAttachmentSummary]
    ) -> CGSize {
        let availableHeight = sceneSize.height - FocusedOverlayPaneLayoutCoordinator.sceneMargin * 2
        let contentHeight = measuredTelemetryContentHeight > 1
            ? measuredTelemetryContentHeight
            : estimatedTelemetryContentHeight(
                orientation: orientation,
                attachments: attachments
            )
        return LockedNodeOverlayMetrics.telemetrySize(
            contentHeight: contentHeight,
            availableHeight: availableHeight
        )
    }

    private func estimatedTelemetryContentHeight(
        orientation: LockOrientationDisplayState,
        attachments: [LockedAttachmentSummary]
    ) -> CGFloat {
        // Chip strip (~22pt) + caption (~14pt) + spacing (~6pt).
        // Adds ~42pt to the structural readout when the panes index renders.
        // Falls back to the previous 140pt seed
        // because the measurement preference key replaces this estimate
        // once the actual layout settles.
        let structuralReadoutHeight: CGFloat = 182
        let orientationHeight: CGFloat = {
            switch orientation {
            case .pending, .loading:
                return 80
            case .loaded(let result):
                // Inline `[N]` chips ride within the prose so each line is
                // ~20pt (chip is slightly taller than the 12pt text token).
                // No separate citation list contributes height.
                let lineCount = estimatedTelemetryLineCount(for: result.paragraph)
                return CGFloat(lineCount) * 20
            case .failed, .unavailable:
                return 22
            }
        }()
        let attachmentHeight = attachments.isEmpty
            ? 0
            : min(CGFloat(150), 34 + CGFloat(attachments.count) * 28)
        return structuralReadoutHeight + orientationHeight + attachmentHeight
    }

    private func estimatedTelemetryLineCount(for paragraph: String) -> Int {
        let charactersPerLine = 36
        let lines = paragraph
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { max(1, Int(ceil(Double($0.count) / Double(charactersPerLine)))) }
            .reduce(0, +)
        return max(1, lines)
    }

    private func updateTelemetryContentSize(_ size: CGSize) {
        guard size.height > 1 else { return }
        let roundedHeight = ceil(size.height)
        guard abs(measuredTelemetryContentHeight - roundedHeight) > 0.5 else { return }
        measuredTelemetryContentHeight = roundedHeight
    }

    private func manualCenter(offset: CGSize?, focalPoint: CGPoint) -> CGPoint? {
        guard let offset else { return nil }
        return CGPoint(x: focalPoint.x + offset.width, y: focalPoint.y + offset.height)
    }

    private func centerOffset(from center: CGPoint, focalPoint: CGPoint) -> CGSize {
        CGSize(width: center.x - focalPoint.x, height: center.y - focalPoint.y)
    }

    private func makeDefaultTelemetryFrame(
        in sceneSize: CGSize,
        size: CGSize,
        focalPoint: CGPoint,
        avoidanceFrames: [CGRect]
    ) -> CGRect {
        paneCoordinator.contextFrame(
            id: LockedOverlayPaneKey.telemetry,
            size: size,
            manualCenter: manualCenter(
                offset: paneCenterOffsets[LockedOverlayPaneKey.telemetry],
                focalPoint: focalPoint
            ),
            focalPoint: focalPoint,
            sceneSize: sceneSize,
            sidebarSide: sidebarSide,
            reservedFrames: avoidanceFrames
        )
    }

    private func paneFrame(
        key: String,
        defaultFrame: CGRect,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> CGRect {
        guard let center = manualCenter(offset: paneCenterOffsets[key], focalPoint: focalPoint) else {
            return defaultFrame
        }
        return FocusedOverlayPaneLayoutCoordinator.frame(
            center: center,
            size: defaultFrame.size,
            sceneSize: sceneSize
        )
    }

    private func annotationDisplayFrame(
        baseFrame: CGRect,
        item: AnnotationItem,
        expanded: Bool,
        sceneSize: CGSize
    ) -> CGRect {
        let rawSize = expanded ? item.expandedSize : baseFrame.size
        // Cap the layout rect used for placement and leaders to the viewport
        // (minus an 8pt margin per side). The popup receives this height as
        // its scroll viewport, so long attachment summaries remain readable
        // without tail-truncation or painting past the scene.
        let cappedSize = CGSize(
            width: min(rawSize.width, max(120, sceneSize.width - 16)),
            height: min(rawSize.height, max(120, sceneSize.height - 16))
        )
        return FocusedOverlayPaneLayoutCoordinator.frame(
            center: CGPoint(x: baseFrame.midX, y: baseFrame.midY),
            size: cappedSize,
            sceneSize: sceneSize
        )
    }

    private func annotationManualCenters(
        for items: [ScreenAnnotationItem],
        focalPoint: CGPoint
    ) -> [String: CGPoint] {
        Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                guard let center = manualCenter(
                    offset: paneCenterOffsets[LockedOverlayPaneKey.annotation(item.id)],
                    focalPoint: focalPoint
                ) else { return nil }
                return (item.id, center)
            }
        )
    }

    @discardableResult
    private func moveCard(
        by translation: CGSize,
        liveCenter: CGPoint,
        liveFrame: CGRect,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> CGRect {
        let session: LockedCardMoveSession
        if let moveSession {
            session = moveSession
        } else {
            session = LockedCardMoveSession(startCenter: liveCenter, settledFrame: liveFrame)
            moveSession = session
            settledCardFrame = liveFrame
            cardInteraction = .moving
        }

        let nextFrame = LockedCardGeometry.movedFrame(
            startCenter: session.startCenter,
            translation: translation,
            size: liveFrame.size,
            sceneRect: cardSceneRect(sceneSize: sceneSize)
        )
        let nextCenter = CGPoint(x: nextFrame.midX, y: nextFrame.midY)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cardCenterOffset = centerOffset(from: nextCenter, focalPoint: focalPoint)
        }
        return nextFrame
    }

    @discardableResult
    private func movePane(
        id: String,
        by translation: CGSize,
        liveFrame: CGRect,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> CGRect {
        let session: LockedOverlayPaneMoveSession
        if let paneMoveSession, paneMoveSession.id == id {
            session = paneMoveSession
        } else {
            session = LockedOverlayPaneMoveSession(
                id: id,
                startCenter: CGPoint(x: liveFrame.midX, y: liveFrame.midY),
                settledFrame: liveFrame
            )
            paneMoveSession = session
        }

        let nextFrame = LockedCardGeometry.movedFrame(
            startCenter: session.startCenter,
            translation: translation,
            size: liveFrame.size,
            sceneSize: sceneSize,
            margin: FocusedOverlayPaneLayoutCoordinator.sceneMargin
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            paneCenterOffsets[id] = centerOffset(
                from: CGPoint(x: nextFrame.midX, y: nextFrame.midY),
                focalPoint: focalPoint
            )
        }
        return nextFrame
    }

    @discardableResult
    private func resizeCard(
        by translation: CGSize,
        liveFrame: CGRect,
        sceneSize: CGSize,
        focalPoint: CGPoint
    ) -> CGRect {
        let session: LockedCardResizeSession
        if let resizeSession {
            session = resizeSession
        } else {
            session = LockedCardResizeSession(startFrame: liveFrame, settledFrame: liveFrame)
            resizeSession = session
            settledCardFrame = liveFrame
            cardInteraction = .resizing
        }

        let maxHeight = LockedEmailCardLayoutMetrics.automaticCardHeightLimit(
            sceneHeight: sceneSize.height
        )
        let minHeight = min(
            LockedEmailCardLayoutMetrics.resizeMinimumHeight(
                chromeHeight: cardChromeHeight
            ),
            maxHeight
        )
        let resizedFrame = LockedCardGeometry.resizedFrame(
            from: session.startFrame,
            translation: translation,
            limits: LockedCardGeometry.SizeLimits(
                minWidth: LockedNodeOverlayMetrics.minCardWidth,
                maxWidth: LockedNodeOverlayMetrics.maxCardWidth,
                minHeight: minHeight,
                maxHeight: maxHeight
            ),
            sceneRect: cardSceneRect(sceneSize: sceneSize)
        )

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cardWidth = resizedFrame.width
            manualCardHeight = resizedFrame.height
            cardCenterOffset = centerOffset(
                from: CGPoint(x: resizedFrame.midX, y: resizedFrame.midY),
                focalPoint: focalPoint
            )
        }
        return resizedFrame
    }

    private func endCardInteraction(liveFrame: CGRect) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            moveSession = nil
            resizeSession = nil
            settledCardFrame = liveFrame
            cardInteraction = .idle
        }
    }

    private func endPaneInteraction(id: String, liveFrame: CGRect, focalPoint: CGPoint) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            paneCenterOffsets[id] = centerOffset(
                from: CGPoint(x: liveFrame.midX, y: liveFrame.midY),
                focalPoint: focalPoint
            )
            if paneMoveSession?.id == id {
                paneMoveSession = nil
            }
        }
    }

    private var lockedWorldPosition: SIMD3<Float>? {
        lockedWorldResolution?.world
    }

    private var lockedWorldResolution: LockedWorldResolution? {
        if let focusWorldOverride {
            return LockedWorldResolution(world: focusWorldOverride)
        }
        // The renderer draws one star per message at the weighted centroid
        // of the message's vectors. Use that rendered centroid as the lock
        // anchor instead of the raw vector row that opened the overlay.
        let messageId = record.messageId
        if let star = renderPacket.stars.first(where: { $0.messageId == messageId }) {
            return LockedWorldResolution(world: star.position)
        }
        if let proxy = renderPacket.hitProxies.first(where: { $0.messageId == messageId }) {
            return LockedWorldResolution(world: proxy.worldPosition)
        }
        if let context {
            return LockedWorldResolution(world: context.center.worldPosition)
        }
        guard let x = record.layoutX, let y = record.layoutY, let z = record.layoutZ else { return nil }
        return LockedWorldResolution(world: SIMD3<Float>(x, y, z))
    }

    /// Kind-based accent for the locked email. The previous behavior derived
    /// this from the message id (account-color / hash fallback), which made
    /// the lock card stripe and reticle a different colour for every email
    /// — an arbitrary signal carrying no semantic meaning. Routing through
    /// Focal-message accent — derived from the per-account hue and
    /// normalized through `PaletteAccentEnvelope` so it adapts to
    /// Light/Dark mode. Used by the lock card stripe + glow, the lock
    /// tether, the focus reticle, the coord-readout pill, the focal
    /// chip.
    ///
    /// Both `lockAccentColor` (SwiftUI) and `lockAccentNSColor` (AppKit)
    /// resolve through the same dynamic `NSColor` provider so the
    /// SwiftUI chips and the CGContext-drawn tether/reticle land
    /// on the exact same hue with no color-space drift on wide-gamut
    /// displays, and the mode-aware brightness/saturation switch lands
    /// in both render paths simultaneously.
    private var lockAccentColor: Color {
        Color(nsColor: lockAccentNSColor)
    }

    private var lockAccentNSColor: NSColor {
        let account = isPeopleFocusOverlay
            ? AccountColorPalette.correspondentAccentColor(
                forAccountColorIndex: lockedAccountColor.id,
                usedAccountColorIndices: [lockedAccountColor.id]
            )
            : lockedAccountColor
        return NSColor(name: nil) { appearance in
            let env = PaletteAccentEnvelope.current(for: appearance)
            let rgb = env.sRGB(for: account)
            return NSColor(
                srgbRed: CGFloat(rgb.x),
                green: CGFloat(rgb.y),
                blue: CGFloat(rgb.z),
                alpha: 1.0
            )
        }
    }

    /// Faint accent-tinted halo around the locked correspondent's
    /// Saturn — the SwiftUI equivalent of the locked email card's
    /// `.shadow(color: accentColor.opacity(0.08), radius: 30)`
    /// modifier. Rendered as a screen-space radial gradient with 0
    /// alpha across the Saturn body (so the Metal-rendered Saturn
    /// isn't tinted by the overlay sitting in front of it) and a soft
    /// Gaussian-feathered accent crest just outside the outermost
    /// ring, fading to 0 over ~30pt of further outward reach. Returns
    /// `EmptyView` when the locked overlay isn't pinned to a People-
    /// focus hub or when the hub isn't currently in front of the
    /// camera.
    @ViewBuilder
    private func saturnAuraOverlay(sceneSize: CGSize) -> some View {
        if let hub = focusedSaturnHub,
           let centerScreen = projectToOverlay(world: hub.position, sceneSize: sceneSize),
           let saturnRadius = saturnScreenRadius(hub: hub, sceneSize: sceneSize) {
            let haloOuterRadius = saturnRadius + 30
            // Where the Saturn's silhouette ends in normalized [0, 1]
            // gradient space. Stops below this are fully transparent
            // (no tint on the Metal Saturn pixels behind); the crest
            // sits just past it and fades out by 1.0.
            let saturnFraction = max(0.0, min(0.92, saturnRadius / haloOuterRadius))
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: lockAccentColor.opacity(0.0), location: 0.0),
                    .init(color: lockAccentColor.opacity(0.0), location: saturnFraction),
                    .init(color: lockAccentColor.opacity(0.18), location: min(1.0, saturnFraction + 0.04)),
                    .init(color: lockAccentColor.opacity(0.0), location: 1.0),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: haloOuterRadius
            )
            .frame(width: haloOuterRadius * 2, height: haloOuterRadius * 2)
            // Soften the gradient-stop transitions so the crest reads
            // as a Gaussian halo rather than a banded ring. The
            // SwiftUI `.shadow` recipe on the email card is itself a
            // Gaussian-blurred silhouette; this blur lands the radial
            // version in the same falloff regime.
            .blur(radius: 14)
            .position(centerScreen)
        } else {
            EmptyView()
        }
    }

    /// Locked correspondent's `PersonHubInstance` in the current
    /// render packet, or `nil` outside People-focus state or when the
    /// hub hasn't been packed yet.
    private var focusedSaturnHub: PersonHubInstance? {
        guard isPeopleFocusOverlay, let personFocus else { return nil }
        let target = personFocus.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !target.isEmpty else { return nil }
        return renderPacket.personHubs.first {
            $0.email.lowercased() == target
        }
    }

    /// Screen-space radius of the Saturn's outermost visible extent
    /// (outermost ring's outer edge, or `1.5 × planet radius` when
    /// the hub has no rings yet). Computed via the camera's view
    /// matrix + perspective math so the halo size tracks zoom and
    /// dolly without drifting. Returns `nil` when the hub sits behind
    /// the camera.
    private func saturnScreenRadius(
        hub: PersonHubInstance,
        sceneSize: CGSize
    ) -> CGFloat? {
        let outerWorldRadius: Float = {
            if let last = hub.rings.last, last.radius > 0 {
                return last.radius + last.thickness
            }
            return max(hub.radius * 1.5, 0.04)
        }()
        let cam = cameraController.state
        let q = simd_quatf(angle: cam.yaw, axis: SIMD3<Float>(0, 1, 0)) *
                simd_quatf(angle: cam.pitch, axis: SIMD3<Float>(1, 0, 0)) *
                simd_quatf(angle: cam.roll, axis: SIMD3<Float>(0, 0, -1))
        let cameraForward = q.act(SIMD3<Float>(0, 0, -1))
        let toHub = hub.position - cam.position
        let depth = -simd_dot(toHub, cameraForward)
        guard depth > 0.0001 else { return nil }
        let fovY: Float = .pi / 3
        let focalLengthPixels = Float(sceneSize.height) * 0.5 / tanf(fovY * 0.5)
        let pixels = CGFloat(outerWorldRadius * focalLengthPixels / depth)
        // Floor so the halo stays legible when the camera pulls back
        // to galaxy-scale — at large dolly distances the projected
        // size collapses to a few pixels and the halo would vanish
        // before the Saturn does. 40pt is generous enough to read
        // without overwhelming the rendered hub.
        return max(40, pixels)
    }

    private var lockedAccountWormholePalette: AnnotationWormholePalette {
        AnnotationWormholePalette.account(lockedAccountColor)
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Every attachment on the locked message, regardless of extraction state.
    /// Sourced from the loader's SwiftData fetch so binary-only attachments
    /// and text-bearing attachments still awaiting the `extractAttachments`
    /// worker are visible in the FILES list with appropriate badges.
    private var lockedAttachments: [LockedAttachmentSummary] {
        context?.attachments ?? []
    }

    private var lockedTelemetryAttachments: [LockedAttachmentSummary] {
        guard LockedOverlayAttachmentPlacement.showsLockedMessageAttachmentsInTelemetry(
            activeFrame: activeFrame,
            personFocus: personFocus
        ) else {
            return []
        }
        return lockedAttachments
    }

    private var emailCardAttachments: [LockedAttachmentSummary] {
        activeFrame.spatialLens == .meaning ? lockedAttachments : []
    }

    private var correspondentIdentityLine: String? {
        SurveyTelemetryFraming.correspondentIdentityLine(
            for: activeFrame,
            row: row,
            userAddresses: userAddresses,
            personFocus: personFocus
        )
    }

    private var cardContent: LockedEmailCardContent {
        if isPeopleFocusOverlay, let ringItem = peopleFocusRingItem {
            return peopleRingCardContent(for: ringItem)
        }
        let summary = summaryOverride ?? row.bodySummary
        let bodyState: LockedEmailCardContent.BodyState
        if let bodyContent = context?.center.bodyContent {
            bodyState = .loaded(bodyContent)
        } else {
            bodyState = loadFailed ? .failed : .loading
        }
        return LockedEmailCardContent(
            messageId: record.messageId,
            vectorId: lockedVectorId,
            row: row,
            summary: summary,
            classificationOverride: classificationOverride,
            summaryCustomCategoryKeys: summaryCustomKeysOverride,
            statusDescriptor: MessageStatusDescriptor.constellationRow(
                row,
                messageID: UUID(uuidString: record.messageId),
                statusSignals: messageStatusSignals,
                includeAmbientSharedEvidence: true
            ),
            summaryIsRegenerating: regeneratingSummaryMessageIds.contains(record.messageId),
            bodyState: bodyState,
            userAddresses: userAddresses
        )
    }

    /// Card content for a tab-focused ring email in the People overlay.
    /// The row comes from the parent's filter-scope `messageIndex` (the
    /// same source the chronological ring is built from), the summary
    /// from the live `summaryByMessageId` cache the parent maintains, and
    /// the body resolves lazily via `peopleRingBodyState` — collapsed by
    /// default, expanded on demand via Shift+Space. The card's
    /// `messageId` and `vectorId` reflect the *ring* email so downstream
    /// hooks (header chevron, copy actions) operate on the focused
    /// message, not the locked center.
    private func peopleRingCardContent(for item: AnnotationItem) -> LockedEmailCardContent {
        let messageId = item.anchorMessageId
        let ringRow = messageId.flatMap { messageIndex[$0] } ?? row
        let resolvedMessageId = messageId ?? record.messageId
        let summary = (messageId.flatMap { summaryByMessageId[$0] }
            ?? item.summary
            ?? ringRow.bodySummary)
        return LockedEmailCardContent(
            messageId: resolvedMessageId,
            vectorId: lockedVectorId,
            row: ringRow,
            summary: summary,
            classificationOverride: nil,
            statusDescriptor: MessageStatusDescriptor.constellationRow(
                ringRow,
                messageID: UUID(uuidString: resolvedMessageId),
                statusSignals: messageStatusSignals,
                includeAmbientSharedEvidence: true
            ),
            summaryIsRegenerating: regeneratingSummaryMessageIds.contains(resolvedMessageId),
            bodyState: peopleRingBodyState(for: ringRow, messageId: resolvedMessageId),
            userAddresses: userAddresses
        )
    }

    /// Body state for a People-focus ring email. Collapsed by default
    /// (summary mode shown in the header chevron region); Shift+Space
    /// expands the body region. Real per-message body content is not
    /// preloaded for the ring (only the locked centre carries
    /// `LockReadoutBodyContent`), so the expanded body region surfaces a
    /// `.loaded` snapshot that is deliberately empty rather than reusing
    /// `bodySummary` — surfacing the summary text twice (once in the
    /// header summary chip, again in the body region) would visually
    /// double the content for zero added signal. A future commit can
    /// route a per-message body fetch through `LockReadoutBodyLoader`
    /// to materialize the actual MIME body on demand.
    private func peopleRingBodyState(
        for ringRow: MessageFilterRow,
        messageId: String
    ) -> LockedEmailCardContent.BodyState {
        return .loaded(
            LockReadoutBodyContent(
                source: LockReadoutBodySource(
                    text: "",
                    format: .plainText
                )
            )
        )
    }

    // MARK: People-dial helpers

    /// Hover-target rows for the People dial. One per People-kind
    /// annotation that's currently on screen. Identifiable so the `ForEach`
    /// in the body can diff stable rows across frames.
    private struct PeopleSatelliteHitZone: Identifiable {
        let id: String
        let anchor: CGPoint
    }

    private struct PeopleSatelliteHoverTracker: NSViewRepresentable {
        let items: [PeopleSatelliteHitZone]
        let hoverRadius: CGFloat
        /// When `false` the tracker forces its hover to `nil` and skips
        /// hit-testing, so no dial card can appear (used to hold hover inert
        /// through the focus-entry transition). Flipping it back to `true`
        /// re-resolves the current pointer location via `updateNSView`, so a
        /// cursor already parked over a node lights it without needing to move.
        let isEnabled: Bool
        let onHoverIDChanged: @MainActor (String?) -> Void

        func makeNSView(context: Context) -> TrackingView {
            let view = TrackingView()
            view.items = items
            view.hoverRadius = hoverRadius
            view.isEnabled = isEnabled
            view.onHoverIDChanged = onHoverIDChanged
            return view
        }

        func updateNSView(_ nsView: TrackingView, context: Context) {
            nsView.items = items
            nsView.hoverRadius = hoverRadius
            nsView.isEnabled = isEnabled
            nsView.onHoverIDChanged = onHoverIDChanged
            nsView.evaluateCurrentMouseLocation()
        }

        // Hover-only: this view never claims mouse or key events (mounted with
        // `.allowsHitTesting(false)`). Ring-node click-select and right-click
        // menu are handled by the Metal view's `onClick` / `onRightClick` in
        // `ConstellationModeView`, which keep the Metal view as first responder
        // so Tab / Esc keep reaching the lock's key handler. Hover is read from
        // a window-level `NSEvent` monitor so it works without hit-testing.
        final class TrackingView: NSView {
            var items: [PeopleSatelliteHitZone] = []
            var hoverRadius: CGFloat = 30
            var isEnabled: Bool = true
            var onHoverIDChanged: (@MainActor (String?) -> Void)?

            private var monitor: Any?
            private var trackingArea: NSTrackingArea?
            private var hoveredID: String?

            override var isFlipped: Bool { true }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window == nil {
                    removeMonitor()
                    setHoveredID(nil)
                } else if monitor == nil {
                    installMonitor()
                    evaluateCurrentMouseLocation()
                }
            }

            override func updateTrackingAreas() {
                if let trackingArea {
                    removeTrackingArea(trackingArea)
                }
                let area = NSTrackingArea(
                    rect: bounds,
                    options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(area)
                trackingArea = area
                super.updateTrackingAreas()
            }

            override func mouseExited(with event: NSEvent) {
                setHoveredID(nil)
            }

            deinit {
                if let trackingArea {
                    removeTrackingArea(trackingArea)
                }
                removeMonitor()
            }

            func evaluateCurrentMouseLocation() {
                guard let window else {
                    setHoveredID(nil)
                    return
                }
                let screenPoint = NSEvent.mouseLocation
                let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                updateHoveredID(at: point)
            }

            private func installMonitor() {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
                    guard let self else { return event }
                    self.handle(event)
                    return event
                }
            }

            private func removeMonitor() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }

            private func handle(_ event: NSEvent) {
                guard let window else {
                    setHoveredID(nil)
                    return
                }
                guard event.window === window else {
                    setHoveredID(nil)
                    return
                }
                updateHoveredID(at: convert(event.locationInWindow, from: nil))
            }

            /// Nearest ring satellite id within `hoverRadius` of `point`
            /// (view-local, flipped coords), or `nil` when the point is outside
            /// the view or no satellite is in range.
            private func nearestItemID(at point: CGPoint) -> String? {
                guard bounds.contains(point), !items.isEmpty else { return nil }
                let maxDistanceSquared = hoverRadius * hoverRadius
                var best: (id: String, distanceSquared: CGFloat)?
                for item in items {
                    let dx = item.anchor.x - point.x
                    let dy = item.anchor.y - point.y
                    let distanceSquared = dx * dx + dy * dy
                    guard distanceSquared <= maxDistanceSquared else { continue }
                    if best.map({ distanceSquared < $0.distanceSquared }) ?? true {
                        best = (item.id, distanceSquared)
                    }
                }
                return best?.id
            }

            private func updateHoveredID(at point: CGPoint) {
                // Held inert during the focus-entry transition: force the
                // hover to `nil` so internal state can't drift ahead of the
                // suppressed dial card and desync once hover re-enables.
                guard isEnabled else {
                    setHoveredID(nil)
                    return
                }
                setHoveredID(nearestItemID(at: point))
            }

            private func setHoveredID(_ id: String?) {
                guard hoveredID != id else { return }
                hoveredID = id
                onHoverIDChanged?(id)
            }
        }
    }

    private func peopleSatelliteHitZones(
        screenItems: [ScreenAnnotationItem]
    ) -> [PeopleSatelliteHitZone] {
        screenItems.compactMap { item in
            guard item.item.kind.personRingTier != nil else { return nil }
            return PeopleSatelliteHitZone(id: item.id, anchor: item.anchor)
        }
    }

    /// Screen-space radius of the wedge's inner arc — sits just outside
    /// the outermost People ring at the current camera pose. We take the
    /// max distance from the hub to any visible People-kind satellite,
    /// then pad by `PeopleDialWedge.dialInset`. Falls back to a sensible
    /// default when no satellites are on screen yet (lock just opened
    /// before the projection layer caught up).
    private func peopleDialInnerRadius(
        hubCenter: CGPoint,
        screenItems: [ScreenAnnotationItem]
    ) -> CGFloat {
        let satelliteAnchors = screenItems
            .filter { $0.item.kind.personRingTier != nil }
            .map(\.anchor)
        return PeopleDialGeometry.dialInnerRadius(
            hub: hubCenter,
            satelliteAnchors: satelliteAnchors,
            inset: PeopleDialWedge.dialInset
        )
    }

    /// Samples the outermost ring of the focused People hub as a closed
    /// polyline in screen space. Each vertex is one of
    /// `PeopleDialGeometry.ringPolylineSampleCount` evenly-spaced points
    /// on the 3D ring projected through `projectToOverlay` — the single
    /// projection path every People-dial geometry consumer shares — so
    /// the polyline matches the actual elliptical outline of the ring at
    /// the current camera pose (camera tilt away from the ring plane
    /// flattens the ellipse; camera roll rotates it). Returns an empty
    /// array when:
    ///   - There is no `personFocus` (the wedge is not active),
    ///   - The hub has no rings yet (`maxRingRadius == 0`),
    ///   - The scene size hasn't been captured (`lastSceneSize.zero`),
    ///   - All samples fall behind the camera (projection returns `nil`).
    /// `PeopleDialWedge` falls back to its constant-radius arc in those
    /// cases, so an empty return is always safe.
    private func peopleRingPolyline() -> [CGPoint] {
        guard let focus = personFocus,
              focus.outerRingEdgeRadius > 1e-5,
              lastSceneSize.width > 1, lastSceneSize.height > 1 else {
            return []
        }
        let normal = simd_normalize(focus.ringNormal)
        // Build two orthogonal in-plane vectors `u`, `v` from the ring
        // normal. We pick a helper axis that isn't parallel to the
        // normal so the cross product is non-degenerate, then derive
        // `v` so `(u, v, n)` forms a right-handed basis on the ring
        // plane.
        let helper: SIMD3<Float> = abs(normal.y) < 0.95
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, normal))
        let v = simd_normalize(simd_cross(normal, u))

        let n = PeopleDialGeometry.ringPolylineSampleCount
        var points: [CGPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let t = (2 * Float.pi * Float(i)) / Float(n)
            let world = focus.worldPosition
                + focus.outerRingEdgeRadius * (cos(t) * u + sin(t) * v)
            guard let screen = projectToOverlay(world: world, sceneSize: lastSceneSize) else {
                continue
            }
            points.append(screen)
        }
        return points
    }

    /// Resolves the screen-space polar coordinates of a People-kind
    /// satellite (relative to the hub) in the current scene. Returns
    /// `nil` when the satellite isn't on screen (e.g., camera framing
    /// excluded it) or before the body has captured a scene size — the
    /// caller dismisses the wedge in that case.
    ///
    /// The hub anchor here MUST be the same point, through the same
    /// projection path and the same out-of-bounds clamp, as the
    /// `focalPoint` the wedge is mounted at — the returned angle and
    /// radius are only meaningful relative to the wedge's own center.
    /// Re-projecting the hub through an independent path is how both
    /// dial detachments happened (2026-07-06 aligned-viewport swap,
    /// 2026-07-15 overlay restructure): the two hub anchors agree only
    /// by coincidence, and the wedge shears off the ring the moment
    /// they diverge.
    private func resolvePeopleSatellitePolar(
        itemID: String
    ) -> (hub: CGPoint, angle: CGFloat, rx: CGFloat)? {
        guard lastSceneSize.width > 1, lastSceneSize.height > 1,
              let world = lockedWorldResolution?.world,
              let projected = projectToOverlay(world: world, sceneSize: lastSceneSize) else {
            return nil
        }
        let hub = FocusedOverlayPaneLayoutCoordinator.focalPoint(
            projected: projected,
            sceneSize: lastSceneSize
        )
        let screenItems = projectedAnnotationItems(sceneSize: lastSceneSize)
        let anchors: [(id: String, anchor: CGPoint)] = screenItems.map { ($0.id, $0.anchor) }
        guard let polar = PeopleDialGeometry.satellitePolar(
            itemID: itemID,
            in: anchors,
            hub: hub
        ) else {
            return nil
        }
        return (hub, polar.angle, polar.rx)
    }

    /// Re-evaluates the active People-kind satellite (selection wins over
    /// hover, hover wins over rank focus) and dispatches a dial transition if
    /// it changed. Called from `.onChange` on selection / hover / focus.
    @MainActor
    private func updatePeopleDialActive() {
        guard isPeopleFocusOverlay else {
            // Other lenses: clear any leftover dial state so re-entering
            // the People lens starts hidden per spec.
            let hadDialState = dialDisplayedItemID != nil ||
                dialTransitionTargetItemID != nil ||
                dialIsTransitioning ||
                dialLeaderProgress != 1 ||
                dialPhase2Snapshot != nil
            if hadDialState {
                dialTransitionGeneration &+= 1
            }
            dialDisplayedItemID = nil
            dialTransitionTargetItemID = nil
            dialLeaderProgress = 1
            dialIsTransitioning = false
            dialPhase2Snapshot = nil
            return
        }
        // Selection wins: after a click or keyboard step, the pointer often
        // remains parked over an old satellite. Letting hover outrank
        // selection would move the chip counter without moving the visible
        // pane. With no active selection, hover is purely transient: moving
        // off every ring node must close the hover pane.
        let nextActive = selectedRingItem?.id ?? dialHoveredItemID
        let selectedTravel = PeopleDialGeometry.isSelectedDialActive(
            activeID: nextActive,
            selectedID: selectedRingItem?.id
        )
        triggerPeopleDialTransition(
            to: nextActive,
            selectedTravel: selectedTravel
        )
    }

    /// Drives the dial's three-phase animation. Sequenced via
    /// `Task.sleep` between `withAnimation` blocks; superseding
    /// transitions bump `dialTransitionGeneration` so each phase guard
    /// drops stale work.
    ///   nil → id:   appear at destination with the leader collapsed into
    ///               the node, then extend outward to the email pane edge.
    ///   id → nil:   retract the leader into the node before clearing
    ///               `dialDisplayedItemID`.
    ///   id → id':   the pane uses the classic 3-phase orbital travel.
    ///               Selected / Tab travel also retracts the leader into
    ///               the old node, keeps it hidden during the orbit, then
    ///               extends it from the new node.
    @MainActor
    private func triggerPeopleDialTransition(
        to nextActive: String?,
        selectedTravel: Bool = false
    ) {
        let prevActive = dialDisplayedItemID
        let currentTarget = dialTransitionTargetItemID ?? prevActive

        // Both ends nil — already hidden, nothing to do.
        if currentTarget == nil, nextActive == nil { return }
        // Same destination — no-op. During id → id' travel, the displayed
        // item is still the outgoing id, so include the in-flight target.
        // This keeps focused / hover updates from cancelling the one pane
        // transition they just requested. Selected same-id updates still
        // refresh their polar geometry once no transition is in flight:
        // People scope/filter rebuilds can keep the same selected item
        // while moving the rendered ring under it.
        if currentTarget == nextActive {
            if selectedTravel,
               dialTransitionTargetItemID == nil,
               let nextActive,
               let target = resolvePeopleSatellitePolar(itemID: nextActive) {
                refreshSelectedPeopleDialGeometry(to: nextActive, target: target)
            }
            return
        }

        // id → nil — retract the leader into the node, then drop the
        // displayed item so it disappears from the tree on the next pass.
        guard let nextActive else {
            dialTransitionGeneration &+= 1
            let generation = dialTransitionGeneration
            // Wedge is going away; if a prior 3-phase travel was
            // superseded mid-flight by this id → nil, the in-flight
            // `dialIsTransitioning` flag would otherwise leak into the
            // next nil → id fade-in and suppress `liveSatelliteAnchor`
            // there. Clear it now.
            dialIsTransitioning = false
            dialTransitionTargetItemID = nil
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.16)) {
                    dialLeaderProgress = 0
                }
                try? await Task.sleep(for: .seconds(0.16))
                guard dialTransitionGeneration == generation else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    dialDisplayedItemID = nil
                }
                try? await Task.sleep(for: .seconds(0.12))
                guard dialTransitionGeneration == generation else { return }
                dialLeaderProgress = 1
            }
            return
        }

        // Resolve the destination polar coords now. If the satellite isn't
        // on screen (rare race during lock entry / scene resize), bail —
        // the user can re-hover or re-Tab once the projection settles.
        guard let target = resolvePeopleSatellitePolar(itemID: nextActive) else {
            return
        }

        dialTransitionGeneration &+= 1
        let generation = dialTransitionGeneration

        // nil → id — show the wedge at the destination immediately and
        // fade it in. There's no outgoing item to slide away from.
        if prevActive == nil {
            // Ensure any stale `dialIsTransitioning` (left set by a
            // superseded 3-phase travel that bailed at a supersede
            // guard) is cleared, so the wedge starts in steady-state
            // and the spoke uses `liveSatelliteAnchor` immediately.
            dialIsTransitioning = false
            dialTransitionTargetItemID = nil
            dialAnchorAngle = target.angle
            dialAnchorRX = target.rx
            dialLeaderProgress = 0
            withAnimation(.easeOut(duration: 0.18)) {
                dialDisplayedItemID = nextActive
            }
            withAnimation(.easeOut(duration: 0.22).delay(0.02)) {
                dialLeaderProgress = 1
            }
            return
        }

        // id → id' — full 3-phase travel.
        let dialInnerRadius = peopleDialInnerRadius(
            hubCenter: target.hub,
            screenItems: projectedAnnotationItems(sceneSize: lastSceneSize)
        )

        // If a previous transition's phase 2 sweep is still in flight,
        // `dialAnchorAngle` already equals that sweep's TARGET (committed
        // by `withAnimation`) but the render thread is still partway
        // through the easing curve. Computing shortest-arc against the
        // committed value would lock us to the prior target's 2π branch
        // and can sweep the long way (>π) for diametrically opposite
        // satellites. Estimate the render-thread visual angle with a
        // cubic-easeInOut approximation and freeze the committed value
        // there (via `disablesAnimations`) so the new shortest-arc
        // computation starts from a stable, on-screen position.
        if let snapshot = dialPhase2Snapshot {
            let elapsed = Date.now.timeIntervalSince(snapshot.startAt)
            if elapsed >= 0, elapsed < snapshot.duration {
                let estimatedVisual = PeopleDialGeometry.interpolatedAngle(
                    from: snapshot.startAngle,
                    to: snapshot.targetAngle,
                    elapsed: elapsed,
                    duration: snapshot.duration
                )
                var freeze = Transaction(animation: nil)
                freeze.disablesAnimations = true
                withTransaction(freeze) {
                    dialAnchorAngle = estimatedVisual
                }
            }
            dialPhase2Snapshot = nil
        }

        // Pick the shorter angular path so the wedge sweeps the natural
        // direction (no >π detours).
        let shortest = PeopleDialGeometry.shortestArcDelta(
            from: dialAnchorAngle,
            to: target.angle
        )
        let interpolatedTarget = dialAnchorAngle + shortest

        let contractDuration: TimeInterval = 0.16
        let travelDuration: TimeInterval = 0.30
        let extendDuration: TimeInterval = 0.22
        let extendSettle: TimeInterval = 0.34
        dialTransitionTargetItemID = nextActive

        Task { @MainActor in
            if selectedTravel {
                // Selection / Tab travel is leader-first: keep live
                // satellite anchoring while the line retracts into the
                // old rendered node, then hide the line and let the pane
                // orbit on the polar dial path.
                dialIsTransitioning = false
                if dialLeaderProgress > 0 {
                    withAnimation(.easeIn(duration: contractDuration)) {
                        dialLeaderProgress = 0
                    }
                }
                try? await Task.sleep(for: .seconds(contractDuration))
                guard dialTransitionGeneration == generation else { return }

                var hiddenEndpoint = Transaction(animation: nil)
                hiddenEndpoint.disablesAnimations = true
                withTransaction(hiddenEndpoint) {
                    dialAnchorRX = dialInnerRadius
                }
                dialIsTransitioning = true
            } else {
                // Mark the wedge as transitioning so the wedge instantiation
                // suppresses `liveSatelliteAnchor` and lets the polar
                // (anchorAngle, anchorRX) drive the spoke through the
                // shrink/sweep/extend choreography.
                dialIsTransitioning = true
                dialLeaderProgress = 1
                // Phase 1 — contract spoke (easeIn into the wedge's inner arc).
                withAnimation(.easeIn(duration: contractDuration)) {
                    dialAnchorRX = dialInnerRadius
                }
                try? await Task.sleep(for: .seconds(contractDuration))
                guard dialTransitionGeneration == generation else { return }
            }

            // Phase 2 — wedge travels around the outer dial. Card content
            // stays on the OUTGOING item throughout so the slide reads as
            // one continuous physical motion (no crossfade). The
            // snapshot captures the start angle / target / duration so a
            // superseding transition can estimate the render-thread
            // visual angle and freeze it before computing its own
            // shortest-arc delta.
            let phase2StartAngle = dialAnchorAngle
            dialPhase2Snapshot = DialPhase2Snapshot(
                startAt: Date.now,
                startAngle: phase2StartAngle,
                targetAngle: interpolatedTarget,
                duration: travelDuration
            )
            withAnimation(.easeInOut(duration: travelDuration)) {
                dialAnchorAngle = interpolatedTarget
            }
            try? await Task.sleep(for: .seconds(travelDuration))
            guard dialTransitionGeneration == generation else {
                // Superseding transition will consume the snapshot itself
                // if it hasn't already; don't clear here in case it's
                // still mid-flight when we bail.
                return
            }
            // Phase 2 complete — the visual angle now equals the
            // committed `dialAnchorAngle`, so the snapshot is no longer
            // needed.
            dialPhase2Snapshot = nil

            // Phase 3 — the new item takes over, then the leader extends
            // from its node. Hover previews use the original springy RX
            // extend; selected / Tab travel keeps live node anchoring so
            // the visible line grows outward from the rendered node.
            if selectedTravel {
                var liveEndpoint = Transaction(animation: nil)
                liveEndpoint.disablesAnimations = true
                withTransaction(liveEndpoint) {
                    dialAnchorRX = target.rx
                    dialDisplayedItemID = nextActive
                }
                dialIsTransitioning = false
                withAnimation(.easeOut(duration: extendDuration)) {
                    dialLeaderProgress = 1
                }
            } else {
                withAnimation(.spring(response: extendDuration, dampingFraction: 0.72)) {
                    dialAnchorRX = target.rx
                    dialDisplayedItemID = nextActive
                }
            }
            try? await Task.sleep(for: .seconds(extendSettle))
            guard dialTransitionGeneration == generation else { return }
            // Normalize the committed angle back to (-π, π] so future
            // shortest-path deltas stay well-bounded. Visual is invariant
            // under 2π shifts (cos/sin are 2π-periodic), so this is a
            // no-op visually — it just keeps the @State value canonical
            // across many transitions instead of accumulating drift.
            var settled = Transaction(animation: nil)
            settled.disablesAnimations = true
            withTransaction(settled) {
                dialAnchorAngle = PeopleDialGeometry.canonicalAngle(dialAnchorAngle)
            }
            dialTransitionTargetItemID = nil
            dialLeaderProgress = 1
            // Steady state — let the wedge spoke track the live screen
            // projection of the satellite again. (Superseding transitions
            // re-arm the flag themselves; supersede-bail paths above can
            // leave it set, which is harmless: the next transition will
            // re-arm it, and steady state without a transition only
            // happens once this path completes.)
            dialIsTransitioning = false
        }
    }

    /// Refreshes a selected People dial whose item id did not change but
    /// whose projected geometry did. People scope/filter rebuilds can keep
    /// the same selected message while the rendered ring and satellite
    /// anchors move; that should update the pane/leader geometry without
    /// replaying the Tab retraction choreography.
    @MainActor
    private func refreshSelectedPeopleDialGeometry(
        to itemID: String,
        target: (hub: CGPoint, angle: CGFloat, rx: CGFloat)
    ) {
        var refresh = Transaction(animation: nil)
        refresh.disablesAnimations = true
        withTransaction(refresh) {
            dialAnchorAngle = target.angle
            dialAnchorRX = target.rx
            dialDisplayedItemID = itemID
            dialLeaderProgress = 1
        }
        dialIsTransitioning = false
        dialPhase2Snapshot = nil
    }

    private func projectedAnnotationItems(sceneSize: CGSize) -> [ScreenAnnotationItem] {
        annotationItems.compactMap { item in
            guard let anchor = projectToOverlay(world: item.anchorWorld, sceneSize: sceneSize) else {
                return nil
            }
            return ScreenAnnotationItem(item: item, anchor: anchor)
        }
    }

    /// Resolves the screen-space anchor used by an annotation's wormhole,
    /// pane layout, and leader for the current frame. While a wormhole
    /// phase is in flight we return the latched anchor captured at phase
    /// install — that's what makes the closing wormhole stay put while the
    /// camera warps and the opening wormhole stay put after the warp
    /// settles. Falls back to the live projected anchor in steady state.
    private func effectiveAnchor(forID id: String, liveAnchor: CGPoint) -> CGPoint {
        guard let phase = annotationStates.phase(for: id),
              let latched = latchedAnchorByID[id],
              latched.phaseStartedAt == phase.startedAt,
              latched.direction == phase.direction else {
            return liveAnchor
        }
        return latched.anchor
    }

    /// Returns a copy of `screenItems` with each item's anchor replaced by
    /// `effectiveAnchor` so the layout resolver produces a stable rect for
    /// any annotation currently in a wormhole phase.
    private func anchorsLatched(_ screenItems: [ScreenAnnotationItem]) -> [ScreenAnnotationItem] {
        screenItems.map { screenItem in
            let resolved = effectiveAnchor(forID: screenItem.id, liveAnchor: screenItem.anchor)
            if resolved == screenItem.anchor { return screenItem }
            return ScreenAnnotationItem(item: screenItem.item, anchor: resolved)
        }
    }

    /// Captures fresh latched anchors when the wormhole phase set changes:
    /// records the current projected anchor for any newly-installed phase,
    /// preserves still-active latches, and drops latches whose phase has
    /// completed or been removed. Called from `.onChange` of
    /// `annotationStates.phasesGeneration`, which bumps on every phase
    /// install or removal.
    @MainActor
    private func refreshAnnotationAnchorLatches() {
        guard lastSceneSize.width > 1, lastSceneSize.height > 1 else { return }
        var nextLatch = latchedAnchorByID
        let activeIDs = Set(annotationItems.map(\.id))

        // Drop latches for ids that no longer have an annotation item or
        // no longer have a live phase — both happen when context reloads.
        for id in nextLatch.keys where !activeIDs.contains(id) {
            nextLatch.removeValue(forKey: id)
        }

        for item in annotationItems {
            guard let phase = annotationStates.phase(for: item.id) else {
                nextLatch.removeValue(forKey: item.id)
                continue
            }
            if let existing = nextLatch[item.id],
               existing.phaseStartedAt == phase.startedAt,
               existing.direction == phase.direction {
                continue
            }
            guard let anchor = projectToOverlay(
                world: item.anchorWorld,
                sceneSize: lastSceneSize
            ) else {
                continue
            }
            nextLatch[item.id] = LatchedAnnotationAnchor(
                phaseStartedAt: phase.startedAt,
                direction: phase.direction,
                anchor: anchor
            )
        }

        if nextLatch != latchedAnchorByID {
            latchedAnchorByID = nextLatch
        }
    }

    private func visibleBadgeItems(from items: [ScreenAnnotationItem], now: Date) -> [ScreenAnnotationItem] {
        LockedOverlayBadgePolicy.visibleBadgeItems(
            from: items,
            activeFrame: activeFrame,
            limit: LockedNodeOverlayMetrics.visibleBadgeLimit,
            rankedItems: rankedAnnotationItems,
            shouldShowBadge: { annotationStates.shouldShowBadge($0, now: now) }
        )
    }

    @MainActor
    private func openCitation(_ citation: ContextOrientationCitation) {
        // Own-chunk citations point at vectors inside the locked email
        // itself — there's no annotation pane for those, the pane is the
        // lock card. Route those clicks to global rank index 0 so the
        // user lands on the main email pane the same way they would by
        // Tab-stepping back to it.
        if citation.kind == .ownChunk {
            rankController.setIndex(0)
            return
        }
        guard let targetID = citation.targetID,
              let item = annotationItem(forCitationTargetID: targetID) else {
            return
        }
        // Mirror Tab/citation-click semantics: route through the rank controller
        // so the click triggers the same collapse-warp-open sequence the
        // user gets from Tab / Shift+Tab, instead
        // of just popping the pane open in place.
        let ranked = rankedAnnotations
        guard let annotationIndex = ranked.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        rankController.setIndex(annotationIndex + 1)
    }

    private func annotationItem(forCitationTargetID targetID: String) -> AnnotationItem? {
        if let direct = annotationItems.first(where: { $0.id == targetID }) {
            return direct
        }
        if targetID.hasPrefix("vector:"),
           let vectorId = Int64(String(targetID.dropFirst("vector:".count))) {
            return annotationItems.first { $0.anchorVectorId == vectorId }
        }
        if targetID.hasPrefix("message:") {
            let messageId = String(targetID.dropFirst("message:".count))
            return annotationItems.first { $0.anchorMessageId == messageId }
        }
        return nil
    }

    private var contextLoadKey: String {
        if let contextOverride {
            let attachmentFingerprint = contextOverride.attachments
                .map {
                    [
                        $0.id.uuidString,
                        $0.extractedTextPath ?? "",
                        $0.extractionMethod ?? "",
                        $0.extractionStatus ?? "",
                        $0.extractionFailureReason ?? "",
                        $0.visualExtractionStatus ?? "",
                        $0.visualExtractionMethod ?? "",
                        $0.visualExtractionFailureReason ?? "",
                        $0.visualSummary ?? ""
                    ].joined(separator: ":")
                }
                .joined(separator: "|")
            return [
                "override",
                contextOverride.center.messageId,
                "\(contextOverride.center.vectorId)",
                "\(contextOverride.ownChunks.count)",
                "\(contextOverride.neighbours.count)",
                "\(contextOverride.thread.count)",
                attachmentFingerprint
            ].joined(separator: ":")
        }
        return "loader:\(lockedVectorId):\(activeFrame.rawValue)"
    }

    @MainActor
    private func resetContextState() {
        context = nil
        loadFailed = false
        annotationItems = []
        rankedAnnotationItems = []
        cardCenterOffset = nil
        moveSession = nil
        resizeSession = nil
        settledCardFrame = nil
        cardInteraction = .idle
        measuredTelemetryContentHeight = 0
        paneCenterOffsets = [:]
        paneMoveSession = nil
        orientation = .pending
        annotationStates.reset()
        attachmentSummaryStates = [:]
        relatedSummaryStates = [:]
        relatedMessageBodyStates = [:]
        // Drop any dial-wedge state from the previous lock target — a
        // stale `dialDisplayedItemID` from a prior People-focus session
        // would otherwise short-circuit `updatePeopleDialActive`'s
        // `prevActive == nextActive` early-return when the new context
        // lands. Bumping the transition generation invalidates any
        // in-flight animation that was still running against the old
        // satellite geometry.
        dialFocusedItemID = nil
        dialHoveredItemID = nil
        dialDisplayedItemID = nil
        dialTransitionTargetItemID = nil
        dialLeaderProgress = 1
        dialIsTransitioning = false
        dialPhase2Snapshot = nil
        dialTransitionGeneration &+= 1
        // Clear any prior rank focus before the new context lands; the
        // post-load `rankController.reset(rankedCount:)` below sets the
        // count from the freshly-loaded neighbour set.
        rankController.reset(rankedCount: 0)
    }

    @MainActor
    private func loadOrInstallContext() async {
        if let contextOverride {
            resetContextState()
            installContext(contextOverride, prewarmRelatedSummaries: true)
            return
        }
        await loadContext()
    }

    @MainActor
    private func loadContext() async {
        resetContextState()
        let loader = LockedNodeContextLoader(
            vectorId: lockedVectorId,
            activeFrame: activeFrame,
            vectorStore: vectorStore,
            vectorNeighborsStore: vectorNeighborsStore,
            vectorFrameLayoutStore: vectorFrameLayoutStore,
            messageIndex: messageIndex,
            modelContext: modelContext,
            summaryOverride: summaryOverride,
            classificationOverride: classificationOverride,
            userAddresses: userAddresses,
            personFocus: personFocus
        )
        do {
            let loaded = try await loader.load()
            installContext(loaded, prewarmRelatedSummaries: true)
        } catch {
            loadFailed = true
            annotationStates.reset()
            orientation = .failed
        }
    }

    @MainActor
    private func installContext(
        _ loaded: LockedNodeContext,
        prewarmRelatedSummaries: Bool
    ) {
        context = loaded
        let items = makeAnnotationItems(context: loaded)
        annotationItems = items
        rankedAnnotationItems = rankedItems(for: items)
        // Lock entry shows only the main email card. Every annotation —
        // attachments, neighbours, thread siblings, entities — starts in
        // its closed badge state, and the user tabs through them at their
        // own pace. We still register the items so the chip strip knows
        // what's available; we just hand `register`
        // an empty `initiallyOpen` set so no popups auto-materialize.
        annotationStates.register(
            items: items,
            initiallyOpen: []
        )
        // Pre-warm body summaries for the loaded ranked neighbour set
        // (≤ 12 messages per `LockedNodeContextLoader.neighbourMessageLimit`)
        // and for every thread sibling that gets an annotation popup. The
        // parent dispatches one `OnDemandSummarizer.summary(...)` per
        // message id whose cached summary is missing — by the time the user
        // steps through with `Tab` / `Shift+Tab` (or expands a thread
        // chevron), the results are already cached.
        let prewarmTargets = LockedNodeRelatedSummaryPrewarmPlanner.targets(for: loaded)
        if prewarmRelatedSummaries, !prewarmTargets.isEmpty {
            onPrewarmRelatedSummaries(prewarmTargets)
        }
        // Tell the controller how many annotation panes are available for
        // Rank-step navigation walks every kind plus the main email at
        // index 0, so `Tab` traverses `[mainEmail, …rankedAnnotations]`
        // — which is why the rank count is `count + 1`. The sorted
        // annotation snapshot is recomputed lazily on each step.
        //
        // `preselectIndex: 0` seeds the rank to the main / Saturn-portrait
        // pane so the chip strip opens with that pane already highlighted.
        // First Tab then advances to index 1 — the first ring email in
        // People focus, the first annotation in every other lens — so the
        // initial keystroke surfaces the first tabable item rather than
        // the focal pane the user is already looking at.
        let lensPreselectIndex: Int? = 0
        rankController.reset(
            rankedCount: rankedAnnotations.count + 1,
            preselectIndex: lensPreselectIndex
        )
        // New context → restore the lock card's body to its default
        // (shown) state so a previous lock's collapsed-by-space state
        // doesn't carry over.
        if lockedEmailBodyCollapsed { lockedEmailBodyCollapsed = false }
    }

    private var orientationGenerationKey: LockedOrientationGenerationKey? {
        guard let enrichmentSequence, let context else { return nil }
        return LockedOrientationGenerationKey(
            vectorId: lockedVectorId,
            sequence: enrichmentSequence,
            messageId: context.center.messageId
        )
    }

    /// Sorted snapshot of every annotation pane the user can step through
    /// with `Tab` / `Shift+Tab`. Relevance-descending, then stable by id,
    /// so the closest/strongest evidence is first and the order doesn't
    /// reshuffle across body passes. Related emails use affinity
    /// (`radialAffinity`) as their primary signal; other kinds use their
    /// existing importance.
    private var rankedAnnotations: [AnnotationItem] {
        rankedAnnotationItems
    }

    private func rankedItems(for items: [AnnotationItem]) -> [AnnotationItem] {
        guard activeFrame.spatialLens == .people else {
            return LockedPaneRanking.sortedItems(items)
        }
        // People focus overlay: the user is inspecting a single
        // correspondent's ring; `Tab` walks the same inside→outside ring
        // bucket order the focused Saturn uses.
        if isPeopleFocusOverlay {
            return LockedPaneRanking.sortedPeopleFocusItems(items)
        }
        // People layer hover/non-focus rendering: bucket by kind so
        // received / sent / shared stay contiguous, then order each role
        // by timeline date.
        return LockedPaneRanking.sortedPeopleItems(items)
    }

    /// The annotation item at `rankController.currentIndex`, or `nil` when
    /// rank-step is inactive, when the main email pane is focused
    /// (`currentIndex == 0`), or when the index has fallen out of range
    /// after a context reload. Index 0 is the main email — see
    /// `isMainEmailRankFocused`.
    private var focusedAnnotationItem: AnnotationItem? {
        guard let annotationIndex = focusedAnnotationIndex else { return nil }
        let ranked = rankedAnnotations
        guard ranked.indices.contains(annotationIndex) else { return nil }
        return ranked[annotationIndex]
    }

    /// Maps `rankController.currentIndex` from the unified pane index
    /// (0 = main email, 1..N = annotations) to the annotation array index
    /// (0..N-1). Returns `nil` when rank-step is inactive or focused on
    /// the main email.
    private var focusedAnnotationIndex: Int? {
        guard let index = rankController.currentIndex else { return nil }
        guard index >= 1 else { return nil }
        return index - 1
    }

    /// `true` when rank-step is active and pointing at the main email
    /// pane (the lock card itself).
    private var isMainEmailRankFocused: Bool {
        rankController.currentIndex == 0
    }

    /// Convenience: the focused neighbour, when the rank-focused item is
    /// one. Used by `projectionAnnotationLeaders` to attach the affinity
    /// gauge — that gauge represents a 0-1 cosine similarity, which only
    /// neighbours carry. Reply-shaped neighbours also carry
    /// `radialAffinity`, even though their chip kind is `.reply`.
    private var focusedNeighbour: LockedNodeContext.Neighbour? {
        guard let item = focusedAnnotationItem,
              item.radialAffinity != nil,
              let messageId = item.anchorMessageId else {
            return nil
        }
        return context?.neighbours.first { $0.messageId == messageId }
    }

    /// Pane-index data shown at the top of the CONTEXT pane: per-kind
    /// chip strip with counts and a focused-pane caption. The main email
    /// is always present at global index 0; annotations occupy indices
    /// 1..N. Returns `nil` only when the lock context hasn't loaded yet
    /// — once loaded, the strip always at minimum advertises the main
    /// email pane.
    private var panesIndexData: LockedPanesIndexData? {
        guard context != nil else { return nil }
        let ranked = rankedAnnotations

        // Track per-kind global indices so chip clicks can step within a
        // kind. The main email sits at global index 0; annotations occupy
        // indices 1..N in rank order. In People focus the focal pane is
        // the Saturn portrait (only one correspondent), so it does not
        // get a chip — the chip strip surfaces just the ring email
        // counters (Sent / Sent·Included / Received / Included) per the
        // user-facing spec.
        let focalKind = focalPaneKind
        var indicesByKind: [AnnotationKind: [Int]]
        if isPeopleFocusOverlay {
            indicesByKind = [:]
        } else {
            indicesByKind = [focalKind: [0]]
        }
        for (offset, item) in ranked.enumerated() {
            let globalIndex = offset + 1
            indicesByKind[item.kind, default: []].append(globalIndex)
        }

        let activeIndex = rankController.currentIndex
        let activeKind: AnnotationKind? = {
            guard let activeIndex else { return nil }
            if activeIndex == 0 { return focalKind }
            let annotationIndex = activeIndex - 1
            return ranked.indices.contains(annotationIndex) ? ranked[annotationIndex].kind : nil
        }()

        // Chip order mirrors the spatial metaphor: main email first, then
        // each available kind by the strongest pane it contains. People
        // focus surfaces four counter chips that partition the
        // correspondent's ring, inside→outside: Received (inbound from the
        // correspondent), Included (third-party messages where the
        // correspondent was Cc'd / on-thread alongside the user), Sent
        // (user's direct outbound), Sent·Included (user's outbound where
        // the correspondent was on Cc:/Bcc: alongside someone else).
        // Every ring dot
        // belongs to exactly one of these four; the strip's counts add
        // up to the ring's total cardinality.
        let chipKinds: [AnnotationKind]
        if isPeopleFocusOverlay {
            chipKinds = AnnotationKind.peopleRingTraversalOrder
        } else {
            chipKinds = AnnotationKind.allCases
        }
        let groups = LockedPaneRanking.sortedKinds(
            chipKinds,
            rankedItems: ranked
        )
            .compactMap { kind -> LockedPanesIndexData.KindGroup? in
                guard let indices = indicesByKind[kind], !indices.isEmpty else { return nil }
                let activeSubIndex: Int? = {
                    guard activeKind == kind, let activeIndex,
                          let position = indices.firstIndex(of: activeIndex) else {
                        return nil
                    }
                    // 1-based for the user-facing `2/4` label.
                    return position + 1
                }()
                return LockedPanesIndexData.KindGroup(
                    kind: kind,
                    count: indices.count,
                    globalIndices: indices,
                    activeSubIndex: activeSubIndex
                )
            }

        // Caption: kind-aware. Non-People neighbours surface the affinity
        // score; People focus panes keep only the relationship and position.
        let focusCaption: String? = {
            guard let activeKind,
                  let group = groups.first(where: { $0.kind == activeKind }),
                  let sub = group.activeSubIndex else {
                return nil
            }
            let positionPart = "\(activeKind.contextLabel) · \(sub) of \(group.count)"
            if !isPeopleFocusOverlay, let neighbour = focusedNeighbour {
                let similarity = neighbour.bestSimilarity.formatted(.number.precision(.fractionLength(2)))
                return "\(positionPart) · \(similarity)"
            }
            return positionPart
        }()

        return LockedPanesIndexData(
            groups: groups,
            totalCount: ranked.count + 1,
            focusCaption: focusCaption,
            fallbackCaption: isPeopleFocusOverlay ? emailCountCaption(ranked.count) : nil
        )
    }

    private func emailCountCaption(_ count: Int) -> String {
        "\(count) email\(count == 1 ? "" : "s")"
    }

    /// Cycle to the next pane within the given kind. If a pane of that
    /// kind is already focused, advance to the next one in rank order
    /// (wrapping at the end). Otherwise jump to the first pane of that
    /// kind. Wired to chip clicks in `LockedPanesIndex`. The main email
    /// kind always has exactly one pane at global index 0.
    @MainActor
    private func cycleWithinKind(_ kind: AnnotationKind) {
        if kind == focalPaneKind {
            rankController.setIndex(0)
            return
        }
        let ranked = rankedAnnotations
        // Annotation kinds occupy global indices 1..N (offset by 1 for
        // the main email at index 0).
        let indices = ranked.enumerated().compactMap { offset, item -> Int? in
            item.kind == kind ? offset + 1 : nil
        }
        guard !indices.isEmpty else { return }
        let nextIndex: Int
        if let current = rankController.currentIndex,
           let position = indices.firstIndex(of: current) {
            // Already inside this kind — step to the next entry, wrap at
            // the end so a long click run loops the user through every
            // pane of the kind.
            nextIndex = indices[(position + 1) % indices.count]
        } else {
            // Not currently inside this kind — land on the first one.
            nextIndex = indices[0]
        }
        rankController.setIndex(nextIndex)
    }

    /// Reaction to a `stepTick` bump from the controller. Sequences the
    /// transition strictly: collapse the previous pane in place, then warp
    /// the camera, then open the new pane. The wormhole closes through its
    /// full closing animation before the camera moves, and the new
    /// wormhole opens at a settled (post-warp) position. Latched anchors
    /// (see `effectiveAnchor` / `refreshAnnotationAnchorLatches`) keep the
    /// closing wormhole and the opening wormhole stationary on screen
    /// throughout — they don't drift with the camera.
    ///
    /// Index 0 is the main email pane (the lock card). Focusing it closes
    /// every open annotation and warps the camera back to the locked node;
    /// there's no annotation popup to open since the lock card is always
    /// visible.
    @MainActor
    private func applyRankFocus() {
        if isPeopleFocusOverlay {
            applyPeopleFocusRankFocus()
            return
        }
        if isMainEmailRankFocused {
            applyMainEmailRankFocus()
            return
        }
        guard let item = focusedAnnotationItem else { return }
        let targetID = item.id
        let targetWorld = item.anchorWorld

        rankFocusGeneration &+= 1
        let generation = rankFocusGeneration
        Task { @MainActor in
            // Phase 1 — collapse any other open pane in place. The latch
            // captured by `.onChange(of: phasesGeneration)` keeps each
            // closing wormhole pinned to its current screen position
            // throughout the close, no matter what the camera does next.
            let closeNow = Date.now
            annotationStates.closeAll(except: [targetID], now: closeNow)
            let closeDelay = annotationStates.maxRemainingClosingDuration(now: closeNow)
            if closeDelay > 0 {
                try? await Task.sleep(for: .seconds(closeDelay))
            }
            // Bail when a newer dispatch has overtaken us. Generation is
            // bumped synchronously in `applyRankFocus`, so any later Tab
            // press has already raised it before we resume here.
            guard rankFocusGeneration == generation else { return }

            // Phase 2 — warp the camera to the new anchor. Awaits the warp
            // settling so the next phase opens against a stationary scene.
            await onWarpToWorld(targetWorld)
            guard rankFocusGeneration == generation else { return }

            // Phase 3 — open the new pane. Its anchor latches the moment
            // the opening phase is installed (post-warp camera state), so
            // the vortex, leader, and pane all stay put as they materialize.
            // The lock card and tether follow the locked-node star
            // automatically because the body's TimelineView reprojects
            // the live world point at frame cadence.
            annotationStates.open(targetID)
        }
    }

    /// Reaction to an `expansionToggleTick` bump: flip the focused rank's
    /// expanded state so the chevron-pane (summary + extras) toggles
    /// open/closed. For attachments, also kicks extraction and the lazy
    /// summary request the first time the pane is expanded — same path the
    /// chevron click would take. For the main email pane, toggles the lock card's body
    /// region (same effect as clicking the header chevron) so the user
    /// can hide / show the email text from the keyboard. No-op when no
    /// rank is focused.
    @MainActor
    private func applyRankExpansionToggle() {
        if isPeopleFocusOverlay {
            // People focus inspects ring emails through the
            // `PeopleDialWedge`. The dial card embeds `AnnotationPopup`,
            // so Space (summary) and Shift-Space (original message
            // body) route to the same `toggleExpandedAnnotation` path
            // the meanings lens uses. Prefer the dial-displayed item
            // (which prefers hover > focus) so the keystroke acts on
            // whatever the user is currently looking at — falling back
            // to the rank-focused item when nothing is displayed.
            let dialItem = dialDisplayedItemID.flatMap { id in
                annotationItems.first(where: { $0.id == id })
            }
            guard let item = dialItem ?? focusedAnnotationItem else { return }
            toggleExpandedAnnotation(item, requestedMode: rankController.expansionContentMode)
            return
        }
        if isMainEmailRankFocused {
            guard showsEmailCard else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                lockedEmailBodyCollapsed.toggle()
            }
            return
        }
        guard let item = focusedAnnotationItem else { return }
        toggleExpandedAnnotation(item, requestedMode: rankController.expansionContentMode)
    }

    @MainActor
    private func toggleExpandedAnnotation(
        _ item: AnnotationItem,
        requestedMode: AnnotationExpandedContentMode
    ) {
        let mode = resolvedExpansionMode(for: item, requestedMode: requestedMode)
        let isShowingRequestedMode = withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            annotationStates.toggleExpanded(item.id, mode: mode)
        }
        guard isShowingRequestedMode else { return }
        switch mode {
        case .summary:
            kickExpandedSummaryIfNeeded(item: item)
        case .message:
            kickRelatedMessageBodyIfNeeded(item: item)
        }
    }

    private func resolvedExpansionMode(
        for item: AnnotationItem,
        requestedMode: AnnotationExpandedContentMode
    ) -> AnnotationExpandedContentMode {
        guard requestedMode == .message else { return .summary }
        return item.anchorMessageId == nil ? .summary : .message
    }

    /// Main-email branch of `applyRankFocus`. Closes any open annotation
    /// pane and warps the camera back to the locked node — so Tab-ing
    /// back to the main email after stepping through neighbours brings
    /// the locked star (and the lock card) back to centre.
    @MainActor
    private func applyMainEmailRankFocus() {
        let world = lockedWorldPosition
        rankFocusGeneration &+= 1
        let generation = rankFocusGeneration
        Task { @MainActor in
            // Phase 1 — collapse every open annotation in place. The lock
            // card is a peer; nothing on the card is a wormhole, so no
            // popup-open phase is needed for the main email.
            let closeNow = Date.now
            annotationStates.closeAll(now: closeNow)
            let closeDelay = annotationStates.maxRemainingClosingDuration(now: closeNow)
            if closeDelay > 0 {
                try? await Task.sleep(for: .seconds(closeDelay))
            }
            guard rankFocusGeneration == generation else { return }

            // Phase 2 — warp the camera back to the locked node so the
            // user is recentered on the message they're inspecting. The
            // body's TimelineView re-evaluates the live projection at frame
            // cadence so the card stays glued to the locked-node star
            // throughout the warp without any explicit refresh here.
            if let world {
                await onWarpToWorld(world)
            }
        }
    }

    /// Reaction to `chronologicalStepTick`. Resolves the user's strictly-
    /// chronological step request (Option+Tab / Option+Shift+Tab) by
    /// walking the People-focus ring in oldest → newest order, then
    /// re-indexes that new item back into the default bucketed ordering
    /// `rankedAnnotations` so the rest of the overlay machinery (chip
    /// strip activeSubIndex, popup open/close routing) keeps using one
    /// consistent index space. No-op outside People focus or when no ring
    /// items are loaded.
    @MainActor
    private func applyChronologicalStep() {
        guard isPeopleFocusOverlay else { return }
        let direction = rankController.chronologicalStepDirection
        guard direction != 0 else { return }

        let bucketed = rankedAnnotations
        guard !bucketed.isEmpty else { return }
        let chronological = LockedPaneRanking.chronologicalPeopleFocusItems(annotationItems)
        guard !chronological.isEmpty else { return }

        let currentBucketIndex = rankController.currentIndex
        let currentItem: AnnotationItem? = {
            guard let index = currentBucketIndex, index >= 1 else { return nil }
            let annotationIndex = index - 1
            return bucketed.indices.contains(annotationIndex) ? bucketed[annotationIndex] : nil
        }()

        // Resolve the destination chronological position. Without a current
        // ring focus (rank-step idle or sitting on the Saturn at index 0),
        // a forward Option+Tab lands on the oldest message; a backward step
        // lands on the newest.
        let nextChronIndex: Int
        if let current = currentItem,
           let position = chronological.firstIndex(where: { $0.id == current.id }) {
            let count = chronological.count
            nextChronIndex = ((position + direction) % count + count) % count
        } else {
            nextChronIndex = direction > 0 ? 0 : chronological.count - 1
        }

        let destination = chronological[nextChronIndex]
        guard let bucketedPosition = bucketed.firstIndex(where: { $0.id == destination.id }) else {
            return
        }
        // bucketed position 0..N-1 maps to global index 1..N (slot 0 is
        // the Saturn portrait).
        rankController.setIndex(bucketedPosition + 1)
    }

    /// Tab dispatch for the People focus overlay. The Saturn stays
    /// centered — no camera warp. For ring-email indices (1..N) we hand
    /// the focused id off to the dial controller after promoting it into
    /// selected-ring state. That triggers the 3-phase contract → travel →
    /// extend animation when the active item changes; unselected hover is
    /// only a transient preview. Index 0 (the Saturn portrait) is the chrome-clean
    /// focal pane: the dial dismisses and the lock card body collapses
    /// back to its summary default.
    @MainActor
    private func applyPeopleFocusRankFocus() {
        let nextFocusedItem = focusedAnnotationItem
        let nextSelectedMessageId = nextFocusedItem?.anchorMessageId

        // Bump the generation so any in-flight rank-focus tasks
        // dispatched from other entry points (e.g. the warp paths
        // above) bail out instead of clobbering the next focus.
        rankFocusGeneration &+= 1

        if !lockedEmailBodyCollapsed {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                lockedEmailBodyCollapsed = true
            }
        }

        // A keyboard step is an intentional focus change. Promote its
        // destination into the same selected-ring state that a click uses so
        // the visible highlight, action column, chip counter, and dial card all
        // advance together. Clear stale hover first: after clicking a node, the
        // pointer can remain parked over the old satellite, and stale hover
        // should not be mistaken for the keyboard-selected destination.
        if dialHoveredItemID != nil {
            dialHoveredItemID = nil
        }
        if selectedRingMessageId.wrappedValue != nextSelectedMessageId {
            selectedRingMessageId.wrappedValue = nextSelectedMessageId
        }

        // `.onChange(of: dialFocusedItemID)` picks this up and trips the dial
        // transition. `nil` (Saturn portrait at index 0) dismisses the wedge
        // once selection has also been cleared above.
        dialFocusedItemID = nextFocusedItem?.id
    }

    /// Align the rank cursor with the click-selected ring satellite so the
    /// SurveyTelemetryStrip chip ("satellite tracker") highlights the clicked
    /// node and a subsequent `Tab` advances relative to it. Driven by
    /// `.onChange(of: selectedRingMessageId.wrappedValue)`.
    ///
    /// Index domain: the rank cursor (`rankController.currentIndex`, which the
    /// strip reads via `focusedGlobalIndex`) is the unified pane index where
    /// slot 0 is the focal pane (the Saturn portrait, which carries no chip in
    /// People focus) and slots `1..N` map to `rankedAnnotations[index - 1]`.
    /// So a satellite at position `p` in the bucketed `rankedAnnotations`
    /// ordering lives at global index `p + 1` — the same mapping
    /// `applyChronologicalStep` uses when it routes a chronological step back
    /// into the bucketed index space.
    ///
    /// Camera-quiet by design: this routes through
    /// `LockNeighbourRankController.silentlyFocus(index:)`, which sets
    /// `currentIndex` without bumping `stepTick`, so the overlay's
    /// `.onChange(of: stepTick)` warp/auto-open orchestration never fires. The
    /// dial card, highlight ring, and action column are already driven by the
    /// selection observers above. No-op outside People focus, when nothing is
    /// selected, or when the selected message no longer resolves to a ranked
    /// ring item (e.g. it left the scene after a delete).
    @MainActor
    private func syncRankFocusToSelectedRing() {
        guard isPeopleFocusOverlay else { return }
        // Match on the selected satellite's message id (the selection's source
        // of truth) rather than the annotation item's `id`, so the lookup
        // succeeds regardless of any id-domain difference between the resolved
        // `selectedRingItem` and the ranked array.
        guard let messageId = selectedRingMessageId.wrappedValue else { return }
        let ranked = rankedAnnotations
        guard let position = ranked.firstIndex(where: { $0.anchorMessageId == messageId }) else {
            return
        }
        // bucketed position 0..N-1 maps to global index 1..N (slot 0 is the
        // Saturn portrait focal pane).
        rankController.silentlyFocus(index: position + 1)
    }

    /// Stable fingerprint of every annotated message's currently-cached
    /// summary (ranked neighbours + thread siblings within ±2), used as the
    /// `.onChange` key so item rebuilds only fire when one of our specific
    /// message ids gains a new summary. Other summary-cache writes
    /// (hovered messages, locked-message warm-up) don't perturb this string.
    private var annotatedSummaryFingerprint: String {
        let neighbourEntries = (context?.neighbours ?? [])
            .map { "n:\($0.messageId):\(summaryByMessageId[$0.messageId]?.count ?? 0)" }
        let threadEntries = (context?.thread ?? [])
            .filter { abs($0.position) <= 2 }
            .map { "t:\($0.messageId):\(summaryByMessageId[$0.messageId]?.count ?? 0)" }
        return (neighbourEntries + threadEntries).joined(separator: ",")
    }

    private var peopleAnnotationScopeFingerprint: String {
        guard isPeopleFocusOverlay else { return "none" }
        let focusEmail = personFocus?.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let anchorByMessageId = renderPacket.stars.reduce(into: [String: SIMD3<Float>]()) { anchors, star in
            anchors[star.messageId] = star.position
        }
        let anchoredMessageIds = Set(anchorByMessageId.keys)
        let rowEntries = peopleRingRowsForFactory.map { entry -> String in
            let anchorDescription: String
            if let anchor = anchorByMessageId[entry.messageId] {
                anchorDescription = [
                    Self.fingerprint(anchor.x),
                    Self.fingerprint(anchor.y),
                    Self.fingerprint(anchor.z)
                ].joined(separator: ",")
            } else {
                anchorDescription = "missing"
            }
            return [
                entry.messageId,
                entry.row.isSentByUser ? "sent" : "received",
                entry.row.fromAddress.lowercased(),
                entry.row.recipientAddresses.map { $0.lowercased() }.sorted().joined(separator: ";"),
                anchoredMessageIds.contains(entry.messageId) ? "anchored" : "missing",
                anchorDescription
            ].joined(separator: ":")
        }
        return ([focusEmail] + rowEntries).joined(separator: "|")
    }

    private var peopleAnnotationRefreshKey: PeopleAnnotationRefreshKey? {
        guard isPeopleFocusOverlay else { return nil }
        return PeopleAnnotationRefreshKey(
            scopeFingerprint: peopleAnnotationScopeFingerprint,
            contextMessageID: context?.center.messageId
        )
    }

    private static func fingerprint(_ value: Float) -> String {
        String(format: "%.5f", Double(value))
    }

    @MainActor
    private func makeAnnotationItems(context: LockedNodeContext) -> [AnnotationItem] {
        AnnotationItemFactory(
            centerSubject: row.subject,
            centerReceivedAt: row.receivedAt,
            summaryOverridesByMessageId: summaryByMessageId,
            personFocus: personFocus,
            peopleRingRows: peopleRingRowsForFactory,
            peopleRingRowsAreAuthoritative: isPeopleFocusOverlay
        )
        .makeItems(context: context, renderPacket: renderPacket)
    }

    /// Rebuilds `annotationItems` with the latest `summaryByMessageId`
    /// values folded into the factory. Skipped when the lock context
    /// hasn't loaded yet — `loadContext` builds the initial set.
    @MainActor
    private func rebuildAnnotationItemsAfterSummaryUpdate() {
        guard let context else { return }
        let items = makeAnnotationItems(context: context)
        annotationItems = items
        rankedAnnotationItems = rankedItems(for: items)
    }

    @MainActor
    private func rebuildAnnotationItemsAfterPeopleScopeUpdate() {
        guard let context else { return }
        let items = makeAnnotationItems(context: context)
        annotationItems = items
        rankedAnnotationItems = rankedItems(for: items)
        annotationStates.register(items: items, initiallyOpen: [])
        let rankedCount = rankedAnnotations.count + 1
        let preselectIndex = rankController.currentIndex.map {
            min(max($0, 0), max(0, rankedCount - 1))
        }
        rankController.reset(rankedCount: rankedCount, preselectIndex: preselectIndex)
        let activeItemIDs = Set(items.map(\.id))
        let visibleMessageIDs = Set(items.compactMap(\.anchorMessageId))
        if let selectedMessageID = selectedRingMessageId.wrappedValue,
           !visibleMessageIDs.contains(selectedMessageID) {
            selectedRingMessageId.wrappedValue = nil
        }
        if let hoveredID = dialHoveredItemID, !activeItemIDs.contains(hoveredID) {
            dialHoveredItemID = nil
        }
        if let focusedID = dialFocusedItemID, !activeItemIDs.contains(focusedID) {
            dialFocusedItemID = nil
        }
        if let displayedID = dialDisplayedItemID, !activeItemIDs.contains(displayedID) {
            dialTransitionGeneration &+= 1
            dialDisplayedItemID = nil
            dialTransitionTargetItemID = nil
            dialLeaderProgress = 1
            dialPhase2Snapshot = nil
            dialIsTransitioning = false
        }
        if selectedRingItem != nil {
            syncRankFocusToSelectedRing()
        }
        updatePeopleDialActive()
    }

    /// Materializes the parent-supplied ring scope into the (messageId, row)
    /// pairs the factory consumes. Returns an empty array outside People
    /// focus so the Meanings flow keeps using the in-context neighbour
    /// sample. Sorted by `receivedAt` descending so the factory's emitted
    /// item order is stable across rebuilds (the rank step relies on a
    /// deterministic chronological walk).
    private var peopleRingRowsForFactory: [(messageId: String, row: MessageFilterRow)] {
        guard isPeopleFocusOverlay, !peopleRingMessageIds.isEmpty else {
            return []
        }
        return peopleRingMessageIds
            .compactMap { id -> (messageId: String, row: MessageFilterRow)? in
                guard let row = messageIndex[id] else { return nil }
                return (id, row)
            }
            .sorted { lhs, rhs in
                switch (lhs.row.receivedAt, rhs.row.receivedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.messageId < rhs.messageId
                }
            }
    }

    /// Resolves the lazy summary state to surface in an annotation popup.
    /// Attachments route through `attachmentSummaryStates`; related
    /// message panes route through `relatedSummaryStates` when explicit
    /// expansion beats lock-time prewarm.
    private func summaryDisplay(for item: AnnotationItem) -> AnnotationSummaryDisplay? {
        guard item.kind == .attachment else {
            return relatedSummaryDisplay(for: item)
        }
        guard let reference = item.attachmentReference else {
            return nil
        }
        switch reference.extractionState {
        case .extracting:
            return .extracting
        case .waitingForAppleIntelligence:
            return .waitingForAppleIntelligence
        case .unsupported:
            return .unsupported
        case .unavailable:
            return .unavailable
        case .ready:
            switch attachmentSummaryStates[reference.attachmentID] {
            case .loading:
                return .loading
            case .loaded(let text):
                return .ready(text)
            case .failed:
                return .unavailable
            case nil:
                // Idle — summary hasn't been requested yet. The chevron
                // collapsed view shows the brief; once the user expands,
                // `kickAttachmentSummaryIfNeeded` flips this to `.loading`.
                return nil
            }
        }
    }

    private func relatedSummaryDisplay(for item: AnnotationItem) -> AnnotationSummaryDisplay? {
        guard let messageId = item.anchorMessageId else {
            return nil
        }
        if regeneratingSummaryMessageIds.contains(messageId) {
            return .loading
        }
        if let summary = trimmedSummary(summaryByMessageId[messageId]) {
            return .ready(summary)
        }
        if let summary = trimmedSummary(item.summary) {
            return .ready(summary)
        }
        switch relatedSummaryStates[messageId] {
        case .loading:
            return .loading
        case .loaded(let text):
            return .ready(text)
        case .failed:
            return .unavailable
        case nil:
            return nil
        }
    }

    private func messageDisplay(for item: AnnotationItem) -> AnnotationMessageDisplay? {
        guard let messageId = item.anchorMessageId else { return nil }
        switch relatedMessageBodyStates[messageId] {
        case .loading:
            return .loading
        case .loaded(let text, _):
            return .ready(text)
        case .failed:
            return .unavailable
        case nil:
            return nil
        }
    }

    private func messageAttachments(for item: AnnotationItem) -> [AnnotationMessageAttachmentLink] {
        guard let messageId = item.anchorMessageId else { return [] }
        let currentAttachments = messageAttachmentLinks(forMessageId: messageId)
        if !currentAttachments.isEmpty {
            return currentAttachments
        }
        switch relatedMessageBodyStates[messageId] {
        case .loaded(_, let attachments):
            return attachments
        case .loading, .failed, nil:
            return []
        }
    }

    @MainActor
    private func kickExpandedSummaryIfNeeded(item: AnnotationItem) {
        kickAttachmentExtractionIfNeeded(item: item)
        kickAttachmentSummaryIfNeeded(item: item)
        kickRelatedSummaryIfNeeded(item: item)
    }

    @MainActor
    private func kickRelatedSummaryIfNeeded(item: AnnotationItem) {
        guard let messageId = item.anchorMessageId,
              item.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              summaryByMessageId[messageId]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              relatedSummaryStates[messageId] != .loading,
              let target = relatedSummaryTarget(forMessageId: messageId) else {
            return
        }
        relatedSummaryStates[messageId] = .loading
        Task { @MainActor in
            let rawSummary = await onRequestRelatedSummary(target)
            let summary = trimmedSummary(rawSummary)
            if let summary {
                relatedSummaryStates[messageId] = .loaded(summary)
            } else if trimmedSummary(summaryByMessageId[messageId]) != nil {
                relatedSummaryStates[messageId] = nil
            } else {
                relatedSummaryStates[messageId] = .failed
            }
        }
    }

    private func trimmedSummary(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func relatedSummaryTarget(forMessageId messageId: String) -> LockedNodeRelatedSummaryPrewarm? {
        if let sibling = context?.thread.first(where: { $0.messageId == messageId }) {
            return LockedNodeRelatedSummaryPrewarm(messageId: sibling.messageId, row: sibling.row)
        }
        if let neighbour = context?.neighbours.first(where: { $0.messageId == messageId }) {
            return LockedNodeRelatedSummaryPrewarm(messageId: neighbour.messageId, row: neighbour.row)
        }
        return nil
    }

    @MainActor
    private func kickRelatedMessageBodyIfNeeded(item: AnnotationItem) {
        guard let messageId = item.anchorMessageId,
              relatedMessageBodyStates[messageId] == nil,
              let row = relatedMessageRow(forMessageId: messageId) else {
            return
        }
        relatedMessageBodyStates[messageId] = .loading
        let attachments = messageAttachmentLinks(forMessageId: messageId)
        let htmlPath = row.bodyHtmlPath
        let textPath = row.bodyTextPath
        let lockedVectorId = lockedVectorId
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LockReadoutBodyLoader.load(
                    htmlPath: textPath == nil ? htmlPath : nil,
                    textPath: textPath
                )
            }.value
            guard self.lockedVectorId == lockedVectorId else { return }
            guard case .loaded(let source) = result else {
                self.relatedMessageBodyStates[messageId] = attachments.isEmpty
                    ? .failed
                    : .loaded("", attachments)
                return
            }
            let bodyContent = LockReadoutBodyContent(source: source)
            // Full body, no character cap: the annotation popup's message
            // window scrolls, so a long email is read in place instead of
            // being cut (a cap would also append the banned "..." marker).
            let text = OriginalMessageText.cleaned(from: bodyContent.plainText)
            if let text {
                self.relatedMessageBodyStates[messageId] = .loaded(text, attachments)
            } else if !attachments.isEmpty {
                self.relatedMessageBodyStates[messageId] = .loaded("", attachments)
            } else {
                self.relatedMessageBodyStates[messageId] = .failed
            }
        }
    }

    @MainActor
    private func messageAttachmentLinks(forMessageId messageId: String) -> [AnnotationMessageAttachmentLink] {
        guard let uuid = UUID(uuidString: messageId),
              let message = try? modelContext.fetch(
                FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
              ).first else {
            return []
        }
        return message.attachments
            .map {
                AnnotationMessageAttachmentLink(
                    id: $0.id,
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    sizeBytes: $0.sizeBytes,
                    filePath: $0.filePath,
                    summaryText: AnnotationMessageAttachmentLink.displaySummary(
                        visualSummary: $0.visualSummary,
                        attachmentSummary: $0.attachmentSummary,
                        mimeType: $0.mimeType,
                        filename: $0.filename
                    )
                )
            }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    private func relatedMessageRow(forMessageId messageId: String) -> MessageFilterRow? {
        if let sibling = context?.thread.first(where: { $0.messageId == messageId }) {
            return sibling.row
        }
        if let neighbour = context?.neighbours.first(where: { $0.messageId == messageId }) {
            return neighbour.row
        }
        return messageIndex[messageId]
    }

    /// Fires a single attachment-summary request the first time the user
    /// expands an attachment popup. Subsequent expands are no-ops because
    /// the state map already carries `.loading` / `.loaded` / `.failed`.
    /// Queued, unavailable, and unsupported attachments short-circuit — there's
    /// no text to feed the model.
    @MainActor
    private func kickAttachmentSummaryIfNeeded(item: AnnotationItem) {
        guard item.kind == .attachment,
              let reference = item.attachmentReference,
              reference.extractionState == .ready,
              item.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              attachmentSummaryStates[reference.attachmentID] == nil else {
            return
        }
        attachmentSummaryStates[reference.attachmentID] = .loading
        let attachmentID = reference.attachmentID
        let input = AttachmentSummaryInput(
            attachmentID: attachmentID,
            filename: reference.filename,
            mimeType: reference.mimeType,
            sizeBytes: reference.sizeBytes,
            extractedText: reference.concatenatedText,
            documentKind: reference.documentKind,
            structureUnitKind: reference.structureUnitKind,
            structureUnitCount: reference.structureUnitCount,
            characterCount: reference.characterCount,
            documentTitle: reference.documentTitle,
            documentAuthor: reference.documentAuthor,
            anchorSubject: row.subject,
            anchorSenderName: row.fromName ?? row.fromAddress,
            anchorReceivedAt: row.receivedAt,
            anchorPurpose: row.purpose
        )
        let fingerprint = AttachmentSummaryService.fingerprint(
            input: input,
            targetLanguage: .ohiaPreferred()
        )
        let service = attachmentSummaryService
        let lockedVectorId = lockedVectorId
        Task {
            let result = await service.summary(
                for: attachmentID,
                input: input,
                accountID: row.accountId
            )
            // The enclosing View is a struct so there's no retain cycle to
            // break — `@State` storage is owned by SwiftUI, not the closure.
            // The user may have released the lock or the lock may have moved
            // to a different message while generation was in flight; drop
            // stale results so we don't paint a popup that no longer exists.
            guard self.lockedVectorId == lockedVectorId else { return }
            if let result {
                self.attachmentSummaryStates[attachmentID] = .loaded(result.paragraph)
                self.persistAttachmentSummary(
                    attachmentID: attachmentID,
                    paragraph: result.paragraph,
                    fingerprint: fingerprint
                )
            } else {
                self.attachmentSummaryStates[attachmentID] = .failed
            }
        }
    }

    @MainActor
    private func persistAttachmentSummary(
        attachmentID: UUID,
        paragraph: String,
        fingerprint: String
    ) {
        do {
            var descriptor = FetchDescriptor<Attachment>(
                predicate: #Predicate<Attachment> { $0.id == attachmentID }
            )
            descriptor.fetchLimit = 1
            guard let attachment = try modelContext.fetch(descriptor).first else { return }
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            attachment.attachmentSummary = trimmed
            attachment.attachmentSummaryFingerprint = fingerprint
            attachment.attachmentSummaryGeneratedAt = Date()
            attachment.attachmentSummaryAttemptedAt = Date()
            attachment.attachmentSummaryFailureReason = nil
            try modelContext.save()
        } catch {
            lockedOverlayLogger.error("failed to persist attachment summary: \(error, privacy: .private)")
        }
    }

    /// Expanding a queued attachment is explicit user intent: ask the scheduler
    /// to extract this locked message now instead of waiting for the bulk
    /// catch-up attachment pass to become eligible.
    @MainActor
    private func kickAttachmentExtractionIfNeeded(item: AnnotationItem) {
        guard item.kind == .attachment,
              let reference = item.attachmentReference,
              reference.extractionState == .extracting,
              let messageID = UUID(uuidString: record.messageId) else {
            return
        }
        let jobType: JobType = reference.isImage ? .extractVisualAttachments : .extractAttachments
        do {
            let alreadyQueued = try JobFetch.active(context: modelContext).contains { job in
                job.type == jobType
                    && job.messageId == messageID
                    && (job.status == .pending || job.status == .running)
            }
            guard !alreadyQueued else { return }
            try JobQueue().enqueue(
                type: jobType,
                priority: 4,
                messageId: messageID,
                context: modelContext
            )
        } catch {
            lockedOverlayLogger.error("failed to enqueue attachment extraction: \(error, privacy: .private)")
        }
    }

    @MainActor
    private func correspondentHistoryRows(
        for loaded: LockedNodeContext
    ) -> [(messageId: String, row: MessageFilterRow)] {
        var entries: [(messageId: String, row: MessageFilterRow)] = [
            (loaded.center.messageId, loaded.center.row)
        ]
        let scopedIds: Set<String>
        if peopleRingMessageIds.isEmpty {
            scopedIds = Set(
                loaded.thread.map(\.messageId)
                    + loaded.neighbours.map(\.messageId)
            )
        } else {
            scopedIds = peopleRingMessageIds
        }
        for messageId in scopedIds.sorted() {
            if let row = messageIndex[messageId] {
                entries.append((messageId, row))
            }
        }
        return entries
    }

    @MainActor
    private func correspondentMemoryNotes(
        for personFocus: LockedPersonFocus,
        historyRows: [(messageId: String, row: MessageFilterRow)]
    ) -> [ContextOrientationMemoryNote] {
        guard let askMemoryProvider else { return [] }
        let email = personFocus.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return [] }
        let accountIds = Array(Set(historyRows.compactMap { $0.row.accountId }))
            .sorted { $0.uuidString < $1.uuidString }
        let query = [
            personFocus.displayName,
            email,
            "correspondence history relationship status topics issues"
        ]
        .joined(separator: " ")
        do {
            let context = try askMemoryProvider.context(
                for: query,
                filter: FilterSpec(
                    accountIds: accountIds,
                    senderEmails: [email]
                ),
                limit: AskMemoryLimit(maxSnippets: 5, maxCharacters: 1_800)
            )
            return context.snippets
                .filter { $0.source.hasPrefix("memory:\(AccountMemoryDimension.correspondent):") }
                .map {
                    ContextOrientationMemoryNote(
                        title: $0.title,
                        text: $0.text,
                        source: $0.source,
                        score: $0.score
                    )
                }
        } catch {
            lockedOverlayLogger.warning(
                "failed to load correspondent memories: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            return []
        }
    }

    @MainActor
    private func runOrientationGeneration(
        for loaded: LockedNodeContext,
        sequence: Int,
        forceRefresh: Bool = false
    ) async {
        let lockedVectorId = lockedVectorId
        let input: ContextOrientationInput
        let activityAccountID: UUID?
        if isPeopleFocusOverlay, let personFocus {
            let historyRows = correspondentHistoryRows(for: loaded)
            activityAccountID = SummarizationAccountResolver.singleAccountID(
                in: historyRows.map(\.row.accountId)
            )
            let memoryNotes = correspondentMemoryNotes(
                for: personFocus,
                historyRows: historyRows
            )
            input = LockOrientationInputBuilder.buildCorrespondentRelationship(
                personFocus: personFocus,
                historyRows: historyRows,
                telemetry: loaded.surveyTelemetry,
                memoryNotes: memoryNotes,
                userIdentity: userIdentity
            )
        } else {
            let attachments = LockOrientationInputBuilder.attachmentsFromOwnChunks(loaded.ownChunks)
            input = LockOrientationInputBuilder.build(
                anchorRow: loaded.center.row,
                bodyContent: loaded.center.bodyContent,
                ownChunks: loaded.ownChunks,
                neighbours: loaded.neighbours,
                threadSiblings: loaded.thread,
                attachments: attachments,
                telemetry: loaded.surveyTelemetry,
                activeFrame: activeFrame,
                userIdentity: userIdentity,
                anchorDirection: loaded.center.row.isSentByUser ? .outgoing : .incoming
            )
            activityAccountID = loaded.center.row.accountId
        }
        let requestID = UUID()
        orientationRequestID = requestID
        guard input.hasOrientationEvidence else {
            orientation = .unavailable
            return
        }
        orientation = .loading
        let service = contextOrientationService
        let result = await Task.detached(priority: .userInitiated) {
            await service.orientation(
                for: lockedVectorId,
                input: input,
                forceRefresh: forceRefresh,
                accountID: activityAccountID
            )
        }.value
        // Re-check that the user hasn't released the lock while we were generating.
        guard !Task.isCancelled,
              orientationRequestID == requestID,
              self.lockedVectorId == lockedVectorId,
              enrichmentSequence == sequence,
              context?.center.messageId == loaded.center.messageId else {
            return
        }
        if let result, !result.paragraph.isEmpty {
            orientation = .loaded(result)
        } else {
            orientation = .failed
        }
    }
}

private struct LockedOrientationGenerationKey: Equatable {
    let vectorId: Int64
    let sequence: Int
    let messageId: String
}

/// Per-attachment view of the lazy summary pipeline. Consumed by the
/// overlay's `[UUID: AttachmentSummaryFetchState]` map and projected into
/// each popup's `AnnotationSummaryDisplay` when it expands.
enum AttachmentSummaryFetchState: Equatable {
    case loading
    case loaded(String)
    case failed
}

/// Per-message view of the lazy summary pipeline for thread/neighbour
/// annotation panes. Separate from attachment state because the parent
/// `ConstellationModeView` owns message-summary generation and persistence.
enum RelatedSummaryFetchState: Equatable {
    case loading
    case loaded(String)
    case failed
}

/// Per-message view of the original-body display for thread/neighbour
/// annotation panes. Shift-Space / Shift-click uses this instead of the
/// generated summary state above.
enum RelatedMessageBodyFetchState: Equatable {
    case loading
    case loaded(String, [AnnotationMessageAttachmentLink])
    case failed
}

/// Display states for the CONTEXT pane's orientation paragraph. Drives the
/// pane to either show the placeholder animation, the rendered paragraph, or
/// fall back to the legacy structure-only readout.
enum LockOrientationDisplayState: Equatable {
    case pending          // before context load returns
    case loading          // generation in flight
    case loaded(ContextOrientationResult)   // paragraph ready
    case failed           // generation failed (transient)
    case unavailable      // no orientation evidence to lean on
}

extension HorizontalEdge {
    fileprivate var opposite: HorizontalEdge {
        switch self {
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }
}

/// Constants shared by the rank-step navigator and the gauge geometry.
enum LockNeighbourRankConstants {
    /// Cosine-similarity floor used to qualify "neighbour" status. Mirrors
    /// `LockedNeighborhoodResolver.QualityGate.default.absoluteFloor` (0.95
    /// for BGE-M3) — the floor the ingestion pipeline already enforces, so
    /// the gauge's "0" position represents the worst-case neighbour the
    /// user can ever see, and the "1" position represents a perfect
    /// embedding match.
    static let affinityFloor: Float = 0.95
}

private struct LockedCardMoveSession: Equatable {
    let startCenter: CGPoint
    let settledFrame: CGRect
}

private struct LockedCardResizeSession: Equatable {
    let startFrame: CGRect
    let settledFrame: CGRect
}

private struct LockedOverlayPaneMoveSession: Equatable {
    let id: String
    let startCenter: CGPoint
    let settledFrame: CGRect
}

private enum LockedOverlayPaneKey {
    static let primaryEmail = "primary-email"
    static let telemetry = "telemetry"

    static func annotation(_ id: String) -> String {
        "annotation:\(id)"
    }
}

private struct LockedEmailCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 1, next.height > 1 else { return }
        value = next
    }
}

// MARK: - People-focus space backdrop
//
// Port of `SpaceBackground` + `BackdropStarField` from
// `Ohia/Previews/DesignSandbox.swift` so the production People-focus
// overlay sits on the same midnight-radial-gradient + sparse-twinkle
// backdrop the sandbox study used.

private struct PeopleFocusSpaceBackdrop: View {
    /// Freezes the twinkle timeline while the overlay is at rest. Even a
    /// throttled tick re-evaluates the overlay's layout graph, and a
    /// settled lock should cost nothing.
    let twinklePaused: Bool

    var body: some View {
        // Only the twinkling star layer. The Metal renderer already
        // paints the dark void backdrop beneath this SwiftUI overlay;
        // stacking the sandbox's RadialGradient on top would render an
        // opaque dark fill over the Metal-rendered Saturn (the rings
        // simply disappear behind it). The stars alone are sparse
        // enough to add the sandbox's twinkle feel without occluding
        // anything important.
        //
        // The twinkle is a ~7-second sine (`time * 0.9`), so a 10Hz tick
        // renders it visually identically to 60Hz at a sixth of the
        // SwiftUI churn. This timeline runs for the entire life of a
        // People lock — including fully settled ones — and was the
        // residual idle burn after the overlay's own body timeline
        // learned to idle.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: twinklePaused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            PeopleFocusStarField(time: t)
        }
    }
}

private struct PeopleFocusStarField: View {
    /// One star of the backdrop: unit-space position, brightness base,
    /// and twinkle phase. Derived once from the fixed seed — re-running
    /// the seeded RNG for all 320 stars on every tick produced byte-for-
    /// byte identical values at real per-frame cost. The draw order of
    /// the RNG (x, y, base, phase per star) is preserved so the field
    /// renders exactly as it always has.
    private struct Star {
        let unitX: CGFloat
        let unitY: CGFloat
        let base: Double
        let twinklePhase: Double
    }

    private static let stars: [Star] = {
        var rng = PeopleFocusSeededRandom(seed: 71)
        return (0..<320).map { _ in
            let unitX = CGFloat(rng.nextDouble())
            let unitY = CGFloat(rng.nextDouble())
            let base = rng.nextDouble()
            let twinklePhase = rng.nextDouble() * .pi * 2
            return Star(unitX: unitX, unitY: unitY, base: base, twinklePhase: twinklePhase)
        }
    }()

    let time: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { gc, size in
            for star in Self.stars {
                let twinkle = 0.65 + 0.35 * sin(time * 0.9 + star.twinklePhase)
                let sz = CGFloat(0.6 + star.base * 1.6)
                gc.fill(
                    Path(ellipseIn: CGRect(
                        x: star.unitX * size.width - sz / 2,
                        y: star.unitY * size.height - sz / 2,
                        width: sz,
                        height: sz
                    )),
                    with: .color(.white.opacity((0.10 + star.base * 0.50) * twinkle))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PeopleFocusSeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = max(seed, 1) }
    mutating func nextUInt64() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func nextDouble() -> Double {
        Double(nextUInt64() & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
    }
}
