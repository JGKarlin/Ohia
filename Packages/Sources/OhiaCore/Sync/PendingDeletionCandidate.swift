import Foundation
import SwiftData

/// Staged deletion candidate for non-Gmail accounts. The deletion-sync
/// coordinator inserts one of these per `.deferToGracePeriod` decision;
/// the `PendingDeletionReaperWorker` finalizes (cascades) or drops
/// (move detected late) at grace-period expiry.
///
/// The reaper's "expired candidates" query filters on
/// `gracePeriodEndsAt`. We can add `@Attribute(.index)` here when row
/// volume justifies it; for typical mailboxes (low candidate counts at
/// any time) the full-table scan is fine.
@Model
public final class PendingDeletionCandidate {
    /// Default grace-period window. Long enough to absorb
    /// most folder-poll latencies; shorter than the 29-min IDLE rotation
    /// (fast moves rely on the ingestion-side early-exit hook).
    public static let gracePeriodSeconds: TimeInterval = DeletionSyncPreferences.defaultNonGmailGracePeriodSeconds

    public var id: UUID
    public var accountID: UUID
    public var messageID: UUID
    public var folder: String
    public var uid: UInt32
    public var messageIdHeader: String?
    public var vanishedAt: Date
    public var gracePeriodEndsAt: Date

    public init(
        accountID: UUID,
        messageID: UUID,
        folder: String,
        uid: UInt32,
        messageIdHeader: String?,
        vanishedAt: Date,
        gracePeriodEndsAt: Date? = nil
    ) {
        self.id = UUID()
        self.accountID = accountID
        self.messageID = messageID
        self.folder = folder
        self.uid = uid
        self.messageIdHeader = messageIdHeader
        self.vanishedAt = vanishedAt
        self.gracePeriodEndsAt = gracePeriodEndsAt
            ?? vanishedAt.addingTimeInterval(Self.gracePeriodSeconds)
    }
}
