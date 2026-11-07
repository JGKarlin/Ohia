import Foundation
import SwiftData

/// Persistent record of a user-initiated mutation against a remote mailbox
/// (mark read / mark unread / move to Junk / move to Trash / move to Inbox /
/// permanent delete). Mirrors the OutboxItem pattern:
/// the row is created when the user takes the action and stays in the
/// store until the propagation job either succeeds (`.succeeded`) or
/// exhausts retries (`.failed`). Most Constellation actions update local
/// state optimistically; Move to Junk instead retains the local message until
/// the provider move succeeds. This row drives the server-side write and its
/// crash-survivable local finalization.
///
/// `messageRef` is a weak link to the Message row when present — for
/// move-to-Trash and permanent-delete actions the Message row may already be
/// gone (we remove it locally on enqueue), so the worker relies on `accountID`,
/// `imapFolderPath`, `imapUID`, RFC Message-ID, and optional destination
/// fields to issue and verify the remote command.
@Model
public final class MailboxMutation {
    public var id: UUID

    /// The account whose IMAP session this mutation runs against.
    /// Resolved on the worker tick; not held as a relationship because
    /// the row must outlive Account-side migrations.
    public var accountID: UUID

    /// The Message-Id (Ohia's UUID) at the time of enqueue. Useful for
    /// debugging and for collapsing duplicate enqueues; the worker does
    /// not require the Message row to still exist.
    public var messageID: UUID

    /// The remote folder path (already-quoted IMAP mailbox name in its
    /// raw form, e.g. `"INBOX"` or `"[Gmail]/All Mail"`). Captured at
    /// enqueue time because Message.imapFolderPath may be cleared by the
    /// optimistic local removal before the worker runs.
    public var imapFolderPath: String

    /// The UID inside `imapFolderPath` at enqueue time.
    public var imapUID: UInt32

    /// RFC 5322 Message-ID captured before optimistic local removal. Unlike an
    /// IMAP UID, this identity survives mailbox moves and UIDVALIDITY changes,
    /// so the worker can re-resolve stale coordinates and prove the intended
    /// provider message actually reached Trash. Optional for lightweight
    /// migration of mutation rows created by older builds.
    public var rfcMessageIDHeader: String?

    /// Optional UIDVALIDITY for the source folder at enqueue time. Transient
    /// Withheld rows always provide this so the worker can fail closed if the
    /// folder generation changes before a queued server mutation runs.
    public var expectedUIDValidity: UInt32?

    /// Server-side action this row represents.
    public var kind: MailboxMutationKind

    /// Destination mailbox for actions that move/copy to another folder
    /// (`.moveToJunk`, `.moveToTrash`, `.moveToInbox`). Optional for lightweight migration
    /// and because flag-only mutations do not need a destination.
    public var destinationFolderPath: String?

    /// Lightweight evidence captured when a user move should inform future
    /// Junk/Spam weighting. These stay on the existing mutation row so the
    /// feedback history follows the mailbox operation itself rather than a
    /// parallel classifier table. All fields are optional for lightweight
    /// migration and because non-spam mailbox actions do not carry feedback.
    public var feedbackSourceRoleRaw: String?
    public var feedbackSenderAddress: String?
    public var feedbackSenderDomain: String?
    public var feedbackListId: String?
    public var feedbackSubjectFingerprint: String?
    public var feedbackProviderSpamScore: Double?

    /// Lifecycle status. `.queued` rows in `nextAttemptAfter` are
    /// eligible to drain on the next tick.
    public var status: MailboxMutationStatus

    public var createdAt: Date
    public var lastAttemptAt: Date?
    public var nextAttemptAfter: Date?
    public var attempts: Int
    public var lastError: String?
    /// Set only after a succeeded destructive provider mutation has completed
    /// (or safely waived) its local Message/artifact finalization. Optional for
    /// lightweight migration of mutation history created by earlier builds.
    public var localFinalizedAt: Date?

    public init(
        accountID: UUID,
        messageID: UUID,
        imapFolderPath: String,
        imapUID: UInt32,
        rfcMessageIDHeader: String? = nil,
        expectedUIDValidity: UInt32? = nil,
        kind: MailboxMutationKind,
        destinationFolderPath: String? = nil,
        feedbackSourceRoleRaw: String? = nil,
        feedbackSenderAddress: String? = nil,
        feedbackSenderDomain: String? = nil,
        feedbackListId: String? = nil,
        feedbackSubjectFingerprint: String? = nil,
        feedbackProviderSpamScore: Double? = nil
    ) {
        self.id = UUID()
        self.accountID = accountID
        self.messageID = messageID
        self.imapFolderPath = imapFolderPath
        self.imapUID = imapUID
        self.rfcMessageIDHeader = rfcMessageIDHeader
        self.expectedUIDValidity = expectedUIDValidity
        self.kind = kind
        self.destinationFolderPath = destinationFolderPath
        self.feedbackSourceRoleRaw = feedbackSourceRoleRaw
        self.feedbackSenderAddress = feedbackSenderAddress
        self.feedbackSenderDomain = feedbackSenderDomain
        self.feedbackListId = feedbackListId
        self.feedbackSubjectFingerprint = feedbackSubjectFingerprint
        self.feedbackProviderSpamScore = feedbackProviderSpamScore
        self.status = .queued
        self.createdAt = Date()
        self.attempts = 0
        self.localFinalizedAt = nil
    }
}
