import Foundation

/// Single source of truth for embedders known to this app run: one current
/// embedder for new writes, plus optional previous embedders for controlled
/// embedding-version upgrades.
public final class EmbedderRegistry: @unchecked Sendable {
    public let current: EmbeddingProvider
    public let legacy: [EmbeddingProvider]

    public init(current: EmbeddingProvider, legacy: [EmbeddingProvider] = []) {
        self.current = current
        self.legacy = legacy
    }

    public func embedder(forVersion version: String) -> EmbeddingProvider? {
        if current.embeddingVersion == version {
            return current
        }
        return legacy.first { $0.embeddingVersion == version }
    }

    public var dimensionsByVersion: [String: Int] {
        var dimensions = [current.embeddingVersion: current.embeddingDimension]
        for embedder in legacy {
            dimensions[embedder.embeddingVersion] = embedder.embeddingDimension
        }
        return dimensions
    }
}
