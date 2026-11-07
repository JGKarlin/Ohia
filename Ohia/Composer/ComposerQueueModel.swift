// Ohia/Composer/ComposerQueueModel.swift
// Shared queue builder for the Composer: which replies are in the drafting
// workflow and where each one stands. Consumed by the Composer window's
// queue pane and by the Almanac's Composer pane (which renders the same
// items as read-only entry points).

import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

nonisolated enum ComposerGenerationTaskPresentation {
    static let applyingStyleAdjustments = "applying style adjustments"

    static func isApplyingStyleAdjustments(
        pendingInstruction: String?,
        hasPendingStyleAdjustment: Bool,
        isGenerationBlocked: Bool = false,
        isRegeneratingExistingDraft: Bool = false
    ) -> Bool {
        guard hasPendingStyleAdjustment, !isGenerationBlocked else { return false }
        return isRegeneratingExistingDraft
            || pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
                == DraftGenerationOrchestrator.regenerationInstruction
    }

    static func isGenerationBlocked(_ draft: Draft, now: Date = Date()) -> Bool {
        DraftGenerationOrchestrator.hasContextPackWaitTimedOut(draft, now: now)
            || (draft.generationFailureCount != nil
                && (draft.nextGenerationAttemptAt ?? .distantPast) > now)
    }

    /// Why drafting is blocked, empty when it is not. A content failure that
    /// waits for an explicit retry names its recorded cause (written for the
    /// author: an unusable draft, a source to remove), so the author sees what
    /// went wrong rather than only that it did. Content failures stop
    /// automatic attempts at once; engine failures only after
    /// `maximumAutomaticAttempts`, and their recorded text is diagnostic, not
    /// shown.
    static func generationBlockedReason(_ draft: Draft, now: Date = Date()) -> String {
        if DraftGenerationOrchestrator.hasContextPackWaitTimedOut(draft, now: now) {
            return "Could not prepare evidence for this draft. Retry when the retrieval model is available."
        }
        guard let attempts = draft.generationFailureCount,
              (draft.nextGenerationAttemptAt ?? .distantPast) > now else { return "" }
        guard draft.nextGenerationAttemptAt == .distantFuture else {
            return "Draft generation failed. Retry now or wait for the next automatic attempt."
        }
        let preserved = "Your instructions and changes are preserved."
        guard attempts < DraftGenerationOrchestrator.maximumAutomaticAttempts else {
            return "The draft could not be completed after \(attempts) attempts. \(preserved)"
        }
        let cause = (draft.generationFailureDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let closed = cause.last.map { ".!?。！？」』)）\"'".contains($0) } ?? true
        let sentence = closed ? cause : cause + "."
        return (["The draft could not be completed."] + (sentence.isEmpty ? [] : [sentence]) + [preserved])
            .joined(separator: " ")
    }
}

/// One row in the Composer queue. Every field is information the user acts
/// on: who, what, how urgent, and where the draft stands in the workflow.
nonisolated struct ComposerQueueItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// AI-drafted reply to an inbound message; `id` is the message id
        /// (for in-progress drafts) or the outbox item id (for send-status
        /// rows).
        case reply
        /// User-compose draft written in the Composer; `id` is the draft id
        /// (in-progress) or the outbox item id (send-status row).
        case compose
    }

    enum WorkState: Equatable, Sendable {
        enum WritingTask: Equatable, Sendable {
            case draft
            case styleAdjustments
        }

        /// Triage queued the message; its source-compilation draft is not yet
        /// seeded (model loading or backlog).
        case queued
        /// Background preparation finished and the packed sources are waiting
        /// for explicit Composer entry.
        case sourcesReady
        /// Background preparation reached its terminal retry state.
        case sourcePreparationFailed
        /// A Needs Reply row has not acquired a preparation record yet.
        case sourcesNotPrepared
        /// A compose setup or explicit source edit is waiting for user action.
        case curatingSources
        /// The model is evaluating compiled or re-checked sources to decide
        /// whether anything needs asking.
        case evaluatingSources
        /// Automatic content-derived research is still enriching the source list.
        case researchingSources
        /// The sources were sufficient — no questions — and the draft is ready
        /// for the user to generate on demand.
        case readyToDraft
        /// Questions are waiting for the user's decisions.
        case awaitingDecisions(open: Int)
        /// Retrieval is preparing the context pack required before Qwen can write.
        case preparingEvidence
        /// Generation is paused after a recoverable context/model failure.
        case generationBlocked
        /// The generation worker owes this draft its next version.
        case writing(task: WritingTask = .draft)
        /// A draft version is ready for review, revision, or sending.
        case draftReady(version: Int)
        /// A pending user-compose draft.
        case composeDraft
        /// Waiting for an outbox attempt, including a scheduled retry.
        case queuedToSend
        /// An outbox send attempt is in progress.
        case sending
        /// A send attempt failed; retry is available.
        case failed

        /// Queue ordering: failures demand attention first, then the pre-draft
        /// states the user owes (decisions, ready-to-draft, sources to review),
        /// then drafts ready for review, then work the model owes (evaluating,
        /// writing), then intake, then in-flight sends.
        var sortRank: Int {
            switch self {
            case .failed: 0
            case .awaitingDecisions: 1
            case .readyToDraft: 2
            case .sourcesReady: 3
            case .curatingSources: 4
            case .draftReady: 5
            case .composeDraft: 6
            case .researchingSources: 7
            case .evaluatingSources: 8
            case .generationBlocked: 9
            case .sourcePreparationFailed: 10
            case .preparingEvidence: 11
            case .writing: 12
            case .queued: 13
            case .sourcesNotPrepared: 14
            case .queuedToSend, .sending: 15
            }
        }

        var label: String {
            switch self {
            case .queued: "compiling sources"
            case .sourcesReady: "sources ready"
            case .sourcePreparationFailed: "source preparation failed"
            case .sourcesNotPrepared: "sources not prepared"
            case .curatingSources: "sources to review"
            case .evaluatingSources: "formulating questions"
            case .researchingSources: "compiling sources"
            case .readyToDraft: "ready to draft"
            case .awaitingDecisions(let open):
                open == 1 ? "1 decision waiting" : "\(open) decisions waiting"
            case .preparingEvidence: "preparing evidence"
            case .generationBlocked: "retry needed"
            case .writing(let task):
                task == .styleAdjustments
                    ? ComposerGenerationTaskPresentation.applyingStyleAdjustments
                    : "writing draft"
            case .draftReady(let version): "draft ready · v\(version)"
            case .composeDraft: "compose draft"
            case .sending: "sending"
            case .queuedToSend: "queued to send"
            case .failed: "send failed"
            }
        }

        var showsProgressIndicator: Bool {
            switch self {
            case .queued, .evaluatingSources, .researchingSources, .writing:
                true
            default: false
            }
        }

        /// A failed send — surfaces the warning glyph and the Retry action.
        var isFailed: Bool { self == .failed }

        /// A confirmed item in the outbox (sending or failed) rather than a
        /// draft still being written. Drives which management actions appear.
        var isOutbox: Bool { self == .queuedToSend || self == .sending || self == .failed }

        /// A draft ready to push straight to send.
        var isSendable: Bool {
            switch self {
            case .draftReady, .composeDraft: true
            default: false
            }
        }
    }

    /// The name a compose draft shows before it has a recipient.
    static let noRecipientName = "(no recipient)"

    let id: UUID
    let kind: Kind
    let name: String
    let subject: String
    let state: WorkState
    let receivedAt: Date
    let urgency: Double
    /// Surface deadline text from triage ("by Friday"), when stated.
    let deadline: String?
}

nonisolated enum ComposerQueueModel {

    /// Builds the live queue: pending reply drafts (any stage), actionable
    /// messages still awaiting question generation, and pending compose
    /// drafts. Ordered by workflow rank, then urgency, then recency.
    static func build(context: ModelContext) -> [ComposerQueueItem] {
        (try? load(context: context)) ?? []
    }

    /// Refresh owners keep their last successful snapshot when a store read
    /// fails; a failed fetch must not masquerade as an empty queue.
    static func load(context: ModelContext) throws -> [ComposerQueueItem] {
        // This runs on a 2.5s poll while the Composer is open, so the fetch
        // must not materialize the whole store (10k–100k rows). The shared
        // candidate scan (also used by pipeline intake and pack preparation)
        // narrows to live inbound mail plus explicit "Send to Composer"
        // additions; `requiresReply` is deliberately not in the predicates —
        // pre-column legacy rows are NULL in SQL and would be dropped — so
        // the canonical `isComposerQueueEligible` check filters in memory.
        let automaticTriageQueueingEnabled = ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        let messages = try DraftGenerationOrchestrator.loadQueueCandidateMessages(
            context: context,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).filter {
            $0.placedAt != nil && $0.isComposerQueueEligible(
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            )
        }
        guard !Task.isCancelled else { return [] }
        let decoder = JSONDecoder()
        var preparations: [ReplySourcePreparation] = []
        let candidateIDs = messages.map(\.id)
        for offset in stride(from: 0, to: candidateIDs.count, by: 200) {
            guard !Task.isCancelled else { return [] }
            let ids = Array(candidateIDs[offset..<min(offset + 200, candidateIDs.count)])
            let descriptor = FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> { ids.contains($0.messageId) }
            )
            preparations.append(contentsOf: try context.fetch(descriptor))
        }
        let preparationByMessageID = preferredPreparationsByMessageID(preparations)

        var items: [ComposerQueueItem] = []

        // Membership is `Message.isComposerQueueEligible` (applied above):
        // explicit user "Send to Composer" additions, plus automatic
        // actionable live-inbound mail only when Settings allows it, minus
        // explicit removals — one item per conversation, replying to its
        // newest qualifying email. Analysis is not required for display — a
        // user-added message without interpretation shows as "preparing
        // questions" until the pipeline catches up.
        for msg in messages {
            guard !Task.isCancelled else { return [] }
            guard msg.placedAt != nil else { continue }
            let state: ComposerQueueItem.WorkState
            // A queue discard can delete Draft after this read fetched Message.
            // Following msg.draft then faults a missing row and traps inside
            // SwiftData before an error can be caught. Fetch the live draft
            // directly, including revisions used for its queue presentation.
            let messageID = msg.id
            var draftDescriptor = FetchDescriptor<Draft>(predicate: #Predicate {
                $0.message?.id == messageID
            })
            draftDescriptor.fetchLimit = 1
            draftDescriptor.relationshipKeyPathsForPrefetching = [\Draft.revisions]
            if let draft = try context.fetch(draftDescriptor).first {
                guard draft.status == .pending else { continue }
                if draft.pendingInstruction?.isEmpty == false {
                    let generationBlocked = ComposerGenerationTaskPresentation
                        .isGenerationBlocked(draft)
                    state = generationBlocked
                        ? .generationBlocked
                        : (ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                            pendingInstruction: draft.pendingInstruction,
                            hasPendingStyleAdjustment: draft.hasPendingStyleControlDecision
                        ) ? .writing(task: .styleAdjustments) : .writing())
                } else if draft.isAutomaticSourceResearchPending {
                    state = .researchingSources
                } else {
                    switch draft.resolvedStage {
                    case DraftStage.collectingSources:
                        state = .curatingSources
                    case DraftStage.evaluatingSources:
                        state = .evaluatingSources
                    case DraftStage.collectingAnswers:
                        state = interviewWorkState(for: draft)
                    case DraftStage.generating:
                        let now = Date()
                        if ComposerGenerationTaskPresentation.isGenerationBlocked(draft, now: now) {
                            state = .generationBlocked
                        } else if DraftGenerationOrchestrator.isWaitingForContextPack(draft, now: now) {
                            state = .preparingEvidence
                        } else {
                            state = .writing()
                        }
                    default:
                        state = .draftReady(version: max(draft.orderedRevisions.count, 1))
                    }
                }
            } else if ReplySourcePreparationEligibility.isEligible(
                msg,
                context: context
            ) {
                switch preparationByMessageID[msg.id]?.statusRaw {
                case ReplySourcePreparationStatus.ready:
                    state = .sourcesReady
                case ReplySourcePreparationStatus.pending,
                     ReplySourcePreparationStatus.compilingSources:
                    state = .queued
                case ReplySourcePreparationStatus.formulatingQuestions:
                    state = .evaluatingSources
                case ReplySourcePreparationStatus.drafting:
                    state = .writing()
                case ReplySourcePreparationStatus.retryWaiting:
                    state = .sourcePreparationFailed
                default:
                    state = .sourcesNotPrepared
                }
            } else {
                // Explicit non-Needs-Reply rows remain owned by ordinary
                // queue intake, which is actively compiling their visible
                // source-backed draft before question evaluation.
                state = .queued
            }

            items.append(ComposerQueueItem(
                id: msg.id,
                kind: .reply,
                name: msg.fromName ?? msg.fromAddress,
                subject: displaySubject(msg.subject),
                state: state,
                receivedAt: msg.receivedAt ?? msg.ingestedAt,
                urgency: 0,
                deadline: deadlineText(msg, decoder: decoder)
            ))
        }

        // Pending user-compose drafts — the in-Composer compose surface
        // (recipient editor + AI drafting) renders these when selected.
        let drafts = try context.fetch(FetchDescriptor<Draft>())
        let replyDraftsWithRemoteCopy = drafts.filter { draft in
            draft.kind != .userCompose && hasMailboxDraftRemoteIdentity(draft)
        }
        for draft in drafts where draft.kind == .userCompose && draft.status == .pending {
            guard !Task.isCancelled else { return [] }
            if replyDraftsWithRemoteCopy.contains(where: { mailboxDraftsReferToSameRemoteCopy(draft, $0) }) {
                continue
            }
            let recipients = ComposeAddressEncoding.decode(draft.composeToJSON)
            let state: ComposerQueueItem.WorkState
            if draft.pendingInstruction?.isEmpty == false {
                let generationBlocked = ComposerGenerationTaskPresentation
                    .isGenerationBlocked(draft)
                state = generationBlocked
                    ? .generationBlocked
                    : (ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                        pendingInstruction: draft.pendingInstruction,
                        hasPendingStyleAdjustment: draft.hasPendingStyleControlDecision
                    ) ? .writing(task: .styleAdjustments) : .writing())
            } else if draft.isAutomaticSourceResearchPending {
                state = .researchingSources
            } else {
                switch draft.resolvedStage {
                case DraftStage.collectingSources:
                    state = .curatingSources
                case DraftStage.evaluatingSources:
                    state = .evaluatingSources
                case DraftStage.collectingAnswers:
                    state = interviewWorkState(for: draft)
                case DraftStage.generating:
                    let now = Date()
                    if ComposerGenerationTaskPresentation.isGenerationBlocked(draft, now: now) {
                        state = .generationBlocked
                    } else if DraftGenerationOrchestrator.isWaitingForContextPack(draft, now: now) {
                        state = .preparingEvidence
                    } else if ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                        pendingInstruction: draft.pendingInstruction,
                        hasPendingStyleAdjustment: draft.hasPendingStyleControlDecision,
                        isRegeneratingExistingDraft: !draft.orderedRevisions.isEmpty
                    ) {
                        state = .writing(task: .styleAdjustments)
                    } else {
                        state = .writing()
                    }
                default:
                    state = .composeDraft
                }
            }
            items.append(ComposerQueueItem(
                id: draft.id,
                kind: .compose,
                name: recipients.first ?? ComposerQueueItem.noRecipientName,
                subject: displaySubject(draft.composeSubject),
                state: state,
                receivedAt: draft.generatedAt,
                urgency: 0,
                deadline: nil
            ))
        }

        // Confirmed sends, in flight or failed — the queue IS the outbox.
        // Sent and cancelled items leave the queue (reviewed in the lenses);
        // failed sends stay, surfaced for retry. `id` is the outbox item id.
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        for item in outbox {
            guard !Task.isCancelled else { return [] }
            let state: ComposerQueueItem.WorkState
            switch item.status {
            case .queued: state = .queuedToSend
            case .sending: state = .sending
            case .failed: state = .failed
            default: continue
            }
            items.append(ComposerQueueItem(
                id: item.id,
                kind: item.draft?.kind == .userCompose ? .compose : .reply,
                name: outboxRecipientName(item),
                subject: displaySubject(item.subject),
                state: state,
                receivedAt: item.createdAt,
                urgency: state == .failed ? 1.0 : 0,
                deadline: nil
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            return lhs.receivedAt > rhs.receivedAt
        }
    }

    private static func interviewWorkState(for draft: Draft) -> ComposerQueueItem.WorkState {
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              state.planningOutcome != .invalid else {
            return .readyToDraft
        }
        return ComposerInterviewExecutor.project(state).currentNode == nil
            ? .readyToDraft
            : .awaitingDecisions(open: 1)
    }

    private static func hasMailboxDraftRemoteIdentity(_ draft: Draft) -> Bool {
        guard draft.mailboxDraftAccountID != nil else {
            return false
        }
        let uid = draft.mailboxDraftUID.flatMap { $0 > 0 ? $0 : nil }
        let messageID = normalizedMessageIDHeader(draft.mailboxDraftMessageIDHeader)
        return uid != nil || messageID != nil
    }

    private static func mailboxDraftsReferToSameRemoteCopy(_ lhs: Draft, _ rhs: Draft) -> Bool {
        guard let lhsAccountID = lhs.mailboxDraftAccountID,
              let rhsAccountID = rhs.mailboxDraftAccountID,
              lhsAccountID == rhsAccountID else {
            return false
        }

        if let lhsMessageID = normalizedMessageIDHeader(lhs.mailboxDraftMessageIDHeader),
           let rhsMessageID = normalizedMessageIDHeader(rhs.mailboxDraftMessageIDHeader),
           lhsMessageID == rhsMessageID {
            return true
        }

        guard let lhsFolder = nonBlank(lhs.mailboxDraftFolderPath),
              let rhsFolder = nonBlank(rhs.mailboxDraftFolderPath),
              lhsFolder == rhsFolder,
              let lhsUID = lhs.mailboxDraftUID.flatMap({ $0 > 0 ? $0 : nil }),
              let rhsUID = rhs.mailboxDraftUID.flatMap({ $0 > 0 ? $0 : nil }),
              lhsUID == rhsUID else {
            return false
        }

        guard let lhsValidity = lhs.mailboxDraftUIDValidity,
              let rhsValidity = rhs.mailboxDraftUIDValidity else {
            return true
        }
        return lhsValidity == rhsValidity
    }

    private static func displaySubject(_ value: String?) -> String {
        guard let subject = nonBlank(value) else { return "(no subject)" }
        return MIMEHeaderDecoder.decodeEncodedWords(subject)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedMessageIDHeader(_ value: String?) -> String? {
        guard var trimmed = nonBlank(value) else { return nil }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.lowercased()
    }

    /// The recipient shown for an outbox (send-status) row — the first To
    /// address, with a "+N" suffix when there are several.
    private static func outboxRecipientName(_ item: OutboxItem) -> String {
        guard let data = item.toAddressesJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data),
              let first = list.first else {
            return item.fromAddress
        }
        return list.count > 1 ? "\(first) +\(list.count - 1)" : first
    }

    private static func preferredPreparationsByMessageID(
        _ preparations: [ReplySourcePreparation]
    ) -> [UUID: ReplySourcePreparation] {
        var result: [UUID: ReplySourcePreparation] = [:]
        for preparation in preparations {
            guard let existing = result[preparation.messageId] else {
                result[preparation.messageId] = preparation
                continue
            }
            if preparationPrecedes(preparation, existing) {
                result[preparation.messageId] = preparation
            }
        }
        return result
    }

    private static func preparationPrecedes(
        _ lhs: ReplySourcePreparation,
        _ rhs: ReplySourcePreparation
    ) -> Bool {
        func rank(_ status: String) -> Int {
            switch status {
            case ReplySourcePreparationStatus.ready: 0
            case ReplySourcePreparationStatus.drafting: 1
            case ReplySourcePreparationStatus.formulatingQuestions: 2
            case ReplySourcePreparationStatus.compilingSources: 3
            case ReplySourcePreparationStatus.pending: 4
            case ReplySourcePreparationStatus.retryWaiting: 5
            default: 6
            }
        }

        let lhsRank = rank(lhs.statusRaw)
        let rhsRank = rank(rhs.statusRaw)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func deadlineText(_ msg: Message, decoder: JSONDecoder) -> String? {
        guard let json = msg.analysis?.triageVerdictJSON,
              let data = json.data(using: .utf8),
              let verdict = try? decoder.decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.action?.deadline?.dateString
    }
}
