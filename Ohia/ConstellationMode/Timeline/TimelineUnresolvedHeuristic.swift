import Foundation

/// Pure helper that derives `.unresolved` `AIAnnotation` records from a
/// chronological stream of messages grouped by thread. A thread is
/// considered unresolved when its trailing eligible message was received
/// (not sent by the user) and no sent reply followed.
///
/// Extracted from `TimelineDataController.gatherInput` so the logic can be
/// exercised in pure unit tests without an in-memory `ModelContext`.
enum TimelineUnresolvedHeuristic {

    struct ThreadOutstanding: Equatable, Sendable {
        var lastReceivedDate: Date?
        var lastReceivedMessageID: UUID?
        var lastReceivedPurposeState: TimelinePurposeState?
        var sawSentAfterLastReceived: Bool
    }

    /// Fold one message into the per-thread state. The caller must invoke
    /// this in chronological order — see `TimelineDataController.gatherInput`
    /// for the sort that guarantees that property.
    static func update(
        state previous: ThreadOutstanding?,
        messageID: UUID,
        date: Date,
        purposeState: TimelinePurposeState,
        isSentByUser: Bool
    ) -> ThreadOutstanding {
        var entry = previous ?? ThreadOutstanding(
            lastReceivedDate: nil,
            lastReceivedMessageID: nil,
            lastReceivedPurposeState: nil,
            sawSentAfterLastReceived: false
        )
        if isSentByUser {
            if entry.lastReceivedDate != nil {
                entry.sawSentAfterLastReceived = true
            }
        } else {
            if let existing = entry.lastReceivedDate, date <= existing {
                // Older or equal-time received message — ignore so we
                // retain the latest received as the candidate. The
                // caller's sort makes this branch unreachable in
                // practice, but the guard keeps the helper safe under
                // unsorted input too.
            } else {
                entry.lastReceivedDate = date
                entry.lastReceivedMessageID = messageID
                entry.lastReceivedPurposeState = purposeState
                entry.sawSentAfterLastReceived = false
            }
        }
        return entry
    }

    /// Collapse per-thread states into a list of `.unresolved` annotations.
    /// A thread contributes one annotation iff its trailing message was
    /// received and no sent reply followed.
    static func annotations<S: Sequence>(
        from states: S
    ) -> [TimelineLayoutSnapshot.AIAnnotation]
    where S.Element == ThreadOutstanding {
        var result: [TimelineLayoutSnapshot.AIAnnotation] = []
        for state in states {
            guard state.sawSentAfterLastReceived == false,
                  let date = state.lastReceivedDate,
                  let messageID = state.lastReceivedMessageID,
                  let purposeState = state.lastReceivedPurposeState else { continue }
            result.append(
                TimelineLayoutSnapshot.AIAnnotation(
                    kind: .unresolved,
                    messageID: messageID,
                    date: date,
                    purposeState: purposeState
                )
            )
        }
        return result
    }
}
