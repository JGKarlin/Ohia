import Foundation
import OhiaCore

/// Builds the typed Ask-time context packet used by `ConstellationAskTab`
/// when the active lens is `.conversations`. The packer carries claims,
/// contradictions, supersessions, precedents, open loops, and explicit
/// citation candidates so the Qwen prompt template can cite underlying
/// message IDs (rendered via `CitationParser`) rather than just claim
/// cards. Per §9 / §12 of the implementation plan, verification asserts
/// Ask answers from the lens contain message-level citations.
public struct AskContextPacker: Sendable {
    public struct Configuration: Sendable {
        public let topClaimCount: Int
        public let topPrecedentCount: Int
        public let openLoopCount: Int
        public let citationCount: Int

        public init(
            topClaimCount: Int = 24,
            topPrecedentCount: Int = 10,
            openLoopCount: Int = 16,
            citationCount: Int = 40
        ) {
            self.topClaimCount = topClaimCount
            self.topPrecedentCount = topPrecedentCount
            self.openLoopCount = openLoopCount
            self.citationCount = citationCount
        }
        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Build a packet for the given snapshot. The `coverage` argument
    /// flows from `ConversationsSnapshot.coverage`; the packet flags
    /// `incomplete` whenever the snapshot is still extracting so the Ask
    /// UI can render a "provisional" indicator.
    public func pack(input: AskContextInput) -> ConversationMemoryAskContext {
        let confirmedFirst: (KnowledgeClaim, KnowledgeClaim) -> Bool = { lhs, rhs in
            // Confirmed claims rank above unconfirmed, then by weight.
            let lhsConfirmed = lhs.status.userConfirmation == .confirmed
            let rhsConfirmed = rhs.status.userConfirmation == .confirmed
            if lhsConfirmed != rhsConfirmed { return lhsConfirmed }
            return lhs.weight > rhs.weight
        }

        // Sensitivity gate: sensitive claims are excluded until the user
        // has explicitly confirmed them.
        let eligibleClaims = input.claims.filter { claim in
            switch claim.status.sensitivityRisk {
            case .none, .low:
                return claim.status.userConfirmation != .rejected
                    && claim.status.userConfirmation != .markedStale
            case .elevated, .high:
                return claim.status.userConfirmation == .confirmed
            }
        }

        let topClaims = Array(eligibleClaims.sorted(by: confirmedFirst).prefix(configuration.topClaimCount))
        let precedents = Array(
            input.precedents
                .sorted { $0.applicabilityScore > $1.applicabilityScore }
                .prefix(configuration.topPrecedentCount)
        )
        let openLoops = Array(input.openLoops.prefix(configuration.openLoopCount))

        var citationsByMessage: [UUID: CitationCandidate] = [:]
        for claim in topClaims {
            for link in claim.evidenceLinks {
                if citationsByMessage[link.messageID] == nil {
                    citationsByMessage[link.messageID] = CitationCandidate(
                        messageID: link.messageID,
                        claimKey: claim.key,
                        fieldSource: link.fieldSource,
                        span: link.span,
                        confidence: link.confidence
                    )
                }
            }
        }
        for precedent in precedents {
            for link in precedent.evidenceLinks {
                if citationsByMessage[link.messageID] == nil {
                    citationsByMessage[link.messageID] = CitationCandidate(
                        messageID: link.messageID,
                        claimKey: precedent.key,
                        fieldSource: link.fieldSource,
                        span: link.span,
                        confidence: link.confidence
                    )
                }
            }
        }
        let citations = Array(citationsByMessage.values.prefix(configuration.citationCount))

        let isIncomplete: Bool
        switch input.coverage {
        case .complete, .failed:
            isIncomplete = false
        case .seeded, .extracting, .partial:
            isIncomplete = true
        }

        return ConversationMemoryAskContext(
            topClaims: topClaims,
            contradictions: input.contradictions,
            supersessions: input.supersessions,
            precedents: precedents,
            openLoops: openLoops,
            citations: citations,
            sensitivityFilter: input.sensitivityFilter,
            incomplete: isIncomplete,
            coverage: input.coverage
        )
    }
}

public struct AskContextInput: Sendable {
    public let claims: [KnowledgeClaim]
    public let contradictions: [ContradictionLink]
    public let supersessions: [SupersessionRecord]
    public let precedents: [Precedent]
    public let openLoops: [OpenLoopRow]
    public let sensitivityFilter: SensitivityVerdict
    public let coverage: ConversationMemoryCoverage

    public init(
        claims: [KnowledgeClaim],
        contradictions: [ContradictionLink],
        supersessions: [SupersessionRecord],
        precedents: [Precedent],
        openLoops: [OpenLoopRow],
        sensitivityFilter: SensitivityVerdict,
        coverage: ConversationMemoryCoverage
    ) {
        self.claims = claims
        self.contradictions = contradictions
        self.supersessions = supersessions
        self.precedents = precedents
        self.openLoops = openLoops
        self.sensitivityFilter = sensitivityFilter
        self.coverage = coverage
    }
}

/// Typed context packet handed to the Ask LLM prompt.
public struct ConversationMemoryAskContext: Sendable {
    public let topClaims: [KnowledgeClaim]
    public let contradictions: [ContradictionLink]
    public let supersessions: [SupersessionRecord]
    public let precedents: [Precedent]
    public let openLoops: [OpenLoopRow]
    public let citations: [CitationCandidate]
    public let sensitivityFilter: SensitivityVerdict
    public let incomplete: Bool
    public let coverage: ConversationMemoryCoverage

    public init(
        topClaims: [KnowledgeClaim],
        contradictions: [ContradictionLink],
        supersessions: [SupersessionRecord],
        precedents: [Precedent],
        openLoops: [OpenLoopRow],
        citations: [CitationCandidate],
        sensitivityFilter: SensitivityVerdict,
        incomplete: Bool,
        coverage: ConversationMemoryCoverage
    ) {
        self.topClaims = topClaims
        self.contradictions = contradictions
        self.supersessions = supersessions
        self.precedents = precedents
        self.openLoops = openLoops
        self.citations = citations
        self.sensitivityFilter = sensitivityFilter
        self.incomplete = incomplete
        self.coverage = coverage
    }

    public var messageIDsForCitation: [UUID] {
        citations.map(\.messageID)
    }
}

public struct CitationCandidate: Sendable, Equatable, Hashable {
    public let messageID: UUID
    public let claimKey: String
    public let fieldSource: DiscourseSourceField
    public let span: DiscourseEvidenceSpan?
    public let confidence: Double

    public init(
        messageID: UUID,
        claimKey: String,
        fieldSource: DiscourseSourceField,
        span: DiscourseEvidenceSpan?,
        confidence: Double
    ) {
        self.messageID = messageID
        self.claimKey = claimKey
        self.fieldSource = fieldSource
        self.span = span
        self.confidence = confidence
    }
}

/// Coverage state of a `ConversationsSnapshot`. Lives in the OhiaML
/// layer so extractors and packers can reason about it without an app
/// dependency.
public enum ConversationMemoryCoverage: Sendable, Equatable, Hashable {
    case seeded
    case extracting
    case partial
    case complete
    case failed(reason: String)
}
