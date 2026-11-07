import CoreML
import CryptoKit
import Foundation

enum CoreMLModelCacheCompiler {
    private static let compileLock = NSLock()
    private static let sourceSignatureFilename = ".ohia-source-signature"

    static func loadableModelURL(for modelSourceURL: URL, compiledModelURL: URL?) throws -> URL {
        guard modelSourceURL.pathExtension != "mlmodelc" else {
            return modelSourceURL
        }

        compileLock.lock()
        defer { compileLock.unlock() }

        let fm = FileManager.default
        if let compiledModelURL,
           isCompiledModelFresh(compiledModelURL, sourceModelURL: modelSourceURL)
        {
            try? writeSourceSignatureIfNeeded(for: compiledModelURL, sourceModelURL: modelSourceURL)
            return compiledModelURL
        }

        let temporaryCompiledURL = try MLModel.compileModel(at: modelSourceURL)
        guard let compiledModelURL else {
            return temporaryCompiledURL
        }

        try fm.createDirectory(
            at: compiledModelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: compiledModelURL)
        try fm.moveItem(at: temporaryCompiledURL, to: compiledModelURL)
        try? writeSourceSignatureIfNeeded(for: compiledModelURL, sourceModelURL: modelSourceURL)
        return compiledModelURL
    }

    private static func isCompiledModelFresh(_ compiledModelURL: URL, sourceModelURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: compiledModelURL.path) else { return false }

        if let expectedSignature = sourceSignature(for: sourceModelURL) {
            let signatureURL = compiledModelURL.appendingPathComponent(sourceSignatureFilename)
            if let storedSignature = try? String(contentsOf: signatureURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                return storedSignature == expectedSignature
            }
        }

        let sourceDate = modificationDate(
            for: sourceModelURL.appendingPathComponent("Manifest.json")
        ) ?? modificationDate(for: sourceModelURL)
        let compiledDate = modificationDate(for: compiledModelURL)
        guard let sourceDate, let compiledDate else { return true }
        return compiledDate >= sourceDate
    }

    private static func writeSourceSignatureIfNeeded(
        for compiledModelURL: URL,
        sourceModelURL: URL
    ) throws {
        guard let signature = sourceSignature(for: sourceModelURL) else { return }
        try signature.write(
            to: compiledModelURL.appendingPathComponent(sourceSignatureFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func sourceSignature(for sourceModelURL: URL) -> String? {
        let manifestURL = sourceModelURL.appendingPathComponent("Manifest.json")
        let modelURL = sourceModelURL
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("com.apple.CoreML", isDirectory: true)
            .appendingPathComponent("model.mlmodel")
        let weightURL = sourceModelURL
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("com.apple.CoreML", isDirectory: true)
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin")

        var parts: [String] = []
        if let manifestHash = sha256Hex(contentsOf: manifestURL) {
            parts.append("manifest:\(manifestHash)")
        }
        if let modelHash = sha256Hex(contentsOf: modelURL) {
            parts.append("model:\(modelHash)")
        }
        if let weightSize = fileSize(for: weightURL) {
            parts.append("weight-bytes:\(weightSize)")
        }
        if let weightDate = modificationDate(for: weightURL) {
            parts.append("weight-modified:\(weightDate.timeIntervalSince1970)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    private static func sha256Hex(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(for url: URL) -> UInt64? {
        guard let value = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return value as? UInt64
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
