import Foundation
import OhiaCore

nonisolated struct CompletionDataMutation: Equatable {
    var hasIndex = false
    var requiresImmediateMetalRefresh = false
    var refreshesNonMetalLenses = false
    var updateColorLookup = false
    var resolveTimelineRollingWindow = false
    var includesLiveInbound = false
    var affectsFrontPageProjectDefinitions = false
}

nonisolated struct CompletionFrontPageRefreshPolicy: Equatable {
    let preservingProjectDefinitions: Bool
    let deferringIfRefreshInFlight: Bool
}

nonisolated struct CompletionRefreshIntent: Equatable {
    var dataMutation: CompletionDataMutation?
    var summary = false
    var affectsFrontPageProjectDefinitions = false
    var bypassesPlacementGate = false

    var isEmpty: Bool {
        dataMutation == nil && !summary
    }

    mutating func merge(_ type: JobType) {
        switch type {
        case .index:
            mergeData(
                hasIndex: true,
                immediate: false,
                refreshesNonMetalLenses: false,
                rolling: true,
                liveInbound: false,
                affectsProjectDefinitions: false
            )
        case .imapPollFolder, .ingest:
            mergeData(
                hasIndex: false,
                immediate: true,
                refreshesNonMetalLenses: true,
                rolling: true,
                liveInbound: false,
                affectsProjectDefinitions: true
            )
        case .triage:
            mergeData(
                hasIndex: false,
                immediate: true,
                refreshesNonMetalLenses: true,
                rolling: false,
                liveInbound: false,
                affectsProjectDefinitions: true
            )
        case .embed:
            mergeData(
                hasIndex: false,
                immediate: true,
                refreshesNonMetalLenses: false,
                rolling: false,
                liveInbound: false,
                affectsProjectDefinitions: false
            )
        case .imapLiveInbound:
            mergeData(
                hasIndex: false,
                immediate: true,
                refreshesNonMetalLenses: true,
                rolling: true,
                liveInbound: true,
                affectsProjectDefinitions: true
            )
        case .summarize:
            // `.summarize` is the generic Qwen interpretation/datafication
            // lane. It can rewrite classification, triage, deadlines,
            // categories, and semantic project membership.
            summary = true
            affectsFrontPageProjectDefinitions = true
        case .summarizeAttachments:
            summary = true
        default:
            break
        }
    }

    /// Exact mutation metadata lets the UI patch changed message summaries
    /// immediately while batching their slower project-affinity reconciliation.
    /// Interpretation and visibility changes retain their conservative refreshes.
    mutating func merge(_ event: JobCompletionEvent) {
        if let mutations = event.messageMutations {
            let facets = mutations.reduce(into: Set<PipelineMessageFacet>()) {
                $0.formUnion($1.facets)
            }
            if facets.contains(.visibility) {
                bypassesPlacementGate = true
                mergeData(
                    hasIndex: false,
                    immediate: true,
                    refreshesNonMetalLenses: true,
                    rolling: false,
                    liveInbound: false,
                    affectsProjectDefinitions: true
                )
            }
        }
        guard event.type == .summarize else {
            merge(event.type)
            return
        }
        guard let mutations = event.messageMutations else {
            merge(.summarize)
            return
        }

        let facets = mutations.reduce(into: Set<PipelineMessageFacet>()) {
            $0.formUnion($1.facets)
        }
        if facets.contains(.visibility) {
            mergeData(
                hasIndex: false,
                immediate: true,
                refreshesNonMetalLenses: true,
                rolling: false,
                liveInbound: false,
                affectsProjectDefinitions: true
            )
        }
        if facets.contains(.interpretation) {
            summary = true
            affectsFrontPageProjectDefinitions = true
        }
        if facets.contains(.summary) {
            summary = true
            affectsFrontPageProjectDefinitions = true
        }
    }

    mutating func merge(_ other: CompletionRefreshIntent) {
        if let otherData = other.dataMutation {
            var data = dataMutation ?? CompletionDataMutation()
            data.hasIndex = data.hasIndex || otherData.hasIndex
            data.requiresImmediateMetalRefresh =
                data.requiresImmediateMetalRefresh
                || otherData.requiresImmediateMetalRefresh
            data.refreshesNonMetalLenses =
                data.refreshesNonMetalLenses
                || otherData.refreshesNonMetalLenses
            data.updateColorLookup =
                data.updateColorLookup || otherData.updateColorLookup
            data.resolveTimelineRollingWindow =
                data.resolveTimelineRollingWindow
                || otherData.resolveTimelineRollingWindow
            data.includesLiveInbound =
                data.includesLiveInbound || otherData.includesLiveInbound
            data.affectsFrontPageProjectDefinitions =
                data.affectsFrontPageProjectDefinitions
                || otherData.affectsFrontPageProjectDefinitions
            dataMutation = data
        }
        summary = summary || other.summary
        affectsFrontPageProjectDefinitions =
            affectsFrontPageProjectDefinitions
            || other.affectsFrontPageProjectDefinitions
        bypassesPlacementGate =
            bypassesPlacementGate || other.bypassesPlacementGate
    }

    func resolve(
        refreshesOnNewPlacements: Bool,
        onboarding: Bool
    ) -> ResolvedCompletionRefresh {
        let resolvedData = refreshesOnNewPlacements
            || onboarding
            || bypassesPlacementGate
            ? dataMutation
            : nil
        return ResolvedCompletionRefresh(
            dataMutation: resolvedData,
            summary: summary,
            affectsFrontPageProjectDefinitions:
                affectsFrontPageProjectDefinitions
        )
    }

    private mutating func mergeData(
        hasIndex: Bool,
        immediate: Bool,
        refreshesNonMetalLenses: Bool,
        rolling: Bool,
        liveInbound: Bool,
        affectsProjectDefinitions: Bool
    ) {
        var data = dataMutation ?? CompletionDataMutation()
        data.hasIndex = data.hasIndex || hasIndex
        data.requiresImmediateMetalRefresh =
            data.requiresImmediateMetalRefresh || immediate
        data.refreshesNonMetalLenses =
            data.refreshesNonMetalLenses || refreshesNonMetalLenses
        data.updateColorLookup = true
        data.resolveTimelineRollingWindow =
            data.resolveTimelineRollingWindow || rolling
        data.includesLiveInbound = data.includesLiveInbound || liveInbound
        data.affectsFrontPageProjectDefinitions =
            data.affectsFrontPageProjectDefinitions
            || affectsProjectDefinitions
        dataMutation = data
    }
}

nonisolated struct ResolvedCompletionRefresh: Equatable {
    let dataMutation: CompletionDataMutation?
    let summary: Bool
    let affectsFrontPageProjectDefinitions: Bool

    var hasWork: Bool {
        dataMutation != nil || summary
    }

    var invalidateInactiveLenses: Bool {
        dataMutation?.refreshesNonMetalLenses == true || summary
    }

    var frontPageRefreshPolicy: CompletionFrontPageRefreshPolicy {
        CompletionFrontPageRefreshPolicy(
            preservingProjectDefinitions:
                dataMutation?.affectsFrontPageProjectDefinitions != true
                && !affectsFrontPageProjectDefinitions,
            deferringIfRefreshInFlight:
                dataMutation?.includesLiveInbound != true
        )
    }
}

nonisolated enum CompletionRefreshDisposition: Equatable {
    case immediateExact
    case accumulate(flushDelay: Duration)
    case ignore

    static func classify(_ type: JobType) -> Self {
        switch type {
        case .frameBurst, .clusterDetect:
            return .immediateExact
        case .imapLiveInbound:
            return .accumulate(flushDelay: .zero)
        case .index, .imapPollFolder, .ingest, .triage, .embed,
             .summarize, .summarizeAttachments:
            return .accumulate(flushDelay: .milliseconds(50))
        default:
            return .ignore
        }
    }

    static func classify(_ event: JobCompletionEvent) -> Self {
        if let mutations = event.messageMutations {
            let facets = mutations.reduce(into: Set<PipelineMessageFacet>()) {
                $0.formUnion($1.facets)
            }
            if facets.contains(.visibility) {
                return .accumulate(flushDelay: .milliseconds(50))
            }
        }
        switch event.type {
        case .summarize:
            guard let mutations = event.messageMutations else {
                return .accumulate(flushDelay: .milliseconds(50))
            }
            let facets = mutations.reduce(into: Set<PipelineMessageFacet>()) {
                $0.formUnion($1.facets)
            }
            if facets.contains(.visibility) {
                return .accumulate(flushDelay: .milliseconds(50))
            }
            if facets.contains(.interpretation) || facets.contains(.summary) {
                // Fixed cadence from the first pending structural mutation. It
                // is deliberately not a trailing debounce, so a continuously
                // datafying mailbox still converges every two minutes.
                return .accumulate(flushDelay: .seconds(120))
            }
            return .ignore
        case .summarizeAttachments, .embed, .triage, .ingest, .index:
            // Attachment summaries are reader-local, embed has no visible
            // placement yet, triage/ingest are legacy no-ops, and Metal's
            // placement observer already catches index revisions once/sec.
            return .ignore
        case .imapPollFolder:
            return .accumulate(flushDelay: .milliseconds(250))
        default:
            return classify(event.type)
        }
    }
}

nonisolated enum CompletionMessageSummaryRefresh {
    static func messageIDs(in event: JobCompletionEvent) -> Set<UUID> {
        guard event.type == .summarize,
              let mutations = event.messageMutations else {
            return []
        }
        return mutations.reduce(into: Set<UUID>()) { ids, mutation in
            guard mutation.facets.contains(.summary) else { return }
            ids.formUnion(mutation.messageIDs)
        }
    }
}

/// Exact IDs whose mailbox mutation has completed its local destructive
/// finalization. These need transient reader/lock teardown in addition to the
/// generic lens refresh, because those caches intentionally outlive snapshots.
nonisolated enum CompletionMailboxVisibilityRefresh {
    static func messageIDs(in event: JobCompletionEvent) -> Set<UUID> {
        guard event.type == .mailboxMutation
                || event.type == .imapDeletionWatch
                || event.type == .pendingDeletionReaper,
              let mutations = event.messageMutations else {
            return []
        }
        return mutations.reduce(into: Set<UUID>()) { ids, mutation in
            guard mutation.facets.contains(.visibility) else { return }
            ids.formUnion(mutation.messageIDs)
        }
    }
}

/// Exact server-reconciled deletions bridged from the BGE worker process.
/// These retire arrival accounting even while the Constellation window is
/// closed; app-originated mailbox mutations already retire synchronously.
nonisolated enum CompletionRemoteDeletionRetirement {
    static func messageIDs(in event: JobCompletionEvent) -> Set<String> {
        guard event.type == .imapDeletionWatch
                || event.type == .pendingDeletionReaper,
              let mutations = event.messageMutations else {
            return []
        }
        return mutations.reduce(into: Set<String>()) { ids, mutation in
            guard mutation.facets.contains(.visibility) else { return }
            ids.formUnion(mutation.messageIDs.map(\.uuidString))
        }
    }
}

nonisolated enum CompletionRefreshAction: Equatable {
    case none
    case schedule(after: Duration)
    case reschedule(after: Duration)
    case cancelScheduleAndFlush
    case flush
}

nonisolated struct CompletionRefreshAccumulator {
    private(set) var pending = CompletionRefreshIntent()
    private(set) var isScheduled = false
    private(set) var scheduledDelay: Duration?
    private(set) var isFlushing = false
    private(set) var isCancelled = false

    mutating func enqueue(
        _ intent: CompletionRefreshIntent,
        flushDelay: Duration
    ) -> CompletionRefreshAction {
        guard !isCancelled, !intent.isEmpty else { return .none }
        pending.merge(intent)
        guard !isFlushing else { return .none }
        if flushDelay <= .zero {
            if isScheduled {
                isScheduled = false
                scheduledDelay = nil
                return .cancelScheduleAndFlush
            }
            return .flush
        }
        if isScheduled {
            guard let scheduledDelay,
                  flushDelay < scheduledDelay else { return .none }
            self.scheduledDelay = flushDelay
            return .reschedule(after: flushDelay)
        }
        isScheduled = true
        scheduledDelay = flushDelay
        return .schedule(after: flushDelay)
    }

    mutating func scheduledFlushFired()
        -> (CompletionRefreshAction, CompletionRefreshIntent?)
    {
        guard !isCancelled, isScheduled else { return (.none, nil) }
        isScheduled = false
        scheduledDelay = nil
        return beginFlush()
    }

    mutating func beginImmediateFlush()
        -> (CompletionRefreshAction, CompletionRefreshIntent?)
    {
        guard !isCancelled, !isFlushing else { return (.none, nil) }
        isScheduled = false
        scheduledDelay = nil
        return beginFlush()
    }

    mutating func finishFlush()
        -> (CompletionRefreshAction, CompletionRefreshIntent?)
    {
        guard isFlushing else { return (.none, nil) }
        isFlushing = false
        guard !pending.isEmpty, !isCancelled else { return (.none, nil) }
        return beginFlush()
    }

    mutating func cancel() {
        isCancelled = true
        isScheduled = false
        scheduledDelay = nil
        isFlushing = false
        pending = CompletionRefreshIntent()
    }

    mutating func discardScheduledFlush() {
        guard isScheduled, !isFlushing else { return }
        isScheduled = false
        scheduledDelay = nil
        pending = CompletionRefreshIntent()
    }

    private mutating func beginFlush()
        -> (CompletionRefreshAction, CompletionRefreshIntent?)
    {
        guard !pending.isEmpty else { return (.none, nil) }
        let intent = pending
        pending = CompletionRefreshIntent()
        isFlushing = true
        return (.flush, intent)
    }
}

/// Owns the one delayed or active completion-refresh task without
/// participating in SwiftUI observation. The view supplies the concrete flush
/// operation so lens, frame, onboarding, and time-range decisions stay live at
/// execution time.
@MainActor
final class CompletionRefreshCoordinator {
    typealias Wait = @MainActor (Duration) async throws -> Void
    typealias Flush = @MainActor (CompletionRefreshIntent) async -> Void

    private var accumulator = CompletionRefreshAccumulator()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var taskRevision: UInt64 = 0
    private let wait: Wait

    init(
        wait: @escaping Wait = { delay in
            try await Task.sleep(for: max(.zero, delay))
        }
    ) {
        self.wait = wait
    }

    func reset() {
        generation &+= 1
        taskRevision &+= 1
        task?.cancel()
        task = nil
        accumulator = CompletionRefreshAccumulator()
    }

    func cancel() {
        generation &+= 1
        taskRevision &+= 1
        accumulator.cancel()
        task?.cancel()
        task = nil
    }

    func enqueue(
        _ intent: CompletionRefreshIntent,
        flushDelay: Duration,
        flush: @escaping Flush
    ) {
        let action = accumulator.enqueue(
            intent,
            flushDelay: flushDelay
        )
        perform(action, flush: flush)
    }

    private func perform(
        _ action: CompletionRefreshAction,
        flush: @escaping Flush
    ) {
        switch action {
        case .none:
            return
        case .schedule(let delay):
            schedule(after: delay, flush: flush)
        case .reschedule(let delay):
            task?.cancel()
            task = nil
            schedule(after: delay, flush: flush)
        case .cancelScheduleAndFlush:
            task?.cancel()
            task = nil
            beginImmediateFlush(flush: flush)
        case .flush:
            beginImmediateFlush(flush: flush)
        }
    }

    private func schedule(
        after delay: Duration,
        flush: @escaping Flush
    ) {
        guard task == nil else { return }
        let generation = generation
        let revision = nextTaskRevision()
        let wait = wait

        task = Task { @MainActor [weak self, wait] in
            do {
                try await wait(delay)
            } catch {
                guard let self,
                      self.isCurrent(
                        generation: generation,
                        revision: revision
                      ) else {
                    return
                }
                self.accumulator.discardScheduledFlush()
                self.clearTaskIfCurrent(
                    generation: generation,
                    revision: revision
                )
                return
            }
            guard let self,
                  self.isCurrent(
                    generation: generation,
                    revision: revision
                  ),
                  !Task.isCancelled else {
                return
            }

            let (action, intent) =
                self.accumulator.scheduledFlushFired()
            guard action == .flush, let intent else {
                self.clearTaskIfCurrent(
                    generation: generation,
                    revision: revision
                )
                return
            }
            await self.runFlushes(
                startingWith: intent,
                generation: generation,
                revision: revision,
                flush: flush
            )
        }
    }

    private func beginImmediateFlush(
        flush: @escaping Flush
    ) {
        guard task == nil else { return }
        let (action, intent) = accumulator.beginImmediateFlush()
        guard action == .flush, let intent else { return }

        let generation = generation
        let revision = nextTaskRevision()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFlushes(
                startingWith: intent,
                generation: generation,
                revision: revision,
                flush: flush
            )
        }
    }

    private func runFlushes(
        startingWith firstIntent: CompletionRefreshIntent,
        generation: UInt64,
        revision: UInt64,
        flush: @escaping Flush
    ) async {
        var intent: CompletionRefreshIntent? = firstIntent
        while let currentIntent = intent {
            guard isCurrent(
                generation: generation,
                revision: revision
            ), !Task.isCancelled else {
                return
            }

            await flush(currentIntent)

            guard isCurrent(
                generation: generation,
                revision: revision
            ), !Task.isCancelled else {
                return
            }

            let (action, trailingIntent) = accumulator.finishFlush()
            guard action == .flush else {
                clearTaskIfCurrent(
                    generation: generation,
                    revision: revision
                )
                return
            }
            intent = trailingIntent
        }

        clearTaskIfCurrent(
            generation: generation,
            revision: revision
        )
    }

    private func nextTaskRevision() -> UInt64 {
        taskRevision &+= 1
        return taskRevision
    }

    private func isCurrent(
        generation candidateGeneration: UInt64,
        revision candidateRevision: UInt64
    ) -> Bool {
        candidateGeneration == generation
            && candidateRevision == taskRevision
    }

    private func clearTaskIfCurrent(
        generation candidateGeneration: UInt64,
        revision candidateRevision: UInt64
    ) {
        guard isCurrent(
            generation: candidateGeneration,
            revision: candidateRevision
        ) else {
            return
        }
        task = nil
    }
}
