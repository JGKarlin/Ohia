import Foundation

/// A Sendable, account-scoped view of the durable initial-IMAP-import work
/// snapshots. Callers provide value entries rather than SwiftData models so
/// model instances and contexts never cross actor boundaries.
public struct InitialIMAPImportProgress: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let accountID: UUID
        public let isRequiredCorpusFolder: Bool
        public let totalWork: Int?
        public let remainingWork: Int?
        public let terminalExclusionReason: String?

        public init(
            accountID: UUID,
            isRequiredCorpusFolder: Bool,
            totalWork: Int?,
            remainingWork: Int?,
            terminalExclusionReason: String?
        ) {
            self.accountID = accountID
            self.isRequiredCorpusFolder = isRequiredCorpusFolder
            self.totalWork = totalWork
            self.remainingWork = remainingWork
            self.terminalExclusionReason = terminalExclusionReason
        }
    }

    public let totalWork: Int
    public let completedWork: Int
    public let remainingWork: Int
    public let completionAuthority: Bool

    public static func reduce(
        for accountID: UUID,
        entries: some Sequence<Entry>
    ) -> Self {
        let requiredEntries = entries.filter {
            $0.accountID == accountID && $0.isRequiredCorpusFolder
        }

        guard !requiredEntries.isEmpty else {
            return Self(
                totalWork: 0,
                completedWork: 0,
                remainingWork: 0,
                completionAuthority: false
            )
        }

        var totalWork = 0
        var remainingWork = 0
        var completionAuthority = true

        for entry in requiredEntries {
            let hasTerminalExclusion = entry.terminalExclusionReason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false

            guard let rawTotal = entry.totalWork,
                  let rawRemaining = entry.remainingWork else {
                completionAuthority = completionAuthority && hasTerminalExclusion
                continue
            }

            let total = max(0, rawTotal)
            let remaining = min(max(0, rawRemaining), total)
            totalWork = saturatedAdd(totalWork, total)
            remainingWork = saturatedAdd(remainingWork, remaining)
            completionAuthority = completionAuthority && (remaining == 0 || hasTerminalExclusion)
        }

        let completedWork = totalWork - remainingWork
        return Self(
            totalWork: totalWork,
            completedWork: completedWork,
            remainingWork: remainingWork,
            completionAuthority: completionAuthority
        )
    }

    private init(
        totalWork: Int,
        completedWork: Int,
        remainingWork: Int,
        completionAuthority: Bool
    ) {
        self.totalWork = totalWork
        self.completedWork = completedWork
        self.remainingWork = remainingWork
        self.completionAuthority = completionAuthority
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}
