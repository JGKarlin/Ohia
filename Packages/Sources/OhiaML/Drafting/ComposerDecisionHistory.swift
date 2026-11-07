import Foundation
import OhiaCore

/// One completed source-evaluation result in the Composer's Decisions
/// timeline. The snapshot is deliberately independent of body revisions:
/// selecting it restores the evidence and interview that should shape the
/// next body without rewriting any already-saved draft text.
public struct ComposerDecisionVersion: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let index: Int
    public let createdAt: Date
    public let sources: [ComposerSource]
    public let interviewState: ComposerInterviewState
    /// The normalized Draft guidance captured with this Decisions basis.
    /// `nil` is reserved for histories written before guidance was versioned;
    /// new snapshots store `""` when the user supplied no guidance.
    public let draftGuidance: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        createdAt: Date = .now,
        sources: [ComposerSource],
        interviewState: ComposerInterviewState,
        draftGuidance: String? = nil
    ) {
        self.id = id
        self.index = index
        self.createdAt = createdAt
        self.sources = sources
        self.interviewState = interviewState
        self.draftGuidance = draftGuidance
    }
}

/// The decisions a full generation wrote its body from, frozen when that
/// body was persisted, and the language family it was written in. Restyles,
/// instruction revisions and manual edits since then leave it as it was.
public struct ComposerGeneratedDecisions: Codable, Sendable, Equatable {
    public let decisions: ComposerDecisionVersion
    public let languageID: String?

    public init(decisions: ComposerDecisionVersion, languageID: String?) {
        self.decisions = decisions
        self.languageID = languageID
    }
}

public struct ComposerDecisionHistory: Codable, Sendable, Equatable {
    public let versions: [ComposerDecisionVersion]
    public let activeVersionID: UUID?
    /// What the latest full generation was written from; nil before one, and
    /// in histories saved before it was recorded.
    public let generated: ComposerGeneratedDecisions?

    public init(
        versions: [ComposerDecisionVersion],
        activeVersionID: UUID?,
        generated: ComposerGeneratedDecisions? = nil
    ) {
        self.versions = versions.sorted { $0.index < $1.index }
        self.activeVersionID = activeVersionID
        self.generated = generated
    }
}

/// Owns the JSON boundary for `Draft.decisionHistoryJSON` and the mutations
/// that define Decisions-version semantics. All operations are synchronous
/// draft-row mutations; callers remain responsible for saving their context.
public enum ComposerDecisionHistoryPersistence {
    public static func decode(_ json: String?) -> ComposerDecisionHistory? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ComposerDecisionHistory.self, from: data)
    }

    public static func encode(_ history: ComposerDecisionHistory) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(history) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Seeds an evaluated v1 before the first subsequent source mutation.
    /// Initial source curation is not a Decisions version: its first version
    /// is written only when that evaluation completes successfully.
    public static func captureCurrentVersionIfNeeded(
        on draft: Draft,
        sourceBaseline: [ComposerSource]? = nil,
        at date: Date = .now
    ) {
        if let history = decode(draft.decisionHistoryJSON), !history.versions.isEmpty {
            return
        }
        guard draft.resolvedStage == DraftStage.collectingAnswers
                || draft.resolvedStage == DraftStage.drafted else {
            return
        }
        let version = snapshot(
            of: draft,
            id: UUID(),
            index: 1,
            createdAt: date,
            sources: sourceBaseline
        )
        store(
            ComposerDecisionHistory(
                versions: [version],
                activeVersionID: version.id
            ),
            on: draft
        )
    }

    /// Publishes one completed protocol evaluation.
    public static func recordCompletedEvaluation(
        on draft: Draft,
        createsNewVersion: Bool,
        at date: Date = .now
    ) {
        var history = decode(draft.decisionHistoryJSON)
            ?? ComposerDecisionHistory(versions: [], activeVersionID: nil)

        if createsNewVersion || history.versions.isEmpty {
            let nextIndex = (history.versions.map(\.index).max() ?? 0) + 1
            let version = snapshot(
                of: draft,
                id: UUID(),
                index: nextIndex,
                createdAt: date
            )
            history = ComposerDecisionHistory(
                versions: history.versions + [version],
                activeVersionID: version.id
            )
        } else {
            history = replacingActiveVersionFromDraft(in: history, draft: draft)
        }
        store(history, on: draft)
    }

    /// Freezes the exact Decisions basis used by a successful full-generation
    /// pass. The first draft enriches v1 in place. Later answer or guidance
    /// changes append one pending version; if source/question evaluation has
    /// already appended that version, guidance updates the same version.
    ///
    /// The decisions themselves are also frozen with `writtenLanguageID`, the
    /// language family the body was written in, so a later restyle or edit
    /// can be told apart from new decisions (`hasPendingDecisionChanges`).
    public static func recordGenerationBasis(
        on draft: Draft,
        writtenLanguageID: String?,
        at date: Date = .now
    ) {
        recordGenerationVersion(on: draft, at: date)
        guard let history = decode(draft.decisionHistoryJSON) else { return }
        let decisions = snapshot(
            of: draft,
            id: history.activeVersionID ?? UUID(),
            index: history.versions.first(where: { $0.id == history.activeVersionID })?.index ?? 0,
            createdAt: date,
            draftGuidance: liveGenerationGuidance(on: draft)
        )
        store(
            ComposerDecisionHistory(
                versions: history.versions,
                activeVersionID: history.activeVersionID,
                generated: ComposerGeneratedDecisions(decisions: decisions, languageID: writtenLanguageID)
            ),
            on: draft
        )
    }

    private static func recordGenerationVersion(
        on draft: Draft,
        at date: Date
    ) {
        var history = decode(draft.decisionHistoryJSON)
            ?? ComposerDecisionHistory(versions: [], activeVersionID: nil)
        let guidance = liveGenerationGuidance(on: draft)

        guard !history.versions.isEmpty,
              let activeIndex = activeVersionIndex(in: history) else {
            let version = snapshot(
                of: draft,
                id: UUID(),
                index: 1,
                createdAt: date,
                draftGuidance: guidance
            )
            store(
                ComposerDecisionHistory(
                    versions: [version],
                    activeVersionID: version.id
                ),
                on: draft
            )
            return
        }

        let active = history.versions[activeIndex]
        let current = snapshot(
            of: draft,
            id: active.id,
            index: active.index,
            createdAt: active.createdAt,
            draftGuidance: guidance
        )
        guard let latestDraftCreatedAt = draft.orderedRevisions.last?.createdAt else {
            var versions = history.versions
            versions[activeIndex] = current
            store(
                ComposerDecisionHistory(
                    versions: versions,
                    activeVersionID: active.id
                ),
                on: draft
            )
            return
        }

        let generatedIndex = generatedVersionIndex(
            in: history,
            latestDraftCreatedAt: latestDraftCreatedAt
        )
        let generated = history.versions[generatedIndex]
        if sameDecisionContent(current, generated) {
            if active.index > generated.index {
                let versions = history.versions.filter { $0.id != active.id }
                store(
                    ComposerDecisionHistory(
                        versions: versions,
                        activeVersionID: generated.id
                    ),
                    on: draft
                )
            } else if active.id != generated.id {
                store(
                    ComposerDecisionHistory(
                        versions: history.versions,
                        activeVersionID: generated.id
                    ),
                    on: draft
                )
            }
            return
        }
        if active.index > generated.index {
            var versions = history.versions
            versions[activeIndex] = current
            store(
                ComposerDecisionHistory(
                    versions: versions,
                    activeVersionID: active.id
                ),
                on: draft
            )
            return
        }

        let nextIndex = (history.versions.map(\.index).max() ?? 0) + 1
        let version = snapshot(
            of: draft,
            id: UUID(),
            index: nextIndex,
            createdAt: date,
            draftGuidance: guidance
        )
        history = ComposerDecisionHistory(
            versions: history.versions + [version],
            activeVersionID: version.id
        )
        store(history, on: draft)
    }

    /// Captures the active interview before a source mutation clears live
    /// groundings. Existing evaluated sources remain that version's baseline.
    public static func refreshActiveVersionFromDraft(on draft: Draft) {
        guard let history = decode(draft.decisionHistoryJSON), !history.versions.isEmpty else {
            captureCurrentVersionIfNeeded(on: draft)
            return
        }
        guard let activeIndex = activeVersionIndex(in: history) else { return }
        // Once a body exists, the version that produced it is immutable.
        // Reopening an answer prunes live interview state, but that action by
        // itself is not a changed decision and must not rewrite the baseline.
        guard draft.orderedRevisions.isEmpty else { return }
        let active = history.versions[activeIndex]
        let liveSources = ComposerSourceCoding.decode(draft.sourcesJSON)
        let replacement = ComposerDecisionVersion(
            id: active.id,
            index: active.index,
            createdAt: active.createdAt,
            sources: active.sources,
            interviewState: liveSources == active.sources
                ? decodedInterviewState(on: draft)
                : active.interviewState,
            draftGuidance: capturedDraftGuidance(on: draft, fallback: active.draftGuidance)
        )
        var versions = history.versions
        versions[activeIndex] = replacement
        store(
            ComposerDecisionHistory(
                versions: versions,
                activeVersionID: active.id
            ),
            on: draft
        )
    }

    /// Captures in-progress UI answers immediately before re-check, generation,
    /// or version switching. The evaluated source and grounding snapshot is
    /// intentionally preserved: an un-rechecked source edit is not a version.
    public static func updateActiveQuestionsAndAnswers(on draft: Draft) {
        guard let history = decode(draft.decisionHistoryJSON),
              let activeIndex = activeVersionIndex(in: history) else {
            return
        }
        let active = history.versions[activeIndex]
        let replacement = ComposerDecisionVersion(
            id: active.id,
            index: active.index,
            createdAt: active.createdAt,
            sources: active.sources,
            interviewState: decodedInterviewState(on: draft),
            draftGuidance: capturedDraftGuidance(on: draft, fallback: active.draftGuidance)
        )
        var versions = history.versions
        if let latestDraftCreatedAt = draft.orderedRevisions.last?.createdAt {
            let generatedIndex = generatedVersionIndex(
                in: history,
                latestDraftCreatedAt: latestDraftCreatedAt
            )
            let generated = history.versions[generatedIndex]
            if sameDecisionContent(replacement, generated) {
                if active.index > generated.index {
                    let remaining = history.versions.filter { $0.id != active.id }
                    store(
                        ComposerDecisionHistory(
                            versions: remaining,
                            activeVersionID: generated.id
                        ),
                        on: draft
                    )
                } else if active.id != generated.id {
                    store(
                        ComposerDecisionHistory(
                            versions: history.versions,
                            activeVersionID: generated.id
                        ),
                        on: draft
                    )
                }
                return
            }
            if active.index > generated.index {
                versions[activeIndex] = replacement
                store(
                    ComposerDecisionHistory(
                        versions: versions,
                        activeVersionID: active.id
                    ),
                    on: draft
                )
                return
            }
            let nextIndex = (history.versions.map(\.index).max() ?? 0) + 1
            let pending = ComposerDecisionVersion(
                id: UUID(),
                index: nextIndex,
                createdAt: .now,
                sources: replacement.sources,
                interviewState: replacement.interviewState,
                draftGuidance: replacement.draftGuidance
            )
            store(
                ComposerDecisionHistory(
                    versions: versions + [pending],
                    activeVersionID: pending.id
                ),
                on: draft
            )
            return
        }
        versions[activeIndex] = replacement
        store(
            ComposerDecisionHistory(
                versions: versions,
                activeVersionID: active.id
            ),
            on: draft
        )
    }

    /// Whether a new email's decisions (sources, answers, guidance) differ
    /// from those its latest full generation was written from. Restyles,
    /// revisions and manual edits since then do not change them. With no
    /// record of that generation, they are taken to differ. Compose only: a
    /// reply's Draft guidance is consumed by its generation.
    public static func hasPendingDecisionChanges(on draft: Draft) -> Bool {
        guard let generated = decode(draft.decisionHistoryJSON)?.generated?.decisions else { return true }
        let current = snapshot(
            of: draft,
            id: generated.id,
            index: generated.index,
            createdAt: generated.createdAt,
            draftGuidance: liveGenerationGuidance(on: draft)
        )
        return !sameDecisionContent(current, generated)
    }

    /// Whether the draft's chosen output language differs from the one its
    /// latest full generation was written in. An automatic language choice
    /// never differs.
    public static func hasPendingLanguageChange(on draft: Draft) -> Bool {
        guard let selected = DraftLanguage.familyID(for: draft.languageID) else { return false }
        guard let generated = decode(draft.decisionHistoryJSON)?.generated else { return true }
        return generated.languageID != selected
    }

    public static func hasPendingSourceChanges(on draft: Draft) -> Bool {
        guard let history = decode(draft.decisionHistoryJSON),
              let activeIndex = activeVersionIndex(in: history) else {
            return false
        }
        return ComposerSourceCoding.decode(draft.sourcesJSON)
            != history.versions[activeIndex].sources
    }

    /// Reinstates the active interview when a source edit returns exactly to
    /// its evaluated set. This keeps a net-zero add/remove cycle from leaving
    /// live grounding data cleared while Re-check is correctly disabled.
    @discardableResult
    public static func restoreDecisionStateIfSourcesMatchActiveVersion(
        _ sources: [ComposerSource],
        on draft: Draft
    ) -> Bool {
        guard let history = decode(draft.decisionHistoryJSON),
              let activeIndex = activeVersionIndex(in: history) else {
            return false
        }
        let active = history.versions[activeIndex]
        guard sources == active.sources else { return false }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(active.interviewState)
        draft.decisionResearchOverlayJSON = nil
        return true
    }

    /// Reinstates the complete Decisions basis while leaving body revisions
    /// untouched. The restored source set may therefore make the current body
    /// eligible for Regenerate, which is the intended cross-timeline behavior.
    public static func restore(_ version: ComposerDecisionVersion, on draft: Draft) {
        guard let history = decode(draft.decisionHistoryJSON),
              let storedVersion = history.versions.first(where: {
                  $0.id == version.id
              }) else {
            return
        }
        draft.sourcesJSON = ComposerSourceCoding.encode(storedVersion.sources)
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(
            storedVersion.interviewState
        )
        draft.decisionResearchOverlayJSON = nil
        if let guidance = storedVersion.draftGuidance {
            let restored = normalizedGuidance(guidance)
            if draft.message == nil {
                draft.composeInstruction = restored.isEmpty ? nil : restored
            } else {
                draft.draftingInstruction = restored.isEmpty ? nil : restored
            }
        }
        draft.stageRaw = DraftStage.collectingAnswers
        draft.sourceContextTokenCount = nil
        draft.sourceContextMeasurementRequestedAt = Date()
        draft.clearGenerationBackoff()
        store(
            ComposerDecisionHistory(
                versions: history.versions,
                activeVersionID: version.id
            ),
            on: draft
        )
    }

    private static func replacingActiveVersionFromDraft(
        in history: ComposerDecisionHistory,
        draft: Draft
    ) -> ComposerDecisionHistory {
        guard let activeIndex = activeVersionIndex(in: history) else { return history }
        let active = history.versions[activeIndex]
        let replacement = snapshot(
            of: draft,
            id: active.id,
            index: active.index,
            createdAt: active.createdAt,
            draftGuidance: capturedDraftGuidance(on: draft, fallback: active.draftGuidance)
        )
        var versions = history.versions
        versions[activeIndex] = replacement
        return ComposerDecisionHistory(
            versions: versions,
            activeVersionID: active.id
        )
    }

    private static func activeVersionIndex(in history: ComposerDecisionHistory) -> Int? {
        if let activeVersionID = history.activeVersionID,
           let index = history.versions.firstIndex(where: { $0.id == activeVersionID }) {
            return index
        }
        return history.versions.indices.last
    }

    private static func generatedVersionIndex(
        in history: ComposerDecisionHistory,
        latestDraftCreatedAt: Date
    ) -> Int {
        history.versions.indices
            .filter { history.versions[$0].createdAt <= latestDraftCreatedAt }
            .max { history.versions[$0].createdAt < history.versions[$1].createdAt }
            ?? history.versions.indices.first!
    }

    private static func snapshot(
        of draft: Draft,
        id: UUID,
        index: Int,
        createdAt: Date,
        sources: [ComposerSource]? = nil,
        draftGuidance: String? = nil
    ) -> ComposerDecisionVersion {
        ComposerDecisionVersion(
            id: id,
            index: index,
            createdAt: createdAt,
            sources: sources ?? ComposerSourceCoding.decode(draft.sourcesJSON),
            interviewState: decodedInterviewState(on: draft),
            draftGuidance: draftGuidance ?? capturedDraftGuidance(on: draft, fallback: nil)
        )
    }

    private static func sameDecisionContent(
        _ lhs: ComposerDecisionVersion,
        _ rhs: ComposerDecisionVersion
    ) -> Bool {
        lhs.sources == rhs.sources
            && lhs.interviewState == rhs.interviewState
            && normalizedGuidance(lhs.draftGuidance) == normalizedGuidance(rhs.draftGuidance)
    }

    private static func liveGenerationGuidance(on draft: Draft) -> String {
        normalizedGuidance(
            draft.message == nil ? draft.composeInstruction : draft.draftingInstruction
        )
    }

    private static func capturedDraftGuidance(
        on draft: Draft,
        fallback: String?
    ) -> String {
        if draft.message == nil {
            return normalizedGuidance(draft.composeInstruction)
        }
        if let draftingInstruction = draft.draftingInstruction {
            return normalizedGuidance(draftingInstruction)
        }
        if let fallback {
            return normalizedGuidance(fallback)
        }
        let generated = draft.orderedRevisions.reversed().first {
            $0.triggerRaw == DraftRevisionTrigger.initial
                || $0.triggerRaw == DraftRevisionTrigger.regenerate
        }
        return normalizedGuidance(generated?.instruction)
    }

    private static func normalizedGuidance(_ guidance: String?) -> String {
        guidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodedInterviewState(on draft: Draft) -> ComposerInterviewState {
        ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
            ?? ComposerInterviewState(
                contractVersion: ComposerInterviewPlanner.contractVersion,
                inputFingerprint: "",
                evidenceFingerprint: "",
                generationEpoch: 0,
                planningOutcome: .empty,
                baseProtocol: ComposerInterviewPlanner.emptyProtocol
            )
    }

    /// Version edits keep the record of what the latest full generation was
    /// written from; only `recordGenerationBasis` replaces it.
    private static func store(_ history: ComposerDecisionHistory, on draft: Draft) {
        let stored = history.generated == nil
            ? ComposerDecisionHistory(
                versions: history.versions,
                activeVersionID: history.activeVersionID,
                generated: decode(draft.decisionHistoryJSON)?.generated
            )
            : history
        if let encoded = encode(stored) {
            draft.decisionHistoryJSON = encoded
        }
    }
}
