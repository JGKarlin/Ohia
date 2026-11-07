import Foundation
import OhiaCore

/// Hardware-scaled limits for interactive hybrid retrieval.
///
/// Candidate generation retains the original recall-oriented 10x/100 pool on
/// every device. Only the more expensive cross-encoder stage scales down on
/// compact machines, and it never receives fewer than three candidates per
/// requested result so the downstream MMR pass keeps its full working set.
public struct RetrievalPerformanceProfile: Sendable, Equatable {
    public let rerankCandidateMultiplier: Int
    public let minimumRerankCandidateCount: Int
    public let crossEncoderBatchSize: Int

    public init(
        rerankCandidateMultiplier: Int,
        minimumRerankCandidateCount: Int,
        crossEncoderBatchSize: Int
    ) {
        self.rerankCandidateMultiplier = max(3, rerankCandidateMultiplier)
        self.minimumRerankCandidateCount = max(1, minimumRerankCandidateCount)
        self.crossEncoderBatchSize = max(1, crossEncoderBatchSize)
    }

    public static let compact = RetrievalPerformanceProfile(
        rerankCandidateMultiplier: 6,
        minimumRerankCandidateCount: 48,
        crossEncoderBatchSize: 2
    )

    public static let balanced = RetrievalPerformanceProfile(
        rerankCandidateMultiplier: 8,
        minimumRerankCandidateCount: 80,
        crossEncoderBatchSize: 4
    )

    public static let workstation = RetrievalPerformanceProfile(
        rerankCandidateMultiplier: 10,
        minimumRerankCandidateCount: 100,
        crossEncoderBatchSize: 8
    )

    public static func current(
        processInfo: ProcessInfo = .processInfo,
        topology suppliedTopology: AppleSiliconComputeTopology? = nil
    ) -> RetrievalPerformanceProfile {
        select(
            physicalMemory: processInfo.physicalMemory,
            topology: suppliedTopology ?? .current(processInfo: processInfo)
        )
    }

    public static func select(
        physicalMemory: UInt64,
        topology: AppleSiliconComputeTopology
    ) -> RetrievalPerformanceProfile {
        let memoryGB = physicalMemory / (1024 * 1024 * 1024)
        if memoryGB >= 32, topology.weightedComputeCapacity >= 18 {
            return .workstation
        }
        if memoryGB <= 8 || topology.weightedComputeCapacity <= 12 {
            return .compact
        }
        return .balanced
    }

    /// Bounds the expensive rerank stage while preserving the `3 * k`
    /// candidate pool consumed by MMR and never exceeding hydrated candidates.
    public func rerankCandidateLimit(
        requestedResultCount: Int,
        availableCandidateCount: Int
    ) -> Int {
        guard requestedResultCount > 0, availableCandidateCount > 0 else { return 0 }
        let mmrQualityFloor = Self.saturatingMultiply(requestedResultCount, by: 3)
        let preferredDepth = max(
            Self.saturatingMultiply(requestedResultCount, by: rerankCandidateMultiplier),
            minimumRerankCandidateCount
        )
        return min(availableCandidateCount, max(mmrQualityFloor, preferredDepth))
    }

    /// The recall-oriented dense/sparse pool is intentionally invariant across
    /// devices; only the expensive cross-encoder depth is hardware-scaled.
    public func stage1CandidateLimit(requestedResultCount: Int) -> Int {
        guard requestedResultCount > 0 else { return 0 }
        return max(Self.saturatingMultiply(requestedResultCount, by: 10), 100)
    }

    public func diversificationCandidateLimit(
        requestedResultCount: Int,
        availableCandidateCount: Int
    ) -> Int {
        guard requestedResultCount > 0, availableCandidateCount > 0 else { return 0 }
        return min(
            availableCandidateCount,
            Self.saturatingMultiply(requestedResultCount, by: 3)
        )
    }

    private static func saturatingMultiply(_ value: Int, by multiplier: Int) -> Int {
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? Int.max : result
    }
}
