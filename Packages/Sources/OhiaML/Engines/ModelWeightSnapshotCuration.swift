// ModelWeightSnapshotCuration.swift
// Constrains Hugging Face weight downloads and on-disk snapshots to the shard
// files declared by the repo's own `model.safetensors.index.json`.
//
// Some MLX community repos ship auxiliary weight files outside the shard index
// (e.g. mlx-community/Qwen3.6-27B-OptiQ-4bit's `optiq/mtp.safetensors`, aimed
// at newer Python runtimes; its vision sidecar was later registered in the
// index and is not affected). mlx-swift-lm's `loadWeights` merges every
// `*.safetensors` under the snapshot directory recursively, and stray `mtp.*`
// tensors flip the Qwen3.5 family's norm-shift heuristic — corrupting every
// RMSNorm of an already-converted checkpoint and producing garbage
// generations. Curating to the index keeps any such repo loadable without
// model-specific accommodation elsewhere.

import Foundation

enum ModelWeightSnapshotCuration {

    /// The weight glob mlx-swift-lm passes for model downloads. Coupled to the
    /// literal spelling of `modelDownloadPatterns` in MLXLMCommon — if that
    /// dependency ever changes its pattern, curation silently disables, so the
    /// coupling must be revisited on dependency updates.
    static let weightGlob = "*.safetensors"

    static let indexFileName = "model.safetensors.index.json"

    /// Outcome of resolving a snapshot's shard index.
    enum IndexResolution: Equatable {
        /// No index file — single-file repos legitimately have none.
        case missing
        /// An index file exists but cannot name the shard set (unreadable,
        /// undecodable, or empty `weight_map`). Curation must fall back to the
        /// plain glob so repos the glob served before keep loading.
        case unusable(String)
        /// The snapshot-relative shard paths the repo declares.
        case indexed(Set<String>)
    }

    /// Outcome of a prune pass over a snapshot directory.
    enum PruneOutcome: Equatable {
        /// Snapshot-relative paths of removed weight files (possibly empty).
        case pruned([String])
        /// Nothing was deleted: the index names files that are absent from the
        /// snapshot (broken index push, or a torn read across a repo update).
        /// Deleting while index and disk disagree risks destroying a valid
        /// local model, so the pass declines.
        case skipped(missingIndexedFiles: [String])
    }

    private struct WeightIndex: Decodable {
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    static func containsWeightGlob(_ patterns: [String]) -> Bool {
        patterns.contains(weightGlob)
    }

    static func resolveIndex(inSnapshot directory: URL) -> IndexResolution {
        let indexURL = directory.appending(path: indexFileName)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            return .unusable("index unreadable: \(error.localizedDescription)")
        }
        let index: WeightIndex
        do {
            index = try JSONDecoder().decode(WeightIndex.self, from: data)
        } catch {
            return .unusable("index undecodable: \(error.localizedDescription)")
        }
        let files = Set(index.weightMap.values)
        guard !files.isEmpty else {
            return .unusable("index names no weight files")
        }
        return .indexed(files)
    }

    /// Replaces the weight glob with the explicit indexed shard list, keeping
    /// every other pattern in place. Exact filenames are themselves valid
    /// `fnmatch` patterns, so HubApi downloads precisely those files.
    static func weightConstrainedPatterns(
        _ patterns: [String],
        indexedFiles: Set<String>
    ) -> [String] {
        patterns.flatMap { pattern in
            pattern == weightGlob ? indexedFiles.sorted() : [pattern]
        }
    }

    /// Removes `*.safetensors` files the index does not declare, along with
    /// their HubApi download-metadata twins (offline mode requires file and
    /// metadata to stay paired), then clears any directories the removals
    /// emptied.
    ///
    /// The UI process and the generative worker share the snapshot directory
    /// and may prune concurrently, so every removal tolerates the file already
    /// being gone.
    @discardableResult
    static func pruneUnindexedWeightFiles(
        inSnapshot directory: URL,
        indexedFiles: Set<String>
    ) throws -> PruneOutcome {
        let fileManager = FileManager.default
        let root = directory.resolvingSymlinksInPath()
        let rootPrefix = root.path + "/"

        let missingIndexedFiles = indexedFiles
            .filter { !fileManager.fileExists(atPath: root.appending(path: $0).path) }
            .sorted()
        guard missingIndexedFiles.isEmpty else {
            return .skipped(missingIndexedFiles: missingIndexedFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return .pruned([])
        }

        var doomed: [(url: URL, relativePath: String)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "safetensors" else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(resolved.path.dropFirst(rootPrefix.count))
            guard !relativePath.hasPrefix(".cache/") else { continue }
            guard !indexedFiles.contains(relativePath) else { continue }
            doomed.append((resolved, relativePath))
        }

        let metadataRoot = root.appending(path: ".cache/huggingface/download")
        for (url, relativePath) in doomed {
            try removeItemToleratingAbsence(at: url)
            try removeItemToleratingAbsence(
                at: metadataRoot.appending(path: relativePath + ".metadata"))
        }
        for (url, _) in doomed {
            try removeEmptiedDirectories(from: url.deletingLastPathComponent(), upTo: root)
        }
        for (_, relativePath) in doomed {
            let metadataDirectory = metadataRoot
                .appending(path: relativePath + ".metadata")
                .deletingLastPathComponent()
            try removeEmptiedDirectories(from: metadataDirectory, upTo: metadataRoot)
        }

        return .pruned(doomed.map(\.relativePath).sorted())
    }

    /// `removeItem` that treats an already-absent file as success — the goal
    /// state, reached first by whichever process won the race.
    private static func removeItemToleratingAbsence(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileNoSuchFile.rawValue {
                return
            }
            if nsError.domain == NSPOSIXErrorDomain,
               nsError.code == Int(ENOENT) {
                return
            }
            throw error
        }
    }

    /// Removes `directory` and its ancestors while they are empty, stopping at
    /// (and never removing) `root`. Uses POSIX `rmdir`, which refuses to remove
    /// a non-empty directory, so a concurrent writer can never lose files to
    /// this cleanup.
    private static func removeEmptiedDirectories(from directory: URL, upTo root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().path
        var current = directory.resolvingSymlinksInPath()
        while current.path != rootPath, current.path.hasPrefix(rootPath + "/") {
            if rmdir(current.path) != 0 {
                switch errno {
                case ENOTEMPTY, EEXIST:
                    // Occupied (or re-occupied by a concurrent writer): done.
                    return
                case ENOENT:
                    // A concurrent prune removed it first; continue upward.
                    break
                default:
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            current = current.deletingLastPathComponent()
        }
    }
}
