import Foundation
import OhiaCore

public enum AccountMemoryRefreshEligibility {
    public static let minimumInterval: TimeInterval = 24 * 60 * 60
    public static let deferredResumeDelay: TimeInterval = 60
    public static let sentMessageThreshold = 20
    public static let receivedMessageThreshold = 50
    public static let combinedMessageThreshold = 60

    public static func triggerReason(
        state: AccountMemoryRefreshState?,
        counts: AccountMemoryMessageCounts,
        now: Date = .now
    ) -> String? {
        guard counts.eligibleMessages > 0 else { return nil }

        if let state,
           state.lastStatusRaw == AccountMemoryRefreshStatus.deferred,
           let completedAt = state.lastRunCompletedAt,
           now.timeIntervalSince(completedAt) < deferredResumeDelay {
            return nil
        }

        if let state,
           state.cursorDate != nil || state.cursorMessageID != nil || state.cursorProcessedMessageCount > 0 {
            return "resume"
        }

        guard let state, let lastSuccess = state.lastSuccessfulRunAt else {
            return "firstRun"
        }

        let eligibleDelta = max(0, counts.eligibleMessages - state.lastEligibleMessageCount)
        let sentDelta = max(0, counts.sentMessages - state.lastSentMessageCount)
        let receivedDelta = max(0, counts.receivedMessages - state.lastReceivedMessageCount)
        let combinedDelta = sentDelta + receivedDelta

        if sentDelta >= sentMessageThreshold {
            return "sentDelta:\(sentDelta)"
        }
        if receivedDelta >= receivedMessageThreshold {
            return "receivedDelta:\(receivedDelta)"
        }
        if combinedDelta >= combinedMessageThreshold {
            return "combinedDelta:\(combinedDelta)"
        }
        if now.timeIntervalSince(lastSuccess) >= minimumInterval, eligibleDelta > 0 {
            return "dailyWithNewMail:\(eligibleDelta)"
        }
        return nil
    }
}
