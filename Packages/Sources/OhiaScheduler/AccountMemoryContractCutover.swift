import Foundation
import OhiaCore

public enum LegacyMemoryDisposition: Sendable, Equatable {
    case current
    case quarantine
    case needsReview
    case preserveAsUserCurated
    case preserveTombstone
}

public struct AccountMemoryCutoverReport: Sendable, Equatable {
    public var current = 0
    public var quarantined = 0
    public var needsReview = 0
    public var preservedAsUserCurated = 0
    public var preservedTombstones = 0
}

/// Non-destructive cutover from the claim ledger to durable guidance. Legacy
/// generated rows stay in the store for audit, but only complete material user
/// edits may be promoted into the current promptable contract.
public enum AccountMemoryContractCutover {
    public static func classify(_ memory: AccountMemory) -> LegacyMemoryDisposition {
        if memory.statusRaw == AccountMemoryProjectedStatus.deleted
            || memory.statusRaw == AccountMemoryProjectedStatus.rejected {
            return .preserveTombstone
        }
        if memory.isCurrentContract { return .current }

        if materialEdit(memory.userEditedText) {
            return hasCompleteReusableGuidance(memory)
                ? .preserveAsUserCurated
                : .needsReview
        }
        if memory.statusRaw == AccountMemoryProjectedStatus.affirmed
            || memory.statusRaw == AccountMemoryProjectedStatus.confirmed
            || memory.lastAffirmedAt != nil {
            return .needsReview
        }
        return .quarantine
    }

    @discardableResult
    public static func apply(
        to memories: [AccountMemory],
        now: Date = .now
    ) -> AccountMemoryCutoverReport {
        var report = AccountMemoryCutoverReport()
        for memory in memories {
            switch classify(memory) {
            case .current:
                report.current += 1
            case .quarantine:
                memory.statusRaw = AccountMemoryProjectedStatus.needsReview
                memory.updatedAt = now
                report.quarantined += 1
            case .needsReview:
                memory.statusRaw = AccountMemoryProjectedStatus.needsReview
                memory.updatedAt = now
                report.needsReview += 1
            case .preserveAsUserCurated:
                memory.extractionVersion = AccountMemoryContract.currentVersion
                memory.formationBasisRaw = AccountMemoryFormationBasis.userCurated
                memory.statusRaw = AccountMemoryProjectedStatus.confirmed
                memory.updatedAt = now
                report.preservedAsUserCurated += 1
            case .preserveTombstone:
                report.preservedTombstones += 1
            }
        }
        return report
    }

    private static func materialEdit(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasCompleteReusableGuidance(_ memory: AccountMemory) -> Bool {
        AccountMemoryKind.all.contains(memory.targetKindRaw)
            && AccountMemoryUsePolicy.all.contains(memory.usePolicyRaw ?? "")
            && memory.hasCompleteDurableScope
            && memory.contradictionStateRaw == "clean"
            && memory.supersededByMemoryKey == nil
            && !(memory.futureUseText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}
