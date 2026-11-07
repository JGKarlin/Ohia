import Foundation

/// A nonresident ANN facade for processes that need SQLite vector metadata but
/// must not own or load the disk-backed HNSW index.
///
/// Reads fail closed as an empty index. Mutations throw instead of silently
/// discarding index writes, making accidental embedding/index work in a
/// read-oriented process visible to its caller. `save()` is an explicit no-op
/// because this implementation has no in-memory or on-disk state to persist.
public struct NonresidentVectorIndex: VectorIndex {
    public enum Mutation: String, Sendable, Equatable {
        case add
        case remove
        case removeAllData
        case removeEmbeddingVersion
    }

    public enum MutationError: Error, Sendable, Equatable {
        case unsupported(Mutation)
    }

    public init() {}

    public func add(
        key: Int64,
        vector: [Float],
        collection: VectorCollection,
        embeddingVersion: String
    ) throws {
        throw MutationError.unsupported(.add)
    }

    public func remove(
        key: Int64,
        collection: VectorCollection,
        embeddingVersion: String
    ) throws {
        throw MutationError.unsupported(.remove)
    }

    public func search(
        query: [Float],
        collection: VectorCollection,
        embeddingVersion: String,
        k: Int
    ) throws -> [(key: Int64, distance: Float)] {
        []
    }

    public func count(collection: VectorCollection, embeddingVersion: String) -> Int {
        0
    }

    public func allKeys(
        collection: VectorCollection,
        embeddingVersion: String
    ) -> Set<Int64> {
        []
    }

    public func save() throws {
        // Intentionally empty: there is no resident state and no backing file.
    }

    public func removeAllData() throws {
        throw MutationError.unsupported(.removeAllData)
    }

    public func removeAllData(embeddingVersion: String) throws {
        throw MutationError.unsupported(.removeEmbeddingVersion)
    }
}
