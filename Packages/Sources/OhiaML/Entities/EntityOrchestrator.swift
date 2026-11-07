import Foundation
import SwiftData
import OhiaCore

public final class EntityOrchestrator: @unchecked Sendable {
    private let embedder: EmbeddingProvider
    private let vectorStore: VectorStore
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(
        embedder: EmbeddingProvider,
        vectorStore: VectorStore,
        canonicalStore: CanonicalStore? = nil
    ) {
        _ = canonicalStore
        self.embedder = embedder
        self.vectorStore = vectorStore
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    @MainActor
    public func promoteEntities(context: ModelContext) async throws -> EntityPromotionWork {
        try reconcileAttachmentEntities(context: context)
        var work = try promoteCorrespondents(context: context)
        let attachmentWork = try promoteAttachments(context: context)
        work.embedIds.append(contentsOf: attachmentWork.embedIds)
        work.refreshIds.append(contentsOf: attachmentWork.refreshIds)
        try context.save()
        return work
    }

    @MainActor
    public func hasPromotionOrRefreshWork(context: ModelContext) throws -> Bool {
        if try hasOrphanedAttachmentEntities(context: context) {
            return true
        }
        return try hasUnrepresentedPromotionOrRefreshWork(
            context: context,
            representedEmbedIds: [],
            representedRefreshIds: []
        )
    }

    @MainActor
    public func hasUnrepresentedPromotionOrRefreshWork(
        context: ModelContext,
        representedEmbedIds: Set<UUID>,
        representedRefreshIds: Set<UUID>
    ) throws -> Bool {
        let work = try promotionCandidates(context: context)
        return work.embedIds.contains { !representedEmbedIds.contains($0) }
            || work.refreshIds.contains { !representedRefreshIds.contains($0) }
    }

    @MainActor
    private func promotionCandidates(context: ModelContext) throws -> EntityPromotionWork {
        let entities = try context.fetch(FetchDescriptor<Entity>())
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        var work = EntityPromotionWork()

        let byKindKey = entitiesByKindKey(entities)

        for correspondent in correspondents {
            let key = correspondent.primaryEmail.lowercased()
            guard EntityPromotionPolicy.shouldPromote(
                kind: .correspondent,
                supportCount: correspondent.messageCount,
                supportWeight: Double(correspondent.messageCount)
            ) else { continue }
            if let existing = byKindKey[entityKey(kind: .correspondent, key: key)] {
                if existing.vectorRowId == nil {
                    work.embedIds.append(existing.id)
                } else if shouldRefresh(correspondent: correspondent, entity: existing) {
                    work.refreshIds.append(existing.id)
                }
            } else {
                work.embedIds.append(correspondent.id)
            }
        }

        for attachment in attachments {
            guard attachmentHasEmbeddableText(attachment),
                  let parentMessageId = attachment.message?.id.uuidString else { continue }
            let key = Self.attachmentKey(filename: attachment.filename, parentMessageId: parentMessageId)
            if let existing = byKindKey[entityKey(kind: .attachment, key: key)] {
                if existing.vectorRowId == nil {
                    work.embedIds.append(existing.id)
                }
            } else {
                work.embedIds.append(attachment.id)
            }
        }

        return work
    }

    @MainActor
    public func promoteCorrespondents(context: ModelContext) throws -> EntityPromotionWork {
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        let entities = try context.fetch(FetchDescriptor<Entity>())
        let byKey = entitiesByKey(entities.filter { $0.kind == .correspondent })
        var work = EntityPromotionWork()

        for correspondent in correspondents {
            let key = correspondent.primaryEmail.lowercased()
            guard EntityPromotionPolicy.shouldPromote(
                kind: .correspondent,
                supportCount: correspondent.messageCount,
                supportWeight: Double(correspondent.messageCount)
            ) else { continue }

            if let existing = byKey[key] {
                existing.supportCount = correspondent.messageCount
                existing.supportWeight = Double(correspondent.messageCount)
                if let firstSeen = correspondent.firstSeenAt { existing.firstSeenAt = firstSeen }
                if let lastSeen = correspondent.lastSeenAt { existing.lastSeenAt = lastSeen }
                if existing.vectorRowId == nil {
                    work.embedIds.append(existing.id)
                } else if shouldRefresh(correspondent: correspondent, entity: existing) {
                    work.refreshIds.append(existing.id)
                }
            } else {
                let entity = Entity(
                    kind: .correspondent,
                    key: key,
                    displayName: correspondent.primaryName.isEmpty ? key : correspondent.primaryName
                )
                entity.supportCount = correspondent.messageCount
                entity.supportWeight = Double(correspondent.messageCount)
                if let firstSeen = correspondent.firstSeenAt { entity.firstSeenAt = firstSeen }
                if let lastSeen = correspondent.lastSeenAt { entity.lastSeenAt = lastSeen }
                context.insert(entity)
                work.embedIds.append(entity.id)
            }
        }

        return work
    }

    @MainActor
    public func promoteAttachments(context: ModelContext) throws -> EntityPromotionWork {
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        let entities = try context.fetch(FetchDescriptor<Entity>())
        let byKey = entitiesByKey(entities.filter { $0.kind == .attachment })
        var work = EntityPromotionWork()

        for attachment in attachments {
            guard attachmentHasEmbeddableText(attachment),
                  let parentMessageId = attachment.message?.id.uuidString else { continue }
            let key = Self.attachmentKey(filename: attachment.filename, parentMessageId: parentMessageId)
            if let existing = byKey[key] {
                if existing.vectorRowId == nil {
                    work.embedIds.append(existing.id)
                }
                continue
            }
            guard EntityPromotionPolicy.shouldPromote(kind: .attachment, supportCount: 1, supportWeight: 1) else {
                continue
            }

            let entity = Entity(
                kind: .attachment,
                key: key,
                displayName: Self.attachmentDisplayName(filename: attachment.filename)
            )
            entity.supportCount = 1
            entity.supportWeight = 1
            entity.firstSeenAt = attachment.message?.receivedAt ?? attachment.message?.sentAt ?? Date()
            entity.lastSeenAt = entity.firstSeenAt
            context.insert(entity)
            work.embedIds.append(entity.id)
        }

        return work
    }

    @MainActor
    public func embedEntity(_ entity: Entity, context: ModelContext) async throws {
        let payload = try buildPayload(for: entity, context: context)
        let entityId = entity.id.uuidString
        let kind = entity.kind
        let key = entity.key
        let score = Float(entity.supportWeight)
        let embedder = self.embedder
        let vectorStore = self.vectorStore

        let rowId = try await Task.detached(priority: .utility) {
            guard let vector = embedder.embed(payload.document) else {
                throw EntityOrchestratorError.embedFailed
            }
            return try vectorStore.insertEntity(
                entityId: entityId,
                kind: kind,
                entityKey: key,
                entityScore: score,
                embeddingVersion: embedder.embeddingVersion,
                vector: vector,
                textPayload: payload.document,
                metadataJSON: payload.profileJSON
            )
        }.value

        entity.vectorRowId = rowId
        entity.profileJSON = payload.profileJSON
        entity.supportCountAtLastEmbed = entity.supportCount
        entity.roleDistributionAtLastEmbedJSON = payload.roleDistributionJSON
        try context.save()
    }

    @MainActor
    public func refreshEntity(_ entity: Entity, context: ModelContext) async throws {
        if let vectorRowId = entity.vectorRowId {
            try vectorStore.deleteEntityVector(vectorId: vectorRowId)
        }
        entity.vectorRowId = nil
        try await embedEntity(entity, context: context)
    }

    /// Attachment entities are derived from the current attachment rows. If
    /// their source disappeared after work was scheduled, discard the derived
    /// entity instead of sending an impossible embed through the retry budget.
    @MainActor
    public func discardAttachmentEntityIfSourceMissing(
        _ entity: Entity,
        context: ModelContext
    ) throws -> Bool {
        guard entity.kind == .attachment else { return false }
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        guard !attachmentSourceKeys(attachments).contains(entity.key) else {
            return false
        }
        try discardEntity(entity, context: context)
        try context.save()
        return true
    }

    public static func attachmentKey(filename: String, parentMessageId: String) -> String {
        "\(filename)|\(parentMessageId.prefix(8))"
    }

    static func attachmentDisplayName(filename: String) -> String {
        let decoded = MIMEHeaderDecoder.decodeEncodedWords(filename)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? filename : decoded
    }

    private struct EntityPayload: Sendable {
        let document: String
        let profileJSON: String
        let roleDistributionJSON: String?
    }

    @MainActor
    private func buildPayload(for entity: Entity, context: ModelContext) throws -> EntityPayload {
        switch entity.kind {
        case .correspondent:
            return try buildCorrespondentPayload(for: entity, context: context)
        case .attachment:
            return try buildAttachmentPayload(for: entity, context: context)
        }
    }

    @MainActor
    private func buildCorrespondentPayload(for entity: Entity, context: ModelContext) throws -> EntityPayload {
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        guard let correspondent = correspondents.first(where: { $0.primaryEmail.lowercased() == entity.key }) else {
            throw EntityOrchestratorError.missingSourceEntity(entity.id)
        }

        var profile = decodedCorrespondentProfile(correspondent.profileJSON) ?? CorrespondentProfile()
        if profile.messageCount == 0 {
            profile.messageCount = correspondent.messageCount
        }
        if profile.familiarityScore == 0 {
            profile.familiarityScore = correspondent.familiarityScore
        }

        let document = EntityDocumentBuilder.buildCorrespondentDocument(
            displayName: entity.displayName,
            emailAddress: entity.key,
            profile: profile,
            firstSeenAt: correspondent.firstSeenAt ?? entity.firstSeenAt,
            lastSeenAt: correspondent.lastSeenAt ?? entity.lastSeenAt
        )

        let messages = try context.fetch(FetchDescriptor<Message>())
        let supportingIds = messages
            .filter { $0.fromAddress.lowercased() == entity.key }
            .prefix(EntityProfile.supportingIdsCap)
            .map { $0.id.uuidString }

        var entityProfile = EntityProfile(supportingMessageIds: Array(supportingIds))
        entityProfile.roleDistribution = roleDistribution(from: correspondent)
        entityProfile.recentTopics = profile.topTopics.prefix(5).map(\.label)
        entityProfile.familiarityScore = profile.familiarityScore
        entityProfile.languages = profile.languagePreferences.prefix(5).map(\.label)

        let profileJSON = try encodeString(entityProfile)
        let roleJSON = try entityProfile.roleDistribution.map(encodeString)
        return EntityPayload(document: document, profileJSON: profileJSON, roleDistributionJSON: roleJSON)
    }

    @MainActor
    private func buildAttachmentPayload(for entity: Entity, context: ModelContext) throws -> EntityPayload {
        let parts = entity.key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw EntityOrchestratorError.missingSourceEntity(entity.id) }
        let filename = parts[0]
        let messagePrefix = parts[1]

        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        guard let attachment = attachments.first(where: {
            $0.filename == filename && ($0.message?.id.uuidString.hasPrefix(messagePrefix) ?? false)
        }), let parent = attachment.message else {
            throw EntityOrchestratorError.missingSourceEntity(entity.id)
        }

        let rawExtractedText: String
        if let path = attachment.extractedTextPath, FileManager.default.fileExists(atPath: path) {
            rawExtractedText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            rawExtractedText = ""
        }
        let structuredEmbeddingText = attachment.ragDocumentPath
            .flatMap(Self.loadAttachmentRAGDocument(path:))?
            .embeddingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sidecarEmbeddingText = attachment.embeddingTextPath
            .flatMap { path -> String? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return try? String(contentsOfFile: path, encoding: .utf8)
            }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddingFallbackText = structuredEmbeddingText?.isEmpty == false
            ? structuredEmbeddingText!
            : (sidecarEmbeddingText?.isEmpty == false ? sidecarEmbeddingText! : rawExtractedText)
        let evidencePacket = AttachmentEvidencePacket(
            attachment: attachment,
            messageId: parent.id.uuidString
        )
        let extractedText = evidencePacket?
            .embeddingText(fallbackExtractedText: embeddingFallbackText) ?? embeddingFallbackText
        let parentBodyText: String
        if let path = parent.bodyTextPath, FileManager.default.fileExists(atPath: path) {
            parentBodyText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            parentBodyText = ""
        }
        let evidenceBundle = MessageEvidenceBundle.build(
            message: parent,
            bodyText: parentBodyText,
            fallbackTextByAttachmentId: [attachment.id.uuidString: rawExtractedText]
        )
        let evidenceDigest = evidenceBundle?.digest(maxCharacters: 1_600)
        let coAttachments = parent.attachments
            .filter { $0.id != attachment.id }
            .map { Self.attachmentDisplayName(filename: $0.filename) }
        let sender = (parent.fromName?.isEmpty == false) ? parent.fromName! : parent.fromAddress

        let document = EntityDocumentBuilder.buildAttachmentDocument(
            filename: Self.attachmentDisplayName(filename: attachment.filename),
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            parentSubject: parent.subject,
            parentSenderDisplay: sender,
            parentSentAt: parent.sentAt ?? parent.receivedAt ?? parent.ingestedAt,
            coAttachmentFilenames: coAttachments,
            extractedTextSummary: extractedText,
            messageEvidenceDigest: evidenceDigest
        )

        var entityProfile = EntityProfile(supportingMessageIds: [parent.id.uuidString])
        entityProfile.contentType = attachment.mimeType
        entityProfile.sizeBytes = attachment.sizeBytes
        entityProfile.parentMessageId = parent.id.uuidString
        entityProfile.coAttachmentFilenames = coAttachments
        entityProfile.extractedTextSummary = String(extractedText.prefix(EntityDocumentBuilder.attachmentSummaryCap))
        entityProfile.visualEvidenceKind = evidencePacket?.evidenceKind
        entityProfile.visualLabels = evidencePacket?.labels.map(\.identifier)
        entityProfile.visualObjects = evidencePacket?.objects.map(\.label)
        entityProfile.visualOCRText = evidencePacket?.ocrText.map { String($0.prefix(400)) }
        entityProfile.visualConfidence = evidencePacket?.averageConfidence.map(Double.init)
        entityProfile.documentType = evidencePacket?.evidenceKind ?? attachment.detectedDocumentKind
        entityProfile.visibleNamesDatesAmounts = Self.visibleNamesDatesAmounts(from: evidencePacket)
        entityProfile.parentMessageSubject = parent.subject
        entityProfile.parentMessageSender = sender
        entityProfile.parentMessageContext = evidenceDigest
        return EntityPayload(
            document: document,
            profileJSON: try encodeString(entityProfile),
            roleDistributionJSON: nil
        )
    }

    private func shouldRefresh(correspondent: Correspondent, entity: Entity) -> Bool {
        EntityRefreshPolicy.shouldRefresh(
            kind: .correspondent,
            supportCountAtLastEmbed: entity.supportCountAtLastEmbed,
            currentSupportCount: correspondent.messageCount,
            roleDistributionAtLastEmbed: decodedRoleDistribution(entity.roleDistributionAtLastEmbedJSON),
            currentRoleDistribution: roleDistribution(from: correspondent)
        )
    }

    private func attachmentHasEmbeddableText(_ attachment: Attachment) -> Bool {
        guard let path = attachment.extractedTextPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    @MainActor
    public func hasOrphanedAttachmentEntities(context: ModelContext) throws -> Bool {
        let entities = try context.fetch(FetchDescriptor<Entity>())
        let attachmentEntities = entities.filter { $0.kind == .attachment }
        guard !attachmentEntities.isEmpty else { return false }
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        let sourceKeys = attachmentSourceKeys(attachments)
        return attachmentEntities.contains { !sourceKeys.contains($0.key) }
    }

    @MainActor
    private func reconcileAttachmentEntities(context: ModelContext) throws {
        let entities = try context.fetch(FetchDescriptor<Entity>())
        let attachmentEntities = entities.filter { $0.kind == .attachment }
        guard !attachmentEntities.isEmpty else { return }
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        let sourceKeys = attachmentSourceKeys(attachments)
        for entity in attachmentEntities where !sourceKeys.contains(entity.key) {
            try discardEntity(entity, context: context)
        }
    }

    private func attachmentSourceKeys(_ attachments: [Attachment]) -> Set<String> {
        Set(attachments.compactMap { attachment in
            guard let parentMessageId = attachment.message?.id.uuidString else {
                return nil
            }
            return Self.attachmentKey(
                filename: attachment.filename,
                parentMessageId: parentMessageId
            )
        })
    }

    @MainActor
    private func discardEntity(_ entity: Entity, context: ModelContext) throws {
        try vectorStore.deleteEntityVectors(kind: entity.kind, key: entity.key)
        context.delete(entity)
    }

    private static func loadAttachmentRAGDocument(path: String) -> AttachmentRAGDocument? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(AttachmentRAGDocument.self, from: data)
    }

    private static func visibleNamesDatesAmounts(from packet: AttachmentEvidencePacket?) -> [String]? {
        guard let packet else { return nil }
        let text = (
            packet.ocrBlocks.map(\.text)
            + [packet.ocrText].compactMap { $0 }
            + [packet.visualSummary, packet.attachmentSummary].compactMap { $0 }
        )
        .joined(separator: "\n")
        let patterns = [
            #"\$[0-9][0-9,]*(?:\.[0-9]{2})?"#,
            #"\b[0-9]{1,2}[/-][0-9]{1,2}[/-][0-9]{2,4}\b"#,
            #"\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b"#,
            #"\b[A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+){0,2}\b"#
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count >= 2 else { continue }
                values.append(value)
            }
        }
        var seen = Set<String>()
        let unique = values.filter { seen.insert($0).inserted }.prefix(12)
        return unique.isEmpty ? nil : Array(unique)
    }

    private func roleDistribution(from correspondent: Correspondent) -> [String: Double] {
        guard let profile = decodedCorrespondentProfile(correspondent.profileJSON) else { return [:] }
        return Dictionary(uniqueKeysWithValues: profile.relationshipDistribution.map { ($0.label, $0.score) })
    }

    private func decodedCorrespondentProfile(_ json: String?) -> CorrespondentProfile? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(CorrespondentProfile.self, from: data)
    }

    private func decodedRoleDistribution(_ json: String?) -> [String: Double]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode([String: Double].self, from: data)
    }

    private func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }

    private func entityKey(kind: EntityKind, key: String) -> String {
        "\(kind.rawValue):\(key)"
    }

    private func entitiesByKindKey(_ entities: [Entity]) -> [String: Entity] {
        var out: [String: Entity] = [:]
        for entity in entities {
            out[entityKey(kind: entity.kind, key: entity.key)] = entity
        }
        return out
    }

    private func entitiesByKey(_ entities: [Entity]) -> [String: Entity] {
        var out: [String: Entity] = [:]
        for entity in entities {
            out[entity.key] = entity
        }
        return out
    }
}

public enum EntityOrchestratorError: Error, LocalizedError {
    case embedFailed
    case missingSourceEntity(UUID)

    public var errorDescription: String? {
        switch self {
        case .embedFailed:
            return "Entity embedding provider returned no vector"
        case .missingSourceEntity(let entityID):
            return "Entity source no longer exists: \(entityID.uuidString)"
        }
    }
}
