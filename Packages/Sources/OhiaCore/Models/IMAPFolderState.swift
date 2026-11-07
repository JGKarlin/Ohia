import Foundation
import SwiftData

@Model
public final class IMAPFolderState {
    public var id: UUID
    public var account: Account?
    public var folderName: String
    /// JSON-encoded `[String]` of RFC 6154 special-use flags (`\Sent`, `\Trash`,
    /// `\All`, `\Drafts`, `\Junk`, `\Flagged`, `\Archive`, `\Inbox`) plus
    /// server-reported generic flags (`\Noselect`, `\HasChildren`,
    /// `\HasNoChildren`). Stored as JSON string because SwiftData `#Predicate`
    /// doesn't support array-of-String membership checks reliably.
    public var folderAttributesJSON: String
    public var uidValidity: UInt32
    public var uidNextAtLastSelect: UInt32
    /// Server-reported message count from the most recent SELECT. This is a
    /// per-folder diagnostic count, not a deduped account total. `UIDNEXT` is
    /// a cursor, not a count, especially on Gmail where UID space is sparse.
    public var existsAtLastSelect: Int?
    /// Highest UID we've ingested from this folder. 0 until the first fetch.
    public var highestFetchedUID: UInt32
    /// Walks down during backfill. Set to `uidNextAtLastSelect` on first select
    /// (meaning "nothing fetched yet, cursor is above the top of the range").
    public var lowestFetchedUID: UInt32
    public var backfillComplete: Bool
    public var lastIdleAt: Date?
    public var lastPollAt: Date?
    /// Timestamp of the most recent failed `.imapPollFolder` attempt. This is
    /// separate from `lastPollAt` so a cleared failure can suppress immediate
    /// reseeding without pretending the poll succeeded.
    public var lastPollFailureAt: Date?
    /// Timestamp of the most recent `.imapDeletionWatch` tick (SELECT-only
    /// lightweight deletion-watch path).
    /// Optional per the SwiftData lightweight-migration constraint — adding
    /// non-optional fields with defaults to existing `@Model` rows crashes
    /// migration on macOS.
    public var lastDeletionWatchAt: Date?
    /// Timestamp of the most recent failed `.imapDeletionWatch` attempt.
    public var lastDeletionWatchFailureAt: Date?
    /// RFC 7162 modseq tracker. `nil` until the first SELECT after upgrade
    /// records a server-reported HIGHESTMODSEQ.
    public var highestModSeq: UInt64?
    /// Timestamp of the last successful deletion-sync pass for this folder.
    public var lastDeletionSyncAt: Date?
    /// Timestamp of the last full server Message-ID reconciliation pass.
    /// Used as a fallback for providers that miss or omit VANISHED events.
    public var lastMessageIDReconciliationAt: Date?
    /// Lower bound that the current historical IMAP backfill completion state
    /// applies to. nil means all-time backfill, matching legacy behavior.
    public var backfillLowerBoundAt: Date?
    /// Initial-import UID-work snapshot. All fields stay optional so existing
    /// SwiftData rows load through lightweight migration without a backfill.
    public var initialImportUIDWorkTotal: Int?
    public var initialImportUIDWorkRemaining: Int?
    public var initialImportSnapshotUIDValidity: UInt32?
    public var initialImportTerminalExclusionReason: String?
    /// Date-scoped server message count from the most recent SELECT/search.
    /// Used by gap checks for finite account history windows so we don't
    /// compare local in-window messages to the server's full EXISTS count.
    public var inScopeMessageCountAtLastSelect: Int?
    /// Round-robin cursor for lightweight FLAGS-only reconciliation on servers
    /// that do not support QRESYNC. Optional for lightweight migration safety.
    public var lastFlagReconciliationUID: UInt32?
    public var createdAt: Date
    public var updatedAt: Date

    public init(account: Account, folderName: String, attributes: [String], uidValidity: UInt32) {
        self.id = UUID()
        self.account = account
        self.folderName = folderName
        if let data = try? JSONEncoder().encode(attributes),
           let str = String(data: data, encoding: .utf8) {
            self.folderAttributesJSON = str
        } else {
            self.folderAttributesJSON = "[]"
        }
        self.uidValidity = uidValidity
        self.uidNextAtLastSelect = 0
        self.existsAtLastSelect = nil
        self.highestFetchedUID = 0
        self.lowestFetchedUID = 0
        self.backfillComplete = false
        self.highestModSeq = nil
        self.lastDeletionSyncAt = nil
        self.lastMessageIDReconciliationAt = nil
        self.backfillLowerBoundAt = nil
        self.inScopeMessageCountAtLastSelect = nil
        self.lastFlagReconciliationUID = nil
        self.lastPollFailureAt = nil
        self.lastDeletionWatchAt = nil
        self.lastDeletionWatchFailureAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Decoded view of the attributes JSON. Returns `[]` on any parse error
    /// (defensive — the field is JSON-only writable from our code).
    public var folderAttributes: [String] {
        guard let data = folderAttributesJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    public func setFolderAttributes(_ arr: [String]) {
        if let data = try? JSONEncoder().encode(arr),
           let str = String(data: data, encoding: .utf8) {
            folderAttributesJSON = str
        } else {
            folderAttributesJSON = "[]"
        }
    }
}
