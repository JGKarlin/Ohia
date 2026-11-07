import Foundation

public struct ComposerContextPack: Sendable, Equatable {
    public let anchorText: String
    public let sources: [ComposerSource]
    public let digest: String
    public let tokenCount: Int
    public let tokenLimit: Int

    public init(
        anchorText: String,
        sources: [ComposerSource],
        digest: String,
        tokenCount: Int,
        tokenLimit: Int
    ) {
        self.anchorText = anchorText
        self.sources = sources
        self.digest = digest
        self.tokenCount = tokenCount
        self.tokenLimit = tokenLimit
    }
}

public enum ComposerContextPackingError: LocalizedError, Sendable, Equatable {
    case contextTooLarge

    public var errorDescription: String? {
        switch self {
        case .contextTooLarge:
            return "The selected Composer context is too large to pack safely."
        }
    }
}

public struct ComposerContextPacker: Sendable {
    public struct Policy: Sendable, Equatable {
        public var maximumOperatingInputTokens = 32_768
        public var reservedPromptAndOutputTokens = 8_192
        public var fallbackEvidenceTokens = 12_288
        public var minimumUserSourceTokens = 64

        public init() {}
    }

    private let tokenCounter: (any PromptTokenCounting)?
    private let policy: Policy
    private let passageSelector = ComposerPassageSelector()

    public init(
        tokenCounter: (any PromptTokenCounting)?,
        policy: Policy = Policy()
    ) {
        self.tokenCounter = tokenCounter
        self.policy = policy
    }

    /// The writer window measured with this packer's tokenizer: the packer
    /// sizes evidence for preparation's full context, the window then fits
    /// that evidence to the draft writer.
    public var writerWindow: ComposerWriterWindow {
        ComposerWriterWindow(tokenCounter: tokenCounter)
    }

    public func pack(
        anchorText: String,
        anchorTerms: [String],
        sources: [ComposerSource]
    ) throws -> ComposerContextPack {
        let evidenceCeiling = evidenceTokenCeiling
        guard evidenceCeiling > 0 else {
            throw ComposerContextPackingError.contextTooLarge
        }

        let ordered = try prioritized(sources).compactMap { source -> ComposerSource? in
            let cleaned = source.kind == .memory
                ? source.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                : passageSelector.cleanedText(from: source.snippet)
            if cleaned.isEmpty {
                if source.isUserAdded {
                    throw ComposerContextPackingError.contextTooLarge
                }
                return nil
            }
            return replacingSnippet(of: source, with: cleaned)
        }
        let cleanedAnchor = passageSelector.cleanedText(from: anchorText)
        if anchorText.isEmpty == false, cleanedAnchor.isEmpty {
            throw ComposerContextPackingError.contextTooLarge
        }

        let completeDigest = digest(for: ordered)
        let completeTokenCount = count(cleanedAnchor + completeDigest)
        if completeTokenCount <= evidenceCeiling {
            return ComposerContextPack(
                anchorText: cleanedAnchor,
                sources: ordered,
                digest: completeDigest,
                tokenCount: completeTokenCount,
                tokenLimit: evidenceCeiling
            )
        }

        let userSources = ordered.filter(\.isUserAdded)
        let automaticSources = ordered.filter { $0.isUserAdded == false }
        let minimumUsers = try userSources.map {
            try minimumPackedUserSource($0, anchorTerms: anchorTerms)
        }
        let minimumDigest = digest(for: minimumUsers)
        guard count(minimumDigest) <= evidenceCeiling else {
            throw ComposerContextPackingError.contextTooLarge
        }

        let packedAnchor: String
        if count(cleanedAnchor + minimumDigest) <= evidenceCeiling {
            packedAnchor = cleanedAnchor
        } else {
            let allowance = max(0, evidenceCeiling - count(minimumDigest))
            packedAnchor = passageSelector.select(
                from: cleanedAnchor,
                anchorTerms: anchorTerms,
                maximumTokenCount: allowance,
                preservingBoundaryChunks: true,
                tokenCounter: count
            )
            guard count(packedAnchor + minimumDigest) <= evidenceCeiling else {
                throw ComposerContextPackingError.contextTooLarge
            }
        }
        if cleanedAnchor.isEmpty == false, packedAnchor.isEmpty {
            throw ComposerContextPackingError.contextTooLarge
        }

        var accepted = minimumUsers
        for (index, original) in userSources.enumerated() {
            var expanded = accepted
            expanded[index] = original
            if count(packedAnchor + digest(for: expanded)) <= evidenceCeiling {
                accepted = expanded
                continue
            }

            let selected = passageSelector.select(
                from: original.snippet,
                anchorTerms: anchorTerms
            )
            guard selected.isEmpty == false else {
                throw ComposerContextPackingError.contextTooLarge
            }
            let candidate = replacingSnippet(of: original, with: selected)
            expanded = accepted
            expanded[index] = candidate
            if count(packedAnchor + digest(for: expanded)) <= evidenceCeiling {
                accepted = expanded
            }
        }

        for source in automaticSources {
            if count(packedAnchor + digest(for: accepted + [source])) <= evidenceCeiling {
                accepted.append(source)
                continue
            }
            if let clipped = clippedAutomaticSource(
                source,
                acceptedSources: accepted,
                packedAnchor: packedAnchor,
                anchorTerms: anchorTerms,
                evidenceCeiling: evidenceCeiling
            ) {
                accepted.append(clipped)
            }
        }

        let packedDigest = digest(for: accepted)
        let packedTokenCount = count(packedAnchor + packedDigest)
        guard packedTokenCount <= evidenceCeiling else {
            throw ComposerContextPackingError.contextTooLarge
        }
        return ComposerContextPack(
            anchorText: packedAnchor,
            sources: accepted,
            digest: packedDigest,
            tokenCount: packedTokenCount,
            tokenLimit: evidenceCeiling
        )
    }

    private var evidenceTokenCeiling: Int {
        guard let tokenCounter,
              let modelMaximum = tokenCounter.maximumContextTokens else {
            return max(0, policy.fallbackEvidenceTokens)
        }
        let operating = min(
            max(0, modelMaximum),
            max(0, policy.maximumOperatingInputTokens)
        )
        return max(0, operating - max(0, policy.reservedPromptAndOutputTokens))
    }

    private func count(_ text: String) -> Int {
        if let tokenCounter {
            return max(0, tokenCounter.promptTokenCount(text))
        }
        return text.unicodeScalars.count
    }

    private func minimumPackedUserSource(
        _ source: ComposerSource,
        anchorTerms: [String]
    ) throws -> ComposerSource {
        // A memory's conditions and future-use limits cannot be separated from
        // its content, including when a user explicitly retained the source.
        if source.kind == .memory { return source }
        let selected = passageSelector.select(
            from: source.snippet,
            anchorTerms: anchorTerms
        )
        guard selected.isEmpty == false else {
            throw ComposerContextPackingError.contextTooLarge
        }
        let target = max(1, policy.minimumUserSourceTokens)
        let excerpt: String
        if count(selected) <= target {
            excerpt = selected
        } else {
            excerpt = ComposerPassageSelector.prefix(
                of: selected,
                fitting: target,
                tokenCounter: count
            )
        }
        guard excerpt.isEmpty == false else {
            throw ComposerContextPackingError.contextTooLarge
        }
        return replacingSnippet(of: source, with: excerpt)
    }

    private func clippedAutomaticSource(
        _ source: ComposerSource,
        acceptedSources: [ComposerSource],
        packedAnchor: String,
        anchorTerms: [String],
        evidenceCeiling: Int
    ) -> ComposerSource? {
        guard source.kind != .memory else { return nil }
        let currentCount = count(packedAnchor + digest(for: acceptedSources))
        let remaining = evidenceCeiling - currentCount
        guard remaining > 0 else { return nil }

        // Measure the source block's label/separator cost with the live
        // tokenizer, then spend only the true remaining evidence allowance
        // on a relevant passage from the source.
        let marker = "x"
        let markerSource = replacingSnippet(of: source, with: marker)
        let markerTotal = count(packedAnchor + digest(for: acceptedSources + [markerSource]))
        let overhead = max(0, markerTotal - currentCount - count(marker))
        var allowance = remaining - overhead
        guard allowance > 0 else { return nil }

        for _ in 0..<4 {
            let excerpt = passageSelector.select(
                from: source.snippet,
                anchorTerms: anchorTerms,
                maximumTokenCount: allowance,
                preservingBoundaryChunks: false,
                tokenCounter: count
            )
            guard excerpt.isEmpty == false else { return nil }
            let candidate = replacingSnippet(of: source, with: excerpt)
            let candidateCount = count(packedAnchor + digest(for: acceptedSources + [candidate]))
            if candidateCount <= evidenceCeiling {
                return candidate
            }
            let overflow = candidateCount - evidenceCeiling
            allowance -= max(1, overflow)
            if allowance <= 0 { return nil }
        }
        return nil
    }

    private func replacingSnippet(
        of source: ComposerSource,
        with snippet: String
    ) -> ComposerSource {
        ComposerSource(
            id: source.id,
            kind: source.kind,
            label: source.label,
            snippet: snippet,
            messageID: source.messageID,
            filePath: source.filePath,
            transcriptMessageCount: source.transcriptMessageCount,
            isUserAdded: source.isUserAdded,
            addedAt: source.addedAt,
            provenance: source.provenance,
            memoryUsePolicy: source.memoryUsePolicy,
            authoredByUser: source.authoredByUser,
            authoredAt: source.authoredAt
        )
    }

    private func digest(for sources: [ComposerSource]) -> String {
        sources.promptDigest(
            perSourceLimit: Int.max / 4,
            totalLimit: Int.max / 2
        )
    }

    private enum Priority: Int {
        case userAdded
        case threadState
        case threadMessage
        case remaining
    }

    private func prioritized(_ sources: [ComposerSource]) -> [ComposerSource] {
        sources.enumerated()
            .sorted { left, right in
                let leftPriority = priority(for: left.element)
                let rightPriority = priority(for: right.element)
                if leftPriority != rightPriority {
                    return leftPriority.rawValue < rightPriority.rawValue
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func priority(for source: ComposerSource) -> Priority {
        if source.isUserAdded {
            return .userAdded
        }
        return automaticPriority(for: source.kind)
    }

    /// The raw-value check recognizes Task 3's future `.threadState` case
    /// without requiring another edit to this packer.
    private func automaticPriority(for kind: ComposerSource.Kind) -> Priority {
        if kind.rawValue == "threadState" {
            return .threadState
        }
        switch kind {
        case .thread:
            return .threadMessage
        default:
            return .remaining
        }
    }
}

/// Fast, model-independent preflight for manual Composer source additions.
///
/// Sources the author adds are never left out of a draft, so together they
/// must fit the draft writer's room for sources: the writer prompt budget
/// minus the prompt without any source, which the worker measures with the
/// real tokenizer (`ComposerWriterWindowUsage.userSourceAllowance`). The app
/// process does not own that tokenizer, so the added sources are estimated
/// with a language-aware approximation: one token per digit (Qwen splits
/// numbers into digits, which dominates spreadsheet and CSV grids), roughly
/// four other ASCII bytes per token, and one token per non-ASCII scalar.
/// Automatic sources are not counted: the writer fit leaves them out first.
public struct ComposerSourceCapacityEstimate: Equatable, Sendable {
    public let estimatedCurrentTokens: Int
    public let estimatedCombinedTokens: Int
    public let estimatedAdditionalTokens: Int
    /// Room for author-added sources in the draft writer's prompt.
    public let evidenceTokenLimit: Int

    public var wouldExceed: Bool {
        estimatedCombinedTokens > evidenceTokenLimit
    }
}

public enum ComposerSourceCapacityEstimator {
    /// `writerUsage` is the draft's latest writer-window measurement. Before
    /// the first measurement, the room is the budget less the writer template
    /// and `unmeasuredContext` (the incoming message and the author's
    /// instructions), estimated the same way as the sources.
    public static func estimate(
        currentSources: [ComposerSource],
        proposedSources: [ComposerSource],
        writerUsage: ComposerWriterWindowUsage?,
        unmeasuredContext: String
    ) -> ComposerSourceCapacityEstimate {
        let currentManual = currentSources.filter(\.isUserAdded)
        let proposedManual = proposedSources.filter(\.isUserAdded)
        let currentTokens = estimatedTokens(for: currentManual)
        let combinedTokens = estimatedTokens(
            for: currentManual + proposedManual
        )
        let allowance = writerUsage?.userSourceAllowance
            ?? max(0, ComposerWriterWindow.promptBudget - templateTokens
                - (unmeasuredContext.isEmpty ? 0 : estimatedTokens(in: unmeasuredContext)))
        return ComposerSourceCapacityEstimate(
            estimatedCurrentTokens: currentTokens,
            estimatedCombinedTokens: combinedTokens,
            estimatedAdditionalTokens: max(0, combinedTokens - currentTokens),
            evidenceTokenLimit: allowance
        )
    }

    /// The writer template with no message, instruction or source, under the
    /// same approximation as the sources.
    static let templateTokens: Int = {
        let request = ComposerGenerationRequest(
            content: ComposerContentInput(mode: .reply, identityAddress: "", authorDisplayName: nil,
                to: [], cc: [], bcc: [], languageID: "und", subject: "", anchor: nil,
                requirements: [], unknowns: [], evidence: [], manualEdits: []),
            presentation: ComposerPresentationInput(registerID: nil, registerName: nil,
                registerRevision: nil, controls: nil),
            currentBody: nil, displayedRevisionID: nil, requestID: UUID())
        guard let brief = try? ComposerContentBrief.prepared(from: request.content),
              let prompt = try? ComposerWriterPrompt.render(request: request, brief: brief).prompt else { return 0 }
        return estimatedTokens(in: prompt)
    }()

    private static func estimatedTokens(for sources: [ComposerSource]) -> Int {
        guard !sources.isEmpty else { return 0 }
        return estimatedTokens(in: sources.promptDigest(
            perSourceLimit: Int.max / 4,
            totalLimit: Int.max / 2
        ))
    }

    static func estimatedTokens(in text: String) -> Int {
        var asciiBytes = 0
        var digits = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                if ("0"..."9").contains(scalar) { digits += 1 } else { asciiBytes += 1 }
            } else {
                nonASCII += 1
            }
        }
        return max(1, ((asciiBytes + 3) / 4) + digits + nonASCII)
    }
}
