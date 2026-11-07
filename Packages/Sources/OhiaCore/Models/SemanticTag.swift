import Foundation
import SwiftData

public enum SemanticTagLifecycle: String, Sendable, CaseIterable {
    case provisional
    case promoted
    case merged
}

public enum SemanticTagObservationState: String, Sendable, CaseIterable {
    case pending
    case resolved
    case invalid
}

@Model
public final class SemanticTag {
    #Index<SemanticTag>([\.lifecycleRaw])

    @Attribute(.unique) public var id: UUID
    public var preferredDisplayName: String
    public var normalizedIdentity: String
    public var qualifierSignatureJSON: String
    public var lifecycleRaw: String
    public var mergedIntoTagID: UUID?
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var promotedAt: Date?
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SemanticTagAlias.tag)
    public var aliases: [SemanticTagAlias] = []

    @Relationship(deleteRule: .nullify, inverse: \MessageSemanticTagMembership.tag)
    public var memberships: [MessageSemanticTagMembership] = []

    public init(
        id: UUID = UUID(),
        preferredDisplayName: String,
        normalizedIdentity: String,
        qualifierSignatureJSON: String = "{}",
        lifecycle: SemanticTagLifecycle = .provisional,
        mergedIntoTagID: UUID? = nil,
        firstObservedAt: Date = .now,
        lastObservedAt: Date? = nil,
        promotedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.preferredDisplayName = preferredDisplayName
        self.normalizedIdentity = normalizedIdentity
        self.qualifierSignatureJSON = qualifierSignatureJSON
        self.lifecycleRaw = lifecycle.rawValue
        self.mergedIntoTagID = mergedIntoTagID
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt ?? firstObservedAt
        self.promotedAt = promotedAt
        self.updatedAt = updatedAt ?? firstObservedAt
    }

    public var lifecycle: SemanticTagLifecycle {
        get { SemanticTagLifecycle(rawValue: lifecycleRaw) ?? .provisional }
        set { lifecycleRaw = newValue.rawValue }
    }

    public func markMerged(into survivingTagID: UUID, at date: Date = .now) {
        guard survivingTagID != id else { return }
        lifecycle = .merged
        mergedIntoTagID = survivingTagID
        updatedAt = date
    }
}

@Model
public final class SemanticTagAlias {
    #Index<SemanticTagAlias>([\.aliasKey])

    public var id: UUID
    public var aliasKey: String
    public var displayName: String
    public var normalizedText: String
    public var languageID: String?
    public var observationCount: Int
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var embeddingData: Data?
    public var embeddingVersion: String?
    public var tag: SemanticTag?

    public init(
        id: UUID = UUID(),
        tag: SemanticTag,
        displayName: String,
        normalizedText: String,
        aliasKey: String,
        languageID: String? = nil,
        observationCount: Int = 1,
        firstObservedAt: Date = .now,
        lastObservedAt: Date? = nil,
        embeddingData: Data? = nil,
        embeddingVersion: String? = nil
    ) {
        self.id = id
        self.aliasKey = aliasKey
        self.displayName = displayName
        self.normalizedText = normalizedText
        self.languageID = languageID
        self.observationCount = max(0, observationCount)
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt ?? firstObservedAt
        self.embeddingData = embeddingData
        self.embeddingVersion = embeddingVersion
        self.tag = tag
    }
}

@Model
public final class SemanticTagObservation {
    #Index<SemanticTagObservation>([\.messageID], [\.stateRaw])

    public var id: UUID
    @Attribute(.unique) public var observationFingerprint: String
    public var messageID: UUID
    public var logicalMessageKey: String
    public var extractionVersion: String
    public var candidateJSON: String
    public var stateRaw: String
    public var resolvedTagID: UUID?
    public var createdAt: Date
    public var resolvedAt: Date?
    public var invalidReason: String?
    public var message: Message?

    public init(
        id: UUID = UUID(),
        message: Message,
        logicalMessageKey: String,
        extractionVersion: String = "semantic-tags-v1",
        candidateJSON: String,
        observationFingerprint: String,
        state: SemanticTagObservationState = .pending,
        resolvedTagID: UUID? = nil,
        createdAt: Date = .now,
        resolvedAt: Date? = nil,
        invalidReason: String? = nil
    ) {
        self.id = id
        self.observationFingerprint = observationFingerprint
        self.messageID = message.id
        self.logicalMessageKey = logicalMessageKey
        self.extractionVersion = extractionVersion
        self.candidateJSON = candidateJSON
        self.stateRaw = state.rawValue
        self.resolvedTagID = resolvedTagID
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.invalidReason = invalidReason
        self.message = message
    }

    public var state: SemanticTagObservationState {
        get { SemanticTagObservationState(rawValue: stateRaw) ?? .invalid }
        set { stateRaw = newValue.rawValue }
    }
}

@Model
public final class MessageSemanticTagMembership {
    #Index<MessageSemanticTagMembership>([\.messageID], [\.tagID])

    public var id: UUID
    @Attribute(.unique) public private(set) var membershipKey: String
    public private(set) var messageID: UUID
    public private(set) var tagID: UUID
    public var logicalMessageKey: String
    public var score: Double
    public var confidence: Double
    public var centralityRaw: String
    public var rolesJSON: String
    public var evidenceJSON: String
    public var createdAt: Date
    public var reconciledAt: Date
    public var message: Message?
    public var tag: SemanticTag?

    public init(
        id: UUID = UUID(),
        message: Message,
        tag: SemanticTag,
        logicalMessageKey: String,
        score: Double,
        confidence: Double,
        centralityRaw: String,
        rolesJSON: String,
        evidenceJSON: String,
        createdAt: Date = .now,
        reconciledAt: Date? = nil
    ) {
        self.id = id
        self.messageID = message.id
        self.tagID = tag.id
        self.membershipKey = Self.key(messageID: message.id, tagID: tag.id)
        self.logicalMessageKey = logicalMessageKey
        self.score = Self.clamped(score)
        self.confidence = Self.clamped(confidence)
        self.centralityRaw = centralityRaw
        self.rolesJSON = rolesJSON
        self.evidenceJSON = evidenceJSON
        self.createdAt = createdAt
        self.reconciledAt = reconciledAt ?? createdAt
        self.message = message
        self.tag = tag
    }

    public static func key(messageID: UUID, tagID: UUID) -> String {
        "\(messageID.uuidString)|\(tagID.uuidString)"
    }

    public func retarget(to survivingTag: SemanticTag, at date: Date = .now) {
        tag = survivingTag
        tagID = survivingTag.id
        membershipKey = Self.key(messageID: messageID, tagID: survivingTag.id)
        reconciledAt = date
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
