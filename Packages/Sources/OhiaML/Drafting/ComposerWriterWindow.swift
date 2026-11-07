import Foundation
import OhiaCore

/// What the writer fit measured for one request: the source-context meter
/// and the sources the writer leaves out. Persisted with the source counts
/// (`Draft.sourceContextFitJSON`, `ReplySourcePreparation.sourceContextFitJSON`).
public struct ComposerWriterWindowUsage: Codable, Sendable, Equatable {
    /// Framed writer-prompt tokens with every selected source included: the
    /// meter's numerator. Above `promptBudget`, sources are left out.
    public var promptTokens: Int
    /// `ComposerWriterWindow.promptBudget`: the meter's denominator.
    public var promptBudget: Int
    /// Framed writer-prompt tokens with everything the fit never leaves out
    /// except sources the author added: the template, incoming message,
    /// instructions, memory and sources behind settled questions. Sources
    /// behind answered requests are left out last, not never. Author-added
    /// sources are never left out either, so they must fit in `promptBudget`
    /// minus this.
    public var essentialTokens: Int
    /// Automatic sources the fit leaves out, in the order it drops them.
    public var leftOutSourceIDs: [UUID]
    /// False when the content that is never left out still leaves the writer
    /// less than its minimum completion: drafting is rejected.
    public var fits: Bool
    /// When it does not fit, the largest cause, which names what the author
    /// can change.
    public var overflow: ComposerWriterWindowOverflow?
    /// Identity of the measured request. An unchanged request is not fitted
    /// again.
    public var requestFingerprint: String

    public init(promptTokens: Int, promptBudget: Int, essentialTokens: Int, leftOutSourceIDs: [UUID],
                fits: Bool = true, overflow: ComposerWriterWindowOverflow? = nil, requestFingerprint: String = "") {
        self.promptTokens = promptTokens
        self.promptBudget = promptBudget
        self.essentialTokens = essentialTokens
        self.leftOutSourceIDs = leftOutSourceIDs
        self.fits = fits
        self.overflow = overflow
        self.requestFingerprint = requestFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens, promptBudget, essentialTokens, leftOutSourceIDs, fits, overflow, requestFingerprint
        case incomingMessageExceedsWindow
    }

    /// A count is current only with the fit detail it was measured with. A
    /// count whose detail does not decode is not shown; it is measured again.
    public static func currentCount(_ count: Int?, fitJSON: String?) -> Int? {
        guard let count, decode(fitJSON) != nil else { return nil }
        return count
    }

    /// Measurements written by earlier builds of this window lack the later
    /// fields: they decode with the values a fitting, unfingerprinted
    /// measurement has, so the next measurement replaces them. An earlier
    /// overflow flag maps to its cause. A cause this build no longer has
    /// (the retired source findings) decodes as sources, unfingerprinted, so
    /// the measurement is taken again and a payload nesting it still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        promptBudget = try container.decodeIfPresent(Int.self, forKey: .promptBudget) ?? ComposerWriterWindow.promptBudget
        essentialTokens = try container.decodeIfPresent(Int.self, forKey: .essentialTokens) ?? 0
        leftOutSourceIDs = try container.decodeIfPresent([UUID].self, forKey: .leftOutSourceIDs) ?? []
        fits = try container.decodeIfPresent(Bool.self, forKey: .fits) ?? true
        requestFingerprint = try container.decodeIfPresent(String.self, forKey: .requestFingerprint) ?? ""
        if let raw = try container.decodeIfPresent(String.self, forKey: .overflow) {
            if let overflow = ComposerWriterWindowOverflow(rawValue: raw) {
                self.overflow = overflow
            } else {
                overflow = .sources
                requestFingerprint = ""
            }
        } else if try container.decodeIfPresent(Bool.self, forKey: .incomingMessageExceedsWindow) == true {
            overflow = .incomingMessage
        } else {
            overflow = fits ? nil : .sources
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(promptBudget, forKey: .promptBudget)
        try container.encode(essentialTokens, forKey: .essentialTokens)
        try container.encode(leftOutSourceIDs, forKey: .leftOutSourceIDs)
        try container.encode(fits, forKey: .fits)
        try container.encodeIfPresent(overflow, forKey: .overflow)
        try container.encode(requestFingerprint, forKey: .requestFingerprint)
    }

    /// Room for the sources the author adds by hand.
    public var userSourceAllowance: Int { max(0, promptBudget - essentialTokens) }

    public var json: String? {
        (try? ComposerContentCoding.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func decode(_ json: String?) -> ComposerWriterWindowUsage? {
        guard let json else { return nil }
        return try? ComposerContentCoding.decode(ComposerWriterWindowUsage.self, from: json)
    }
}

/// The draft writer's complete-sequence window, applied where selected
/// sources become writer evidence (`ComposerGenerationRequestCompiler`).
/// The fitted request is what the writer renders and what the generation
/// basis freezes, so runtime drafting and training render the same evidence.
///
/// A request that fits comes back unchanged. Otherwise whole evidence items
/// are left out, never clipped, in this order:
/// 1. automatic sources shown in Composer, other than thread mail and memory,
///    that the source review does not cite, lowest source priority first;
/// 2. the same kinds that the review cites as context or partial answers;
/// 3. thread mail, oldest first;
/// 4. thread-state observations;
/// 5. decision-research sources Composer does not list, which the author
///    cannot see or swap.
/// The incoming message, instructions, sources the author added, memory and
/// sources behind settled questions are never left out; sources that fully
/// answer a request are left out last. When
/// those alone exceed the budget, every other source is left out and the
/// writer drafts with what output room remains; only beyond the ceiling does
/// compilation throw.
///
/// Every count comes from the drafting engine's loaded tokenizer, the one the
/// executor's window guard uses. Without it the fit throws the transient
/// `TrainingEngineError.modelNotLoaded` rather than trusting an estimate.
public struct ComposerWriterWindow: Sendable {
    /// The writer's requested completion maximum. `ComposerContentPipeline`
    /// requests exactly this many tokens, so a fitted prompt always leaves the
    /// writer its full output allowance.
    public static let outputReserve = 1_024
    /// The largest framed writer prompt that leaves `outputReserve` inside the
    /// trained window: 4,096 - 1 - 1,024 = 3,071.
    public static let promptBudget = ComposerModelExecutor.writerSequenceLimit - 1 - outputReserve
    /// The longest prompt the writer can still complete from: the trained
    /// window less the writer's minimum completion, 4,096 - 1 - 128 = 3,967.
    /// A request whose kept content lands between the budget and this drafts
    /// with a shorter completion allowance.
    public static let promptCeiling = ComposerModelExecutor.writerSequenceLimit - 1
        - ComposerModelExecutor.minimumWriterOutputTokens

    /// The prompt size the fit aims for and the size beyond which the request
    /// is rejected.
    public struct Limits: Sendable, Equatable {
        public let budget: Int
        public let ceiling: Int

        /// Live drafting: full output room when possible, the executor's
        /// minimum completion at worst.
        public static let drafting = Limits(budget: promptBudget, ceiling: promptCeiling)

        /// A training example whose completion is known: prompt and completion
        /// share the trained window, with `reservedTokens` kept for content
        /// added after the fit (reconstructed notes).
        public static func training(completionTokens: Int, reservedTokens: Int) -> Limits {
            let budget = ComposerModelExecutor.writerSequenceLimit - completionTokens - reservedTokens
            return Limits(budget: budget, ceiling: budget)
        }
    }

    /// Sources the fit must keep, sources the source review cites, and
    /// sources Composer does not list.
    public struct Retention: Sendable, Equatable {
        public var protectedSourceIDs: Set<UUID>
        public var citedSourceIDs: Set<UUID>
        public var hiddenSourceIDs: Set<UUID>
        /// Sources of requests the review settled without asking: kept over
        /// every other source, but left out last rather than leaving the
        /// writer no room at all (a long related thread a dozen settled
        /// requests cite). The writer still reads the incoming email.
        public var settledSourceIDs: Set<UUID>

        public init(protectedSourceIDs: Set<UUID> = [], citedSourceIDs: Set<UUID> = [],
                    hiddenSourceIDs: Set<UUID> = [], settledSourceIDs: Set<UUID> = []) {
            self.protectedSourceIDs = protectedSourceIDs
            self.citedSourceIDs = citedSourceIDs
            self.hiddenSourceIDs = hiddenSourceIDs
            self.settledSourceIDs = settledSourceIDs
        }

        public static let none = Retention()

        /// The writer's only copy of an answer the interview settled is the
        /// source it came from: the question was pruned (answered questions,
        /// resolved groundings) or never asked (a request the sources fully
        /// answer). Those sources are kept. Other sources the review cites
        /// leave only after uncited ones.
        public static func from(_ state: ComposerInterviewState?,
                                hiddenSourceIDs: Set<UUID> = []) -> Retention {
            guard let state else { return Retention(hiddenSourceIDs: hiddenSourceIDs) }
            var protected = Set<UUID>()
            var cited = Set<UUID>()
            var settled = Set<UUID>()
            if let review = state.replyContext {
                for question in review.questions where question.disposition == .answered {
                    protected.formUnion(question.evidence.map(\.sourceID))
                }
                for item in review.responseItems ?? [] {
                    let sources = item.evidence.map(\.sourceID)
                    if item.status == .supported { settled.formUnion(sources) } else { cited.formUnion(sources) }
                }
                cited.formUnion(review.established.map(\.sourceID))
            }
            // Only groundings of questions still in this interview: a stale
            // grounding of a replaced question protects nothing the writer needs.
            let questionIDs = Set((state.baseProtocol.nodes + state.acceptedPatches.flatMap(\.nodes)).map(\.id))
            for grounding in state.groundings where questionIDs.contains(grounding.questionID)
                && QuestionGroundingValidation.isResolvedFact(grounding) {
                for citation in grounding.citations where citation.origin == .composerSource {
                    let prefix = "composer-source:"
                    guard citation.evidenceID.hasPrefix(prefix),
                          let id = UUID(uuidString: String(citation.evidenceID.dropFirst(prefix.count))) else { continue }
                    protected.insert(id)
                }
            }
            return Retention(protectedSourceIDs: protected,
                citedSourceIDs: cited.subtracting(protected).subtracting(settled),
                hiddenSourceIDs: hiddenSourceIDs, settledSourceIDs: settled.subtracting(protected))
        }
    }

    /// The fitted request and what was measured. When `fits` is false the
    /// request has every droppable source removed and still exceeds the
    /// ceiling; drafting rejects it.
    public struct Fit: Sendable {
        public let request: ComposerGenerationRequest
        public let usage: ComposerWriterWindowUsage
        public var fits: Bool { usage.fits }
    }

    private let tokenCounter: (any PromptTokenCounting)?

    /// `tokenCounter` is the drafting engine's tokenizer, the same one the
    /// writer guard in `ComposerModelExecutor` counts with.
    public init(tokenCounter: (any PromptTokenCounting)?) {
        self.tokenCounter = tokenCounter
    }

    /// Whether this window can measure: the drafting model's tokenizer is
    /// loaded.
    public var isTokenizerLoaded: Bool { tokenCounter?.isTokenizerLoaded == true }

    /// The loaded tokenizer, or the transient error that defers the fit until
    /// the drafting model is loaded.
    func loadedCounter() throws -> any PromptTokenCounting {
        guard let tokenCounter, tokenCounter.isTokenizerLoaded else { throw TrainingEngineError.modelNotLoaded }
        return tokenCounter
    }

    /// Framed writer-prompt tokens, as the executor guard counts them.
    public func promptTokens(_ prompt: String) throws -> Int {
        ComposerModelExecutor.promptTokens(prompt, counter: try loadedCounter())
    }

    /// Tokens a training completion occupies after the framed prompt: the
    /// stored completion and the turn's end marker.
    public func trainingCompletionTokens(_ completion: String) throws -> Int {
        try loadedCounter().promptTokenCount(completion + "<|im_end|>")
    }

    /// The brief the content pipeline renders `request` with: a cached brief
    /// still valid for exactly this content, otherwise a fresh one. Fresh
    /// briefs render from atoms and unknowns only, so the passage index is
    /// skipped.
    static func renderingBrief(for request: ComposerGenerationRequest,
                               cachedBrief: ComposerContentBrief?) throws -> ComposerContentBrief {
        if let cachedBrief, let completed = try? cachedBrief.completingCoverage(for: request.content),
           (try? completed.validate(against: request.content)) != nil {
            return completed
        }
        return try ComposerContentBrief.rendering(from: request.content)
    }

    /// The writer prompt for `request` exactly as drafting renders it.
    static func renderedPrompt(_ request: ComposerGenerationRequest, cachedBrief: ComposerContentBrief?) throws -> String {
        try ComposerWriterPrompt.render(request: request, brief: renderingBrief(for: request, cachedBrief: cachedBrief)).prompt
    }

    /// Identity of everything a fit depends on: what the prompt renders
    /// from, which sources must stay, and the limits.
    public static func fingerprint(_ request: ComposerGenerationRequest, retention: Retention,
                                   limits: Limits) throws -> String {
        func ids(_ set: Set<UUID>) -> String { set.map(\.uuidString).sorted().joined(separator: ",") }
        // Content identity leaves the output language out (a translation
        // reuses the evidence), but the writer prompt names it.
        let parts = [try request.contentIdentity, try request.presentationIdentity, request.content.languageID,
                     request.currentBody ?? "",
                     ids(retention.protectedSourceIDs), ids(retention.citedSourceIDs), ids(retention.hiddenSourceIDs),
                     ids(retention.settledSourceIDs),
                     "\(limits.budget):\(limits.ceiling)"]
        return ComposerContentCoding.digest(Data(parts.joined(separator: "\u{1f}").utf8))
    }

    public func fit(_ request: ComposerGenerationRequest, retention: Retention,
                    cachedBrief: ComposerContentBrief? = nil, limits: Limits = .drafting) throws -> Fit {
        let counter = try loadedCounter()
        func measure(_ candidate: ComposerGenerationRequest) throws -> Int {
            ComposerModelExecutor.promptTokens(try Self.renderedPrompt(candidate, cachedBrief: cachedBrief), counter: counter)
        }
        let full = try measure(request)
        let order = Self.dropOrder(request.content.evidence, retention: retention)
        let droppable = Set(order)
        var essentials = request
        essentials.content.evidence.removeAll { $0.source.isUserAdded || droppable.contains($0.source.id) }
        let essential = try measure(essentials)
        let fingerprint = try Self.fingerprint(request, retention: retention, limits: limits)
        func fitted(_ candidate: ComposerGenerationRequest, leftOut: [UUID], kept: Int) throws -> Fit {
            let fits = kept <= limits.ceiling
            let overflow = fits ? nil : Self.overflowCause(of: candidate, kept: kept, ceiling: limits.ceiling,
                measure: measure)
            return Fit(request: candidate, usage: ComposerWriterWindowUsage(promptTokens: full,
                promptBudget: limits.budget, essentialTokens: essential, leftOutSourceIDs: leftOut, fits: fits,
                overflow: overflow, requestFingerprint: fingerprint))
        }
        guard full > limits.budget else { return try fitted(request, leftOut: [], kept: full) }
        guard !order.isEmpty else { return try fitted(request, leftOut: [], kept: full) }

        func dropping(_ count: Int) -> ComposerGenerationRequest {
            let removed = Set(order.prefix(count))
            var candidate = request
            candidate.content.evidence.removeAll { removed.contains($0.source.id) }
            return candidate
        }
        // Each correspondence block's tokens, measured once. Sums choose how
        // many to leave out; only a full re-render measured within the budget
        // is accepted, so a sum that is off by a join never decides.
        let blocks = Dictionary(ComposerWriterPrompt.historyBlocks(request).map { ($0.sourceID, $0.text) },
            uniquingKeysWith: { first, _ in first })
        let costs = order.map { id in blocks[id].map { counter.promptTokenCount($0) + 1 } ?? 0 }
        let excess = full - limits.budget
        var count = order.count
        var removed = 0
        for (index, cost) in costs.enumerated() {
            removed += cost
            if removed >= excess { count = index + 1; break }
        }
        var kept = try measure(dropping(count))
        while kept > limits.budget, count < order.count {
            count += 1
            kept = try measure(dropping(count))
        }
        guard kept <= limits.budget else {
            // The kept content alone exceeds the budget: leave every other
            // source out for the most output room the window allows.
            return try fitted(dropping(order.count), leftOut: order, kept: kept)
        }
        // A sum that overestimated may have left out one source too many.
        while count > 1 {
            let fewer = try measure(dropping(count - 1))
            guard fewer <= limits.budget else { break }
            count -= 1
            kept = fewer
        }
        return try fitted(dropping(count), leftOut: Array(order.prefix(count)), kept: kept)
    }

    /// The largest part of what the writer must keep. The incoming email is
    /// the cause only when it alone, with nothing else, overflows; otherwise
    /// the part whose removal frees the most room, among parts the author can
    /// change.
    static func overflowCause(of kept: ComposerGenerationRequest, kept tokens: Int, ceiling: Int,
                              measure: (ComposerGenerationRequest) throws -> Int) -> ComposerWriterWindowOverflow {
        var bare = kept
        bare.content.evidence = []
        bare.content.requirements = []
        bare.content.manualEdits = []
        bare.content.unknowns = []
        bare.currentBody = nil
        if kept.content.anchor != nil, let bareTokens = try? measure(bare), bareTokens > ceiling {
            return .incomingMessage
        }
        var candidates: [(ComposerWriterWindowOverflow, ComposerGenerationRequest)] = []
        if kept.content.evidence.contains(where: { $0.source.kind != .memory }) {
            var without = kept
            without.content.evidence.removeAll { $0.source.kind != .memory }
            candidates.append((.sources, without))
        }
        if kept.content.evidence.contains(where: { $0.source.kind == .memory }) {
            var without = kept
            without.content.evidence.removeAll { $0.source.kind == .memory }
            candidates.append((.memory, without))
        }
        if !kept.content.requirements.isEmpty || !kept.content.unknowns.isEmpty {
            var without = kept
            without.content.requirements = []
            without.content.unknowns = []
            candidates.append((.instructions, without))
        }
        if kept.currentBody != nil || !kept.content.manualEdits.isEmpty {
            var without = kept
            without.currentBody = nil
            without.content.manualEdits = []
            candidates.append((.currentDraft, without))
        }
        // A part whose removal leaves a request the brief cannot render is
        // not a candidate.
        var largest: (cause: ComposerWriterWindowOverflow, freed: Int)?
        for (cause, without) in candidates {
            guard let remaining = try? measure(without) else { continue }
            let freed = tokens - remaining
            if freed > (largest?.freed ?? Int.min) { largest = (cause, freed) }
        }
        return largest?.cause ?? (kept.content.anchor != nil ? .incomingMessage : .instructions)
    }

    /// Evidence IDs in the order they are left out. Protected evidence never
    /// appears. Evidence order is the source pack's priority order.
    static func dropOrder(_ evidence: [ComposerEvidence], retention: Retention) -> [UUID] {
        let candidates = evidence.enumerated().filter { _, item in
            !item.source.isUserAdded && item.source.kind != .memory
                && !retention.protectedSourceIDs.contains(item.source.id)
        }
        let droppable = candidates.filter { !retention.settledSourceIDs.contains($0.element.source.id) }
        let settled = candidates.filter { retention.settledSourceIDs.contains($0.element.source.id) }.reversed()
        let visible = droppable.filter { !retention.hiddenSourceIDs.contains($0.element.source.id) }
        let other = visible.filter { $0.element.source.kind != .thread && $0.element.source.kind != .threadState }
            .reversed()
        let uncited = other.filter { !retention.citedSourceIDs.contains($0.element.source.id) }
        let cited = other.filter { retention.citedSourceIDs.contains($0.element.source.id) }
        let thread = visible.filter { $0.element.source.kind == .thread }.sorted { left, right in
            let leftDate = left.element.authoredAt ?? left.element.source.authoredAt ?? .distantPast
            let rightDate = right.element.authoredAt ?? right.element.source.authoredAt ?? .distantPast
            return leftDate == rightDate ? left.offset > right.offset : leftDate < rightDate
        }
        let state = visible.filter { $0.element.source.kind == .threadState }.reversed()
        let hidden = droppable.filter { retention.hiddenSourceIDs.contains($0.element.source.id) }.reversed()
        return (uncited + cited + thread + state + hidden + settled).map(\.element.source.id)
    }
}
