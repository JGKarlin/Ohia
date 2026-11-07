import Foundation
import OhiaCore

public enum TaskUnitType: String, Codable, Sendable {
    case search
    case locateAttachment
    case compare
    case summarize
    case compose
}

public struct TaskUnit: Codable, Sendable {
    public let description: String
    public let taskType: TaskUnitType
    public let searchQuery: String
    public let index: Int

    public init(description: String, taskType: TaskUnitType, searchQuery: String, index: Int) {
        self.description = description
        self.taskType = taskType
        self.searchQuery = searchQuery
        self.index = index
    }
}

public enum AgentResultStatus: String, Codable, Sendable {
    case completed
    case needsInput
    case lowConfidence
}

public struct Finding: Codable, Sendable {
    public let text: String
    public let sourceMessageId: String?
    public let confidence: Double

    public init(text: String, sourceMessageId: String? = nil, confidence: Double) {
        self.text = text
        self.sourceMessageId = sourceMessageId
        self.confidence = confidence
    }
}

public struct Deliverable: Codable, Sendable {
    public let filename: String
    public let filePath: String
    public let sourceMessageId: String

    public init(filename: String, filePath: String, sourceMessageId: String) {
        self.filename = filename
        self.filePath = filePath
        self.sourceMessageId = sourceMessageId
    }
}

public struct Gap: Codable, Sendable {
    public let description: String
    public let whatWasSearched: String
    public let whatWasFound: String?
    public let suggestedAction: String

    public init(description: String, whatWasSearched: String, whatWasFound: String? = nil, suggestedAction: String) {
        self.description = description
        self.whatWasSearched = whatWasSearched
        self.whatWasFound = whatWasFound
        self.suggestedAction = suggestedAction
    }
}

public struct AgentResult: Codable, Sendable {
    public let taskDescription: String
    public let status: AgentResultStatus
    public let findings: [Finding]
    public let deliverables: [Deliverable]
    public let gaps: [Gap]

    public init(
        taskDescription: String,
        status: AgentResultStatus,
        findings: [Finding] = [],
        deliverables: [Deliverable] = [],
        gaps: [Gap] = []
    ) {
        self.taskDescription = taskDescription
        self.status = status
        self.findings = findings
        self.deliverables = deliverables
        self.gaps = gaps
    }
}

/// Wraps a task description and its agent result status as a Sendable struct.
/// (Replaces the tuple `(description: String, status: AgentResultStatus)` which is
/// not unconditionally Sendable under Swift 6 strict concurrency.)
public struct TaskStatus: Codable, Sendable {
    public let description: String
    public let status: AgentResultStatus

    public init(description: String, status: AgentResultStatus) {
        self.description = description
        self.status = status
    }
}

/// A durable account memory selected for injection into a draft prompt,
/// labeled with the dossier dimension that matched the incoming message
/// (the correspondent, a classification facet, a project, or the account itself).
public struct MemoryNote: Codable, Sendable, Equatable {
    public let dimensionLabel: String
    public let text: String
    public let status: String
    public let weight: Double
    /// Ledger provenance carried from the source `AccountMemory` row so the
    /// prompt builders can weigh explicit assertions over inferences and
    /// surface temporal / conditional scope. Optional so context packs written
    /// before the ledger (which lack these keys) decode with nils — the
    /// synthesized `Codable` decodes absent keys for optionals as nil.
    public let originRaw: String?
    public let assertedBy: String?
    public let asOf: Date?
    public let expiresAt: Date?
    public let kindRaw: String?
    public let conditionsText: String?
    /// Why this guidance qualified as durable, how it may be used, and the
    /// concrete future situation in which it should influence the model.
    public let formationBasisRaw: String?
    public let usePolicyRaw: String?
    public let futureUseText: String?
    /// The source memory's contradiction state (contested | superseded |
    /// scopeNarrowed) when it is anything other than "clean". Appended last so
    /// context packs written before the ledger decode it as nil.
    public let contradictionRaw: String?

    public init(
        dimensionLabel: String,
        text: String,
        status: String,
        weight: Double,
        originRaw: String? = nil,
        assertedBy: String? = nil,
        asOf: Date? = nil,
        expiresAt: Date? = nil,
        kindRaw: String? = nil,
        conditionsText: String? = nil,
        formationBasisRaw: String? = nil,
        usePolicyRaw: String? = nil,
        futureUseText: String? = nil,
        contradictionRaw: String? = nil
    ) {
        self.dimensionLabel = dimensionLabel
        self.text = text
        self.status = status
        self.weight = weight
        self.originRaw = originRaw
        self.assertedBy = assertedBy
        self.asOf = asOf
        self.expiresAt = expiresAt
        self.kindRaw = kindRaw
        self.conditionsText = conditionsText
        self.formationBasisRaw = formationBasisRaw
        self.usePolicyRaw = usePolicyRaw
        self.futureUseText = futureUseText
        self.contradictionRaw = contradictionRaw
    }
}

/// Question-interview authority carried into the actual prompt rendering.
/// Current transactional values remain guidance-only regardless of this base
/// classification; the interview prompt enforces that operation-specific rule.
enum MemoryQuestionAuthority: String, Sendable, Equatable {
    case settlesDurableQuestion = "settles-durable-question"
    case requiresConfirmation = "requires-confirmation"
    case guidanceOnly = "guidance-only"

    static func classify(
        _ note: MemoryNote,
        asksForCurrentTransactionalValue: Bool = false
    ) -> Self {
        if note.contradictionRaw == ContradictionState.contested.rawValue
            || note.status == AccountMemoryProjectedStatus.contested {
            return .requiresConfirmation
        }
        guard asksForCurrentTransactionalValue == false else { return .guidanceOnly }
        guard note.usePolicyRaw == AccountMemoryUsePolicy.assertableKnowledge else {
            return .guidanceOnly
        }
        let reliableBasis = note.formationBasisRaw == AccountMemoryFormationBasis.explicitStanding
            || note.formationBasisRaw == AccountMemoryFormationBasis.explicitCorrection
            || note.formationBasisRaw == AccountMemoryFormationBasis.userCurated
        let reliableState = note.status == AccountMemoryProjectedStatus.confirmed || reliableBasis
        return reliableState ? .settlesDurableQuestion : .guidanceOnly
    }
}

/// The single rendering path for a `MemoryNote` shared across every prompt
/// surface — reply Composer sources, the compose `[MEMORY NOTES]` section,
/// and the interview's known-context digest — so the reliability tags read
/// identically everywhere, with no local formatting drift.
public enum MemoryNoteRendering {

    public struct UseGroup: Sendable, Equatable {
        public let policyRaw: String
        public let notes: [MemoryNote]
    }

    private static let orderedPolicies = [
        AccountMemoryUsePolicy.internalGuidance,
        AccountMemoryUsePolicy.draftingGuidance,
        AccountMemoryUsePolicy.contextualOrientation,
        AccountMemoryUsePolicy.assertableKnowledge,
    ]

    /// Shared outbound precedence and privacy contract used by compose and
    /// reply prompts.
    public static let precedenceGuidance = "Current user instructions and current source evidence override memory. Never reveal that memory was used. Never state or paraphrase internal guidance. Do not strengthen a memory beyond its wording, scope, conditions, or use policy."

    /// The memory conflict instruction used by compose and interview prompts.
    /// Reply prompts receive each selected note through their persisted
    /// Composer source pack instead of a parallel hidden section.
    public static let conflictGuidance = "Durable guidance distilled from past correspondence. Apply a note only when its scope, conditions, future use, and use policy fit this exact request. The current thread and the user's current instruction always override memory. Never state internalGuidance as an outbound fact; use draftingGuidance to shape the draft; use contextualOrientation only as background; state assertableKnowledge only when relevant."

    public static func groups(for notes: [MemoryNote]) -> [UseGroup] {
        let grouped = Dictionary(grouping: notes) { $0.usePolicyRaw ?? "" }
        return orderedPolicies.compactMap { policy in
            guard let values = grouped[policy], values.isEmpty == false else { return nil }
            return UseGroup(policyRaw: policy, notes: values)
        }
    }

    public static func sectionHeader(for policy: String) -> String {
        switch policy {
        case AccountMemoryUsePolicy.internalGuidance:
            return "[MEMORY — INTERNAL GUIDANCE]"
        case AccountMemoryUsePolicy.draftingGuidance:
            return "[MEMORY — DRAFTING GUIDANCE]"
        case AccountMemoryUsePolicy.contextualOrientation:
            return "[MEMORY — CONTEXTUAL ORIENTATION]"
        case AccountMemoryUsePolicy.assertableKnowledge:
            return "[MEMORY — ASSERTABLE KNOWLEDGE]"
        default:
            return "[MEMORY NOTES]"
        }
    }

    public static func policyGuidance(for policy: String) -> String {
        switch policy {
        case AccountMemoryUsePolicy.internalGuidance:
            return "Use these notes only to guide private reasoning. Never state or paraphrase these notes to the recipient."
        case AccountMemoryUsePolicy.draftingGuidance:
            return "Use these notes to control language, tone, structure, routing, or process. Do not present them as facts about the recipient."
        case AccountMemoryUsePolicy.contextualOrientation:
            return "Use these notes as background for interpretation. Do not independently assert them in the email."
        case AccountMemoryUsePolicy.assertableKnowledge:
            return "These notes may be stated only when directly relevant and not contradicted by the current thread or user instruction."
        default:
            return ""
        }
    }

    /// One prompt line for a note: `- (dimensionLabel, status[, origin][,
    /// contradiction][, as of yyyy-MM-dd][, applies: conditions][, expires
    /// yyyy-MM-dd]) text`. Every tag after `status` is appended only when its
    /// field is present and non-empty, in that fixed order; dates format as
    /// `yyyy-MM-dd` in UTC. Never emits an ellipsis.
    public static func line(for note: MemoryNote) -> String {
        var tags = [note.dimensionLabel, note.status]
        tags.append("question-authority: \(MemoryQuestionAuthority.classify(note).rawValue)")
        if let origin = note.originRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            tags.append(origin)
        }
        if let contradiction = note.contradictionRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contradiction.isEmpty {
            tags.append(contradiction)
        }
        if let asOf = note.asOf {
            tags.append("as of \(formattedDay(asOf))")
        }
        if let conditions = note.conditionsText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !conditions.isEmpty {
            tags.append("applies: \(conditions)")
        }
        if let basis = note.formationBasisRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !basis.isEmpty {
            tags.append("basis: \(basis)")
        }
        if let policy = note.usePolicyRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !policy.isEmpty {
            tags.append("policy: \(policy)")
        }
        if let futureUse = note.futureUseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !futureUse.isEmpty {
            tags.append("future use: \(futureUse)")
        }
        if let expiresAt = note.expiresAt {
            tags.append("expires \(formattedDay(expiresAt))")
        }
        return "- (\(tags.joined(separator: ", "))) \(note.text)"
    }

    /// `yyyy-MM-dd` in UTC via a POSIX-locale `DateFormatter`. Built per call
    /// so the helper stays a pure, `Sendable`-safe static with no shared
    /// mutable formatter; memory notes are few (≤8 per draft), so the cost is
    /// negligible.
    private static func formattedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct AggregatedContext: Codable, Sendable {
    public let findings: [Finding]
    public let deliverables: [Deliverable]
    public let gaps: [Gap]
    public let taskStatuses: [TaskStatus]
    public let threadContext: String
    public let messageEvidenceDigest: String?
    public let correspondentName: String
    public let correspondentProfile: CorrespondentProfile?
    public let styleExemplars: [String]
    public let memoryNotes: [MemoryNote]

    public init(
        findings: [Finding],
        deliverables: [Deliverable],
        gaps: [Gap],
        taskStatuses: [TaskStatus],
        threadContext: String,
        messageEvidenceDigest: String? = nil,
        correspondentName: String,
        correspondentProfile: CorrespondentProfile?,
        styleExemplars: [String],
        memoryNotes: [MemoryNote] = []
    ) {
        self.findings = findings
        self.deliverables = deliverables
        self.gaps = gaps
        self.taskStatuses = taskStatuses
        self.threadContext = threadContext
        self.messageEvidenceDigest = messageEvidenceDigest?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? messageEvidenceDigest
            : nil
        self.correspondentName = correspondentName
        self.correspondentProfile = correspondentProfile
        self.styleExemplars = styleExemplars
        self.memoryNotes = memoryNotes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        findings = try container.decode([Finding].self, forKey: .findings)
        deliverables = try container.decode([Deliverable].self, forKey: .deliverables)
        gaps = try container.decode([Gap].self, forKey: .gaps)
        taskStatuses = try container.decode([TaskStatus].self, forKey: .taskStatuses)
        threadContext = try container.decode(String.self, forKey: .threadContext)
        messageEvidenceDigest = try container.decodeIfPresent(String.self, forKey: .messageEvidenceDigest)
        correspondentName = try container.decode(String.self, forKey: .correspondentName)
        correspondentProfile = try container.decodeIfPresent(CorrespondentProfile.self, forKey: .correspondentProfile)
        styleExemplars = try container.decode([String].self, forKey: .styleExemplars)
        // Context packs written before memory notes existed lack the key.
        memoryNotes = try container.decodeIfPresent([MemoryNote].self, forKey: .memoryNotes) ?? []
    }
}

public struct Citation: Codable, Sendable {
    public let claim: String
    public let sourceMessageId: String
    public let confidence: Double

    public init(claim: String, sourceMessageId: String, confidence: Double) {
        self.claim = claim
        self.sourceMessageId = sourceMessageId
        self.confidence = confidence
    }
}

/// Structural record of how personalized the model was when it produced a
/// draft. Captured at generation time inside the qwen worker (where the live
/// `MLXTrainingEngine` and its loaded LoRA adapter actually run) and persisted
/// onto the `Draft`, so the Composer can show an honest training-influence
/// indicator without a second generation. These are *basis counts*, never a
/// fabricated "influence %": there is no measurable per-draft LoRA effect
/// without regenerating on base weights (see `ui_design_framework_philosophical`
/// and the ghost-in-the-machine constraint — show structure, not agency).
public struct PersonalizationSnapshot: Codable, Sendable, Equatable {
    /// A trained LoRA adapter was loaded into the model for this generation.
    /// `false` means the draft was produced on base weights.
    public let adapterActive: Bool
    /// Cumulative training step of the active adapter — the latest
    /// non-archived checkpoint's `stepCount`. `0` on base weights. (Sourced
    /// from the checkpoint store, not `engine.totalSteps`, which only counts
    /// steps trained in the current worker-process session and reads `0`
    /// right after a boot-time adapter load.)
    public let adapterStep: Int
    /// Total pair revisions incorporated by promoted adapter checkpoints.
    public let totalPairsTrained: Int
    /// How many of the user's past replies to this correspondent are in the
    /// sent corpus — the per-correspondent training basis for this draft.
    public let correspondentReplyCount: Int

    public init(
        adapterActive: Bool,
        adapterStep: Int,
        totalPairsTrained: Int,
        correspondentReplyCount: Int
    ) {
        self.adapterActive = adapterActive
        self.adapterStep = adapterStep
        self.totalPairsTrained = totalPairsTrained
        self.correspondentReplyCount = correspondentReplyCount
    }

    /// The model ran on base weights (no adapter) with no recorded corpus.
    public static let base = PersonalizationSnapshot(
        adapterActive: false,
        adapterStep: 0,
        totalPairsTrained: 0,
        correspondentReplyCount: 0
    )
}

public struct DraftOutput: Codable, Sendable {
    public let replyText: String
    public let taskStatuses: [TaskStatus]
    public let citations: [Citation]
    public let deliverables: [Deliverable]
    public let gaps: [Gap]
    /// Count of style exemplars retrieved from the user's sent corpus while
    /// building this draft. Used by the UI to show how grounded the style is.
    public let styleExemplarCount: Int
    /// The drafting rules injected into this generation's prompt. The
    /// persistence layer stamps them onto the draft so rule distillation
    /// knows which rules were active.
    public let appliedRuleNotes: [DraftingRuleNote]
    /// Personalization basis captured at generation time. The persistence
    /// layer stamps it onto the `Draft` so the Composer's Style panel can
    /// report whether (and how much) training shaped this reply.
    public let personalization: PersonalizationSnapshot
    /// The `StyleRegister` that steered this generation (resolver choice or
    /// the user's picker choice). The persistence layer stamps it onto the
    /// `Draft` and the appended revision. Nil when no register applied.
    public let styleRegisterID: UUID?
    /// The output language this generation was pinned to (the draft's
    /// selection at pass start). The persistence layer compares it with the
    /// draft's *current* selection: a mismatch means the user switched
    /// language while the pass ran, so the draft keeps owing a generation
    /// instead of settling on a superseded-language body. Nil when the pass
    /// ran with no known language.
    public let languageID: String?
    /// Immutable defaults, effective axes, and intent used for this pass.
    public let styleControlSnapshot: StyleControlSnapshot?
    /// Exact pending decision consumed at prompt-build time. Persistence uses
    /// this as a compare-and-swap token so a newer slider move survives.
    public let consumedStyleDecisionID: UUID?
    public let reasoningContent: String?
    public let reasoningContinuationFingerprint: String?
    public let reasoningPrompt: String?
    /// The frozen request, brief and writer task that produced `replyText`
    /// (`ComposerGenerationBasis` JSON). Persisted with the revision.
    public let generationBasisJSON: String?
    /// The writer fit this generation used: the meter and the sources it left
    /// out, persisted on the draft so Composer shows exactly what the writer
    /// dropped.
    public let writerWindowUsage: ComposerWriterWindowUsage?

    public init(
        replyText: String,
        taskStatuses: [TaskStatus],
        citations: [Citation],
        deliverables: [Deliverable],
        gaps: [Gap],
        styleExemplarCount: Int = 0,
        appliedRuleNotes: [DraftingRuleNote] = [],
        personalization: PersonalizationSnapshot = .base,
        styleRegisterID: UUID? = nil,
        languageID: String? = nil,
        styleControlSnapshot: StyleControlSnapshot? = nil,
        consumedStyleDecisionID: UUID? = nil,
        reasoningContent: String? = nil,
        reasoningContinuationFingerprint: String? = nil,
        reasoningPrompt: String? = nil,
        generationBasisJSON: String? = nil,
        writerWindowUsage: ComposerWriterWindowUsage? = nil
    ) {
        self.replyText = replyText
        self.taskStatuses = taskStatuses
        self.citations = citations
        self.deliverables = deliverables
        self.gaps = gaps
        self.styleExemplarCount = styleExemplarCount
        self.appliedRuleNotes = appliedRuleNotes
        self.personalization = personalization
        self.styleRegisterID = styleRegisterID
        self.languageID = languageID
        self.styleControlSnapshot = styleControlSnapshot
        self.consumedStyleDecisionID = consumedStyleDecisionID
        self.reasoningContent = reasoningContent
        self.reasoningContinuationFingerprint = reasoningContinuationFingerprint
        self.reasoningPrompt = reasoningPrompt
        self.generationBasisJSON = generationBasisJSON
        self.writerWindowUsage = writerWindowUsage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replyText = try container.decode(String.self, forKey: .replyText)
        taskStatuses = try container.decode([TaskStatus].self, forKey: .taskStatuses)
        citations = try container.decode([Citation].self, forKey: .citations)
        deliverables = try container.decode([Deliverable].self, forKey: .deliverables)
        gaps = try container.decode([Gap].self, forKey: .gaps)
        styleExemplarCount = try container.decodeIfPresent(Int.self, forKey: .styleExemplarCount) ?? 0
        // Payloads written before drafting rules existed lack the key.
        appliedRuleNotes = try container.decodeIfPresent([DraftingRuleNote].self, forKey: .appliedRuleNotes) ?? []
        // Payloads written before the personalization snapshot existed lack the key.
        personalization = try container.decodeIfPresent(PersonalizationSnapshot.self, forKey: .personalization) ?? .base
        // Payloads written before style registers existed lack the key.
        styleRegisterID = try container.decodeIfPresent(UUID.self, forKey: .styleRegisterID)
        // Payloads written before language pinning existed lack the key.
        languageID = try container.decodeIfPresent(String.self, forKey: .languageID)
        styleControlSnapshot = try container.decodeIfPresent(
            StyleControlSnapshot.self,
            forKey: .styleControlSnapshot
        )
        consumedStyleDecisionID = try container.decodeIfPresent(
            UUID.self,
            forKey: .consumedStyleDecisionID
        )
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        reasoningContinuationFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .reasoningContinuationFingerprint
        )
        reasoningPrompt = try container.decodeIfPresent(String.self, forKey: .reasoningPrompt)
        generationBasisJSON = try container.decodeIfPresent(String.self, forKey: .generationBasisJSON)
        writerWindowUsage = try container.decodeIfPresent(ComposerWriterWindowUsage.self, forKey: .writerWindowUsage)
    }
}

public struct DraftRevisionOutput: Equatable, Sendable {
    public let replyText: String
    public let reasoningContent: String?
    public let reasoningContinuationFingerprint: String?
    public let reasoningPrompt: String?
    public let generationBasisJSON: String?
    /// The writer fit this revision used, as on `DraftOutput`.
    public let writerWindowUsage: ComposerWriterWindowUsage?

    public init(
        replyText: String,
        reasoningContent: String? = nil,
        reasoningContinuationFingerprint: String? = nil,
        reasoningPrompt: String? = nil,
        generationBasisJSON: String? = nil,
        writerWindowUsage: ComposerWriterWindowUsage? = nil
    ) {
        self.replyText = replyText
        self.reasoningContent = reasoningContent
        self.reasoningContinuationFingerprint = reasoningContinuationFingerprint
        self.reasoningPrompt = reasoningPrompt
        self.generationBasisJSON = generationBasisJSON
        self.writerWindowUsage = writerWindowUsage
    }
}

public struct ToolResult: Codable, Sendable {
    public let findings: [Finding]
    public let deliverables: [Deliverable]

    public init(findings: [Finding] = [], deliverables: [Deliverable] = []) {
        self.findings = findings
        self.deliverables = deliverables
    }
}
