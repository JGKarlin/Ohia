import Foundation

/// Pure decision function for the IMAP gap-check. Decides
/// whether the gap between server EXISTS count and local Message count
/// warrants scheduling an IMAP backfill.
///
/// Threshold: 5% of serverExistsCount, floored at 10 messages. I.e.
/// for small mailboxes (100 messages on server, 95 locally), the 5-
/// message gap is below the floor so we skip. For mature mailboxes
/// (10,000 server, 9,500 local), the 500-message gap exceeds 5% so
/// we schedule backfill.
public enum GapCheckThreshold {
    public static func shouldRunBackfill(
        serverExistsCount: Int,
        localMessageCount: Int
    ) -> Bool {
        guard serverExistsCount > 0 else { return false }
        let gap = serverExistsCount - localMessageCount
        guard gap > 0 else { return false }
        let percentGap = serverExistsCount / 20   // 5%
        let floor = 10
        let threshold = max(percentGap, floor)
        return gap >= threshold
    }
}
