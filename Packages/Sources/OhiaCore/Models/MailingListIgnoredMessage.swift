import Foundation
import SwiftData

public enum MailingListIgnoredTrashDisposition {
    /// The source message was removed locally and a server-side move to Trash
    /// was queued.
    public static let serverTrash = "serverTrash"
    /// The source had no writable IMAP coordinates, so Ohia could only remove
    /// its local copy.
    public static let localOnly = "localOnly"
    /// The record was written before the mailbox dispatcher completed. This is
    /// intentionally durable so a post-commit artifact-cleanup failure cannot
    /// erase the fact that the ignore action happened.
    public static let pending = "pending"
}

public enum MailingListIgnoredRemoteStatus {
    /// The server-side move has been persisted and is waiting for the mailbox
    /// mutation worker.
    public static let queued = "queued"
    /// IMAP confirmed that the message moved to Trash.
    public static let completed = "completed"
    /// The mailbox mutation exhausted retries or failed permanently.
    public static let failed = "failed"
    /// No writable remote coordinates existed; only Ohia's local row moved.
    public static let notApplicable = "notApplicable"
}

/// Durable audit evidence for one message removed by a mailing-list ignore
/// rule. The source `Message` row is deleted by the Trash mutation, so this
/// model deliberately stores scalar evidence instead of a SwiftData
/// relationship.
@Model
public final class MailingListIgnoredMessage {
    #Index<MailingListIgnoredMessage>(
        [\.id],
        [\.ruleID, \.originalMessageID],
        [\.accountID, \.normalizedMessageIDHeader]
    )

    public var id: UUID
    public var ruleID: UUID
    public var accountID: UUID
    public var listId: String
    public var originalMessageID: UUID
    public var messageIdHeader: String?
    /// Lowercased Message-ID without surrounding angle brackets. Stored so the
    /// restore exemption lookup stays indexed instead of scanning account
    /// history and normalizing every row in memory.
    public var normalizedMessageIDHeader: String?
    public var subject: String
    public var senderAddress: String
    public var senderName: String?
    public var messageDate: Date?
    public var ignoredAt: Date
    public var trashDispositionRaw: String
    /// Truthful remote lifecycle. Older rows can have nil, which is treated as
    /// unknown/queued rather than guessing that an IMAP move completed.
    public var remoteStatusRaw: String?
    public var lastRemoteError: String?
    /// Explainability captured at decision time, before the Message row leaves
    /// the active store.
    public var matchScore: Double?
    public var matchedSignalsJSON: String?
    public var matcherVersion: String?
    /// The source-only matcher input for this decision. Kept opaque in Core;
    /// OhiaScheduler decodes it when Restore should refine the originating rule.
    public var matchFeaturesJSON: String?
    /// Set when Restore also teaches the rule that this message family was a
    /// false positive.
    public var excludedFromRuleAt: Date?
    /// Set before a restore starts. It also acts as the one-message exemption
    /// that prevents an active rule from immediately ignoring the restored
    /// copy when it is re-ingested from Inbox.
    public var restoreRequestedAt: Date?
    public var restoredAt: Date?
    public var lastRestoreError: String?

    public init(
        id: UUID = UUID(),
        ruleID: UUID,
        accountID: UUID,
        listId: String,
        originalMessageID: UUID,
        messageIdHeader: String?,
        normalizedMessageIDHeader: String? = nil,
        subject: String,
        senderAddress: String,
        senderName: String?,
        messageDate: Date?,
        ignoredAt: Date = .now,
        trashDispositionRaw: String = MailingListIgnoredTrashDisposition.pending,
        remoteStatusRaw: String? = nil,
        lastRemoteError: String? = nil,
        matchScore: Double? = nil,
        matchedSignalsJSON: String? = nil,
        matcherVersion: String? = nil,
        matchFeaturesJSON: String? = nil,
        excludedFromRuleAt: Date? = nil,
        restoreRequestedAt: Date? = nil,
        restoredAt: Date? = nil,
        lastRestoreError: String? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.accountID = accountID
        self.listId = listId
        self.originalMessageID = originalMessageID
        self.messageIdHeader = messageIdHeader
        self.normalizedMessageIDHeader = normalizedMessageIDHeader
        self.subject = subject
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.messageDate = messageDate
        self.ignoredAt = ignoredAt
        self.trashDispositionRaw = trashDispositionRaw
        self.remoteStatusRaw = remoteStatusRaw
        self.lastRemoteError = lastRemoteError
        self.matchScore = matchScore
        self.matchedSignalsJSON = matchedSignalsJSON
        self.matcherVersion = matcherVersion
        self.matchFeaturesJSON = matchFeaturesJSON
        self.excludedFromRuleAt = excludedFromRuleAt
        self.restoreRequestedAt = restoreRequestedAt
        self.restoredAt = restoredAt
        self.lastRestoreError = lastRestoreError
    }
}

public extension MailingListIgnoredMessage {
    var wasMovedToServerTrash: Bool {
        trashDispositionRaw == MailingListIgnoredTrashDisposition.serverTrash
    }

    var isRemoteTrashCompleted: Bool {
        guard wasMovedToServerTrash else { return false }
        return remoteStatusRaw == MailingListIgnoredRemoteStatus.completed
    }

    var isRemoteTrashQueued: Bool {
        guard wasMovedToServerTrash else { return false }
        return remoteStatusRaw == nil
            || remoteStatusRaw == MailingListIgnoredRemoteStatus.queued
    }

    var didRemoteTrashFail: Bool {
        remoteStatusRaw == MailingListIgnoredRemoteStatus.failed
    }

    var wasHiddenLocallyOnly: Bool {
        trashDispositionRaw == MailingListIgnoredTrashDisposition.localOnly
    }

    var hasRestoreExemption: Bool {
        restoreRequestedAt != nil
    }

    var isRestored: Bool {
        restoredAt != nil
    }
}
