import Foundation
import OhiaCore
import OhiaML

/// Thin actor wrapper that drives `LayoutOrchestrator.indexNewVector` for a
/// single `.index` pipeline job. Phase 1 doesn't need retry, batching, or
/// back-pressure here — the orchestrator internally handles all degenerate
/// cases (missing vector, empty placed set, positionless neighbors).
public actor LayoutIndexWorker {

    private let orchestrator: LayoutOrchestrator

    public init(orchestrator: LayoutOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Place a single newly-embedded vector: k-NN against the placed set,
    /// persist neighbor edges, seed at the similarity-weighted centroid, and
    /// run a short local force-directed refinement.
    public func process(vectorId: Int64) async throws {
        try await orchestrator.indexNewVector(vectorId: vectorId)
    }

    /// Place a burst of newly-embedded vectors while reusing the same placed
    /// corpus snapshot. This is the scheduler hot path during first ingest.
    @discardableResult
    public func process(vectorIds: [Int64]) async throws -> Int {
        try await orchestrator.indexNewVectors(vectorIds: vectorIds)
    }
}
