import Foundation

/// One deletion-sync decision. The applier consumes these values and performs
/// side effects only for `.delete`; skip cases remain auditable no-ops.
public enum MessageDeletionDecision: Sendable, Equatable {
    case delete(messageID: UUID, accountID: UUID, folder: String, uid: UInt32)
    case skipUidValidityChanged(folder: String, oldValidity: UInt32, newValidity: UInt32)
    case skipNonAllFolder(folder: String, uid: UInt32)
    case skipFirstSync(folder: String)
    /// Non-Gmail account: the candidate's Message-ID exists in another
    /// tracked folder for the same account. Treated as a move; no
    /// cascade. The `Message` row for the source folder may become a
    /// stale pointer — see spec §7 for the known imperfection.
    case skipMoveDetected(folder: String, uid: UInt32, messageIdHeader: String?)
    /// Non-Gmail account: the candidate's Message-ID is unique in this
    /// account. Defer the cascade decision until `deferUntil`; the
    /// reaper re-evaluates at expiry and either cascades (still gone)
    /// or drops (match arrived during grace).
    case deferToGracePeriod(
        messageID: UUID, accountID: UUID, folder: String, uid: UInt32,
        messageIdHeader: String?, deferUntil: Date
    )
}
