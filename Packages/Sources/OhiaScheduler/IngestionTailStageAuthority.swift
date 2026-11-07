import Foundation
import OhiaCore

public enum IngestionTailStage: Sendable, Equatable {
    case membership
    case training
    case tagging
    case dreaming
    case complete
}

public enum IngestionTailStageAuthority {
    /// Longest the training stage may hold later tail work. Continuous voice
    /// training resumes an interrupted corpus run in short idle slices and can
    /// stay incomplete for weeks; past this limit tagging and Dreaming claim
    /// between training slices instead of waiting for the whole run.
    public static let trainingHoldLimit: TimeInterval = 60 * 60

    /// How long released tagging may keep the generative worker from starting
    /// a training slice without completing a resolution. The retrieval worker
    /// claims tagging within seconds of the Qwen worker going idle, and each
    /// resolution takes about a second; a longer stall means tagging cannot
    /// run now, so training resumes rather than waiting on it. While tagging
    /// makes no progress, at most one such window opens per `trainingHoldLimit`.
    public static let taggingDrainWindow: TimeInterval = 60

    /// How long Train Now owns training exclusively, from the request or from
    /// planning its manual full run. Afterwards that training takes turns
    /// with released tagging and Dreaming like any other run.
    public static let trainNowExclusiveWindow: TimeInterval = 60 * 60

    public struct Evidence: Sendable, Equatable {
        public let membershipRequired: Bool
        public let trainingRequired: Bool
        public let taggingRequired: Bool
        public let dreamingRequired: Bool
        /// When the oldest outstanding tagging work was created.
        public let taggingHeldSince: Date?
        /// When Dreaming last finished a full pass, or, never having finished
        /// one, when its accounts became ready to dream.
        public let dreamingHeldSince: Date?

        public init(
            membershipRequired: Bool,
            trainingRequired: Bool,
            taggingRequired: Bool,
            dreamingRequired: Bool,
            taggingHeldSince: Date? = nil,
            dreamingHeldSince: Date? = nil
        ) {
            self.membershipRequired = membershipRequired
            self.trainingRequired = trainingRequired
            self.taggingRequired = taggingRequired
            self.dreamingRequired = dreamingRequired
            self.taggingHeldSince = taggingHeldSince
            self.dreamingHeldSince = dreamingHeldSince
        }
    }

    /// The strict stage plus the later stages that have outwaited training's
    /// bounded hold.
    public struct Decision: Sendable, Equatable {
        public let stage: IngestionTailStage
        /// Tagging claims beside training on the retrieval worker.
        public let releasesTagging: Bool
        /// Dreaming claims between training slices on the generative worker.
        public let releasesDreaming: Bool

        public var blockedJobTypes: Set<JobType> {
            var blocked = IngestionTailStageAuthority.blockedJobTypes(for: stage)
            if releasesTagging { blocked.remove(.resolveSemanticTags) }
            if releasesDreaming { blocked.remove(.accountMemoryRefresh) }
            return blocked
        }
    }

    public static func stage(for evidence: Evidence) -> IngestionTailStage {
        if evidence.membershipRequired { return .membership }
        if evidence.trainingRequired { return .training }
        if evidence.taggingRequired { return .tagging }
        if evidence.dreamingRequired { return .dreaming }
        return .complete
    }

    /// Membership and tagging remain strict barriers. Training is bounded:
    /// once tagging or Dreaming work has waited `trainingHoldLimit` behind it,
    /// that stage is released. Dreaming still waits for tagging to drain, and
    /// an earlier stage is never held longer than a later stage already
    /// released, so Dreaming's expired hold releases new tagging too.
    public static func decision(for evidence: Evidence, now: Date) -> Decision {
        let stage = stage(for: evidence)
        guard stage == .training else {
            return Decision(stage: stage, releasesTagging: false, releasesDreaming: false)
        }
        let dreamingHoldExpired = holdHasExpired(since: evidence.dreamingHeldSince, now: now)
        return Decision(
            stage: stage,
            releasesTagging: evidence.taggingRequired
                && (holdHasExpired(since: evidence.taggingHeldSince, now: now)
                    || dreamingHoldExpired),
            releasesDreaming: !evidence.taggingRequired && dreamingHoldExpired
        )
    }

    /// The released stage a new training slice waits behind. A running slice
    /// is never preempted; this governs only whether the next one starts.
    public enum TrainingDeferral: Sendable, Equatable {
        /// Released tagging drains between slices. The retrieval worker cannot
        /// claim it while a Qwen job keeps its sibling active.
        case tagging
        /// Released Dreaming takes every other turn between slices.
        case dreaming

        /// Training wait reason, in the vocabulary of the other wait reasons.
        public var waitReason: String {
            switch self {
            case .tagging: "tagging"
            case .dreaming: "dreaming"
            }
        }
    }

    /// Durable queue evidence for `trainingDeferral`. Turn ends are terminal
    /// job completions, failed ones included; a tagging completion counts
    /// only when it succeeded.
    public struct DeferralEvidence: Sendable, Equatable {
        /// Train Now still inside `trainNowExclusiveWindow`.
        public let trainNowExclusive: Bool
        /// A resolution job the retrieval worker can claim now is pending, or
        /// one is running.
        public let taggingRunnable: Bool
        /// A Dreaming job the generative worker can claim this turn is pending.
        public let dreamingClaimable: Bool
        public let lastTrainingTurnEndedAt: Date?
        public let lastTaggingCompletedAt: Date?
        public let lastDreamingTurnEndedAt: Date?
        /// When any job of the generative worker last finished. While that
        /// worker runs other work, the retrieval worker stays throttled below
        /// tagging, so a window spent busy is no evidence tagging cannot run.
        public let lastGenerativeJobEndedAt: Date?

        public init(
            trainNowExclusive: Bool,
            taggingRunnable: Bool,
            dreamingClaimable: Bool,
            lastTrainingTurnEndedAt: Date?,
            lastTaggingCompletedAt: Date?,
            lastDreamingTurnEndedAt: Date?,
            lastGenerativeJobEndedAt: Date? = nil
        ) {
            self.trainNowExclusive = trainNowExclusive
            self.taggingRunnable = taggingRunnable
            self.dreamingClaimable = dreamingClaimable
            self.lastTrainingTurnEndedAt = lastTrainingTurnEndedAt
            self.lastTaggingCompletedAt = lastTaggingCompletedAt
            self.lastDreamingTurnEndedAt = lastDreamingTurnEndedAt
            self.lastGenerativeJobEndedAt = lastGenerativeJobEndedAt
        }
    }

    /// The generative worker's record of tagging drain windows, kept for the
    /// life of the process. A restart forgets it and costs at most one window.
    public struct TaggingWindowLedger: Sendable, Equatable {
        /// The Qwen turn end the open drain window started from.
        public var openedAt: Date?
        /// The start of the last window that closed without a resolution.
        public var lapsedAt: Date?

        public init(openedAt: Date? = nil, lapsedAt: Date? = nil) {
            self.openedAt = openedAt
            self.lapsedAt = lapsedAt
        }
    }

    /// Whether Train Now still owns training exclusively.
    public static func trainNowIsExclusive(
        requestedAt: Date?,
        manualRunPlannedAt: Date?,
        now: Date
    ) -> Bool {
        isRecent(requestedAt, within: trainNowExclusiveWindow, now: now)
            || isRecent(manualRunPlannedAt, within: trainNowExclusiveWindow, now: now)
    }

    /// Train Now wins inside its exclusive window. Released tagging drains
    /// fully before the next slice: it gets `taggingDrainWindow` after the
    /// generative worker's last turn ends, and each resolution extends it. A
    /// window that closes without a resolution while the generative worker
    /// stayed idle is a lapse; until tagging next progresses, only one window
    /// opens per `trainingHoldLimit`. Released Dreaming strictly alternates
    /// with training: it takes the turn only when training had the last one.
    /// A timestamp after `now`, ledger entries included, is stale and ignored.
    public static func trainingDeferral(
        decision: Decision,
        evidence: DeferralEvidence,
        ledger: inout TaggingWindowLedger,
        now: Date
    ) -> TrainingDeferral? {
        guard !evidence.trainNowExclusive else { return nil }
        ledger.openedAt = current(ledger.openedAt, now: now)
        ledger.lapsedAt = current(ledger.lapsedAt, now: now)
        let lastTrainingTurnEndedAt = current(evidence.lastTrainingTurnEndedAt, now: now)
        let lastDreamingTurnEndedAt = current(evidence.lastDreamingTurnEndedAt, now: now)
        let lastTaggingCompletedAt = current(evidence.lastTaggingCompletedAt, now: now)
        let lastGenerativeJobEndedAt = current(evidence.lastGenerativeJobEndedAt, now: now)

        if decision.releasesTagging, evidence.taggingRunnable {
            if isRecent(lastTaggingCompletedAt, within: taggingDrainWindow, now: now) {
                return .tagging
            }
            let lastTurnEndedAt = [lastTrainingTurnEndedAt, lastDreamingTurnEndedAt]
                .compactMap { $0 }
                .max()
            if let lastTurnEndedAt,
               isRecent(lastTurnEndedAt, within: taggingDrainWindow, now: now),
               ledger.openedAt == lastTurnEndedAt
                || taggingWindowMayOpen(
                    after: lastTurnEndedAt,
                    lastTaggingCompletedAt: lastTaggingCompletedAt,
                    lapsedAt: ledger.lapsedAt
                ) {
                ledger.openedAt = lastTurnEndedAt
                return .tagging
            }
            if let openedAt = ledger.openedAt,
               (lastTaggingCompletedAt ?? .distantPast) < openedAt,
               (lastGenerativeJobEndedAt ?? .distantPast) <= openedAt {
                ledger.lapsedAt = openedAt
            }
        }
        ledger.openedAt = nil

        if decision.releasesDreaming,
           evidence.dreamingClaimable,
           let lastTrainingTurnEndedAt,
           lastTrainingTurnEndedAt > (lastDreamingTurnEndedAt ?? .distantPast) {
            return .dreaming
        }
        return nil
    }

    private static func taggingWindowMayOpen(
        after turnEndedAt: Date,
        lastTaggingCompletedAt: Date?,
        lapsedAt: Date?
    ) -> Bool {
        guard let lapsedAt else { return true }
        if let lastTaggingCompletedAt, lastTaggingCompletedAt > lapsedAt { return true }
        return turnEndedAt.timeIntervalSince(lapsedAt) >= trainingHoldLimit
    }

    private static func isRecent(_ date: Date?, within window: TimeInterval, now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < window
    }

    private static func current(_ date: Date?, now: Date) -> Date? {
        guard let date, date <= now else { return nil }
        return date
    }

    public static func blockedJobTypes(for stage: IngestionTailStage) -> Set<JobType> {
        switch stage {
        case .membership:
            return [.buildTrainingPairs, .train, .resolveSemanticTags, .accountMemoryRefresh]
        case .training:
            return [.resolveSemanticTags, .accountMemoryRefresh]
        case .tagging:
            return [.accountMemoryRefresh]
        case .dreaming, .complete:
            return []
        }
    }

    /// Whether work waiting since `since` has outwaited training's hold.
    public static func holdHasExpired(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= trainingHoldLimit
    }
}
