import Foundation
import OhiaML

/// Thin actor wrapper that drives `LayoutOrchestrator.refineStep` for one
/// `.refine` pipeline tick. The `iterations` parameter is set by
/// `PipelineRunner`: visible Constellation sessions defer refinement to
/// preserve spatial stability, while idle sessions run larger bursts. Self-
/// reenqueue pacing also lives in `PipelineRunner` — this worker is
/// intentionally a one-liner so tests can exercise the orchestrator call
/// directly.
public actor LayoutRefineWorker {

    private let orchestrator: LayoutOrchestrator

    public init(orchestrator: LayoutOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Run `iterations` force-directed steps over the whole placed corpus.
    /// Degenerate cases (fewer than 2 placed vectors) are handled inside the
    /// orchestrator — this method forwards without any local gating.
    public func runBurst(iterations: Int) async throws {
        try await orchestrator.refineStep(iterations: iterations)
    }
}
