import Foundation
import SwiftData
import OhiaCore

/// Turns a confirmed send into training evidence. A send the author edited,
/// or whose instruction revision they endorsed by sending, records one
/// writer-task pair: the frozen generation basis as input, the sent text as
/// completion. A send without a recorded basis stays pending for the
/// preparation job, which compiles it from the draft or reconstructs it
/// from the sent mail. An accepted send that used a saved style's unchanged
/// sliders, or explicit slider changes, is recorded as a style preference in
/// every case.
public final class SentTrainingFeedbackRecorder: Sendable {
    public static let writerEventKind = "writer"

    private let canonicalStore: CanonicalStore

    public init(canonicalStore: CanonicalStore) {
        self.canonicalStore = canonicalStore
    }

    @MainActor
    public func record(_ item: OutboxItem, context: ModelContext, now: Date = .now) throws {
        guard item.status == .sent, item.trainingFeedbackProcessedAt == nil else { return }
        guard let evidence = try SentTrainingEvidenceStore().recordSuccessfulSend(
            item,
            context: context,
            now: now
        ) else {
            finish(item, disposition: .notEligible, now: now)
            return
        }
        guard item.learnFromSend else {
            finish(item, disposition: .dismissed, now: now)
            return
        }
        guard let messageID = normalizeMessageIDHeader(item.messageIDHeader),
              let draft = item.draft else {
            finalize(
                evidence,
                disposition: .excluded,
                reason: .unsupportedEvidenceShape,
                now: now
            )
            finish(item, disposition: .notEligible, now: now)
            return
        }

        let finalText = AuthoredReplyText.extract(from: item.plainBody)
        guard !finalText.isEmpty else {
            finalize(evidence, disposition: .excluded, reason: .missingBody, now: now)
            finish(item, disposition: .notEligible, now: now)
            return
        }

        let generatedRevisions = draft.orderedRevisions.filter {
            $0.triggerRaw != DraftRevisionTrigger.manualEdit
        }
        let matchingGeneratedRevision = generatedRevisions.last {
            AuthoredReplyText.extract(from: $0.bodyText) == finalText
        }
        let matchesGeneratedRevision = matchingGeneratedRevision != nil
        let styleControlSnapshot = item.styleControlSnapshot
            ?? matchingGeneratedRevision?.styleControlSnapshot
            ?? draft.styleControlSnapshot
        let approvedSignals = TrainingSignal.decodeJSON(item.approvedTrainingSignalsJSON)
        let dismissedAllSignals = item.approvedTrainingSignalsJSON != nil
            && approvedSignals.isEmpty

        let stylePreferenceEventID = try recordStylePreferenceEvent(
            snapshot: styleControlSnapshot,
            item: item,
            draft: draft,
            finalText: finalText,
            generatedTextWasEdited: !matchesGeneratedRevision,
            normalizedMessageID: messageID,
            context: context,
            now: now
        )

        // Unchanged model output is not the author's writing unless the
        // author endorsed an instruction revision by sending it; dismissing
        // every edit signal declines to learn from an edit.
        let endorsed = TrainingPairBuilder.endorsedInstructionRevision(of: draft)
        let eligible = endorsed != nil || (!matchesGeneratedRevision && !dismissedAllSignals)
        guard eligible else {
            finalize(evidence, disposition: .excluded,
                reason: matchesGeneratedRevision ? .unchangedGeneratedOutput : .userOptOut, now: now)
            let disposition: SentTrainingFeedbackDisposition = stylePreferenceEventID != nil
                ? .recorded : (matchesGeneratedRevision ? .noUserAuthoredDelta : .dismissed)
            finish(item, disposition: disposition, now: now)
            return
        }

        let key = Self.eventKey(messageID: messageID, kind: Self.writerEventKind, revisionID: nil)
        if containsPair(eventKey: key, context: context) {
            linkExistingPair(eventKey: key, to: evidence, context: context)
            finalize(evidence, disposition: .loraEligible, now: now)
            finish(item, disposition: .recorded, now: now)
            return
        }
        guard item.generationBasisJSON != nil else {
            // The preparation job compiles the example from the draft's
            // recorded decisions, or reconstructs it once the sent mail syncs.
            evidence.updatedAt = now
            finish(item, disposition: .recorded, now: now)
            return
        }
        let example: ComposerWriterTraining.Example
        do {
            example = try ComposerWriterTraining.example(fromSend: item)
        } catch let error as ComposerContentError {
            // A basis this build cannot render leaves the evidence pending:
            // the preparation job compiles the example from the draft's
            // recorded decisions or reconstructs it from the sent mail.
            print("[Ohia] send basis not renderable at record time: \(error.kind)")
            evidence.updatedAt = now
            finish(item, disposition: .recorded, now: now)
            return
        }
        let pair = try TrainingPairBuilder.apply(example, to: nil, evidence: evidence,
            sourceWeight: TrainingPairBuilder.sendWeight(item))
        stamp(pair, evidence: evidence, eventKey: key, item: item,
            normalizedMessageID: messageID, stylePreferenceEventID: stylePreferenceEventID)
        context.insert(pair)
        finalize(evidence, disposition: .loraEligible, now: now)
        finish(item, disposition: .recorded, now: now)
    }

    @MainActor
    private func recordStylePreferenceEvent(
        snapshot: StyleControlSnapshot?,
        item: OutboxItem,
        draft: Draft,
        finalText: String,
        generatedTextWasEdited: Bool,
        normalizedMessageID: String,
        context: ModelContext,
        now: Date
    ) throws -> UUID? {
        guard let snapshot,
              let accountID = item.account?.id
                ?? draft.composeFromAccountID
                ?? draft.message?.accountID
                ?? draft.message?.account?.id else { return nil }
        let languageID = DraftLanguage.detectedFamilyID(ofText: finalText)
            ?? DraftLanguage.familyID(for: draft.languageID)
            ?? "und"
        let selectedRegister = snapshot.registerID.flatMap {
            StyleRegisterResolver.register(withID: $0, language: languageID, context: context)
        }
        let usesSavedStyleDefaults: Bool
        if let selectedRegister,
           selectedRegister.isUserSavedStyle,
           let effective = snapshot.effectiveAxes,
           let defaults = selectedRegister.styleAxes {
            usesSavedStyleDefaults = !effective.differs(from: defaults, tolerance: 0.0001)
        } else {
            usesSavedStyleDefaults = false
        }
        // A style picked from the Style pane is the author's choice for this
        // correspondent even when its sliders were left alone.
        let usesChosenStyle = snapshot.registerID != nil && snapshot.registerID == draft.chosenStyleRegisterID
        guard snapshot.isExplicitPreference || usesSavedStyleDefaults || usesChosenStyle else { return nil }
        let key = Self.eventKey(
            messageID: normalizedMessageID,
            kind: "style-preference",
            revisionID: nil
        )
        var descriptor = FetchDescriptor<StylePreferenceEvent>(
            predicate: #Predicate<StylePreferenceEvent> { event in
                event.eventKey == key
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing.id
        }

        let recipient = Self.firstRecipient(from: item.toAddressesJSON)?.address.lowercased()
        let event = StylePreferenceEvent(
            eventKey: key,
            sourceOutboxID: item.id,
            accountID: accountID,
            correspondentAddress: recipient,
            languageID: languageID,
            acceptedBodyText: finalText,
            styleControlSnapshot: snapshot,
            generatedTextWasEdited: generatedTextWasEdited,
            createdAt: now
        )
        context.insert(event)
        return event.id
    }

    @MainActor
    private func containsPair(eventKey: String, context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<TrainingPair>(
            predicate: #Predicate<TrainingPair> { pair in
                pair.sourceEventKey == eventKey
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).isEmpty == false) == true
    }

    private func stamp(
        _ pair: TrainingPair,
        evidence: SentTrainingEvidence,
        eventKey: String,
        item: OutboxItem,
        normalizedMessageID: String,
        stylePreferenceEventID: UUID?
    ) {
        pair.evidence = evidence
        pair.evidenceRevision = evidence.revision
        pair.stylePreferenceEventID = stylePreferenceEventID
        pair.sourceEventKey = eventKey
        pair.sourceOutboxID = item.id
        pair.sourceMessageIDNormalized = normalizedMessageID
        pair.styleEvidenceAccountID = item.account?.id
        pair.styleEvidenceCorrespondentAddress = Self.firstRecipient(
            from: item.toAddressesJSON
        )?.address.lowercased()
    }

    @MainActor
    private func linkExistingPair(
        eventKey: String,
        to evidence: SentTrainingEvidence,
        context: ModelContext
    ) {
        var descriptor = FetchDescriptor<TrainingPair>(
            predicate: #Predicate<TrainingPair> { pair in
                pair.sourceEventKey == eventKey
            }
        )
        descriptor.fetchLimit = 1
        guard let pair = try? context.fetch(descriptor).first else { return }
        pair.evidence = evidence
        pair.evidenceRevision = evidence.revision
    }

    private func finalize(
        _ evidence: SentTrainingEvidence,
        disposition: SentTrainingEvidenceDisposition,
        reason: SentTrainingEvidenceReason? = nil,
        now: Date
    ) {
        evidence.disposition = disposition
        evidence.reason = reason
        evidence.dispositionedAt = now
        evidence.preparationAttemptedAt = now
        evidence.isRetryable = false
        evidence.updatedAt = now
    }

    private func finish(
        _ item: OutboxItem,
        disposition: SentTrainingFeedbackDisposition,
        now: Date
    ) {
        item.trainingFeedbackDispositionRaw = disposition.rawValue
        item.trainingFeedbackProcessedAt = now
        item.trainingFeedbackError = nil
    }

    static func eventKey(
        messageID: String,
        kind: String,
        revisionID: UUID?
    ) -> String {
        ["sent", messageID, kind, revisionID?.uuidString]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    private static func firstRecipient(from json: String?) -> (name: String, address: String)? {
        guard let json, let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data).first,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let address = String(trimmed[trimmed.index(after: open)..<close])
            return (name.isEmpty ? address : name, address)
        }
        return (trimmed, trimmed)
    }
}
