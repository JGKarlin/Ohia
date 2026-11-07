import Foundation
import OhiaCore
import OhiaML

/// Drives the Constellation Search tab's exact-biased literal search off the
/// main actor. Wraps `LexicalSearchEngine` (FTS5 trigram literal hits +
/// demoted semantic neighbors) — distinct from Ask, which uses the full
/// hybrid retriever and an LLM.
@MainActor
public final class LexicalSearchController {

    private let engine: LexicalSearchEngine

    public init(engine: LexicalSearchEngine) {
        self.engine = engine
    }

    public func search(_ query: String, filter: FilterSpec) async throws -> LexicalSearchResult {
        try await Task.detached(priority: .userInitiated) { [engine] in
            try engine.search(query: query, filter: filter)
        }.value
    }
}
