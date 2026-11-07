// Summarizer.swift
// Generates proportional summaries of email bodies using the MLX engine.

import Foundation
import os
import OhiaCore

private let interpretationParseLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "pipeline"
)

public enum SummaryTextSanitizer {
    public static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = stripQuotedReplyLeakage(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false,
              looksLikeDegenerateRepetition(cleaned) == false else {
            return nil
        }
        return cleaned
    }

    /// Rejects the unmistakable adjacent token loops produced when a model
    /// keeps emitting the same name or phrase until its token budget ends.
    /// The thresholds deliberately tolerate ordinary repetition: a two-word
    /// phrase must repeat three times in a row, while a single token must
    /// repeat four times. Tokenization is Unicode-aware so Japanese and
    /// English summaries follow the same conservative rule.
    private static func looksLikeDegenerateRepetition(_ text: String) -> Bool {
        let tokens = text.lowercased().split { character in
            character.isLetter == false && character.isNumber == false
        }
        guard tokens.count >= 4 else { return false }

        var singleTokenRun = 1
        for index in tokens.indices.dropFirst() {
            if tokens[index] == tokens[tokens.index(before: index)], tokens[index].count >= 3 {
                singleTokenRun += 1
                if singleTokenRun >= 4 { return true }
            } else {
                singleTokenRun = 1
            }
        }

        let maximumPhraseWidth = min(8, tokens.count / 3)
        guard maximumPhraseWidth >= 2 else { return false }
        for width in 2...maximumPhraseWidth {
            let repeatedWidth = width * 3
            guard tokens.count >= repeatedWidth else { continue }
            for start in 0...(tokens.count - repeatedWidth) {
                let first = tokens[start..<(start + width)]
                let second = tokens[(start + width)..<(start + (2 * width))]
                let third = tokens[(start + (2 * width))..<(start + repeatedWidth)]
                if first.elementsEqual(second), first.elementsEqual(third) {
                    return true
                }
            }
        }
        return false
    }

    private static func stripQuotedReplyLeakage(from raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var kept: [String] = []
        var hasKeptContent = false

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReplyBoundary(lines: lines, index: index) {
                break
            }
            if isQuotedLine(trimmed) {
                if hasKeptContent { break }
                continue
            }
            kept.append(line)
            if trimmed.isEmpty == false {
                hasKeptContent = true
            }
        }

        return kept.joined(separator: "\n")
    }

    private static func isQuotedLine(_ trimmed: String) -> Bool {
        guard trimmed.isEmpty == false else { return false }
        return trimmed.hasPrefix(">")
    }

    private static func isReplyBoundary(lines: [String], index: Int) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if isStandardReplyBoundary(trimmed) { return true }
        let continuations = lines.dropFirst(index + 1).prefix(2).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ReplyAttribution.joinedAttribution(leadIn: trimmed, continuations: continuations) != nil {
            return true
        }
        return isOriginalHeaderBlockStart(lines: lines, index: index)
    }

    private static func isStandardReplyBoundary(_ trimmed: String) -> Bool {
        guard trimmed.isEmpty == false else { return false }
        let lowercased = trimmed.lowercased()
        if lowercased == "-----original message-----"
            || lowercased == "begin forwarded message:"
            || lowercased.hasPrefix("forwarded message")
            || lowercased.hasPrefix("original message") {
            return true
        }
        if trimmed.utf16.count <= 600,
           trimmed.range(
               of: #"^.{1,400}<[^<>\s]{1,200}>\s+wrote:$"#,
               options: .regularExpression
           ) != nil {
            return true
        }
        return ReplyAttribution.isAttributionLine(trimmed)
    }

    private static func isOriginalHeaderBlockStart(lines: [String], index: Int) -> Bool {
        OriginalHeaderBlock.starts(lines: lines, at: index)
    }
}

public struct SummarizationResult: Sendable, Equatable {
    public let summary: String
    public let classificationCandidates: ModelClassificationCandidates
    /// Present when a summary is generated from an already-persisted known
    /// interpretation. Fresh one-pass generation carries candidates instead.
    public let classification: MailClassification?
    /// User-defined category keys (`custom.<slug>`) assigned as independent
    /// overlays alongside built-in Purpose classification.
    public let customCategoryKeys: Set<String>
    public let semanticTagCandidates: [SemanticTagCandidate]
    /// Two-axis triage classification produced by the summarization LLM.
    /// Nil for existing stored summaries and conservative fallbacks. Populated by
    /// the one-pass Apple Foundation and MLX `.summarize` paths and persisted
    /// as JSON on `MessageAnalysis.triageVerdictJSON`.
    public let triageVerdict: TriageVerdict?

    public init(
        summary: String,
        classificationCandidates: ModelClassificationCandidates,
        triageVerdict: TriageVerdict? = nil,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) {
        self.summary = SummaryTextSanitizer.cleaned(summary)
            ?? summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationCandidates = classificationCandidates
        self.classification = nil
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.triageVerdict = triageVerdict
        self.semanticTagCandidates = semanticTagCandidates
    }

    public static func existing(
        summary: String?,
        classification: MailClassification,
        triageVerdict: TriageVerdict? = nil,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) -> SummarizationResult? {
        guard let summary = MLXSummarizer.postProcess(summary ?? "") else {
            return nil
        }
        return SummarizationResult(
            summary: summary,
            classification: classification,
            triageVerdict: triageVerdict,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    init(
        summary: String,
        classification: MailClassification,
        triageVerdict: TriageVerdict? = nil,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) {
        self.summary = SummaryTextSanitizer.cleaned(summary)
            ?? summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationCandidates = .empty
        self.classification = classification
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.triageVerdict = triageVerdict
        self.semanticTagCandidates = semanticTagCandidates
    }

    func replacingSummary(_ summary: String) -> SummarizationResult {
        return SummarizationResult(
            summary: summary,
            classificationCandidates: classificationCandidates,
            classification: classification,
            triageVerdict: triageVerdict,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    func replacingGeneratedText(
        summary: String,
        triageVerdict: TriageVerdict?,
        semanticTagCandidates: [SemanticTagCandidate]
    ) -> SummarizationResult {
        SummarizationResult(
            summary: summary,
            classificationCandidates: classificationCandidates,
            classification: classification,
            triageVerdict: triageVerdict,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    private init(
        summary: String,
        classificationCandidates: ModelClassificationCandidates,
        classification: MailClassification?,
        triageVerdict: TriageVerdict?,
        customCategoryKeys: Set<String>,
        semanticTagCandidates: [SemanticTagCandidate]
    ) {
        self.summary = SummaryTextSanitizer.cleaned(summary)
            ?? summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationCandidates = classificationCandidates
        self.classification = classification
        self.customCategoryKeys = customCategoryKeys
        self.triageVerdict = triageVerdict
        self.semanticTagCandidates = semanticTagCandidates
    }

}

public struct InterpretationResult: Sendable, Equatable {
    public let classificationCandidates: ModelClassificationCandidates
    public let customCategoryKeys: Set<String>
    public let semanticTagCandidates: [SemanticTagCandidate]
    public let triageVerdict: TriageVerdict
    /// Independent scheduling evidence. It never changes mail classification
    /// or attention state.
    public let meeting: MeetingCandidate?

    public init(
        classificationCandidates: ModelClassificationCandidates,
        triageVerdict: TriageVerdict,
        meeting: MeetingCandidate? = nil,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) {
        self.classificationCandidates = classificationCandidates
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.triageVerdict = triageVerdict
        self.meeting = meeting
        self.semanticTagCandidates = semanticTagCandidates
    }
}

public struct InterpretationMetadataResult: Sendable, Equatable {
    public let classificationCandidates: ModelClassificationCandidates
    public let customCategoryKeys: Set<String>
    public let semanticTagCandidates: [SemanticTagCandidate]

    public init(
        classificationCandidates: ModelClassificationCandidates,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) {
        self.classificationCandidates = classificationCandidates
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.semanticTagCandidates = semanticTagCandidates
    }
}

public extension InterpretationResult {
    var metadata: InterpretationMetadataResult {
        InterpretationMetadataResult(
            classificationCandidates: classificationCandidates,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }
}

public struct SummaryKnownInterpretation: Sendable, Equatable {
    public let classification: MailClassification
    public let customCategoryKeys: Set<String>
    public let semanticTagCandidates: [SemanticTagCandidate]
    public let triageVerdict: TriageVerdict

    public init(
        classification: MailClassification,
        triageVerdict: TriageVerdict,
        customCategoryKeys: Set<String> = [],
        semanticTagCandidates: [SemanticTagCandidate] = []
    ) {
        self.classification = classification
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.triageVerdict = triageVerdict
        self.semanticTagCandidates = semanticTagCandidates
    }
}

enum CustomCategoryAssignmentPolicy {
    static let confidenceThreshold = 0.75
    static let maxCustomCategories = 3

    /// Parses the `CustomCategories:` output line against the live custom
    /// catalog. Accepts `key=confidence` entries (and bare keys, which get
    /// a permissive default) and maps them back onto canonical keys via
    /// exact, display-name, and slug matching. Keys that don't resolve to a
    /// cataloged category are dropped — the model can't invent categories.
    static func customCategoryKeys(
        fromField raw: String?,
        catalog: [CustomMailCategoryDescriptor]
    ) -> Set<String> {
        guard catalog.isEmpty == false else { return [] }
        var accepted: Set<String> = []

        if let raw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            if !trimmed.isEmpty, !["none", "null", "nil", "n/a", "na", "[]"].contains(lowered) {
                for candidate in splitCandidates(trimmed) {
                    guard accepted.count < maxCustomCategories else { break }
                    let cleaned = candidate
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard cleaned.isEmpty == false else { continue }
                    // Strip a trailing `=confidence` / `:confidence` /
                    // `(confidence)` annotation; bare keys pass through.
                    var keyText = cleaned
                    var confidence = 1.0
                    if let separator = cleaned.lastIndex(where: { $0 == "=" || $0 == ":" }) {
                        let trailing = String(cleaned[cleaned.index(after: separator)...])
                            .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                        if let value = Double(trailing), value >= 0.0, value <= 1.0 {
                            keyText = String(cleaned[..<separator])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            confidence = value
                        }
                    }
                    guard confidence >= confidenceThreshold,
                          let key = CustomMailCategoryNormalization.normalizedKey(keyText, catalog: catalog) else {
                        continue
                    }
                    accepted.insert(key)
                }
            }
        }
        return accepted
    }

    private static func splitCandidates(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "\n", with: " || ")
            .replacingOccurrences(of: ";", with: " || ")
            .replacingOccurrences(of: ",", with: " || ")
        return normalized
            .components(separatedBy: TriageVerdictParsing.arraySeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}

/// Maps generated or user-facing custom-category tokens back onto
/// canonical `custom.<slug>` keys from the live catalog. Matching is
/// deliberately tolerant of model formatting (case, missing prefix,
/// display name instead of key) but never invents keys: anything that
/// fails to resolve against the catalog returns nil.
enum CustomMailCategoryNormalization {
    static func normalizedKey(
        _ raw: String,
        catalog: [CustomMailCategoryDescriptor]
    ) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return nil }
        let lowered = cleaned.lowercased()

        // 1. Exact key match (case-insensitive).
        if let exact = catalog.first(where: { $0.key.lowercased() == lowered }) {
            return exact.key
        }
        // 2. Exact display-name match (case-insensitive).
        if let byName = catalog.first(where: { $0.displayName.lowercased() == lowered }) {
            return byName.key
        }
        // 3. Slug match: the candidate's slug equals the key's slug part or
        //    the display name's slug ("Surf Trips", "surf trips",
        //    "surf_trips", "custom.surf_trips" all converge).
        let candidateSlug = CustomMailCategory.slug(
            forDisplayName: lowered.hasPrefix(CustomCategoryKeysJSON.keyPrefix)
                ? String(lowered.dropFirst(CustomCategoryKeysJSON.keyPrefix.count))
                : cleaned
        )
        guard candidateSlug != "category" else { return nil }
        return catalog.first { descriptor in
            let keySlug = String(descriptor.key.dropFirst(CustomCategoryKeysJSON.keyPrefix.count))
            return keySlug == candidateSlug
                || CustomMailCategory.slug(forDisplayName: descriptor.displayName) == candidateSlug
        }?.key
    }
}

/// Produces a concise proportional summary of an email body suitable for display in
/// the Map Mode Action pane, providing context before the user answers
/// the generated draft questions.
public protocol Summarizing: Sendable {
    /// Returns classification candidates, a triage verdict, and a summary sized to the source
    /// message and context, or nil on failure.
    func summarize(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async throws -> SummarizationResult?

    /// Returns a summary while treating the existing Purpose classification and
    /// Intents verdict as fixed inputs. Implementations that can use a
    /// narrower prompt should override this.
    func summarizeOnly(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?
    ) async throws -> SummarizationResult?
}

public extension Summarizing {
    func summarize(
        bodyText: String,
        senderName: String,
        subject: String
    ) async throws -> SummarizationResult? {
        try await summarize(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: nil
        )
    }

    func summarizeOnly(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?
    ) async throws -> SummarizationResult? {
        guard let result = try await summarize(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: context
        ) else {
            return nil
        }
        return SummarizationResult(
            summary: result.summary,
            classification: knownInterpretation.classification,
            triageVerdict: knownInterpretation.triageVerdict,
            customCategoryKeys: knownInterpretation.customCategoryKeys,
            semanticTagCandidates: knownInterpretation.semanticTagCandidates
        )
    }
}

public enum SummarizationError: Error {
    case guardrailViolation
    case modelUnavailable
    case empty
    case invalidCategory(String)
    case underlying(Error)
}

private func runCancellableGeneration(
    engine: any TrainingEngine,
    priority: TaskPriority,
    operation: @escaping @Sendable (any TrainingEngine, GenerationCancellation) throws -> String
) async throws -> String {
    let cancellation = GenerationCancellation()
    let task = Task.detached(priority: priority) {
        try Task.checkCancellation()
        return try operation(engine, cancellation)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        cancellation.cancel()
        task.cancel()
    }
}

/// Fast LLM-backed structured mail interpretation for ingestion-time use. This does
/// not ask for or persist a body summary; the rich summary remains an on-demand
/// UI affordance so bulk ingestion does not pay the full summary-generation
/// cost for every message.
public final class MLXInterpreter: @unchecked Sendable {

    private let engine: any TrainingEngine
    private let maxTokens: Int

    /// The interpretation emits a structured payload — purpose candidates,
    /// semantic labels, and (for triage-eligible mail) a verdict carrying an
    /// action spec and deadline candidates. A budget that the payload can
    /// overrun is not a soft limit: the output truncates mid-structure, the
    /// parse fails, and because the same input reproduces the same overrun the
    /// message can never succeed on retry. Ordinary correspondence was landing
    /// at ~1040 characters against a 640-token ceiling, so the ceiling itself
    /// was the failure. Budget for the long tail instead — a cap that is never
    /// reached costs nothing, since generation stops at the stop token.
    public static let defaultMaxTokens = 1_536

    public init(engine: any TrainingEngine, maxTokens: Int = MLXInterpreter.defaultMaxTokens) {
        self.engine = engine
        self.maxTokens = maxTokens
    }

    public func interpret(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async throws -> InterpretationResult? {
        let trimmed = Self.classificationBodyText(bodyText)
        let prompt = SummarizationPromptBuilder.mlxInterpretationPromptParts(
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            context: context
        )

        let engine = self.engine
        let maxTokens = self.maxTokens
        let raw = try await runCancellableGeneration(engine: engine, priority: .utility) { engine, cancellation in
            try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        var result = MLXSummarizer.parseGeneratedInterpretationResult(
            raw,
            customCategories: context?.customCategories ?? [],
            excludingSemanticTagKeys: Self.individualNameKeys(
                senderName: senderName,
                context: context
            )
        )
        if let reason = Self.secondPassReason(result?.classificationCandidates, context: context) {
            // Mirror `interpretMetadata`. Without this the full-interpretation
            // lane failed silently: the only trace was "MLX returned nil", which
            // cannot distinguish a truncated payload from a malformed one.
            // `rawCharacters` at the budget ceiling is the truncation signature.
            if result == nil { interpretationParseLogger.error(
                "Interpretation parse structure \(MLXSummarizer.interpretationMetadataParseStructure(raw), privacy: .public) rawCharacters=\(raw.count, privacy: .public) maxTokens=\(maxTokens, privacy: .public)"
            ) }
            let repairPrompt = SummarizationPromptBuilder.interpretationRepairPrompt(
                prompt, context: context, includesTriage: true, reason: reason
            )
            let repairedRaw = try await runCancellableGeneration(engine: engine, priority: .utility) { engine, cancellation in
                try PrefixCachedGeneration.generate(engine: engine, prompt: repairPrompt,
                    maxTokens: maxTokens, cancellation: cancellation)
            }
            let reviewed = MLXSummarizer.parseGeneratedInterpretationResult(repairedRaw,
                customCategories: context?.customCategories ?? [],
                excludingSemanticTagKeys: Self.individualNameKeys(senderName: senderName, context: context))
            if let reviewed, let original = result {
                result = InterpretationResult(classificationCandidates: reviewed.classificationCandidates,
                    triageVerdict: original.triageVerdict, meeting: original.meeting,
                    customCategoryKeys: original.customCategoryKeys, semanticTagCandidates: original.semanticTagCandidates)
            } else if let reviewed {
                result = reviewed
            }
            if reviewed == nil {
                interpretationParseLogger.error(
                    "Interpretation repair failed \(MLXSummarizer.interpretationMetadataParseStructure(repairedRaw), privacy: .public)"
                )
            }
        }
        return result
    }

    public func interpretMetadata(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async throws -> InterpretationMetadataResult? {
        let trimmed = Self.classificationBodyText(bodyText)
        let prompt = SummarizationPromptBuilder.mlxInterpretationPromptParts(
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            context: context,
            includesTriage: false
        )

        let engine = self.engine
        let maxTokens = self.maxTokens
        let raw = try await runCancellableGeneration(engine: engine, priority: .utility) { engine, cancellation in
            try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        var result = MLXSummarizer.parseGeneratedInterpretationMetadataResult(
            raw,
            customCategories: context?.customCategories ?? [],
            excludingSemanticTagKeys: Self.individualNameKeys(
                senderName: senderName,
                context: context
            )
        )
        if let reason = Self.secondPassReason(result?.classificationCandidates, context: context) {
            if result == nil { interpretationParseLogger.error(
                "Metadata interpretation parse structure \(MLXSummarizer.interpretationMetadataParseStructure(raw), privacy: .public)"
            ) }
            let repairPrompt = SummarizationPromptBuilder.interpretationRepairPrompt(
                prompt, context: context, includesTriage: false, reason: reason
            )
            let repairedRaw = try await runCancellableGeneration(engine: engine, priority: .utility) { engine, cancellation in
                try PrefixCachedGeneration.generate(engine: engine, prompt: repairPrompt,
                    maxTokens: maxTokens, cancellation: cancellation)
            }
            let reviewed = MLXSummarizer.parseGeneratedInterpretationMetadataResult(repairedRaw,
                customCategories: context?.customCategories ?? [],
                excludingSemanticTagKeys: Self.individualNameKeys(senderName: senderName, context: context))
            if let reviewed, let original = result {
                result = InterpretationMetadataResult(classificationCandidates: reviewed.classificationCandidates,
                    customCategoryKeys: original.customCategoryKeys, semanticTagCandidates: original.semanticTagCandidates)
            } else if let reviewed {
                result = reviewed
            }
            if reviewed == nil {
                interpretationParseLogger.error(
                    "Metadata interpretation repair failed \(MLXSummarizer.interpretationMetadataParseStructure(repairedRaw), privacy: .public)"
                )
            }
        }
        return result
    }

    /// The single bounded second generation, when one is warranted. `nil`
    /// candidates mean the first answer failed the contract.
    static func secondPassReason(
        _ candidates: ModelClassificationCandidates?,
        context: SummarizationContext?
    ) -> InterpretationSecondPassReason? {
        guard let candidates else { return .formatRepair }
        // The writer removes correspondence from these list posts before
        // resolving (`MessageSummaryWriter.listDeliveryExcludesCorrespondence`),
        // so judge exactly the remainder it will resolve. A first answer that
        // survives the writer is never re-generated.
        let excludesCorrespondence = context?.correspondenceExcludingListID != nil
            && candidates.purposes.contains { $0.purpose == .correspondence }
        let effective = excludesCorrespondence
            ? ModelClassificationCandidates(
                purposes: candidates.purposes.filter { $0.purpose != .correspondence },
                classifierVersion: candidates.classifierVersion
            )
            : candidates
        guard MailClassificationResolver.resolve(model: effective).purpose == nil else { return nil }
        if excludesCorrespondence {
            return .listCorrespondenceExcluded
        }
        guard effective.purposes.filter({ $0.confidence >= MailClassificationResolver.purposeThreshold }).count >= 2 else {
            return nil
        }
        return .competingPurposes
    }

    static func classificationBodyText(_ bodyText: String) -> String {
        let cleaned = OriginalMessageText.cleaned(
            from: bodyText,
            characterLimit: SummarizationPromptBuilder.interpretationBodyCharacterLimit
        ) ?? ""
        let signatureBoundaries = ["\n-- \n", "\n--\n"]
        let earliest = signatureBoundaries.compactMap { cleaned.range(of: $0)?.lowerBound }.min()
        guard let earliest else { return cleaned }
        return String(cleaned[..<earliest])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func individualNameKeys(
        senderName: String,
        context: SummarizationContext?
    ) -> Set<String> {
        var names: [String] = []
        if let ownerName = context?.userIdentity?.displayName {
            names.append(ownerName)
        }

        var sourceNames = [senderName]
        if let recipients = context?.anchorRecipients {
            sourceNames.append(contentsOf: recipients.to.compactMap(\.displayName))
            sourceNames.append(contentsOf: recipients.cc.compactMap(\.displayName))
        }
        for item in context?.connectedItems ?? [] {
            sourceNames.append(item.senderName)
            if let recipients = item.recipients {
                sourceNames.append(contentsOf: recipients.to.compactMap(\.displayName))
                sourceNames.append(contentsOf: recipients.cc.compactMap(\.displayName))
            }
        }
        names.append(contentsOf: sourceNames.compactMap(individualNameValue))

        return Set(names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : SemanticTagNormalizer.aliasKey(trimmed)
        })
    }

    private static func individualNameValue(_ raw: String) -> String? {
        let transportedName = raw.range(
            of: " via ",
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).map { range in
            String(raw[..<range.lowerBound])
        }
        let candidate = (transportedName ?? raw)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "'\"")
            ))
        let groupWords: Set<Substring> = [
            "builders", "class", "club", "committee", "community", "council",
            "course", "forum", "group", "media", "program", "secretariat",
            "services", "society", "staff", "support", "team", "vendor",
        ]
        let words = candidate
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }
        guard words.contains(where: groupWords.contains) == false else {
            return nil
        }
        return TranslationGlossaryCandidateValidator.isPlausiblePersonalName(candidate)
            ? candidate
            : nil
    }
}

/// LLM-backed summarizer using any `TrainingEngine` for text generation.
/// Used as the fallback when Apple's local model refuses a single email text
/// summary for content reasons.
public final class MLXSummarizer: Summarizing, @unchecked Sendable {

    static let extractionVersion = "mlx-v1"

    private let engine: any TrainingEngine
    private let maxTokens: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        maxTokens: Int = 640,
        generationTaskPriority: TaskPriority = .utility
    ) {
        self.engine = engine
        self.maxTokens = maxTokens
        self.generationTaskPriority = generationTaskPriority
    }

    public func summarize(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async throws -> SummarizationResult? {
        let trimmed = TranslationGlossaryProtection.markerSafePrefix(
            bodyText,
            limit: SummarizationPromptBuilder.bodyCharacterLimit
        )  // cap input — skip verbose footers
        let prompt = SummarizationPromptBuilder.mlxPromptParts(
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            context: context
        )

        let engine = self.engine
        let maxTokens = self.maxTokens
        let priority = generationTaskPriority
        let raw = try await runCancellableGeneration(engine: engine, priority: priority) { engine, cancellation in
            try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        guard let result = Self.parseGeneratedResult(
            raw,
            customCategories: context?.customCategories ?? []
        ) else { return nil }
        return SummaryIdentityValidator.validatedSummary(
            result,
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            context: context
        )
    }

    public func summarizeOnly(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?
    ) async throws -> SummarizationResult? {
        let trimmed = TranslationGlossaryProtection.markerSafePrefix(
            bodyText,
            limit: SummarizationPromptBuilder.bodyCharacterLimit
        )
        let prompt = SummarizationPromptBuilder.mlxSummaryOnlyPromptParts(
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            context: context
        )

        let engine = self.engine
        let maxTokens = self.maxTokens
        let priority = generationTaskPriority
        let raw = try await runCancellableGeneration(engine: engine, priority: priority) { engine, cancellation in
            try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        guard let summary = Self.parseGeneratedSummaryOnly(raw) else { return nil }
        let result = SummarizationResult(
            summary: summary,
            classification: knownInterpretation.classification,
            triageVerdict: knownInterpretation.triageVerdict,
            customCategoryKeys: knownInterpretation.customCategoryKeys,
            semanticTagCandidates: knownInterpretation.semanticTagCandidates
        )
        return SummaryIdentityValidator.validatedSummary(
            result,
            bodyText: trimmed,
            senderName: senderName,
            subject: subject,
            context: context
        )
    }

    public static func conservativeSummaryOnlyFallback(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?
    ) -> SummarizationResult {
        SummarizationResult(
            summary: bodyDerivedSummaryOnlyFallback(
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                knownInterpretation: knownInterpretation,
                context: context
            ) ?? SummaryIdentityValidator.conservativeSummaryFallback(
                senderName: senderName,
                subject: subject,
                context: context,
                includeAmbiguityNotice: false
            ),
            classification: knownInterpretation.classification,
            triageVerdict: knownInterpretation.triageVerdict,
            customCategoryKeys: knownInterpretation.customCategoryKeys,
            semanticTagCandidates: knownInterpretation.semanticTagCandidates
        )
    }

    private static func bodyDerivedSummaryOnlyFallback(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?
    ) -> String? {
        let actor = actorReference(senderName: senderName, context: context)
        var sentences: [String] = []
        if let lead = intentLeadSentence(
            from: knownInterpretation.triageVerdict,
            actor: actor
        ) {
            sentences.append(lead)
        }

        let sourceSentences = fallbackSourceSentences(from: bodyText)
        let detailSentences = prioritizedFallbackDetails(
            from: sourceSentences,
            subject: subject,
            knownInterpretation: knownInterpretation,
            existing: sentences,
            actor: actor,
            context: context
        )
        sentences.append(contentsOf: detailSentences)

        guard !sentences.isEmpty else { return nil }
        return postProcess(sentences.prefix(3).joined(separator: " "))
    }

    private static func intentLeadSentence(
        from verdict: TriageVerdict,
        actor: String
    ) -> String? {
        if let action = verdict.action,
           let sentence = intentSummarySentence(action.summary, actor: actor, isAction: true) {
            return sentence
        }
        if let acknowledgement = verdict.acknowledgement,
           let sentence = intentSummarySentence(acknowledgement.summary, actor: actor, isAction: false) {
            return sentence
        }
        return nil
    }

    private static func intentSummarySentence(
        _ raw: String,
        actor: String,
        isAction: Bool
    ) -> String? {
        let summary = collapsed(raw)
        guard !summary.isEmpty else { return nil }
        let lower = summary.lowercased()
        let sentence: String
        if lower.hasPrefix("ask if ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) whether \(lowercaseFirst(String(summary.dropFirst(7))))."
        } else if lower.hasPrefix("asks if ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) whether \(lowercaseFirst(String(summary.dropFirst(8))))."
        } else if lower.hasPrefix("ask whether ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) whether \(lowercaseFirst(String(summary.dropFirst(12))))."
        } else if lower.hasPrefix("asks whether ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) whether \(lowercaseFirst(String(summary.dropFirst(13))))."
        } else if lower.hasPrefix("request ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "requests", secondPerson: "request")) \(lowercaseFirst(String(summary.dropFirst(8))))."
        } else if lower.hasPrefix("requests ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "requests", secondPerson: "request")) \(lowercaseFirst(String(summary.dropFirst(9))))."
        } else if lower.hasPrefix("tell ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "says", secondPerson: "say")) \(lowercaseFirst(String(summary.dropFirst(5))))."
        } else if lower.hasPrefix("tells ") {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "says", secondPerson: "say")) \(lowercaseFirst(String(summary.dropFirst(6))))."
        } else if isAction {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) the recipient to \(lowercaseFirst(summary))."
        } else {
            sentence = "\(actor) \(verb(actor: actor, thirdPerson: "says", secondPerson: "say")) \(lowercaseFirst(summary))."
        }
        return ensureSentenceEnding(collapsed(sentence))
    }

    private static func fallbackSourceSentences(from bodyText: String) -> [String] {
        let normalized = bodyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                appendFallbackParagraph(current, to: &paragraphs)
                current.removeAll()
            } else {
                current.append(line)
            }
        }
        appendFallbackParagraph(current, to: &paragraphs)

        var sentences: [String] = []
        for paragraph in paragraphs {
            sentences.append(contentsOf: splitFallbackSentences(paragraph))
        }
        return sentences
    }

    private static func appendFallbackParagraph(_ lines: [String], to paragraphs: inout [String]) {
        let usefulLines = lines.filter { !isNonSummaryLine($0) }
        let paragraph = collapsed(usefulLines.joined(separator: " "))
        guard paragraph.count >= 18 else { return }
        paragraphs.append(paragraph)
    }

    private static func splitFallbackSentences(_ paragraph: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        for character in paragraph {
            buffer.append(character)
            if ".?!".contains(character) {
                appendFallbackSentence(buffer, to: &result)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        appendFallbackSentence(buffer, to: &result)
        return result
    }

    private static func appendFallbackSentence(_ raw: String, to sentences: inout [String]) {
        let sentence = collapsed(raw)
        guard sentence.count >= 18, !isNonSummaryLine(sentence) else { return }
        sentences.append(ensureSentenceEnding(sentence))
    }

    private static func prioritizedFallbackDetails(
        from sourceSentences: [String],
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        existing: [String],
        actor: String,
        context: SummarizationContext?
    ) -> [String] {
        let candidates = sourceSentences
            .map { transformedFallbackSentence($0, actor: actor, context: context) }
            .filter { !isDuplicateFallbackSentence($0, existing: existing) }
        guard !candidates.isEmpty else { return [] }

        var selected: [String] = []
        let groups: [(String) -> Bool] = [
            { containsAny($0, keywords: planningKeywords) },
            { containsNumericMoneySignal($0) },
            { containsMoneySignal($0) },
            { containsAny($0, keywords: decisionKeywords) || $0.contains("?") },
            { containsSubjectSignal($0, subject: subject) },
            { containsIntentSignal($0, knownInterpretation: knownInterpretation) }
        ]
        for group in groups {
            if let sentence = candidates.first(where: { group($0) && !isDuplicateFallbackSentence($0, existing: existing + selected) }) {
                selected.append(sentence)
            }
            if selected.count >= 2 { return selected }
        }

        for sentence in candidates where !isDuplicateFallbackSentence(sentence, existing: existing + selected) {
            selected.append(sentence)
            if selected.count >= 2 { break }
        }
        return selected
    }

    private static func transformedFallbackSentence(
        _ sentence: String,
        actor: String,
        context: SummarizationContext?
    ) -> String {
        var value = focusedFallbackClause(sentence)
        let owner = ownerReference(context)
        if value.lowercased().hasPrefix("do you have ") {
            value = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) whether \(owner) has \(String(value.dropFirst(12)))"
        } else if value.lowercased().hasPrefix("please ") {
            value = "\(actor) \(verb(actor: actor, thirdPerson: "asks", secondPerson: "ask")) \(owner) to \(String(value.dropFirst(7)))"
        } else if value.lowercased().hasPrefix("thank you for ") {
            value = "\(actor) \(verb(actor: actor, thirdPerson: "thanks", secondPerson: "thank")) \(owner) for \(String(value.dropFirst(14)))"
        }
        value = value
            .replacingOccurrences(of: "I'm assuming", with: "\(actor) \(verb(actor: actor, thirdPerson: "assumes", secondPerson: "assume"))")
            .replacingOccurrences(of: "I’m assuming", with: "\(actor) \(verb(actor: actor, thirdPerson: "assumes", secondPerson: "assume"))")
            .replacingOccurrences(of: "I'm going", with: "\(actor) \(verb(actor: actor, thirdPerson: "is going", secondPerson: "are going"))")
            .replacingOccurrences(of: "I’m going", with: "\(actor) \(verb(actor: actor, thirdPerson: "is going", secondPerson: "are going"))")
            .replacingOccurrences(of: "I wanted", with: "\(actor) wanted")
            .replacingOccurrences(of: "I revised", with: "\(actor) revised")
            .replacingOccurrences(of: "I've", with: "\(actor) \(verb(actor: actor, thirdPerson: "has", secondPerson: "have"))")
            .replacingOccurrences(of: "I’ve", with: "\(actor) \(verb(actor: actor, thirdPerson: "has", secondPerson: "have"))")
            .replacingOccurrences(of: "I ", with: "\(actor) ")
            .replacingOccurrences(of: " I'll ", with: " \(actor) will ")
            .replacingOccurrences(of: " I’ll ", with: " \(actor) will ")
            .replacingOccurrences(of: " I ", with: " \(actor) ")
            .replacingOccurrences(of: " you ", with: " \(owner) ")
            .replacingOccurrences(of: " your ", with: " \(owner)'s ")
        return ensureSentenceEnding(collapsed(value))
    }

    private static func focusedFallbackClause(_ sentence: String) -> String {
        let lower = sentence.lowercased()
        if let range = lower.range(of: "but if ") {
            let clause = sentence[range.upperBound...]
            return uppercaseFirst("if \(clause)")
        }
        if let range = lower.range(of: "based on ") {
            return uppercaseFirst(String(sentence[range.lowerBound...]))
        }
        return sentence
    }

    private static func isDuplicateFallbackSentence(_ sentence: String, existing: [String]) -> Bool {
        let candidateTokens = meaningfulFallbackTokens(sentence)
        guard !candidateTokens.isEmpty else { return true }
        for item in existing {
            let otherTokens = meaningfulFallbackTokens(item)
            guard !otherTokens.isEmpty else { continue }
            let overlap = candidateTokens.intersection(otherTokens).count
            let denominator = min(candidateTokens.count, otherTokens.count)
            if denominator > 0, Double(overlap) / Double(denominator) >= 0.65 {
                return true
            }
        }
        return false
    }

    private static func containsSubjectSignal(_ sentence: String, subject: String) -> Bool {
        let sentenceTokens = meaningfulFallbackTokens(sentence)
        return !sentenceTokens.isDisjoint(with: meaningfulFallbackTokens(subject))
    }

    private static func containsIntentSignal(
        _ sentence: String,
        knownInterpretation: SummaryKnownInterpretation
    ) -> Bool {
        var text = ""
        if let action = knownInterpretation.triageVerdict.action {
            text += " \(action.summary) \(action.decisionInputs.joined(separator: " "))"
        }
        if let acknowledgement = knownInterpretation.triageVerdict.acknowledgement {
            text += " \(acknowledgement.summary) \(acknowledgement.materialFacts.joined(separator: " "))"
        }
        let intentTokens = meaningfulFallbackTokens(text)
        return !intentTokens.isEmpty
            && !meaningfulFallbackTokens(sentence).isDisjoint(with: intentTokens)
    }

    private static func containsMoneySignal(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return lower.contains("budget")
            || lower.contains("ballpark")
            || lower.contains("cost")
            || lower.contains("$")
            || containsNumericMoneySignal(sentence)
    }

    private static func containsNumericMoneySignal(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return lower.contains("$")
            || lower.range(of: #"\b\d+(?:[,.]\d+)?\s*(?:k|m|\+|dollars?)\b"#, options: .regularExpression) != nil
    }

    private static func containsAny(_ sentence: String, keywords: Set<String>) -> Bool {
        let lower = sentence.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    private static func meaningfulFallbackTokens(_ raw: String) -> Set<String> {
        let words = raw
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !fallbackStopWords.contains($0) }
        return Set(words)
    }

    private static func isNonSummaryLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        if lower.hasPrefix(">") || lower.hasPrefix("on ") && lower.contains(" wrote:") {
            return true
        }
        let trimmed = lower.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!:-"))
        if fallbackGreetingOrSignatureLines.contains(trimmed) {
            return true
        }
        if trimmed.hasPrefix("hi ") || trimmed.hasPrefix("hello ") || trimmed.hasPrefix("dear ") {
            return true
        }
        if trimmed.split(whereSeparator: \.isWhitespace).count <= 2,
           !trimmed.contains("?"),
           !trimmed.contains("$"),
           trimmed.rangeOfCharacter(from: .decimalDigits) == nil {
            return true
        }
        return false
    }

    private static func actorReference(
        senderName: String,
        context: SummarizationContext?
    ) -> String {
        switch context?.anchorDirection {
        case .some(.outgoing):
            return "You"
        case .some(.incoming), .none:
            let trimmed = collapsed(senderName)
            return trimmed.isEmpty ? "The sender" : trimmed
        }
    }

    private static func verb(actor: String, thirdPerson: String, secondPerson: String) -> String {
        actor == "You" ? secondPerson : thirdPerson
    }

    private static func ownerReference(_ context: SummarizationContext?) -> String {
        if let displayName = context?.userIdentity?.displayName, !displayName.isEmpty {
            return displayName
        }
        if let address = context?.userIdentity?.primaryEmailAddress, !address.isEmpty {
            return address
        }
        return "the recipient"
    }

    private static func collapsed(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ensureSentenceEnding(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".?!".contains(last) ? trimmed : "\(trimmed)."
    }

    private static func lowercaseFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + String(value.dropFirst())
    }

    private static func uppercaseFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + String(value.dropFirst())
    }

    private static let planningKeywords: Set<String> = [
        "planning", "plan", "schedule", "timeline", "deadline", "call",
        "meeting", "coordinate", "integrated", "builder", "contractor",
        "prep", "scope", "estimate"
    ]

    private static let decisionKeywords: Set<String> = [
        "ask", "asks", "confirm", "decide", "decision", "whether",
        "review", "approve", "allocate", "priority", "must-have",
        "must have", "willing"
    ]

    private static let fallbackGreetingOrSignatureLines: Set<String> = [
        "hi", "hello", "dear", "thanks", "thank you", "best", "regards",
        "sincerely", "cheers", "sent from my iphone"
    ]

    private static let fallbackStopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are",
        "but", "not", "have", "has", "had", "was", "were", "will", "would",
        "could", "should", "from", "about", "into", "onto", "than", "then",
        "them", "they", "their", "there", "here", "some", "more", "just",
        "like", "what", "when", "where", "who", "why", "how", "can", "all",
        "any", "our", "out", "get", "got", "going"
    ]

    /// Canonical field labels accepted from Qwen output. The prompt asks for
    /// exact labels, but Qwen 3.5 may add spaces, markdown bullets, JSON key
    /// casing, or acknowledgement wording while still returning the right
    /// structure. Canonicalizing labels keeps the parser strict about required
    /// fields and categories without rejecting harmless formatting.
    private static let fieldKeyByCanonicalLabel: [String: String] = [
        "acknowledgementsummary": "acknowledgementSummary",
        "acknowledgmentsummary": "acknowledgementSummary",
        "acknowledgementsignalkind": "acknowledgementSignalKind",
        "acknowledgmentsignalkind": "acknowledgementSignalKind",
        "acknowledgementdeadlinekind": "acknowledgementDeadlineKind",
        "acknowledgmentdeadlinekind": "acknowledgementDeadlineKind",
        "acknowledgementdeadline": "acknowledgementDeadline",
        "acknowledgmentdeadline": "acknowledgementDeadline",
        "acknowledgementfacts": "acknowledgementFacts",
        "acknowledgmentfacts": "acknowledgementFacts",
        "actionsummary": "actionSummary",
        "actionkind": "actionKind",
        "actiondirectedat": "actionDirectedAt",
        "actiondeadlinekind": "actionDeadlineKind",
        "actiondeadline": "actionDeadline",
        "actioninputs": "actionInputs",
        "isactionable": "isActionable",
        "actionable": "isActionable",
        "meetingtitle": "meetingTitle",
        "meetingstart": "meetingStart",
        "meetingend": "meetingEnd",
        "meetingtimezone": "meetingTimeZone",
        "meetingtimezoneidentifier": "meetingTimeZone",
        "meetinglocation": "meetingLocation",
        "meetingurl": "meetingURL",
        "meetinglink": "meetingURL",
        "requiresconfirmation": "requiresConfirmation",
        "requiresacknowledgement": "requiresConfirmation",
        "requiresacknowledgment": "requiresConfirmation",
        "needsacknowledgement": "requiresConfirmation",
        "needsacknowledgment": "requiresConfirmation",
        "purposecandidates": "purposeCandidates",
        "classificationevidence": "classificationEvidence",
        "customcategory": "customCategories",
        "customcategories": "customCategories",
        "usercategory": "customCategories",
        "usercategories": "customCategories",
        "userdefinedcategory": "customCategories",
        "userdefinedcategories": "customCategories",
        "semantictags": "semanticTags",
        "bodysummary": "summary",
        "summary": "summary",
        "intent": "intentSummary",
        "intents": "intentSummary",
        "attentionflags": "intentSummary",
        "triage": "intentSummary",
    ]

    static func parseGeneratedResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor] = []
    ) -> SummarizationResult? {
        let normalizedRaw = GenerationStopPolicy.finalizedSummaryOutput(
            stripControlTokens(from: stripThinking(from: raw))
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
        if let result = parseJSONGeneratedResult(normalizedRaw, customCategories: customCategories) {
            return result
        }
        let lines = normalizedRaw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var fields: [String: String] = [:]
        var summaryLines: [String] = []
        var summaryFieldSeen = false

        for line in lines where line.isEmpty == false {
            let cleanedLine = cleanedGeneratedLine(line)
            guard cleanedLine.isEmpty == false else { continue }
            if let (key, value) = parseFieldLine(cleanedLine) {
                if key == "summary" {
                    summaryFieldSeen = true
                    if value.isEmpty == false {
                        summaryLines.append(value)
                    }
                } else {
                    fields[key] = value
                }
                continue
            }
            if summaryFieldSeen {
                summaryLines.append(cleanedLine)
            }
        }

        return makeGeneratedResult(
            fields: fields,
            summarySource: summaryLines.isEmpty ? nil : summaryLines.joined(separator: "\n"),
            customCategories: customCategories
        )
    }

    static func parseGeneratedSummaryOnly(_ raw: String) -> String? {
        let normalizedRaw = GenerationStopPolicy.finalizedSummaryOutput(
            stripControlTokens(from: stripThinking(from: raw))
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
        if let jsonText = jsonObjectSubstring(from: normalizedRaw),
           let data = jsonText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            for (label, value) in dictionary {
                guard fieldKeyByCanonicalLabel[canonicalFieldLabel(label)] == "summary",
                      let stringValue = stringValue(fromJSONValue: value) else {
                    continue
                }
                if let summary = postProcess(stringValue) {
                    return summary
                }
            }
        }

        let lines = normalizedRaw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var summaryLines: [String] = []
        var summaryFieldSeen = false

        for line in lines where line.isEmpty == false {
            let cleanedLine = cleanedGeneratedLine(line)
            guard cleanedLine.isEmpty == false else { continue }
            if let (key, value) = parseFieldLine(cleanedLine) {
                if key == "summary" {
                    summaryFieldSeen = true
                    if value.isEmpty == false {
                        summaryLines.append(value)
                    }
                }
                continue
            }
            if summaryFieldSeen {
                summaryLines.append(cleanedLine)
            }
        }

        if !summaryLines.isEmpty {
            return postProcess(summaryLines.joined(separator: "\n"))
        }
        return postProcess(normalizedRaw)
    }

    static func parseGeneratedInterpretationResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor] = [],
        excludingSemanticTagKeys: Set<String> = []
    ) -> InterpretationResult? {
        let normalizedRaw = GenerationStopPolicy.finalizedSummaryOutput(
            stripControlTokens(from: stripThinking(from: raw))
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
        if let result = parseJSONGeneratedInterpretationResult(
            normalizedRaw,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        ) {
            return result
        }

        let lines = normalizedRaw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var fields: [String: String] = [:]
        for line in lines where line.isEmpty == false {
            let cleanedLine = cleanedGeneratedLine(line)
            guard cleanedLine.isEmpty == false else { continue }
            if let (key, value) = parseFieldLine(cleanedLine), key != "summary" {
                fields[key] = value
            }
        }

        return makeGeneratedInterpretationResult(
            fields: fields,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        )
    }

    static func parseGeneratedInterpretationMetadataResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor] = [],
        excludingSemanticTagKeys: Set<String> = []
    ) -> InterpretationMetadataResult? {
        let normalizedRaw = GenerationStopPolicy.finalizedSummaryOutput(
            stripControlTokens(from: stripThinking(from: raw))
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
        if let result = parseJSONGeneratedInterpretationMetadataResult(
            normalizedRaw,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        ) {
            return result
        }

        let lines = normalizedRaw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var fields: [String: String] = [:]
        for line in lines where line.isEmpty == false {
            let cleanedLine = cleanedGeneratedLine(line)
            guard cleanedLine.isEmpty == false else { continue }
            if let (key, value) = parseFieldLine(cleanedLine), key != "summary" {
                fields[key] = value
            }
        }

        return makeGeneratedInterpretationMetadataResult(
            fields: fields,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        )
    }

    /// Redacted shape-only diagnostics for live parser failures. Values are
    /// deliberately omitted because they may contain private message data.
    static func interpretationMetadataParseStructure(_ raw: String) -> String {
        let normalizedRaw = GenerationStopPolicy.finalizedSummaryOutput(
            stripControlTokens(from: stripThinking(from: raw))
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
        let lines = normalizedRaw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var fields: [String: String] = [:]
        for line in lines where line.isEmpty == false {
            let cleanedLine = cleanedGeneratedLine(line)
            guard cleanedLine.isEmpty == false else { continue }
            if let (key, value) = parseFieldLine(cleanedLine), key != "summary" {
                fields[key] = value
            }
        }

        let purposeEntries = classificationCandidateEntries(fields["purposeCandidates"] ?? "")
        let purposePartCounts = purposeEntries.map {
            $0.split(separator: "|", omittingEmptySubsequences: false).count
        }
        let parsedPurposeCandidateCount = purposeEntries.reduce(into: 0) { count, entry in
            count += parseClassificationCandidates(entry)?.count ?? 0
        }
        let invalidNecessaryRuleCandidateCount = purposeEntries.flatMap {
            parseClassificationCandidates($0) ?? []
        }.filter {
            !MailClassificationResolver.hasNecessaryPurposeEvidence(
                MailPurposeCandidate($0.purpose, confidence: $0.confidence, ruleIDs: $0.ruleIDs)
            )
        }.count
        let hasDecodableJSONObject: Bool
        if let jsonText = jsonObjectSubstring(from: normalizedRaw),
           let data = jsonText.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            hasDecodableJSONObject = true
        } else {
            hasDecodableJSONObject = false
        }
        return [
            "chars=\(normalizedRaw.count)",
            "lines=\(lines.count)",
            "marker=\(raw.contains(GenerationStopPolicy.summaryEndMarker))",
            "jsonObject=\(hasDecodableJSONObject)",
            "fields=\(fields.keys.sorted().joined(separator: ","))",
            "purposeEntries=\(purposeEntries.count)",
            "purposePartCounts=\(purposePartCounts.map(String.init).joined(separator: ","))",
            "parsedPurposeCandidates=\(parsedPurposeCandidateCount)",
            "invalidNecessaryRuleCandidates=\(invalidNecessaryRuleCandidateCount)"
        ].joined(separator: " ")
    }

    private static func parseJSONGeneratedResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor]
    ) -> SummarizationResult? {
        guard let jsonText = jsonObjectSubstring(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        var fields: [String: String] = [:]
        var summarySource: String?
        for (label, value) in dictionary {
            guard let key = fieldKeyByCanonicalLabel[canonicalFieldLabel(label)],
                  let stringValue = stringValue(fromJSONValue: value, forFieldKey: key) else {
                continue
            }
            if key == "summary" {
                summarySource = stringValue
            } else {
                fields[key] = stringValue
            }
        }
        return makeGeneratedResult(
            fields: fields,
            summarySource: summarySource,
            customCategories: customCategories
        )
    }

    private static func parseJSONGeneratedInterpretationResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor],
        excludingSemanticTagKeys: Set<String>
    ) -> InterpretationResult? {
        guard let jsonText = jsonObjectSubstring(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        var fields: [String: String] = [:]
        for (label, value) in dictionary {
            guard let key = fieldKeyByCanonicalLabel[canonicalFieldLabel(label)],
                  key != "summary",
                  let stringValue = stringValue(fromJSONValue: value, forFieldKey: key) else {
                continue
            }
            fields[key] = stringValue
        }
        return makeGeneratedInterpretationResult(
            fields: fields,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        )
    }

    private static func parseJSONGeneratedInterpretationMetadataResult(
        _ raw: String,
        customCategories: [CustomMailCategoryDescriptor],
        excludingSemanticTagKeys: Set<String>
    ) -> InterpretationMetadataResult? {
        guard let jsonText = jsonObjectSubstring(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        var fields: [String: String] = [:]
        for (label, value) in dictionary {
            guard let key = fieldKeyByCanonicalLabel[canonicalFieldLabel(label)],
                  key != "summary",
                  let stringValue = stringValue(fromJSONValue: value, forFieldKey: key) else {
                continue
            }
            fields[key] = stringValue
        }
        return makeGeneratedInterpretationMetadataResult(
            fields: fields,
            customCategories: customCategories,
            excludingSemanticTagKeys: excludingSemanticTagKeys
        )
    }

    private static func jsonObjectSubstring(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else {
            return nil
        }
        return String(raw[start...end])
    }

    private static func stringValue(fromJSONValue value: Any) -> String? {
        switch value {
        case let value as String:
            return cleanedFieldValue(value)
        case let value as NSNumber:
            return value.stringValue
        case let value as Bool:
            return value ? "true" : "false"
        case let value as [Any]:
            return value.compactMap { Self.stringValue(fromJSONValue: $0) }.joined(separator: " || ")
        case let value as [String: Any]:
            if let rawCandidate = value["purpose"] ?? value["value"],
               let rawText = Self.stringValue(fromJSONValue: rawCandidate),
               let confidence = value["confidence"] ?? value["score"],
               let confidenceText = Self.stringValue(fromJSONValue: confidence) {
                let ruleIDsValue = value["ruleIDs"] ?? value["rule_ids"] ?? value["rules"]
                let ruleIDs: String
                if let values = ruleIDsValue as? [Any] {
                    ruleIDs = values.compactMap(Self.stringValue(fromJSONValue:)).joined(separator: ",")
                } else {
                    ruleIDs = ruleIDsValue.flatMap(Self.stringValue(fromJSONValue:)) ?? ""
                }
                return [rawText, confidenceText, ruleIDs]
                    .joined(separator: " | ")
            }
            let label = value["label"] ?? value["name"]
            guard let categoryText = label.flatMap(Self.stringValue(fromJSONValue:)) else {
                return nil
            }
            let confidence = value["confidence"] ?? value["score"]
            if let confidenceText = confidence.flatMap(Self.stringValue(fromJSONValue:)),
               confidenceText.isEmpty == false {
                return "\(categoryText)=\(confidenceText)"
            }
            return categoryText
        case _ as NSNull:
            return ""
        default:
            return nil
        }
    }

    private static func stringValue(fromJSONValue value: Any, forFieldKey key: String) -> String? {
        guard key == "semanticTags", let values = value as? [Any] else {
            return stringValue(fromJSONValue: value)
        }
        return values.compactMap(stringValue(fromJSONValue:)).joined(separator: " || ")
    }

    private static func parseFieldLine(_ line: String) -> (key: String, value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let rawLabel = String(line[..<colonIndex])
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = fieldKeyByCanonicalLabel[canonicalFieldLabel(rawLabel)] else {
            return nil
        }
        let rawValue = String(line[line.index(after: colonIndex)...])
        return (key, cleanedFieldValue(rawValue))
    }

    private static func canonicalFieldLabel(_ raw: String) -> String {
        var output = ""
        for scalar in raw.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    private static func cleanedGeneratedLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:[-*]\s+|\d+[\.)]\s+|>\s+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return trimmed
        }
        return regex.stringByReplacingMatches(
            in: trimmed,
            options: [],
            range: NSRange(location: 0, length: (trimmed as NSString).length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedFieldValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = value.first, first == "`" || first == "*" || first == "\"" || first == "'" {
            value.removeFirst()
        }
        while let last = value.last, last == "`" || last == "*" || last == "\"" || last == "'" {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let classificationSchemaVersion = "email-interpretation-v5-primary-purpose"

    /// The single strict Purpose parser shared by full summary,
    /// live interpretation, and historical metadata output.
    static func parseModelClassificationCandidates(
        fields: [String: String]
    ) -> ModelClassificationCandidates? {
        let required = ["purposeCandidates", "classificationEvidence"]
        guard required.allSatisfy({ fields[$0] != nil }),
              let purposes = parsePurposeCandidates(fields["purposeCandidates"] ?? "") else {
            return nil
        }

        let topLevelEvidence = parseStablePurposeRuleIDs(fields["classificationEvidence"] ?? "")
        var allRuleIDs = purposes.flatMap(\.ruleIDs)
        allRuleIDs.append(contentsOf: topLevelEvidence)
        let necessaryRuleIDs = Set(purposes.compactMap {
            MailClassificationResolver.necessaryPurposeRuleID(for: $0.purpose)
        })
        let extraRuleIDs = allRuleIDs.filter { !necessaryRuleIDs.contains($0) }
        let boundedRuleIDs = necessaryRuleIDs.union(
            boundedRuleIDSet(extraRuleIDs).sorted().prefix(
                max(0, MailClassificationJSON.maximumEvidenceRecords - necessaryRuleIDs.count)
            )
        )

        return ModelClassificationCandidates(
            purposes: purposes.map {
                MailPurposeCandidate(
                    $0.purpose,
                    confidence: $0.confidence,
                    ruleIDs: $0.ruleIDs.filter(boundedRuleIDs.contains)
                )
            },
            classifierVersion: classificationSchemaVersion
        )
    }

    private static func parsePurposeCandidates(_ raw: String) -> [MailPurposeCandidate]? {
        var merged: [MailPurpose: MailPurposeCandidate] = [:]
        for entry in classificationCandidateEntries(raw) {
            guard let parsedCandidates = parseClassificationCandidates(entry) else {
                continue
            }
            for parsed in parsedCandidates {
                let candidate = MailPurposeCandidate(
                    parsed.purpose,
                    confidence: parsed.confidence,
                    ruleIDs: parsed.ruleIDs
                )
                // A high-confidence purpose with an invented rule must cause
                // retry, not disappear and leave a weak sibling as uncertainty.
                guard MailClassificationResolver.hasNecessaryPurposeEvidence(candidate) else {
                    if candidate.confidence >= MailClassificationResolver.purposeThreshold {
                        return nil
                    }
                    continue
                }
                if let existing = merged[parsed.purpose] {
                    merged[parsed.purpose] = MailPurposeCandidate(
                        parsed.purpose,
                        confidence: max(existing.confidence, candidate.confidence),
                        ruleIDs: Array(Set(existing.ruleIDs + candidate.ruleIDs)).sorted()
                    )
                } else {
                    merged[parsed.purpose] = candidate
                }
            }
        }
        let candidates = Array(merged.values)
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return (MailPurpose.allCases.firstIndex(of: lhs.purpose) ?? .max)
                    < (MailPurpose.allCases.firstIndex(of: rhs.purpose) ?? .max)
            }
            .prefix(MailClassificationJSON.maximumPurposeCandidates)
            .map { $0 }
        return candidates.isEmpty ? nil : candidates
    }

    private static func parseClassificationCandidates(
        _ raw: String
    ) -> [(purpose: MailPurpose, confidence: Double, ruleIDs: [String])]? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var candidates: [(purpose: MailPurpose, confidence: Double, ruleIDs: [String])] = []
        var cursor = 0

        while cursor < parts.count {
            guard cursor + 2 < parts.count,
                  let purpose = MailPurpose(rawValue: parts[cursor]),
                  let confidence = strictConfidence(parts[cursor + 1]) else {
                return nil
            }

            var nextCandidateStart = cursor + 3
            while nextCandidateStart < parts.count {
                if nextCandidateStart + 1 < parts.count,
                   MailPurpose(rawValue: parts[nextCandidateStart]) != nil,
                   strictConfidence(parts[nextCandidateStart + 1]) != nil {
                    break
                }
                nextCandidateStart += 1
            }
            let ruleIDs = parseStablePurposeRuleIDs(
                parts[(cursor + 2)..<nextCandidateStart].joined(separator: ",")
            )
            candidates.append((purpose, confidence, ruleIDs))
            cursor = nextCandidateStart
        }

        return candidates
    }

    private static func classificationCandidateEntries(_ raw: String) -> [String] {
        raw.components(separatedBy: TriageVerdictParsing.arraySeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func strictConfidence(_ raw: String?) -> Double? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        // Qwen sometimes carries the adjacent semantic-tag confidence=value
        // spelling into Purpose candidates. Accept that exact label without
        // loosening numeric validation or discarding otherwise valid output.
        if raw.hasPrefix("confidence=") {
            raw = String(raw.dropFirst("confidence=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard raw.isEmpty == false,
              let value = Double(raw),
              value.isFinite,
              (0...1).contains(value) else {
            return nil
        }
        return value
    }

    private static func parseStablePurposeRuleIDs(_ raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(
            of: TriageVerdictParsing.arraySeparator,
            with: ","
        )
        return Array(Set(normalized
            .split(separator: ",")
            .map { strippingEchoedRuleLabel(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0.hasPrefix("purpose.") && MailClassificationRuleID.isValid($0) }))
            .sorted()
    }

    /// Qwen sometimes copies the contract's `rule-ids` placeholder, or the
    /// taxonomy's `rule purpose.…` wording, in front of a rule ID. Accept
    /// exactly those two spellings, once per ID; the remainder must still be a
    /// canonical rule ID, so validation is not loosened.
    private static let echoedRuleLabels = ["rule-ids=", "rule "]

    private static func strippingEchoedRuleLabel(_ value: String) -> String {
        for label in echoedRuleLabels where value.hasPrefix(label) {
            return String(value.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func boundedRuleIDSet(_ ruleIDs: [String]) -> Set<String> {
        Set(Array(Set(ruleIDs.filter(MailClassificationRuleID.isValid))).sorted()
            .prefix(MailClassificationJSON.maximumEvidenceRecords))
    }

    private static func makeGeneratedResult(
        fields: [String: String],
        summarySource: String?,
        customCategories: [CustomMailCategoryDescriptor]
    ) -> SummarizationResult? {
        let customKeys = CustomCategoryAssignmentPolicy.customCategoryKeys(
            fromField: fields["customCategories"],
            catalog: customCategories
        )
        guard let classificationCandidates = parseModelClassificationCandidates(fields: fields) else {
            return nil
        }
        guard let summarySource else { return nil }
        guard let summary = postProcess(summarySource) else { return nil }
        guard let triageVerdict = makeTriageVerdict(fields: fields) else {
            return nil
        }
        let semanticTagCandidates = SemanticTagCandidateParsing.candidates(from: fields)
        return SummarizationResult(
            summary: summary,
            classificationCandidates: classificationCandidates,
            triageVerdict: triageVerdict,
            customCategoryKeys: customKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    private static func makeGeneratedInterpretationResult(
        fields: [String: String],
        customCategories: [CustomMailCategoryDescriptor],
        excludingSemanticTagKeys: Set<String> = []
    ) -> InterpretationResult? {
        guard fields.isEmpty == false else { return nil }
        guard let classificationCandidates = parseModelClassificationCandidates(fields: fields) else {
            return nil
        }
        guard let triageVerdict = makeTriageVerdict(fields: fields) else {
            return nil
        }
        let customKeys = CustomCategoryAssignmentPolicy.customCategoryKeys(
            fromField: fields["customCategories"],
            catalog: customCategories
        )
        let semanticTagCandidates = SemanticTagCandidateParsing.candidates(from: fields).filter {
            !isExcludedIndividualName($0, excludingSemanticTagKeys: excludingSemanticTagKeys)
        }
        return InterpretationResult(
            classificationCandidates: classificationCandidates,
            triageVerdict: triageVerdict,
            meeting: MeetingCandidate.make(
                title: fields["meetingTitle"] ?? "",
                startText: fields["meetingStart"] ?? "",
                endText: fields["meetingEnd"] ?? "",
                timeZoneIdentifier: fields["meetingTimeZone"] ?? "",
                location: fields["meetingLocation"] ?? "",
                onlineMeetingURL: fields["meetingURL"] ?? ""
            ),
            customCategoryKeys: customKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    private static func makeGeneratedInterpretationMetadataResult(
        fields: [String: String],
        customCategories: [CustomMailCategoryDescriptor],
        excludingSemanticTagKeys: Set<String> = []
    ) -> InterpretationMetadataResult? {
        guard fields.isEmpty == false else { return nil }
        guard let classificationCandidates = parseModelClassificationCandidates(fields: fields) else {
            return nil
        }
        let customKeys = CustomCategoryAssignmentPolicy.customCategoryKeys(
            fromField: fields["customCategories"],
            catalog: customCategories
        )
        let semanticTagCandidates = SemanticTagCandidateParsing.candidates(from: fields).filter {
            !isExcludedIndividualName($0, excludingSemanticTagKeys: excludingSemanticTagKeys)
        }
        return InterpretationMetadataResult(
            classificationCandidates: classificationCandidates,
            customCategoryKeys: customKeys,
            semanticTagCandidates: semanticTagCandidates
        )
    }

    private static func isExcludedIndividualName(
        _ candidate: SemanticTagCandidate,
        excludingSemanticTagKeys: Set<String>
    ) -> Bool {
        ([candidate.preferredLabel] + candidate.sourceForms).contains { surface in
            excludingSemanticTagKeys.contains(SemanticTagNormalizer.aliasKey(surface))
        }
    }

    public static func conservativeInterpretationFallback(
        bodyText: String,
        senderName: String,
        subject: String
    ) -> InterpretationResult {
        let verdict = TriageVerdict(
            isActionable: false,
            requiresConfirmation: false,
            confidence: 0.0,
            extractionVersion: "\(extractionVersion)-conservative-fallback"
        )
        return InterpretationResult(classificationCandidates: .empty, triageVerdict: verdict)
    }

    public static func conservativeInterpretationMetadataFallback(
        bodyText: String,
        senderName: String,
        subject: String
    ) -> InterpretationMetadataResult {
        InterpretationMetadataResult(
            classificationCandidates: .empty
        )
    }

    /// Builds a triage verdict from the MLX line-prefix output. Returns
    /// nil unless both required boolean flags are present and parseable.
    /// When a flag is true and the matching structured block is populated,
    /// builds the corresponding `ActionSpec` / `AcknowledgementSpec` via the
    /// shared factories so the storage shape matches the Apple Foundation path
    /// exactly.
    static func makeTriageVerdict(fields: [String: String]) -> TriageVerdict? {
        // Missing or malformed flags are a contract failure, not evidence that
        // no reply is needed. Let the interpreter's bounded repair handle them.
        guard let isActionable = parseBoolean(fields["isActionable"]),
              let requiresConfirmation = parseBoolean(fields["requiresConfirmation"]) else {
            return nil
        }

        let action: ActionSpec? = isActionable
            ? ActionSpec.make(
                summary: fields["actionSummary"] ?? "",
                kind: fields["actionKind"] ?? "",
                directedAt: fields["actionDirectedAt"] ?? "",
                deadlineText: fields["actionDeadline"] ?? "",
                deadlineKind: fields["actionDeadlineKind"] ?? "",
                decisionInputs: TriageVerdictParsing.splitArrayString(fields["actionInputs"] ?? "")
            )
            : nil

        let acknowledgement: AcknowledgementSpec? = requiresConfirmation
            ? AcknowledgementSpec.make(
                summary: fields["acknowledgementSummary"] ?? "",
                signalKind: fields["acknowledgementSignalKind"] ?? "",
                deadlineText: fields["acknowledgementDeadline"] ?? "",
                deadlineKind: fields["acknowledgementDeadlineKind"] ?? "",
                materialFacts: TriageVerdictParsing.splitArrayString(fields["acknowledgementFacts"] ?? "")
            )
            : nil

        return TriageVerdict(
            isActionable: isActionable,
            requiresConfirmation: requiresConfirmation,
            confidence: 0.5,
            action: action,
            acknowledgement: acknowledgement,
            extractionVersion: extractionVersion
        )
    }

    private static func parseBoolean(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let normalized = cleanedFieldValue(raw)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = normalized
            .split { !$0.isLetter && !$0.isNumber }
            .first
            .map(String.init)

        switch token {
        case "true", "yes", "1", "y": return true
        case "false", "no", "0", "n": return false
        default: return nil
        }
    }

    private static func stripThinking(from raw: String) -> String {
        var working = raw

        let closedPattern = #"(?s)<think(?:ing)?>(.*?)</think(?:ing)?>"#
        if let regex = try? NSRegularExpression(pattern: closedPattern, options: []) {
            working = regex.stringByReplacingMatches(
                in: working,
                options: [],
                range: NSRange(location: 0, length: (working as NSString).length),
                withTemplate: ""
            )
        }

        if let openRange = working.range(of: #"<think(?:ing)?>"#, options: .regularExpression) {
            let prefix = String(working[..<openRange.lowerBound])
            let suffix = String(working[openRange.upperBound...])
            if let answerRange = firstStructuredFieldRange(in: suffix) {
                working = String(suffix[answerRange.lowerBound...])
            } else {
                working = prefix
            }
        }

        let closePattern = #"</think(?:ing)?>"#
        while let closeRange = working.range(of: closePattern, options: .regularExpression) {
            let suffix = String(working[closeRange.upperBound...])
            if suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                working.removeSubrange(closeRange)
            } else {
                working = suffix
            }
        }

        let tagPattern = #"</?think(?:ing)?>"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: []) else {
            return working
        }
        return regex.stringByReplacingMatches(
            in: working,
            options: [],
            range: NSRange(location: 0, length: (working as NSString).length),
            withTemplate: ""
        )
    }

    private static func firstStructuredFieldRange(in raw: String) -> Range<String.Index>? {
        let pattern = #"(?im)^\s*(?:[-*]\s+|\d+[\.)]\s+)?(?:\*\*)?\s*(?:purpose\s*candidates|classification\s*evidence|headline|intent|intents|project\s*labels?|projects|team\s*labels?|teams|topic\s*labels?|topics|is\s*actionable|requires\s*confirmation|requires\s*acknowledg(?:e)?ment|needs\s*acknowledg(?:e)?ment|summary)\s*(?:\*\*)?\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsRange = NSRange(location: 0, length: (raw as NSString).length)
        guard let match = regex.firstMatch(in: raw, options: [], range: nsRange) else {
            return nil
        }
        return Range(match.range, in: raw)
    }

    private static func stripControlTokens(from raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                var line = String(rawLine)
                for token in [
                    "<|im_start|>assistant",
                    "<|im_start|>",
                    "<|im_end|>",
                    "<|endoftext|>",
                    "</s>"
                ] {
                    line = line.replacingOccurrences(
                        of: token,
                        with: "",
                        options: [.caseInsensitive]
                    )
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                if lower == "/no_think" || lower == "assistant" { return nil }
                if lower.hasPrefix("```") { return nil }
                return line
            }
            .joined(separator: "\n")
    }

    /// Trims and cleans LLM output: strips stray quotes and extra whitespace
    /// while preserving the model's full proportional summary.
    static func postProcess(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common lead-ins the model might produce
        let leadIns = ["Summary:", "summary:", "Here is", "Here's"]
        for prefix in leadIns {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Strip surrounding quotes
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count > 2 {
            s = String(s.dropFirst().dropLast())
        }

        guard !looksLikeReasoningScratchpad(s) else { return nil }
        return SummaryTextSanitizer.cleaned(s)
    }

    private static func looksLikeReasoningScratchpad(_ raw: String) -> Bool {
        let text = raw
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return false }
        if text.contains("<think") || text.contains("</think") {
            return true
        }

        let openingCues = [
            "okay, let me",
            "let me try",
            "i need to",
            "i should",
            "first, i need",
            "alright, putting it all together"
        ]
        if openingCues.contains(where: { text.hasPrefix($0) }) {
            return true
        }

        if text.contains("existing headline")
            || text.contains("existing action summary")
            || text.contains("existing intents")
            || text.contains("provided guidelines") {
            return true
        }

        let reasoningCues = [
            "the user wants",
            "the summary needs",
            "the prompt asks",
            "the anchor body",
            "the category is",
            "let me check",
            "source again",
            "putting it all together"
        ]
        let cueCount = reasoningCues.reduce(into: 0) { count, cue in
            if text.contains(cue) {
                count += 1
            }
        }
        return cueCount >= 2
    }
}

enum SummaryIdentityValidator {
    static func validatedSummary(
        _ result: SummarizationResult,
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) -> SummarizationResult {
        let evidence = summaryEvidence(bodyText: bodyText, subject: subject, context: context)
        let repaired = repairAccountOwnerReferences(
            in: repairAmbiguousPossessives(
                in: result.summary,
                evidence: evidence,
                identity: context?.userIdentity
            ),
            evidence: evidence
        )
        if violatesIncomingAuthorship(repaired, direction: context?.anchorDirection) {
            return result.replacingSummary(
                conservativeSummaryFallback(
                    senderName: senderName,
                    subject: subject,
                    context: context
                )
            )
        }
        return result.replacingSummary(repaired)
    }

    static func validatedOrientation(
        _ result: ContextOrientationResult,
        input: ContextOrientationInput
    ) -> ContextOrientationResult {
        let evidence = orientationEvidence(input: input)
        let repaired = repairAmbiguousPossessives(
            in: result.paragraph,
            evidence: evidence,
            identity: input.userIdentity
        )
        if violatesIncomingAuthorship(repaired, direction: input.anchorDirection) {
            return ContextOrientationResult(
                paragraph: conservativeOrientationFallback(input: input),
                citations: result.citations
            )
        }
        if input.subject.correspondentRelationship != nil,
           violatesCorrespondentRelationshipFraming(repaired) {
            return ContextOrientationResult(
                paragraph: conservativeOrientationFallback(input: input),
                citations: result.citations
            )
        }
        return ContextOrientationResult(paragraph: repaired, citations: result.citations)
    }

    static func fallbackOrientation(input: ContextOrientationInput) -> ContextOrientationResult {
        ContextOrientationResult(paragraph: conservativeOrientationFallback(input: input))
    }

    private static func summaryEvidence(
        bodyText: String,
        subject: String,
        context: SummarizationContext?
    ) -> String {
        var parts = [bodyText, subject]
        if let context {
            for item in context.connectedItems {
                parts.append(contentsOf: [item.senderName, item.subject, item.excerpt])
            }
            parts.append(contentsOf: context.satelliteEvidence.map(\.text))
            for visual in context.visualAttachmentSummaries {
                parts.append(contentsOf: [visual.filename, visual.summary])
            }
            for attachment in context.textAttachmentEvidence {
                parts.append(contentsOf: [attachment.filename, attachment.text])
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func orientationEvidence(input: ContextOrientationInput) -> String {
        var parts = [
            input.anchorSenderName,
            input.anchorSubject,
            input.bodyExcerpt
        ]
        for chunk in input.ownExcerpts {
            parts.append(chunk.excerpt)
        }
        for item in input.neighbours + input.threadSiblings {
            parts.append(contentsOf: [item.senderName, item.subject, item.excerpt])
        }
        return parts.joined(separator: "\n")
    }

    private static func repairAmbiguousPossessives(
        in text: String,
        evidence: String,
        identity: SummarizationUserIdentity?
    ) -> String {
        var repaired = text
        for name in sameFirstNameThirdPartyNames(identity: identity, evidence: evidence) {
            for phrase in possessivePhraseCandidates(name: name, evidence: evidence) {
                let possessive = possessiveName(name)
                repaired = replaceYourPhrase(in: repaired, phrase: phrase, replacement: "\(possessive) \(phrase)")
            }
        }
        return repaired
    }

    private static func repairAccountOwnerReferences(in text: String, evidence: String) -> String {
        var repaired = text
        repaired = replaceGenericAccountOwnerAppositives(in: repaired)
        if !sourceEvidenceMentionsAccountOwner(evidence) {
            repaired = replaceAccountOwnerPossessives(in: repaired)
            repaired = replaceAccountOwnerNouns(in: repaired)
        }
        repaired = repairSecondPersonVerbAgreement(in: repaired)
        return repaired
    }

    private static func sourceEvidenceMentionsAccountOwner(_ evidence: String) -> Bool {
        evidence.range(of: "account owner", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func replaceAccountOwnerPossessives(in text: String) -> String {
        replaceMatches(
            in: text,
            pattern: #"\b(?:the\s+)?account owner(?:'s|’s)\b"#,
            options: [.caseInsensitive]
        ) { match in
            pronounCapitalized(for: match, lower: "your", upper: "Your")
        }
    }

    private static func replaceGenericAccountOwnerAppositives(in text: String) -> String {
        replaceMatches(
            in: text,
            pattern: #"\b(?:the\s+)?account owner\s*,\s*[^\n,;:!?()]{2,80},"#,
            options: [.caseInsensitive]
        ) { match in
            pronounCapitalized(for: match, lower: "you", upper: "You")
        }
    }

    private static func replaceAccountOwnerNouns(in text: String) -> String {
        replaceMatches(
            in: text,
            pattern: #"\b(?:the\s+)?account owner\b(?!\s+(?:for|at|of|in|on|from|with|under|within|over|as)\b)"#,
            options: [.caseInsensitive]
        ) { match in
            pronounCapitalized(for: match, lower: "you", upper: "You")
        }
    }

    private static func repairSecondPersonVerbAgreement(in text: String) -> String {
        [
            (#"\b([Yy])ou prefers\b"#, "$1ou prefer"),
            (#"\b([Yy])ou wants\b"#, "$1ou want"),
            (#"\b([Yy])ou needs\b"#, "$1ou need"),
            (#"\b([Yy])ou has\b"#, "$1ou have"),
            (#"\b([Yy])ou is\b"#, "$1ou are"),
            (#"\b([Yy])ou was\b"#, "$1ou were"),
            (#"\b([Yy])ou asks\b"#, "$1ou ask"),
            (#"\b([Yy])ou says\b"#, "$1ou say"),
            (#"\b([Yy])ou receives\b"#, "$1ou receive"),
            (#"\b([Yy])ou reviews\b"#, "$1ou review"),
            (#"\b([Yy])ou approves\b"#, "$1ou approve")
        ].reduce(text) { partial, repair in
            replaceRegex(repair.0, in: partial, withTemplate: repair.1, options: [.caseInsensitive])
        }
    }

    private static func pronounCapitalized(for match: String, lower: String, upper: String) -> String {
        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return lower }
        return first.isUppercase ? upper : lower
    }

    private static func violatesIncomingAuthorship(
        _ text: String,
        direction: SummarizationContext.AnchorDirection?
    ) -> Bool {
        guard direction == .incoming else { return false }
        let pattern = #"\byou\s+(sent|wrote|asked|requested|told|said|shared|attached|provided|submitted|replied|followed\s+up)\b"#
        return regex(pattern, in: text, options: [.caseInsensitive]).isEmpty == false
    }

    private static func violatesCorrespondentRelationshipFraming(_ text: String) -> Bool {
        let pattern = #"^\s*(this|the|a)\s+(latest\s+)?(message|email|note|item)\b"#
        return regex(pattern, in: text, options: [.caseInsensitive]).isEmpty == false
    }

    fileprivate static func conservativeSummaryFallback(
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        includeAmbiguityNotice: Bool = true
    ) -> String {
        let subjectText = clean(subject, limit: 120)
        let ambiguityNotice = includeAmbiguityNotice
            ? " Names are kept explicit because the source identity evidence is ambiguous."
            : ""
        switch context?.anchorDirection {
        case .some(.outgoing):
            let recipients = recipientList(context?.anchorRecipients?.to ?? [])
            return "You sent this to \(recipients) about \(subjectText).\(ambiguityNotice)"
        case .some(.incoming), .none:
            let owner = ownerReference(context?.userIdentity)
            return "\(clean(senderName, limit: 80)) sent this to \(owner) about \(subjectText).\(ambiguityNotice)"
        }
    }

    private static func conservativeOrientationFallback(input: ContextOrientationInput) -> String {
        if let relationship = input.subject.correspondentRelationship {
            let name = relationship.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? relationship.email
                : relationship.displayName
            let total = relationship.correspondentAuthoredCount
                + relationship.accountOwnerAuthoredCount
                + relationship.includedCount
            var parts = [
                "The available correspondence history with \(clean(name, limit: 80)) spans \(total) record\(total == 1 ? "" : "s") across \(relationship.threadCount) thread\(relationship.threadCount == 1 ? "" : "s")."
            ]
            if !relationship.tagSignals.isEmpty {
                parts.append("The visible tag signals include \(relationship.tagSignals.prefix(3).joined(separator: ", ")).")
            }
            if !input.memoryNotes.isEmpty {
                parts.append("Correspondent memories provide additional relationship context.")
            }
            parts.append("Names are kept explicit because the source identity evidence is ambiguous.")
            return parts.joined(separator: " ")
        }
        let subject = clean(input.anchorSubject, limit: 120)
        let recipients = recipientList(input.anchorRecipients?.to ?? [])
        switch input.anchorDirection {
        case .some(.outgoing):
            return "You sent this to \(recipients) about \(subject). Related sent and received items provide the detailed background, and names are kept explicit because the source identity evidence is ambiguous."
        case .some(.incoming), .none:
            let owner = input.userIdentity == nil
                ? recipientList(input.anchorRecipients?.to ?? [])
                : ownerReference(input.userIdentity)
            return "\(clean(input.anchorSenderName, limit: 80)) sent this to \(owner) about \(subject). Related sent and received items provide the detailed background, and names are kept explicit because the source identity evidence is ambiguous."
        }
    }

    private static func sameFirstNameThirdPartyNames(
        identity: SummarizationUserIdentity?,
        evidence: String
    ) -> [String] {
        guard let identity,
              let first = identity.displayName
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init),
              !first.isEmpty else {
            return []
        }
        let owner = normalizedName(identity.displayName)
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: first) + #"\s+[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,2}\b"#
        var seen = Set<String>()
        return regex(pattern, in: evidence).compactMap { match in
            let candidate = normalizeSpaces(match)
            guard normalizedName(candidate) != owner,
                  seen.insert(candidate.lowercased()).inserted else {
                return nil
            }
            return candidate
        }
    }

    private static func possessivePhraseCandidates(name: String, evidence: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b"# + escaped + #"(?:'s|’s)\s+([A-Za-z][A-Za-z0-9'’.-]*(?:\s+[A-Za-z][A-Za-z0-9'’.-]*){0,4})"#
        var candidates: [String] = []
        var seen = Set<String>()
        for match in captureGroup(pattern, group: 1, in: evidence) {
            let tokens = match
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
            let useful = tokens.prefix { token in
                !possessiveStopWords.contains(token.lowercased())
            }
            let phraseTokens = Array(useful.prefix(3))
            for width in stride(from: phraseTokens.count, through: 1, by: -1) {
                let phrase = phraseTokens.prefix(width).joined(separator: " ")
                appendCandidate(phrase, seen: &seen, candidates: &candidates)
            }
            if let last = phraseTokens.last, phraseTokens.count > 1 {
                appendCandidate(last, seen: &seen, candidates: &candidates)
            }
        }
        return candidates
    }

    private static func replaceYourPhrase(
        in text: String,
        phrase: String,
        replacement: String
    ) -> String {
        let pattern = #"\byour\s+"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        for match in matches.reversed() {
            let original = ns.substring(with: match.range)
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: transform(original)
            )
        }
        return result
    }

    private static func replaceRegex(
        _ pattern: String,
        in text: String,
        withTemplate template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func appendCandidate(
        _ phrase: String,
        seen: inout Set<String>,
        candidates: inout [String]
    ) {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 2, seen.insert(cleaned.lowercased()).inserted else { return }
        candidates.append(cleaned)
    }

    private static func regex(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) }
    }

    private static func captureGroup(_ pattern: String, group: Int, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ).compactMap { match in
            guard match.numberOfRanges > group else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    private static func possessiveName(_ name: String) -> String {
        "\(name)'s"
    }

    private static func normalizedName(_ name: String) -> String {
        normalizeSpaces(name).lowercased()
    }

    private static func normalizeSpaces(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ownerReference(_ identity: SummarizationUserIdentity?) -> String {
        if let displayName = identity?.displayName, !displayName.isEmpty {
            return displayName
        }
        if let address = identity?.primaryEmailAddress, !address.isEmpty {
            return address
        }
        return "you"
    }

    private static func recipientList(_ recipients: [SummarizationContext.Recipient]) -> String {
        let values = recipients
            .prefix(4)
            .map { recipient in
                recipient.displayName?.isEmpty == false
                    ? recipient.displayName!
                    : recipient.address
            }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "the listed recipients" : values.joined(separator: ", ")
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = normalizeSpaces(text)
        guard collapsed.count > limit else { return collapsed.isEmpty ? "(no subject)" : collapsed }
        return TranslationGlossaryProtection.markerSafePrefix(collapsed, limit: max(0, limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static let possessiveStopWords: Set<String> = [
        "before", "after", "because", "since", "when", "while", "where",
        "for", "from", "with", "without", "about", "into", "onto",
        "and", "or", "but", "the", "a", "an", "to", "of", "in", "on", "by"
    ]
}
