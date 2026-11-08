import Foundation
import Hub
import OhiaCore
import Tokenizers

/// Concrete bge-m3 embedding provider backed by the converted Core ML package.
public final class BGE3Embedder: RuntimeLaneLimitedEmbeddingProvider, @unchecked Sendable {
    public static var embeddingDimension: Int { 1024 }
    // v4 sizes every document to the model's 512-token window with the model's
    // own tokenizer (`EmbeddingChunker`), so long bodies, attachments, and text
    // without spaces (Japanese, Chinese, Korean) are chunked instead of cut off.
    // v3 introduced embedding only the message's own text, excluding quoted
    // reply/forward history. The model itself is unchanged. The version bump
    // segregates pre- and post-cutover vectors in the index and routes existing
    // rows through `EmbeddingMigrationCoordinator` for re-embedding.
    public static var embeddingVersion: String { "bge-m3-v4-token-windows" }

    public var embeddingDimension: Int { Self.embeddingDimension }
    public var embeddingVersion: String { Self.embeddingVersion }

    public var parallelLaneCount: Int { lanes.count }

    public var documentTokenizer: (any EmbeddingDocumentTokenizing)? { tokenCounter }

    private let lanes: [CoreMLEmbedder]
    private let tokenCounter: EmbeddingModelTokenizer

    public init(
        downloader: BGE3ModelDownloader,
        laneCount: Int = BGE3Embedder.defaultLaneCount()
    ) throws {
        guard downloader.isAvailable else {
            throw EmbedderError.modelNotDownloaded
        }

        let resolvedLaneCount = max(1, min(laneCount, Self.maximumLaneCount))
        var builtLanes: [CoreMLEmbedder] = []
        builtLanes.reserveCapacity(resolvedLaneCount)
        for _ in 0..<resolvedLaneCount {
            let tokenizer = try Self.loadTokenizer(from: downloader.tokenizerDirectory)
            builtLanes.append(try CoreMLEmbedder(
                modelPackageURL: downloader.modelSourceURL,
                compiledModelURL: downloader.compiledModelURL,
                tokenizer: tokenizer,
                embeddingDimension: Self.embeddingDimension,
                embeddingVersion: Self.embeddingVersion,
                outputName: "embedding",
                maxSequenceLength: 512
            ))
        }
        self.lanes = builtLanes
        // Measured on the last lane: single-text embeds and the first share of
        // every batch use lane 0, so counting contends least here.
        self.tokenCounter = builtLanes[builtLanes.count - 1].makeDocumentTokenizer()

        guard self.lanes[0].embed("Ohia embedding startup validation.") != nil else {
            throw EmbedderError.invalidEmbeddingOutput
        }
    }

    public func embed(_ text: String) -> [Float]? {
        lanes[0].embed(text)
    }

    public func embedBatch(_ texts: [String]) -> [[Float]?] {
        lanes[0].embedBatch(texts)
    }

    public func embedBatchAsync(_ texts: [String], priority: TaskPriority) async -> [[Float]?] {
        await embedBatchAsync(texts, priority: priority, laneLimit: lanes.count)
    }

    public func embedBatchAsync(
        _ texts: [String],
        priority: TaskPriority,
        laneLimit: Int
    ) async -> [[Float]?] {
        guard !texts.isEmpty else { return [] }
        let requestedLaneCount = max(1, min(laneLimit, lanes.count))
        guard requestedLaneCount > 1, texts.count > 1 else {
            return lanes[0].embedBatch(texts)
        }

        let activeLaneCount = min(requestedLaneCount, texts.count)
        let chunkSize = Int(ceil(Double(texts.count) / Double(activeLaneCount)))
        return await withTaskGroup(of: (Int, [[Float]?]).self) { group in
            var start = 0
            for laneIndex in 0..<activeLaneCount {
                let end = min(start + chunkSize, texts.count)
                guard start < end else { break }
                let lane = lanes[laneIndex]
                let offset = start
                let chunk = Array(texts[start..<end])
                group.addTask(priority: priority) {
                    (offset, lane.embedBatch(chunk))
                }
                start = end
            }

            var results = Array<[Float]?>(repeating: nil, count: texts.count)
            for await (offset, chunkResults) in group {
                for (index, result) in chunkResults.enumerated() {
                    results[offset + index] = result
                }
            }
            return results
        }
    }

    public static func defaultLaneCount(processInfo: ProcessInfo = .processInfo) -> Int {
        if let override = processInfo.environment["OHIA_BGE_EMBEDDER_LANES"],
           let value = Int(override) {
            return max(1, min(value, maximumLaneCount))
        }

        return selectLaneCount(
            physicalMemory: processInfo.physicalMemory,
            topology: .current(processInfo: processInfo)
        )
    }

    public static func selectLaneCount(
        physicalMemory: UInt64,
        topology: AppleSiliconComputeTopology
    ) -> Int {
        let memoryGB = physicalMemory / (1024 * 1024 * 1024)
        if memoryGB >= 64, topology.weightedComputeCapacity >= 32 {
            return 4
        }
        if memoryGB >= 32, topology.weightedComputeCapacity >= 18 {
            return 3
        }
        if memoryGB >= 16, topology.weightedComputeCapacity >= 14 {
            return 2
        }
        return 1
    }

    static func loadTokenizer(from directory: URL) throws -> Tokenizer {
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        let tokenizerDataURL = directory.appendingPathComponent("tokenizer.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tokenizerConfigURL.path) else {
            throw EmbedderError.missingTokenizerFile(tokenizerConfigURL.lastPathComponent)
        }
        guard fm.fileExists(atPath: tokenizerDataURL.path) else {
            throw EmbedderError.missingTokenizerFile(tokenizerDataURL.lastPathComponent)
        }

        let hubApi = HubApi.shared
        let tokenizerConfig = try hubApi.configuration(fileURL: tokenizerConfigURL)
        let tokenizerData = try hubApi.configuration(fileURL: tokenizerDataURL)
        return try AutoTokenizer.from(
            tokenizerConfig: swiftTransformersCompatibleConfig(tokenizerConfig, tokenizerData: tokenizerData),
            tokenizerData: tokenizerData
        )
    }

    private static func swiftTransformersCompatibleConfig(_ config: Config, tokenizerData: Config) -> Config {
        let tokenizerClass = config.tokenizerClass.string()?.replacingOccurrences(of: "Fast", with: "")
        guard tokenizerClass == "XLMRobertaTokenizer",
              tokenizerData.model.type.string() == "Unigram"
        else {
            return config
        }

        // swift-transformers does not currently expose an XLM-R class, but bge-m3's
        // tokenizer.json is a SentencePiece-style Unigram pipeline.
        var values = config.dictionary(or: [:])
        values[BinaryDistinctString("tokenizer_class")] = Config("T5Tokenizer")
        return Config(values)
    }

    public enum EmbedderError: Error, Sendable {
        case modelNotDownloaded
        case missingTokenizerFile(String)
        case invalidEmbeddingOutput
    }

    private static let maximumLaneCount = 4
}
