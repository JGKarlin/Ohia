// TrainingTrigger.swift
// Pure, testable decision function for the event-driven training lifecycle.
// Replaces the cadence-based TrainingPolicy (threshold / interval / scheduled
// time). Decides BOTH whether a `.train` job should be enqueued and which seed
// mode it carries; composes with ResourcePolicy, which decides whether the
// queue may CLAIM the resulting job now.
//
// Lifecycle (priority order, first match wins):
//   paused                         → .paused,           no job
//   engine cold                    → .waitingForModel,  no job
//   force-run requested            → .ready(.force), manual-full run
//   no promoted lineage, corpus still preparing → .preparingCorpus, no job
//   only deferred revisions        → .deferred, no job until they lapse
//   no pending revisions           → .noNewPairs, no job
//   no promoted lineage            → .ready(.backfill), initial-full run
//   promoted lineage + pending work → .ready(.incremental), incremental run

import Foundation
import OhiaCore

public enum SeedMode: Sendable, Equatable {
    case initialFull
    case incremental
    case manualFull
}

public struct TrainingTrigger: Sendable {
    public struct Decision: Sendable, Equatable {
        public let readiness: TrainingReadiness
        /// nil = don't enqueue a `.train` job this tick.
        public let seedMode: SeedMode?

        public init(readiness: TrainingReadiness, seedMode: SeedMode?) {
            self.readiness = readiness
            self.seedMode = seedMode
        }
    }

    public static func decide(
        isPaused: Bool,
        engineReady: Bool,
        forceRunRequested: Bool,
        hasPromotedLineage: Bool,
        lastRunAt: Date?,
        pendingTargetCount: Int,
        preparationRemaining: Int = 0,
        deferredTargetCount: Int = 0,
        deferredRetryAt: Date? = nil,
        now: Date = .now
    ) -> Decision {
        if isPaused { return .init(readiness: .paused, seedMode: nil) }
        guard engineReady else {
            return .init(readiness: .waitingForModel, seedMode: nil)
        }
        if forceRunRequested { return .init(readiness: .ready(.force), seedMode: .manualFull) }
        // The first full pass trains the whole prepared corpus together;
        // mail still being prepared would otherwise only ever reach the
        // adapter through short incremental passes.
        if !hasPromotedLineage, preparationRemaining > 0 {
            return .init(readiness: .preparingCorpus(ready: pendingTargetCount, remaining: preparationRemaining),
                         seedMode: nil)
        }
        guard pendingTargetCount > 0 else {
            if deferredTargetCount > 0, let deferredRetryAt {
                return .init(readiness: .deferred(pairs: deferredTargetCount, retryAt: deferredRetryAt), seedMode: nil)
            }
            return .init(readiness: .noNewPairs, seedMode: nil)
        }
        if !hasPromotedLineage {
            return .init(
                readiness: .ready(.backfill(pairs: pendingTargetCount)),
                seedMode: .initialFull
            )
        }
        return .init(
            readiness: .ready(.incremental(pairs: pendingTargetCount)),
            seedMode: .incremental
        )
    }
}
