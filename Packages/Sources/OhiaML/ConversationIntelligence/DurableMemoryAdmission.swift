import Foundation
import OhiaCore

public enum MemoryAdmissionRejection: Sendable, Equatable {
    case episodicOrUnclassified
    case invalidKind
    case invalidFormationBasis
    case invalidUsePolicy
    case missingFutureUse
    case futureUseRepeatsStatement
    case missingExactEvidence
    case insufficientExplicitSupport
    case insufficientPatternBreadth
}

public enum MemoryAdmissionDecision: Sendable, Equatable {
    case accepted
    case rejected(reason: MemoryAdmissionRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Shared, deterministic definition gate for every memory scope. Dossier
/// identity affects later applicability and ranking, never what a memory is.
public enum DurableMemoryAdmission {
    public static func evaluate(
        candidate: ClaimCandidate,
        supportingMessageCount: Int,
        distinctThreadCount: Int
    ) -> MemoryAdmissionDecision {
        guard candidate.isEpisodic == false else {
            return .rejected(reason: .episodicOrUnclassified)
        }
        guard let kind = normalized(candidate.kindRaw),
              AccountMemoryKind.all.contains(kind) else {
            return .rejected(reason: .invalidKind)
        }
        guard let basis = normalized(candidate.formationBasisRaw),
              AccountMemoryFormationBasis.generated.contains(basis) else {
            return .rejected(reason: .invalidFormationBasis)
        }
        guard let policy = normalized(candidate.usePolicyRaw),
              AccountMemoryUsePolicy.all.contains(policy) else {
            return .rejected(reason: .invalidUsePolicy)
        }
        guard let futureUse = normalized(candidate.futureUseText) else {
            return .rejected(reason: .missingFutureUse)
        }
        if comparisonForm(futureUse) == comparisonForm(candidate.text) {
            return .rejected(reason: .futureUseRepeatsStatement)
        }
        guard supportingMessageCount > 0,
              candidate.evidenceSpans.contains(where: {
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return .rejected(reason: .missingExactEvidence)
        }

        switch basis {
        case AccountMemoryFormationBasis.repeatedPattern:
            guard candidate.support == .repeatedPattern,
                  supportingMessageCount >= 2,
                  distinctThreadCount >= 2 else {
                return .rejected(reason: .insufficientPatternBreadth)
            }
        case AccountMemoryFormationBasis.explicitStanding,
             AccountMemoryFormationBasis.explicitCorrection:
            guard candidate.support == .explicitlyStated else {
                return .rejected(reason: .insufficientExplicitSupport)
            }
        default:
            return .rejected(reason: .invalidFormationBasis)
        }

        return .accepted
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func comparisonForm(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
