import CoreML
import Foundation
import Hub
import Tokenizers

/// Testable execution seam around Core ML's batch and individual prediction
/// APIs. The production reranker supplies model-backed closures; tests inject
/// deterministic providers without loading model artifacts.
enum CrossEncoderPredictionExecutor {
    static func predict(
        providers: [any MLFeatureProvider],
        batch: ([any MLFeatureProvider]) throws -> [Float],
        individual: (any MLFeatureProvider) throws -> Float,
        onBatchFallback: (any Error) -> Void = { _ in },
        onIndividualFailure: (any Error) -> Void = { _ in }
    ) throws -> [Float] {
        try Task.checkCancellation()
        do {
            let scores = try batch(providers)
            guard scores.count == providers.count else {
                throw PredictionError.outputCountMismatch(
                    expected: providers.count,
                    actual: scores.count
                )
            }
            return scores
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onBatchFallback(error)
            var scores: [Float] = []
            scores.reserveCapacity(providers.count)
            for provider in providers {
                try Task.checkCancellation()
                do {
                    scores.append(try individual(provider))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    onIndividualFailure(error)
                    scores.append(0)
                }
            }
            return scores
        }
    }

    private enum PredictionError: Error {
        case outputCountMismatch(expected: Int, actual: Int)
    }
}

public protocol RetrievalReranking: Sendable {
    func score(query: String, documents: [String]) throws -> [Float]
}

/// Cross-encoder reranker. Scores (query, document) pairs with full
/// cross-attention, returning a calibrated [0, 1] relevance after sigmoid.
/// This is stage 2 of HybridRetriever.
public final class CrossEncoderReranker: RetrievalReranking, @unchecked Sendable {

    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let maxSequenceLength: Int
    private let batchSize: Int
    private let bosTokenId: Int
    private let eosTokenId: Int
    /// Core ML models and swift-transformers tokenizers are not declared
    /// Sendable. All access to both is serialized through this lock.
    private let lock = NSLock()

    public init(
        downloader: CrossEncoderDownloader,
        maxSequenceLength: Int = 512,
        performanceProfile: RetrievalPerformanceProfile = .current()
    ) async throws {
        guard downloader.isAvailable else {
            throw RerankError.modelNotDownloaded
        }
        guard maxSequenceLength > 0 else {
            throw RerankError.invalidMaxSequenceLength
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loadableModelURL = try CoreMLModelCacheCompiler.loadableModelURL(
            for: downloader.modelSourceURL,
            compiledModelURL: downloader.compiledModelURL
        )
        self.model = try MLModel(contentsOf: loadableModelURL, configuration: config)
        let loadedTokenizer = try Self.loadTokenizer(from: downloader.tokenizerDirectory)
        self.tokenizer = loadedTokenizer.tokenizer
        self.maxSequenceLength = maxSequenceLength
        self.batchSize = performanceProfile.crossEncoderBatchSize
        self.bosTokenId = loadedTokenizer.bosTokenId
        self.eosTokenId = loadedTokenizer.eosTokenId
    }

    /// Score a batch of (query, document) pairs. Returns scores aligned to the
    /// input order. Each score is sigmoid(logit), in [0, 1]. Core ML receives
    /// bounded `MLBatchProvider` chunks so accelerator utilization improves
    /// without materializing every candidate tensor at once.
    public func score(query: String, documents: [String]) throws -> [Float] {
        guard !documents.isEmpty else { return [] }
        try Task.checkCancellation()

        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()

        // BGE's XLM-R pair format lets the query be tokenized once and reused
        // across every document in this request.
        let queryTokens = tokenizer.encode(text: query, addSpecialTokens: false)
        var scores: [Float] = []
        scores.reserveCapacity(documents.count)

        var batchStart = 0
        while batchStart < documents.count {
            try Task.checkCancellation()
            let batchEnd = min(documents.count, batchStart + batchSize)
            var providers: [any MLFeatureProvider] = []
            var providerOffsets: [Int] = []
            providers.reserveCapacity(batchEnd - batchStart)
            providerOffsets.reserveCapacity(batchEnd - batchStart)

            for documentIndex in batchStart..<batchEnd {
                try Task.checkCancellation()
                do {
                    providers.append(try featureProvider(
                        queryTokens: queryTokens,
                        document: documents[documentIndex]
                    ))
                    providerOffsets.append(documentIndex - batchStart)
                } catch {
                    print("[CrossEncoder] input preparation failed: \(String(reflecting: type(of: error)))")
                }
            }

            try Task.checkCancellation()
            var batchScores = Array(repeating: Float(0), count: batchEnd - batchStart)
            if !providers.isEmpty {
                let predictedScores = try predict(providers: providers)
                for (offset, predictedScore) in zip(providerOffsets, predictedScores) {
                    batchScores[offset] = predictedScore
                }
            }
            scores.append(contentsOf: batchScores)
            batchStart = batchEnd
        }
        return scores
    }

    private func predict(providers: [any MLFeatureProvider]) throws -> [Float] {
        try CrossEncoderPredictionExecutor.predict(
            providers: providers,
            batch: { providers in
                let batch = MLArrayBatchProvider(array: providers)
                let predictions = try model.predictions(from: batch, options: MLPredictionOptions())
                return (0..<predictions.count).map { index in
                    Self.score(from: predictions.features(at: index)) ?? 0
                }
            },
            individual: { provider in
                let prediction = try model.prediction(from: provider)
                return Self.score(from: prediction) ?? 0
            },
            onBatchFallback: { error in
                // Some Core ML backends may reject batch execution even when
                // every feature shape is valid. Preserve per-pair behavior.
                print("[CrossEncoder] batch prediction failed; using individual fallback: \(String(reflecting: type(of: error)))")
            },
            onIndividualFailure: { error in
                print("[CrossEncoder] score failed: \(String(reflecting: type(of: error)))")
            }
        )
    }

    private func featureProvider(
        queryTokens: [Int],
        document: String
    ) throws -> any MLFeatureProvider {
        let documentTokens = tokenizer.encode(text: document, addSpecialTokens: false)
        let tokens = [bosTokenId] + queryTokens + [eosTokenId, eosTokenId] + documentTokens + [eosTokenId]
        let actualLength = min(tokens.count, maxSequenceLength)

        let inputIds = try MLMultiArray(
            shape: [1, NSNumber(value: maxSequenceLength)],
            dataType: .int32
        )
        let attentionMask = try MLMultiArray(
            shape: [1, NSNumber(value: maxSequenceLength)],
            dataType: .int32
        )
        for index in 0..<maxSequenceLength {
            if index < actualLength {
                inputIds[index] = NSNumber(value: Int32(tokens[index]))
                attentionMask[index] = 1
            } else {
                inputIds[index] = 0
                attentionMask[index] = 0
            }
        }

        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
        ])
    }

    private static func score(from prediction: any MLFeatureProvider) -> Float? {
        guard let logitArray = prediction.featureValue(for: "logit")?.multiArrayValue,
              logitArray.count > 0 else {
            return nil
        }
        let logit = logitArray[0].doubleValue
        return Float(1.0 / (1.0 + exp(-logit)))
    }

    private static func loadTokenizer(from directory: URL) throws -> LoadedTokenizer {
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        let tokenizerDataURL = directory.appendingPathComponent("tokenizer.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tokenizerConfigURL.path) else {
            throw RerankError.missingTokenizerFile(tokenizerConfigURL.lastPathComponent)
        }
        guard fm.fileExists(atPath: tokenizerDataURL.path) else {
            throw RerankError.missingTokenizerFile(tokenizerDataURL.lastPathComponent)
        }

        let hubApi = HubApi.shared
        let tokenizerConfig = try hubApi.configuration(fileURL: tokenizerConfigURL)
        let tokenizerData = try hubApi.configuration(fileURL: tokenizerDataURL)
        let tokenizer = try AutoTokenizer.from(
            tokenizerConfig: swiftTransformersCompatibleConfig(tokenizerConfig, tokenizerData: tokenizerData),
            tokenizerData: tokenizerData
        )
        guard let bosTokenId = configuredSpecialTokenID(
            from: tokenizerConfig.bosToken,
            tokenizer: tokenizer
        ) ?? tokenizer.bosTokenId,
        let eosTokenId = configuredSpecialTokenID(
            from: tokenizerConfig.eosToken,
            tokenizer: tokenizer
        ) ?? tokenizer.eosTokenId else {
            throw RerankError.missingPairSpecialTokens
        }
        return LoadedTokenizer(
            tokenizer: tokenizer,
            bosTokenId: bosTokenId,
            eosTokenId: eosTokenId
        )
    }

    private static func configuredSpecialTokenID(
        from config: Config?,
        tokenizer: any Tokenizer
    ) -> Int? {
        guard let config,
              let token = config.string() ?? config.content.string(),
              let tokenID = tokenizer.convertTokenToId(token),
              tokenizer.convertIdToToken(tokenID) == token else {
            return nil
        }
        return tokenID
    }

    private static func swiftTransformersCompatibleConfig(_ config: Config, tokenizerData: Config) -> Config {
        let tokenizerClass = config.tokenizerClass.string()?.replacingOccurrences(of: "Fast", with: "")
        guard tokenizerClass == "XLMRobertaTokenizer",
              tokenizerData.model.type.string() == "Unigram"
        else {
            return config
        }

        var values = config.dictionary(or: [:])
        values[BinaryDistinctString("tokenizer_class")] = Config("T5Tokenizer")
        return Config(values)
    }

    public enum RerankError: Error, Sendable, Equatable {
        case modelNotDownloaded
        case invalidMaxSequenceLength
        case missingTokenizerFile(String)
        case missingPairSpecialTokens
    }

    private struct LoadedTokenizer {
        let tokenizer: any Tokenizer
        let bosTokenId: Int
        let eosTokenId: Int
    }
}
