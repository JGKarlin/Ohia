import Foundation
import OhiaCore
import SwiftData

public enum SemanticTagResolutionWorkerResult: Sendable, Equatable {
    case resolved
    case alreadyResolved
    case pendingEmbedding
    case invalidated
    case missingObservation
}

@MainActor
public final class SemanticTagResolutionWorker {
    private let context: ModelContext
    private let resolver: SemanticTagIdentityResolver

    public init(context: ModelContext, resolver: SemanticTagIdentityResolver) {
        self.context = context
        self.resolver = resolver
    }

    public func run(observationID: UUID, at date: Date = .now) throws -> SemanticTagResolutionWorkerResult {
        var descriptor = FetchDescriptor(
            predicate: #Predicate<SemanticTagObservation> { $0.id == observationID }
        )
        descriptor.fetchLimit = 1
        guard let observation = try context.fetch(descriptor).first else {
            return .missingObservation
        }
        guard observation.state == .pending else {
            return observation.state == .resolved ? .alreadyResolved : .invalidated
        }
        guard let message = observation.message else {
            observation.state = .invalid
            observation.invalidReason = "message-deleted"
            observation.resolvedAt = date
            try context.save()
            return .invalidated
        }
        guard let data = observation.candidateJSON.data(using: .utf8),
              let candidate = try? JSONDecoder().decode(SemanticTagCandidate.self, from: data) else {
            observation.state = .invalid
            observation.invalidReason = "malformed-candidate"
            observation.resolvedAt = date
            try context.save()
            return .invalidated
        }

        let repository = SemanticTagRepository(context: context)
        let resolution = try resolver.resolve(
            candidate: candidate,
            repository: repository,
            at: date
        )
        guard let tag = resolution.tag else {
            return .pendingEmbedding
        }

        _ = try repository.upsertMembership(
            message: message,
            tag: tag,
            candidate: candidate,
            observation: observation,
            evidenceJSON: "{}",
            at: date
        )
        try removeBroaderMemberships(
            from: message,
            resolvedTagID: tag.id,
            qualifiedCandidate: candidate
        )
        _ = try repository.promoteIfEligible(tag, at: date)
        try repository.rewriteProjection(for: message)
        try context.save()
        return .resolved
    }

    private func removeBroaderMemberships(
        from message: Message,
        resolvedTagID: UUID,
        qualifiedCandidate: SemanticTagCandidate
    ) throws {
        let specificSignature = SemanticTagNormalizer.qualifierSignature(
            label: qualifiedCandidate.preferredLabel,
            qualifiers: qualifiedCandidate.qualifiers
        )
        guard !specificSignature.hardValuesByKind.isEmpty else { return }

        let specificForms = [qualifiedCandidate.preferredLabel] + qualifiedCandidate.sourceForms
        let messageID = message.id
        let memberships = try context.fetch(FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { $0.messageID == messageID }
        ))
        for membership in memberships where membership.tagID != resolvedTagID {
            guard let broadTag = membership.tag else { continue }
            let broadSignature = SemanticTagNormalizer.qualifierSignature(
                label: broadTag.preferredDisplayName,
                qualifiers: []
            )
            guard !specificSignature.conflicts(with: broadSignature) else { continue }
            let broadForms = [broadTag.preferredDisplayName] + broadTag.aliases.map(\.displayName)
            if broadForms.contains(where: { broad in
                specificForms.contains(where: { specific in isStrictBroadForm(broad, of: specific) })
            }) {
                context.delete(membership)
            }
        }
    }

    private func isStrictBroadForm(_ broad: String, of specific: String) -> Bool {
        let broadText = SemanticTagNormalizer.normalizedText(broad)
        let specificText = SemanticTagNormalizer.normalizedText(specific)
        guard !broadText.isEmpty, broadText != specificText else { return false }
        let broadTokens = Set(broadText.split(separator: " ").map(String.init))
        let specificTokens = Set(specificText.split(separator: " ").map(String.init))
        if broadTokens.isStrictSubset(of: specificTokens) { return true }
        let compactBroad = broadText.replacingOccurrences(of: " ", with: "")
        let compactSpecific = specificText.replacingOccurrences(of: " ", with: "")
        return compactSpecific.contains(compactBroad) && compactSpecific.count > compactBroad.count
    }
}
