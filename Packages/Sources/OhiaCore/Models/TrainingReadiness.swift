// TrainingReadiness.swift
// Event-shaped status describing why training is (or is not) eligible right
// now. Replaces the cadence-shaped TrainingPolicy.Decision mirror that the
// worker-status IPC snapshot used to carry. Plain data enum — no behavior.
//
// Shared directly by TrainingStatusPublisher (OhiaML) and the worker-status
// IPC snapshot (WorkerTrainingStatusSnapshot.nextEligibleReason). Both the app
// and worker processes are the same build, so the Codable shape is an
// ephemeral DTO, not durable data.

import Foundation

/// Message-scoped progress for the sent-evidence corpus. One
/// `SentTrainingEvidence` row represents one outgoing message even when its
/// preparation produces multiple optimizer pairs.
public struct TrainingCandidateCorpusProgress: Codable, Equatable, Sendable {
    public let discoveredMessageCount: Int
    public let assessedMessageCount: Int
    public let eligibleMessageCount: Int
    public let trainedMessageCount: Int

    public init(
        discoveredMessageCount: Int,
        assessedMessageCount: Int,
        eligibleMessageCount: Int,
        trainedMessageCount: Int
    ) {
        self.discoveredMessageCount = discoveredMessageCount
        self.assessedMessageCount = assessedMessageCount
        self.eligibleMessageCount = eligibleMessageCount
        self.trainedMessageCount = trainedMessageCount
    }

    public static let empty = TrainingCandidateCorpusProgress(
        discoveredMessageCount: 0,
        assessedMessageCount: 0,
        eligibleMessageCount: 0,
        trainedMessageCount: 0
    )

    public var isAssessmentComplete: Bool {
        assessedMessageCount >= discoveredMessageCount
    }
}

public enum TrainingReadiness: Codable, Equatable, Sendable {
    /// User paused training in Settings. Dominant over everything else.
    case paused
    /// The personalization engine is still loading its model weights.
    case waitingForModel
    /// Caught up — no unused pairs to train on.
    case noNewPairs
    /// A small incremental backlog is waiting for either the target batch size
    /// or its daily fallback time. This is not an ingestion/resource wait.
    case accumulating(pairs: Int, target: Int, eligibleAt: Date)
    /// The first full pass waits until the sent-mail corpus is prepared, so
    /// every prepared email trains together in full passes.
    case preparingCorpus(ready: Int, remaining: Int)
    /// Every untrained revision is deferred: the pass that last trained on it
    /// did not improve the voice. It is retried from `retryAt`.
    case deferred(pairs: Int, retryAt: Date)
    /// Eligible to enqueue a `.train` job; `ReadyKind` carries the seed shape.
    case ready(ReadyKind)

    public enum ReadyKind: Codable, Equatable, Sendable {
        /// First run ever (or a forced full retrain): full-corpus pass.
        case backfill(pairs: Int)
        /// Subsequent unused pairs (sends / re-ingestion): short incremental pass.
        case incremental(pairs: Int)
        /// User pressed Train Now → forced backfill pass.
        case force
    }
}
