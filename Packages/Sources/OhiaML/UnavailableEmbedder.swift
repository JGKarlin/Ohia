// UnavailableEmbedder.swift
// Null-object `EmbeddingProvider` used when no real embedder can be
// created. Every call to `embed(_:)` returns nil, so downstream consumers
// that already guard on an optional vector (EmbeddingOrchestrator,
// VectorNeighborProvider, StyleExemplarRetriever, AgentTools…) naturally
// no-op. The app logs the condition once at startup so the failure is
// visible rather than silently polluting the vector store with fake data.

import Foundation

public final class UnavailableEmbedder: EmbeddingProvider {
    public let embeddingDimension: Int
    public let embeddingVersion: String

    public init(dimension: Int = 0, embeddingVersion: String = "unavailable-v1") {
        self.embeddingDimension = dimension
        self.embeddingVersion = embeddingVersion
    }

    public func embed(_ text: String) -> [Float]? {
        nil
    }
}
