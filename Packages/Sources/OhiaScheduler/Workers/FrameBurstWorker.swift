import Foundation
import SwiftData
import OhiaCore
import OhiaML

public struct FrameBurstPayload: Codable, Sendable {
    public let frame: FrameKey
    public let iterations: Int
    public init(frame: FrameKey, iterations: Int = 200) {
        self.frame = frame
        self.iterations = iterations
    }
}

/// Drains `.frameBurst` jobs by invoking `LayoutOrchestrator.burstForFrame`
/// for a single frame, then chaining a `.clusterDetect` enqueue via
/// `ClusterDetectSeeder`. The edge provider is injected at construction
/// time; the context accessor (a closure returning the app's main
/// `ModelContext`) is used for the seeder enqueue because `ModelContext`
/// is not `Sendable` and cannot be stored on an actor.
public actor FrameBurstWorker {
    private let orchestrator: LayoutOrchestrator
    private let edgeProvider: FrameEdgeProvider
    private let contextAccessor: @MainActor () -> ModelContext

    public init(
        orchestrator: LayoutOrchestrator,
        edgeProvider: FrameEdgeProvider,
        contextAccessor: @escaping @MainActor () -> ModelContext
    ) {
        self.orchestrator = orchestrator
        self.edgeProvider = edgeProvider
        self.contextAccessor = contextAccessor
    }

    public func run(payload: FrameBurstPayload) async throws {
        let weights = FrameForceWeights.forFrame(payload.frame)
        try await orchestrator.burstForFrame(
            payload.frame,
            weights: weights,
            edgeProvider: edgeProvider,
            iterations: payload.iterations
        )
        try await MainActor.run { [contextAccessor] in
            try ClusterDetectSeeder.seedIfNeeded(
                frame: payload.frame,
                context: contextAccessor()
            )
        }
    }
}
