import Foundation
import OhiaCore
import SwiftData

public enum SemanticTagRepositoryError: Error, Equatable {
    case redirectCycle
    case missingAnalysis
    case invalidDimensions
}

@MainActor
public final class SemanticTagRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func exactTag(matching candidate: SemanticTagCandidate) throws -> SemanticTag? {
        try exactTags(matching: candidate).first
    }

    public func exactTags(matching candidate: SemanticTagCandidate) throws -> [SemanticTag] {
        let candidateKeys = Set(
            ([candidate.preferredLabel] + candidate.sourceForms)
                .map(SemanticTagNormalizer.aliasKey)
                .filter { !$0.isEmpty }
        )
        guard !candidateKeys.isEmpty else { return [] }
        let candidateSignature = SemanticTagNormalizer.qualifierSignature(
            label: candidate.preferredLabel,
            qualifiers: candidate.qualifiers
        )

        var aliases: [SemanticTagAlias] = []
        for key in candidateKeys {
            aliases.append(contentsOf: try context.fetch(FetchDescriptor(
                predicate: #Predicate<SemanticTagAlias> { $0.aliasKey == key }
            )))
        }
        var seenTagIDs = Set<UUID>()
        var matches: [SemanticTag] = []
        for alias in aliases where candidateKeys.contains(alias.aliasKey) {
            guard let tagID = alias.tag?.id else { continue }
            if let resolved = try resolvedTag(id: tagID),
               candidateSignature.conflicts(with: qualifierSignature(for: resolved)) == false,
               seenTagIDs.insert(resolved.id).inserted {
                matches.append(resolved)
            }
        }
        return matches.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func activeTags() throws -> [SemanticTag] {
        let merged = SemanticTagLifecycle.merged.rawValue
        return try context.fetch(FetchDescriptor(
            predicate: #Predicate<SemanticTag> { $0.lifecycleRaw != merged }
        ))
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func attachAliases(
        from candidate: SemanticTagCandidate,
        to tag: SemanticTag,
        at date: Date = .now
    ) throws {
        let resolved = try resolvedTag(id: tag.id) ?? tag
        var seenKeys = Set<String>()
        for displayName in [candidate.preferredLabel] + candidate.sourceForms {
            let key = SemanticTagNormalizer.aliasKey(displayName)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            let aliases = try context.fetch(FetchDescriptor(
                predicate: #Predicate<SemanticTagAlias> { $0.aliasKey == key }
            ))
            if let existing = aliases.first(where: { $0.tag?.id == resolved.id }) {
                existing.lastObservedAt = max(existing.lastObservedAt, date)
                continue
            }
            let alias = SemanticTagAlias(
                tag: resolved,
                displayName: displayName,
                normalizedText: SemanticTagNormalizer.normalizedText(displayName),
                aliasKey: key,
                firstObservedAt: date,
                lastObservedAt: date
            )
            context.insert(alias)
        }
    }

    public func createProvisionalTag(
        for candidate: SemanticTagCandidate,
        at date: Date = .now
    ) throws -> SemanticTag {
        if let existing = try exactTag(matching: candidate) {
            return existing
        }

        let normalizedIdentity = SemanticTagNormalizer.aliasKey(candidate.preferredLabel)
        let tag = SemanticTag(
            preferredDisplayName: candidate.preferredLabel,
            normalizedIdentity: normalizedIdentity,
            qualifierSignatureJSON: try encodeQualifierSignature(candidate),
            firstObservedAt: date,
            updatedAt: date
        )
        context.insert(tag)

        var seenKeys = Set<String>()
        for displayName in [candidate.preferredLabel] + candidate.sourceForms {
            let key = SemanticTagNormalizer.aliasKey(displayName)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            context.insert(SemanticTagAlias(
                tag: tag,
                displayName: displayName,
                normalizedText: SemanticTagNormalizer.normalizedText(displayName),
                aliasKey: key,
                firstObservedAt: date,
                lastObservedAt: date
            ))
        }
        return tag
    }

    @discardableResult
    public func persistObservation(
        message: Message,
        candidate: SemanticTagCandidate,
        extractionVersion: String,
        at date: Date = .now
    ) throws -> SemanticTagObservation {
        let fingerprint = SemanticTagNormalizer.observationFingerprint(
            message: message,
            candidate: candidate,
            extractionVersion: extractionVersion
        )
        var descriptor = FetchDescriptor(
            predicate: #Predicate<SemanticTagObservation> {
                $0.observationFingerprint == fingerprint
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let candidateJSON = String(decoding: try encoder.encode(candidate), as: UTF8.self)
        let observation = SemanticTagObservation(
            message: message,
            logicalMessageKey: SemanticTagNormalizer.logicalMessageKey(for: message),
            extractionVersion: extractionVersion,
            candidateJSON: candidateJSON,
            observationFingerprint: fingerprint,
            createdAt: date
        )
        context.insert(observation)
        return observation
    }

    @discardableResult
    public func upsertMembership(
        message: Message,
        tag: SemanticTag,
        candidate: SemanticTagCandidate,
        observation: SemanticTagObservation,
        evidenceJSON: String,
        at date: Date = .now
    ) throws -> MessageSemanticTagMembership {
        let resolvedTag = try resolvedTag(id: tag.id) ?? tag
        let key = MessageSemanticTagMembership.key(messageID: message.id, tagID: resolvedTag.id)
        let rolesJSON = try encodeRoles(candidate.roles)
        let membership: MessageSemanticTagMembership

        var descriptor = FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { $0.membershipKey == key }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.logicalMessageKey = SemanticTagNormalizer.logicalMessageKey(for: message)
            existing.score = candidate.centrality.weightMultiplier
            existing.confidence = candidate.confidence
            existing.centralityRaw = candidate.centrality.rawValue
            existing.rolesJSON = rolesJSON
            existing.evidenceJSON = evidenceJSON
            existing.reconciledAt = date
            membership = existing
        } else {
            membership = MessageSemanticTagMembership(
                message: message,
                tag: resolvedTag,
                logicalMessageKey: SemanticTagNormalizer.logicalMessageKey(for: message),
                score: candidate.centrality.weightMultiplier,
                confidence: candidate.confidence,
                centralityRaw: candidate.centrality.rawValue,
                rolesJSON: rolesJSON,
                evidenceJSON: evidenceJSON,
                createdAt: date,
                reconciledAt: date
            )
            context.insert(membership)
        }

        observation.state = .resolved
        observation.resolvedTagID = resolvedTag.id
        observation.resolvedAt = date
        observation.invalidReason = nil
        resolvedTag.lastObservedAt = max(resolvedTag.lastObservedAt, date)
        resolvedTag.updatedAt = max(resolvedTag.updatedAt, date)
        return membership
    }

    @discardableResult
    public func promoteIfEligible(
        _ tag: SemanticTag,
        at date: Date = .now
    ) throws -> Bool {
        let resolved = try resolvedTag(id: tag.id) ?? tag
        guard resolved.lifecycle == .provisional else { return false }
        let resolvedID = resolved.id
        let logicalMessageKeys = Set(
            try context.fetch(FetchDescriptor(
                predicate: #Predicate<MessageSemanticTagMembership> { $0.tagID == resolvedID }
            ))
                .map(\.logicalMessageKey)
        )
        guard logicalMessageKeys.count >= 2 else { return false }
        resolved.lifecycle = .promoted
        resolved.promotedAt = date
        resolved.updatedAt = date
        return true
    }

    @discardableResult
    public func merge(
        _ first: SemanticTag,
        with second: SemanticTag,
        at date: Date = .now
    ) throws -> SemanticTag {
        let firstResolved = try resolvedTag(id: first.id) ?? first
        let secondResolved = try resolvedTag(id: second.id) ?? second
        guard firstResolved.id != secondResolved.id else { return firstResolved }

        let ordered = [firstResolved, secondResolved].sorted { $0.id.uuidString < $1.id.uuidString }
        let survivor = ordered[0]
        let losing = ordered[1]

        let conditions = try context.fetch(FetchDescriptor<MailProjectRuleCondition>())
        let losingStableKey = losing.id.uuidString.lowercased()
        let survivorStableKey = survivor.id.uuidString.lowercased()
        var rewrittenConditionValues: [(MailProjectRuleCondition, [String])] = []
        for condition in conditions where condition.facet == .semanticTag {
            let values = try condition.values()
            guard values.contains(where: { $0.lowercased() == losingStableKey }) else { continue }
            rewrittenConditionValues.append((
                condition,
                values.map { $0.lowercased() == losingStableKey ? survivorStableKey : $0 }
            ))
        }

        let aliases = try context.fetch(FetchDescriptor<SemanticTagAlias>())
        var survivorAliasKeys = Set(
            aliases.filter { $0.tag?.id == survivor.id }.map(\.aliasKey)
        )
        for alias in aliases where alias.tag?.id == losing.id {
            if survivorAliasKeys.insert(alias.aliasKey).inserted {
                alias.tag = survivor
            } else {
                context.delete(alias)
            }
        }

        let survivorID = survivor.id
        let losingID = losing.id
        let survivorMemberships = try context.fetch(FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { $0.tagID == survivorID }
        ))
        let losingMemberships = try context.fetch(FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { $0.tagID == losingID }
        ))
        let survivorByMessage = Dictionary(
            uniqueKeysWithValues: survivorMemberships.map { ($0.messageID, $0) }
        )
        var affectedMessages: [Message] = []
        for membership in losingMemberships {
            if let existing = survivorByMessage[membership.messageID] {
                if membership.confidence > existing.confidence {
                    existing.score = membership.score
                    existing.confidence = membership.confidence
                    existing.centralityRaw = membership.centralityRaw
                    existing.rolesJSON = membership.rolesJSON
                    existing.evidenceJSON = membership.evidenceJSON
                }
                existing.reconciledAt = max(existing.reconciledAt, date)
                if let message = membership.message { affectedMessages.append(message) }
                context.delete(membership)
            } else {
                membership.retarget(to: survivor, at: date)
                if let message = membership.message { affectedMessages.append(message) }
            }
        }

        let observations = try context.fetch(FetchDescriptor(
            predicate: #Predicate<SemanticTagObservation> { $0.resolvedTagID == losingID }
        ))
        for observation in observations {
            observation.resolvedTagID = survivor.id
            observation.resolvedAt = date
        }
        for (condition, values) in rewrittenConditionValues {
            try condition.replaceValues(values)
        }

        if losing.lifecycle == .promoted, survivor.lifecycle == .provisional {
            survivor.lifecycle = .promoted
            survivor.promotedAt = losing.promotedAt ?? date
        }
        survivor.firstObservedAt = min(survivor.firstObservedAt, losing.firstObservedAt)
        survivor.lastObservedAt = max(survivor.lastObservedAt, losing.lastObservedAt)
        survivor.qualifierSignatureJSON = mergedQualifierSignatureJSON(
            survivor.qualifierSignatureJSON,
            losing.qualifierSignatureJSON
        )
        survivor.updatedAt = date
        losing.markMerged(into: survivor.id, at: date)

        for message in uniqueMessages(affectedMessages) where message.analysis != nil {
            try rewriteProjection(for: message)
        }
        return survivor
    }

    public func resolvedTag(id: UUID) throws -> SemanticTag? {
        guard var current = try tag(id: id) else { return nil }
        var visited = Set<UUID>()

        while let nextID = current.mergedIntoTagID {
            guard visited.insert(current.id).inserted,
                  let next = try tag(id: nextID) else {
                throw SemanticTagRepositoryError.redirectCycle
            }
            current = next
        }
        return current
    }

    public func rewriteProjection(for message: Message) throws {
        guard let analysis = message.analysis else {
            throw SemanticTagRepositoryError.missingAnalysis
        }
        guard let data = analysis.dimensionsJSON.data(using: .utf8),
              var dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            throw SemanticTagRepositoryError.invalidDimensions
        }

        let messageID = message.id
        let memberships = try context.fetch(FetchDescriptor(
            predicate: #Predicate<MessageSemanticTagMembership> { $0.messageID == messageID }
        ))
        var strongestByTagID: [UUID: SemanticTagProjection] = [:]
        for membership in memberships {
            guard let tag = try resolvedTag(id: membership.tagID) else { continue }
            let centrality = SemanticTagCentrality(rawValue: membership.centralityRaw) ?? .mention
            let roles = decodeRoles(membership.rolesJSON)
            let projection = SemanticTagProjection(
                tagID: tag.id,
                displayName: tag.preferredDisplayName,
                score: membership.score,
                confidence: membership.confidence,
                centrality: centrality,
                roles: roles
            )
            if let existing = strongestByTagID[tag.id], existing.weightedScore >= projection.weightedScore {
                continue
            }
            strongestByTagID[tag.id] = projection
        }
        dimensions.semanticTags = strongestByTagID.values.sorted {
            if $0.weightedScore != $1.weightedScore { return $0.weightedScore > $1.weightedScore }
            return $0.tagID.uuidString < $1.tagID.uuidString
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        analysis.dimensionsJSON = String(decoding: try encoder.encode(dimensions), as: UTF8.self)
    }

    private func encodeRoles(_ roles: [SemanticTagRole]) throws -> String {
        String(decoding: try JSONEncoder().encode(roles.map(\.rawValue)), as: UTF8.self)
    }

    private func decodeRoles(_ json: String) -> [SemanticTagRole] {
        guard let data = json.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return rawValues.compactMap(SemanticTagRole.init(rawValue:))
    }

    private func uniqueMessages(_ messages: [Message]) -> [Message] {
        var ids = Set<UUID>()
        return messages.filter { ids.insert($0.id).inserted }
    }

    private func tag(id: UUID) throws -> SemanticTag? {
        var descriptor = FetchDescriptor(
            predicate: #Predicate<SemanticTag> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func encodeQualifierSignature(_ candidate: SemanticTagCandidate) throws -> String {
        let signature = SemanticTagNormalizer.qualifierSignature(
            label: candidate.preferredLabel,
            qualifiers: candidate.qualifiers
        )
        let encodable = signature.hardValuesByKind.mapValues { Array($0).sorted() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(encodable), as: UTF8.self)
    }

    private func qualifierSignature(for tag: SemanticTag) -> SemanticTagQualifierSignature {
        var values = decodedQualifierValues(tag.qualifierSignatureJSON)
        for displayName in [tag.preferredDisplayName] + tag.aliases.map(\.displayName) {
            let displayValues = SemanticTagNormalizer.qualifierSignature(
                label: displayName,
                qualifiers: []
            ).hardValuesByKind
            for (kind, additions) in displayValues {
                values[kind, default: []].formUnion(additions)
            }
        }
        return SemanticTagQualifierSignature(hardValuesByKind: values)
    }

    private func mergedQualifierSignatureJSON(_ lhs: String, _ rhs: String) -> String {
        var merged = decodedQualifierValues(lhs)
        for (kind, values) in decodedQualifierValues(rhs) {
            merged[kind, default: []].formUnion(values)
        }
        let encodable = merged.mapValues { Array($0).sorted() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(encodable) else { return lhs }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodedQualifierValues(_ json: String) -> [String: Set<String>] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded.mapValues(Set.init)
    }
}
