import Foundation
import OhiaCore

/// Exact-biased literal search for the Constellation Search tab. Unlike
/// `HybridRetriever.retrieve` (dense + sparse RRF fusion → cross-encoder
/// rerank → MMR diversification, which Ask uses), this drives the FTS5
/// trigram index directly: literal hits surface first, BM25-ranked, never
/// culled by diversification. Semantic neighbors are computed separately and
/// returned demoted, for the weak / no-literal-match fallback.
///
/// The supplied `FilterSpec` is honoured by both lanes, so results respect
/// the active Constellation top-bar filter scope.
public final class LexicalSearchEngine: @unchecked Sendable {

    private let ftsIndex: MessageFTSIndex
    private let vectorStore: VectorStore
    private let registry: EmbedderRegistry
    private let dense: DenseRetriever

    public init(
        ftsIndex: MessageFTSIndex,
        vectorStore: VectorStore,
        registry: EmbedderRegistry
    ) {
        self.ftsIndex = ftsIndex
        self.vectorStore = vectorStore
        self.registry = registry
        self.dense = DenseRetriever(vectorStore: vectorStore, registry: registry)
    }

    public func search(
        query rawQuery: String,
        filter: FilterSpec,
        matchLimit: Int = 250,
        neighborLimit: Int = 8
    ) throws -> LexicalSearchResult {
        guard let query = LexicalQuery(rawQuery) else {
            return .empty(query: rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // ---- Literal (exact) lane ----
        let ftsMatches = try ftsIndex.literalMatches(
            matchExpression: query.ftsExpression,
            filter: filter,
            limit: matchLimit
        )
        let attachmentMatches = try ftsIndex.literalAttachmentMatches(
            matchExpression: query.ftsExpression,
            filter: filter,
            limit: matchLimit
        )
        let attachmentFilenamesByMessage = Dictionary(
            grouping: attachmentMatches,
            by: \.messageId
        ).mapValues { matches in
            Array(Set(matches.map(\.filename))).sorted()
        }
        let attachmentDescriptorsByMessage = Dictionary(
            grouping: attachmentMatches,
            by: \.messageId
        ).mapValues(Self.attachmentDescriptors)
        let exactTotal = try ftsIndex.literalCombinedMatchCount(
            matchExpression: query.ftsExpression,
            filter: filter
        )
        let rankedMessageIds = Array(
            ftsMatches.map(\.messageId) + attachmentMatches.map(\.messageId)
        )
        let representative = try vectorStore.representativeVectorIds(
            forMessageIds: rankedMessageIds,
            filter: filter
        )
        var matches: [LexicalSearchResult.Match] = []
        matches.reserveCapacity(rankedMessageIds.count)
        var seenExactMessageIds = Set<String>()
        for hit in ftsMatches {
            guard matches.count < matchLimit else { break }
            guard let vectorId = representative[hit.messageId] else { continue }
            let attachmentFilenames = attachmentFilenamesByMessage[hit.messageId] ?? []
            let attachmentDescriptors = attachmentDescriptorsByMessage[hit.messageId] ?? []
            seenExactMessageIds.insert(hit.messageId)
            matches.append(
                LexicalSearchResult.Match(
                    vectorId: vectorId,
                    messageId: hit.messageId,
                    subject: hit.subject,
                    senderEmail: hit.senderEmail,
                    receivedAt: hit.receivedAt,
                    matchedSubject: hit.columns.contains(.subject),
                    matchedBody: hit.columns.contains(.body),
                    matchedSender: hit.columns.contains(.sender),
                    matchedAttachment: !attachmentFilenames.isEmpty,
                    matchedAttachmentFilenames: attachmentFilenames,
                    matchedAttachmentDescriptors: attachmentDescriptors
                )
            )
        }
        for hit in attachmentMatches where !seenExactMessageIds.contains(hit.messageId) {
            guard matches.count < matchLimit else { break }
            guard let vectorId = representative[hit.messageId] else { continue }
            let attachmentFilenames = attachmentFilenamesByMessage[hit.messageId] ?? [hit.filename]
            let attachmentDescriptors = attachmentDescriptorsByMessage[hit.messageId] ?? [
                .init(
                    filename: hit.filename,
                    provenanceLabel: hit.provenanceLabel,
                    snippet: hit.snippet,
                    matchedFilename: hit.matchedFilename
                )
            ]
            seenExactMessageIds.insert(hit.messageId)
            matches.append(
                LexicalSearchResult.Match(
                    vectorId: vectorId,
                    messageId: hit.messageId,
                    subject: hit.subject,
                    senderEmail: hit.senderEmail,
                    receivedAt: hit.receivedAt,
                    matchedSubject: false,
                    matchedBody: false,
                    matchedSender: false,
                    matchedAttachment: true,
                    matchedAttachmentFilenames: attachmentFilenames,
                    matchedAttachmentDescriptors: attachmentDescriptors
                )
            )
        }

        // ---- Field + term breakdown ----
        let fieldSubject = try fieldCount(.subject, query: query, filter: filter)
        let fieldBody = try fieldCount(.body, query: query, filter: filter)
        let fieldSender = try fieldCount(.senderEmail, query: query, filter: filter)
        let fieldAttachment = try ftsIndex.literalAttachmentMatchCount(
            matchExpression: query.ftsExpression,
            filter: filter
        )

        var terms: [LexicalSearchResult.TermCount] = []
        // Only break down trigram-viable terms; shorter tokens cannot match
        // the trigram index, so a count would be a misleading zero.
        for term in query.displayTerms where term.count >= LexicalQuery.trigramMinimum {
            let count = (try? ftsIndex.literalCombinedMatchCount(
                matchExpression: LexicalQuery.phraseExpression(term),
                filter: filter
            )) ?? 0
            terms.append(LexicalSearchResult.TermCount(term: term, count: count))
        }

        var phrase: LexicalSearchResult.TermCount?
        if let phraseText = query.phraseText {
            let count = (try? ftsIndex.literalCombinedMatchCount(
                matchExpression: LexicalQuery.phraseExpression(phraseText),
                filter: filter
            )) ?? 0
            phrase = LexicalSearchResult.TermCount(term: phraseText, count: count)
        }

        // ---- Demoted semantic lane ----
        var semanticMatches: [LexicalSearchResult.Match] = []
        var topScore: Float?
        let semanticLaneAvailable: Bool
        if let queryVector = registry.current.embed(rawQuery) {
            semanticLaneAvailable = true
            // Dense retrieval ranks chunks, while Nearby presents messages.
            // Leave enough headroom for exact-message chunks and duplicate
            // chunks to be removed before applying the visible result limit.
            let semanticCandidateLimit = max(neighborLimit * 10, 100) + matches.count
            let scored = (try? dense.retrieveScored(
                queryVector: queryVector,
                filter: filter,
                k: semanticCandidateLimit
            )) ?? []
            let exactVectorIds = Set(matches.map(\.vectorId))
            let exactMessageIdsInRankOrder = matches.map(\.messageId)
            let exactMessageIds = Set(exactMessageIdsInRankOrder)
            var seenSemanticMessageIds = Set<String>()
            let affinityTerms = semanticAffinityTerms(
                forExactMessageIds: exactMessageIdsInRankOrder,
                query: query
            )
            let candidateIds = scored
                .filter { $0.score >= LexicalSearchResult.semanticNeighborDisplayThreshold }
                .map(\.id)
                .filter { !exactVectorIds.contains($0) }
            let recordsById = Dictionary(
                uniqueKeysWithValues: ((try? vectorStore.hydrate(vectorIds: candidateIds)) ?? [])
                    .map { ($0.vectorId, $0) }
            )
            let metadataByMessageId = (try? ftsIndex.metadata(
                forMessageIds: recordsById.values.map(\.messageId)
            )) ?? [:]

            for candidate in scored
                where candidate.score >= LexicalSearchResult.semanticNeighborDisplayThreshold
                    && !exactVectorIds.contains(candidate.id) {
                guard let record = recordsById[candidate.id] else { continue }
                guard !exactMessageIds.contains(record.messageId) else { continue }
                guard seenSemanticMessageIds.insert(record.messageId).inserted else { continue }
                guard let metadata = metadataByMessageId[record.messageId] else { continue }
                let semanticCue = Self.semanticCue(
                    from: record.textPayload,
                    query: query,
                    affinityTerms: affinityTerms
                )
                if topScore == nil { topScore = candidate.score }
                semanticMatches.append(
                    LexicalSearchResult.Match(
                        vectorId: candidate.id,
                        messageId: record.messageId,
                        subject: metadata.subject,
                        senderEmail: metadata.senderEmail,
                        receivedAt: metadata.receivedAt ?? record.messageReceivedAt,
                        matchedSubject: false,
                        matchedBody: false,
                        matchedSender: false,
                        semanticScore: candidate.score,
                        semanticCue: semanticCue
                    )
                )
                if semanticMatches.count >= neighborLimit { break }
            }
        } else {
            semanticLaneAvailable = false
        }

        return LexicalSearchResult(
            query: query.raw,
            isPhrase: query.isPhrase,
            exactMatches: matches,
            exactTotalCount: exactTotal,
            terms: terms,
            phrase: phrase,
            fieldSubject: fieldSubject,
            fieldBody: fieldBody,
            fieldSender: fieldSender,
            fieldAttachment: fieldAttachment,
            semanticMatches: semanticMatches,
            topSemanticScore: topScore,
            semanticLaneAvailable: semanticLaneAvailable
        )
    }

    /// The three indexed FTS columns. A closed set keeps the column-scope
    /// interpolation (`{column} : (...)`) free of any caller-supplied string.
    private enum FTSField: String {
        case subject
        case body
        case senderEmail = "sender_email"
    }

    private func fieldCount(_ field: FTSField, query: LexicalQuery, filter: FilterSpec) throws -> Int {
        try ftsIndex.literalMatchCount(
            matchExpression: "{\(field.rawValue)} : (\(query.ftsExpression))",
            filter: filter
        )
    }

    private static func attachmentDescriptors(
        from matches: [FTSAttachmentMatch]
    ) -> [LexicalSearchResult.Match.AttachmentDescriptor] {
        var seen = Set<String>()
        return matches.compactMap { match in
            let key = [match.filename, match.provenanceLabel, match.snippet].joined(separator: "\u{1f}")
            guard seen.insert(key).inserted else { return nil }
            return LexicalSearchResult.Match.AttachmentDescriptor(
                filename: match.filename,
                provenanceLabel: match.provenanceLabel,
                snippet: match.snippet,
                matchedFilename: match.matchedFilename
            )
        }
    }

    private struct SemanticCueToken {
        let display: String
        let normalized: String
    }

    private func semanticAffinityTerms(
        forExactMessageIds messageIds: [String],
        query: LexicalQuery
    ) -> Set<String> {
        guard !messageIds.isEmpty else { return [] }
        var records: [VectorRecord] = []
        var seen = Set<String>()
        for messageId in messageIds where seen.insert(messageId).inserted {
            guard records.count < Self.semanticAffinityRecordLimit,
                  let messageRecords = try? vectorStore.vectorsForMessage(messageId: messageId) else { continue }
            records.append(contentsOf: messageRecords.filter { record in
                record.collection == .context || record.collection == .attachment
            })
        }
        return Self.semanticAffinityTerms(from: records, query: query)
    }

    private static func semanticCue(
        from textPayload: String,
        query: LexicalQuery,
        affinityTerms: Set<String>
    ) -> String? {
        let queryTokens = Set(cueTokens(in: query.raw).map { cueStem($0.normalized) })
        let fields = parseCueFields(textPayload)
        let queryBearingKeys = [
            "topics",
            "topiclabels",
            "projects",
            "projectlabels",
            "teams",
            "teamlabels",
            "body_preview",
            "attachment_text",
            "subject",
            "attachments",
            "attachment",
            "body"
        ]
        if !queryTokens.isEmpty {
            for key in queryBearingKeys {
                guard let value = fields[key],
                      fieldContainsQueryToken(value, queryTokens: queryTokens),
                      let cue = semanticCueCandidate(
                        from: value,
                        queryTokens: queryTokens,
                        affinityTerms: affinityTerms
                      ) else { continue }
                return cue
            }
            if fieldContainsQueryToken(textPayload, queryTokens: queryTokens),
               let cue = semanticCueCandidate(
                from: textPayload,
                queryTokens: queryTokens,
                affinityTerms: affinityTerms
               ) {
                return cue
            }
        }

        guard !affinityTerms.isEmpty else { return nil }
        for key in queryBearingKeys {
            guard let value = fields[key],
                  let cue = semanticCueCandidate(
                    from: value,
                    queryTokens: queryTokens,
                    affinityTerms: affinityTerms
                  ) else { continue }
            return cue
        }
        return semanticCueCandidate(
            from: textPayload,
            queryTokens: queryTokens,
            affinityTerms: affinityTerms
        )
    }

    private static func parseCueFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            let rawKey = String(rawLine[..<separator])
            let valueStart = rawLine.index(after: separator)
            let value = String(rawLine[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    private static func fieldContainsQueryToken(_ raw: String, queryTokens: Set<String>) -> Bool {
        cueTokens(in: raw).contains { queryTokens.contains(cueStem($0.normalized)) }
    }

    private static func semanticCueCandidate(
        from raw: String,
        queryTokens: Set<String>,
        affinityTerms: Set<String>
    ) -> String? {
        let tokens = cueTokens(in: raw)
        guard !tokens.isEmpty else { return nil }

        if let anchor = tokens.firstIndex(where: { queryTokens.contains(cueStem($0.normalized)) }) {
            var selected = tokens
                .dropFirst(anchor + 1)
                .filter { token in
                    !queryTokens.contains(cueStem(token.normalized)) && !isLowSignalCueToken(token)
                }
                .prefix(4)
                .map(\.self)
            if selected.count < 4 {
                let before = tokens
                    .prefix(anchor)
                    .filter { token in
                        !queryTokens.contains(cueStem(token.normalized)) && !isLowSignalCueToken(token)
                    }
                    .suffix(4 - selected.count)
                selected.insert(contentsOf: before, at: 0)
            }
            if let phrase = cuePhrase(selected) {
                return phrase
            }
        }

        guard !affinityTerms.isEmpty,
              let anchor = tokens.firstIndex(where: { affinityTerms.contains(cueStem($0.normalized)) }) else {
            return nil
        }
        var selected = tokens
            .dropFirst(anchor)
            .filter { token in
                !queryTokens.contains(cueStem(token.normalized)) && !isLowSignalCueToken(token)
            }
            .prefix(4)
            .map(\.self)
        if selected.count < 2 {
            let before = tokens
                .prefix(anchor)
                .filter { token in
                    !queryTokens.contains(cueStem(token.normalized)) && !isLowSignalCueToken(token)
                }
                .suffix(2 - selected.count)
            selected.insert(contentsOf: before, at: 0)
        }
        return cuePhrase(selected)
    }

    private static func cuePhrase(_ tokens: [SemanticCueToken]) -> String? {
        let phrase = tokens.map(\.display).joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    private static func cueTokens(in raw: String) -> [SemanticCueToken] {
        raw.split { character in
            character.isLetter == false && character.isNumber == false
        }
        .compactMap { rawToken -> SemanticCueToken? in
            let display = String(rawToken)
            let normalized = display.lowercased()
            guard normalized.count >= 3,
                  normalized.allSatisfy(\.isNumber) == false,
                  !cueStopWords.contains(normalized) else { return nil }
            return SemanticCueToken(display: display, normalized: normalized)
        }
    }

    private static func semanticAffinityTerms(from records: [VectorRecord], query: LexicalQuery) -> Set<String> {
        let queryTokens = Set(cueTokens(in: query.raw).map { cueStem($0.normalized) })
        guard !queryTokens.isEmpty else { return [] }

        var scores: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var ordinal = 0
        for record in records.prefix(semanticAffinityRecordLimit) {
            let tokens = cueTokens(in: record.textPayload)
            guard !tokens.isEmpty else { continue }

            for (index, token) in tokens.enumerated() where queryTokens.contains(cueStem(token.normalized)) {
                let lower = Swift.max(tokens.startIndex, index - semanticAffinityContextWindow)
                let upper = Swift.min(tokens.endIndex - 1, index + semanticAffinityContextWindow)
                for candidateIndex in lower...upper where candidateIndex != index {
                    let candidate = tokens[candidateIndex]
                    let stem = cueStem(candidate.normalized)
                    guard !queryTokens.contains(stem),
                          !isLowSignalCueToken(candidate),
                          !cueStopWords.contains(stem) else { continue }
                    let distance = abs(candidateIndex - index)
                    let score = semanticAffinityContextWindow + 1 - distance
                    guard score >= semanticAffinityMinimumTermScore else { continue }
                    scores[stem, default: 0] += score
                    if firstSeen[stem] == nil {
                        firstSeen[stem] = ordinal
                        ordinal += 1
                    }
                }
            }
        }

        return Set(
            scores
                .filter { $0.value >= semanticAffinityMinimumTotalScore }
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return (firstSeen[lhs.key] ?? Int.max) < (firstSeen[rhs.key] ?? Int.max)
                    }
                    return lhs.value > rhs.value
                }
                .prefix(semanticAffinityTermLimit)
                .map(\.key)
        )
    }

    private static func isLowSignalCueToken(_ token: SemanticCueToken) -> Bool {
        cueLowSignalTerms.contains(token.normalized)
            || cueLowSignalTerms.contains(cueStem(token.normalized))
    }

    private static func cueStem(_ normalized: String) -> String {
        guard normalized.count > 3 else { return normalized }
        if normalized.count > 4, normalized.hasSuffix("ies") {
            return String(normalized.dropLast(3)) + "y"
        }
        if normalized.count > 4, normalized.hasSuffix("es"), !normalized.hasSuffix("ses") {
            return String(normalized.dropLast(2))
        }
        if normalized.hasSuffix("s"), !normalized.hasSuffix("ss") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    private static let cueStopWords: Set<String> = [
        "and", "are", "about", "after", "also", "attachment", "attachments",
        "because", "before", "between", "body", "bucket", "can", "com", "date", "day",
        "days", "content", "could", "email", "every", "final", "from", "for", "front", "has", "have",
        "how", "http", "https", "into", "its", "kind", "language", "look", "message",
        "not", "preview", "received", "report", "right", "should", "size", "subject",
        "that", "the", "this", "through", "type",
        "with", "you", "your", "confirmation", "confirm", "confirmed", "follow",
        "followup", "intent", "proposal", "question", "request", "response", "visit",
        "what", "when", "where", "who", "why", "would", "www"
    ]

    private static let cueLowSignalTerms: Set<String> = [
        "attachment", "attachments", "file", "files", "heic", "image", "img",
        "jpeg", "jpg", "pdf", "png", "qui", "screenshot", "scan", "tiff"
    ]

    private static let semanticAffinityContextWindow = 4
    private static let semanticAffinityMinimumTermScore = 2
    private static let semanticAffinityMinimumTotalScore = 5
    private static let semanticAffinityRecordLimit = 64
    private static let semanticAffinityTermLimit = 24
}
