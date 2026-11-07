import Foundation

public enum HistoryIngestionWindowPolicy {
    public static func accepts(date: Date?, lowerBound: Date?) -> Bool {
        guard let lowerBound else { return true }
        guard let date else { return false }
        return date >= lowerBound
    }

    public static func isWidening(oldLowerBound: Date?, newLowerBound: Date?) -> Bool {
        switch (oldLowerBound, newLowerBound) {
        case (.none, _):
            return false
        case (.some, .none):
            return true
        case let (.some(old), .some(new)):
            return new < old
        }
    }
}

public extension Account {
    func acceptsExistingMessageIngestionWindow(receivedAt: Date?, sentAt: Date?) -> Bool {
        HistoryIngestionWindowPolicy.accepts(
            date: receivedAt ?? sentAt,
            lowerBound: ingestionLowerBoundAt
        )
    }

    @MainActor
    func applyHistoryIngestionWindow(
        lowerBound: Date?,
        presetRaw: String?,
        now: Date = Date()
    ) {
        if imapFolderStates.isEmpty {
            ingestionLowerBoundAt = lowerBound
            ingestionWindowPresetRaw = presetRaw
            return
        }

        let oldLowerBound = ingestionLowerBoundAt
        guard oldLowerBound != lowerBound else { return }

        guard HistoryIngestionWindowPolicy.isWidening(
            oldLowerBound: oldLowerBound,
            newLowerBound: lowerBound
        ) else {
            return
        }

        ingestionLowerBoundAt = lowerBound
        ingestionWindowPresetRaw = presetRaw

        for state in imapFolderStates {
            state.backfillComplete = false
            state.backfillLowerBoundAt = lowerBound
            state.inScopeMessageCountAtLastSelect = nil
            state.updatedAt = now
        }
    }
}
