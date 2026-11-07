import Foundation

/// Session-to-manager callback protocol. The manager conforms as a
/// `@MainActor` class; the session calls `reportStatus` from its actor
/// context and Swift infers the main-actor hop.
public protocol IMAPSessionStatusReporting: AnyObject, Sendable {
    @MainActor func reportStatus(_ status: IMAPSessionStatus, for accountID: UUID)
    @MainActor func reportDeletionEvent(_ event: IMAPDeletionEvent, for accountID: UUID)
    @MainActor func reportFlagSnapshotEvent(_ event: IMAPFlagSnapshotEvent, for accountID: UUID)
    @MainActor func reportNewInboundMessages(_ event: IMAPNewInboundMessageEvent, for accountID: UUID)
}

public extension IMAPSessionStatusReporting {
    @MainActor func reportDeletionEvent(_ event: IMAPDeletionEvent, for accountID: UUID) {}
    @MainActor func reportFlagSnapshotEvent(_ event: IMAPFlagSnapshotEvent, for accountID: UUID) {}
    @MainActor func reportNewInboundMessages(_ event: IMAPNewInboundMessageEvent, for accountID: UUID) {}
}

public extension Notification.Name {
    static let ohiaIMAPNewInboundMessages = Notification.Name("ohia.imap.newInboundMessages")
    static let ohiaIMAPCheckingMail = Notification.Name("ohia.imap.checkingMail")
}

/// Sendable mirror of `IMAPSession.Status` without the actor-internal reasons
/// needing to cross isolation. `IMAPSession.Status` is defined on the session
/// actor; the manager reads a sendable copy here.
public enum IMAPSessionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case authing
    case selected(mailbox: String, exists: Int, uidNext: UInt32, uidValidity: UInt32)
    case idling
    case syncing(folder: String)
    case reconnecting(attempt: Int)
    case halted(reason: IMAPSessionHaltReason)
}

public enum IMAPSessionHaltReason: Sendable, Equatable {
    case authFailed(String)
    case reauthRequired(String)
    case certMismatch(presented: String)
    case tlsError(String)
    case protocolViolation(String)
}

public struct IMAPUIDMessageID: Sendable, Equatable {
    public let uid: UInt32
    public let messageID: String

    public init(uid: UInt32, messageID: String) {
        self.uid = uid
        self.messageID = messageID
    }
}

public struct IMAPNewInboundMessageEvent: Sendable, Equatable {
    public let folder: String
    public let count: Int
    public let messageIDs: [UUID]
    public let observedAt: Date

    public init(
        folder: String,
        count: Int,
        messageIDs: [UUID] = [],
        observedAt: Date = Date()
    ) {
        self.folder = folder
        self.count = count
        self.messageIDs = messageIDs
        self.observedAt = observedAt
    }
}

public struct IMAPFlagSnapshotEvent: Sendable, Equatable {
    public let folder: String
    public let snapshots: [IMAPFlagSnapshot]
    public let observedAt: Date

    public init(
        folder: String,
        snapshots: [IMAPFlagSnapshot],
        observedAt: Date = Date()
    ) {
        self.folder = folder
        self.snapshots = snapshots
        self.observedAt = observedAt
    }
}

public struct IMAPDeletionEvent: Sendable, Equatable {
    public let folder: String
    public let folderAttributes: [String]
    public let uidValidityBefore: UInt32?
    public let uidValidityAfter: UInt32
    public let highestModSeqBefore: UInt64?
    public let highestModSeqAfter: UInt64?
    public let vanishedUIDs: [UInt32]
    public let observedAt: Date
    /// Set ONLY on first-sync (when highestModSeqBefore was nil at SELECT time).
    /// Carries the server's full current UID set for the folder, so the
    /// coordinator can reconcile by diffing against locally-known UIDs and
    /// cascading any local UIDs that aren't present on the server. Subsequent
    /// polls leave this nil — QRESYNC handles incremental detection.
    public let serverUidSetForReconciliation: [UInt32]?
    /// Current server UID → Message-ID snapshot used to reconcile rows whose
    /// IMAP UID is missing.
    public let serverMessageIDsForReconciliation: [IMAPUIDMessageID]?

    public init(
        folder: String,
        folderAttributes: [String],
        uidValidityBefore: UInt32?,
        uidValidityAfter: UInt32,
        highestModSeqBefore: UInt64?,
        highestModSeqAfter: UInt64?,
        vanishedUIDs: [UInt32],
        observedAt: Date,
        serverUidSetForReconciliation: [UInt32]? = nil,
        serverMessageIDsForReconciliation: [IMAPUIDMessageID]? = nil
    ) {
        self.folder = folder
        self.folderAttributes = folderAttributes
        self.uidValidityBefore = uidValidityBefore
        self.uidValidityAfter = uidValidityAfter
        self.highestModSeqBefore = highestModSeqBefore
        self.highestModSeqAfter = highestModSeqAfter
        self.vanishedUIDs = vanishedUIDs
        self.observedAt = observedAt
        self.serverUidSetForReconciliation = serverUidSetForReconciliation
        self.serverMessageIDsForReconciliation = serverMessageIDsForReconciliation
    }
}
