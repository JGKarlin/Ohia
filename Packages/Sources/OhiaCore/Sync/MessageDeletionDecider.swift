import Foundation

/// Value-only input for deletion-sync decision logic.
public struct MessageDeletionDeciderInput: Sendable {
    public let accountID: UUID
    public let folder: String
    public let folderRole: IMAPFolderRole
    public let isGmailAccount: Bool
    public let uidValidityBefore: UInt32?
    public let uidValidityAfter: UInt32
    public let highestModSeqBefore: UInt64?
    public let vanishedUIDs: [UInt32]
    public let knownLocalMessages: [(messageID: UUID, uid: UInt32, messageIdHeader: String?)]
    /// `messageIdHeader` → count of `Message` rows in this account that
    /// share that header. Pre-computed by the coordinator from a single
    /// SwiftData fetch. Used only by the non-Gmail branch.
    public let accountMessageIdCounts: [String: Int]
    public let nonGmailGracePeriodSeconds: TimeInterval

    public init(
        accountID: UUID,
        folder: String,
        folderRole: IMAPFolderRole,
        isGmailAccount: Bool,
        uidValidityBefore: UInt32?,
        uidValidityAfter: UInt32,
        highestModSeqBefore: UInt64?,
        vanishedUIDs: [UInt32],
        knownLocalMessages: [(messageID: UUID, uid: UInt32, messageIdHeader: String?)],
        accountMessageIdCounts: [String: Int],
        nonGmailGracePeriodSeconds: TimeInterval = DeletionSyncPreferences.defaultNonGmailGracePeriodSeconds
    ) {
        self.accountID = accountID
        self.folder = folder
        self.folderRole = folderRole
        self.isGmailAccount = isGmailAccount
        self.uidValidityBefore = uidValidityBefore
        self.uidValidityAfter = uidValidityAfter
        self.highestModSeqBefore = highestModSeqBefore
        self.vanishedUIDs = vanishedUIDs
        self.knownLocalMessages = knownLocalMessages
        self.accountMessageIdCounts = accountMessageIdCounts
        self.nonGmailGracePeriodSeconds = nonGmailGracePeriodSeconds
    }
}

/// Convert raw SELECT-time IMAP signals into safe deletion actions.
///
/// Check order: first-sync guard → UIDVALIDITY mismatch → Gmail vs.
/// non-Gmail branch. The first-sync guard comes first so a
/// UIDVALIDITY change on a never-before-synced folder always returns
/// `.skipFirstSync` rather than `.skipUidValidityChanged` (the old
/// cursor is absent, so there is nothing to invalidate).
///
/// - Parameters:
///   - input: The decider input with all sync signals.
///   - now: The reference time for grace-period calculation. Defaults to `Date()`.
///          Exposed as a parameter so callers (primarily tests) can pass a fixed
///          instant and keep the function deterministic.
public func decideMessageDeletions(_ input: MessageDeletionDeciderInput, now: Date = Date()) -> [MessageDeletionDecision] {
    if input.highestModSeqBefore == nil {
        return [.skipFirstSync(folder: input.folder)]
    }
    if let before = input.uidValidityBefore, before != input.uidValidityAfter {
        return [.skipUidValidityChanged(
            folder: input.folder,
            oldValidity: before,
            newValidity: input.uidValidityAfter
        )]
    }
    if input.isGmailAccount {
        if input.folderRole != .gmailAll {
            return input.vanishedUIDs.map { .skipNonAllFolder(folder: input.folder, uid: $0) }
        }
        return matchVanishedToGmailDeletes(input)
    }
    return decideNonGmail(input, now: now)
}

private func matchVanishedToGmailDeletes(_ input: MessageDeletionDeciderInput) -> [MessageDeletionDecision] {
    var byUID: [UInt32: UUID] = [:]
    byUID.reserveCapacity(input.knownLocalMessages.count)
    for entry in input.knownLocalMessages {
        byUID[entry.uid] = entry.messageID
    }
    var out: [MessageDeletionDecision] = []
    out.reserveCapacity(input.vanishedUIDs.count)
    for uid in input.vanishedUIDs {
        guard let mid = byUID[uid] else { continue }
        out.append(.delete(
            messageID: mid, accountID: input.accountID,
            folder: input.folder, uid: uid
        ))
    }
    return out
}

private func decideNonGmail(_ input: MessageDeletionDeciderInput, now: Date) -> [MessageDeletionDecision] {
    var byUID: [UInt32: (messageID: UUID, messageIdHeader: String?)] = [:]
    byUID.reserveCapacity(input.knownLocalMessages.count)
    for entry in input.knownLocalMessages {
        byUID[entry.uid] = (entry.messageID, entry.messageIdHeader)
    }
    var out: [MessageDeletionDecision] = []
    out.reserveCapacity(input.vanishedUIDs.count)
    let gracePeriod = max(0, input.nonGmailGracePeriodSeconds)
    let deferUntil = now.addingTimeInterval(gracePeriod)
    for uid in input.vanishedUIDs {
        guard let local = byUID[uid] else { continue }
        let count: Int
        if let header = local.messageIdHeader {
            let normalized = normalizeMessageIDHeader(header)
            count = normalized.flatMap { input.accountMessageIdCounts[$0] }
                ?? input.accountMessageIdCounts[header]
                ?? 0
        } else {
            count = 0
        }
        if count > 1 {
            out.append(.skipMoveDetected(
                folder: input.folder, uid: uid,
                messageIdHeader: local.messageIdHeader
            ))
        } else if gracePeriod == 0 {
            out.append(.delete(
                messageID: local.messageID,
                accountID: input.accountID,
                folder: input.folder,
                uid: uid
            ))
        } else {
            out.append(.deferToGracePeriod(
                messageID: local.messageID,
                accountID: input.accountID,
                folder: input.folder,
                uid: uid,
                messageIdHeader: local.messageIdHeader,
                deferUntil: deferUntil
            ))
        }
    }
    return out
}
