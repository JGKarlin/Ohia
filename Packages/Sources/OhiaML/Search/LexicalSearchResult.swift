import Foundation
import OhiaCore

/// Result of an exact-biased literal search over the constellation's active
/// filter scope. Distinct from Ask: there is no synthesized answer and no
/// MMR-diversified semantic blend — `exactMatches` are literal FTS hits in
/// BM25 order, and the semantic neighbors are a clearly-demoted fallback for
/// when the term is weak or absent.
///
/// Deliberately structural: it carries no message *body* text. The app layer
/// adds display polish (cluster labels, sender display names) and the
/// constellation scene remains the place to inspect content.
public enum LexicalSearchLane: String, Sendable, Equatable {
    case exact
    case semantic
}

public struct LexicalSearchResult: Sendable, Equatable {

    /// One literal hit, mapped to a representative node for camera warp.
    public struct Match: Sendable, Equatable {
        public struct AttachmentDescriptor: Sendable, Equatable {
            public let filename: String
            public let provenanceLabel: String
            public let snippet: String?
            public let matchedFilename: Bool

            public init(
                filename: String,
                provenanceLabel: String,
                snippet: String? = nil,
                matchedFilename: Bool = false
            ) {
                self.filename = filename
                self.provenanceLabel = provenanceLabel
                self.snippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? snippet
                    : nil
                self.matchedFilename = matchedFilename
            }
        }

        public let vectorId: Int64
        public let messageId: String
        public let subject: String?
        public let senderEmail: String
        public let receivedAt: TimeInterval?
        public let matchedSubject: Bool
        public let matchedBody: Bool
        public let matchedSender: Bool
        public let matchedAttachment: Bool
        public let matchedAttachmentFilenames: [String]
        public let matchedAttachmentDescriptors: [AttachmentDescriptor]
        public let semanticScore: Float?
        public let semanticCue: String?

        public init(
            vectorId: Int64,
            messageId: String,
            subject: String? = nil,
            senderEmail: String,
            receivedAt: TimeInterval?,
            matchedSubject: Bool,
            matchedBody: Bool,
            matchedSender: Bool,
            matchedAttachment: Bool = false,
            matchedAttachmentFilenames: [String] = [],
            matchedAttachmentDescriptors: [AttachmentDescriptor] = [],
            semanticScore: Float? = nil,
            semanticCue: String? = nil
        ) {
            self.vectorId = vectorId
            self.messageId = messageId
            self.subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? subject
                : nil
            self.senderEmail = senderEmail
            self.receivedAt = receivedAt
            self.matchedSubject = matchedSubject
            self.matchedBody = matchedBody
            self.matchedSender = matchedSender
            self.matchedAttachment = matchedAttachment
            self.matchedAttachmentFilenames = matchedAttachmentFilenames
            self.matchedAttachmentDescriptors = matchedAttachmentDescriptors
            self.semanticScore = semanticScore
            let cleanedSemanticCue = semanticCue?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.semanticCue = cleanedSemanticCue?.isEmpty == false ? cleanedSemanticCue : nil
        }
    }

    public struct TermCount: Sendable, Equatable {
        public let term: String
        public let count: Int
        public init(term: String, count: Int) {
            self.term = term
            self.count = count
        }
    }

    public let query: String
    public let isPhrase: Bool
    /// Literal hits in BM25 order, capped at the engine's match limit.
    public let exactMatches: [Match]
    /// Total distinct messages matching the literal query (unbounded by the
    /// match-list cap), for the honest headline count.
    public let exactTotalCount: Int
    public let terms: [TermCount]
    /// Contiguous-phrase count in terms-mode (nil otherwise).
    public let phrase: TermCount?
    public let fieldSubject: Int
    public let fieldBody: Int
    public let fieldSender: Int
    public let fieldAttachment: Int
    /// Demoted semantic neighbors (excluded from the exact set).
    public let semanticMatches: [Match]
    public let topSemanticScore: Float?
    /// False when the current embedder cannot produce a query vector yet.
    public let semanticLaneAvailable: Bool

    public init(
        query: String,
        isPhrase: Bool,
        exactMatches: [Match],
        exactTotalCount: Int,
        terms: [TermCount],
        phrase: TermCount?,
        fieldSubject: Int,
        fieldBody: Int,
        fieldSender: Int,
        fieldAttachment: Int = 0,
        semanticMatches: [Match],
        topSemanticScore: Float?,
        semanticLaneAvailable: Bool
    ) {
        self.query = query
        self.isPhrase = isPhrase
        self.exactMatches = exactMatches
        self.exactTotalCount = exactTotalCount
        self.terms = terms
        self.phrase = phrase
        self.fieldSubject = fieldSubject
        self.fieldBody = fieldBody
        self.fieldSender = fieldSender
        self.fieldAttachment = fieldAttachment
        self.semanticMatches = semanticMatches
        self.topSemanticScore = topSemanticScore
        self.semanticLaneAvailable = semanticLaneAvailable
    }

    public var hasExactMatches: Bool { !exactMatches.isEmpty }
    public var hasSemanticMatches: Bool { !semanticMatches.isEmpty }

    public var defaultLane: LexicalSearchLane? {
        if hasExactMatches { return .exact }
        if hasSemanticMatches { return .semantic }
        return nil
    }

    public func matches(for lane: LexicalSearchLane?) -> [Match] {
        switch lane {
        case .exact:
            return exactMatches
        case .semantic:
            return semanticMatches
        case nil:
            return []
        }
    }

    public func laneIsSelectable(_ lane: LexicalSearchLane) -> Bool {
        switch lane {
        case .exact:
            return hasExactMatches
        case .semantic:
            return semanticLaneAvailable && hasSemanticMatches
        }
    }

    /// Similarity below which the nearest neighbors are flagged "weak" — a
    /// near-miss embedding result the user should not mistake for a real hit.
    public static let weakNeighborThreshold: Float = 0.35

    /// Minimum similarity required to expose dense-only search neighbors. Lower
    /// scores routinely look plausible while being unrelated for short rare
    /// queries, so the Search tab hides them instead of presenting false
    /// "nearby" evidence.
    public static let semanticNeighborDisplayThreshold: Float = 0.70

    public var weakSemantic: Bool {
        guard let top = topSemanticScore else { return semanticMatches.isEmpty }
        return top < Self.weakNeighborThreshold
    }

    public static func empty(query: String) -> LexicalSearchResult {
        LexicalSearchResult(
            query: query,
            isPhrase: false,
            exactMatches: [],
            exactTotalCount: 0,
            terms: [],
            phrase: nil,
            fieldSubject: 0,
            fieldBody: 0,
            fieldSender: 0,
            fieldAttachment: 0,
            semanticMatches: [],
            topSemanticScore: nil,
            semanticLaneAvailable: false
        )
    }
}
