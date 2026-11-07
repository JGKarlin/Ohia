import Foundation
import SwiftData
import OhiaCore
import OhiaML

public struct MailingListIgnoreRuleDraft: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let accountID: UUID
    public let listId: String
    public let listDisplayName: String?
    public let displayLabel: String
    public let semanticTagIDs: [String]
    public let semanticTagLabels: [String]
    public let subjectFingerprint: String
    public let subjectAnchors: [String]
    public let bodyAnchors: [String]
    public let evidenceMessageID: UUID
    public let evidenceSubject: String
    public let evidenceSummary: String?
    public let evidenceFeatures: MailingListIgnoreFeatureSnapshot
    public let previewCandidates: [MailingListIgnorePreviewCandidate]
    public let positiveExamples: [MailingListIgnoreFeatureSnapshot]
    public let negativeExamples: [MailingListIgnoreFeatureSnapshot]

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        listId: String,
        listDisplayName: String?,
        displayLabel: String,
        semanticTagIDs: [String],
        semanticTagLabels: [String],
        subjectFingerprint: String,
        subjectAnchors: [String],
        bodyAnchors: [String],
        evidenceMessageID: UUID,
        evidenceSubject: String,
        evidenceSummary: String?,
        evidenceFeatures: MailingListIgnoreFeatureSnapshot,
        previewCandidates: [MailingListIgnorePreviewCandidate] = [],
        positiveExamples: [MailingListIgnoreFeatureSnapshot]? = nil,
        negativeExamples: [MailingListIgnoreFeatureSnapshot] = []
    ) {
        self.id = id
        self.accountID = accountID
        self.listId = listId
        self.listDisplayName = listDisplayName
        self.displayLabel = displayLabel
        self.semanticTagIDs = semanticTagIDs
        self.semanticTagLabels = semanticTagLabels
        self.subjectFingerprint = subjectFingerprint
        self.subjectAnchors = subjectAnchors
        self.bodyAnchors = bodyAnchors
        self.evidenceMessageID = evidenceMessageID
        self.evidenceSubject = evidenceSubject
        self.evidenceSummary = evidenceSummary
        self.evidenceFeatures = evidenceFeatures
        self.previewCandidates = previewCandidates
        self.positiveExamples = positiveExamples ?? [evidenceFeatures]
        self.negativeExamples = negativeExamples
    }

    public func applyingHistoricalSelection(_ selectedCandidateIDs: Set<UUID>) -> Self {
        let selected = previewCandidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .map(\.features)
        let rejected = previewCandidates
            .filter { !selectedCandidateIDs.contains($0.id) }
            .map(\.features)
        return MailingListIgnoreRuleDraft(
            id: id,
            accountID: accountID,
            listId: listId,
            listDisplayName: listDisplayName,
            displayLabel: displayLabel,
            semanticTagIDs: semanticTagIDs,
            semanticTagLabels: semanticTagLabels,
            subjectFingerprint: subjectFingerprint,
            subjectAnchors: subjectAnchors,
            bodyAnchors: bodyAnchors,
            evidenceMessageID: evidenceMessageID,
            evidenceSubject: evidenceSubject,
            evidenceSummary: evidenceSummary,
            evidenceFeatures: evidenceFeatures,
            previewCandidates: previewCandidates,
            positiveExamples: [evidenceFeatures] + selected,
            negativeExamples: rejected
        )
    }
}

public struct MailingListIgnoreMatch: Sendable, Equatable {
    public let matched: Bool
    public let score: Double
    public let subjectScore: Double
    public let signalCount: Int
    public let matchedSignals: Set<String>
    public let blockedReason: String?
}

public struct MailingListIgnoreCreationOutcome: Sendable, Equatable {
    public let ruleID: UUID
    public let movedEvidenceMessage: Bool
    public let propagatedToServer: Bool
}

@MainActor
public final class MailingListIgnoreRuleService {
    public enum Error: Swift.Error, LocalizedError {
        case invalidPersistedEvidence

        public var errorDescription: String? {
            switch self {
            case .invalidPersistedEvidence:
                "The ignore rule's saved matching evidence could not be read. The rule was paused to protect future mail."
            }
        }
    }

    private struct RuleSnapshot {
        let statusRaw: String
        let displayLabel: String
        let semanticTagIDsJSON: String
        let semanticTagLabelsJSON: String
        let subjectFingerprint: String
        let subjectAnchorsJSON: String
        let bodyAnchorsJSON: String
        let positiveExamplesJSON: String?
        let negativeExamplesJSON: String?
        let matcherVersion: String?
        let evidenceMessageID: UUID?
        let evidenceSubject: String
        let evidenceSummary: String?
        let updatedAt: Date

        init(rule: MailingListIgnoreRule) {
            statusRaw = rule.statusRaw
            displayLabel = rule.displayLabel
            semanticTagIDsJSON = rule.semanticTagIDsJSON
            semanticTagLabelsJSON = rule.semanticTagLabelsJSON
            subjectFingerprint = rule.subjectFingerprint
            subjectAnchorsJSON = rule.subjectAnchorsJSON
            bodyAnchorsJSON = rule.bodyAnchorsJSON
            positiveExamplesJSON = rule.positiveExamplesJSON
            negativeExamplesJSON = rule.negativeExamplesJSON
            matcherVersion = rule.matcherVersion
            evidenceMessageID = rule.evidenceMessageID
            evidenceSubject = rule.evidenceSubject
            evidenceSummary = rule.evidenceSummary
            updatedAt = rule.updatedAt
        }

        func restore(_ rule: MailingListIgnoreRule) {
            rule.statusRaw = statusRaw
            rule.displayLabel = displayLabel
            rule.semanticTagIDsJSON = semanticTagIDsJSON
            rule.semanticTagLabelsJSON = semanticTagLabelsJSON
            rule.subjectFingerprint = subjectFingerprint
            rule.subjectAnchorsJSON = subjectAnchorsJSON
            rule.bodyAnchorsJSON = bodyAnchorsJSON
            rule.positiveExamplesJSON = positiveExamplesJSON
            rule.negativeExamplesJSON = negativeExamplesJSON
            rule.matcherVersion = matcherVersion
            rule.evidenceMessageID = evidenceMessageID
            rule.evidenceSubject = evidenceSubject
            rule.evidenceSummary = evidenceSummary
            rule.updatedAt = updatedAt
        }
    }

    private struct RuleUpsert {
        let rule: MailingListIgnoreRule
        /// Nil means this action inserted the rule instead of updating one.
        let previousState: RuleSnapshot?
    }

    private let context: ModelContext
    private let jobQueue: JobQueue
    private let localDeletionCascade: MessageLocalDeletionCascade?
    private let decoder = JSONDecoder()

    public init(
        context: ModelContext,
        jobQueue: JobQueue,
        localDeletionCascade: MessageLocalDeletionCascade? = nil
    ) {
        self.context = context
        self.jobQueue = jobQueue
        self.localDeletionCascade = localDeletionCascade
    }

    public func draftRule(for message: Message) -> MailingListIgnoreRuleDraft? {
        guard Self.isEligibleListMessage(message) else { return nil }
        guard let accountID = message.accountID ?? message.account?.id else { return nil }
        guard let listId = normalizedNonEmpty(message.listId) else { return nil }

        let dimensions = decodeDimensions(message.analysis?.dimensionsJSON)
        let tagLabels = tagDisplayLabels(from: dimensions)
        let tagIDs = tagCanonicalIDs(from: dimensions)
        let subjectFingerprint = Self.subjectFingerprint(message.subject)
        let historicalMessages = historicalMessages(
            accountID: accountID,
            listId: listId,
            excluding: message.id
        )
        let subjectAnchors = discriminativeSubjectAnchors(
            for: message.subject,
            comparedWith: historicalMessages.map(\.subject)
        )
        let summary = normalizedNonEmpty(message.analysis?.bodySummary)
        let bodyAnchors = Self.bodyAnchors(
            subject: message.subject,
            summary: nil,
            bodyText: sourceBodyText(for: message)
        )
        let features = featureSnapshot(
            for: message,
            dimensions: dimensions,
            subjectAnchors: subjectAnchors,
            bodyAnchors: bodyAnchors
        )

        guard !tagLabels.isEmpty || !subjectAnchors.isEmpty || !bodyAnchors.isEmpty else {
            return nil
        }

        let displayLabel = tagLabels.first
            ?? subjectAnchors.first
            ?? bodyAnchors.first
            ?? message.subject

        let previewCorpusSubjects = [message.subject] + historicalMessages.map(\.subject)
        let previewCandidates = historicalMessages
            .compactMap {
                previewCandidate(
                    message: $0,
                    evidence: features,
                    corpusSubjects: previewCorpusSubjects
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSuggestedMatch != rhs.isSuggestedMatch {
                    return lhs.isSuggestedMatch && !rhs.isSuggestedMatch
                }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (lhs.messageDate ?? .distantPast) > (rhs.messageDate ?? .distantPast)
            }
            .prefix(8)

        return MailingListIgnoreRuleDraft(
            accountID: accountID,
            listId: listId,
            listDisplayName: normalizedNonEmpty(message.listDisplayName),
            displayLabel: displayLabel,
            semanticTagIDs: tagIDs,
            semanticTagLabels: tagLabels,
            subjectFingerprint: subjectFingerprint,
            subjectAnchors: subjectAnchors,
            bodyAnchors: bodyAnchors,
            evidenceMessageID: message.id,
            evidenceSubject: message.subject,
            evidenceSummary: summary,
            evidenceFeatures: features,
            previewCandidates: Array(previewCandidates)
        )
    }

    public func createRuleAndApplyToEvidence(
        draft: MailingListIgnoreRuleDraft
    ) throws -> MailingListIgnoreCreationOutcome {
        let upsert = try upsertRule(from: draft)
        let rule = upsert.rule
        guard let message = try fetchMessage(id: draft.evidenceMessageID) else {
            try rollback(upsert)
            return MailingListIgnoreCreationOutcome(
                ruleID: rule.id,
                movedEvidenceMessage: false,
                propagatedToServer: false
            )
        }

        let outcome: MailboxMutationDispatcher.Outcome
        do {
            outcome = try suppress(
                message: message,
                using: rule,
                features: draft.evidenceFeatures,
                match: MailingListIgnoreMatch(
                    matched: true,
                    score: 1,
                    subjectScore: 1,
                    signalCount: 1,
                    matchedSignals: ["userEvidence"],
                    blockedReason: nil
                )
            )
        } catch {
            // If the dispatcher failed before removing the evidence message,
            // the user's action did not happen. Undo the rule insert/update so
            // future mail cannot be ignored by an operation the UI reported as
            // failed. A post-commit cleanup failure leaves the Message absent;
            // in that case suppression did happen, so the rule remains valid.
            if (try? fetchMessage(id: draft.evidenceMessageID)) != nil {
                try rollback(upsert)
            }
            throw error
        }
        return MailingListIgnoreCreationOutcome(
            ruleID: rule.id,
            movedEvidenceMessage: true,
            propagatedToServer: outcome.propagatedToServer
        )
    }

    /// Applies the first active rule matching this message. Returns true when
    /// the message was removed from active Ohia surfaces and optionally queued
    /// for server-side Trash movement.
    public func applyIgnoreIfNeeded(to message: Message) throws -> Bool {
        guard Self.isEligibleListMessage(message) else { return false }
        guard let accountID = message.accountID ?? message.account?.id,
              let listId = normalizedNonEmpty(message.listId) else {
            return false
        }
        let rules = try rules(accountID: accountID, listId: listId)
            .filter(\.isActive)
            .filter { rule in
                guard message.ingestedAt >= rule.createdAt else { return false }
                guard let sourceDate = message.receivedAt ?? message.sentAt else { return true }
                return sourceDate >= rule.createdAt.addingTimeInterval(-300)
            }
        guard !rules.isEmpty else { return false }

        // A restore is an explicit one-message override. Fetch it only after an
        // active rule exists so ordinary list mail pays no history-query cost.
        if try hasRestoreExemption(for: message, accountID: accountID) {
            return false
        }

        let candidateFeatures = featureSnapshot(for: message)

        let best = rules
            .map { (rule: $0, match: match(features: candidateFeatures, against: $0)) }
            .filter(\.match.matched)
            .max { lhs, rhs in
                if lhs.match.score != rhs.match.score {
                    return lhs.match.score < rhs.match.score
                }
                return lhs.match.subjectScore < rhs.match.subjectScore
            }
        guard let best else { return false }
        _ = try suppress(
            message: message,
            using: best.rule,
            features: candidateFeatures,
            match: best.match
        )
        return true
    }

    public func match(message: Message, against rule: MailingListIgnoreRule) -> MailingListIgnoreMatch {
        guard rule.isActive else {
            return MailingListIgnoreMatch(
                matched: false,
                score: 0,
                subjectScore: 0,
                signalCount: 0,
                matchedSignals: [],
                blockedReason: "rule is disabled"
            )
        }
        guard let accountID = message.accountID ?? message.account?.id,
              accountID == rule.accountID,
              normalizedNonEmpty(message.listId) == rule.listId else {
            return MailingListIgnoreMatch(
                matched: false,
                score: 0,
                subjectScore: 0,
                signalCount: 0,
                matchedSignals: [],
                blockedReason: "different list scope"
            )
        }
        return match(features: featureSnapshot(for: message), against: rule)
    }

    private func match(
        features: MailingListIgnoreFeatureSnapshot,
        against rule: MailingListIgnoreRule
    ) -> MailingListIgnoreMatch {
        guard let persistedPositives = decodedExamples(rule.positiveExamplesJSON),
              let negatives = decodedExamples(rule.negativeExamplesJSON) else {
            let reason = "saved matching evidence could not be read"
            let surfacedError = "Ignore rule paused: " + reason + "."
            if rule.lastActionError != surfacedError {
                rule.lastActionError = surfacedError
                rule.updatedAt = .now
                try? context.save()
            }
            return MailingListIgnoreMatch(
                matched: false,
                score: 0,
                subjectScore: 0,
                signalCount: 0,
                matchedSignals: [],
                blockedReason: reason
            )
        }
        let positives = persistedPositives.isEmpty
            ? [legacyPositiveExample(for: rule)]
            : persistedPositives
        let evaluation = MailingListIgnoreMatcher.evaluate(
            candidate: features,
            positives: positives,
            negatives: negatives,
            aggressiveness: rule.matchAggressiveness
        )
        return MailingListIgnoreMatch(
            matched: evaluation.matched,
            score: evaluation.score,
            subjectScore: evaluation.subjectScore,
            signalCount: evaluation.matchedSignals.count,
            matchedSignals: evaluation.matchedSignals,
            blockedReason: evaluation.blockedReason
        )
    }

    public func broaden(ruleID: UUID) throws {
        guard let rule = try fetchRule(id: ruleID) else { return }
        rule.strengthen()
        try context.save()
    }

    public func narrow(ruleID: UUID) throws {
        guard let rule = try fetchRule(id: ruleID) else { return }
        rule.weaken()
        try context.save()
    }

    public func strengthen(ruleID: UUID) throws {
        try broaden(ruleID: ruleID)
    }

    public func weaken(ruleID: UUID) throws {
        try narrow(ruleID: ruleID)
    }

    public func revoke(ruleID: UUID) throws {
        guard let rule = try fetchRule(id: ruleID) else { return }
        rule.disable()
        try context.save()
    }

    /// Backward-compatible spelling for callers that still model revocation as
    /// disabling. New UI should use `revoke(ruleID:)` so the user-facing
    /// distinction from permanent deletion stays explicit.
    public func disable(ruleID: UUID) throws {
        try revoke(ruleID: ruleID)
    }

    /// Permanently removes both the rule and the audit history it owns.
    public func deleteRuleAndHistory(ruleID: UUID) throws {
        let historyDescriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> { $0.ruleID == ruleID }
        )
        for entry in try context.fetch(historyDescriptor) {
            context.delete(entry)
        }
        if let rule = try fetchRule(id: ruleID) {
            context.delete(rule)
        }
        try context.save()
    }

    /// Teaches the originating rule that a restored message was a false
    /// positive. The exact Message-ID exemption remains separate so restoring
    /// one copy can never create an immediate ignore loop.
    public func refineRuleByExcluding(historyID: UUID) throws {
        guard let history = try fetchHistory(id: historyID),
              let rule = try fetchRule(id: history.ruleID) else {
            return
        }
        let features = decodedFeature(history.matchFeaturesJSON)
            ?? MailingListIgnoreFeatureSnapshot(
                subjectFingerprint: Self.subjectFingerprint(history.subject),
                subjectAnchors: Self.subjectAnchors(from: history.subject),
                bodyAnchors: [],
                primaryTagIDs: [],
                supportingTagIDs: [],
                purpose: .announcement,
                deliveryPriority: .list,
                isActionable: false,
                requiresConfirmation: false
            )
        guard let existingNegatives = decodedExamples(rule.negativeExamplesJSON) else {
            throw Error.invalidPersistedEvidence
        }
        rule.negativeExamplesJSON = encodedExamples(mergedExamples(existingNegatives, [features]))
        rule.matcherVersion = MailingListIgnoreMatcher.version
        rule.updatedAt = .now
        history.excludedFromRuleAt = .now
        try context.save()
    }

    public static func isEligibleListMessage(_ message: Message) -> Bool {
        isEligibleList(
            hasListID: normalizedNonEmpty(message.listId) != nil,
            purpose: MailClassificationJSON.decode(
                message.analysis?.mailClassificationJSON
            )?.purpose
        )
    }

    /// Whether a message may have a list-ignore rule filed against it, decided
    /// from projected values rather than a fetched `Message`.
    ///
    /// This is the single definition of "Ignore applies here", and every lens
    /// must route through it — either via `isEligibleListMessage` when it holds
    /// a `Message`, or via this overload when it only has a lightweight row.
    /// The lenses previously disagreed: Meaning, People, and Projects applied
    /// the full rule while Timeline and the Front Page tested only for a
    /// `List-ID`, so the disc appeared on protected mail and then did nothing
    /// when clicked, because `draftRule` re-checks and refuses.
    ///
    /// Both conditions are load-bearing:
    ///  - `hasListID` — an ignore rule is scoped to a mailing list, so mail
    ///    without RFC 2919 `List-ID` has nothing to scope a rule to;
    ///  - `purpose` — a message Ohia has not classified yet cannot be judged
    ///    safe to ignore, and `neverIgnoredPurposes` keeps security and
    ///    verification-code mail ignorable-proof even when it arrives over a
    ///    list.
    /// `nonisolated` because the lens data controllers evaluate it inside
    /// their off-main gathers; it is pure and touches no actor state.
    public nonisolated static func isEligibleList(hasListID: Bool, purpose: MailPurpose?) -> Bool {
        guard hasListID, let purpose else { return false }
        return MailingListIgnoreMatcher.neverIgnoredPurposes.contains(purpose) == false
    }

    public static func subjectFingerprint(_ subject: String) -> String {
        let withoutReply = subject
            .replacingOccurrences(
                of: #"(?i)^\s*(re|fw|fwd|返信|転送)\s*[:：]\s*"#,
                with: "",
                options: .regularExpression
            )
        var value = withoutReply
        var removedPrefix = true
        while removedPrefix {
            let before = value
            value = value
                .replacingOccurrences(
                    of: #"^\s*(\[[^\]]+\]|\【[^】]+\】|\（[^）]+\）|\([^)]+\))\s*"#,
                    with: "",
                    options: .regularExpression
                )
            removedPrefix = before != value
        }
        value = value.replacingOccurrences(
            of: #"(?i)^\s*(re|fw|fwd|返信|転送)\s*[:：]\s*"#,
            with: "",
            options: .regularExpression
        )
        value = value
            .replacingOccurrences(of: #"(?i)\b(reminder|リマインド|お知らせ|notice)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b20\d{2}\s*年度?\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"第\s*\d+\s*回"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\b\d{1,2}\s*/\s*\d{1,2}(?:\s*/\s*\d{2,4})?\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\b(?:19|20)\d{2}\b"#, with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        return normalizedWords(value)
    }

    public static func subjectAnchors(from subject: String) -> [String] {
        let fingerprint = subjectFingerprint(subject)
        return anchors(from: fingerprint, limit: 5, includeWhole: true)
    }

    public static func bodyAnchors(subject: String, summary: String?, bodyText: String?) -> [String] {
        let text = [summary, bodyText]
            .compactMap { $0 }
            .joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let subjectWords = Set(subjectFingerprint(subject).split(separator: " ").map(String.init))
        return anchors(from: text, limit: 8, includeWhole: false)
            .filter { anchor in
                let words = Set(anchor.split(separator: " ").map(String.init))
                return words.isDisjoint(with: subjectWords) == false || anchor.count >= 6
            }
    }

    private func upsertRule(from draft: MailingListIgnoreRuleDraft) throws -> RuleUpsert {
        if let existing = try rulesIncludingDisabled(accountID: draft.accountID, listId: draft.listId).first(where: { rule in
            shouldUpdateExistingRule(rule, with: draft)
        }) {
            guard let existingPositives = decodedExamples(existing.positiveExamplesJSON),
                  let existingNegatives = decodedExamples(existing.negativeExamplesJSON) else {
                throw Error.invalidPersistedEvidence
            }
            let previousState = RuleSnapshot(rule: existing)
            existing.statusRaw = MailingListIgnoreRuleStatus.active
            existing.displayLabel = draft.displayLabel
            existing.subjectFingerprint = draft.subjectFingerprint
            existing.evidenceMessageID = draft.evidenceMessageID
            existing.evidenceSubject = draft.evidenceSubject
            existing.evidenceSummary = draft.evidenceSummary
            existing.replaceSemanticTags(ids: draft.semanticTagIDs, labels: draft.semanticTagLabels)
            existing.replaceAnchors(subject: draft.subjectAnchors, body: draft.bodyAnchors)
            existing.positiveExamplesJSON = encodedExamples(
                mergedExamples(
                    existingPositives,
                    draft.positiveExamples
                )
            )
            existing.negativeExamplesJSON = encodedExamples(
                mergedExamples(
                    existingNegatives,
                    draft.negativeExamples
                )
            )
            existing.matcherVersion = MailingListIgnoreMatcher.version
            existing.updatedAt = .now
            try context.save()
            return RuleUpsert(rule: existing, previousState: previousState)
        }

        let rule = MailingListIgnoreRule(
            accountID: draft.accountID,
            listId: draft.listId,
            displayLabel: draft.displayLabel,
            semanticTagIDs: draft.semanticTagIDs,
            semanticTagLabels: draft.semanticTagLabels,
            subjectFingerprint: draft.subjectFingerprint,
            subjectAnchors: draft.subjectAnchors,
            bodyAnchors: draft.bodyAnchors,
            positiveExamplesJSON: encodedExamples(draft.positiveExamples),
            negativeExamplesJSON: encodedExamples(draft.negativeExamples),
            matcherVersion: MailingListIgnoreMatcher.version,
            evidenceMessageID: draft.evidenceMessageID,
            evidenceSubject: draft.evidenceSubject,
            evidenceSummary: draft.evidenceSummary
        )
        context.insert(rule)
        try context.save()
        return RuleUpsert(rule: rule, previousState: nil)
    }

    private func rollback(_ upsert: RuleUpsert) throws {
        if let previousState = upsert.previousState {
            previousState.restore(upsert.rule)
        } else {
            context.delete(upsert.rule)
        }
        try context.save()
    }

    private func shouldUpdateExistingRule(
        _ rule: MailingListIgnoreRule,
        with draft: MailingListIgnoreRuleDraft
    ) -> Bool {
        if rule.evidenceMessageID == draft.evidenceMessageID {
            return true
        }

        let evaluation = match(features: draft.evidenceFeatures, against: rule)
        return evaluation.matched && evaluation.score >= 0.78
    }

    private func suppress(
        message: Message,
        using rule: MailingListIgnoreRule,
        features: MailingListIgnoreFeatureSnapshot,
        match: MailingListIgnoreMatch
    ) throws -> MailboxMutationDispatcher.Outcome {
        let messageID = message.id
        let audit = try ignoredMessageAudit(
            for: message,
            rule: rule,
            features: features,
            match: match
        )
        let dispatcher = MailboxMutationDispatcher(
            context: context,
            jobQueue: jobQueue,
            localDeletionCascade: localDeletionCascade
        )
        let outcome: MailboxMutationDispatcher.Outcome
        do {
            outcome = try dispatcher.moveToTrash(messageID: messageID)
        } catch {
            // A dispatcher can throw before changing the mailbox (for example,
            // no Trash destination). In that case the audit must not claim the
            // message was ignored. If the local Message is already gone, retain
            // the pending audit: the dispatcher committed before a later
            // artifact-cleanup failure and the history is still truthful.
            if (try? fetchMessage(id: messageID)) != nil {
                context.delete(audit)
                try? context.save()
            }
            throw error
        }
        audit.trashDispositionRaw = outcome.propagatedToServer
            ? MailingListIgnoredTrashDisposition.serverTrash
            : MailingListIgnoredTrashDisposition.localOnly
        audit.remoteStatusRaw = outcome.propagatedToServer
            ? MailingListIgnoredRemoteStatus.queued
            : MailingListIgnoredRemoteStatus.notApplicable
        rule.matchCount += 1
        rule.lastMatchedAt = .now
        rule.updatedAt = .now
        if outcome.propagatedToServer {
            rule.lastActionError = nil
        } else {
            rule.hiddenOnlyCount += 1
            rule.lastActionError = "No server Trash destination was available; hidden locally only."
        }
        try context.save()
        return outcome
    }

    private func ignoredMessageAudit(
        for message: Message,
        rule: MailingListIgnoreRule,
        features: MailingListIgnoreFeatureSnapshot,
        match: MailingListIgnoreMatch
    ) throws -> MailingListIgnoredMessage {
        let messageID = message.id
        let ruleID = rule.id
        var descriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> {
                $0.ruleID == ruleID && $0.originalMessageID == messageID
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            applyMatchEvidence(features: features, match: match, to: existing)
            return existing
        }

        let audit = MailingListIgnoredMessage(
            ruleID: rule.id,
            accountID: rule.accountID,
            listId: rule.listId,
            originalMessageID: message.id,
            messageIdHeader: message.messageIdHeader,
            normalizedMessageIDHeader: normalizeMessageIDHeader(message.messageIdHeader),
            subject: message.subject,
            senderAddress: message.fromAddress,
            senderName: message.fromName,
            messageDate: message.receivedAt ?? message.sentAt
        )
        applyMatchEvidence(features: features, match: match, to: audit)
        context.insert(audit)
        return audit
    }

    private func hasRestoreExemption(for message: Message, accountID: UUID) throws -> Bool {
        guard let normalizedHeader = normalizeMessageIDHeader(message.messageIdHeader) else {
            return false
        }
        var descriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> {
                $0.accountID == accountID
                    && $0.normalizedMessageIDHeader == normalizedHeader
                    && $0.restoreRequestedAt != nil
            }
        )
        descriptor.fetchLimit = 1
        if try !context.fetch(descriptor).isEmpty {
            return true
        }

        // Compatibility for history rows written before the normalized key was
        // persisted. New rows stay entirely on the indexed path above.
        let legacyDescriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> {
                $0.accountID == accountID
                    && $0.normalizedMessageIDHeader == nil
                    && $0.restoreRequestedAt != nil
            }
        )
        return try context.fetch(legacyDescriptor).contains { entry in
            normalizeMessageIDHeader(entry.messageIdHeader) == normalizedHeader
        }
    }

    private func rules(accountID: UUID, listId: String) throws -> [MailingListIgnoreRule] {
        let activeStatus = MailingListIgnoreRuleStatus.active
        let descriptor = FetchDescriptor<MailingListIgnoreRule>(
            predicate: #Predicate<MailingListIgnoreRule> { rule in
                rule.accountID == accountID
                    && rule.listId == listId
                    && rule.statusRaw == activeStatus
            }
        )
        return try context.fetch(descriptor)
    }

    private func rulesIncludingDisabled(accountID: UUID, listId: String) throws -> [MailingListIgnoreRule] {
        let descriptor = FetchDescriptor<MailingListIgnoreRule>(
            predicate: #Predicate<MailingListIgnoreRule> { rule in
                rule.accountID == accountID && rule.listId == listId
            }
        )
        return try context.fetch(descriptor)
    }

    private func fetchRule(id: UUID) throws -> MailingListIgnoreRule? {
        var descriptor = FetchDescriptor<MailingListIgnoreRule>(
            predicate: #Predicate<MailingListIgnoreRule> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchHistory(id: UUID) throws -> MailingListIgnoredMessage? {
        var descriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchMessage(id: UUID) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private struct TriageAttentionFields: Decodable {
        let isActionable: Bool
        let requiresConfirmation: Bool
    }

    private func featureSnapshot(
        for message: Message,
        dimensions: MessageDimensions? = nil,
        subjectAnchors: [String]? = nil,
        bodyAnchors: [String]? = nil
    ) -> MailingListIgnoreFeatureSnapshot {
        let resolvedDimensions = dimensions ?? decodeDimensions(message.analysis?.dimensionsJSON)
        let tagFeatures = tagFeatures(from: resolvedDimensions)
        let attention = attentionFields(from: message.analysis?.triageVerdictJSON)
        let sourceBody = bodyAnchors == nil ? sourceBodyText(for: message) : nil
        let resolvedBodyAnchors = bodyAnchors ?? Self.bodyAnchors(
            subject: message.subject,
            summary: nil,
            bodyText: sourceBody
        )
        let classification = MailClassificationJSON.decode(
            message.analysis?.mailClassificationJSON
        )
        return MailingListIgnoreFeatureSnapshot(
            subjectFingerprint: Self.subjectFingerprint(message.subject),
            subjectAnchors: subjectAnchors ?? Self.subjectAnchors(from: message.subject),
            bodyAnchors: resolvedBodyAnchors,
            primaryTagIDs: tagFeatures.primary,
            supportingTagIDs: tagFeatures.supporting,
            purpose: classification?.purpose,
            deliveryPriority: deliveryPriority(for: message),
            isActionable: attention?.isActionable ?? false,
            requiresConfirmation: attention?.requiresConfirmation ?? false
        )
    }

    private func previewCandidate(
        message: Message,
        evidence: MailingListIgnoreFeatureSnapshot,
        corpusSubjects: [String]
    ) -> MailingListIgnorePreviewCandidate? {
        let features = featureSnapshot(
            for: message,
            subjectAnchors: discriminativeSubjectAnchors(
                for: message.subject,
                comparedWith: corpusSubjects.filter { $0 != message.subject }
            ),
            // Historical preview stays cheap and source-safe: subject plus
            // already-persisted semantic labels are enough to teach series
            // boundaries without opening up to forty body files on MainActor.
            bodyAnchors: []
        )
        let evaluation = MailingListIgnoreMatcher.evaluate(
            candidate: features,
            positives: [evidence],
            negatives: [],
            aggressiveness: 0.5
        )
        guard evaluation.matched || evaluation.score >= 0.35 else { return nil }
        return MailingListIgnorePreviewCandidate(
            id: message.id,
            subject: message.subject,
            messageDate: message.receivedAt ?? message.sentAt,
            score: evaluation.score,
            reasonSummary: MailingListIgnoreMatcher.reasonSummary(
                for: evaluation.matchedSignals,
                blockedReason: evaluation.blockedReason
            ),
            isSuggestedMatch: evaluation.matched,
            features: features
        )
    }

    private func historicalMessages(
        accountID: UUID,
        listId: String,
        excluding messageID: UUID
    ) -> [Message] {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.accountID == accountID && message.listId == listId
            },
            sortBy: [SortDescriptor(\Message.ingestedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 40
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.id != messageID }
    }

    private func discriminativeSubjectAnchors(
        for subject: String,
        comparedWith historicalSubjects: [String]
    ) -> [String] {
        let anchors = Self.subjectAnchors(from: subject)
        guard historicalSubjects.count >= 4 else { return anchors }

        var documentFrequency: [String: Int] = [:]
        for historicalSubject in historicalSubjects {
            let keys = Set(Self.subjectAnchors(from: historicalSubject).map(Self.normalizedWords))
            for key in keys where !key.isEmpty {
                documentFrequency[key, default: 0] += 1
            }
        }
        let commonThreshold = max(3, Int(ceil(Double(historicalSubjects.count) * 0.40)))
        let filtered = anchors.filter { anchor in
            documentFrequency[Self.normalizedWords(anchor), default: 0] < commonThreshold
        }
        return filtered.isEmpty ? Array(anchors.prefix(1)) : filtered
    }

    private func tagFeatures(from dimensions: MessageDimensions?) -> (primary: [String], supporting: [String]) {
        guard let dimensions else { return ([], []) }
        let eligible = SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .filter { $0.confidence >= 0.72 && $0.score >= 0.65 }
        return (
            eligible.filter { $0.centrality == .primary }.map { $0.tagID.uuidString.lowercased() },
            eligible.filter { $0.centrality != .primary }.map { $0.tagID.uuidString.lowercased() }
        )
    }

    private func attentionFields(from json: String?) -> TriageAttentionFields? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(TriageAttentionFields.self, from: data)
    }

    private func deliveryPriority(for message: Message) -> MailingListIgnoreDeliveryPriority {
        let ownedAddresses: Set<String>
        if let account = message.account {
            ownedAddresses = account.ownedEmailAddresses
        } else if let accountID = message.accountID {
            var descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { $0.id == accountID }
            )
            descriptor.fetchLimit = 1
            ownedAddresses = (try? context.fetch(descriptor).first?.ownedEmailAddresses) ?? []
        } else {
            ownedAddresses = []
        }

        if !ownedAddresses.isEmpty {
            if hasOwnedRecipient(message, role: .to, ownedAddresses: ownedAddresses) {
                return .direct
            }
            if hasOwnedRecipient(message, role: .cc, ownedAddresses: ownedAddresses) {
                return .copied
            }
        }
        if normalizedNonEmpty(message.listId) != nil { return .list }
        return .unknown
    }

    private func hasOwnedRecipient(
        _ message: Message,
        role: ParticipantRole,
        ownedAddresses: Set<String>
    ) -> Bool {
        message.participants.contains { link in
            guard link.role == role,
                  let address = link.participant?.emailAddress
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  !address.isEmpty else {
                return false
            }
            return ownedAddresses.contains(address)
        }
    }

    private func sourceBodyText(for message: Message) -> String? {
        bodyText(for: message).flatMap {
            OriginalMessageText.cleaned(from: $0, characterLimit: 4_000)
        }
    }

    private func legacyPositiveExample(for rule: MailingListIgnoreRule) -> MailingListIgnoreFeatureSnapshot {
        MailingListIgnoreFeatureSnapshot(
            subjectFingerprint: rule.subjectFingerprint,
            subjectAnchors: rule.subjectAnchors,
            bodyAnchors: rule.bodyAnchors,
            primaryTagIDs: rule.semanticTagIDs,
            supportingTagIDs: [],
            purpose: .announcement,
            deliveryPriority: .list,
            isActionable: false,
            requiresConfirmation: false
        )
    }

    /// Nil is the intentional legacy representation. Any non-nil payload must
    /// decode successfully; corruption or a future incompatible schema must
    /// never broaden an automatic Trash rule by silently discarding evidence.
    private func decodedExamples(_ json: String?) -> [MailingListIgnoreFeatureSnapshot]? {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return try? decoder.decode([MailingListIgnoreFeatureSnapshot].self, from: data)
    }

    private func decodedFeature(_ json: String?) -> MailingListIgnoreFeatureSnapshot? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(MailingListIgnoreFeatureSnapshot.self, from: data)
    }

    private func encodedExamples(_ examples: [MailingListIgnoreFeatureSnapshot]) -> String? {
        guard let data = try? JSONEncoder().encode(examples) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func mergedExamples(
        _ lhs: [MailingListIgnoreFeatureSnapshot],
        _ rhs: [MailingListIgnoreFeatureSnapshot]
    ) -> [MailingListIgnoreFeatureSnapshot] {
        var seen = Set<String>()
        return (lhs + rhs).filter { example in
            let identity = [
                example.subjectFingerprint,
                example.primaryTagIDs.sorted().joined(separator: ","),
                example.deliveryPriority.rawValue,
            ].joined(separator: "|")
            return seen.insert(identity).inserted
        }
    }

    private func applyMatchEvidence(
        features: MailingListIgnoreFeatureSnapshot,
        match: MailingListIgnoreMatch,
        to audit: MailingListIgnoredMessage
    ) {
        audit.matchScore = match.score
        audit.matcherVersion = MailingListIgnoreMatcher.version
        audit.matchedSignalsJSON = try? String(
            decoding: JSONEncoder().encode(match.matchedSignals.sorted()),
            as: UTF8.self
        )
        audit.matchFeaturesJSON = try? String(
            decoding: JSONEncoder().encode(features),
            as: UTF8.self
        )
    }

    private func decodeDimensions(_ json: String?) -> MessageDimensions? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(MessageDimensions.self, from: data)
    }

    private func tagDisplayLabels(from dimensions: MessageDimensions?) -> [String] {
        guard let dimensions else { return [] }
        let labels = SemanticTagProjectionPresentation.canonical(dimensions.semanticTags).map(\.displayName)
        return unique(labels.map { normalizedDisplay($0) })
    }

    private func tagCanonicalIDs(from dimensions: MessageDimensions?) -> [String] {
        guard let dimensions else { return [] }
        return SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .map { $0.tagID.uuidString.lowercased() }
    }

    private func bodyText(for message: Message) -> String? {
        guard let path = normalizedNonEmpty(message.bodyTextPath) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
        return text.map { String($0.prefix(4_000)) }
    }

    private static func anchors(from text: String, limit: Int, includeWhole: Bool) -> [String] {
        let normalized = normalizedWords(text)
        guard !normalized.isEmpty else { return [] }
        var values: [String] = []
        if includeWhole, normalized.count >= 3 {
            values.append(String(normalized.prefix(120)))
        }

        let split = normalized
            .components(separatedBy: CharacterSet(charactersIn: " \n\r\t,.;:!?/\\|•·、。・「」『』【】[]()（）<>"))
            .map(normalizedWords)
            .filter { $0.count >= 3 && !isBoilerplate($0) }
        values.append(contentsOf: split)

        let words = normalized.split(separator: " ").map(String.init)
        if words.count >= 2 {
            for size in [4, 3, 2] {
                guard words.count >= size else { continue }
                for index in 0...(words.count - size) {
                    let phrase = words[index..<(index + size)].joined(separator: " ")
                    if phrase.count >= 5 && !isBoilerplate(phrase) {
                        values.append(phrase)
                    }
                }
            }
        }
        return Array(unique(values).prefix(limit))
    }

    nonisolated static func anchorsOverlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        for left in lhs.map(normalizedWords) where left.count >= 3 {
            for right in rhs.map(normalizedWords) where right.count >= 3 {
                if left == right || left.contains(right) || right.contains(left) {
                    return true
                }
                if similarity(left, right) >= 0.74 {
                    return true
                }
            }
        }
        return false
    }

    nonisolated static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(bigrams(lhs))
        let right = Set(bigrams(rhs))
        guard !left.isEmpty, !right.isEmpty else { return lhs == rhs ? 1.0 : 0.0 }
        let overlap = left.intersection(right).count
        return Double(overlap * 2) / Double(left.count + right.count)
    }

    nonisolated private static func bigrams(_ raw: String) -> [String] {
        let chars = Array(normalizedWords(raw))
        guard chars.count > 1 else { return raw.isEmpty ? [] : [raw] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }

    nonisolated static func isVagueSubject(_ fingerprint: String, anchors: [String]) -> Bool {
        let compact = fingerprint.replacingOccurrences(of: " ", with: "")
        if compact.count < 8 { return true }
        if anchors.isEmpty { return true }
        return isBoilerplate(compact)
    }

    nonisolated private static func isBoilerplate(_ value: String) -> Bool {
        let normalized = normalizedWords(value)
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let boilerplate: Set<String> = [
            "お知らせ", "リマインド", "通知", "notice", "reminder",
            "announcement", "information", "ご案内", "重要"
        ]
        return boilerplate.contains(normalized) || boilerplate.contains(compact)
    }

    nonisolated static func normalizedWords(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[\u{0000}-\u{001F}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[　\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func normalizedDisplay(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unique(_ values: [String]) -> [String] {
        Self.unique(values)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = normalizedWords(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        Self.normalizedNonEmpty(value)
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
