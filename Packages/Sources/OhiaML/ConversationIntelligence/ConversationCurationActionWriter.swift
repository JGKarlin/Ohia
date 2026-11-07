import Foundation
import SwiftData
import OhiaCore

/// Persists user curation verdicts as `ConversationCurationAction` rows.
/// Mirrors the writer pattern from `ProjectLensActionRepository`: each
/// call resolves existing matching rows, revokes superseded ones, and
/// inserts a fresh row for the new verdict. The data controller bumps
/// its `actionRevision` after every write so the snapshot recomputes.
@MainActor
public struct ConversationCurationActionWriter {
    public let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func write(
        components: CurationKeyComponents,
        action: ConversationCurationAction.ActionValue,
        mergedIntoKey: String? = nil,
        splitChildrenKeys: [String]? = nil,
        noteText: String? = nil,
        now: Date = .now
    ) {
        let active = activeRows(matchingTargetKey: components.targetKey)
        for row in active {
            row.revokedAt = now
        }
        let csv = splitChildrenKeys?.joined(separator: ",")
        let row = ConversationCurationAction(
            targetKey: components.targetKey,
            targetKindRaw: components.targetKind.rawValue,
            normalizedClaimText: components.normalizedClaimText,
            scopeFingerprint: components.scopeFingerprint,
            extractionVersion: components.extractionVersion,
            supportingFingerprint: components.supportingFingerprint,
            actionRawValue: action.rawValue,
            mergedIntoKey: mergedIntoKey,
            splitChildrenKeysCSV: csv,
            noteText: noteText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            appliedAt: now
        )
        modelContext.insert(row)
    }

    public func revoke(targetKey: String, now: Date = .now) {
        for row in activeRows(matchingTargetKey: targetKey) {
            row.revokedAt = now
        }
    }

    public func activeRows() -> [ConversationCurationAction] {
        let rows = (try? modelContext.fetch(FetchDescriptor<ConversationCurationAction>())) ?? []
        return rows.filter(\.isActive)
    }

    private func activeRows(matchingTargetKey key: String) -> [ConversationCurationAction] {
        activeRows().filter { $0.targetKey == key }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
