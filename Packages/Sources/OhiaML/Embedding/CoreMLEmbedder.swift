import CoreML
import Foundation
import Tokenizers

/// Generic Core ML embedding adapter: tokenize, pad/truncate, run the model,
/// and unbox the dense embedding output.
public final class CoreMLEmbedder: EmbeddingProvider, @unchecked Sendable {
    public let embeddingDimension: Int
    public let embeddingVersion: String

    private let model: MLModel
    private let compiledModelURL: URL?
    private let tokenizer: any Tokenizer
    private let outputName: String
    private let maxSequenceLength: Int
    private let lock = NSLock()

    public init(
        modelPackageURL: URL,
        compiledModelURL: URL? = nil,
        tokenizer: any Tokenizer,
        embeddingDimension: Int,
        embeddingVersion: String,
        outputName: String,
        maxSequenceLength: Int = 512
    ) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loadableModelURL = try CoreMLModelCacheCompiler.loadableModelURL(
            for: modelPackageURL,
            compiledModelURL: compiledModelURL
        )
        self.compiledModelURL = loadableModelURL == modelPackageURL ? nil : loadableModelURL
        self.model = try MLModel(contentsOf: loadableModelURL, configuration: config)
        self.tokenizer = tokenizer
        self.embeddingDimension = embeddingDimension
        self.embeddingVersion = embeddingVersion
        self.outputName = outputName
        self.maxSequenceLength = maxSequenceLength
    }

    /// A counter over this embedder's tokenizer that shares its lock, so
    /// documents can be measured exactly as `featureProvider(for:)` will
    /// tokenize them.
    public func makeDocumentTokenizer() -> EmbeddingModelTokenizer {
        EmbeddingModelTokenizer(tokenizer: tokenizer, lock: lock, maximumInputTokens: maxSequenceLength)
    }

    public static func isEffectivelyEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func embed(_ text: String) -> [Float]? {
        guard !Self.isEffectivelyEmpty(text) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        return embedLocked(text)
    }

    public func embedBatch(_ texts: [String]) -> [[Float]?] {
        guard !texts.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var results = Array<[Float]?>(repeating: nil, count: texts.count)
        do {
            var providers: [MLFeatureProvider] = []
            var resultIndices: [Int] = []
            providers.reserveCapacity(texts.count)
            resultIndices.reserveCapacity(texts.count)
            for (index, text) in texts.enumerated() where !Self.isEffectivelyEmpty(text) {
                providers.append(try featureProvider(for: text))
                resultIndices.append(index)
            }

            guard !providers.isEmpty else { return results }
            let predictions = try model.predictions(
                from: MLArrayBatchProvider(array: providers),
                options: MLPredictionOptions()
            )
            for (batchIndex, resultIndex) in resultIndices.enumerated() {
                results[resultIndex] = embedding(from: predictions.features(at: batchIndex))
            }
            return results
        } catch {
            print("[CoreMLEmbedder] batch embed failed: \(String(reflecting: type(of: error))); falling back to single predictions")
            return texts.map { text in
                guard !Self.isEffectivelyEmpty(text) else { return nil }
                return embedLocked(text)
            }
        }
    }

    private func embedLocked(_ text: String) -> [Float]? {
        do {
            let prediction = try model.prediction(from: featureProvider(for: text))
            return embedding(from: prediction)
        } catch {
            print("[CoreMLEmbedder] embed failed: \(String(reflecting: type(of: error)))")
            return nil
        }
    }

    private func featureProvider(for text: String) throws -> MLFeatureProvider {
        var tokens = tokenizer.encode(text: Self.normalizedTextForTokenization(text))
        if tokens.count > maxSequenceLength {
            tokens = Array(tokens.prefix(maxSequenceLength))
        }

        let actualLength = tokens.count
        let padCount = max(0, maxSequenceLength - actualLength)
        let paddedTokens = tokens + Array(repeating: 0, count: padCount)
        let attentionMask = Array(repeating: 1, count: actualLength) + Array(repeating: 0, count: padCount)

        let inputIds = try mlArray(from: paddedTokens)
        let mask = try mlArray(from: attentionMask)
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
    }

    private func embedding(from prediction: MLFeatureProvider) -> [Float]? {
        guard let embedding = prediction.featureValue(for: outputName)?.multiArrayValue else {
            return nil
        }

        let floats = floats(from: embedding)
        guard floats.count == embeddingDimension else { return nil }
        guard !Self.isNearZero(floats) else {
            print("[CoreMLEmbedder] embed rejected near-zero vector")
            return nil
        }
        return floats
    }

    private func mlArray(from values: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: maxSequenceLength)],
            dataType: .int32
        )
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: Int32(value))
        }
        return array
    }

    private func floats(from array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }

    private static func isNearZero(_ vector: [Float]) -> Bool {
        let normSquared = vector.reduce(Float(0)) { partial, value in
            let sanitized = value.isFinite ? value : 0
            return partial + sanitized * sanitized
        }
        return normSquared <= 1e-12
    }

    /// Shared with `EmbeddingModelTokenizer` so token counts used for chunking
    /// match the tokens this adapter feeds the model.
    static func normalizedTextForTokenization(_ text: String) -> String {
        let decomposed = text
            .precomposedStringWithCompatibilityMapping
            .decomposedStringWithCanonicalMapping

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            // swift-transformers can fatalError when Unigram emits decomposed kana marks
            // that are canonically equivalent to vocab entries but not NSString-equal.
            guard scalar.value != 0x3099, scalar.value != 0x309A else { continue }
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }
}
