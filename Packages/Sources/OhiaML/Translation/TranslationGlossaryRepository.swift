import Foundation
import SwiftData
import OhiaCore

public enum TranslationGlossaryRepositoryError: Error, Sendable, Equatable {
    case invalidObservation(TranslationGlossaryCandidateRejection)
    case pairNotFound(UUID)
}

/// The sole persistence boundary for canonical translation dyads and their
/// authored evidence. Callers provide observations; this repository validates,
/// reconciles, and commits each resulting state atomically.
@MainActor
public final class TranslationGlossaryRepository {
    private let modelContext: ModelContext
    private let beforeSave: () throws -> Void

    public init(modelContext: ModelContext, beforeSave: @escaping () throws -> Void = {}) {
        self.modelContext = modelContext
        self.beforeSave = beforeSave
    }

    public func apply(_ observation: TranslationGlossaryObservation) throws {
        try applyBatch([observation], reconciledAt: observation.observedAt, afterReconciliation: {})
    }

    /// Applies every observation belonging to one source and its completion
    /// stamp in one save/rollback boundary. Validation happens before any
    /// mutation, so an invalid later observation cannot leave an earlier pair
    /// or evidence row visible. The caller's stamp closure runs only after
    /// pair reconciliation has succeeded, immediately before the one save.
    public func applyBatch(
        _ observations: [TranslationGlossaryObservation],
        reconciledAt: Date,
        afterReconciliation: () throws -> Void
    ) throws {
        let validated: [TranslationGlossaryObservation] = try observations.map { observation in
            switch TranslationGlossaryCandidateValidator.validate(observation) {
            case let .success(value): return value
            case let .failure(rejection): throw TranslationGlossaryRepositoryError.invalidObservation(rejection)
            }
        }
        let deduplicated = Dictionary(grouping: validated, by: \.evidenceKey)
            .values
            .compactMap { group in
                group.sorted(by: Self.preferredDuplicate).first
            }
            .sorted { $0.evidenceKey < $1.evidenceKey }
        try transaction {
            for observation in deduplicated {
                _ = try applyValidated(observation)
            }
            if deduplicated.isEmpty == false {
                try reconcileAll(now: reconciledAt)
            }
            try afterReconciliation()
            return true
        }
    }

    public func reconcile(now: Date) throws {
        try transaction {
            try reconcileAll(now: now)
            return true
        }
    }

    /// Founds provisional pairs from the local model's renderings of terms it
    /// left untranslated. A rendering is inserted only when no live pair
    /// already claims either term and no tombstone holds the same pair, so it
    /// never overrides the user's curation or authored evidence and never
    /// accrues weight from repetition. Returns the number of pairs founded.
    @discardableResult
    public func insertModelRenderings(
        _ observations: [TranslationGlossaryObservation],
        now: Date
    ) throws -> Int {
        let validated = observations.compactMap { observation -> TranslationGlossaryObservation? in
            guard observation.kind == .modelRendering,
                  case let .success(value) = TranslationGlossaryCandidateValidator.validate(observation) else {
                return nil
            }
            return value
        }
        guard validated.isEmpty == false else { return 0 }
        var inserted = 0
        try transaction {
            var rows = try allPairs()
            var evidenceKeys = Set(try modelContext.fetch(FetchDescriptor<TranslationGlossaryEvidence>()).map(\.evidenceKey))
            for observation in validated {
                let canonical = canonicalPair(for: observation)
                guard rows.contains(where: { $0.canonicalKey == canonical.canonicalKey }) == false,
                      rows.contains(where: { isActive($0) && conflictsWithSource($0, candidate: canonical) }) == false,
                      evidenceKeys.insert(observation.evidenceKey).inserted else {
                    continue
                }
                let pair = makePair(canonical, now: now)
                pair.lastEvidenceAt = observation.observedAt
                modelContext.insert(pair)
                modelContext.insert(makeEvidence(observation: observation, pairID: pair.id))
                pair.confidence = TranslationGlossaryPolicy.confidence(
                    supporting: [observation.strength],
                    contradicting: []
                )
                rows.append(pair)
                inserted += 1
            }
            return inserted > 0
        }
        return inserted
    }

    public func addConfirmed(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        now: Date
    ) throws {
        let canonical = try validatedManualCanonical(
            language1: language1, term1: term1, language2: language2, term2: term2, now: now
        )
        try transaction {
            let existing = try allPairs().first { $0.canonicalKey == canonical.canonicalKey }
            let pair = existing ?? makePair(canonical, now: now)
            if existing == nil { modelContext.insert(pair) }
            try tombstoneActiveConflicts(with: canonical, except: pair.id, now: now)
            install(canonical, on: pair)
            pair.statusRaw = TranslationGlossaryPairStatus.confirmed.rawValue
            pair.confidence = 1
            pair.confirmedAt = now
            pair.updatedAt = now
            pair.lastEvidenceAt = now
            try insertManualEvidence(for: pair, canonical: canonical, now: now)
            return true
        }
    }

    public func confirm(pairID: UUID, now: Date) throws {
        try transaction {
            guard let pair = try allPairs().first(where: { $0.id == pairID }) else {
                throw TranslationGlossaryRepositoryError.pairNotFound(pairID)
            }
            let canonical = TranslationGlossaryCanonicalizer.canonicalPair(
                language1: pair.canonicalLanguageA, term1: pair.termA,
                language2: pair.canonicalLanguageB, term2: pair.termB
            )
            try tombstoneActiveConflicts(with: canonical, except: pair.id, now: now)
            pair.statusRaw = TranslationGlossaryPairStatus.confirmed.rawValue
            pair.confirmedAt = now
            pair.updatedAt = now
            return true
        }
    }

    public func edit(
        pairID: UUID,
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        now: Date
    ) throws {
        let replacement = try validatedManualCanonical(
            language1: language1, term1: term1, language2: language2, term2: term2, now: now
        )
        try transaction {
            guard let prior = try allPairs().first(where: { $0.id == pairID }) else {
                throw TranslationGlossaryRepositoryError.pairNotFound(pairID)
            }
            guard prior.canonicalKey != replacement.canonicalKey else {
                try tombstoneActiveConflicts(with: replacement, except: prior.id, now: now)
                install(replacement, on: prior)
                prior.statusRaw = TranslationGlossaryPairStatus.confirmed.rawValue
                prior.confidence = 1
                prior.confirmedAt = now
                prior.updatedAt = now
                insertManualEditEvidence(for: prior, canonical: replacement, now: now)
                return true
            }
            prior.statusRaw = TranslationGlossaryPairStatus.deleted.rawValue
            prior.updatedAt = now

            let existing = try allPairs().first { $0.canonicalKey == replacement.canonicalKey }
            let pair = existing ?? makePair(replacement, now: now)
            if existing == nil { modelContext.insert(pair) }
            try tombstoneActiveConflicts(with: replacement, except: pair.id, now: now)
            install(replacement, on: pair)
            pair.statusRaw = TranslationGlossaryPairStatus.confirmed.rawValue
            pair.confidence = 1
            pair.confirmedAt = now
            pair.updatedAt = now
            pair.lastEvidenceAt = now
            insertManualEditEvidence(for: pair, canonical: replacement, now: now)
            return true
        }
    }

    public func delete(pairID: UUID, now: Date) throws {
        try transaction {
            guard let pair = try allPairs().first(where: { $0.id == pairID }) else {
                throw TranslationGlossaryRepositoryError.pairNotFound(pairID)
            }
            pair.statusRaw = TranslationGlossaryPairStatus.deleted.rawValue
            pair.updatedAt = now
            return true
        }
    }

    private func transaction(_ body: () throws -> Bool) throws {
        do {
            if try body() {
                try beforeSave()
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func applyValidated(_ canonicalObservation: TranslationGlossaryObservation) throws -> Bool {
        guard try existingEvidence(key: canonicalObservation.evidenceKey) == nil else { return false }
        let canonical = canonicalPair(for: canonicalObservation)
        let rows = try allPairs()
        if rows.contains(where: {
            $0.canonicalKey == canonical.canonicalKey
                && $0.statusRaw == TranslationGlossaryPairStatus.deleted.rawValue
        }) {
            return false
        }
        let activeExact = rows.first { $0.canonicalKey == canonical.canonicalKey && isActive($0) }
        let sourceConflict = rows.first { isActive($0) && conflictsWithSource($0, candidate: canonical) }
        if canonicalObservation.kind == .modelRendering, activeExact != nil || sourceConflict != nil {
            return false
        }
        guard activeExact != nil || sourceConflict != nil
                || canonicalObservation.strength >= TranslationGlossaryPolicy.provisionalThreshold else {
            return false
        }
        let pair = activeExact ?? sourceConflict ?? makePair(canonical, now: canonicalObservation.observedAt)
        if activeExact == nil, sourceConflict == nil { modelContext.insert(pair) }
        modelContext.insert(makeEvidence(observation: canonicalObservation, pairID: pair.id))
        if pair.statusRaw != TranslationGlossaryPairStatus.confirmed.rawValue {
            try reconcile(pair: pair, candidate: canonical)
        } else {
            try reclassifyEvidence(for: pair)
            try recomputeConfidence(for: pair)
            pair.updatedAt = max(pair.updatedAt, canonicalObservation.observedAt)
            pair.lastEvidenceAt = max(pair.lastEvidenceAt ?? .distantPast, canonicalObservation.observedAt)
        }
        return true
    }

    private func reconcileAll(now: Date) throws {
        for pair in try allPairs() where pair.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue {
            let priorConfidence = pair.confidence
            let priorPolarities = Dictionary(uniqueKeysWithValues: try evidence(for: pair.id).map { ($0.id, $0.polarityRaw) })
            try reclassifyEvidence(for: pair)
            try recomputeConfidence(for: pair)
            let polaritiesChanged = try evidence(for: pair.id).contains { priorPolarities[$0.id] != $0.polarityRaw }
            if priorConfidence != pair.confidence || polaritiesChanged {
                pair.updatedAt = max(pair.updatedAt, now)
            }
            if TranslationGlossaryPolicy.shouldRetire(status: status(of: pair), confidence: pair.confidence) {
                for evidence in try evidence(for: pair.id) { modelContext.delete(evidence) }
                modelContext.delete(pair)
            }
        }
    }

    private func allPairs() throws -> [TranslationGlossaryPair] {
        try modelContext.fetch(FetchDescriptor<TranslationGlossaryPair>())
    }

    private func evidence(for pairID: UUID) throws -> [TranslationGlossaryEvidence] {
        try modelContext.fetch(FetchDescriptor<TranslationGlossaryEvidence>()).filter { $0.pairID == pairID }
    }

    private func existingEvidence(key: String) throws -> TranslationGlossaryEvidence? {
        try modelContext.fetch(FetchDescriptor<TranslationGlossaryEvidence>()).first { $0.evidenceKey == key }
    }

    private func canonicalPair(for observation: TranslationGlossaryObservation) -> TranslationGlossaryCanonicalPair {
        TranslationGlossaryCanonicalizer.canonicalPair(
            language1: observation.language1,
            term1: observation.term1,
            language2: observation.language2,
            term2: observation.term2
        )
    }

    private func validatedManualCanonical(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        now: Date
    ) throws -> TranslationGlossaryCanonicalPair {
        let observation = TranslationGlossaryObservation(
            evidenceKey: "manual-validation",
            kind: .manual,
            language1: language1,
            term1: term1,
            language2: language2,
            term2: term2,
            authoredSurfaces: ["\(term1) / \(term2)"],
            sourceMessageID: nil,
            sourceDraftID: nil,
            sourceAccountID: nil,
            sourceAuthorAddress: nil,
            excerpt: nil,
            observedAt: now,
            strength: TranslationGlossaryPolicy.manualStrength
        )
        switch TranslationGlossaryCandidateValidator.validate(observation) {
        case let .success(validated):
            return canonicalPair(for: validated)
        case let .failure(rejection):
            throw TranslationGlossaryRepositoryError.invalidObservation(rejection)
        }
    }

    private func makePair(_ canonical: TranslationGlossaryCanonicalPair, now: Date) -> TranslationGlossaryPair {
        TranslationGlossaryPair(
            canonicalLanguageA: canonical.languageA,
            canonicalLanguageB: canonical.languageB,
            termA: canonical.termA,
            termB: canonical.termB,
            normalizedTermA: canonical.normalizedTermA,
            normalizedTermB: canonical.normalizedTermB,
            canonicalKey: canonical.canonicalKey,
            createdAt: now,
            updatedAt: now
        )
    }

    private func insertManualEvidence(
        for pair: TranslationGlossaryPair,
        canonical: TranslationGlossaryCanonicalPair,
        now: Date
    ) throws {
        let evidenceKey = "manual:\(canonical.canonicalKey)"
        guard try existingEvidence(key: evidenceKey) == nil else { return }
        modelContext.insert(TranslationGlossaryEvidence(
            pairID: pair.id,
            evidenceKey: evidenceKey,
            kindRaw: TranslationGlossaryEvidenceKind.manual.rawValue,
            polarityRaw: TranslationGlossaryEvidencePolarity.supporting.rawValue,
            observedTermA: canonical.termA,
            observedTermB: canonical.termB,
            observedAt: now,
            strength: TranslationGlossaryPolicy.manualStrength
        ))
    }

    private func insertManualEditEvidence(
        for pair: TranslationGlossaryPair,
        canonical: TranslationGlossaryCanonicalPair,
        now: Date
    ) {
        modelContext.insert(TranslationGlossaryEvidence(
            pairID: pair.id,
            evidenceKey: "manual-edit:\(UUID().uuidString.lowercased())",
            kindRaw: TranslationGlossaryEvidenceKind.manual.rawValue,
            polarityRaw: TranslationGlossaryEvidencePolarity.supporting.rawValue,
            observedTermA: canonical.termA,
            observedTermB: canonical.termB,
            observedAt: now,
            strength: TranslationGlossaryPolicy.manualStrength
        ))
    }

    private func makeEvidence(
        observation: TranslationGlossaryObservation,
        pairID: UUID
    ) -> TranslationGlossaryEvidence {
        TranslationGlossaryEvidence(
            pairID: pairID,
            evidenceKey: observation.evidenceKey,
            kindRaw: observation.kind.rawValue,
            polarityRaw: TranslationGlossaryEvidencePolarity.supporting.rawValue,
            observedTermA: observation.term1,
            observedTermB: observation.term2,
            sourceMessageID: observation.sourceMessageID,
            sourceDraftID: observation.sourceDraftID,
            sourceAccountID: observation.sourceAccountID,
            sourceAuthorAddress: observation.sourceAuthorAddress,
            excerpt: observation.excerpt,
            observedAt: observation.observedAt,
            strength: observation.strength
        )
    }

    private func reconcile(
        pair: TranslationGlossaryPair,
        candidate: TranslationGlossaryCanonicalPair
    ) throws {
        let conflictOnA = pair.canonicalLanguageA == candidate.languageA
            && pair.normalizedTermA == candidate.normalizedTermA
        let sourceLanguage = conflictOnA ? pair.canonicalLanguageA : pair.canonicalLanguageB
        let sourceTerm = conflictOnA ? pair.termA : pair.termB
        let targetLanguage = conflictOnA ? pair.canonicalLanguageB : pair.canonicalLanguageA
        let observed = try evidence(for: pair.id)
        let grouped = Dictionary(grouping: observed) { evidence -> String in
            conflictOnA
                ? TranslationGlossaryCanonicalizer.normalizedIdentityTerm(evidence.observedTermB)
                : TranslationGlossaryCanonicalizer.normalizedIdentityTerm(evidence.observedTermA)
        }
        // Any authored rendering outranks the model's own guess, however weak.
        let authoredGroups = grouped.values.filter { group in
            group.contains { $0.kindRaw != TranslationGlossaryEvidenceKind.modelRendering.rawValue }
        }
        let candidates = authoredGroups.isEmpty ? Array(grouped.values) : authoredGroups
        guard let winner = candidates.map({ group -> (String, Double, Date, String, String) in
            let term = conflictOnA ? group[0].observedTermB : group[0].observedTermA
            let score = TranslationGlossaryPolicy.confidence(
                supporting: group.map(\.strength),
                contradicting: []
            )
            let newest = group.map(\.observedAt).max() ?? .distantPast
            let key = TranslationGlossaryCanonicalizer.canonicalPair(
                language1: sourceLanguage, term1: sourceTerm,
                language2: targetLanguage, term2: term
            ).canonicalKey
            return (term, score, newest, key, TranslationGlossaryCanonicalizer.normalizedIdentityTerm(term))
        }).sorted(by: { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.3 < rhs.3
        }).first else { return }

        let selected = TranslationGlossaryCanonicalizer.canonicalPair(
            language1: sourceLanguage, term1: sourceTerm,
            language2: targetLanguage, term2: winner.0
        )
        if pair.canonicalKey != selected.canonicalKey { install(selected, on: pair) }
        for row in observed {
            let observedTarget = conflictOnA ? row.observedTermB : row.observedTermA
            row.polarityRaw = TranslationGlossaryCanonicalizer.normalizedIdentityTerm(observedTarget) == winner.4
                ? TranslationGlossaryEvidencePolarity.supporting.rawValue
                : TranslationGlossaryEvidencePolarity.contradicting.rawValue
        }
        try recomputeConfidence(for: pair)
        pair.updatedAt = max(pair.updatedAt, winner.2)
        pair.lastEvidenceAt = observed.map(\.observedAt).max()
    }

    private func reclassifyEvidence(for pair: TranslationGlossaryPair) throws {
        let rows = try evidence(for: pair.id)
        for row in rows {
            let supports = TranslationGlossaryCanonicalizer.normalizedIdentityTerm(row.observedTermA) == pair.normalizedTermA
                && TranslationGlossaryCanonicalizer.normalizedIdentityTerm(row.observedTermB) == pair.normalizedTermB
            row.polarityRaw = supports
                ? TranslationGlossaryEvidencePolarity.supporting.rawValue
                : TranslationGlossaryEvidencePolarity.contradicting.rawValue
        }
    }

    private func recomputeConfidence(for pair: TranslationGlossaryPair) throws {
        let rows = try evidence(for: pair.id)
        let supporting = rows.filter { $0.polarityRaw == TranslationGlossaryEvidencePolarity.supporting.rawValue }
        let authoredSupport = supporting.filter { $0.kindRaw != TranslationGlossaryEvidenceKind.modelRendering.rawValue }
        pair.confidence = TranslationGlossaryPolicy.confidence(
            // The model's guess holds a pair only until authored evidence
            // speaks for it; from then on authored evidence alone decides
            // whether the pair reaches exact authority.
            supporting: (authoredSupport.isEmpty ? supporting : authoredSupport).map(\.strength),
            // A superseded model rendering is not evidence against the
            // authored rendering that replaced it.
            contradicting: rows.filter {
                $0.polarityRaw == TranslationGlossaryEvidencePolarity.contradicting.rawValue
                    && $0.kindRaw != TranslationGlossaryEvidenceKind.modelRendering.rawValue
            }.map(\.strength)
        )
    }

    private func conflictsWithSource(_ pair: TranslationGlossaryPair, candidate: TranslationGlossaryCanonicalPair) -> Bool {
        (pair.canonicalLanguageA == candidate.languageA && pair.normalizedTermA == candidate.normalizedTermA)
            || (pair.canonicalLanguageB == candidate.languageB && pair.normalizedTermB == candidate.normalizedTermB)
    }

    private func tombstoneActiveConflicts(
        with canonical: TranslationGlossaryCanonicalPair,
        except pairID: UUID,
        now: Date
    ) throws {
        for pair in try allPairs()
        where pair.id != pairID && isActive(pair) && conflictsWithSource(pair, candidate: canonical) {
            pair.statusRaw = TranslationGlossaryPairStatus.deleted.rawValue
            pair.updatedAt = now
        }
    }

    private func isActive(_ pair: TranslationGlossaryPair) -> Bool {
        pair.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue
    }

    private func status(of pair: TranslationGlossaryPair) -> TranslationGlossaryPairStatus {
        TranslationGlossaryPairStatus(rawValue: pair.statusRaw) ?? .inferred
    }

    private func install(_ canonical: TranslationGlossaryCanonicalPair, on pair: TranslationGlossaryPair) {
        pair.canonicalLanguageA = canonical.languageA
        pair.canonicalLanguageB = canonical.languageB
        pair.termA = canonical.termA
        pair.termB = canonical.termB
        pair.normalizedTermA = canonical.normalizedTermA
        pair.normalizedTermB = canonical.normalizedTermB
        pair.canonicalKey = canonical.canonicalKey
    }

    private static func preferredDuplicate(
        _ lhs: TranslationGlossaryObservation,
        _ rhs: TranslationGlossaryObservation
    ) -> Bool {
        if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        if lhs.authoredSurfaces != rhs.authoredSurfaces {
            return lhs.authoredSurfaces.lexicographicallyPrecedes(rhs.authoredSurfaces)
        }
        return (lhs.excerpt ?? "") < (rhs.excerpt ?? "")
    }
}
