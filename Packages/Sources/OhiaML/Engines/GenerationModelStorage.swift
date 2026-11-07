import Foundation

public enum GenerationModelStorage {
    public static let directoryName = "huggingface"

    public static func downloadBaseDirectory(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func legacyDocumentsDownloadBaseDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func modelDirectory(downloadBaseDirectory: URL, modelID: String) -> URL {
        modelID.split(separator: "/").reduce(
            downloadBaseDirectory.appendingPathComponent("models", isDirectory: true)
        ) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    public static func isModelDownloaded(downloadBaseDirectory: URL, modelID: String) -> Bool {
        let modelDirectory = modelDirectory(downloadBaseDirectory: downloadBaseDirectory, modelID: modelID)
        guard let model = ModelManager.allModels.first(where: { $0.modelId == modelID }) else {
            return hasCompleteModelArtifacts(in: modelDirectory)
        }
        return isModelDownloaded(
            downloadBaseDirectory: downloadBaseDirectory,
            modelID: modelID,
            revision: model.revision
        )
    }

    public static func isModelDownloaded(
        downloadBaseDirectory: URL,
        modelID: String,
        revision: String
    ) -> Bool {
        guard ModelInfo.isImmutableRevision(revision) else {
            return false
        }
        let modelDirectory = modelDirectory(downloadBaseDirectory: downloadBaseDirectory, modelID: modelID)
        return hasCompleteModelArtifacts(in: modelDirectory)
            && hasRevisionMetadata(revision, in: modelDirectory)
    }

    /// Returns true only for a complete public model whose Hugging Face
    /// metadata proves every installed artifact came from the exact immutable
    /// revision supplied by the model registry.
    public static func isVerifiedPublicModel(
        at modelDirectory: URL,
        expectedRevision: String
    ) -> Bool {
        guard ModelInfo.isImmutableRevision(expectedRevision),
              hasCompleteModelArtifacts(in: modelDirectory)
        else {
            return false
        }
        return hasRevisionMetadata(expectedRevision, in: modelDirectory)
    }

    private static func hasCompleteModelArtifacts(in modelDirectory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        guard fileExists(named: "config.json", in: modelDirectory),
              hasTokenizerArtifact(in: modelDirectory),
              hasCompleteWeights(in: modelDirectory)
        else {
            return false
        }
        return true
    }

    @discardableResult
    public static func migrateLegacyDocumentsModels(
        to downloadBaseDirectory: URL,
        modelIDs: [String] = ModelManager.allModels.map(\.modelId)
    ) throws -> [URL] {
        let legacyBase = legacyDocumentsDownloadBaseDirectory()
        return try migrateLegacyModels(
            from: legacyBase,
            to: downloadBaseDirectory,
            modelIDs: modelIDs
        )
    }

    @discardableResult
    static func migrateLegacyModels(
        from legacyBase: URL,
        to downloadBaseDirectory: URL,
        modelIDs: [String] = ModelManager.allModels.map(\.modelId)
    ) throws -> [URL] {
        let fileManager = FileManager.default
        guard legacyBase.standardizedFileURL.path != downloadBaseDirectory.standardizedFileURL.path else {
            return []
        }

        var migrated: [URL] = []
        for modelID in Set(modelIDs) {
            let legacyModelDirectory = modelDirectory(downloadBaseDirectory: legacyBase, modelID: modelID)
            guard fileManager.fileExists(atPath: legacyModelDirectory.path) else { continue }

            let newModelDirectory = modelDirectory(downloadBaseDirectory: downloadBaseDirectory, modelID: modelID)
            guard !fileManager.fileExists(atPath: newModelDirectory.path) else { continue }

            try fileManager.createDirectory(
                at: newModelDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyModelDirectory, to: newModelDirectory)
            try excludeFromBackup(newModelDirectory)
            migrated.append(newModelDirectory)
            removeEmptyLegacyParents(startingAt: legacyModelDirectory.deletingLastPathComponent(), stopAt: legacyBase)
        }

        if !migrated.isEmpty {
            try excludeFromBackup(downloadBaseDirectory)
        }
        return migrated
    }

    public static func prepareDownloadBase(_ downloadBaseDirectory: URL) throws {
        try FileManager.default.createDirectory(at: downloadBaseDirectory, withIntermediateDirectories: true)
        try excludeFromBackup(downloadBaseDirectory)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func removeEmptyLegacyParents(startingAt start: URL, stopAt stop: URL) {
        let fileManager = FileManager.default
        var current = start
        let stopPath = stop.standardizedFileURL.path
        while current.standardizedFileURL.path.hasPrefix(stopPath) {
            guard current.standardizedFileURL.path != stopPath else { break }
            let contents = (try? fileManager.contentsOfDirectory(atPath: current.path)) ?? []
            guard contents.isEmpty else { break }
            try? fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private static func fileExists(named filename: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }

    private static func hasTokenizerArtifact(in directory: URL) -> Bool {
        fileExists(named: "tokenizer.json", in: directory)
            || fileExists(named: "tokenizer.model", in: directory)
            || fileExists(named: "vocab.json", in: directory)
    }

    private static func hasCompleteWeights(in directory: URL) -> Bool {
        let completedWeightBytes = completedSafetensorsBytes(in: directory)
        guard completedWeightBytes > 0 else { return false }
        if let namedShardsAreComplete = namedShardsAreComplete(in: directory),
           !namedShardsAreComplete {
            return false
        }

        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return true
        }
        guard let expectedWeightBytes = safetensorsTotalBytes(in: directory) else {
            return false
        }
        return completedWeightBytes >= expectedWeightBytes
    }

    private static func hasRevisionMetadata(
        _ expectedRevision: String,
        in modelDirectory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: modelDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let modelPathPrefix = modelDirectory.standardizedFileURL.path + "/"
        let metadataDirectory = modelDirectory
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        var foundArtifact = false

        for case let artifactURL as URL in enumerator {
            guard let values = try? artifactURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  artifactURL.standardizedFileURL.path.hasPrefix(modelPathPrefix)
            else {
                continue
            }
            foundArtifact = true
            let relativePath = String(
                artifactURL.standardizedFileURL.path.dropFirst(modelPathPrefix.count)
            )
            let metadataURL = metadataDirectory
                .appendingPathComponent(relativePath + ".metadata")
            guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8),
                  let commitHash = contents.split(separator: "\n", omittingEmptySubsequences: false).first,
                  commitHash.trimmingCharacters(in: .whitespacesAndNewlines) == expectedRevision
            else {
                return false
            }
        }

        return foundArtifact
    }

    private static func safetensorsTotalBytes(in directory: URL) -> Int64? {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder()
            .decode(SafetensorsIndex.self, from: data)
            .metadata?
            .totalSize
    }

    private static func completedSafetensorsBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let path = url.path
            guard !path.contains("/.cache/"),
                  url.lastPathComponent.hasSuffix(".safetensors"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private static func namedShardsAreComplete(in directory: URL) -> Bool? {
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let shards = filenames.compactMap(shardPosition)
        guard !shards.isEmpty else { return nil }

        let expectedCounts = Set(shards.map(\.count))
        guard expectedCounts.count == 1,
              let expectedCount = expectedCounts.first,
              expectedCount > 0
        else {
            return false
        }

        let completedPositions = Set(shards.map(\.position))
        return completedPositions.count == expectedCount
            && completedPositions == Set(1...expectedCount)
    }

    private static func shardPosition(filename: String) -> (position: Int, count: Int)? {
        let suffix = ".safetensors"
        guard filename.hasSuffix(suffix) else { return nil }
        let stem = filename.dropLast(suffix.count)
        let components = stem.split(separator: "-")
        guard components.count >= 4,
              components[components.count - 2] == "of",
              let position = Int(components[components.count - 3]),
              let count = Int(components[components.count - 1]),
              count > 0,
              (1...count).contains(position)
        else {
            return nil
        }
        return (position, count)
    }

    private struct SafetensorsIndex: Decodable {
        struct Metadata: Decodable {
            let totalSize: Int64

            enum CodingKeys: String, CodingKey {
                case totalSize = "total_size"
            }
        }

        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case metadata
        }
    }
}
