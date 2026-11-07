import Foundation
import SwiftData

/// Exponential recency decay for account memories. Weight decays with a
/// 90-day half-life so memories that have not been re-projected in months
/// automatically reflect their age, without touching the stored `weight`.
public enum AccountMemoryDecay {
    /// Half-life in days. Every 90 days a memory's live weight drops by 50%.
    public static let halfLifeDays: Double = 90

    /// Below this decayed-weight factor a long-unaffirmed memory is stale.
    /// ~3 half-lives (~270 days) puts the factor at 0.125.
    public static let staleFactorThreshold: Double = 0.125

    /// Returns the decay factor in `(0, 1]` for a memory last seen at the
    /// given date. A factor of 1.0 means no time has elapsed; 0.5 means one
    /// half-life has passed.
    public static func factor(lastSeenAt: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(lastSeenAt))
        return pow(0.5, age / (halfLifeDays * 86_400))
    }

    /// Returns `true` when the decayed factor has fallen below
    /// `staleFactorThreshold`, indicating the memory has not been re-affirmed
    /// or re-projected for an extended period.
    public static func isStale(lastSeenAt: Date, now: Date) -> Bool {
        factor(lastSeenAt: lastSeenAt, now: now) < staleFactorThreshold
    }
}

public enum AccountMemoryProjectedStatus {
    /// Current durable-memory lifecycle values.
    public static let active = "active"
    public static let confirmed = "confirmed"
    public static let contested = "contested"
    public static let superseded = "superseded"
    public static let needsReview = "needsReview"

    /// Legacy claim-ledger lifecycle values. They remain readable during the
    /// contract cutover but are never sufficient for durable prompt use.
    public static let inferred = "inferred"
    public static let affirmed = "affirmed"
    public static let weakened = "weakened"
    public static let rejected = "rejected"
    public static let stale = "stale"
    public static let deleted = "deleted"

    public static let activeStatuses: Set<String> = [
        active,
        confirmed,
        inferred,
        affirmed
    ]

    public static let hiddenStatuses: Set<String> = [
        rejected,
        deleted,
        superseded
    ]
}

public enum AccountMemoryRefreshStatus {
    public static let idle = "idle"
    public static let running = "running"
    public static let deferred = "deferred"
    public static let succeeded = "succeeded"
    public static let failed = "failed"
}

/// The dossier dimensions a projected memory can belong to. Stored as
/// raw strings (not a Codable enum) so SwiftData lightweight migration and
/// `#Predicate` translation never see a custom enum type.
public enum AccountMemoryDimension {
    public static let account = "account"
    public static let correspondent = "correspondent"
    public static let classification = "classification"
    public static let project = "project"
    /// Per-target-language translation dossier: evidenced terminology pins
    /// (proper-noun renderings) and style/preference rules, keyed by the
    /// target language code, curated by the user in Settings → Memories.
    public static let translation = "translation"

    public static let all: [String] = [account, correspondent, classification, project, translation]

    public static func displayLabel(_ raw: String) -> String {
        switch raw {
        case account: return "Account"
        case correspondent: return "People"
        case classification: return "Classification"
        case project: return "Projects"
        case translation: return "Translation"
        default: return raw
        }
    }
}

public enum AccountMemoryOrigin {
    public static let explicit = "explicit"
    public static let inferred = "inferred"
}

public enum AccountMemoryDirection {
    public static let sent = "sent"
    public static let received = "received"
    public static let mixed = "mixed"
}

/// Current contract for guidance memories generated from correspondence.
public enum AccountMemoryContract {
    public static let currentVersion = "durable-email-memory-v2"
}

public enum AccountMemoryFormationBasis {
    public static let explicitStanding = "explicitStanding"
    public static let explicitCorrection = "explicitCorrection"
    public static let repeatedPattern = "repeatedPattern"
    public static let userCurated = "userCurated"

    /// Bases that a model-generated candidate may assign. `userCurated` is
    /// reserved for `applyUserEdit` and the explicit legacy cutover seam.
    public static let generated: Set<String> = [
        explicitStanding,
        explicitCorrection,
        repeatedPattern
    ]

    public static let all: Set<String> = [
        explicitStanding,
        explicitCorrection,
        repeatedPattern,
        userCurated
    ]
}

public enum AccountMemoryUsePolicy {
    public static let internalGuidance = "internalGuidance"
    public static let draftingGuidance = "draftingGuidance"
    public static let contextualOrientation = "contextualOrientation"
    public static let assertableKnowledge = "assertableKnowledge"

    public static let all: Set<String> = [
        internalGuidance,
        draftingGuidance,
        contextualOrientation,
        assertableKnowledge
    ]
}

/// Guidance-oriented taxonomy for current generated memories. Claim-ledger
/// constants remain available only so existing rows and call sites decode
/// during the clean cutover; they are intentionally absent from `all`.
public enum AccountMemoryKind {
    public static let preference = "preference"
    public static let relationship = "relationship"
    public static let roleResponsibility = "roleResponsibility"
    public static let norm = "norm"
    public static let ruleConstraint = "ruleConstraint"
    public static let procedure = "procedure"
    public static let convention = "convention"
    public static let orientation = "orientation"
    public static let learnedLesson = "learnedLesson"

    public static let all: [String] = [
        preference,
        relationship,
        roleResponsibility,
        norm,
        ruleConstraint,
        procedure,
        convention,
        orientation,
        learnedLesson
    ]

    // Legacy claim-ledger vocabulary.
    public static let fact = "fact"
    public static let decision = "decision"
    public static let rule = "rule"
    public static let commitment = "commitment"
    public static let projectState = "projectState"
    public static let definition = "definition"
    public static let translation = "translation"
    public static let openQuestion = "openQuestion"
    public static let legacyRaws: Set<String> = [
        "claim",
        "precedent",
        "tacitRule",
        fact,
        decision,
        rule,
        commitment,
        projectState,
        definition,
        translation,
        openQuestion
    ]
}

public enum AccountMemoryEmbeddingCodec {
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
    public static func decode(_ data: Data) -> [Float] {
        guard data.count % 4 == 0 else { return [] }
        var vector: [Float] = []
        vector.reserveCapacity(data.count / 4)
        var index = data.startIndex
        while index < data.endIndex {
            let raw = data[index..<data.index(index, offsetBy: 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            vector.append(Float(bitPattern: UInt32(littleEndian: raw)))
            index = data.index(index, offsetBy: 4)
        }
        return vector
    }
}

public struct AccountMemoryScopeReference: Codable, Hashable, Sendable {
    public var kindRaw: String
    public var value: String

    public init(kindRaw: String, value: String) {
        self.kindRaw = kindRaw
        self.value = value
    }
}

public struct AccountMemoryEvidenceReference: Codable, Hashable, Sendable {
    public var messageID: UUID
    public var subject: String
    public var senderAddress: String
    public var senderName: String?
    public var timestamp: Date
    public var fieldSourceRaw: String
    public var spanText: String?
    public var summary: String?
    public var confidence: Double
    public var threadID: UUID?
    public var isSentByUser: Bool?

    public init(
        messageID: UUID,
        subject: String,
        senderAddress: String,
        senderName: String? = nil,
        timestamp: Date,
        fieldSourceRaw: String,
        spanText: String? = nil,
        summary: String? = nil,
        confidence: Double,
        threadID: UUID? = nil,
        isSentByUser: Bool? = nil
    ) {
        self.messageID = messageID
        self.subject = subject
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.timestamp = timestamp
        self.fieldSourceRaw = fieldSourceRaw
        self.spanText = spanText
        self.summary = summary
        self.confidence = confidence
        self.threadID = threadID
        self.isSentByUser = isSentByUser
    }
}

/// Account-level memory projection built from per-message discourse memory.
/// `memoryKey` is the `ConversationCurationKey.targetKey`; user verdicts
/// remain canonical in `ConversationCurationAction` and are folded back into
/// `statusRaw` whenever the projection refreshes.
@Model
public final class AccountMemory {
    public var id: UUID
    public var accountID: UUID
    public var memoryKey: String
    public var targetKindRaw: String
    /// Dossier dimension (`AccountMemoryDimension`). Optional because rows
    /// created before the dimension expansion lack the attribute — they read
    /// back as the account dimension via `dimensionKind`.
    public var dimensionKindRaw: String?
    /// Dimension-specific key: normalized correspondent address, canonical
    /// classification-facet value, or canonical project key. Empty for `account`.
    public var dimensionValue: String?
    /// Human-readable form of `dimensionValue` for UI and exports
    /// (correspondent display name, classification label, project title).
    public var dimensionDisplayName: String?
    public var normalizedText: String
    public var generatedText: String
    public var userEditedText: String?
    public var statusRaw: String
    public var weight: Double
    public var extractionConfidence: Double
    public var evidenceStrength: Double
    public var sensitivityRiskRaw: String
    public var contradictionStateRaw: String
    /// When non-nil, this memory has been superseded by a newer dossier fact;
    /// the value is the `memoryKey` of the superseding row. Optional so SwiftData
    /// lightweight migration adds it as NULL to existing rows (they read back as
    /// "not superseded"). Retrieval selectors drop superseded rows so a draft or
    /// answer never grounds on a fact a later message replaced.
    public var supersededByMemoryKey: String?
    /// explicit | inferred — support-level origin carried through distillation.
    public var originRaw: String?
    /// Who asserted the claim: "user", a correspondent address, or nil once
    /// corroborated as shared/institutional knowledge.
    public var assertedByAddress: String?
    /// sent | received | mixed evidence direction.
    public var directionRaw: String?
    /// Temporal scope: when the fact took effect / stops applying.
    public var asOf: Date?
    public var expiresAt: Date?
    /// One-clause applicability qualifier ("applies when …").
    public var conditionsText: String?
    /// Concrete description of how this guidance changes a future
    /// interpretation, question, or draft.
    public var futureUseText: String?
    /// `AccountMemoryFormationBasis` raw value.
    public var formationBasisRaw: String?
    /// `AccountMemoryUsePolicy` raw value.
    public var usePolicyRaw: String?
    /// Concrete subject entity, used for claim identity and dedup.
    public var subjectText: String?
    /// Memory-text embedding for semantic dedup and retrieval ranking.
    public var embeddingBlob: Data?
    public var memoryEmbeddingVersion: String?
    public var scopeJSON: String
    public var evidenceJSON: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var lastAffirmedAt: Date?
    public var extractionVersion: String
    public var supportingFingerprint: String
    public var projectedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        memoryKey: String,
        targetKindRaw: String = "claim",
        dimensionKindRaw: String = AccountMemoryDimension.account,
        dimensionValue: String = "",
        dimensionDisplayName: String = "",
        normalizedText: String,
        generatedText: String,
        userEditedText: String? = nil,
        statusRaw: String = AccountMemoryProjectedStatus.inferred,
        weight: Double = 0,
        extractionConfidence: Double = 0,
        evidenceStrength: Double = 0,
        sensitivityRiskRaw: String = "none",
        contradictionStateRaw: String = "clean",
        supersededByMemoryKey: String? = nil,
        scopeJSON: String = "[]",
        evidenceJSON: String = "[]",
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        lastAffirmedAt: Date? = nil,
        extractionVersion: String,
        supportingFingerprint: String = "",
        projectedAt: Date = .now,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        originRaw: String? = nil,
        assertedByAddress: String? = nil,
        directionRaw: String? = nil,
        asOf: Date? = nil,
        expiresAt: Date? = nil,
        conditionsText: String? = nil,
        futureUseText: String? = nil,
        formationBasisRaw: String? = nil,
        usePolicyRaw: String? = nil,
        subjectText: String? = nil,
        embeddingBlob: Data? = nil,
        memoryEmbeddingVersion: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.memoryKey = memoryKey
        self.targetKindRaw = targetKindRaw
        self.dimensionKindRaw = dimensionKindRaw
        self.dimensionValue = dimensionValue
        self.dimensionDisplayName = dimensionDisplayName
        self.normalizedText = normalizedText
        self.generatedText = generatedText
        self.userEditedText = userEditedText
        self.statusRaw = statusRaw
        self.weight = weight
        self.extractionConfidence = extractionConfidence
        self.evidenceStrength = evidenceStrength
        self.sensitivityRiskRaw = sensitivityRiskRaw
        self.contradictionStateRaw = contradictionStateRaw
        self.supersededByMemoryKey = supersededByMemoryKey
        self.originRaw = originRaw
        self.assertedByAddress = assertedByAddress
        self.directionRaw = directionRaw
        self.asOf = asOf
        self.expiresAt = expiresAt
        self.conditionsText = conditionsText
        self.futureUseText = futureUseText
        self.formationBasisRaw = formationBasisRaw
        self.usePolicyRaw = usePolicyRaw
        self.subjectText = subjectText
        self.embeddingBlob = embeddingBlob
        self.memoryEmbeddingVersion = memoryEmbeddingVersion
        self.scopeJSON = scopeJSON
        self.evidenceJSON = evidenceJSON
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastAffirmedAt = lastAffirmedAt
        self.extractionVersion = extractionVersion
        self.supportingFingerprint = supportingFingerprint
        self.projectedAt = projectedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension AccountMemory {
    var isCurrentContract: Bool {
        extractionVersion == AccountMemoryContract.currentVersion
    }

    var isUserCurated: Bool {
        if formationBasisRaw == AccountMemoryFormationBasis.userCurated {
            return true
        }
        let edited = userEditedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited?.isEmpty == false
    }

    /// Contract-level prompt admission. Task-specific selectors still apply
    /// scope, relevance, expiry, sensitivity, and operation use-policy gates.
    var hasCompleteDurableContractFields: Bool {
        let futureUse = futureUseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isCurrentContract
            && AccountMemoryKind.all.contains(targetKindRaw)
            && AccountMemoryFormationBasis.all.contains(formationBasisRaw ?? "")
            && AccountMemoryUsePolicy.all.contains(usePolicyRaw ?? "")
            && hasCompleteDurableScope
            && hasValidDurableProvenance
            && futureUse.isEmpty == false
    }

    var hasCompleteDurableScope: Bool {
        guard decodeScopeIfValid() != nil else { return false }
        switch dimensionKind {
        case AccountMemoryDimension.account:
            return true
        case AccountMemoryDimension.correspondent,
             AccountMemoryDimension.classification,
             AccountMemoryDimension.project,
             AccountMemoryDimension.translation:
            return !resolvedDimensionValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    var hasValidDurableProvenance: Bool {
        guard decodeScopeIfValid() != nil,
              let evidence = decodeEvidenceIfValid() else { return false }
        if formationBasisRaw == AccountMemoryFormationBasis.userCurated {
            return isUserCurated
        }
        let exact = evidence.filter {
            !($0.spanText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard exact.isEmpty == false else { return false }
        if formationBasisRaw == AccountMemoryFormationBasis.repeatedPattern {
            return Set(exact.map(\.messageID)).count >= 2
                && Set(exact.map { $0.threadID ?? $0.messageID }).count >= 2
        }
        return true
    }

    var isDurablePromptEligible: Bool {
        let stateAllowed = statusRaw == AccountMemoryProjectedStatus.active
            || statusRaw == AccountMemoryProjectedStatus.confirmed
        return hasCompleteDurableContractFields
            && stateAllowed
            && contradictionStateRaw == "clean"
            && supersededByMemoryKey == nil
    }

    /// Dossier dimension with the pre-expansion default applied: rows
    /// created before the dimension fields existed are account memories.
    var dimensionKind: String {
        let raw = dimensionKindRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw! : AccountMemoryDimension.account
    }

    var resolvedDimensionValue: String {
        dimensionValue ?? ""
    }

    /// Display name for the dimension value, falling back to the raw value.
    var resolvedDimensionDisplayName: String {
        let display = dimensionDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let display, display.isEmpty == false { return display }
        return resolvedDimensionValue
    }

    var displayText: String {
        let edited = userEditedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited?.isEmpty == false ? edited! : generatedText
    }

    var isHiddenByDefault: Bool {
        AccountMemoryProjectedStatus.hiddenStatuses.contains(statusRaw)
    }

    var isMarkdownExportEligible: Bool {
        isDurablePromptEligible
            && displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isSensitiveAndUnaffirmed: Bool {
        (sensitivityRiskRaw == "elevated" || sensitivityRiskRaw == "high")
            && statusRaw != AccountMemoryProjectedStatus.confirmed
            && statusRaw != AccountMemoryProjectedStatus.affirmed
    }

    func decodedScope() -> [AccountMemoryScopeReference] {
        decodeScopeIfValid() ?? []
    }

    func decodedEvidence() -> [AccountMemoryEvidenceReference] {
        decodeEvidenceIfValid() ?? []
    }

    private func decodeScopeIfValid() -> [AccountMemoryScopeReference]? {
        guard let data = scopeJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AccountMemoryScopeReference].self, from: data)
    }

    private func decodeEvidenceIfValid() -> [AccountMemoryEvidenceReference]? {
        guard let data = evidenceJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([AccountMemoryEvidenceReference].self, from: data)
    }

    static func encodeScope(_ scope: [AccountMemoryScopeReference]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(scope),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func encodeEvidence(_ evidence: [AccountMemoryEvidenceReference]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(evidence),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    var resolvedOrigin: String {
        let raw = originRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw! : AccountMemoryOrigin.inferred
    }

    func isExpired(now: Date) -> Bool {
        expiresAt.map { $0 < now } ?? false
    }

    /// Applies a material user rewrite without inventing missing generated
    /// metadata. Structurally complete current rows become confirmed,
    /// user-curated guidance; everything else remains quarantined for review.
    func applyUserEdit(_ text: String, now: Date = .now) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        userEditedText = trimmed
        if trimmed.isEmpty == false {
            formationBasisRaw = AccountMemoryFormationBasis.userCurated
            let hasReusableStructure = isCurrentContract
                && AccountMemoryKind.all.contains(targetKindRaw)
                && AccountMemoryUsePolicy.all.contains(usePolicyRaw ?? "")
                && !(futureUseText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && hasCompleteDurableScope
                && contradictionStateRaw == "clean"
                && supersededByMemoryKey == nil
            if hasReusableStructure {
                statusRaw = AccountMemoryProjectedStatus.confirmed
                lastAffirmedAt = now
            } else {
                statusRaw = AccountMemoryProjectedStatus.needsReview
            }
        }
        updatedAt = now
    }
}

/// Per-account driver state for background memory refresh. Counts are stored
/// at the last successful projection so the scheduler can seed by account
/// deltas instead of relying on a corpus-wide actionability snapshot.
@Model
public final class AccountMemoryRefreshState {
    public var id: UUID
    public var accountID: UUID
    public var lastRunStartedAt: Date?
    public var lastRunCompletedAt: Date?
    public var lastSuccessfulRunAt: Date?
    public var lastEligibleMessageCount: Int
    public var lastSentMessageCount: Int
    public var lastReceivedMessageCount: Int
    public var cursorDate: Date?
    public var cursorMessageID: UUID?
    public var cursorProcessedMessageCount: Int
    public var lastStatusRaw: String
    public var lastError: String?
    public var lastTriggerReasonRaw: String?
    public var updatedAt: Date
    /// Optional storage so lightweight migration can add the field to existing
    /// rows. Nil behaves as false, which starts legacy stores in backfill mode.
    @Attribute(originalName: "backfillCompleted")
    public var backfillCompletedValue: Bool?

    /// Whether the one-time newest→oldest full-history backfill has completed.
    /// Once the extraction cursor drains the entire corpus in a successful run
    /// this is set to `true` and the worker switches to the normal oldest→newest
    /// incremental walk.
    public var backfillCompleted: Bool {
        get { backfillCompletedValue ?? false }
        set { backfillCompletedValue = newValue }
    }

    /// Records which extraction contract version (`DiscourseMemory.threadVersion`)
    /// the account's cursor state was built under. Optional so SwiftData
    /// lightweight migration adds it as NULL to existing rows. A mismatch
    /// against the current contract version re-enters newest-first backfill:
    /// the worker resets `backfillCompleted` to `false` and clears the cursor
    /// so a corpus-wide extraction contract bump reprocesses the mailbox
    /// newest-first at the (faster) backfill budget instead of drifting
    /// through it oldest-first at the slow incremental budget.
    public var extractionContractVersionRaw: String?

    /// Durable exactly-once progress for bounded memory-distillation batches.
    /// Optional JSON keeps lightweight migration safe; a successful full
    /// refresh clears it after every dossier has completed.
    public var distillationResumeJSON: String?

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        lastRunStartedAt: Date? = nil,
        lastRunCompletedAt: Date? = nil,
        lastSuccessfulRunAt: Date? = nil,
        lastEligibleMessageCount: Int = 0,
        lastSentMessageCount: Int = 0,
        lastReceivedMessageCount: Int = 0,
        cursorDate: Date? = nil,
        cursorMessageID: UUID? = nil,
        cursorProcessedMessageCount: Int = 0,
        lastStatusRaw: String = AccountMemoryRefreshStatus.idle,
        lastError: String? = nil,
        lastTriggerReasonRaw: String? = nil,
        updatedAt: Date = .now,
        backfillCompleted: Bool = false,
        extractionContractVersionRaw: String? = nil,
        distillationResumeJSON: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.lastRunStartedAt = lastRunStartedAt
        self.lastRunCompletedAt = lastRunCompletedAt
        self.lastSuccessfulRunAt = lastSuccessfulRunAt
        self.lastEligibleMessageCount = lastEligibleMessageCount
        self.lastSentMessageCount = lastSentMessageCount
        self.lastReceivedMessageCount = lastReceivedMessageCount
        self.cursorDate = cursorDate
        self.cursorMessageID = cursorMessageID
        self.cursorProcessedMessageCount = cursorProcessedMessageCount
        self.lastStatusRaw = lastStatusRaw
        self.lastError = lastError
        self.lastTriggerReasonRaw = lastTriggerReasonRaw
        self.updatedAt = updatedAt
        self.backfillCompletedValue = backfillCompleted
        self.extractionContractVersionRaw = extractionContractVersionRaw
        self.distillationResumeJSON = distillationResumeJSON
    }
}
