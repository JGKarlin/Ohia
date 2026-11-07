import Foundation
import OhiaCore

/// Per-message structured output of the Conversation Memory extraction pass.
/// Persisted on `MessageAnalysis.discourseMemoryJSON` as a JSON-encoded
/// `DiscourseMemory`. Produced first by `SeedFromMetadata` (deterministic,
/// synchronous, never empty if any analyzer field exists) and then refined
/// in place by `DiscourseExtractor` via the Qwen/Apple Foundation LLM path.
///
/// The schema is closed: every consumer (extractors, snapshot, Ask packer,
/// curation, tests) reads from these fields directly.
public struct DiscourseMemory: Codable, Sendable, Equatable {
    public var discourseMoves: [DiscourseMove]
    public var ibisRoles: [IBISRoleAssignment]
    public var claimCandidates: [ClaimCandidate]
    public var decisionCandidates: [DecisionCandidate]
    public var precedentSignals: [PrecedentSignal]
    public var tacitRuleSignals: [TacitRuleSignal]
    public var contradictionSignals: [ContradictionSignal]
    public var supersessionSignals: [SupersessionSignal]
    public var scopeHints: [ScopeHint]
    public var uncertainties: [Uncertainty]
    /// Stable version tag, e.g. `seed-v1` from `SeedFromMetadata` alone,
    /// `qwen-discourse-v1` after the LLM pass has run. Curation keys
    /// capture this so user verdicts can survive a version bump.
    public var extractionVersion: String
    public var threadFingerprint: String?

    public init(
        discourseMoves: [DiscourseMove] = [],
        ibisRoles: [IBISRoleAssignment] = [],
        claimCandidates: [ClaimCandidate] = [],
        decisionCandidates: [DecisionCandidate] = [],
        precedentSignals: [PrecedentSignal] = [],
        tacitRuleSignals: [TacitRuleSignal] = [],
        contradictionSignals: [ContradictionSignal] = [],
        supersessionSignals: [SupersessionSignal] = [],
        scopeHints: [ScopeHint] = [],
        uncertainties: [Uncertainty] = [],
        extractionVersion: String,
        threadFingerprint: String? = nil
    ) {
        self.discourseMoves = discourseMoves
        self.ibisRoles = ibisRoles
        self.claimCandidates = claimCandidates
        self.decisionCandidates = decisionCandidates
        self.precedentSignals = precedentSignals
        self.tacitRuleSignals = tacitRuleSignals
        self.contradictionSignals = contradictionSignals
        self.supersessionSignals = supersessionSignals
        self.scopeHints = scopeHints
        self.uncertainties = uncertainties
        self.extractionVersion = extractionVersion
        self.threadFingerprint = threadFingerprint
    }

    public static let seedVersion = "seed-v1"
    public static let qwenVersion = "qwen-discourse-v1"
    public static let threadVersion = "thread-discourse-durable-memory-v2"

    public static let empty = DiscourseMemory(extractionVersion: seedVersion)

    public var isEmpty: Bool {
        discourseMoves.isEmpty
            && ibisRoles.isEmpty
            && claimCandidates.isEmpty
            && decisionCandidates.isEmpty
            && precedentSignals.isEmpty
            && tacitRuleSignals.isEmpty
            && contradictionSignals.isEmpty
            && supersessionSignals.isEmpty
            && scopeHints.isEmpty
            && uncertainties.isEmpty
    }

    /// Round-trip helper: encode to compact JSON for `MessageAnalysis.discourseMemoryJSON`.
    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DiscourseMemoryCodingError.invalidUTF8
        }
        return string
    }

    public static func decode(_ json: String) throws -> DiscourseMemory {
        guard let data = json.data(using: .utf8) else {
            throw DiscourseMemoryCodingError.invalidUTF8
        }
        return try JSONDecoder().decode(DiscourseMemory.self, from: data)
    }
}

public enum DiscourseMemoryCodingError: Error, Sendable {
    case invalidUTF8
}

/// Level of evidential support for an extracted item. Only the first three
/// are eligible to become candidates; weakly-inferred items must flow into
/// `DiscourseMemory.uncertainties` so the UI surfaces them as review items
/// rather than presenting them as memory.
public enum SupportLevel: String, Codable, Sendable, CaseIterable, Equatable {
    case explicitlyStated
    case stronglyImplied
    case repeatedPattern
    case weaklyInferred
    case notSupported

    public var qualifiesAsCandidate: Bool {
        switch self {
        case .explicitlyStated, .stronglyImplied, .repeatedPattern:
            return true
        case .weaklyInferred, .notSupported:
            return false
        }
    }
}
