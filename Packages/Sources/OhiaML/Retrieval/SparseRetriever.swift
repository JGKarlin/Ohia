import Foundation
import OhiaCore

public final class SparseRetriever: @unchecked Sendable {

    private let ftsIndex: MessageFTSIndex
    private let vectorStore: VectorStore

    public init(ftsIndex: MessageFTSIndex, vectorStore: VectorStore) {
        self.ftsIndex = ftsIndex
        self.vectorStore = vectorStore
    }

    /// Returns vector IDs ranked by BM25 over message text. Only vectors
    /// belonging to messages in the FTS5 hit set are returned; the supplied
    /// filter is applied through the vector store's filter metadata table.
    public func retrieve(queryText: String, filter: FilterSpec, k: Int) throws -> [Int64] {
        guard k > 0 else { return [] }
        let messageHits = try ftsIndex.search(queryText: queryText, filter: filter, limit: max(k * 4, k))
        guard !messageHits.isEmpty else { return [] }
        return try vectorStore.vectorIds(forMessageIds: messageHits, filter: filter, limit: k)
    }
}
