import Foundation
import OhiaCore

// MARK: - ResourceDecision

public enum ResourceThrottleReason: String, Codable, Sendable, CaseIterable {
    case catchUpDisabled = "catch_up_disabled"
    case notOnACPower = "not_on_ac_power"
    case lowPowerMode = "low_power_mode"
    case memoryWarning = "memory_warning"
    case memoryCritical = "memory_critical"
    case thermalSerious = "thermal_serious"
    case thermalCritical = "thermal_critical"
    case userActive = "user_active"
    case constellationActive = "constellation_active"
    case ohiaForeground = "ohia_foreground"
    case activitySnapshotStale = "activity_snapshot_stale"
    case workerMemoryGuard = "worker_memory_guard"
    case qwenActive = "qwen_active"
    case interactiveQwenGeneration = "interactive_qwen_generation"
    case qwenInterpretationBackpressure = "qwen_interpretation_backpressure"
}

public enum BackgroundModelMode: String, Codable, Sendable, Equatable, CaseIterable {
    case full
    case throttled
    case paused
}

public struct BGEResourceDecision: Sendable, Equatable {
    public let modelMode: BackgroundModelMode
    public let embeddingLaneLimit: Int
    public let allowsModelHeavyWork: Bool

    public init(
        modelMode: BackgroundModelMode,
        embeddingLaneLimit: Int,
        allowsModelHeavyWork: Bool
    ) {
        self.modelMode = modelMode
        self.embeddingLaneLimit = max(1, embeddingLaneLimit)
        self.allowsModelHeavyWork = allowsModelHeavyWork
    }
}

public struct QwenResourceDecision: Sendable, Equatable {
    public let modelMode: BackgroundModelMode
    public let allowsBackgroundTraining: Bool
    public let allowsBackgroundGeneration: Bool
    public let allowsUserInitiatedWork: Bool
    /// A newly arrived email waits (for at most two minutes) to appear with
    /// its prepared reply. That preparation may run through the foreground
    /// throttle, like the email's first interpretation, without opening any
    /// other background generation.
    public let allowsArrivalReplyPreparation: Bool

    public init(
        modelMode: BackgroundModelMode,
        allowsBackgroundTraining: Bool,
        allowsBackgroundGeneration: Bool,
        allowsUserInitiatedWork: Bool,
        allowsArrivalReplyPreparation: Bool? = nil
    ) {
        self.modelMode = modelMode
        self.allowsBackgroundTraining = allowsBackgroundTraining
        self.allowsBackgroundGeneration = allowsBackgroundGeneration
        self.allowsUserInitiatedWork = allowsUserInitiatedWork
        self.allowsArrivalReplyPreparation = allowsArrivalReplyPreparation ?? allowsBackgroundGeneration
    }
}

public enum ModelWorkClass: String, Codable, Sendable, CaseIterable {
    case qwenInteractive = "qwen_interactive"
    case qwenInterpretation = "qwen_interpretation"
    case qwenTraining = "qwen_training"
    case bgeLiveFreshness = "bge_live_freshness"
    case bgeBulkEmbedding = "bge_bulk_embedding"
    case bgeMaintenance = "bge_maintenance"
}

public struct ModelComputeBudget: Sendable, Equatable {
    public let activeClass: ModelWorkClass?
    public let allowedWorkClasses: [ModelWorkClass]
    public let activeProcessorCount: Int
    public let configuredBGELanes: Int
    public let bgeLaneLimit: Int
    public let qwenAllowsGeneration: Bool
    public let qwenAllowsTraining: Bool
    public let throttleReason: ResourceThrottleReason?

    public init(
        activeClass: ModelWorkClass?,
        allowedWorkClasses: [ModelWorkClass],
        activeProcessorCount: Int,
        configuredBGELanes: Int,
        bgeLaneLimit: Int,
        qwenAllowsGeneration: Bool,
        qwenAllowsTraining: Bool,
        throttleReason: ResourceThrottleReason?
    ) {
        self.activeClass = activeClass
        self.allowedWorkClasses = Self.uniquePreservingOrder(allowedWorkClasses)
        self.activeProcessorCount = max(1, activeProcessorCount)
        self.configuredBGELanes = max(1, configuredBGELanes)
        self.bgeLaneLimit = max(1, min(max(1, configuredBGELanes), bgeLaneLimit))
        self.qwenAllowsGeneration = qwenAllowsGeneration
        self.qwenAllowsTraining = qwenAllowsTraining
        self.throttleReason = throttleReason
    }

    public func allows(_ workClass: ModelWorkClass) -> Bool {
        allowedWorkClasses.contains(workClass)
    }

    static func resolved(
        maxAllowedPriority: Int,
        shouldPauseAll: Bool,
        bge: BGEResourceDecision,
        qwen: QwenResourceDecision,
        activeClass: ModelWorkClass?,
        forcedAllowedWorkClasses: [ModelWorkClass]? = nil,
        activeProcessorCount: Int,
        configuredBGELanes: Int,
        throttleReason: ResourceThrottleReason?
    ) -> ModelComputeBudget {
        let allowed: [ModelWorkClass]
        if let forcedAllowedWorkClasses {
            allowed = forcedAllowedWorkClasses
        } else if shouldPauseAll {
            allowed = []
        } else {
            var classes: [ModelWorkClass] = []
            if qwen.allowsUserInitiatedWork {
                classes.append(.qwenInteractive)
                if qwen.allowsBackgroundGeneration, maxAllowedPriority >= 6 {
                    classes.append(.qwenInterpretation)
                }
            }
            if qwen.allowsBackgroundTraining, maxAllowedPriority >= 8 {
                classes.append(.qwenTraining)
            }
            if bge.allowsModelHeavyWork {
                classes.append(.bgeLiveFreshness)
                if maxAllowedPriority >= 5 {
                    classes.append(.bgeBulkEmbedding)
                }
                if maxAllowedPriority >= 8 {
                    classes.append(.bgeMaintenance)
                }
            }
            allowed = classes
        }

        return ModelComputeBudget(
            activeClass: activeClass,
            allowedWorkClasses: allowed,
            activeProcessorCount: activeProcessorCount,
            configuredBGELanes: configuredBGELanes,
            bgeLaneLimit: bge.embeddingLaneLimit,
            qwenAllowsGeneration: qwen.allowsBackgroundGeneration,
            qwenAllowsTraining: qwen.allowsBackgroundTraining,
            throttleReason: throttleReason
        )
    }

    private static func uniquePreservingOrder(_ classes: [ModelWorkClass]) -> [ModelWorkClass] {
        var seen = Set<ModelWorkClass>()
        var unique: [ModelWorkClass] = []
        for workClass in classes where !seen.contains(workClass) {
            seen.insert(workClass)
            unique.append(workClass)
        }
        return unique
    }
}

public struct ResourceDecision: Sendable {
    public let maxAllowedPriority: Int
    public let batchSizeMultiplier: Double
    public let indexBurstMultiplier: Double
    public let interMessageDelayNanoseconds: UInt64
    public let backgroundTaskPriority: TaskPriority
    public let shouldPauseAll: Bool
    public let isCatchUpModeActive: Bool
    public let bge: BGEResourceDecision
    public let qwen: QwenResourceDecision
    public let backgroundModelMode: BackgroundModelMode
    public let bgeEmbeddingLaneLimit: Int
    public let allowsQwenTraining: Bool
    public let allowsBackgroundGeneration: Bool
    public let requiresExclusiveModelResidency: Bool
    public let throttleReasons: [ResourceThrottleReason]
    public let modelComputeBudget: ModelComputeBudget

    public init(
        maxAllowedPriority: Int,
        batchSizeMultiplier: Double,
        indexBurstMultiplier: Double,
        interMessageDelayNanoseconds: UInt64,
        backgroundTaskPriority: TaskPriority,
        shouldPauseAll: Bool,
        isCatchUpModeActive: Bool = false,
        backgroundModelMode: BackgroundModelMode = .full,
        bgeEmbeddingLaneLimit: Int = 1,
        allowsQwenTraining: Bool = true,
        allowsBackgroundGeneration: Bool = true,
        requiresExclusiveModelResidency: Bool = false,
        throttleReasons: [ResourceThrottleReason] = [],
        bge: BGEResourceDecision? = nil,
        qwen: QwenResourceDecision? = nil,
        modelComputeBudget: ModelComputeBudget? = nil
    ) {
        self.maxAllowedPriority = maxAllowedPriority
        self.batchSizeMultiplier = batchSizeMultiplier
        self.indexBurstMultiplier = indexBurstMultiplier
        self.interMessageDelayNanoseconds = interMessageDelayNanoseconds
        self.backgroundTaskPriority = backgroundTaskPriority
        self.shouldPauseAll = shouldPauseAll
        self.isCatchUpModeActive = isCatchUpModeActive
        let resolvedBGE = bge ?? BGEResourceDecision(
            modelMode: backgroundModelMode,
            embeddingLaneLimit: bgeEmbeddingLaneLimit,
            allowsModelHeavyWork: shouldPauseAll == false && backgroundModelMode != .paused
        )
        let resolvedQwen = qwen ?? QwenResourceDecision(
            modelMode: (allowsQwenTraining || allowsBackgroundGeneration) ? backgroundModelMode : .paused,
            allowsBackgroundTraining: allowsQwenTraining,
            allowsBackgroundGeneration: allowsBackgroundGeneration,
            allowsUserInitiatedWork: shouldPauseAll == false
        )
        self.bge = resolvedBGE
        self.qwen = resolvedQwen
        self.backgroundModelMode = resolvedBGE.modelMode
        self.bgeEmbeddingLaneLimit = resolvedBGE.embeddingLaneLimit
        self.allowsQwenTraining = resolvedQwen.allowsBackgroundTraining
        self.allowsBackgroundGeneration = resolvedQwen.allowsBackgroundGeneration
        self.requiresExclusiveModelResidency = requiresExclusiveModelResidency
        self.throttleReasons = throttleReasons
        self.modelComputeBudget = modelComputeBudget ?? ModelComputeBudget.resolved(
            maxAllowedPriority: maxAllowedPriority,
            shouldPauseAll: shouldPauseAll,
            bge: resolvedBGE,
            qwen: resolvedQwen,
            activeClass: nil,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            configuredBGELanes: resolvedBGE.embeddingLaneLimit,
            throttleReason: throttleReasons.last
        )
    }

    public static let unrestricted = ResourceDecision(
        maxAllowedPriority: 9,
        batchSizeMultiplier: 1.0,
        indexBurstMultiplier: 1.0,
        interMessageDelayNanoseconds: 0,
        backgroundTaskPriority: .utility,
        shouldPauseAll: false,
        isCatchUpModeActive: false,
        backgroundModelMode: .full,
        bgeEmbeddingLaneLimit: 4,
        allowsQwenTraining: true,
        allowsBackgroundGeneration: true,
        throttleReasons: []
    )

    public func modelMode(for role: WorkerRole) -> BackgroundModelMode {
        switch role {
        case .bge:
            return bge.modelMode
        case .qwen:
            return qwen.modelMode
        }
    }

    public func scaledLimit(_ base: Int, minimum: Int = 1) -> Int {
        max(minimum, Int((Double(base) * batchSizeMultiplier).rounded(.down)))
    }
}

// MARK: - ResourcePolicy

public enum ResourcePolicy {
    private static let gibibyte = 1024.0 * 1024.0 * 1024.0

    private struct WorkerMemoryBudget {
        let warningBytes: UInt64
        let criticalBytes: UInt64
    }

    /// Evaluate the current system state and return a scheduling decision.
    ///
    /// Priority scale: 1 = highest (user-initiated), 9 = lowest (historical backfill).
    /// Rules are applied in order; each rule can only lower (tighten) the current limits.
    public static func evaluate(
        _ state: ResourceState,
        idleThreshold: Double,
        trainingIdleThreshold: TimeInterval? = nil,
        isInteractiveViewActive: Bool = false,
        catchUpModeEnabled: Bool = false,
        appActivity: AppActivitySnapshot? = nil,
        maxEmbeddingLanes: Int = 1,
        workerRole: WorkerRole? = nil,
        siblingModelWorkerActive: Bool = false,
        siblingModelResident: Bool = false,
        interactiveQwenGenerationActive: Bool = false,
        interactiveGenerationLane: InteractiveGenerationLane? = nil,
        qwenInterpretationBackpressureActive: Bool = false,
        initialIngestionCoreProgressActive: Bool = false,
        liveFreshnessActive: Bool = false,
        liveInterpretationActive: Bool = false,
        composerDraftingActive: Bool = false,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ResourceDecision {
        var maxPriority = 9
        var batchMultiplier = 1.0
        var indexBurstMultiplier = 1.0
        var interMessageDelayNanoseconds: UInt64 = 0
        var taskPriority = TaskPriority.utility
        var pauseAll = false
        var bgeModelMode = BackgroundModelMode.full
        var bgeEmbeddingLaneLimit = max(1, maxEmbeddingLanes)
        var bgeAllowsModelHeavyWork = true
        var qwenModelMode = BackgroundModelMode.full
        var qwenAllowsBackgroundTraining = true
        var qwenAllowsBackgroundGeneration = true
        var qwenAllowsUserInitiatedWork = true
        var activeBudgetClass: ModelWorkClass?
        var forcedBudgetClasses: [ModelWorkClass]?
        var budgetThrottleReason: ResourceThrottleReason?
        var foregroundLiveFreshnessBorrowing = false
        var foregroundLiveInterpretationBorrowing = false
        var foregroundComposerDraftingBorrowing = false
        var reasons: [ResourceThrottleReason] = []
        func addReason(_ reason: ResourceThrottleReason) {
            if !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        let protectedModelReasons: [ResourceThrottleReason] = [
            .notOnACPower,
            .lowPowerMode,
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical
        ]
        func hasProtectedModelReason() -> Bool {
            protectedModelReasons.contains { reasons.contains($0) }
        }
        func hasComposerHardStopReason() -> Bool {
            protectedModelReasons
                .filter { $0 != .memoryWarning }
                .contains { reasons.contains($0) }
        }
        let resolvedInteractiveLane = interactiveGenerationLane
            ?? (interactiveQwenGenerationActive ? .userInteractive : nil)
        let interactiveGenerationActive = resolvedInteractiveLane != nil
        let userInteractiveGenerationActive = resolvedInteractiveLane == .userInteractive
        let memoryPressure = effectiveMemoryPressure(state, workerRole: workerRole)
        let requiresExclusiveModelResidency = shouldApplySiblingMemoryGuard(state)

        let now = Date()
        let isActivityFresh = appActivity?.isFresh(now: now) == true
        // A stale foreground/interaction snapshot is unsafe: the app may have
        // changed state without this process seeing it, so fall back to HID
        // idle time. A stale background snapshot is different: once Ohia has
        // resigned active, other-app interaction should not make Ohia throttle
        // just because no new Ohia events are being written.
        let shouldTrustActivity = isActivityFresh || appActivity?.isAppFrontmost == false
        let effectiveActivity = shouldTrustActivity ? appActivity : nil
        if appActivity != nil, !isActivityFresh, appActivity?.isAppFrontmost != false {
            addReason(.activitySnapshotStale)
        }
        let hasAppActivitySignal = effectiveActivity != nil
        // The witness is a liveness override, so preserve it even if the
        // ordinary interaction heartbeat becomes stale. A busy MainActor can
        // otherwise make the panel revoke the exemption it needs to finish.
        let onboardingWitnessActive = appActivity?.isOnboardingWitnessActive == true
        let isOhiaForeground = effectiveActivity?.isAppFrontmost == true
        let composerForegroundActive = composerDraftingActive
            && effectiveActivity?.isAppFrontmost == true
            && effectiveActivity?.isComposerActive == true
        let recentOhiaInteraction = isActivityFresh && appActivity?.hasRecentOhiaInteraction(
            now: now,
            within: min(max(30, idleThreshold), 300)
        ) == true
        let rawOhiaForegroundActive = isOhiaForeground && (
            state.idleSeconds < idleThreshold || recentOhiaInteraction
        )
        let rawStaleForegroundActive = !shouldTrustActivity
            && appActivity?.isAppFrontmost == true
            && state.idleSeconds < idleThreshold
        // The first-ingestion witness is a blocking wait for the first
        // navigable node. Treating its frontmost Constellation as ordinary
        // interaction pauses the BGE work needed to satisfy that wait, making
        // the panel self-blocking. While the witness is mounted, ignore only
        // foreground/activity throttles; the environmental protections below
        // still apply normally.
        let ohiaForegroundActive = rawOhiaForegroundActive && !onboardingWitnessActive
        let staleForegroundActive = rawStaleForegroundActive && !onboardingWitnessActive
        let constellationReportedActive = isInteractiveViewActive
            || appActivity?.isConstellationActive == true
        let interactiveForegroundActive = (
            constellationReportedActive && (ohiaForegroundActive || staleForegroundActive)
        )

        // 1. Critical thermal OR critical memory → pause all model work.
        if state.thermalState == .critical || memoryPressure == .critical {
            pauseAll = true
            maxPriority = min(maxPriority, 2)
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = 1
            bgeAllowsModelHeavyWork = false
            qwenModelMode = .paused
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            qwenAllowsUserInitiatedWork = false
            if state.thermalState == .critical {
                addReason(.thermalCritical)
            }
            if memoryPressure == .critical {
                addReason(.memoryCritical)
            }
        }

        // 2. Memory warning → halve batch size
        if memoryPressure == .warning {
            addReason(.memoryWarning)
            batchMultiplier = min(batchMultiplier, 0.5)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.5)
            bgeModelMode = .throttled
            bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
            qwenModelMode = .paused
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            qwenAllowsUserInitiatedWork = false
            taskPriority = .background
        }

        // 3. Battery power and Low Power Mode are distinct system signals,
        // but both reserve model-heavy background work. An explicit
        // user-initiated Qwen request remains available unless a stronger
        // thermal or memory protection disabled it above.
        if !state.isOnACPower || state.isLowPowerModeEnabled {
            if !state.isOnACPower {
                addReason(.notOnACPower)
            }
            if state.isLowPowerModeEnabled {
                addReason(.lowPowerMode)
                batchMultiplier = min(batchMultiplier, 0.5)
                indexBurstMultiplier = min(indexBurstMultiplier, 0.5)
                interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 50_000_000)
                taskPriority = .background
            }
            maxPriority = min(maxPriority, 4)
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = 1
            bgeAllowsModelHeavyWork = false
            qwenModelMode = .paused
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
        }

        // 4. Serious thermal → throttle priority and batch
        if state.thermalState == .serious {
            addReason(.thermalSerious)
            maxPriority = min(maxPriority, 6)
            batchMultiplier = min(batchMultiplier, 0.5)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.5)
            interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 50_000_000)
            bgeModelMode = .throttled
            bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
            qwenModelMode = .paused
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            qwenAllowsUserInitiatedWork = false
            taskPriority = .background
        }

        // 5. User active in Ohia → no background model inference or training,
        // and run smaller batches so MainActor SwiftData work doesn't make
        // Ohia's own UI feel stuck. Explicit user-requested Qwen stays
        // available through the interactive lane. If the app-activity signal is
        // present and Ohia is backgrounded, other-app use does not throttle
        // Ohia's background catch-up.
        let shouldApplyUserThrottle: Bool
        if onboardingWitnessActive {
            shouldApplyUserThrottle = false
        } else if hasAppActivitySignal {
            shouldApplyUserThrottle = ohiaForegroundActive
        } else {
            shouldApplyUserThrottle = state.idleSeconds < idleThreshold
        }
        if !catchUpModeEnabled {
            addReason(.catchUpDisabled)
        }
        let catchUpEligible = catchUpModeEnabled
            && state.isOnACPower
            && !state.isLowPowerModeEnabled
            && memoryPressure == .nominal
            && (state.thermalState == .nominal || state.thermalState == .fair)
            && !ohiaForegroundActive
            && !staleForegroundActive
            && !shouldApplyUserThrottle
        if shouldApplyUserThrottle, !catchUpEligible {
            addReason(.userActive)
            if ohiaForegroundActive {
                addReason(.ohiaForeground)
            }
            maxPriority = min(maxPriority, 6)
            batchMultiplier = min(batchMultiplier, 0.5)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.5)
            interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 25_000_000)
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
            bgeAllowsModelHeavyWork = false
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            taskPriority = .background
        }

        // 6. Constellation / foreground interaction is the most sensitive
        // state: renderer work, SwiftUI queries, embedding writes, and
        // layout placement all compete inside the same app. Keep progress
        // visible, but use tiny cooperative pulses.
        if interactiveForegroundActive, !catchUpEligible {
            addReason(.constellationActive)
            maxPriority = min(maxPriority, 6)
            batchMultiplier = min(batchMultiplier, 0.25)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.25)
            interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 200_000_000)
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
            bgeAllowsModelHeavyWork = false
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            taskPriority = .background
        }

        // 6a. Live inbound mail is user-visible freshness, not bulk catch-up.
        // While Ohia is foregrounded, keep the broad throttle in place but let
        // one tiny lane through for newly-arrived mail so it can become a star
        // and receive its first interpretation without waiting for the app to
        // go idle. A durable Composer request owns Qwen even if Ohia loses app
        // focus; memory warning throttles that request but does not strand it.
        // Power, critical memory, and serious/critical thermal gates still win.
        let foregroundActive = shouldApplyUserThrottle || interactiveForegroundActive
        let foregroundBorrowingAllowed = foregroundActive && !hasProtectedModelReason()
        let composerBorrowingAllowed = composerDraftingActive && !hasComposerHardStopReason()
        if foregroundBorrowingAllowed || composerBorrowingAllowed,
           !pauseAll,
           !userInteractiveGenerationActive {
            switch workerRole {
            case .bge where liveFreshnessActive || composerDraftingActive:
                // Live arrivals borrow for first embed/placement; a frontmost
                // Composer borrows so generation context packs (and the
                // retrieval they ground on) keep building while the user is
                // actively drafting. Same throttled single-lane budget. The
                // initial ingestion bulk backlog does NOT borrow here: while
                // the user is actively interacting with a frontmost Ohia,
                // bulk embedding stays paused and resumes on idle/background.
                foregroundLiveFreshnessBorrowing = liveFreshnessActive
                bgeModelMode = .throttled
                bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
                bgeAllowsModelHeavyWork = true
                activeBudgetClass = .bgeLiveFreshness
                forcedBudgetClasses = [.bgeLiveFreshness]
                budgetThrottleReason = budgetThrottleReason ?? (
                    interactiveForegroundActive ? .constellationActive : .userActive
                )
            case .qwen where liveInterpretationActive || composerDraftingActive:
                // Two user-visible Qwen lanes can borrow through the
                // foreground throttle: first interpretation of newly-arrived
                // mail, and Composer drafting while the Composer is the
                // front window (question prep, owed generations, instruction
                // revisions). Both keep training and the bulk interpretation
                // backlog paused; the Composer lane additionally re-enables
                // `.generateDraft` claims via `qwenAllowsGeneration`.
                foregroundLiveInterpretationBorrowing = liveInterpretationActive
                    && !composerDraftingActive
                foregroundComposerDraftingBorrowing = composerDraftingActive
                qwenModelMode = .throttled
                qwenAllowsBackgroundTraining = false
                qwenAllowsBackgroundGeneration = true
                if composerDraftingActive {
                    qwenAllowsUserInitiatedWork = true
                }
                activeBudgetClass = composerDraftingActive ? .qwenInteractive : .qwenInterpretation
                var borrowedClasses: [ModelWorkClass] = []
                if composerDraftingActive { borrowedClasses.append(.qwenInteractive) }
                if foregroundLiveInterpretationBorrowing {
                    borrowedClasses.append(.qwenInterpretation)
                }
                forcedBudgetClasses = borrowedClasses
                budgetThrottleReason = budgetThrottleReason ?? (
                    interactiveForegroundActive ? .constellationActive : .userActive
                )
            default:
                break
            }
        }

        // 6b. A user is waiting on an on-demand Qwen summary or CONTEXT
        // paragraph. Give Qwen the machine: stop BGE model-heavy work and keep
        // Qwen background jobs out of the way until the interactive request
        // clears or its short lease expires.
        if userInteractiveGenerationActive, !pauseAll {
            addReason(.interactiveQwenGeneration)
            maxPriority = min(maxPriority, 1)
            batchMultiplier = min(batchMultiplier, 0.1)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.1)
            interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 250_000_000)
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = 1
            bgeAllowsModelHeavyWork = false
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            if qwenAllowsUserInitiatedWork {
                qwenModelMode = .full
            }
            taskPriority = .userInitiated
            activeBudgetClass = .qwenInteractive
            forcedBudgetClasses = qwenAllowsUserInitiatedWork ? [.qwenInteractive] : []
            budgetThrottleReason = .interactiveQwenGeneration
        } else if resolvedInteractiveLane == .lensAssist, !pauseAll {
            addReason(.interactiveQwenGeneration)
            let borrowingThroughLensAssist = foregroundLiveInterpretationBorrowing
                || foregroundComposerDraftingBorrowing
            maxPriority = min(maxPriority, borrowingThroughLensAssist ? 6 : 4)
            batchMultiplier = min(batchMultiplier, 0.25)
            indexBurstMultiplier = min(indexBurstMultiplier, 0.25)
            interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 100_000_000)
            bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = borrowingThroughLensAssist
            qwenModelMode = .throttled
            if foregroundLiveFreshnessBorrowing {
                bgeModelMode = .throttled
                bgeAllowsModelHeavyWork = true
                activeBudgetClass = .bgeLiveFreshness
                forcedBudgetClasses = [.bgeLiveFreshness, .qwenInteractive]
            } else if foregroundLiveInterpretationBorrowing {
                activeBudgetClass = .qwenInterpretation
                forcedBudgetClasses = [.qwenInterpretation, .qwenInteractive]
            } else {
                bgeModelMode = .paused
                bgeAllowsModelHeavyWork = false
                activeBudgetClass = .qwenInteractive
                forcedBudgetClasses = [.qwenInteractive]
            }
            taskPriority = .utility
            budgetThrottleReason = .interactiveQwenGeneration
        }

        // 7. Model contention is expressed as one shared compute budget. BGE
        // still uses its bounded task-group lanes, but the lane count now comes
        // from this single decision instead of scattered Qwen/BGE exceptions.
        if !pauseAll, !interactiveGenerationActive {
            let canRunModelContentionWork = !hasProtectedModelReason()
            let qwenInterpretationHardStopReasons: [ResourceThrottleReason] = [
                .notOnACPower,
                .lowPowerMode,
                .memoryCritical,
                .thermalSerious,
                .thermalCritical
            ]
            let canRunQwenInterpretationWork = !shouldApplyUserThrottle
                && !interactiveForegroundActive
                && !composerDraftingActive
                && !qwenInterpretationHardStopReasons.contains {
                    reasons.contains($0)
                }

            let siblingMemoryGuardApplies = requiresExclusiveModelResidency
                && (siblingModelWorkerActive || siblingModelResident)
            if siblingMemoryGuardApplies {
                addReason(.workerMemoryGuard)
                budgetThrottleReason = budgetThrottleReason ?? .workerMemoryGuard
                batchMultiplier = min(batchMultiplier, 0.25)
                indexBurstMultiplier = min(indexBurstMultiplier, 0.25)
                interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 100_000_000)
                bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
                taskPriority = .background

                switch workerRole {
                case .bge:
                    maxPriority = min(maxPriority, 5)
                    bgeModelMode = .paused
                    bgeAllowsModelHeavyWork = false
                case .qwen:
                    maxPriority = min(maxPriority, 6)
                    qwenModelMode = .throttled
                    qwenAllowsBackgroundTraining = false
                case nil:
                    maxPriority = min(maxPriority, 4)
                    bgeModelMode = .paused
                    bgeAllowsModelHeavyWork = false
                    qwenModelMode = .paused
                    qwenAllowsBackgroundTraining = false
                    qwenAllowsBackgroundGeneration = false
                    qwenAllowsUserInitiatedWork = false
                    forcedBudgetClasses = []
                }
            }

            let bgeInitialIngestionHardStopReasons: [ResourceThrottleReason] = [
                .notOnACPower,
                .lowPowerMode,
                .memoryCritical,
                .thermalSerious,
                .thermalCritical,
                .workerMemoryGuard
            ]
            // Initial ingestion model work normally runs while the user is not
            // actively engaging a frontmost Ohia. The onboarding witness is
            // the exception: it is waiting on this work to render the first
            // navigable node, so foreground interaction cannot pause it.
            // Network-only IMAP acquisition is admitted separately by the
            // scheduler and does not need a model-work exception here.
            // Computed after the sibling memory guard block so an armed
            // .workerMemoryGuard (resident sibling Qwen on a <=16 GB machine)
            // is visible to the hard-stop check: BGE must not load while the
            // guard holds, even with a backpressure ingestion backlog.
            let canRunInitialIngestionCoreProgress = initialIngestionCoreProgressActive
                && !shouldApplyUserThrottle
                && !interactiveForegroundActive
                && !bgeInitialIngestionHardStopReasons.contains {
                    reasons.contains($0)
                }

            if qwenInterpretationBackpressureActive && !onboardingWitnessActive {
                addReason(.qwenInterpretationBackpressure)
                activeBudgetClass = composerDraftingActive
                    ? .qwenInteractive
                    : .qwenInterpretation
                budgetThrottleReason = .qwenInterpretationBackpressure

                switch workerRole {
                case .bge:
                    maxPriority = min(maxPriority, 4)
                    batchMultiplier = min(batchMultiplier, 0.1)
                    indexBurstMultiplier = min(indexBurstMultiplier, 0.1)
                    interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 250_000_000)
                    bgeEmbeddingLaneLimit = 1
                    taskPriority = .background

                    // An armed worker memory guard means the resident sibling
                    // Qwen owns model residency on this machine; BGE must not
                    // load even for a live arrival. The live job simply waits
                    // for the guard to clear.
                    if liveFreshnessActive,
                       canRunModelContentionWork,
                       !reasons.contains(.workerMemoryGuard) {
                        bgeModelMode = .throttled
                        bgeAllowsModelHeavyWork = true
                        activeBudgetClass = .bgeLiveFreshness
                        forcedBudgetClasses = [.bgeLiveFreshness]
                    } else if canRunInitialIngestionCoreProgress {
                        batchMultiplier = max(batchMultiplier, 0.25)
                        indexBurstMultiplier = max(indexBurstMultiplier, 0.25)
                        interMessageDelayNanoseconds = min(
                            interMessageDelayNanoseconds,
                            100_000_000
                        )
                        bgeModelMode = .throttled
                        bgeAllowsModelHeavyWork = true
                        activeBudgetClass = .bgeBulkEmbedding
                        forcedBudgetClasses = [.bgeLiveFreshness, .bgeBulkEmbedding]
                    } else {
                        bgeModelMode = .paused
                        bgeAllowsModelHeavyWork = false
                        forcedBudgetClasses = []
                    }
                case .qwen:
                    qwenAllowsBackgroundTraining = false
                    // Interpretation backpressure pauses bulk draft
                    // generation, but a frontmost Composer keeps its lane:
                    // the user is actively waiting on question prep or a
                    // draft, which outranks backlog drain ordering.
                    let canRunBackpressureInterpretation = canRunQwenInterpretationWork
                        || foregroundLiveInterpretationBorrowing
                    qwenAllowsBackgroundGeneration = foregroundComposerDraftingBorrowing
                        || canRunBackpressureInterpretation
                    if canRunBackpressureInterpretation {
                        maxPriority = max(maxPriority, 6)
                        if canRunQwenInterpretationWork {
                            batchMultiplier = max(batchMultiplier, 1.0)
                            interMessageDelayNanoseconds = 0
                            qwenModelMode = .full
                            taskPriority = .utility
                        } else {
                            qwenModelMode = .throttled
                            taskPriority = .utility
                        }
                        forcedBudgetClasses = foregroundComposerDraftingBorrowing
                            ? [.qwenInterpretation, .qwenInteractive]
                            : [.qwenInterpretation]
                    } else {
                        forcedBudgetClasses = foregroundComposerDraftingBorrowing
                            ? [.qwenInteractive]
                            : []
                    }
                case nil:
                    forcedBudgetClasses = []
                }
            } else if siblingModelWorkerActive,
                      workerRole == .bge,
                      !onboardingWitnessActive {
                addReason(.qwenActive)
                budgetThrottleReason = .qwenActive
                maxPriority = min(maxPriority, 5)
                batchMultiplier = min(batchMultiplier, 0.25)
                indexBurstMultiplier = min(indexBurstMultiplier, 0.25)
                interMessageDelayNanoseconds = max(interMessageDelayNanoseconds, 100_000_000)
                if siblingMemoryGuardApplies {
                    // <=16 GB devices cannot keep both model families resident.
                    // Active Qwen owns this slice; BGE remains unloaded until
                    // the Qwen worker publishes a nonresident heartbeat.
                    activeBudgetClass = nil
                    forcedBudgetClasses = []
                    bgeModelMode = .paused
                    bgeAllowsModelHeavyWork = false
                } else if !foregroundActive || foregroundLiveFreshnessBorrowing {
                    activeBudgetClass = foregroundLiveFreshnessBorrowing
                        ? .bgeLiveFreshness
                        : .bgeBulkEmbedding
                    bgeModelMode = .throttled
                    if canRunModelContentionWork {
                        bgeAllowsModelHeavyWork = true
                        forcedBudgetClasses = foregroundLiveFreshnessBorrowing
                            ? [.bgeLiveFreshness]
                            : [.bgeLiveFreshness, .bgeBulkEmbedding]
                    }
                }
                // else: the user is actively engaging a frontmost Ohia and no
                // live-freshness lane is borrowing through the throttle.
                // Sibling Qwen contention must not re-enable bulk embedding
                // here: rules 5/6 paused BGE model-heavy work and it stays
                // paused until the user goes idle or the app is backgrounded.
                // (A frontmost-Composer borrow from rule 6a keeps its
                // [.bgeLiveFreshness]-only lane untouched.)
                bgeEmbeddingLaneLimit = min(bgeEmbeddingLaneLimit, 1)
                taskPriority = .background
            }
        }

        // Explicit user-invoked inference is a short foreground burst: context
        // and correspondent orientations, translations, Ask, and similar
        // requests should finish promptly rather than inherit a background
        // resource throttle. Give Qwen the machine after every noncritical rule
        // has been evaluated, while keeping all competing model work disabled.
        // Critical thermal or memory pressure remains the emergency stop.
        if userInteractiveGenerationActive && !pauseAll {
            maxPriority = 9
            batchMultiplier = 1.0
            indexBurstMultiplier = 1.0
            interMessageDelayNanoseconds = 0
            taskPriority = .userInitiated
            bgeModelMode = .paused
            bgeEmbeddingLaneLimit = 1
            bgeAllowsModelHeavyWork = false
            qwenModelMode = .full
            qwenAllowsBackgroundTraining = false
            qwenAllowsBackgroundGeneration = false
            qwenAllowsUserInitiatedWork = true
            activeBudgetClass = .qwenInteractive
            forcedBudgetClasses = [.qwenInteractive]
            budgetThrottleReason = nil
        }

        // Foreground Composer work is latency-critical: the user is waiting
        // for sources, questions, or draft text. Let that work own the
        // available model capacity after every noncritical resource and
        // contention rule has been evaluated. Critical thermal or memory
        // pressure still keeps `pauseAll` as the emergency stop.
        if composerForegroundActive && !pauseAll {
            maxPriority = 9
            batchMultiplier = 1.0
            indexBurstMultiplier = 1.0
            interMessageDelayNanoseconds = 0
            taskPriority = .userInitiated
            qwenAllowsBackgroundTraining = false
            budgetThrottleReason = nil

            switch workerRole {
            case .bge:
                bgeModelMode = .full
                bgeEmbeddingLaneLimit = max(1, maxEmbeddingLanes)
                bgeAllowsModelHeavyWork = true
                activeBudgetClass = .bgeLiveFreshness
                forcedBudgetClasses = [.bgeLiveFreshness]
            case .qwen:
                qwenModelMode = .full
                qwenAllowsBackgroundGeneration = true
                qwenAllowsUserInitiatedWork = true
                activeBudgetClass = .qwenInteractive
                forcedBudgetClasses = [.qwenInteractive]
            case nil:
                break
            }
        }

        // Training has its own activity ramp without changing the ordinary
        // foreground policy above:
        // - frontmost + active: held;
        // - backgrounded without an active Composer: admitted full speed
        //   immediately;
        // - frontmost + system idle through the configured threshold: admitted
        //   full speed.
        // Environmental protection and interactive Qwen demand always win.
        let trainingIdleGateSatisfied: Bool
        if let trainingIdleThreshold, trainingIdleThreshold > 0 {
            trainingIdleGateSatisfied = state.idleSeconds >= trainingIdleThreshold
        } else {
            trainingIdleGateSatisfied = true
        }
        let hasTrainingIdleRamp = trainingIdleThreshold.map { $0 > 0 } == true
        let isAppBackgrounded = effectiveActivity?.isAppFrontmost == false
        // Keep the generative model available across the short gaps between
        // Composer stages. A durable job may not exist yet while the user is
        // editing or while one stage is handing off to the next, but starting
        // an optimizer step in that gap would make the next on-demand request
        // wait until the indivisible MLX update completes.
        let composerSurfaceReserved = effectiveActivity?.isComposerActive == true
            && rawOhiaForegroundActive
        let trainingHardStopReasons: Set<ResourceThrottleReason> = [
            .notOnACPower,
            .lowPowerMode,
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical,
            .workerMemoryGuard,
            .interactiveQwenGeneration,
            .qwenInterpretationBackpressure,
        ]
        let trainingHasHardStop = !trainingHardStopReasons.isDisjoint(with: Set(reasons))
            || composerDraftingActive
            || composerSurfaceReserved
            || liveInterpretationActive
        let trainingActivityAllowsWork = trainingIdleGateSatisfied
            || isAppBackgrounded
        let allowsQwenTraining = !pauseAll
            && !trainingHasHardStop
            && trainingActivityAllowsWork
            && (
                qwenAllowsBackgroundTraining && maxPriority >= 8
                    || hasTrainingIdleRamp
            )
        if allowsQwenTraining, trainingActivityAllowsWork {
            qwenModelMode = .full
        }
        let allowsBackgroundGeneration = !pauseAll
            && qwenAllowsBackgroundGeneration
            && maxPriority >= 6
        let bgeDecision = BGEResourceDecision(
            modelMode: bgeModelMode,
            embeddingLaneLimit: bgeEmbeddingLaneLimit,
            allowsModelHeavyWork: !pauseAll && bgeAllowsModelHeavyWork
        )
        // Only the foreground throttle may be borrowed through; power,
        // memory, thermal and the sibling memory guard still win (the same
        // reasons make a running preparation yield), and any interactive
        // generation lease keeps the model to itself.
        let heldPreparationStops: [ResourceThrottleReason] = [.workerMemoryGuard, .memoryWarning, .memoryCritical]
        let allowsArrivalReplyPreparation = !pauseAll && !interactiveGenerationActive
            && !heldPreparationStops.contains { reasons.contains($0) }
            && (allowsBackgroundGeneration || foregroundBorrowingAllowed)
        let qwenDecision = QwenResourceDecision(
            modelMode: qwenModelMode,
            allowsBackgroundTraining: allowsQwenTraining,
            allowsBackgroundGeneration: allowsBackgroundGeneration,
            allowsUserInitiatedWork: !pauseAll && qwenAllowsUserInitiatedWork,
            allowsArrivalReplyPreparation: allowsArrivalReplyPreparation
        )
        let baseBudget = ModelComputeBudget.resolved(
            maxAllowedPriority: maxPriority,
            shouldPauseAll: pauseAll,
            bge: bgeDecision,
            qwen: qwenDecision,
            activeClass: activeBudgetClass,
            forcedAllowedWorkClasses: forcedBudgetClasses,
            activeProcessorCount: activeProcessorCount,
            configuredBGELanes: maxEmbeddingLanes,
            throttleReason: budgetThrottleReason ?? reasons.last
        )
        let budget: ModelComputeBudget
        if allowsQwenTraining, !baseBudget.allows(.qwenTraining) {
            budget = ModelComputeBudget(
                activeClass: baseBudget.activeClass,
                allowedWorkClasses: baseBudget.allowedWorkClasses + [.qwenTraining],
                activeProcessorCount: baseBudget.activeProcessorCount,
                configuredBGELanes: baseBudget.configuredBGELanes,
                bgeLaneLimit: baseBudget.bgeLaneLimit,
                qwenAllowsGeneration: baseBudget.qwenAllowsGeneration,
                qwenAllowsTraining: true,
                throttleReason: baseBudget.throttleReason
            )
        } else {
            budget = baseBudget
        }

        return ResourceDecision(
            maxAllowedPriority: maxPriority,
            batchSizeMultiplier: batchMultiplier,
            indexBurstMultiplier: indexBurstMultiplier,
            interMessageDelayNanoseconds: interMessageDelayNanoseconds,
            backgroundTaskPriority: taskPriority,
            shouldPauseAll: pauseAll,
            isCatchUpModeActive: catchUpEligible,
            backgroundModelMode: bgeDecision.modelMode,
            bgeEmbeddingLaneLimit: bgeDecision.embeddingLaneLimit,
            allowsQwenTraining: allowsQwenTraining,
            allowsBackgroundGeneration: allowsBackgroundGeneration,
            requiresExclusiveModelResidency: requiresExclusiveModelResidency,
            throttleReasons: reasons,
            bge: bgeDecision,
            qwen: qwenDecision,
            modelComputeBudget: budget
        )
    }

    private static func effectiveMemoryPressure(
        _ state: ResourceState,
        workerRole: WorkerRole?
    ) -> MemoryPressureLevel {
        var level = state.memoryPressure
        guard let residentBytes = state.processResidentMemoryBytes,
              let physicalBytes = state.physicalMemoryBytes,
              physicalBytes > 0 else {
            return level
        }

        let budget = memoryBudget(for: workerRole, physicalBytes: physicalBytes)
        if residentBytes >= budget.criticalBytes {
            level = maxMemoryPressure(level, .critical)
        } else if residentBytes >= budget.warningBytes {
            level = maxMemoryPressure(level, .warning)
        }
        return level
    }

    private static func memoryBudget(
        for workerRole: WorkerRole?,
        physicalBytes: UInt64
    ) -> WorkerMemoryBudget {
        let physicalGB = Double(physicalBytes) / gibibyte
        let gb = gibibyte

        let warningGB: Double
        let criticalGB: Double
        switch workerRole {
        case .bge:
            if physicalGB <= 8 {
                warningGB = 1.5
                criticalGB = 2.25
            } else if physicalGB <= 16 {
                warningGB = 2.5
                criticalGB = 4.0
            } else if physicalGB <= 32 {
                warningGB = 4.0
                criticalGB = 6.0
            } else {
                warningGB = 6.0
                criticalGB = 9.0
            }
        case .qwen:
            if physicalGB <= 8 {
                warningGB = 2.5
                criticalGB = 3.5
            } else if physicalGB <= 16 {
                warningGB = 5.0
                criticalGB = 7.0
            } else if physicalGB <= 32 {
                warningGB = 10.0
                criticalGB = 14.0
            } else {
                warningGB = 18.0
                criticalGB = 26.0
            }
        case nil:
            warningGB = max(2.0, physicalGB * 0.45)
            criticalGB = max(3.0, physicalGB * 0.60)
        }

        return WorkerMemoryBudget(
            warningBytes: UInt64(warningGB * gb),
            criticalBytes: UInt64(criticalGB * gb)
        )
    }

    private static func shouldApplySiblingMemoryGuard(_ state: ResourceState) -> Bool {
        guard let physicalBytes = state.physicalMemoryBytes else { return false }
        return physicalBytes <= UInt64(16.0 * gibibyte)
    }

    private static func maxMemoryPressure(
        _ lhs: MemoryPressureLevel,
        _ rhs: MemoryPressureLevel
    ) -> MemoryPressureLevel {
        severity(lhs) >= severity(rhs) ? lhs : rhs
    }

    private static func severity(_ level: MemoryPressureLevel) -> Int {
        switch level {
        case .nominal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
