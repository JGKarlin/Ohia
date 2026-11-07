// TrainingRunState.swift
// Singleton row holding user-tunable training controls + last-run metadata.
// Use `current(context:)` — never construct this directly in production code
// (it's public only so tests can simulate corrupt state).

import Foundation
import SwiftData

@Model
public final class TrainingRunState {
    public static let automaticIdleMinutesThreshold = 1

    public var id: UUID

    /// Minutes of system idle before training escalates from cooperative
    /// background execution to full speed. Foreground activity still pauses
    /// training until this threshold is met. Optional so SwiftData lightweight
    /// migration can add it without a default-value rider.
    public var idleMinutesThreshold: Int?

    // User controls.
    public var isPaused: Bool
    public var forceRunRequested: Bool
    /// When Train Now was last requested. Train Now owns training exclusively
    /// for a bounded window from this moment, so it outlives the consumed
    /// `forceRunRequested` flag; a request without it is past that window.
    /// Optional so lightweight migration adds it.
    public var forceRunRequestedAt: Date?
    /// Legacy persisted fast-lane toggle. Catch-up now engages automatically
    /// when resource policy says the machine is healthy and Ohia is not active,
    /// but the optional column remains for older stores.
    public var pipelineCatchUpEnabled: Bool?

    // Last-run read-only surface. Written only by TrainingOrchestrator.
    public var lastRunAt: Date?
    public var lastLoss: Double?
    public var lastDurationSeconds: Double?
    public var lastPairsUsed: Int?
    public var lastStepCount: Int
    public var lastError: String?

    /// Held-out loss of the base model (no adapter) on the validation set
    /// named by `baseValidationFingerprint` (model, profile, and the exact
    /// holdout revisions). The base never changes for a fixed set, so epoch
    /// judgments reuse it instead of evaluating the base again.
    public var baseValidationLoss: Double?
    public var baseValidationFingerprint: String?

    /// The base model's drafts of the checkpoint quality probes (encoded
    /// probe array), named by `baseQualityFingerprint` (the exact probe
    /// prompts, token budget, and base model). Sampling is deterministic, so
    /// every candidate's quality check reuses them and drafts only its own.
    public var baseQualityProbesJSON: String?
    public var baseQualityFingerprint: String?

    public init() {
        self.id = UUID()
        self.idleMinutesThreshold = Self.automaticIdleMinutesThreshold
        self.isPaused = false
        self.forceRunRequested = false
        self.forceRunRequestedAt = nil
        self.pipelineCatchUpEnabled = false
        self.lastRunAt = nil
        self.lastLoss = nil
        self.lastDurationSeconds = nil
        self.lastPairsUsed = nil
        self.lastStepCount = 0
        self.lastError = nil
    }

    /// Fetch the singleton row, creating one if absent. If multiple rows exist
    /// (corruption / racy first-run code elsewhere), keeps the first and
    /// deletes the rest — idempotent repair.
    @MainActor
    public static func current(context: ModelContext) -> TrainingRunState {
        do {
            let all = try context.fetch(FetchDescriptor<TrainingRunState>())
            if let first = all.first {
                var needsSave = false
                // One minute is the automatic policy rather than a user-
                // configurable preference. Normalize this singleton at its
                // authoritative access seam; no historical-row walk is needed.
                if first.idleMinutesThreshold != Self.automaticIdleMinutesThreshold {
                    first.idleMinutesThreshold = Self.automaticIdleMinutesThreshold
                    needsSave = true
                }
                if all.count > 1 {
                    for extra in all.dropFirst() {
                        context.delete(extra)
                    }
                    needsSave = true
                }
                if needsSave {
                    try? context.save()
                }
                return first
            }
        } catch {
            // Fall through and create a new row.
        }
        let fresh = TrainingRunState()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
