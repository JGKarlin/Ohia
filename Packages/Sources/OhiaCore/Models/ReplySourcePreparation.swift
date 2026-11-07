import Foundation
import SwiftData

/// Raw-string lifecycle values for a complete reply preparation prepared before
/// a reply Draft exists. Raw storage keeps SwiftData predicates safe.
public enum ReplySourcePreparationStatus {
    public static let pending = "pending"
    public static let compilingSources = "compilingSources"
    public static let formulatingQuestions = "formulatingQuestions"
    public static let drafting = "drafting"
    public static let retryWaiting = "retryWaiting"
    public static let preparing = "preparing"
    public static let ready = "ready"
    public static let failed = "failed"
}

/// Durable contract shared by Scheduler admission and the OhiaML preparation
/// worker. Keeping the payload in Core avoids reversing the package dependency
/// from OhiaML back into OhiaScheduler.
public struct ReplySourcePreparationJobPayload: Codable, Sendable, Equatable {
    public let messageID: UUID
    public let fingerprint: String
    public let contractVersion: Int

    public init(messageID: UUID, fingerprint: String, contractVersion: Int) {
        self.messageID = messageID
        self.fingerprint = fingerprint
        self.contractVersion = contractVersion
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(_ encoded: String?) -> Self? {
        guard let encoded, let data = encoded.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// A complete packed reply preparation waiting for explicit Composer entry.
/// `messageId` intentionally duplicates the relationship key: the app and
/// worker use separate SwiftData contexts, so scalar lookup is the authoritative
/// cross-process seam when a registered relationship is stale.
@Model
public final class ReplySourcePreparation {
    #Index<ReplySourcePreparation>(
        [\.messageId],
        [\.statusRaw],
        [\.messageId, \.statusRaw]
    )

    public var id: UUID
    public var messageId: UUID
    public var message: Message?
    public var statusRaw: String
    public var inputFingerprint: String
    public var contractVersion: Int
    /// Immutable admission witness: the exact live-thread message IDs known to
    /// belong to the preparation input when triage admitted this preparation.
    /// Optional for lightweight migration; a missing or malformed witness is
    /// treated conservatively as empty by the coordinator.
    public var witnessedLiveThreadMessageIDsJSON: String?
    public var sourcesJSON: String?
    /// `ComposerThreadCoverage` JSON for `sourcesJSON`; carried onto the Draft
    /// that adopts this preparation. Optional for lightweight migration.
    public var sourceThreadCoverageJSON: String?
    public var interviewStateJSON: String?
    public var questionCount: Int = -1
    public var generatedDraftJSON: String?
    public var sourceThreadCount: Int
    /// The draft writer's source-context meter and its detail, as on `Draft`.
    public var sourceContextTokenCount: Int?
    public var sourceContextTokenLimit: Int?
    public var sourceContextFitJSON: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var preparedAt: Date?
    public var failureCount: Int
    public var lastError: String?
    public var nextAttemptAt: Date?

    public init(
        id: UUID = UUID(),
        message: Message,
        statusRaw: String = ReplySourcePreparationStatus.pending,
        inputFingerprint: String,
        contractVersion: Int,
        witnessedLiveThreadMessageIDsJSON: String? = nil,
        sourcesJSON: String? = nil,
        sourceThreadCoverageJSON: String? = nil,
        interviewStateJSON: String? = nil,
        questionCount: Int = -1,
        generatedDraftJSON: String? = nil,
        sourceThreadCount: Int = 0,
        sourceContextTokenCount: Int? = nil,
        sourceContextTokenLimit: Int? = nil,
        sourceContextFitJSON: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        preparedAt: Date? = nil,
        failureCount: Int = 0,
        lastError: String? = nil,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.messageId = message.id
        self.message = message
        self.statusRaw = statusRaw
        self.inputFingerprint = inputFingerprint
        self.contractVersion = contractVersion
        self.witnessedLiveThreadMessageIDsJSON = witnessedLiveThreadMessageIDsJSON
        self.sourcesJSON = sourcesJSON
        self.sourceThreadCoverageJSON = sourceThreadCoverageJSON
        self.interviewStateJSON = interviewStateJSON
        self.questionCount = questionCount
        self.generatedDraftJSON = generatedDraftJSON
        self.sourceThreadCount = sourceThreadCount
        self.sourceContextTokenCount = sourceContextTokenCount
        self.sourceContextTokenLimit = sourceContextTokenLimit
        self.sourceContextFitJSON = sourceContextFitJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preparedAt = preparedAt
        self.failureCount = failureCount
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
    }
}
