import Foundation
import SwiftData
import OhiaCore
import OhiaML

/// Keeps pending reply drafts in step with their threads. A thread can gain
/// an email after a draft's sources were compiled that belongs before the
/// replied-to message — most often the author's own reply, which reaches Ohia
/// through a slower folder sync than the correspondent's answer to it. A draft
/// written without that email can contradict what the author already said.
///
/// - A draft whose body the author has not shaped is rebuilt in place: its
///   automatic sources recompile from the full thread (user-added sources
///   are kept), the interview is planned again, and the earlier answers and
///   generated text are dropped.
/// - An author-shaped draft keeps its text. The missed emails join its
///   sources, so the Composer shows that Regenerate would apply them.
/// - The reply open in the Composer always takes the second path: its editor
///   may hold unsaved text no store read can see, and the author is looking
///   at it, so the note reaches them at once.
///
/// A conversation is one Composer queue item replying to its newest
/// qualifying email (`Message.composerConversationQueueResolution`). When a
/// newer qualifying email arrives, a pending draft on an older email moves to
/// it — the draft now replies to the newest email — and then follows the same
/// rule: rebuilt for it when untouched, or kept with the email it replied to
/// added as a source when shaped. The same move returns a draft to an older
/// target when the email it replied to is trashed or stops qualifying. The
/// open reply is extended in place instead and moves once it is no longer
/// open, since its editor is keyed to the email it opened. A later email that
/// qualifies for nothing (a CC'd "Thanks", an FYI) never moves a draft; it is
/// thread context the draft never saw and joins its sources, keeping the
/// author's answers (a later email never rebuilds the draft).
///
/// The pass only mutates rows; the scheduler's ordinary Composer reseed runs
/// the recompilation and measurement at background priority, and draft sync
/// mirrors the result like any other draft change.
@MainActor
public enum ComposerThreadChangeReconciler {

    public enum Outcome: Equatable, Sendable {
        case rebuilt
        case extended(addedSourceCount: Int)
        /// The draft now replies to the conversation's newest qualifying
        /// email (`to`) and was rebuilt for it.
        case movedAndRebuilt(to: UUID)
        /// The draft now replies to the conversation's newest qualifying
        /// email (`to`), keeping the author's text; the email it replied to
        /// before joined its sources.
        case movedAndExtended(to: UUID, addedSourceCount: Int)
    }

    /// Reconciles every pending reply draft against its live thread and
    /// saves once. Returns the per-draft outcomes for drafts that changed.
    @discardableResult
    public static func reconcile(
        context: ModelContext,
        openReplyMessageID: UUID?
    ) throws -> [UUID: Outcome] {
        let automaticTriageQueueingEnabled =
            ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        // The Draft table holds only Composer-flow rows, so the full fetch is
        // small; moves apply to drafts that predate thread coverage too.
        let candidates = try context.fetch(FetchDescriptor<Draft>()).filter { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                // A rebuild in flight recompiles from the live thread.
                && !draft.isAutomaticSourceResearchPending
        }
        var outcomes: [UUID: Outcome] = [:]
        for draft in candidates {
            guard let message = draft.message else { continue }
            let resolution = message.composerConversationQueueResolution(
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            )

            // The conversation's reply belongs on its target. An excluded
            // email's Draft was dismissed with it and is never revived by a
            // move; a trashed email's Draft still moves to the target.
            if let target = resolution.target,
               target.id != message.id,
               message.id != openReplyMessageID,
               message.composerQueueOverride != .exclude {
                if let outcome = try move(draft, from: message, to: target, context: context) {
                    outcomes[draft.id] = outcome
                }
                continue
            }

            guard !message.isTrashed,
                  let coverage = ComposerThreadCoverage.decode(draft.sourceThreadCoverageJSON) else {
                continue
            }
            let earlier = coverage.missedEarlierMessages(for: message)
            // Emails after the replied-to one are context only for the
            // conversation's queue item; a draft whose conversation has no
            // item (answered, or excluded) is not reworked for them.
            let later = resolution.item?.id == message.id
                ? coverage.missedLaterMessages(for: message)
                : []
            guard !earlier.isEmpty || !later.isEmpty else { continue }

            // Only a missed earlier email can contradict what the draft says
            // about where the exchange stood; later context is added to the
            // sources and never rebuilds (the author's answers survive).
            if !earlier.isEmpty,
               message.id != openReplyMessageID,
               !hasAuthorShapedBody(draft) {
                rebuild(draft, context: context)
                outcomes[draft.id] = .rebuilt
            } else {
                let added = extend(draft, for: message, coverage: coverage, missed: earlier + later)
                outcomes[draft.id] = .extended(addedSourceCount: added)
            }
        }
        if !outcomes.isEmpty {
            try context.save()
        }
        return outcomes
    }

    /// Drafts whose move was refused, so the refusal is logged once rather
    /// than on every maintenance pass.
    private static var reportedBlockedMoves: Set<UUID> = []

    /// Re-anchors the conversation's pending draft from `message` to its
    /// `target`. The relationship is one-to-one: a target that already has a
    /// Draft (every creation seam refuses a second Draft for a conversation,
    /// so only a cross-process race can leave one) keeps its own, and this
    /// draft stays where it is rather than being destroyed.
    private static func move(
        _ draft: Draft,
        from message: Message,
        to target: Message,
        context: ModelContext
    ) throws -> Outcome? {
        let targetID = target.id
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == targetID }
        )
        descriptor.fetchLimit = 1
        let storedTargetDraft = try context.fetch(descriptor).first
        if target.draft != nil || storedTargetDraft != nil {
            if reportedBlockedMoves.insert(draft.id).inserted {
                print("[Ohia] ⚠ Composer draft move skipped: the conversation's reply target already has a draft")
            }
            return nil
        }
        reportedBlockedMoves.remove(draft.id)

        let shaped = hasAuthorShapedBody(draft)
        message.draft = nil
        draft.message = target
        target.draft = draft
        // The quoted original is frozen when a reply is opened; it quoted the
        // email this draft no longer replies to. The Composer and the send
        // seam prepare the new replied-to email's quote when it is missing.
        draft.quotedReplyPlainText = nil
        draft.quotedReplyHTML = nil

        guard shaped else {
            rebuild(draft, context: context)
            // The sending identity was resolved for the old email when the
            // draft was seeded; the rebuilt draft resolves it again for the
            // email it now answers.
            draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: target)?.id
            return .movedAndRebuilt(to: target.id)
        }
        let added = extendAfterMove(draft, from: message, to: target)
        return .movedAndExtended(to: target.id, addedSourceCount: added)
    }

    /// The moved draft keeps the author's text. The email it replied to, and
    /// any thread email its sources never saw, join its sources so Regenerate
    /// would apply them; the new replied-to email leaves the automatic thread
    /// sources, since a reply carries its own email separately.
    private static func extendAfterMove(
        _ draft: Draft,
        from previous: Message,
        to target: Message
    ) -> Int {
        let original = ComposerSourceCoding.decode(draft.sourcesJSON)
        let retained = original.filter { $0.isUserAdded || $0.messageID != target.id }
        let coverage = ComposerThreadCoverage.decode(draft.sourceThreadCoverageJSON)
        var newcomers: [Message] = [previous]
        if let coverage {
            newcomers += coverage.missedEarlierMessages(for: target)
            newcomers += coverage.missedLaterMessages(for: target)
        }
        let present = Set(retained.compactMap(\.messageID))
        var seen: Set<UUID> = []
        let members = newcomers.filter {
            $0.id != target.id && !$0.isTrashed && !present.contains($0.id) && seen.insert($0.id).inserted
        }
        let added = ComposerSourceCompiler.threadSources(for: target, members: members)
        let sources = inserting(added, into: retained, for: target)

        let everyMember = Set(target.composerConversationMembers.map(\.id))
        draft.sourceThreadCoverageJSON = (coverage ?? ComposerThreadCoverage(
            messageIDs: [], quotedMessageIDHeaders: []
        )).adding(messageIDs: Array(everyMember)).encoded()
        guard sources != original else { return 0 }
        if draft.generatedSourcesJSON == nil, !draft.orderedRevisions.isEmpty {
            draft.generatedSourcesJSON = ComposerSourceCoding.encode(original)
        }
        draft.sourcesJSON = ComposerSourceCoding.encode(sources)
        draft.sourceContextTokenCount = nil
        draft.sourceContextMeasurementRequestedAt = Date()
        return added.count
    }

    /// True when rebuilding would discard something the author made: a body
    /// saved from the editor (text or formatting), a typed revision
    /// instruction (applied or pending), an inserted photo, or live text that
    /// differs from the generated body it derives from. Whitespace-only
    /// differences are editor normalization, not authorship. Interview
    /// answers are not authorship: a rebuild re-plans the questions.
    static func hasAuthorShapedBody(_ draft: Draft) -> Bool {
        // Only an editor save or the format picker records a reply's format.
        if draft.messageFormatRaw != nil {
            return true
        }
        let revisions = draft.orderedRevisions
        if revisions.contains(where: {
            $0.triggerRaw == DraftRevisionTrigger.manualEdit
                || $0.triggerRaw == DraftRevisionTrigger.instruction
        }) {
            return true
        }
        if let pending = draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pending.isEmpty,
           pending != DraftGenerationOrchestrator.regenerationInstruction {
            return true
        }
        if !ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON).isEmpty {
            return true
        }
        guard let base = draft.baseGeneratedRevision else {
            return !normalizedText(draft.replyText).isEmpty
        }
        return normalizedText(draft.replyText) != normalizedText(base.bodyText)
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Returns the draft to automatic source research with everything the
    /// earlier, incomplete thread produced removed. Recipients, identity,
    /// signature, language, style choices, attachments, and user-added
    /// sources are the author's and survive.
    private static func rebuild(_ draft: Draft, context: ModelContext) {
        let userAdded = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
        draft.sourcesJSON = userAdded.isEmpty ? nil : ComposerSourceCoding.encode(userAdded)
        draft.sourceThreadCoverageJSON = nil
        draft.generatedSourcesJSON = nil
        draft.sourcesCuratedAt = nil
        draft.sourceContextTokenCount = nil
        draft.sourceContextFitJSON = nil
        draft.sourceContextTokenLimit = nil
        draft.sourceContextMeasurementRequestedAt = nil
        draft.interviewStateJSON = nil
        draft.decisionHistoryJSON = nil
        draft.decisionResearchOverlayJSON = nil
        draft.pendingInstruction = nil

        for revision in draft.revisions ?? [] {
            context.delete(revision)
        }
        draft.revisions = []
        draft.baseRevisionID = nil
        draft.replyText = ""
        draft.bodyHTML = nil
        draft.confidence = 0
        draft.citationsJSON = nil
        draft.gapsJSON = nil
        draft.deliverablesJSON = nil
        draft.personalizationJSON = nil
        draft.appliedRuleIDsJSON = nil

        draft.stageRaw = DraftStage.collectingSources
        draft.automaticSourceResearchStateRaw = nil
        draft.beginAutomaticSourceResearchIfNeeded()
        draft.clearGenerationBackoff()
    }

    /// Adds the missed emails as thread sources in their newest-first place
    /// among the existing thread sources, and records them as covered so
    /// they are added once. Returns how many sources were added (an email
    /// with no usable body is covered without a source).
    private static func extend(
        _ draft: Draft,
        for message: Message,
        coverage: ComposerThreadCoverage,
        missed: [Message]
    ) -> Int {
        let original = ComposerSourceCoding.decode(draft.sourcesJSON)
        let present = Set(original.compactMap(\.messageID))
        let members = missed.filter { !present.contains($0.id) }
        let added = ComposerSourceCompiler.threadSources(for: message, members: members)
        draft.sourceThreadCoverageJSON = coverage.adding(messageIDs: missed.map(\.id)).encoded()
        guard !added.isEmpty else { return 0 }

        let sources = inserting(added, into: original, for: message)
        // The applied baseline lets the Composer report the change as
        // pending until Regenerate applies it (same rule as a manual edit).
        if draft.generatedSourcesJSON == nil, !draft.orderedRevisions.isEmpty {
            draft.generatedSourcesJSON = ComposerSourceCoding.encode(original)
        }
        draft.sourcesJSON = ComposerSourceCoding.encode(sources)
        draft.sourceContextTokenCount = nil
        draft.sourceContextMeasurementRequestedAt = Date()
        return added.count
    }

    /// Places each added thread source in its newest-first position among
    /// the existing thread sources of `message`'s conversation.
    private static func inserting(
        _ added: [ComposerSource],
        into existing: [ComposerSource],
        for message: Message
    ) -> [ComposerSource] {
        let threadByID = Dictionary(
            message.composerConversationMembers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func date(of source: ComposerSource) -> Date? {
            source.messageID.flatMap { threadByID[$0] }.map(Self.ordering)
        }
        var sources = existing
        for source in added {
            guard let addedDate = date(of: source) else { continue }
            // Before the first thread source the added email is newer than;
            // after every later-dated one. Recovered quotes carry no row and
            // keep their place.
            let insertion = sources.firstIndex { existing in
                guard existing.kind == .thread, let existingDate = date(of: existing) else {
                    return false
                }
                return existingDate < addedDate
            } ?? (sources.lastIndex { $0.kind == .thread }.map { $0 + 1 } ?? sources.endIndex)
            sources.insert(source, at: insertion)
        }
        return sources
    }

    private static func ordering(_ message: Message) -> Date {
        message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }
}
