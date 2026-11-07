import Foundation
import OhiaCore

// MARK: - ModelInfo

public struct ModelInfo: Sendable, Identifiable {
    public var id: String { modelId }
    public var isImmutableRevision: Bool {
        Self.isImmutableRevision(revision)
    }
    public let modelId: String
    public let revision: String
    public let displayName: String
    public let estimatedDownloadGB: Double
    public let requiredMemoryGB: Double
    public let recommendationMemoryGB: Double
    public let languageSupport: [String]
    public let isOptIn: Bool

    public init(
        modelId: String,
        revision: String = "main",
        displayName: String,
        estimatedDownloadGB: Double,
        requiredMemoryGB: Double,
        recommendationMemoryGB: Double? = nil,
        languageSupport: [String] = ["en"],
        isOptIn: Bool = false
    ) {
        self.modelId = modelId
        self.revision = revision
        self.displayName = displayName
        self.estimatedDownloadGB = estimatedDownloadGB
        self.requiredMemoryGB = requiredMemoryGB
        self.recommendationMemoryGB = recommendationMemoryGB ?? requiredMemoryGB
        self.languageSupport = languageSupport
        self.isOptIn = isOptIn
    }

    static func isImmutableRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

// MARK: - HardwareInfo

public struct HardwareInfo: Sendable {
    public let memoryBytes: UInt64
    public let memoryGB: Int
    public let chipName: String
    public let activeProcessorCount: Int
    public let modelIdentifier: String?

    public init(
        memoryBytes: UInt64,
        memoryGB: Int? = nil,
        chipName: String,
        activeProcessorCount: Int,
        modelIdentifier: String?
    ) {
        self.memoryBytes = memoryBytes
        self.memoryGB = memoryGB ?? Int(memoryBytes / (1024 * 1024 * 1024))
        self.chipName = chipName
        self.activeProcessorCount = activeProcessorCount
        self.modelIdentifier = modelIdentifier
    }
}

// MARK: - GenerationModelMode

public enum GenerationModelMode: String, CaseIterable, Identifiable, Sendable {
    case performance
    case quality

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .performance:
            return "Performance"
        case .quality:
            return "Quality"
        }
    }

    public var shortDescription: String {
        switch self {
        case .performance:
            return "Lower memory use and faster responses."
        case .quality:
            return "More capable model for harder summaries and Ask answers."
        }
    }
}

// MARK: - ModelRecommendationPair

public struct ModelRecommendationPair: Sendable {
    public let hardware: HardwareInfo
    public let performance: ModelInfo
    public let quality: ModelInfo
    public let optInModels: [ModelInfo]

    public func model(for mode: GenerationModelMode) -> ModelInfo {
        switch mode {
        case .performance:
            return performance
        case .quality:
            return quality
        }
    }

    public func mode(for modelID: String) -> GenerationModelMode? {
        if performance.modelId == modelID { return .performance }
        if quality.modelId == modelID { return .quality }
        return nil
    }
}

// MARK: - DownloadProgress

public struct DownloadProgress: Sendable {
    public let modelId: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let fractionCompleted: Double
    public let isComplete: Bool

    public init(modelId: String, bytesDownloaded: Int64, totalBytes: Int64) {
        self.modelId = modelId
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.fractionCompleted = totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0.0
        self.isComplete = totalBytes > 0 && bytesDownloaded >= totalBytes
    }
}

// MARK: - ModelManager

public enum ModelManager {

    public static let selectedGenerationModelIDKey = "ohia.generation.selectedModelID"
    public static let selectedGenerationModelModeKey = "ohia.generation.selectedModelMode"
    public static let pendingGenerationModelIDKey = "ohia.generation.pendingModelID"
    public static let pendingGenerationModelModeKey = "ohia.generation.pendingModelMode"
    public static let stoppedGenerationModelIDKey = "ohia.generation.stoppedModelID"

    /// Which engine produces on-demand body translations. Independent of the
    /// generation-model selection above, persisted to the same defaults suite.
    public static let selectedTranslationEngineKey = "ohia.translation.selectedEngine"

    // MARK: Model Registry

    /// Current Qwen recommendations are ranked newest/highest-quality to
    /// lightest. The UI exposes the largest training-safe entry as Quality and
    /// the next less demanding recommendation tier as Performance for the
    /// Mac's unified memory.
    public static let normalModels: [ModelInfo] = requireImmutableRevisions([
        ModelInfo(
            modelId: "mlx-community/Qwen3.8-27B-bf16",
            revision: "6f265714824f3c38d4452baa1628aef3d9b9aae9",
            displayName: "Qwen3.8 27B (BF16)",
            estimatedDownloadGB: 54.8,
            requiredMemoryGB: 96.0,
            recommendationMemoryGB: 128.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.8-27B-8bit",
            revision: "815b83c0df8ffd1d1b5244cf75fd6ef14fca9ef9",
            displayName: "Qwen3.8 27B (8-bit)",
            estimatedDownloadGB: 29.5,
            requiredMemoryGB: 64.0,
            recommendationMemoryGB: 96.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.8-27B-4bit",
            revision: "3e6447f082e89cc7f0bc6e5441afd38dfce760ff",
            displayName: "Qwen3.8 27B (4-bit)",
            estimatedDownloadGB: 16.1,
            requiredMemoryGB: 48.0,
            recommendationMemoryGB: 48.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.5-9B-4bit",
            revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53",
            displayName: "Qwen3.5 9B (4-bit)",
            estimatedDownloadGB: 6.0,
            requiredMemoryGB: 24.0,
            recommendationMemoryGB: 24.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.5-4B-4bit",
            revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            displayName: "Qwen3.5 4B (4-bit)",
            estimatedDownloadGB: 3.1,
            requiredMemoryGB: 8.0,
            recommendationMemoryGB: 16.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.5-2B-4bit",
            revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
            displayName: "Qwen3.5 2B (4-bit)",
            estimatedDownloadGB: 1.8,
            requiredMemoryGB: 4.0,
            recommendationMemoryGB: 8.0,
            languageSupport: multilingualLanguageSupport
        ),
        ModelInfo(
            modelId: "mlx-community/Qwen3.5-0.8B-4bit",
            revision: "da28692b5f139cb0ec58a356b437486b7dac7462",
            displayName: "Qwen3.5 0.8B (4-bit)",
            estimatedDownloadGB: 0.7,
            requiredMemoryGB: 4.0,
            recommendationMemoryGB: 4.0,
            languageSupport: multilingualLanguageSupport
        ),
    ])

    public static let optInModels: [ModelInfo] = requireImmutableRevisions([])

    public static let allModels: [ModelInfo] = normalModels + optInModels

    private static let multilingualLanguageSupport = LocalModelLanguageSupport.supportedLanguageIDs

    private static func requireImmutableRevisions(_ models: [ModelInfo]) -> [ModelInfo] {
        precondition(
            models.allSatisfy(\.isImmutableRevision),
            "Every production model revision must be a 40-character lowercase hexadecimal commit."
        )
        return models
    }

    // MARK: Hardware Detection

    public static func hardwareInfo() -> HardwareInfo {
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        return HardwareInfo(
            memoryBytes: memoryBytes,
            chipName: readChipName(),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            modelIdentifier: readModelIdentifier()
        )
    }

    private static func readChipName() -> String {
        if let name = readSysctlString("machdep.cpu.brand_string"), !name.isEmpty {
            return name
        }
        return "Apple Silicon Mac"
    }

    private static func readModelIdentifier() -> String? {
        readSysctlString("hw.model")
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let string = String(decoding: buffer.prefix(size > 0 ? size - 1 : 0), as: UTF8.self)
        return string.isEmpty ? nil : string
    }

    // MARK: Compatible Models

    /// Returns models compatible with the given memory, in preference order.
    /// A model is compatible when its `requiredMemoryGB` fits within total
    /// physical memory. The values already include headroom for OS + app.
    public static func compatibleModels(memoryBytes: UInt64) -> [ModelInfo] {
        let memoryGB = Int(memoryBytes / (1024 * 1024 * 1024))
        return compatibleModels(memoryGB: memoryGB)
    }

    /// Convenience overload accepting memory in GB. Preserves registry order.
    public static func compatibleModels(memoryGB: Int) -> [ModelInfo] {
        return allModels.filter { $0.requiredMemoryGB <= Double(memoryGB) }
    }

    // MARK: Recommendation

    public static func recommendedPair(
        memoryBytes: UInt64,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ModelRecommendationPair {
        let hardware = HardwareInfo(
            memoryBytes: memoryBytes,
            chipName: "This Mac",
            activeProcessorCount: activeProcessorCount,
            modelIdentifier: nil
        )
        return recommendedPair(for: hardware)
    }

    public static func recommendedPairForCurrentHardware() -> ModelRecommendationPair {
        recommendedPair(for: hardwareInfo())
    }

    public static func recommendedPair(for hardware: HardwareInfo) -> ModelRecommendationPair {
        let compatibleNormal = normalModels.filter { $0.recommendationMemoryGB <= Double(hardware.memoryGB) }
        let rankedNormal = compatibleNormal.isEmpty ? [normalModels.last].compactMap { $0 } : compatibleNormal
        let quality = rankedNormal[0]
        let performance = rankedNormal.dropFirst().first {
            $0.recommendationMemoryGB < quality.recommendationMemoryGB
        } ?? quality
        return ModelRecommendationPair(
            hardware: hardware,
            performance: performance,
            quality: quality,
            optInModels: optInModels.filter { $0.requiredMemoryGB <= Double(hardware.memoryGB) }
        )
    }

    /// Legacy single-model recommendation. Defaults to the less demanding
    /// Performance choice so first-run downloads remain conservative.
    public static func recommendModel(memoryBytes: UInt64) -> ModelInfo {
        recommendedPair(memoryBytes: memoryBytes).performance
    }

    /// Recommends a model based on the current machine's hardware.
    public static func recommendModelForCurrentHardware() -> ModelInfo {
        recommendedPairForCurrentHardware().performance
    }

    public static func selectedGenerationModelForCurrentHardware() -> ModelInfo {
        selectedGenerationModel(memoryBytes: hardwareInfo().memoryBytes)
    }

    public static func selectedGenerationModel(memoryBytes: UInt64) -> ModelInfo {
        let pair = recommendedPair(memoryBytes: memoryBytes)
        guard let modelID = selectedGenerationModelID(),
              let model = allModels.first(where: { $0.modelId == modelID }),
              compatibleModels(memoryBytes: memoryBytes).contains(where: { $0.modelId == model.modelId })
        else {
            return pair.model(for: selectedGenerationModelMode())
        }
        return model
    }

    public static func selectedGenerationModelMode() -> GenerationModelMode {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let value = defaults.string(forKey: selectedGenerationModelModeKey),
           let mode = GenerationModelMode(rawValue: value) {
            return mode
        }
        return .performance
    }

    public static func selectedGenerationModelID() -> String? {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let value = defaults.string(forKey: selectedGenerationModelIDKey), !value.isEmpty {
            return normalizedSelectedGenerationModelID(value, defaults: defaults)
        }
        return nil
    }

    public static func setSelectedGenerationModelID(_ modelID: String?) {
        let defaults = generationModelDefaults()
        if let modelID, let normalizedID = normalizedModelID(modelID) {
            defaults.set(normalizedID, forKey: selectedGenerationModelIDKey)
        } else {
            defaults.removeObject(forKey: selectedGenerationModelIDKey)
        }
        clearStoppedGenerationModelDownload()
    }

    public static func setSelectedGenerationModelMode(_ mode: GenerationModelMode) {
        let defaults = generationModelDefaults()
        defaults.set(mode.rawValue, forKey: selectedGenerationModelModeKey)
    }

    // MARK: Translation Engine Selection

    /// The engine used for on-demand body translation. Defaults to the local
    /// Qwen generative model (`TranslationEngineKind.defaultEngine`). Read live
    /// by `RoutingTranslator` so a change takes effect on the next translation
    /// without rebuilding the service. When the default engine's model isn't
    /// loaded it surfaces a clear failure rather than silently falling back; the
    /// user switches to Apple's on-device path explicitly if they prefer.
    public static func selectedTranslationEngine() -> TranslationEngineKind {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let raw = defaults.string(forKey: selectedTranslationEngineKey) {
            return persistResolvedTranslationEngine(rawValue: raw, defaults: defaults)
        }
        return .defaultEngine
    }

    private static func persistResolvedTranslationEngine(
        rawValue: String,
        defaults: UserDefaults
    ) -> TranslationEngineKind {
        let kind = resolvedTranslationEngine(rawValue: rawValue)
        if rawValue != kind.rawValue {
            defaults.set(kind.rawValue, forKey: selectedTranslationEngineKey)
        }
        return kind
    }

    private static func resolvedTranslationEngine(rawValue: String) -> TranslationEngineKind {
        if let kind = TranslationEngineKind(rawValue: rawValue) {
            return kind
        }
        return .defaultEngine
    }

    public static func setSelectedTranslationEngine(_ kind: TranslationEngineKind) {
        let defaults = generationModelDefaults()
        defaults.set(kind.rawValue, forKey: selectedTranslationEngineKey)
    }

    public static func pendingGenerationModelID() -> String? {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let value = defaults.string(forKey: pendingGenerationModelIDKey), !value.isEmpty {
            return normalizedPendingGenerationModelID(value, defaults: defaults)
        }
        return nil
    }

    public static func pendingGenerationModelMode() -> GenerationModelMode? {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let value = defaults.string(forKey: pendingGenerationModelModeKey),
           let mode = GenerationModelMode(rawValue: value) {
            return mode
        }
        return nil
    }

    public static func stoppedGenerationModelID() -> String? {
        let defaults = generationModelDefaults()
        defaults.synchronize()
        if let value = defaults.string(forKey: stoppedGenerationModelIDKey), !value.isEmpty {
            return normalizedStoppedGenerationModelID(value, defaults: defaults)
        }
        return nil
    }

    public static func isGenerationModelDownloadStopped(for modelID: String? = nil) -> Bool {
        guard let stoppedID = stoppedGenerationModelID()
        else {
            return false
        }
        let preparationID = pendingGenerationModelID()
            ?? selectedGenerationModelID()
            ?? selectedGenerationModelForCurrentHardware().modelId
        guard preparationID == stoppedID else { return false }
        guard let modelID else { return true }
        return normalizedModelID(modelID) == stoppedID
    }

    public static func setPendingGenerationModelID(_ modelID: String?, mode: GenerationModelMode?) {
        let defaults = generationModelDefaults()
        if let modelID, let normalizedID = normalizedModelID(modelID) {
            defaults.set(normalizedID, forKey: pendingGenerationModelIDKey)
            if let mode {
                defaults.set(mode.rawValue, forKey: pendingGenerationModelModeKey)
            } else {
                defaults.removeObject(forKey: pendingGenerationModelModeKey)
            }
            clearStoppedGenerationModelDownload()
        } else {
            clearPendingGenerationModel()
        }
    }

    public static func clearPendingGenerationModel() {
        let defaults = generationModelDefaults()
        defaults.removeObject(forKey: pendingGenerationModelIDKey)
        defaults.removeObject(forKey: pendingGenerationModelModeKey)
        clearStoppedGenerationModelDownload()
    }

    public static func setGenerationModelDownloadStopped(_ stopped: Bool, modelID: String?) {
        guard stopped,
              let modelID,
              let normalizedID = normalizedModelID(modelID)
        else {
            clearStoppedGenerationModelDownload()
            return
        }

        let defaults = generationModelDefaults()
        defaults.set(normalizedID, forKey: stoppedGenerationModelIDKey)
    }

    public static func clearStoppedGenerationModelDownload() {
        let defaults = generationModelDefaults()
        defaults.removeObject(forKey: stoppedGenerationModelIDKey)
    }

    @discardableResult
    public static func promotePendingGenerationModelIfMatches(_ modelID: String) -> Bool {
        guard let normalizedID = normalizedModelID(modelID),
              pendingGenerationModelID() == normalizedID
        else {
            return false
        }

        setSelectedGenerationModelID(normalizedID)
        if let pendingMode = pendingGenerationModelMode() {
            setSelectedGenerationModelMode(pendingMode)
        }
        clearPendingGenerationModel()
        return true
    }

    private static func generationModelDefaults() -> UserDefaults {
        OhiaSharedDefaults.store
    }

    private static func normalizedSelectedGenerationModelID(_ modelID: String, defaults: UserDefaults) -> String? {
        guard let normalizedID = normalizedModelID(modelID) else {
            defaults.removeObject(forKey: selectedGenerationModelIDKey)
            return nil
        }

        if normalizedID != modelID {
            defaults.set(normalizedID, forKey: selectedGenerationModelIDKey)
        }
        return normalizedID
    }

    private static func normalizedPendingGenerationModelID(_ modelID: String, defaults: UserDefaults) -> String? {
        guard let normalizedID = normalizedModelID(modelID) else {
            clearPendingGenerationModel()
            return nil
        }

        if normalizedID != modelID {
            defaults.set(normalizedID, forKey: pendingGenerationModelIDKey)
        }
        return normalizedID
    }

    private static func normalizedStoppedGenerationModelID(_ modelID: String, defaults: UserDefaults) -> String? {
        guard let normalizedID = normalizedModelID(modelID) else {
            clearStoppedGenerationModelDownload()
            return nil
        }

        if normalizedID != modelID {
            defaults.set(normalizedID, forKey: stoppedGenerationModelIDKey)
        }
        return normalizedID
    }

    private static func normalizedModelID(_ modelID: String) -> String? {
        allModels.contains(where: { $0.modelId == modelID }) ? modelID : nil
    }
}
