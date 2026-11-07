import Foundation
import Hub

public enum CrossEncoderDownloaderError: Error, Sendable, Equatable {
    case missingDownloadedArtifact(String)
}

/// Resolves the bge-reranker-v2-m3 Core ML model package and tokenizer files.
/// Ohia checks the app bundle first for a fully local install, then falls back
/// to the mutable Application Support cache populated from Hugging Face Hub.
public final class CrossEncoderDownloader: @unchecked Sendable {

    public static let coreMLRepoID = "JGKarlin/ohia-bge-reranker-v2-m3-coreml"
    public static let tokenizerRepoID = "BAAI/bge-reranker-v2-m3"
    public static let modelPackageFilename = "bge-reranker-v2-m3.mlpackage"
    public static let compiledModelFilename = "bge-reranker-v2-m3.mlmodelc"

    private static let tokenizerFilenames = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
    ]

    private let cacheDirectory: URL
    private let bundledDirectory: URL?

    public init(
        cacheDirectory: URL,
        bundledDirectory: URL? = CrossEncoderDownloader.defaultBundledDirectory()
    ) {
        self.cacheDirectory = cacheDirectory
        self.bundledDirectory = bundledDirectory
    }

    public var modelPackageURL: URL {
        resolvedDirectory.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
    }

    public var modelSourceURL: URL {
        let compiledURL = resolvedDirectory.appendingPathComponent(Self.compiledModelFilename, isDirectory: true)
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            return compiledURL
        }
        return modelPackageURL
    }

    public var compiledModelURL: URL {
        cacheDirectory.appendingPathComponent(Self.compiledModelFilename, isDirectory: true)
    }

    public var cacheDirectoryURL: URL {
        cacheDirectory
    }

    public var tokenizerDirectory: URL {
        resolvedDirectory
    }

    public var isBundledAvailable: Bool {
        guard let bundledDirectory else { return false }
        return Self.expectedFilesExist(in: bundledDirectory)
    }

    public var isCachedAvailable: Bool {
        Self.expectedFilesExist(in: cacheDirectory)
    }

    public var isAvailable: Bool {
        isBundledAvailable || isCachedAvailable
    }

    private var resolvedDirectory: URL {
        if isBundledAvailable, let bundledDirectory {
            return bundledDirectory
        }
        return cacheDirectory
    }

    private var cachedModelPackageURL: URL {
        cacheDirectory.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
    }

    private static func expectedFilesExist(in directory: URL) -> Bool {
        let fm = FileManager.default
        let modelPackageURL = directory.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
        let compiledModelURL = directory.appendingPathComponent(Self.compiledModelFilename, isDirectory: true)
        guard fm.fileExists(atPath: modelPackageURL.path)
                || fm.fileExists(atPath: compiledModelURL.path)
        else { return false }
        for name in Self.tokenizerFilenames {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return false }
        }
        return true
    }

    public static func defaultBundledDirectory(bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        return resourceURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("bge-reranker-v2-m3", isDirectory: true)
    }

    /// Download or refresh all required artifacts. `Hub.snapshot` owns the
    /// content-addressed global cache; Ohia keeps stable local paths under its
    /// Application Support directory for Core ML and tokenizer loading.
    public func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let coreMLRepo = Hub.Repo(id: Self.coreMLRepoID)
        let coreMLDir = try await Hub.snapshot(
            from: coreMLRepo,
            matching: ["\(Self.modelPackageFilename)/*"]
        ) { p in
            progress?(Self.clamp(p.fractionCompleted * 0.85))
        }
        let downloadedPackage = coreMLDir.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
        try installSymlink(from: downloadedPackage, to: cachedModelPackageURL)

        let tokenizerRepo = Hub.Repo(id: Self.tokenizerRepoID)
        let tokenizerDir = try await Hub.snapshot(
            from: tokenizerRepo,
            matching: Self.tokenizerFilenames
        ) { p in
            progress?(Self.clamp(0.85 + p.fractionCompleted * 0.15))
        }

        let fm = FileManager.default
        for name in Self.tokenizerFilenames {
            let src = tokenizerDir.appendingPathComponent(name)
            let dst = cacheDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else {
                throw CrossEncoderDownloaderError.missingDownloadedArtifact(src.path)
            }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        progress?(1.0)
    }

    private func installSymlink(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw CrossEncoderDownloaderError.missingDownloadedArtifact(src.path)
        }
        try? fm.removeItem(at: dst)
        try fm.createSymbolicLink(at: dst, withDestinationURL: src)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
