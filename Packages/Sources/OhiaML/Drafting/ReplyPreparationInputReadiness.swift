import Foundation
import SwiftData
import OhiaCore
import OhiaIngest

public enum ReplyPreparationInputBlocker: String, CaseIterable, Hashable, Sendable {
    case incompleteInterpretation
    case missingBodySummary
    case pendingDocumentExtraction
    case pendingVisualExtraction
    case pendingCaptureMetadata
    case activeInputMutation
}

public struct ReplyPreparationInputSnapshot: Sendable, Equatable {
    public let fingerprint: String
    public let witnessedLiveThreadMessageIDs: Set<UUID>
}

/// Synchronous reads on the caller's executor. The caller owns the context and
/// every model passed here; neither models nor contexts cross actor boundaries.
public enum ReplyPreparationInputReadiness {
    public enum Result: Sendable, Equatable {
        case ineligible
        case waiting(Set<ReplyPreparationInputBlocker>)
        case ready(ReplyPreparationInputSnapshot)
    }

    private static let documentTerminalStatuses: Set<String> = [
        AttachmentExtractionStatus.unsupportedType.rawValue,
        AttachmentExtractionStatus.parseFailed.rawValue,
        AttachmentExtractionStatus.encryptedOrPasswordProtected.rawValue,
        AttachmentExtractionStatus.tooLarge.rawValue,
        AttachmentExtractionStatus.emptyText.rawValue,
    ]

    private static let visualTerminalStatuses: Set<String> = [
        VisualAttachmentExtractionStatus.completed.rawValue,
        VisualAttachmentExtractionStatus.unsupportedType.rawValue,
        VisualAttachmentExtractionStatus.unavailable.rawValue,
        VisualAttachmentExtractionStatus.parseFailed.rawValue,
        VisualAttachmentExtractionStatus.guardrailViolation.rawValue,
        VisualAttachmentExtractionStatus.tooLarge.rawValue,
        VisualAttachmentExtractionStatus.emptyEvidence.rawValue,
    ]

    private static let inputMutatingJobTypes: Set<JobType> = [
        .summarize,
        .extractAttachments,
        .extractVisualAttachments,
        .extractCaptureMetadata,
    ]

    public static func evaluate(
        message: Message,
        context: ModelContext,
        forCompletedDraftCache: Bool = false
    ) -> Result {
        guard message.isSentByUser == false, message.isTrashed == false else {
            return .ineligible
        }
        let conversation = ReplySourcePreparationEligibility.conversationState(
            for: message,
            context: context
        )
        // A newer email in the conversation is its reply target and is
        // prepared instead, whatever this email's own inputs still await.
        if conversation.isSuperseded {
            return .ineligible
        }
        let needsReply = conversation.isEligible
        let mayCacheForegroundReply = forCompletedDraftCache
            && message.composerQueueOverride == .include
            && conversation.canRetainCompletedPreparation
        // Queue removal stops work requested only by Composer, while an open
        // reply obligation continues to own preemptive preparation.
        if message.composerQueueOverride == .exclude && !needsReply {
            return .ineligible
        }

        var blockers = Set<ReplyPreparationInputBlocker>()
        if interpretationIsComplete(
            message.analysis,
            requiresTriageVerdict: message.isLiveInboundTriageEligible && !forCompletedDraftCache
        ) == false {
            blockers.insert(.incompleteInterpretation)
        }
        if blockers.contains(.incompleteInterpretation) == false,
           !needsReply, !mayCacheForegroundReply {
            return .ineligible
        }
        if bodySummaryIsComplete(message.analysis) == false {
            blockers.insert(.missingBodySummary)
        }

        for attachment in message.attachments {
            // Only a first preparation waits for capture metadata. A reply
            // already prepared stays valid; if the visit finds new evidence
            // it clears the body summary, which re-prepares on its own.
            if message.replyPreparationReadyAt == nil, attachment.awaitsFirstCaptureMetadataVisit {
                blockers.insert(.pendingCaptureMetadata)
            }
            // Mail Drop rows hold no local bytes: there is no text or visual
            // extraction to wait for, only their capture metadata.
            if attachment.remoteURL != nil { continue }
            switch DocumentKind.detect(
                mimeType: attachment.mimeType,
                filename: attachment.filename
            ) {
            case .image:
                if visualExtractionIsTerminal(attachment) == false {
                    blockers.insert(.pendingVisualExtraction)
                }
            case .unsupported:
                continue
            default:
                if documentExtractionIsTerminal(attachment) == false {
                    blockers.insert(.pendingDocumentExtraction)
                }
            }
        }

        if hasActiveInputMutation(for: message.id, context: context) {
            blockers.insert(.activeInputMutation)
        }

        guard blockers.isEmpty else {
            return .waiting(blockers)
        }
        return .ready(
            ReplyPreparationInputSnapshot(
                fingerprint: ReplySourcePreparationFingerprint.value(for: message),
                witnessedLiveThreadMessageIDs: liveThreadMessageIDs(for: message)
            )
        )
    }

    public static func isReadyForFirstPresentation(
        message: Message,
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        guard message.replyPreparationRequiredAt != nil else { return true }
        // Past the hold the email appears whether or not its reply is prepared.
        if let deadline = message.replyPreparationPresentationDeadline, now >= deadline {
            return true
        }
        let readiness = evaluate(message: message, context: context)
        // No preparation will be made for this email — a newer email in its
        // conversation became the reply target, or the obligation closed —
        // so there is nothing to hold it for.
        if readiness == .ineligible {
            return true
        }
        guard message.replyPreparationReadyAt != nil,
              case let .ready(snapshot) = readiness,
              let relatedPreparationID = message.replySourcePreparation?.id else {
            return false
        }

        let messageID = message.id
        let descriptor = FetchDescriptor<ReplySourcePreparation>(
            predicate: #Predicate<ReplySourcePreparation> { row in
                row.messageId == messageID
            }
        )
        guard let rows = try? context.fetch(descriptor) else { return false }
        return rows.contains { preparation in
            preparation.id == relatedPreparationID
                && preparation.statusRaw == ReplySourcePreparationStatus.ready
                && preparation.contractVersion == ReplySourcePreparationFingerprint.contractVersion
                && preparation.inputFingerprint == snapshot.fingerprint
                && decodedWitnessedLiveThreadMessageIDs(in: preparation)
                    == snapshot.witnessedLiveThreadMessageIDs
        }
    }

    private static func interpretationIsComplete(
        _ analysis: MessageAnalysis?,
        requiresTriageVerdict: Bool
    ) -> Bool {
        guard let analysis,
              MailClassificationJSON.isComplete(analysis.mailClassificationJSON) else {
            return false
        }
        // Historical mail intentionally has metadata without live triage.
        // A completed foreground interview supplies its own reply intent.
        guard requiresTriageVerdict else { return true }
        guard let verdictJSON = analysis.triageVerdictJSON,
              let verdictData = verdictJSON.data(using: .utf8),
              (try? JSONDecoder().decode(TriageVerdict.self, from: verdictData)) != nil else {
            return false
        }
        return true
    }

    private static func bodySummaryIsComplete(_ analysis: MessageAnalysis?) -> Bool {
        guard let summary = analysis?.bodySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              summary.isEmpty == false,
              let inputFingerprint = analysis?.bodySummaryInputFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              inputFingerprint.isEmpty == false else {
            return false
        }
        return true
    }

    private static func documentExtractionIsTerminal(_ attachment: Attachment) -> Bool {
        if let path = attachment.extractedTextPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false {
            return FileManager.default.isReadableFile(atPath: path)
        }
        guard attachment.extractionNextRetryAt == nil,
              let status = attachment.extractionStatus else {
            return false
        }
        return documentTerminalStatuses.contains(status)
    }

    private static func visualExtractionIsTerminal(_ attachment: Attachment) -> Bool {
        guard let status = attachment.visualExtractionStatus else { return false }
        return visualTerminalStatuses.contains(status)
    }

    private static func hasActiveInputMutation(
        for messageID: UUID,
        context: ModelContext
    ) -> Bool {
        // UUID equality translates to SQL. Job's Codable status/type enums
        // must still be checked in memory, but only this message's jobs are
        // materialized instead of the entire historical queue per arrival.
        let descriptor = FetchDescriptor<Job>(
            predicate: #Predicate<Job> { $0.messageId == messageID }
        )
        guard let jobs = try? context.fetch(descriptor) else {
            return true
        }
        return jobs.contains { job in
            job.messageId == messageID
                && (job.status == .pending || job.status == .running)
                && inputMutatingJobTypes.contains(job.type)
        }
    }

    private static func liveThreadMessageIDs(for message: Message) -> Set<UUID> {
        var messagesByID: [UUID: Message] = [message.id: message]
        for member in message.thread?.messages ?? [] {
            messagesByID[member.id] = member
        }
        return Set(messagesByID.values.compactMap { member in
            member.liveDetectedAt == nil ? nil : member.id
        })
    }

    private static func decodedWitnessedLiveThreadMessageIDs(
        in preparation: ReplySourcePreparation
    ) -> Set<UUID> {
        guard let encoded = preparation.witnessedLiveThreadMessageIDsJSON,
              let data = encoded.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return Set(ids)
    }
}
