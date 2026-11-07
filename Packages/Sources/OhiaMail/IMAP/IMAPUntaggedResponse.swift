import Foundation

/// Flattened from `NIOIMAPCore.Response` into what `IMAPSession` dispatches on.
/// Other untagged responses (capability updates mid-session, SEARCH, STATUS)
/// map to `.other` and are ignored — our IDLE loop only cares about the
/// mailbox-changed signals.
public enum IMAPUntaggedResponse: Sendable, Equatable {
    case exists(Int)
    case expunge(UInt32)
    /// An untagged FETCH during IDLE: the server reports a message's flags
    /// changed (read elsewhere, for instance). Its sequence number names a
    /// message in the IDLE mailbox only, so the response itself is discarded.
    case flagsChanged
    case alert(String)
    case bye
    case other
}
