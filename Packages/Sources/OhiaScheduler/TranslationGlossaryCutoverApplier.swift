import Foundation
import SwiftData
import OhiaCore

/// One-time migration from directional translation pins to canonical glossary
/// dyads. Translation style rules remain in `AccountMemory`.
@MainActor
public final class TranslationGlossaryCutoverApplier {
    private let modelContext: ModelContext
    private let save: () throws -> Void
    private let rollback: () -> Void

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.save = { try modelContext.save() }
        self.rollback = { modelContext.rollback() }
    }

    convenience init(
        modelContext: ModelContext,
        save: @escaping () throws -> Void
    ) {
        self.init(
            modelContext: modelContext,
            save: save,
            rollback: { modelContext.rollback() }
        )
    }

    init(
        modelContext: ModelContext,
        save: @escaping () throws -> Void,
        rollback: @escaping () -> Void
    ) {
        self.modelContext = modelContext
        self.save = save
        self.rollback = rollback
    }

    /// Migrates every complete user-authoritative legacy pair, removes all
    /// glossary-shaped legacy rows, and saves the resulting state once.
    @discardableResult
    public func run() throws -> Int {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<AccountMemory>())
            let glossaryRows = rows.filter {
                $0.dimensionKind == AccountMemoryDimension.translation
                    && TranslationGlossaryLegacyPinText.isGlossaryShaped($0.displayText)
            }
            guard glossaryRows.isEmpty == false else { return 0 }
            let pins = glossaryRows.compactMap(LegacyPin.init)

            let existingKeys = Set(
                try modelContext.fetch(FetchDescriptor<TranslationGlossaryPair>())
                    .map(\.canonicalKey)
            )
            var migrated = 0
            var insertedKeys = existingKeys

            for selection in selectedPairs(from: pins) where insertedKeys.insert(selection.canonical.canonicalKey).inserted {
                modelContext.insert(TranslationGlossaryPair(
                    canonicalLanguageA: selection.canonical.languageA,
                    canonicalLanguageB: selection.canonical.languageB,
                    termA: selection.canonical.termA,
                    termB: selection.canonical.termB,
                    normalizedTermA: selection.canonical.normalizedTermA,
                    normalizedTermB: selection.canonical.normalizedTermB,
                    canonicalKey: selection.canonical.canonicalKey,
                    statusRaw: selection.status.rawValue,
                    confidence: selection.status == .confirmed ? 1 : 0,
                    createdAt: selection.createdAt,
                    updatedAt: selection.updatedAt,
                    confirmedAt: selection.status == .confirmed ? selection.updatedAt : nil
                ))
                migrated += 1
            }

            for row in glossaryRows { modelContext.delete(row) }
            try save()
            return migrated
        } catch {
            rollback()
            throw error
        }
    }

    private func selectedPairs(from pins: [LegacyPin]) -> [Selection] {
        var candidates: [Selection] = []
        for (offset, lhs) in pins.enumerated() {
            for rhs in pins.dropFirst(offset + 1) where lhs.isReciprocal(of: rhs) {
                if let candidate = Selection(lhs: lhs, rhs: rhs) {
                    candidates.append(candidate)
                }
            }
        }

        // An explicit deletion is authoritative for its exact canonical dyad,
        // even when another account still carries an active copy. Tombstones
        // intentionally do not suppress a different rendering of the source.
        var deletedByCanonicalKey: [String: Selection] = [:]
        for candidate in candidates where candidate.status == .deleted {
            let key = candidate.canonical.canonicalKey
            if let existing = deletedByCanonicalKey[key] {
                if candidate.outranks(existing) { deletedByCanonicalKey[key] = candidate }
            } else {
                deletedByCanonicalKey[key] = candidate
            }
        }

        let tombstonedKeys = Set(deletedByCanonicalKey.keys)
        var confirmedBySource: [String: Selection] = [:]
        for candidate in candidates where candidate.status == .confirmed
            && tombstonedKeys.contains(candidate.canonical.canonicalKey) == false {
            if let existing = confirmedBySource[candidate.conflictKey] {
                if candidate.outranks(existing) { confirmedBySource[candidate.conflictKey] = candidate }
            } else {
                confirmedBySource[candidate.conflictKey] = candidate
            }
        }

        return (Array(deletedByCanonicalKey.values) + Array(confirmedBySource.values))
            .sorted { $0.canonical.canonicalKey < $1.canonical.canonicalKey }
    }
}

private extension TranslationGlossaryCutoverApplier {
    struct LegacyPin {
        let row: AccountMemory
        let sourceTerm: String
        let targetTerm: String
        let targetLanguage: String

        init?(_ row: AccountMemory) {
            guard row.dimensionKind == AccountMemoryDimension.translation,
                  let text = TranslationGlossaryLegacyPinText(row.displayText) else { return nil }
            let targetLanguage = TranslationGlossaryCanonicalizer.baseLanguageCode(row.resolvedDimensionValue)
            guard targetLanguage.isEmpty == false else { return nil }
            self.row = row
            self.sourceTerm = text.sourceTerm
            self.targetTerm = text.targetTerm
            self.targetLanguage = targetLanguage
        }

        var isManual: Bool {
            row.userEditedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || row.extractionVersion.hasPrefix("translation-manual-")
        }

        var affirmedAt: Date { row.lastAffirmedAt ?? row.updatedAt }

        func isReciprocal(of other: LegacyPin) -> Bool {
            targetLanguage != other.targetLanguage
                && TranslationGlossaryCanonicalizer.normalizedIdentityTerm(sourceTerm)
                    == TranslationGlossaryCanonicalizer.normalizedIdentityTerm(other.targetTerm)
                && TranslationGlossaryCanonicalizer.normalizedIdentityTerm(targetTerm)
                    == TranslationGlossaryCanonicalizer.normalizedIdentityTerm(other.sourceTerm)
        }
    }

    struct Selection {
        let canonical: TranslationGlossaryCanonicalPair
        let status: TranslationGlossaryPairStatus
        let manual: Bool
        let updatedAt: Date
        let createdAt: Date
        let conflictKey: String

        init?(lhs: LegacyPin, rhs: LegacyPin) {
            if lhs.row.statusRaw == AccountMemoryProjectedStatus.affirmed,
               rhs.row.statusRaw == AccountMemoryProjectedStatus.affirmed {
                status = .confirmed
            } else if lhs.row.statusRaw == AccountMemoryProjectedStatus.deleted,
                      rhs.row.statusRaw == AccountMemoryProjectedStatus.deleted,
                      lhs.isManual, rhs.isManual {
                status = .deleted
            } else {
                return nil
            }
            canonical = TranslationGlossaryCanonicalizer.canonicalPair(
                language1: rhs.targetLanguage,
                term1: lhs.sourceTerm,
                language2: lhs.targetLanguage,
                term2: lhs.targetTerm
            )
            // Legacy pairs were stored in both directions, so fetch order must
            // not decide which spelling is treated as the conflicting source.
            // Use the lexicographically later canonical language as the stable
            // source side; both directional rows of a legacy mirror converge.
            conflictKey = [
                canonical.languageB,
                canonical.normalizedTermB,
                canonical.languageA,
            ].joined(separator: "\u{1F}")
            manual = lhs.isManual || rhs.isManual
            updatedAt = max(lhs.affirmedAt, rhs.affirmedAt)
            createdAt = min(lhs.row.createdAt, rhs.row.createdAt)
        }

        func outranks(_ other: Selection) -> Bool {
            if manual != other.manual { return manual }
            if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
            if createdAt != other.createdAt { return createdAt < other.createdAt }
            return [canonical.termA, canonical.termB].joined(separator: "\u{1F}")
                < [other.canonical.termA, other.canonical.termB].joined(separator: "\u{1F}")
        }
    }
}
