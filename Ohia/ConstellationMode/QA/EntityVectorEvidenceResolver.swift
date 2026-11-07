import Foundation
import OhiaCore
import OhiaML

public struct EntityVectorEvidenceResolver: EntityProfileResolver {
    private let vectorStore: VectorStore

    public init(vectorStore: VectorStore) {
        self.vectorStore = vectorStore
    }

    public func evidence(for messageId: String) -> String? {
        guard let rows = try? vectorStore.vectorsForMessage(messageId: messageId) else {
            return nil
        }
        return rows.first(where: { $0.collection == .context })?.textPayload
            ?? rows.first?.textPayload
    }
}
