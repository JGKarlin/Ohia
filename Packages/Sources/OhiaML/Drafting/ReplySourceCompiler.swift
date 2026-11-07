import Foundation
import SwiftData
import OhiaCore

/// The compiled automatic sources. The draft writer's measurement of them is
/// taken once the writer's inputs are known: on the Draft that receives them,
/// or after a prepared reply's questions are planned.
public struct ReplySourceCompilationSnapshot: Sendable, Equatable {
    public let sourcesJSON: String
    public let sourceThreadCount: Int
    /// `ComposerThreadCoverage` JSON for the thread these sources were
    /// compiled from.
    public let threadCoverageJSON: String

    public init(
        sourcesJSON: String,
        sourceThreadCount: Int,
        threadCoverageJSON: String
    ) {
        self.sourcesJSON = sourcesJSON
        self.sourceThreadCount = sourceThreadCount
        self.threadCoverageJSON = threadCoverageJSON
    }
}

public protocol ReplySourceCompiling: Sendable {
    @MainActor
    func compile(
        for message: Message,
        context: ModelContext,
        preservingUserAddedSources: [ComposerSource]
    ) async throws -> ReplySourceCompilationSnapshot
}

enum ReplySourceCompilationControl: Error {
    case yielded
}

/// The single complete initial-reply source compiler. Both foreground
/// Composer fallback and background preparation consume this exact packed
/// snapshot; decision-conditioned follow-up research remains downstream.
public final class ReplySourceCompiler: ReplySourceCompiling, @unchecked Sendable {
    public typealias AutomaticWebsiteSourceExpander =
        @Sendable ([ComposerSource]) async throws -> [ComposerSource]

    private struct AutomaticReplySourceSelection {
        let sources: [ComposerSource]
        let selectorCompleted: Bool
    }

    private enum CompilationError: Error {
        case sourceEncodingFailed
    }

    private let sourceSelector: LLMComposerSourceSelector?
    private let hybridRetriever: HybridRetriever?
    private let contextPacker: ComposerContextPacker
    private let relatedAffinityProvider: (any ComposerRelatedAffinityProviding)?
    private let webResearchPlanner: (any ComposerWebResearchPlanning)?
    private let externalResearchProvider: (any ComposerExternalResearching)?
    private let messagesProvider: any MessagesTranscriptProviding
    private let automaticWebsiteSourceExpander: AutomaticWebsiteSourceExpander?
    private let shouldYield: @MainActor @Sendable () -> Bool

    public init(
        sourceSelector: LLMComposerSourceSelector? = nil,
        hybridRetriever: HybridRetriever? = nil,
        contextPacker: ComposerContextPacker = ComposerContextPacker(tokenCounter: nil),
        relatedAffinityProvider: (any ComposerRelatedAffinityProviding)? = nil,
        webResearchPlanner: (any ComposerWebResearchPlanning)? = nil,
        externalResearchProvider: (any ComposerExternalResearching)? = nil,
        messagesProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        automaticWebsiteSourceExpander: AutomaticWebsiteSourceExpander? = nil,
        shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.sourceSelector = sourceSelector
        self.hybridRetriever = hybridRetriever
        self.contextPacker = contextPacker
        self.relatedAffinityProvider = relatedAffinityProvider
        self.webResearchPlanner = webResearchPlanner
        self.externalResearchProvider = externalResearchProvider
        self.messagesProvider = messagesProvider
        self.automaticWebsiteSourceExpander = automaticWebsiteSourceExpander
        self.shouldYield = shouldYield
    }

    @MainActor
    public func compile(
        for message: Message,
        context: ModelContext,
        preservingUserAddedSources: [ComposerSource] = []
    ) async throws -> ReplySourceCompilationSnapshot {
        try checkForYield()
        // Taken before any await: a thread member that arrives mid-compile is
        // then reported as missed rather than claimed as seen.
        let coverage = ComposerSourceCompiler.threadCoverage(for: message)
        let automatic = try await automaticSources(for: message, context: context)
        try checkForYield()
        let merged = mergingAutomaticSources(
            automatic,
            preservingUserAdded: preservingUserAddedSources
        )
        let pack = try QuestionGroundingContextPacking.reply(
            message: message,
            bodyText: QuestionGroundingContextPacking.replyAnchorText(for: message),
            sources: merged,
            packer: contextPacker
        )
        guard let sourcesJSON = ComposerSourceCoding.encode(pack.sources) else {
            throw CompilationError.sourceEncodingFailed
        }
        return ReplySourceCompilationSnapshot(
            sourcesJSON: sourcesJSON,
            sourceThreadCount: coverage.messageIDs.count,
            threadCoverageJSON: coverage.encoded()
        )
    }

    @MainActor
    private func automaticSources(
        for message: Message,
        context: ModelContext
    ) async throws -> [ComposerSource] {
        let cleanedBody = ComposerSourceRelevance.cleanedBodyText(for: message)
        let mode = ComposerReplySourcePolicy.mode(
            cleanedBody: cleanedBody,
            correspondentName: message.fromName,
            hasAttachments: !message.attachments.isEmpty,
            triageVerdict: ComposerSourceRelevance.triageVerdict(of: message)
        )
        let messages = await automaticMessagesSources(for: message)
        if mode == .minimal {
            return dedupeSources(ComposerSourceCompiler.compileMinimal(for: message) + messages)
        }

        let deterministic = ComposerSourceCompiler.compile(
            for: message,
            context: context,
            relatedAffinityProvider: relatedAffinityProvider
        )
        let retrieval = retrievalSourceCandidates(
            for: message,
            contextSources: deterministic,
            context: context
        )
        let selection = selectAutomaticSources(
            for: message,
            candidates: dedupeSources(deterministic + retrieval)
        )
        try checkForYield()
        let withLocalPages = try await expandWebsites(selection.sources,
            anchorTerms: [message.subject, cleanedBody ?? ""])
        try checkForYield()
        guard selection.selectorCompleted, let cleanedBody else {
            return dedupeSources(withLocalPages + messages)
        }
        let researched = try await externalResearchSources(
            for: ComposerWebResearchContext(
                framing: .reply,
                subject: message.subject,
                bodyOrBrief: cleanedBody,
                counterpart: message.fromName ?? message.fromAddress,
                knownContextDigest: withLocalPages.promptDigest(
                    perSourceLimit: 600,
                    totalLimit: 5_000
                ),
                decisionsDigest: ""
            )
        )
        return dedupeSources(withLocalPages + researched + messages)
    }

    @MainActor
    private func automaticMessagesSources(for message: Message) async -> [ComposerSource] {
        guard ComposerSourceProviderPreference.isEnabled(.messages),
              !message.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let request = AutomaticMessagesRequest(
            context: .reply(messageID: message.id, draftID: message.draft?.id),
            correspondentAddress: message.fromAddress,
            limit: 200,
            maxAge: 365 * 24 * 60 * 60
        )
        return await messagesProvider.transcript(for: request)
            .composerSource(messageID: message.id)
            .map { [$0] } ?? []
    }

    @MainActor
    private func selectAutomaticSources(
        for message: Message,
        candidates: [ComposerSource]
    ) -> AutomaticReplySourceSelection {
        guard let sourceSelector else {
            return AutomaticReplySourceSelection(
                sources: LLMComposerSourceSelector.failClosedSources(
                    from: candidates,
                    for: message
                ),
                selectorCompleted: false
            )
        }
        do {
            let outcome = try sourceSelector.selectReplySources(
                for: message,
                candidates: candidates
            )
            return AutomaticReplySourceSelection(
                sources: outcome.sources,
                selectorCompleted: outcome.isValid
            )
        } catch {
            print("[Ohia] ⚠ Source selection failed for \(message.id): \(String(reflecting: type(of: error)))")
            return AutomaticReplySourceSelection(
                sources: LLMComposerSourceSelector.failClosedSources(
                    from: candidates,
                    for: message
                ),
                selectorCompleted: false
            )
        }
    }

    @MainActor
    private func externalResearchSources(
        for researchContext: ComposerWebResearchContext
    ) async throws -> [ComposerSource] {
        try checkForYield()
        guard let webResearchPlanner, let externalResearchProvider else { return [] }
        switch ComposerWebResearchGate.evaluate(researchContext) {
        case .skip:
            return []
        case .allow:
            break
        }
        let needs: [ComposerWebResearchNeed]
        do {
            needs = try webResearchPlanner.researchNeeds(
                for: researchContext,
                phase: .initial
            )
        } catch {
            print("[Ohia] Web research planning failed: \(String(reflecting: type(of: error)))")
            return []
        }
        guard !needs.isEmpty else { return [] }
        let sources = await externalResearchProvider.sources(for: needs)
        try checkForYield()
        let forExpansion = ComposerWebSourceKeeper.keepForExpansion(
            sources,
            needs: needs
        )
        guard !forExpansion.isEmpty else { return [] }
        let expanded = try await expandWebsites(forExpansion,
            anchorTerms: [researchContext.subject, researchContext.bodyOrBrief])
        try checkForYield()
        return ComposerWebSourceKeeper.keep(expanded, needs: needs)
    }

    private func expandWebsites(_ sources: [ComposerSource], anchorTerms: [String]) async throws -> [ComposerSource] {
        if let automaticWebsiteSourceExpander {
            return try await automaticWebsiteSourceExpander(sources)
        }
        return try await WebRAGComposerSourceExpander.expandAutomaticWebsiteSources(sources, anchorTerms: anchorTerms)
    }

    @MainActor
    private func checkForYield() throws {
        if shouldYield() {
            throw ReplySourceCompilationControl.yielded
        }
    }

    @MainActor
    private func retrievalSourceCandidates(
        for message: Message,
        contextSources: [ComposerSource],
        context: ModelContext
    ) -> [ComposerSource] {
        guard let hybridRetriever,
              let accountID = message.accountID ?? message.account?.id else {
            return []
        }
        let filter = FilterSpec(
            accountIds: [accountID],
            collections: [.context, .attachment]
        )
        let queries = DraftGenerationOrchestrator.sourceRetrievalQueries(for: message)
        guard queries.allSatisfy({
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            return []
        }

        let currentThreadIDs = Set((message.thread?.messages ?? []).map(\.id))
        var excludedMessageIDs = Set(contextSources.compactMap(\.messageID))
        for sourceMessageID in Array(excludedMessageIDs) {
            guard let sourceMessage = fetchMessage(sourceMessageID, context: context),
                  let sourceThread = sourceMessage.thread else {
                continue
            }
            excludedMessageIDs.formUnion(sourceThread.messages.map(\.id))
        }
        excludedMessageIDs.formUnion(currentThreadIDs)
        excludedMessageIDs.insert(message.id)

        let budget = AskPromptBudget(
            directMessageLimit: 1,
            wideMessageLimit: 500,
            wideSourceLimit: 32,
            standardSourceLimit: 32,
            directSourceLimit: 32
        )
        let resultLanes = queries.map { query in
            (try? hybridRetriever.retrieveForAsk(
                query: query,
                filter: filter,
                budget: budget
            ).sources) ?? []
        }
        let hydratedLanes = resultLanes.map { results in
            results.compactMap { result -> (
                result: RetrievalResult,
                messageID: UUID,
                message: Message
            )? in
                guard let messageID = UUID(uuidString: result.record.messageId),
                      let hydrated = fetchMessage(messageID, context: context) else {
                    return nil
                }
                return (result, messageID, hydrated)
            }
        }
        let hydratedResults = DraftGenerationOrchestrator.mergeRetrievalLanes(
            hydratedLanes,
            excludingMessageIDs: excludedMessageIDs,
            messageID: { $0.messageID }
        )
        let candidateIDs = Set(hydratedResults.map(\.messageID))
        let storedAffinities = relatedAffinityProvider?.affinities(
            anchorMessageID: message.id,
            candidateMessageIDs: candidateIDs,
            limit: max(candidateIDs.count, 1)
        ) ?? [:]
        let relevanceScores = ComposerSourceCompiler.crossThreadRelevanceScores(
            for: message,
            candidates: hydratedResults.map(\.message),
            context: context,
            storedAffinities: storedAffinities
        )
        let qualifiedResults = DraftGenerationOrchestrator.qualifiedRetrievalHits(
            hydratedResults,
            relevanceScores: relevanceScores,
            messageID: { $0.messageID }
        )
        let anchorTerms = ([message] + (message.thread?.messages ?? []).filter {
            $0.id != message.id && $0.isAutomatedOrBulk != true
        })
        .reduce(into: Set<String>()) { terms, evidenceMessage in
            terms.formUnion(ComposerSourceRelevance.relevanceTerms(for: evidenceMessage))
        }
        .sorted()
        let fallbackSnippets = Dictionary(uniqueKeysWithValues: qualifiedResults.map { item in
            let parsed = ComposerRetrievalPayload.parse(item.result.record.textPayload)
            let snippet = DraftGenerationOrchestrator.retrievalSnippet(
                collection: item.result.record.collection,
                parsedPayload: parsed,
                rawPayload: item.result.record.textPayload,
                hydratedBody: loadBody(item.message),
                anchorTerms: anchorTerms
            )
            return (item.messageID, snippet)
        })
        return ComposerSourceCompiler.bundledRelatedSources(
            for: message,
            messages: qualifiedResults.map(\.message),
            relevanceScores: relevanceScores,
            fallbackSnippets: fallbackSnippets
        )
    }

    private func dedupeSources(_ sources: [ComposerSource]) -> [ComposerSource] {
        var seen = Set<String>()
        var result: [ComposerSource] = []
        for source in sources {
            guard seen.insert(sourceDedupeKey(source)).inserted else { continue }
            result.append(source)
        }
        return result
    }

    private func mergingAutomaticSources(
        _ automatic: [ComposerSource],
        preservingUserAdded userAdded: [ComposerSource]
    ) -> [ComposerSource] {
        let userKeys = Set(userAdded.map(sourceDedupeKey))
        let filteredAutomatic = dedupeSources(automatic).filter {
            userKeys.contains(sourceDedupeKey($0)) == false
        }
        return filteredAutomatic + userAdded
    }

    private func sourceDedupeKey(_ source: ComposerSource) -> String {
        [
            source.kind.rawValue,
            source.messageID?.uuidString ?? "",
            source.filePath ?? "",
            source.label
        ].joined(separator: "\u{1F}")
    }

    @MainActor
    private func fetchMessage(_ id: UUID, context: ModelContext) -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first.flatMap { $0.isTrashed ? nil : $0 }
    }

    private func loadBody(_ message: Message) -> String {
        guard let path = message.bodyTextPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
