import Foundation
import OhiaCore

public struct SemanticTagIdentityPolicy: Sendable, Equatable {
    public let minimumSimilarity: Float
    public let minimumWinnerMargin: Float

    public init(minimumSimilarity: Float, minimumWinnerMargin: Float) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumWinnerMargin = minimumWinnerMargin
    }

    public static let production = Self(
        minimumSimilarity: 0.88,
        minimumWinnerMargin: 0.05
    )
}

public enum SemanticTagIdentityResolutionKind: Sendable, Equatable {
    case exact
    case semantic
    case provisional
    case pending
}

public struct SemanticTagIdentityResolution {
    public let kind: SemanticTagIdentityResolutionKind
    public let tag: SemanticTag?
    public let similarity: Float?

    public init(
        kind: SemanticTagIdentityResolutionKind,
        tag: SemanticTag?,
        similarity: Float? = nil
    ) {
        self.kind = kind
        self.tag = tag
        self.similarity = similarity
    }
}

@MainActor
public final class SemanticTagIdentityResolver {
    private let embedder: EmbeddingProvider
    private let policy: SemanticTagIdentityPolicy

    public init(embedder: EmbeddingProvider, policy: SemanticTagIdentityPolicy = .production) {
        self.embedder = embedder
        self.policy = policy
    }

    public func resolve(
        candidate: SemanticTagCandidate,
        repository: SemanticTagRepository,
        at date: Date = .now
    ) throws -> SemanticTagIdentityResolution {
        let exactMatches = try repository.exactTags(matching: candidate)
        if let first = exactMatches.first {
            var survivor = first
            for duplicate in exactMatches.dropFirst() {
                survivor = try repository.merge(survivor, with: duplicate, at: date)
            }
            try repository.attachAliases(from: candidate, to: survivor, at: date)
            return SemanticTagIdentityResolution(kind: .exact, tag: survivor)
        }

        let candidateSurfaces = uniqueSurfaces(
            [candidate.preferredLabel] + candidate.sourceForms
        )
        let candidateVectors = candidateSurfaces.compactMap { surface -> [Float]? in
            embedder.embed(surface)
        }
        guard !candidateVectors.isEmpty else {
            return SemanticTagIdentityResolution(kind: .pending, tag: nil)
        }

        let candidateSignature = SemanticTagNormalizer.qualifierSignature(
            label: candidate.preferredLabel,
            qualifiers: candidate.qualifiers
        )
        var rankings: [(tag: SemanticTag, similarity: Float)] = []

        for tag in try repository.activeTags() {
            let tagSignature = signature(for: tag)
            guard !candidateSignature.conflicts(with: tagSignature) else { continue }
            let aliases = uniqueAliases(for: tag)
            var best: Float = -1
            for alias in aliases {
                guard let vector = vector(for: alias) else { continue }
                for candidateVector in candidateVectors {
                    best = max(best, cosine(candidateVector, vector))
                }
            }
            if best >= 0 {
                rankings.append((tag, best))
            }
        }

        rankings.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.tag.id.uuidString < $1.tag.id.uuidString
        }
        if let winner = rankings.first, winner.similarity >= policy.minimumSimilarity {
            let runnerUpSimilarity = rankings.dropFirst().first?.similarity ?? -1
            if winner.similarity - runnerUpSimilarity >= policy.minimumWinnerMargin {
                try repository.attachAliases(from: candidate, to: winner.tag, at: date)
                return SemanticTagIdentityResolution(
                    kind: .semantic,
                    tag: winner.tag,
                    similarity: winner.similarity
                )
            }
        }

        let tag = try repository.createProvisionalTag(for: candidate, at: date)
        persistCandidateVectors(candidateSurfaces, on: tag)
        return SemanticTagIdentityResolution(kind: .provisional, tag: tag)
    }

    private func signature(for tag: SemanticTag) -> SemanticTagQualifierSignature {
        var values = decodedQualifierValues(tag.qualifierSignatureJSON)
        let displayValues = SemanticTagNormalizer.qualifierSignature(
            label: tag.preferredDisplayName,
            qualifiers: []
        ).hardValuesByKind
        for (kind, additions) in displayValues {
            values[kind, default: []].formUnion(additions)
        }
        for alias in tag.aliases {
            let aliasValues = SemanticTagNormalizer.qualifierSignature(
                label: alias.displayName,
                qualifiers: []
            ).hardValuesByKind
            for (kind, additions) in aliasValues {
                values[kind, default: []].formUnion(additions)
            }
        }
        return SemanticTagQualifierSignature(hardValuesByKind: values)
    }

    private func decodedQualifierValues(_ json: String) -> [String: Set<String>] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded.mapValues(Set.init)
    }

    private func uniqueAliases(for tag: SemanticTag) -> [SemanticTagAlias] {
        var seen = Set<String>()
        return tag.aliases.filter { seen.insert($0.aliasKey).inserted }
    }

    private func vector(for alias: SemanticTagAlias) -> [Float]? {
        if alias.embeddingVersion == embedder.embeddingVersion,
           let data = alias.embeddingData,
           let stored = try? JSONDecoder().decode([Float].self, from: data) {
            return stored
        }
        guard let generated = embedder.embed(alias.displayName) else { return nil }
        alias.embeddingData = try? JSONEncoder().encode(generated)
        alias.embeddingVersion = embedder.embeddingVersion
        return generated
    }

    private func persistCandidateVectors(_ surfaces: [String], on tag: SemanticTag) {
        let byKey = tag.aliases.reduce(into: [String: SemanticTagAlias]()) { result, alias in
            result[alias.aliasKey] = result[alias.aliasKey] ?? alias
        }
        for surface in surfaces {
            let key = SemanticTagNormalizer.aliasKey(surface)
            guard let alias = byKey[key], let vector = embedder.embed(surface) else { continue }
            alias.embeddingData = try? JSONEncoder().encode(vector)
            alias.embeddingVersion = embedder.embeddingVersion
        }
    }

    private func uniqueSurfaces(_ surfaces: [String]) -> [String] {
        var seen = Set<String>()
        return surfaces.filter {
            let key = SemanticTagNormalizer.aliasKey($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
