import Foundation
import OhiaCore

struct ActivityStripOverallProgress: Equatable {
    var ingested: Int
    var interpreted: Int
    var embedded: Int
    var messageDenominator: Int
    var placed: Int
    var placementTotal: Int

    var fraction: Double {
        var fractions: [Double] = []

        if messageDenominator > 0 {
            fractions.append(Self.fraction(ingested, denominator: messageDenominator))
            fractions.append(Self.fraction(interpreted, denominator: messageDenominator))
            fractions.append(Self.fraction(embedded, denominator: messageDenominator))
        }

        if placementTotal > 0 {
            fractions.append(Self.fraction(placed, denominator: placementTotal))
        }

        return fractions.min() ?? 0
    }

    static func messageDenominator(messageTotal: Int, targetTotal: Int) -> Int {
        if targetTotal > 0 {
            return max(messageTotal, targetTotal)
        }
        return max(0, messageTotal)
    }

    private static func fraction(_ count: Int, denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        let clamped = min(max(count, 0), denominator)
        return Double(clamped) / Double(denominator)
    }

    /// Tempo-gauge percent text: show `100` only when the bottleneck count has
    /// reached its denominator; otherwise floor to an integer capped at `99`.
    static func tempoDisplayPercent(fraction: Double, isBottleneckComplete: Bool) -> Int {
        guard isBottleneckComplete else {
            return min(99, Int(floor(fraction * 100)))
        }
        return 100
    }
}

struct ActivityStripSummaryProgress: Equatable {
    var messageSummaries: Int
    var messageTotal: Int
    var attachmentSummaries: Int
    var attachmentTotal: Int

    var completed: Int {
        clamped(messageSummaries, denominator: messageTotal)
            + clamped(attachmentSummaries, denominator: attachmentTotal)
    }

    var messageCompleted: Int {
        clamped(messageSummaries, denominator: messageTotal)
    }

    var messageSummariesAreComplete: Bool {
        let total = max(0, messageTotal)
        return total > 0 && messageCompleted >= total
    }

    var total: Int {
        max(0, messageTotal) + max(0, attachmentTotal)
    }

    var hasAttachmentBacklog: Bool {
        attachmentTotal > 0 && clamped(attachmentSummaries, denominator: attachmentTotal) < attachmentTotal
    }

    var isComplete: Bool {
        total > 0 && completed >= total
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    private func clamped(_ count: Int, denominator: Int) -> Int {
        let denominator = max(0, denominator)
        return min(max(count, 0), denominator)
    }
}

nonisolated struct ActivityStripMemoryRefreshStateSnapshot: Equatable, Sendable {
    var statusRaw: String
    var cursorProcessedMessageCount: Int
    var lastEligibleMessageCount: Int
    var backfillCompleted: Bool
    /// The account whose memories this row is distilling. Dreaming runs
    /// per-account, so the flow indicator tints its electrons with this
    /// account's colour while the "dreaming" readout is showing.
    var accountID: UUID?
}

struct ActivityStripMemoryRefreshProgress: Equatable {
    var states: [ActivityStripMemoryRefreshStateSnapshot]

    var isRunning: Bool {
        states.contains { $0.statusRaw == AccountMemoryRefreshStatus.running }
    }

    /// The account of the dreaming row that is actually running. Nil when no
    /// row is running or the running row has no account recorded.
    ///
    /// Sorted by account id before picking, so that when more than one account
    /// is dreaming the chosen one — and therefore the flow indicator's tint —
    /// is stable across refreshes instead of following store row order. Mirrors
    /// the same guarantee `imapSessionStatusReadout` makes.
    var runningAccountID: UUID? {
        states
            .filter { $0.statusRaw == AccountMemoryRefreshStatus.running }
            .compactMap(\.accountID)
            .min { $0.uuidString < $1.uuidString }
    }

    var backfillingStates: [ActivityStripMemoryRefreshStateSnapshot] {
        states.filter { !$0.backfillCompleted }
    }

    var backfillCompleted: Bool {
        backfillingStates.isEmpty
    }

    var processedBackfillMessages: Int {
        backfillingStates.reduce(0) { partial, state in
            partial + max(0, state.cursorProcessedMessageCount)
        }
    }

    var eligibleBackfillMessages: Int {
        backfillingStates.reduce(0) { partial, state in
            partial + max(0, state.lastEligibleMessageCount)
        }
    }

    var bottleneckComplete: Bool {
        eligibleBackfillMessages > 0
            && processedBackfillMessages >= eligibleBackfillMessages
    }
}
