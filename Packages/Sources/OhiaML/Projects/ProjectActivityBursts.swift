import Foundation

/// A contiguous burst of correspondence activity — the honest Gantt bar.
/// Bursts are observed spans of messages that happened, never planned
/// duration: consecutive messages belong to one burst while the gap between
/// them stays under an adaptive threshold derived from the row's own cadence.
public struct ProjectActivityBurst: Codable, Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let messageCount: Int

    public init(start: Date, end: Date, messageCount: Int) {
        self.start = start
        self.end = max(start, end)
        self.messageCount = max(1, messageCount)
    }
}

public enum ProjectActivityBursts {
    /// Lower clamp keeps one bursty day from shattering into per-message
    /// slivers; upper clamp keeps a monthly cadence from fusing a year of
    /// mail into one solid bar.
    static let minimumGapThreshold: TimeInterval = 2 * 86_400
    static let maximumGapThreshold: TimeInterval = 30 * 86_400

    public static func bursts(for dates: [Date]) -> [ProjectActivityBurst] {
        let sorted = dates.sorted()
        guard let first = sorted.first else { return [] }
        guard sorted.count > 1 else {
            return [ProjectActivityBurst(start: first, end: first, messageCount: 1)]
        }

        let gaps = zip(sorted, sorted.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 }
            .sorted()
        let medianGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let threshold = min(max(medianGap * 2, minimumGapThreshold), maximumGapThreshold)

        var bursts: [ProjectActivityBurst] = []
        var burstStart = first
        var previous = first
        var count = 1
        for date in sorted.dropFirst() {
            if date.timeIntervalSince(previous) > threshold {
                bursts.append(ProjectActivityBurst(start: burstStart, end: previous, messageCount: count))
                burstStart = date
                count = 1
            } else {
                count += 1
            }
            previous = date
        }
        bursts.append(ProjectActivityBurst(start: burstStart, end: previous, messageCount: count))
        return bursts
    }
}
