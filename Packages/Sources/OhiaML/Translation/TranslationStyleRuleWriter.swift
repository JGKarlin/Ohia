import Foundation
import SwiftData
import OhiaCore

/// The exclusive persistence boundary for free-form, account-scoped
/// translation style rules. Glossary-shaped text is deliberately rejected.
public enum TranslationStyleRuleWriter {
    public static let extractionVersion = "translation-style-rule-v1"

    public static func isGlossaryShaped(_ text: String) -> Bool {
        TranslationGlossaryLegacyPinText.isGlossaryShaped(text)
    }

    @MainActor
    @discardableResult
    public static func apply(
        ops: [MemoryDistiller.Operation],
        existing: [AccountMemory],
        accountID: UUID,
        target: AccountMemoryDimensionTarget,
        evidence: [AccountMemoryEvidenceReference],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Int {
        do {
            var changed = 0
            for op in ops {
                switch op.op {
                case "add":
                    guard op.kind == nil || op.kind == ConversationCurationAction.TargetKind.tacitRule.rawValue,
                          let text = op.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          text.isEmpty == false,
                          !isGlossaryShaped(text) else { continue }
                    let normalized = ConversationCurationKey.normalize(text: text)
                    guard normalized.isEmpty == false else { continue }
                    let rows = try styleRows(accountID: accountID, target: target.value, modelContext: modelContext)
                    if let same = rows.first(where: { $0.normalizedText == normalized }) {
                        guard !same.isHiddenByDefault else { continue }
                        same.lastSeenAt = max(same.lastSeenAt, now)
                        same.updatedAt = now
                    } else {
                        let memory = AccountMemory(
                            accountID: accountID,
                            memoryKey: ConversationCurationKey.make(
                                text: text, kind: .tacitRule, scope: [],
                                extractionVersion: extractionVersion,
                                supportingMessageContentHashes: []
                            ).targetKey,
                            targetKindRaw: ConversationCurationAction.TargetKind.tacitRule.rawValue,
                            dimensionKindRaw: AccountMemoryDimension.translation,
                            dimensionValue: target.value,
                            dimensionDisplayName: target.displayName,
                            normalizedText: normalized,
                            generatedText: text,
                            weight: 0.4,
                            extractionConfidence: evidence.map(\.confidence).max() ?? 0.5,
                            evidenceStrength: min(1, Double(evidence.count) / 3),
                            scopeJSON: "[]",
                            evidenceJSON: AccountMemory.encodeEvidence(evidence),
                            extractionVersion: extractionVersion,
                            createdAt: now,
                            updatedAt: now
                        )
                        modelContext.insert(memory)
                    }
                    changed += 1
                case "reinforce":
                    guard let memory = existing[safe: op.memory], isStyleRule(memory) else { continue }
                    memory.lastSeenAt = max(memory.lastSeenAt, now)
                    memory.updatedAt = now
                    changed += 1
                case "weaken":
                    guard let memory = existing[safe: op.memory], isStyleRule(memory) else { continue }
                    memory.statusRaw = AccountMemoryProjectedStatus.weakened
                    memory.weight = max(0, memory.weight / 2)
                    memory.updatedAt = now
                    changed += 1
                case "delete":
                    guard let memory = existing[safe: op.memory], isStyleRule(memory) else { continue }
                    modelContext.delete(memory)
                    changed += 1
                default:
                    continue
                }
            }
            if changed > 0 { try modelContext.save() }
            return changed
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public static func isStyleRule(_ memory: AccountMemory) -> Bool {
        memory.dimensionKind == AccountMemoryDimension.translation
            && memory.targetKindRaw == ConversationCurationAction.TargetKind.tacitRule.rawValue
            && !isGlossaryShaped(memory.displayText)
    }

    private static func styleRows(
        accountID: UUID,
        target: String,
        modelContext: ModelContext
    ) throws -> [AccountMemory] {
        try modelContext.fetch(FetchDescriptor<AccountMemory>(predicate: #Predicate { $0.accountID == accountID }))
            .filter { $0.resolvedDimensionValue == target && isStyleRule($0) }
    }
}

private extension Array {
    subscript(safe oneBasedIndex: Int?) -> Element? {
        guard let oneBasedIndex, oneBasedIndex > 0, oneBasedIndex <= count else { return nil }
        return self[oneBasedIndex - 1]
    }
}
