import Foundation
import SwiftData
import OhiaCore

public protocol TranslationGlossaryCorrectionRecording: Sendable {
    @MainActor
    func record(_ item: OutboxItem, context: ModelContext, now: Date) throws
}

/// Converts one localized user edit on an accepted Composer draft into
/// deterministic authored evidence. Generated text only locates the changed
/// span; it is never stored as positive evidence.
public final class TranslationGlossaryCorrectionRecorder: TranslationGlossaryCorrectionRecording {
    private let repositoryFactory: @MainActor @Sendable (ModelContext) -> TranslationGlossaryRepository

    public init(
        repositoryFactory: @escaping @MainActor @Sendable (ModelContext) -> TranslationGlossaryRepository = {
            TranslationGlossaryRepository(modelContext: $0)
        }
    ) {
        self.repositoryFactory = repositoryFactory
    }

    @MainActor
    public func record(
        _ item: OutboxItem,
        context: ModelContext,
        now: Date = .now
    ) throws {
        guard item.status == .sent,
              item.translationGlossaryFeedbackProcessedAt == nil else { return }

        let observations: [TranslationGlossaryObservation]
        if let draft = item.draft,
           let initial = draft.orderedRevisions.first(where: {
               $0.triggerRaw == DraftRevisionTrigger.initial
           }),
           let diff = localizedDiff(
               generated: AuthoredReplyText.extract(from: initial.bodyText),
               final: AuthoredReplyText.extract(from: item.plainBody)
           ) {
            let active = try context.fetch(FetchDescriptor<TranslationGlossaryPair>())
                .filter { $0.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue }
            let anchored = existingPairObservation(
                diff: diff,
                draft: draft,
                item: item,
                activePairs: active,
                now: now
            )
            if let anchored {
                observations = [anchored]
            } else if let explicit = explicitGuidanceObservation(
                diff: diff,
                draft: draft,
                item: item,
                now: now
            ) {
                observations = [explicit]
            } else {
                observations = []
            }
        } else {
            observations = []
        }

        let priorProcessedAt = item.translationGlossaryFeedbackProcessedAt
        let priorError = item.translationGlossaryFeedbackError
        do {
            try repositoryFactory(context).applyBatch(observations, reconciledAt: now) {
                item.translationGlossaryFeedbackProcessedAt = now
                item.translationGlossaryFeedbackError = nil
            }
        } catch {
            item.translationGlossaryFeedbackProcessedAt = priorProcessedAt
            item.translationGlossaryFeedbackError = priorError
            throw error
        }
    }

    private struct LocalizedDiff {
        let generated: [Character]
        let final: [Character]
        let generatedRange: Range<Int>
        let finalRange: Range<Int>
    }

    private struct OrientedPair {
        let sourceLanguage: String
        let sourceTerm: String
        let targetLanguage: String
        let generatedTarget: String
    }

    private struct LabeledTerm {
        let language: String
        let term: String
    }

    private func localizedDiff(generated: String, final: String) -> LocalizedDiff? {
        let generated = Array(generated)
        let final = Array(final)
        guard generated != final else { return nil }

        var prefix = 0
        while prefix < generated.count, prefix < final.count,
              generated[prefix] == final[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < generated.count - prefix,
              suffix < final.count - prefix,
              generated[generated.count - suffix - 1] == final[final.count - suffix - 1] {
            suffix += 1
        }
        let generatedRange = prefix..<(generated.count - suffix)
        let finalRange = prefix..<(final.count - suffix)
        guard generatedRange.isEmpty == false, finalRange.isEmpty == false else { return nil }
        let old = String(generated[generatedRange])
        let new = String(final[finalRange])
        guard safeRawReplacement(old), safeRawReplacement(new),
              TranslationGlossaryCanonicalizer.normalizedIdentityTerm(old)
                != TranslationGlossaryCanonicalizer.normalizedIdentityTerm(new) else {
            return nil
        }
        return LocalizedDiff(
            generated: generated,
            final: final,
            generatedRange: generatedRange,
            finalRange: finalRange
        )
    }

    private func safeRawReplacement(_ value: String) -> Bool {
        guard value.isEmpty == false,
              value.count <= TranslationGlossaryCandidateValidator.maximumTermLength,
              value.rangeOfCharacter(from: .newlines) == nil,
              value.split(whereSeparator: \.isWhitespace).count <= 6 else { return false }
        let scalars = value.unicodeScalars
        let meaningful = scalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        return meaningful * 2 >= max(1, scalars.count)
    }

    @MainActor
    private func existingPairObservation(
        diff: LocalizedDiff,
        draft: Draft,
        item: OutboxItem,
        activePairs: [TranslationGlossaryPair],
        now: Date
    ) -> TranslationGlossaryObservation? {
        let inputs = authoredAnchorSurfaces(for: draft)
        var candidates: [TranslationGlossaryObservation] = []
        for pair in activePairs {
            let orientations = [
                OrientedPair(
                    sourceLanguage: pair.canonicalLanguageA,
                    sourceTerm: pair.termA,
                    targetLanguage: pair.canonicalLanguageB,
                    generatedTarget: pair.termB
                ),
                OrientedPair(
                    sourceLanguage: pair.canonicalLanguageB,
                    sourceTerm: pair.termB,
                    targetLanguage: pair.canonicalLanguageA,
                    generatedTarget: pair.termA
                ),
            ]
            for orientation in orientations {
                guard let sourceSurface = inputs.first(where: {
                    $0.range(of: orientation.sourceTerm, options: .literal) != nil
                }) else { continue }
                for targetRange in occurrences(
                    of: Array(orientation.generatedTarget),
                    in: diff.generated
                ) where targetRange == diff.generatedRange {
                    let finalTerm = String(diff.final[diff.finalRange])
                    guard safeExpandedTerm(finalTerm),
                          hasSingleUnambiguousEditHunk(
                              generated: Array(orientation.generatedTarget),
                              final: Array(finalTerm)
                          ),
                          finalTerm != orientation.generatedTarget else { continue }
                    if let observation = validatedObservation(
                        language1: orientation.sourceLanguage,
                        term1: orientation.sourceTerm,
                        language2: orientation.targetLanguage,
                        term2: finalTerm,
                        sourceSurface: sourceSurface,
                        finalSurface: String(diff.final),
                        draft: draft,
                        item: item,
                        now: now
                    ) {
                        candidates.append(observation)
                    }
                }
            }
        }
        let unique = Dictionary(grouping: candidates, by: \.evidenceKey)
            .values.compactMap(\.first)
        return unique.count == 1 ? unique[0] : nil
    }

    private func hasSingleUnambiguousEditHunk(
        generated: [Character],
        final: [Character]
    ) -> Bool {
        let limit = TranslationGlossaryCandidateValidator.maximumTermLength
        guard generated.isEmpty == false, final.isEmpty == false,
              generated.count <= limit, final.count <= limit else { return false }

        var distance = Array(
            repeating: Array(repeating: 0, count: final.count + 1),
            count: generated.count + 1
        )
        for index in 0...generated.count { distance[index][0] = index }
        for index in 0...final.count { distance[0][index] = index }
        if generated.isEmpty == false, final.isEmpty == false {
            for generatedIndex in 1...generated.count {
                for finalIndex in 1...final.count {
                    let substitutionCost = generated[generatedIndex - 1] == final[finalIndex - 1]
                        ? 0
                        : 1
                    distance[generatedIndex][finalIndex] = min(
                        distance[generatedIndex - 1][finalIndex] + 1,
                        distance[generatedIndex][finalIndex - 1] + 1,
                        distance[generatedIndex - 1][finalIndex - 1] + substitutionCost
                    )
                }
            }
        }

        var generatedIndex = generated.count
        var finalIndex = final.count
        var editHunks = 0
        var previousWasEdit = false
        while generatedIndex > 0 || finalIndex > 0 {
            var predecessors: [(generatedIndex: Int, finalIndex: Int, isEdit: Bool)] = []
            let currentDistance = distance[generatedIndex][finalIndex]
            if generatedIndex > 0, finalIndex > 0 {
                let isMatch = generated[generatedIndex - 1] == final[finalIndex - 1]
                let cost = isMatch ? 0 : 1
                if distance[generatedIndex - 1][finalIndex - 1] + cost == currentDistance {
                    predecessors.append((generatedIndex - 1, finalIndex - 1, isMatch == false))
                }
            }
            if generatedIndex > 0,
               distance[generatedIndex - 1][finalIndex] + 1 == currentDistance {
                predecessors.append((generatedIndex - 1, finalIndex, true))
            }
            if finalIndex > 0,
               distance[generatedIndex][finalIndex - 1] + 1 == currentDistance {
                predecessors.append((generatedIndex, finalIndex - 1, true))
            }

            guard predecessors.count == 1, let predecessor = predecessors.first else {
                return false
            }
            if predecessor.isEdit {
                if previousWasEdit == false { editHunks += 1 }
                previousWasEdit = true
            } else {
                previousWasEdit = false
            }
            guard editHunks <= 1 else { return false }
            generatedIndex = predecessor.generatedIndex
            finalIndex = predecessor.finalIndex
        }
        return editHunks == 1
    }

    @MainActor
    private func explicitGuidanceObservation(
        diff: LocalizedDiff,
        draft: Draft,
        item: OutboxItem,
        now: Date
    ) -> TranslationGlossaryObservation? {
        var candidates: [TranslationGlossaryObservation] = []
        for surface in typedGuidanceSurfaces(for: draft) {
            let labeled = labeledTerms(in: surface)
            guard labeled.count >= 2 else { continue }
            for finalTerm in labeled {
                let finalRanges = occurrences(of: Array(finalTerm.term), in: diff.final)
                    .filter {
                        $0.lowerBound <= diff.finalRange.lowerBound
                            && $0.upperBound >= diff.finalRange.upperBound
                    }
                guard finalRanges.count == 1 else { continue }
                for sourceTerm in labeled where sourceTerm.language != finalTerm.language {
                    if let observation = validatedObservation(
                        language1: sourceTerm.language,
                        term1: sourceTerm.term,
                        language2: finalTerm.language,
                        term2: finalTerm.term,
                        sourceSurface: surface,
                        finalSurface: String(diff.final),
                        draft: draft,
                        item: item,
                        now: now
                    ) {
                        candidates.append(observation)
                    }
                }
            }
        }
        let unique = Dictionary(grouping: candidates, by: \.evidenceKey)
            .values.compactMap(\.first)
        return unique.count == 1 ? unique[0] : nil
    }

    private func validatedObservation(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        sourceSurface: String,
        finalSurface: String,
        draft: Draft,
        item: OutboxItem,
        now: Date
    ) -> TranslationGlossaryObservation? {
        let candidate = TranslationGlossaryObservation(
            evidenceKey: "composer-correction:\(draft.id.uuidString.lowercased())",
            kind: .composerCorrection,
            language1: language1,
            term1: term1,
            language2: language2,
            term2: term2,
            authoredSurfaces: [sourceSurface, finalSurface],
            sourceMessageID: draft.message?.id,
            sourceDraftID: draft.id,
            sourceAccountID: item.account?.id,
            sourceAuthorAddress: item.fromAddress,
            relationshipAnchor: .composerCorrection(
                sourceSurfaceIndex: 0,
                finalUserTextSurfaceIndex: 1
            ),
            excerpt: finalSurface,
            observedAt: now,
            strength: TranslationGlossaryPolicy.composerCorrectionStrength
        )
        guard case let .success(validated) = TranslationGlossaryCandidateValidator.validate(candidate) else {
            return nil
        }
        return validated
    }

    @MainActor
    private func authoredAnchorSurfaces(for draft: Draft) -> [String] {
        var surfaces: [String] = []
        if let path = draft.message?.bodyTextPath,
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            surfaces.append(QuotedHistoryTail.authoredText(from: raw))
        }
        surfaces.append(contentsOf: typedGuidanceSurfaces(for: draft))
        surfaces.append(contentsOf: ComposerSourceCoding.decode(draft.sourcesJSON)
            .filter(\.isUserAdded)
            .map(\.snippet))
        return nonemptyUnique(surfaces)
    }

    private func typedGuidanceSurfaces(for draft: Draft) -> [String] {
        nonemptyUnique(
            [draft.composeInstruction, draft.draftingInstruction]
                .compactMap { $0 }
                + draft.orderedRevisions.compactMap(\.instruction)
        )
    }

    private func labeledTerms(in surface: String) -> [LabeledTerm] {
        var values: [LabeledTerm] = []
        for line in surface.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var label = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if label.hasSuffix(" name") { label.removeLast(5) }
            let term = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard safeExpandedTerm(term),
                  let language = LocalModelLanguageSupport.supportedLanguageIDs.first(where: {
                      let display = LocalModelLanguageSupport.displayName(for: $0)?.lowercased()
                      return label == $0 || label == display
                  }) else { continue }
            values.append(LabeledTerm(language: language, term: term))
        }
        return values
    }

    private func safeExpandedTerm(_ value: String) -> Bool {
        safeRawReplacement(value)
            && TranslationGlossaryCanonicalizer.normalizedIdentityTerm(value).isEmpty == false
    }

    private func occurrences(of needle: [Character], in haystack: [Character]) -> [Range<Int>] {
        guard needle.isEmpty == false, needle.count <= haystack.count else { return [] }
        return (0...(haystack.count - needle.count)).compactMap { start in
            let end = start + needle.count
            return haystack[start..<end].elementsEqual(needle) ? start..<end : nil
        }
    }

    private func nonemptyUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && seen.insert($0).inserted
        }
    }
}
