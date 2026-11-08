import Foundation
import Hub

public enum BGE3ModelDownloaderError: Error, Sendable, Equatable {
    case missingDownloadedArtifact(String)
}

/// Resolves the bge-m3 Core ML model package and tokenizer files. Ohia checks
/// the app bundle first for a fully local install, then falls back to the
/// mutable Application Support cache populated from Hugging Face Hub.
public final class BGE3ModelDownloader: @unchecked Sendable {

    public static let coreMLRepoID = "JGKarlin/ohia-bge-m3-coreml"
    public static let tokenizerRepoID = "BAAI/bge-m3"
    /// Downloads are pinned to these commits so a change to a repository's
    /// `main` branch never reaches an installed app unreviewed. Hugging Face
    /// serves a commit's files immutably.
    public static let coreMLRevision = "cb67d6bcbdb0c68efc2448752717cbbf925034c6"
    public static let tokenizerRevision = "5617a9f61b028005a4858fdac845db406aefb181"
    public static let modelPackageFilename = "bge-m3.mlpackage"
    public static let compiledModelFilename = "bge-m3.mlmodelc"

    private static let tokenizerFilenames = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
    ]

    private let cacheDirectory: URL
    private let bundledDirectory: URL?

    public init(
        cacheDirectory: URL,
        bundledDirectory: URL? = BGE3ModelDownloader.defaultBundledDirectory()
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

    /// True when every expected file is present on disk. Used by `AppServices`
    /// to decide whether bge-m3 can be loaded synchronously or must first be
    /// downloaded in the background.
    public var isAvailable: Bool {
        isBundledAvailable || isCachedAvailable
    }

    public var missingArtifactNames: [String] {
        Self.missingExpectedFiles(in: resolvedDirectory)
    }

    private var resolvedDirectory: URL {
        if isBundledAvailable, let bundledDirectory {
            return bundledDirectory
        }
        return cacheDirectory
    }

    private static func expectedFilesExist(in directory: URL) -> Bool {
        missingExpectedFiles(in: directory).isEmpty
    }

    private static func missingExpectedFiles(in directory: URL) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        let modelPackageURL = directory.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
        let compiledModelURL = directory.appendingPathComponent(Self.compiledModelFilename, isDirectory: true)
        if !fm.fileExists(atPath: modelPackageURL.path),
           !fm.fileExists(atPath: compiledModelURL.path) {
            missing.append("\(Self.compiledModelFilename) or \(Self.modelPackageFilename)")
        }
        for name in Self.tokenizerFilenames {
            if !fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        return missing
    }

    public static func defaultBundledDirectory(bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let bundleLocalDirectory = resourceURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("bge-m3", isDirectory: true)
        if expectedFilesExist(in: bundleLocalDirectory) {
            return bundleLocalDirectory
        }

        var ancestor = bundle.bundleURL
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app" {
                let enclosingAppDirectory = ancestor
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent("bge-m3", isDirectory: true)
                if expectedFilesExist(in: enclosingAppDirectory) {
                    return enclosingAppDirectory
                }
                break
            }
            ancestor.deleteLastPathComponent()
        }

        return bundleLocalDirectory
    }

    /// Download or refresh all required artifacts. `HubApi.snapshot` owns the
    /// content-addressed global cache; Ohia keeps stable local paths under its
    /// Application Support directory for Core ML and tokenizer loading.
    public func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let coreMLRepo = Hub.Repo(id: Self.coreMLRepoID)
        let coreMLDir = try await HubApi.shared.snapshot(
            from: coreMLRepo,
            revision: Self.coreMLRevision,
            matching: ["\(Self.modelPackageFilename)/*"]
        ) { p in
            progress?(Self.clamp(p.fractionCompleted * 0.85))
        }
        let downloadedPackage = coreMLDir.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
        try installSymlink(
            from: downloadedPackage,
            to: cacheDirectory.appendingPathComponent(Self.modelPackageFilename, isDirectory: true)
        )

        let tokenizerRepo = Hub.Repo(id: Self.tokenizerRepoID)
        let tokenizerDir = try await HubApi.shared.snapshot(
            from: tokenizerRepo,
            revision: Self.tokenizerRevision,
            matching: Self.tokenizerFilenames
        ) { p in
            progress?(Self.clamp(0.85 + p.fractionCompleted * 0.15))
        }

        let fm = FileManager.default
        for name in Self.tokenizerFilenames {
            let src = tokenizerDir.appendingPathComponent(name)
            let dst = cacheDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else {
                throw BGE3ModelDownloaderError.missingDownloadedArtifact(src.path)
            }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        progress?(1.0)
    }

    private func installSymlink(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw BGE3ModelDownloaderError.missingDownloadedArtifact(src.path)
        }
        try? fm.removeItem(at: dst)
        try fm.createSymbolicLink(at: dst, withDestinationURL: src)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
