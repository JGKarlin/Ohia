import Foundation
import OhiaCore

/// Coarse hardware profile for keeping the pipeline useful across compact
/// Apple Silicon and Max-class desktop parts. The numbers intentionally tune
/// batch sizes and burst counts, not correctness; tests and settings can inject
/// a fixed profile while production uses `current()`.
public struct PipelinePerformanceProfile: Sendable, Equatable {
    public let baseBatchSize: Int
    public let firstLightMailAppSeedLimit: Int
    public let steadyMailAppSeedLimit: Int
    public let firstLightFreshIngestPipelineBatchLimit: Int
    public let embeddingJobBatchLimit: Int
    public let embeddingDocumentBatchLimit: Int
    public let catchUpEmbeddingJobBatchLimit: Int
    public let catchUpEmbeddingDocumentBatchLimit: Int
    public let catchUpEmbedDrainSeconds: TimeInterval
    public let inlineLayoutBurstLimit: Int
    public let steadyIndexJobsPerTick: Int
    public let mediumIndexBurstLimit: Int
    public let highIndexBurstLimit: Int

    public init(
        baseBatchSize: Int,
        firstLightMailAppSeedLimit: Int,
        steadyMailAppSeedLimit: Int,
        firstLightFreshIngestPipelineBatchLimit: Int,
        embeddingJobBatchLimit: Int,
        embeddingDocumentBatchLimit: Int,
        catchUpEmbeddingJobBatchLimit: Int,
        catchUpEmbeddingDocumentBatchLimit: Int,
        catchUpEmbedDrainSeconds: TimeInterval,
        inlineLayoutBurstLimit: Int,
        steadyIndexJobsPerTick: Int,
        mediumIndexBurstLimit: Int,
        highIndexBurstLimit: Int
    ) {
        self.baseBatchSize = baseBatchSize
        self.firstLightMailAppSeedLimit = firstLightMailAppSeedLimit
        self.steadyMailAppSeedLimit = steadyMailAppSeedLimit
        self.firstLightFreshIngestPipelineBatchLimit = firstLightFreshIngestPipelineBatchLimit
        self.embeddingJobBatchLimit = embeddingJobBatchLimit
        self.embeddingDocumentBatchLimit = embeddingDocumentBatchLimit
        self.catchUpEmbeddingJobBatchLimit = catchUpEmbeddingJobBatchLimit
        self.catchUpEmbeddingDocumentBatchLimit = catchUpEmbeddingDocumentBatchLimit
        self.catchUpEmbedDrainSeconds = catchUpEmbedDrainSeconds
        self.inlineLayoutBurstLimit = inlineLayoutBurstLimit
        self.steadyIndexJobsPerTick = steadyIndexJobsPerTick
        self.mediumIndexBurstLimit = mediumIndexBurstLimit
        self.highIndexBurstLimit = highIndexBurstLimit
    }

    public static let compact = PipelinePerformanceProfile(
        baseBatchSize: 32,
        firstLightMailAppSeedLimit: 6,
        steadyMailAppSeedLimit: 96,
        firstLightFreshIngestPipelineBatchLimit: 3,
        embeddingJobBatchLimit: 4,
        embeddingDocumentBatchLimit: 24,
        catchUpEmbeddingJobBatchLimit: 12,
        catchUpEmbeddingDocumentBatchLimit: 48,
        catchUpEmbedDrainSeconds: 3,
        inlineLayoutBurstLimit: 8,
        steadyIndexJobsPerTick: 4,
        mediumIndexBurstLimit: 8,
        highIndexBurstLimit: 12
    )

    public static let balanced = PipelinePerformanceProfile(
        baseBatchSize: 50,
        firstLightMailAppSeedLimit: 8,
        steadyMailAppSeedLimit: 200,
        firstLightFreshIngestPipelineBatchLimit: 4,
        embeddingJobBatchLimit: 8,
        embeddingDocumentBatchLimit: 24,
        catchUpEmbeddingJobBatchLimit: 24,
        catchUpEmbeddingDocumentBatchLimit: 64,
        catchUpEmbedDrainSeconds: 5,
        inlineLayoutBurstLimit: 12,
        steadyIndexJobsPerTick: 8,
        mediumIndexBurstLimit: 16,
        highIndexBurstLimit: 24
    )

    public static let workstation = PipelinePerformanceProfile(
        baseBatchSize: 75,
        firstLightMailAppSeedLimit: 10,
        steadyMailAppSeedLimit: 300,
        firstLightFreshIngestPipelineBatchLimit: 6,
        embeddingJobBatchLimit: 12,
        embeddingDocumentBatchLimit: 24,
        catchUpEmbeddingJobBatchLimit: 32,
        catchUpEmbeddingDocumentBatchLimit: 96,
        catchUpEmbedDrainSeconds: 8,
        inlineLayoutBurstLimit: 12,
        steadyIndexJobsPerTick: 8,
        mediumIndexBurstLimit: 16,
        highIndexBurstLimit: 24
    )

    public static let ultra = PipelinePerformanceProfile(
        baseBatchSize: 100,
        firstLightMailAppSeedLimit: 12,
        steadyMailAppSeedLimit: 500,
        firstLightFreshIngestPipelineBatchLimit: 8,
        embeddingJobBatchLimit: 16,
        embeddingDocumentBatchLimit: 32,
        catchUpEmbeddingJobBatchLimit: 48,
        catchUpEmbeddingDocumentBatchLimit: 128,
        catchUpEmbedDrainSeconds: 10,
        inlineLayoutBurstLimit: 16,
        steadyIndexJobsPerTick: 12,
        mediumIndexBurstLimit: 24,
        highIndexBurstLimit: 36
    )

    public static func current(
        processInfo: ProcessInfo = .processInfo,
        topology suppliedTopology: AppleSiliconComputeTopology? = nil
    ) -> PipelinePerformanceProfile {
        let memoryGB = processInfo.physicalMemory / (1024 * 1024 * 1024)
        let topology = suppliedTopology ?? .current(processInfo: processInfo)

        return forHardware(memoryGB: memoryGB, topology: topology)
    }

    public static func forHardware(
        memoryGB: UInt64,
        topology: AppleSiliconComputeTopology
    ) -> PipelinePerformanceProfile {

        if memoryGB >= 64,
           topology.weightedComputeCapacity >= 32 {
            return .ultra
        }
        if memoryGB >= 32,
           topology.weightedComputeCapacity >= 18 {
            return .workstation
        }
        if memoryGB <= 8 || topology.weightedComputeCapacity <= 12 {
            return .compact
        }
        return .balanced
    }

    public func scaledBatchSize(multiplier: Double) -> Int {
        max(1, Int((Double(baseBatchSize) * multiplier).rounded()))
    }
}
