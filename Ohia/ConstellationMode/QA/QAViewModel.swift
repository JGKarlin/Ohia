// Ohia/ConstellationMode/QA/QAViewModel.swift
import Foundation
import Observation
import OhiaCore
import OhiaML

/// One question / answer round-trip. Stored in `QAViewModel.history` so the
/// sidebar can scroll back through past asks rather than discarding them on
/// every new question. Status starts `.running` and resolves to `.answered`
/// or `.failed`; that lets the row render its own progress indicator without
/// the panel needing a separate "in-flight" slot.
public struct QAEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var question: String
    public var answerText: String
    /// Reserved for diagnostics. The Ask tab renders only `answerText`.
    public var thinkingText: String?
    public var citationVectorIds: [Int64]
    /// Full prompt source list in rank order. `sourceVectorIdsByRank[i]` is
    /// the vector id for `[i + 1]` in `answerText`. The inline-citation
    /// renderer uses this to map each `[N]` chip to its source.
    public var sourceVectorIdsByRank: [Int64]
    /// Source-level display metadata aligned with `sourceVectorIdsByRank`.
    /// Used when a cited body/context source is backed by hydrated attachment
    /// evidence, so the citation can show visual provenance instead of a
    /// generic body label.
    public var sourceCitationMetadataByRank: [AskSourceCitationMetadata]
    public var routingSummary: String?
    public var progressText: String
    public var status: QAViewModel.Status
    public let askedAt: Date

    public init(
        id: UUID = UUID(),
        question: String,
        answerText: String = "",
        thinkingText: String? = nil,
        citationVectorIds: [Int64] = [],
        sourceVectorIdsByRank: [Int64] = [],
        sourceCitationMetadataByRank: [AskSourceCitationMetadata] = [],
        routingSummary: String? = nil,
        progressText: String = "Searching the active scope...",
        status: QAViewModel.Status = .running,
        askedAt: Date = Date.now
    ) {
        self.id = id
        self.question = question
        self.answerText = answerText
        self.thinkingText = thinkingText
        self.citationVectorIds = citationVectorIds
        self.sourceVectorIdsByRank = sourceVectorIdsByRank
        self.sourceCitationMetadataByRank = sourceCitationMetadataByRank
        self.routingSummary = routingSummary
        self.progressText = progressText
        self.status = status
        self.askedAt = askedAt
    }
}

@Observable @MainActor
public final class QAViewModel {

    public enum Status: Sendable, Equatable {
        case idle, running, answered, failed(String)
    }

    /// Text being typed in the input area. Bound to the panel's TextEditor.
    /// Renamed from `question` to clarify that this is the *draft*, not a
    /// committed entry — committed Q&As live in `history`.
    public var question: String = ""

    /// Newest-first list of completed (or in-flight) Q&A entries. The panel's
    /// citation-flash hookup reads `citationVectorIds` (computed below from
    /// the most recent answered entry) so the existing scene-flash plumbing
    /// keeps working without rewiring.
    public var history: [QAEntry] = []

    /// Accordion: the single entry whose answer body is visible. `nil` means
    /// every row is collapsed to its question line. Submitting a new question
    /// auto-sets this to the new entry so the user sees its progress / answer
    /// inline; prior entries fold to their question text.
    public var expandedEntryId: UUID?

    private let service: ConstellationQAService
    private let hybridRetriever: HybridRetriever
    private let askMemoryProvider: (any AskMemoryProvider)?
    private let displayLanguageGuard: DisplayLanguageGuard?
    private let prepareGeneration: @MainActor @Sendable () async -> Void

    public init(
        service: ConstellationQAService,
        hybridRetriever: HybridRetriever,
        askMemoryProvider: (any AskMemoryProvider)? = nil,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        prepareGeneration: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.service = service
        self.hybridRetriever = hybridRetriever
        self.askMemoryProvider = askMemoryProvider
        self.displayLanguageGuard = displayLanguageGuard
        self.prepareGeneration = prepareGeneration
    }

    /// Latest answered entry's citations. Drives the constellation scene's
    /// highlight flash via the existing `.onChange(of: qaVM.citationVectorIds)`
    /// observer in `ConstellationModeView`.
    public var citationVectorIds: [Int64] {
        history.first(where: { $0.status == .answered })?.citationVectorIds ?? []
    }

    /// Convenience for chrome (e.g. disabling the Ask button while any
    /// entry is in flight).
    public var isAnyRunning: Bool {
        history.contains(where: { $0.status == .running })
    }

    public var canRegenerateExpandedAnswer: Bool {
        guard let id = expandedEntryId,
              let entry = history.first(where: { $0.id == id }) else {
            return false
        }
        return entry.status != .running
            && entry.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public func submit(
        filter: FilterSpec,
        threadContextProvider: (@MainActor ([RetrievalResult]) async -> AskThreadExpansion)? = nil
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isAnyRunning else { return }

        let priorTurns = recentPriorTurns()

        // Insert the new entry at the top in `.running` state, then clear
        // the draft so the user can start typing the next question while
        // this one runs. Status updates flow back into the same entry by
        // id rather than tracking a "current" pointer.
        let entry = QAEntry(question: trimmed)
        history.insert(entry, at: 0)
        let entryId = entry.id
        expandedEntryId = entryId
        question = ""

        await runAnswerGeneration(
            query: trimmed,
            entryId: entryId,
            filter: filter,
            priorTurns: priorTurns,
            threadContextProvider: threadContextProvider ?? { _ in .empty }
        )
    }

    public func regenerateExpandedAnswer(
        filter: FilterSpec,
        threadContextProvider: @escaping @MainActor ([RetrievalResult]) async -> AskThreadExpansion
    ) async {
        guard !isAnyRunning,
              let entryId = expandedEntryId,
              let entry = history.first(where: { $0.id == entryId }) else {
            return
        }
        let trimmed = entry.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let priorTurns = recentPriorTurns(excluding: entryId)
        expandedEntryId = entryId
        update(id: entryId) {
            $0.answerText = ""
            $0.thinkingText = nil
            $0.citationVectorIds = []
            $0.sourceVectorIdsByRank = []
            $0.sourceCitationMetadataByRank = []
            $0.routingSummary = nil
            $0.progressText = "Searching the active scope..."
            $0.status = .running
        }
        await runAnswerGeneration(
            query: trimmed,
            entryId: entryId,
            filter: filter,
            priorTurns: priorTurns,
            threadContextProvider: threadContextProvider
        )
    }

    private func runAnswerGeneration(
        query trimmed: String,
        entryId: UUID,
        filter: FilterSpec,
        priorTurns: [QAPriorTurn],
        threadContextProvider: @escaping @MainActor ([RetrievalResult]) async -> AskThreadExpansion
    ) async {
        do {
            let retrieval = try await Task.detached(priority: .userInitiated) { [hybridRetriever] in
                try hybridRetriever.retrieveForAsk(query: trimmed, filter: filter)
            }.value
            update(id: entryId) {
                $0.progressText = "Expanding context..."
            }
            let threadExpansion = await threadContextProvider(retrieval.sources)
            let answerSources = Self.deduplicatedSources(
                retrieval.sources + threadExpansion.additionalSources
            )
            let scopeSummary = retrieval.route.promptScopeSummary(filter: filter)
            let memoryContext = await Task.detached(priority: .utility) { [provider = askMemoryProvider] in
                guard let provider else { return AskMemoryContext.empty }
                return (try? provider.context(for: trimmed, filter: filter, limit: .default)) ?? .empty
            }.value
            update(id: entryId) {
                $0.progressText = "Preparing answer..."
            }
            await prepareGeneration()
            update(id: entryId) {
                $0.progressText = "Writing answer..."
            }
            let answer = try await Task.detached(priority: .userInitiated) { [service] in
                try service.answer(
                    query: trimmed,
                    neighbors: answerSources,
                    scopeSummary: scopeSummary,
                    priorTurns: priorTurns,
                    threadContexts: threadExpansion.contexts,
                    visualEvidence: threadExpansion.visualEvidence,
                    memoryContext: memoryContext
                )
            }.value
            // Answers speak the asker's language; source-language names and
            // terms carried over from the cited mail are rendered into it.
            // Quoted wording, the asker's own terms, and answers to a question
            // about another language's wording stay verbatim. An answer whose
            // source-language passage could not be translated keeps its
            // generated wording, never a romanization.
            let answerLanguage = SummarizationTargetLanguage.readerLanguage(of: trimmed)
            let answerText: String
            if let displayLanguageGuard, answerLanguage.isNamedOtherLanguage(in: trimmed) == false {
                answerText = await displayLanguageGuard.resolve(
                    paragraph: answer.text,
                    targetLanguage: answerLanguage,
                    source: DisplayLanguageGuard.Source(
                        languageHint: nil,
                        context: answerSources.prefix(3).map(\.record.textPayload).joined(separator: "\n"),
                        messageID: nil,
                        accountID: nil,
                        preservesQuotedText: true,
                        readerText: trimmed
                    )
                ) ?? answer.text
            } else {
                answerText = answer.text
            }
            update(id: entryId) {
                $0.answerText = answerText
                $0.thinkingText = answer.thinkingText
                $0.citationVectorIds = answer.citationVectorIds
                $0.sourceVectorIdsByRank = answer.sourceVectorIdsByRank
                $0.sourceCitationMetadataByRank = answer.sourceCitationMetadataByRank
                $0.routingSummary = Self.routingSummary(
                    retrievalSummary: retrieval.uiSummary,
                    threadExpansion: threadExpansion,
                    memoryContext: memoryContext
                )
                $0.status = .answered
            }
        } catch TrainingEngineError.modelUnavailable(let message) {
            update(id: entryId) { $0.status = .failed(message) }
        } catch TrainingEngineError.modelNotLoaded {
            update(id: entryId) {
                $0.status = .failed("Answer engine is not ready yet.")
            }
        } catch {
            update(id: entryId) { $0.status = .failed("Ask failed: \(error.localizedDescription)") }
        }
    }

    /// Hard reset — clears draft AND history. Used by the panel's close-X.
    public func reset() {
        question = ""
        history.removeAll()
        expandedEntryId = nil
    }

    /// Accordion toggle: expand `id` if collapsed, collapse it if already
    /// expanded. Auto-collapses any other open entry since only one is ever
    /// expanded at a time.
    public func toggleExpansion(_ id: UUID) {
        expandedEntryId = (expandedEntryId == id) ? nil : id
    }

    private func update(id: UUID, _ mutate: (inout QAEntry) -> Void) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        var e = history[i]
        mutate(&e)
        history[i] = e
    }

    private func recentPriorTurns(limit: Int = 3, excluding excludedId: UUID? = nil) -> [QAPriorTurn] {
        Array(history
            .compactMap { entry -> QAPriorTurn? in
                if entry.id == excludedId { return nil }
                guard entry.status == .answered, !entry.answerText.isEmpty else { return nil }
                return QAPriorTurn(question: entry.question, answer: entry.answerText)
            }
            .prefix(limit)
            .reversed())
    }

    private static func deduplicatedSources(_ sources: [RetrievalResult]) -> [RetrievalResult] {
        var seen = Set<Int64>()
        return sources.filter { seen.insert($0.record.vectorId).inserted }
    }

    private static func routingSummary(
        retrievalSummary: String,
        threadExpansion: AskThreadExpansion,
        memoryContext: AskMemoryContext
    ) -> String {
        var parts = [retrievalSummary]
        let addedCount = threadExpansion.additionalSources.count
        if addedCount > 0 {
            let unit = addedCount == 1 ? "thread source" : "thread sources"
            parts.append("added \(addedCount) \(unit)")
        }
        let visualCount = threadExpansion.visualEvidence.count
        if visualCount > 0 {
            let unit = visualCount == 1 ? "visual attachment" : "visual attachments"
            parts.append("included \(visualCount) \(unit)")
        }
        if let memorySummary = memoryContext.uiSummary {
            parts.append(memorySummary)
        }
        return parts.joined(separator: "; ")
    }
}

public enum MockTrainingEngine {
    public static var null: any TrainingEngine {
        _NullEngine()
    }
}

private final class _NullEngine: TrainingEngine, @unchecked Sendable {
    var isModelLoaded: Bool { false }
    var isAdapterLoaded: Bool { false }
    var totalSteps: Int { 0 }
    var isCancelled: Bool { false }
    func loadModel(path: String) throws {}
    func trainStep(examples: [TrainingExample], learningRate: Double) throws -> TrainingStepResult {
        throw TrainingEngineError.modelNotLoaded
    }
    func saveAdapter(to path: String) throws {}
    func loadAdapter(from path: String) throws {}
    func generate(prompt: String, maxTokens: Int) throws -> String {
        throw TrainingEngineError.modelNotLoaded
    }
    func cancel() {}
    func resetCancellation() {}
}
