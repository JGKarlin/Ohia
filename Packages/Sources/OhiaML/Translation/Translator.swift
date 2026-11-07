// Translator.swift
// On-demand, full-fidelity translation of an email body into the user's chosen
// summary/translation language, produced by the local generative (Qwen) model.
// Unlike summarization, translation never compresses: it reproduces the whole
// message faithfully in the target language. Generation is user-initiated, so it
// runs at interactive priority; the surrounding `TranslationService` caches the
// result so a given (message, target language) pair is generated once.

import Foundation
import OhiaCore

public struct TranslationResult: Sendable, Equatable {
    /// The fully translated body text, in the target language.
    public let text: String
    /// Canonical identifier of the language the body was translated into.
    public let targetLanguageIdentifier: String
    /// BCP-47 base code of the detected source language, when known. Used only
    /// for the two-column header autonym; never affects generation.
    public let detectedSourceLanguageCode: String?

    public init(
        text: String,
        targetLanguageIdentifier: String,
        detectedSourceLanguageCode: String?
    ) {
        self.text = text
        self.targetLanguageIdentifier = targetLanguageIdentifier
        self.detectedSourceLanguageCode = detectedSourceLanguageCode
    }
}

public enum TranslationError: Error, Sendable {
    case empty
    case modelUnavailable(String)
    /// The language pairing is supported but not downloaded yet. Distinct from
    /// `modelUnavailable` so the UI can offer an in-app download (Apple's
    /// `prepareTranslation()`) rather than just reporting a dead end.
    case languagesNotInstalled(String)
    case glossaryProtectionFailed
    case underlying(String)
}

/// A surfaced translation failure: the displayable reason plus whether it can be
/// resolved by downloading the language pairing in-app (Apple's
/// `prepareTranslation()`), which lets the UI offer a download affordance rather
/// than a dead-end message.
public struct TranslationFailure: Sendable, Equatable {
    public let message: String
    public let requiresLanguageDownload: Bool

    public init(message: String, requiresLanguageDownload: Bool) {
        self.message = message
        self.requiresLanguageDownload = requiresLanguageDownload
    }
}

/// One evidenced terminology pin: how a proper noun / name from the message
/// should be rendered in the target language, as found in the user's real
/// target-language correspondence. Pins close the gap between a model's guessed
/// rendering of a name and the established, correct one.
public struct TranslationGlossaryEntry: Sendable, Equatable {
    /// Stable identity of the one user-wide canonical dyad.
    public let pairID: UUID
    /// The term as it appears in the source message.
    public let sourceTerm: String
    /// The established target-language rendering, evidenced in the corpus.
    public let targetRendering: String
    /// Prompt authority derived from confirmation or deterministic confidence.
    public let authority: TranslationGlossaryPolicy.Authority

    public init(
        pairID: UUID,
        sourceTerm: String,
        targetRendering: String,
        authority: TranslationGlossaryPolicy.Authority
    ) {
        self.pairID = pairID
        self.sourceTerm = sourceTerm
        self.targetRendering = targetRendering
        self.authority = authority
    }

    /// Transitional convenience for existing non-translation prompt tests.
    /// Source-aware providers always use the canonical-pair initializer above.
    public init(sourceTerm: String, targetRendering: String) {
        self.init(
            pairID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            sourceTerm: sourceTerm,
            targetRendering: targetRendering,
            authority: .exact
        )
    }
}

/// Optional, engine-agnostic grounding for a translation. TranslationService
/// consumes exact dyads for every engine; context-aware engines additionally
/// consume provisional dyads and style rules in their prompts.
public struct TranslationContext: Sendable, Equatable {
    /// Confirmed or high-confidence terminology that receives marker protection.
    public let exactGlossary: [TranslationGlossaryEntry]
    /// Applicable inferred terminology that remains advisory.
    public let provisionalGlossary: [TranslationGlossaryEntry]
    /// Free-form style/preference rules (e.g. register, what to leave
    /// untranslated), distilled from the user's translation history.
    public let rules: [String]
    /// Deterministic cache identity for every selected dyad and style rule.
    public let fingerprint: String

    public init(
        exactGlossary: [TranslationGlossaryEntry],
        provisionalGlossary: [TranslationGlossaryEntry],
        rules: [String] = []
    ) {
        self.exactGlossary = exactGlossary.filter { $0.authority == .exact }
        self.provisionalGlossary = provisionalGlossary.filter { $0.authority == .provisional }
        self.rules = rules
        self.fingerprint = Self.makeFingerprint(
            exactGlossary: self.exactGlossary,
            provisionalGlossary: self.provisionalGlossary,
            rules: rules
        )
    }

    public var isEmpty: Bool { exactGlossary.isEmpty && provisionalGlossary.isEmpty && rules.isEmpty }

    private static func makeFingerprint(
        exactGlossary: [TranslationGlossaryEntry],
        provisionalGlossary: [TranslationGlossaryEntry],
        rules: [String]
    ) -> String {
        let exact = exactGlossary.flatMap {
            ["exact", $0.pairID.uuidString, $0.sourceTerm, $0.targetRendering]
        }
        let provisional = provisionalGlossary.flatMap {
            ["provisional", $0.pairID.uuidString, $0.sourceTerm, $0.targetRendering]
        }
        let fields = exact + provisional + rules.flatMap { ["rule", $0] }
        let serialized = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return stableHash(serialized)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Supplies applicable user-wide canonical dyads plus account-scoped target-
/// language style rules. Lookup is source-aware and best-effort: it returns
/// `nil` when no useful grounding is available.
public protocol TranslationContextProviding: Sendable {
    /// Source-aware generation lookup. Glossary scope is user-wide; an optional
    /// account selects only style rules for the current target language.
    func translationContext(
        forAccount accountID: UUID?,
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguage: SummarizationTargetLanguage
    ) -> TranslationContext?

    func translationContext(
        forMessage messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        sourceLanguageCode: String?
    ) async -> TranslationContext?
}

public extension TranslationContextProviding {
    /// Message-only providers can omit this generation-surface lookup.
    func translationContext(
        forAccount accountID: UUID?,
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguage: SummarizationTargetLanguage
    ) -> TranslationContext? {
        nil
    }
}

public protocol Translating: Sendable {
    /// Freezes any live routing decision for one service request. Stateless
    /// translators return themselves; routers return the backend selected at
    /// the instant the request begins.
    func requestSnapshot() -> any Translating

    /// Stable identifier for the engine behind this translator, folded into the
    /// translation cache fingerprint so switching engines never serves another
    /// engine's cached output. Defaults to "" for engine-agnostic conformers
    /// (e.g. test stubs), which keeps their cache behaviour unchanged.
    var cacheTag: String { get }

    /// Whether this engine consumes provisional dyads and style rules from a
    /// `TranslationContext`. Exact dyads are enforced by TranslationService for
    /// engines that return false. Defaults to false.
    var usesContext: Bool { get }

    /// Translates `bodyText` into `targetLanguage`, or returns `nil` when the
    /// model produces no usable output. Throws on engine/availability failures
    /// so the service can surface a specific reason.
    func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?
    ) async throws -> TranslationResult?

    /// Context-aware overload. The default ignores `context` and calls the
    /// context-free method, so existing conformers (Apple path, test stubs) need
    /// no changes; only context-aware engines override it.
    func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?,
        context: TranslationContext?
    ) async throws -> TranslationResult?
}

public extension Translating {
    func requestSnapshot() -> any Translating { self }
    var cacheTag: String { "" }
    var usesContext: Bool { false }

    func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?,
        context: TranslationContext?
    ) async throws -> TranslationResult? {
        try await translate(
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            detectedSourceLanguageCode: detectedSourceLanguageCode
        )
    }
}

// MARK: - Prompt

public enum TranslationPromptBuilder {
    /// Upper bound on body characters fed to the model in one pass. Bodies are
    /// capped here so a single generation stays within a sane token budget; the
    /// original always remains visible alongside the translation.
    public static let bodyCharacterLimit = 6_000

    /// Upper bound on glossary pins injected into one prompt. Caps the suffix
    /// growth and keeps the model's attention on a focused, high-value set.
    public static let maxGlossaryEntries = 20

    public static let instructions = """
    You are a professional translator. Translate the message below into the target language named here, then stop.

    Rules:
    - Output only the translation. No preamble, no notes, no explanations, no labels, and no quotation marks wrapping the whole text.
    - Translate the entire message faithfully and completely. Do not summarize, paraphrase loosely, shorten, or omit anything.
    - Preserve the original structure: keep paragraph breaks and line breaks, list items, and the order of the content.
    - Keep proper names, email addresses, URLs, phone numbers, numbers, dates, currency amounts, and code or identifiers exactly as written; translate only the surrounding prose.
    - If an "Established terminology" list is provided below, render each listed term using exactly its given rendering — these are the correct, evidenced forms and override your own guess. Never echo the list itself.
    - If "Translation preferences" are provided below, follow them (register, what to leave untranslated, etc.). Never echo them.
    - If a passage is already in the target language, reproduce it unchanged.
    - Do not include reasoning, analysis, planning, scratchpad text, or <think> tags. If the model supports thinking controls, disable thinking.
    """

    public static func promptParts(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        glossary: [TranslationGlossaryEntry] = [],
        rules: [String] = [],
        exactMappings: [TranslationGlossaryMarkerMapping] = [],
        provisionalGlossary: [TranslationGlossaryEntry] = [],
        markerRetryInstruction: String? = nil
    ) -> PrefixCachedPrompt {
        // The instruction block + target language are identical across messages
        // for a given target, so they form the cacheable prefix; only the body
        // suffix changes. The cache key carries the target identifier so a
        // language switch never reuses a stale KV prefix.
        let prefix = [
            instructions,
            "",
            "Target language: \(targetLanguage.promptDescription)",
            ""
        ].joined(separator: "\n") + "\n"

        let body = neutralizeControlTokens(String(bodyText.prefix(bodyCharacterLimit)))
        var suffixLines: [String] = []
        if let exactBlock = exactMarkerBlock(exactMappings) {
            suffixLines.append(exactBlock)
            suffixLines.append("")
        } else if let glossaryBlock = glossaryBlock(glossary) {
            suffixLines.append(glossaryBlock)
            suffixLines.append("")
        }
        if let provisionalBlock = provisionalGlossaryBlock(provisionalGlossary) {
            suffixLines.append(provisionalBlock)
            suffixLines.append("")
        }
        if let rulesBlock = rulesBlock(rules) {
            suffixLines.append(rulesBlock)
            suffixLines.append("")
        }
        if let markerRetryInstruction {
            suffixLines.append(markerRetryInstruction)
            suffixLines.append("")
        }
        suffixLines.append(contentsOf: [
            "Message to translate:",
            body,
            "",
            "/no_think"
        ])

        return PrefixCachedPrompt(
            cacheKey: "email-translation-v1:\(targetLanguage.identifier)",
            prefix: prefix,
            suffix: suffixLines.joined(separator: "\n")
        )
    }

    /// Renders the evidenced-terminology pins as a bounded, sanitized reference
    /// block, or `nil` when there is nothing usable. Each term/rendering is run
    /// through the control-token sanitizer so corpus-sourced text can't forge a
    /// role turn, and entries with an empty side are dropped.
    static func glossaryBlock(_ glossary: [TranslationGlossaryEntry]) -> String? {
        let pins: [String] = glossary.prefix(maxGlossaryEntries).compactMap { entry in
            let term = neutralizeControlTokens(entry.sourceTerm).trimmingCharacters(in: .whitespacesAndNewlines)
            let rendering = neutralizeControlTokens(entry.targetRendering).trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(term) => \(rendering)"
        }
        guard pins.isEmpty == false else { return nil }
        return (["Established terminology (render exactly as shown, do not output this list):"] + pins)
            .joined(separator: "\n")
    }

    static func exactMarkerBlock(_ mappings: [TranslationGlossaryMarkerMapping]) -> String? {
        // Every protected occurrence needs an explicit rendering map. Unlike
        // advisory context, exact mappings cannot be truncated after the source
        // has already been replaced with opaque markers.
        let lines = mappings.compactMap { mapping -> String? in
            let marker = neutralizeControlTokens(mapping.marker)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rendering = neutralizeControlTokens(mapping.targetRendering)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard marker.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(marker) => \(rendering)"
        }
        guard lines.isEmpty == false else { return nil }
        return ([
            "Protected exact terminology (copy every marker unchanged into the translated position; never translate, alter, split, or omit a marker):"
        ] + lines).joined(separator: "\n")
    }

    static func omissionTolerantExactMarkerBlock(
        _ mappings: [TranslationGlossaryMarkerMapping]
    ) -> String? {
        let lines = mappings.compactMap { mapping -> String? in
            let marker = neutralizeControlTokens(mapping.marker)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rendering = neutralizeControlTokens(mapping.targetRendering)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard marker.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(marker) => \(rendering)"
        }
        guard lines.isEmpty == false else { return nil }
        return ([
            "Protected exact terminology (when the summary includes a protected fact, copy its marker unchanged; a fact the summary legitimately omits needs no marker):"
        ] + lines).joined(separator: "\n")
    }

    static func provisionalGlossaryBlock(_ glossary: [TranslationGlossaryEntry]) -> String? {
        let lines = glossary.lazy
            .filter { $0.authority == .provisional }
            .prefix(maxGlossaryEntries)
            .compactMap { entry -> String? in
            let term = neutralizeControlTokens(entry.sourceTerm)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rendering = neutralizeControlTokens(entry.targetRendering)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(term) ~> \(rendering)"
        }
        guard lines.isEmpty == false else { return nil }
        return ([
            "Provisional terminology (advisory only; use when context supports it, and do not present it as a confirmed fact):"
        ] + lines).joined(separator: "\n")
    }

    /// Renders distilled style/preference rules as a bounded, sanitized block, or
    /// `nil` when empty. Capped at the same count as glossary pins.
    static func rulesBlock(_ rules: [String]) -> String? {
        let lines: [String] = rules.prefix(maxGlossaryEntries).compactMap { rule in
            let text = neutralizeControlTokens(rule).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "- \(text)"
        }
        guard lines.isEmpty == false else { return nil }
        return (["Translation preferences (follow, do not output this list):"] + lines)
            .joined(separator: "\n")
    }

    /// Generous token budget scaled to the (capped) input length so the full
    /// translation fits. Translation is roughly token-parity with the source,
    /// with headroom for languages that expand (e.g. CJK → English).
    public static func maxTokens(forBodyCharacterCount count: Int) -> Int {
        let capped = min(count, bodyCharacterLimit)
        let estimate = Int((Double(capped) / 2.2).rounded(.up)) + 256
        return min(2_600, max(640, estimate))
    }

    /// Defuses chat-template control tokens that could be smuggled in through
    /// sender-controlled body text and forge a role turn in the prompt. Mirrors
    /// the attachment-summary input sanitizer.
    static func neutralizeControlTokens(_ text: String) -> String {
        var sanitized = text
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|>]*\|>"#) {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: " "
            )
        }
        sanitized = sanitized
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "|>", with: "| >")
        return sanitized
    }
}

public enum TranslationPostProcessor {
    /// Cleans raw model output into a displayable translation: strips thinking
    /// blocks and control tokens, removes a leading `Translation:` label and
    /// whole-text wrapping quotes, and trims. Returns `nil` when nothing usable
    /// remains.
    public static func clean(_ raw: String) -> String? {
        var s = stripControlTokens(stripThinking(raw))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Translation:", "translation:", "Translated text:", "翻訳:", "译文：", "译文:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        if s.count > 2, s.hasPrefix("\""), s.hasSuffix("\""),
           s.dropFirst().dropLast().contains("\"") == false {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s.isEmpty ? nil : s
    }

    private static func stripThinking(_ raw: String) -> String {
        var working = raw
        let closedPattern = #"(?s)<think(?:ing)?>(.*?)</think(?:ing)?>"#
        if let regex = try? NSRegularExpression(pattern: closedPattern) {
            working = regex.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: ""
            )
        }
        // Unclosed: a `<think>` with no terminator → drop from the tag onward
        // only when nothing readable precedes it; otherwise keep the prefix.
        if let openRange = working.range(of: #"<think(?:ing)?>"#, options: .regularExpression) {
            let before = String(working[..<openRange.lowerBound])
            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                working = ""
            } else {
                working = before
            }
        }
        let tagPattern = #"</?think(?:ing)?>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            working = regex.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: ""
            )
        }
        return working
    }

    private static func stripControlTokens(_ raw: String) -> String {
        var sanitized = raw
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|>]*\|>"#) {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: ""
            )
        }
        return sanitized.replacingOccurrences(of: "/no_think", with: "")
    }
}

// MARK: - MLX (Qwen) implementation

public final class MLXTranslator: Translating, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let generationTaskPriority: TaskPriority
    private let glossaryProtection: TranslationGlossaryProtection

    public init(
        engine: any TrainingEngine,
        generationTaskPriority: TaskPriority = .userInitiated,
        nonceGenerator: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.engine = engine
        self.generationTaskPriority = generationTaskPriority
        self.glossaryProtection = TranslationGlossaryProtection(nonceGenerator: nonceGenerator)
    }

    public var cacheTag: String { TranslationEngineKind.qwen.cacheTag }
    public var usesContext: Bool { true }

    public func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?
    ) async throws -> TranslationResult? {
        try await translate(
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            detectedSourceLanguageCode: detectedSourceLanguageCode,
            context: nil
        )
    }

    public func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?,
        context: TranslationContext?
    ) async throws -> TranslationResult? {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let boundedBody = String(bodyText.prefix(TranslationPromptBuilder.bodyCharacterLimit))
        let prepared = glossaryProtection.prepare(
            bodyText: boundedBody,
            exactGlossary: context?.exactGlossary ?? []
        )
        let maxTokens = TranslationPromptBuilder.maxTokens(forBodyCharacterCount: boundedBody.count)

        let prompt = TranslationPromptBuilder.promptParts(
            bodyText: prepared.protectedText,
            targetLanguage: targetLanguage,
            rules: context?.rules ?? [],
            exactMappings: prepared.mappings,
            provisionalGlossary: context?.provisionalGlossary ?? []
        )
        let raw = try await generate(prompt: prompt, maxTokens: maxTokens)
        if let cleaned = TranslationPostProcessor.clean(raw),
           prepared.containsEveryRequiredMarker(in: cleaned) {
            let restored = try prepared.restore(in: cleaned, requireAll: true)
            return TranslationResult(
                text: restored,
                targetLanguageIdentifier: targetLanguage.identifier,
                detectedSourceLanguageCode: detectedSourceLanguageCode
            )
        }
        guard prepared.mappings.isEmpty == false else { return nil }

        let recoveryBody = try prepared.restore(in: prepared.protectedText, requireAll: true)
        let recoveryPrompt = TranslationPromptBuilder.promptParts(
            bodyText: recoveryBody,
            targetLanguage: targetLanguage,
            rules: context?.rules ?? [],
            provisionalGlossary: context?.provisionalGlossary ?? [],
            markerRetryInstruction: """
                EXACT TERMINOLOGY RECOVERY: Established target-language renderings are already inserted in the message. Preserve every occurrence exactly as written, including occurrences in the closing and signature, while translating all surrounding text.
                """
        )
        let recoveryMaxTokens = min(5_200, max(1_024, maxTokens * 2))
        let recoveryRaw = try await generate(
            prompt: recoveryPrompt,
            maxTokens: recoveryMaxTokens
        )
        guard let recovered = TranslationPostProcessor.clean(recoveryRaw),
              Self.preservesExactRenderings(prepared.mappings, in: recovered) else {
            throw TranslationError.glossaryProtectionFailed
        }
        return TranslationResult(
            text: recovered,
            targetLanguageIdentifier: targetLanguage.identifier,
            detectedSourceLanguageCode: detectedSourceLanguageCode
        )
    }

    private static func preservesExactRenderings(
        _ mappings: [TranslationGlossaryMarkerMapping],
        in output: String
    ) -> Bool {
        let requiredCounts = Dictionary(grouping: mappings, by: \.targetRendering)
            .mapValues(\.count)
        return requiredCounts.allSatisfy { rendering, requiredCount in
            literalOccurrenceCount(of: rendering, in: output) >= requiredCount
        }
    }

    private static func literalOccurrenceCount(of needle: String, in text: String) -> Int {
        guard needle.isEmpty == false else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: needle,
                options: .literal,
                range: searchStart..<text.endIndex
              ) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private func generate(prompt: PrefixCachedPrompt, maxTokens: Int) async throws -> String {
        let engine = self.engine
        let priority = generationTaskPriority
        do {
            return try await runCancellableGeneration(priority: priority) { cancellation in
                try PrefixCachedGeneration.generate(
                    engine: engine,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    cancellation: cancellation
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TrainingEngineError {
            throw Self.mapEngineError(error)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.underlying(error.localizedDescription)
        }
    }

    private func runCancellableGeneration(
        priority: TaskPriority,
        operation: @escaping @Sendable (GenerationCancellation) throws -> String
    ) async throws -> String {
        let cancellation = GenerationCancellation()
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation(cancellation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    private static func mapEngineError(_ error: TrainingEngineError) -> TranslationError {
        switch error {
        case .modelNotLoaded:
            return .modelUnavailable("the model is still loading.")
        case .modelUnavailable(let detail):
            return .modelUnavailable(detail)
        case .generationFailed(let detail):
            return .underlying(detail)
        default:
            return .underlying(error.localizedDescription)
        }
    }
}
