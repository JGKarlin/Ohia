// Packages/Sources/OhiaML/Training/TrainingSignal.swift
import Foundation

public enum SignalType: String, Codable, Sendable {
    case toneShift
    case contentAdded
    case contentRemoved
    case rewrite
    case sourceOverride
}

public struct TrainingSignal: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let type: SignalType
    public let description: String
    public let originalSpan: String?
    public let editedSpan: String?
    public let correspondentEmail: String
    public let weight: Double

    public init(
        id: UUID = UUID(),
        type: SignalType,
        description: String,
        originalSpan: String? = nil,
        editedSpan: String? = nil,
        correspondentEmail: String,
        weight: Double = 1.0
    ) {
        self.id = id
        self.type = type
        self.description = description
        self.originalSpan = originalSpan
        self.editedSpan = editedSpan
        self.correspondentEmail = correspondentEmail
        self.weight = weight
    }
}

public extension TrainingSignal {
    /// Combines a caller-supplied baseline (which encodes *why* the pair
    /// exists — a fully user-authored reply vs. an edited model draft) with
    /// the magnitude of the detected edit signals, so a single word swap and
    /// a five-line rewrite plus a rejected citation no longer train the
    /// adapter with identical influence.
    ///
    /// Each signal's own `weight` already encodes its individual strength
    /// (`HeuristicEditAnalyzer` scales tone shifts by formality delta and
    /// weights a rejected citation highest); the average of those is scaled
    /// by the square root — not a raw sum — of the signal count, so a long
    /// diff of many small line changes doesn't linearly run away. `cap`
    /// bounds the result: on the low-RAM runtime tier
    /// (`MLXTrainingEngine.runtimeMemoryConfiguration`'s `maximumTrainingBatchSize
    /// == 1`), this weight is an absolute per-token loss multiplier with no
    /// gradient clipping downstream, so a single outlier pair must not be
    /// able to dominate a training step far more than the previous flat
    /// baseline (max 3.0) did. Falls back to the (still capped) baseline
    /// unscaled when there are no signals to score against.
    static func magnitudeWeight(
        for signals: [TrainingSignal],
        baseline: Double,
        cap: Double = 6.0
    ) -> Double {
        guard !signals.isEmpty else { return min(baseline, cap) }
        let averageWeight = signals.reduce(0.0) { $0 + $1.weight } / Double(signals.count)
        let magnitude = averageWeight * Double(signals.count).squareRoot()
        return min(baseline + magnitude, cap)
    }

    /// Decodes a `[TrainingSignal]` JSON blob such as `OutboxItem
    /// .approvedTrainingSignalsJSON` or `TrainingPair.signalsJSON`. Returns
    /// `[]` for nil, empty, or malformed input — callers treat "no signals"
    /// the same as "couldn't decode them."
    static func decodeJSON(_ json: String?) -> [TrainingSignal] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrainingSignal].self, from: data)) ?? []
    }
}
