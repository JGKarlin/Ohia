import Foundation
import OhiaCore

public final class StyleExemplarRetriever: @unchecked Sendable {
    private let hybridRetriever: HybridRetriever

    public init(hybridRetriever: HybridRetriever) {
        self.hybridRetriever = hybridRetriever
    }

    /// Retrieves the user's own sent replies most similar to the current
    /// correspondent + subject from the `.style` collection.
    ///
    /// `restrictToMessageIDs` hard-filters the hits to a style register's
    /// member replies so the exemplars shown to the model actually belong to
    /// the voice being written in — similarity alone can surface replies
    /// from a different register that merely share vocabulary.
    ///
    /// `fallbackMessageIDs` is the language-pure widening set (the user's
    /// sent mail written in the draft's language). When the register
    /// restriction leaves fewer than two exemplars, the ranking falls back
    /// to this set instead of going unrestricted: thin evidence beats no
    /// evidence, but an exemplar in another language is never evidence —
    /// styles are language-scoped. Only when no fallback set is supplied
    /// (language unknown) does the legacy unrestricted ranking apply.
    public func retrieve(
        correspondentName: String,
        subject: String,
        formality: Double? = nil,
        organization: String? = nil,
        restrictToMessageIDs: Set<String>? = nil,
        fallbackMessageIDs: Set<String>? = nil,
        topK: Int = 5
    ) throws -> [String] {
        var queryParts = ["correspondent=\(correspondentName)", subject]
        if let form = formality { queryParts.append("formality=\(String(format: "%.2f", form))") }
        if let org = organization { queryParts.append("organization=\(org)") }

        let queryText = queryParts.joined(separator: " ")
        let restricted = restrictToMessageIDs != nil || fallbackMessageIDs != nil
        let fetchK = restricted ? topK * 4 : topK
        let results = try hybridRetriever.retrieve(
            query: queryText,
            filter: FilterSpec(collections: [.style]),
            k: fetchK
        )

        if let allowed = restrictToMessageIDs {
            let registerHits = results
                .filter { allowed.contains($0.record.messageId) }
                .prefix(topK)
                .map(\.record.textPayload)
            if registerHits.count >= 2 {
                return Array(registerHits)
            }
        }

        if let languagePool = fallbackMessageIDs {
            return Array(
                results
                    .filter { languagePool.contains($0.record.messageId) }
                    .prefix(topK)
                    .map(\.record.textPayload)
            )
        }

        return results.prefix(topK).map(\.record.textPayload)
    }
}
