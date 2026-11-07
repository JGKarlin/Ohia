import Foundation

public struct ManualProjectTagRecommendationEngine: Sendable {
    public struct Policy: Sendable, Equatable {
        public let titleSimilarityThreshold: Float
        public let selectedTagSimilarityThreshold: Float
        public let minimumCooccurrenceCount: Int
        public let maximumRecommendationCount: Int

        public init(
            titleSimilarityThreshold: Float = 0.55,
            selectedTagSimilarityThreshold: Float = 0.72,
            minimumCooccurrenceCount: Int = 2,
            maximumRecommendationCount: Int = 8
        ) {
            self.titleSimilarityThreshold = titleSimilarityThreshold
            self.selectedTagSimilarityThreshold = selectedTagSimilarityThreshold
            self.minimumCooccurrenceCount = minimumCooccurrenceCount
            self.maximumRecommendationCount = maximumRecommendationCount
        }
    }

    private let embedder: (any EmbeddingProvider)?
    private let policy: Policy

    public init(
        embedder: (any EmbeddingProvider)?,
        policy: Policy = Policy()
    ) {
        self.embedder = embedder
        self.policy = policy
    }

    public func recommendations(
        projectTitle: String,
        selectedTagKeys: Set<String>,
        catalog: MailProjectRuleCatalogSnapshot
    ) -> [MailProjectTagRecommendation] {
        let values = catalog.valuesByFacet[.semanticTag, default: []]
            .filter { $0.isValid && MailProjectSemanticTagIdentity(stableKey: $0.stableKey) != nil }
        guard values.isEmpty == false else { return [] }

        let selectedTags = Set(selectedTagKeys.compactMap(MailProjectSemanticTagIdentity.init(stableKey:)))
        let candidateValues = values.filter { value in
            guard let identity = MailProjectSemanticTagIdentity(stableKey: value.stableKey) else { return false }
            return selectedTags.contains(identity) == false
        }
        guard candidateValues.isEmpty == false else { return [] }

        let title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false || selectedTags.isEmpty == false else { return [] }

        let valuesByIdentity = Dictionary(uniqueKeysWithValues: values.compactMap { value in
            MailProjectSemanticTagIdentity(stableKey: value.stableKey).map { ($0, value) }
        })
        let allIdentities = valuesByIdentity.keys.sorted { $0.stableKey < $1.stableKey }
        let texts = allIdentities.map { Self.embeddingText(for: valuesByIdentity[$0]!) }
        let vectors = embedder?.embedBatch(texts) ?? Array(repeating: nil, count: texts.count)
        let vectorByIdentity = Dictionary(uniqueKeysWithValues: zip(allIdentities, vectors))
        let titleVector = title.isEmpty ? nil : embedder?.embed(title)

        return candidateValues.compactMap { value -> MailProjectTagRecommendation? in
            guard let candidate = MailProjectSemanticTagIdentity(stableKey: value.stableKey) else { return nil }
            let candidateVector = vectorByIdentity[candidate] ?? nil
            let semanticTitleSimilarity = Self.cosineSimilarity(titleVector, candidateVector)
            let lexicalTitleSimilarity = title.isEmpty
                ? nil
                : Self.lexicalSimilarity(title, Self.embeddingText(for: value))
            let titleSimilarity = Self.maximum(semanticTitleSimilarity, lexicalTitleSimilarity)

            var strongestSelectedTag: MailProjectSemanticTagIdentity?
            var selectedTagSimilarity: Float?
            var cooccurrenceCount = 0
            for selectedTag in selectedTags {
                let similarity = Self.cosineSimilarity(
                    vectorByIdentity[selectedTag] ?? nil,
                    candidateVector
                )
                if let similarity,
                   selectedTagSimilarity == nil || similarity > selectedTagSimilarity! {
                    selectedTagSimilarity = similarity
                    strongestSelectedTag = selectedTag
                }
                cooccurrenceCount += catalog.semanticTagCooccurrenceCounts[selectedTag]?[candidate] ?? 0
            }

            let titleQualifies = titleSimilarity.map { $0 >= policy.titleSimilarityThreshold } ?? false
            let selectedQualifies = selectedTagSimilarity.map {
                $0 >= policy.selectedTagSimilarityThreshold
            } ?? false
            let cooccurrenceQualifies = cooccurrenceCount >= policy.minimumCooccurrenceCount
            guard titleQualifies || selectedQualifies || cooccurrenceQualifies else { return nil }

            let cooccurrenceScore = min(1, log2(Float(cooccurrenceCount) + 1) / 3)
            let score = (titleSimilarity ?? 0) * 0.35
                + (selectedTagSimilarity ?? 0) * 0.45
                + cooccurrenceScore * 0.60
                + min(Float(value.currentMatchCount), 25) / 1_000
            return MailProjectTagRecommendation(
                tag: candidate,
                displayName: value.displayName,
                currentMatchCount: value.currentMatchCount,
                score: score,
                cooccurrenceCount: cooccurrenceCount,
                projectTitleSimilarity: titleSimilarity,
                selectedTagSimilarity: selectedTagSimilarity,
                strongestSelectedTag: strongestSelectedTag
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.currentMatchCount != rhs.currentMatchCount {
                return lhs.currentMatchCount > rhs.currentMatchCount
            }
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.tag.stableKey < rhs.tag.stableKey
        }
        .prefix(policy.maximumRecommendationCount)
        .map { $0 }
    }

    private static func embeddingText(for value: MailProjectCatalogValue) -> String {
        [value.displayName, value.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }

    private static func cosineSimilarity(_ lhs: [Float]?, _ rhs: [Float]?) -> Float? {
        guard let lhs, let rhs, lhs.count == rhs.count, lhs.isEmpty == false else { return nil }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private static func lexicalSimilarity(_ lhs: String, _ rhs: String) -> Float? {
        let lhsTokens = tokenSet(lhs)
        let rhsTokens = tokenSet(rhs)
        guard lhsTokens.isEmpty == false, rhsTokens.isEmpty == false else { return nil }
        let intersectionCount = lhsTokens.intersection(rhsTokens).count
        guard intersectionCount > 0 else { return 0 }
        return Float(intersectionCount) / Float(lhsTokens.union(rhsTokens).count)
    }

    private static func tokenSet(_ value: String) -> Set<String> {
        Set(value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { $0.isEmpty == false })
    }

    private static func maximum(_ lhs: Float?, _ rhs: Float?) -> Float? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }
}
