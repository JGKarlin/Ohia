import Foundation
import SwiftData
import OhiaCore
import OhiaML

enum ProjectMessageInputBuilder {
    static func hasDirectSharedRecipientEvidence(for input: ProjectMessageInput) -> Bool {
        input.participants.contains { participant in
            participant.email.isEmpty == false
                && (participant.role == .cc || participant.role == .bcc)
        }
    }

    static func projectInput(
        for message: Message,
        date: Date,
        dimensions: MessageDimensions?,
        triageVerdict: TriageVerdict?
    ) -> ProjectMessageInput? {
        let semanticTags = SemanticTagProjectionPresentation.canonical(dimensions?.semanticTags ?? [])
        let participants = message.participants.compactMap { link -> ProjectParticipant? in
            guard let participant = link.participant else { return nil }
            return ProjectParticipant(
                email: participant.emailAddress,
                displayName: participant.displayName.map(MIMEHeaderDecoder.decodeEncodedWords),
                role: link.role
            )
        }
        let attachmentKinds = Set(message.attachments.map {
            ProjectAttachmentKind.classify(mimeType: $0.mimeType, fileName: $0.filename)
        })
        let isLiveInbound = message.isLiveInboundTriageEligible
        let classification = MailClassificationJSON.decode(message.analysis?.mailClassificationJSON)
        let customCategoryKeys = Set(CustomCategoryKeysJSON.decode(
            message.analysis?.customCategoryKeysJSON
        ))
        let isNonHumanTraffic = DeterministicMessageTrafficFacts.isNonHumanTraffic(message: message)
        return ProjectMessageInput(
            id: message.id,
            accountID: message.accountID,
            threadID: message.thread?.id,
            date: date,
            subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
            bodySummary: message.analysis?.bodySummary,
            fromAddress: message.fromAddress,
            fromName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
            isSentByUser: message.isSentByUser,
            isLiveInbound: isLiveInbound,
            isRead: message.isReadOrFalse,
            isFlagged: message.flaggedOrFalse,
            isInComposerQueue: message.isComposerQueueEligible,
            hasAttachments: message.hasAttachments,
            attachmentKinds: attachmentKinds,
            participants: participants,
            messageType: message.messageType,
            triageVerdict: isLiveInbound ? triageVerdict : nil,
            purpose: classification?.purpose,
            isNonHumanTraffic: isNonHumanTraffic,
            customCategoryKeys: customCategoryKeys,
            semanticTags: semanticTags,
            deadlines: isLiveInbound ? dimensions?.deadlines ?? [] : [],
            messageIDHeader: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            referencesChain: message.referencesChain,
            repliedAt: message.repliedAt
        )
    }
}

/// Fresh-start gating for the shared semantic status computation used by
/// Front Page and Timeline. Manual Projects do not consult this policy.
enum ProjectFreshStartPolicy {
    static let activeWindowDuration: TimeInterval = 24 * 60 * 60

    static func activeWindow(
        modelContext: ModelContext,
        filter: VectorFilter
    ) -> SemanticStatusActiveWindow? {
        let accounts = ((try? modelContext.fetch(FetchDescriptor<Account>())) ?? [])
            .filter { account in
                guard let accountIds = filter.accountIds, !accountIds.isEmpty else { return true }
                return accountIds.contains(account.id)
            }
        let cutoffs = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, account.createdAt.addingTimeInterval(-activeWindowDuration))
        })
        guard !cutoffs.isEmpty else { return nil }
        return SemanticStatusActiveWindow(
            cutoffByAccountID: cutoffs,
            fallbackCutoff: cutoffs.count == 1 ? cutoffs.values.first : nil
        )
    }
}
