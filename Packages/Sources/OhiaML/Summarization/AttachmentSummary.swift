// AttachmentSummary.swift
// Three-sentence orientation a single attachment shows behind the locked-node
// overlay's chevron: what the attachment is, why it's relevant in the email's
// context, and a compact content summary. Generation can happen lazily on
// expansion or through the background attachment-summary backfill worker; both
// paths use the same prompt, post-processing, and fingerprint.

import Foundation
import OSLog
import OhiaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

private let attachmentSummaryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "attachment-summary"
)

public struct AttachmentSummaryInput: Sendable, Equatable {
    public let attachmentID: UUID
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    /// Concatenated extracted text for every chunk of the attachment, in
    /// chunkIndex order. Empty when extraction has not produced any text yet
    /// (binary-only attachments, or text-bearing types waiting on the
    /// `extractAttachments` worker).
    public let extractedText: String
    /// `DocumentKind` raw value the extractor detected (`docx`, `pdf`, `pptx`,
    /// `xlsx`, `image`, …). Drives the type-specific framing the prompt gives
    /// the model so a prose manuscript is never described as a slide deck.
    /// `nil` for rows extracted before the field was tracked; the prompt then
    /// infers the form from the MIME type.
    public let documentKind: String?
    /// Document-format-specific structural unit from extraction — `page`,
    /// `slide`, or `sheet` (Word "section" counts are an XML-part artifact and
    /// are intentionally not surfaced). `nil` when not applicable.
    public let structureUnitKind: String?
    public let structureUnitCount: Int?
    /// Extracted plain-text character count, used to state an approximate word
    /// length for written works. `nil` when unknown.
    public let characterCount: Int?
    /// Document-embedded title/author (OOXML core properties, PDF attributes).
    /// Passed to the model as a fallback cross-check; the prompt instructs it to
    /// prefer the title and author it can read in the extracted text.
    public let documentTitle: String?
    public let documentAuthor: String?
    public let anchorSubject: String
    public let anchorSenderName: String
    public let anchorReceivedAt: Date?
    public let anchorPurpose: MailPurpose?

    public init(
        attachmentID: UUID,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        extractedText: String,
        documentKind: String? = nil,
        structureUnitKind: String? = nil,
        structureUnitCount: Int? = nil,
        characterCount: Int? = nil,
        documentTitle: String? = nil,
        documentAuthor: String? = nil,
        anchorSubject: String,
        anchorSenderName: String,
        anchorReceivedAt: Date?,
        anchorPurpose: MailPurpose?
    ) {
        self.attachmentID = attachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.extractedText = extractedText
        self.documentKind = documentKind
        self.structureUnitKind = structureUnitKind
        self.structureUnitCount = structureUnitCount
        self.characterCount = characterCount
        self.documentTitle = documentTitle
        self.documentAuthor = documentAuthor
        self.anchorSubject = anchorSubject
        self.anchorSenderName = anchorSenderName
        self.anchorReceivedAt = anchorReceivedAt
        self.anchorPurpose = anchorPurpose
    }

    /// `true` when the model has enough text to produce a meaningful three-
    /// sentence summary. Pure-metadata calls (filename only) return `false`
    /// so the service short-circuits to `nil` and the UI renders a neutral
    /// "no extracted text" copy instead of asking the model to invent a
    /// summary from a filename alone.
    public var hasGeneratableEvidence: Bool {
        !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct AttachmentSummaryResult: Sendable, Equatable {
    public let paragraph: String

    public init(paragraph: String) {
        self.paragraph = paragraph
    }
}

/// What one attachment-summary request produced.
public enum AttachmentSummaryOutcome: Sendable, Equatable {
    case summarized(AttachmentSummaryResult)
    /// Generated, but it could not be written in the reading language: the
    /// model answered and its translation was missing or rejected. Nothing
    /// was shown or cached.
    case withheldOutsideReadingLanguage
    /// No evidence, a refused or failed generation, a translation pass that
    /// never reached an answer, or a cancelled request.
    case unavailable

    public var result: AttachmentSummaryResult? {
        guard case .summarized(let result) = self else { return nil }
        return result
    }
}

public enum AttachmentSummaryGenerationFailureKind: String, Sendable {
    case exceededContextWindowSize
    case assetsUnavailable
    case guardrailViolation
    case unsupportedGuide
    case unsupportedLanguageOrLocale
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case refusal
    case unknown
}

public enum AttachmentSummaryError: Error, Sendable {
    case empty
    case modelUnavailable
    case generationFailed(AttachmentSummaryGenerationFailureKind)
    case underlying(Error)

    var logCategory: String {
        switch self {
        case .empty:
            return "empty"
        case .modelUnavailable:
            return "modelUnavailable"
        case .generationFailed(let kind):
            return "generation.\(kind.rawValue)"
        case .underlying(let error):
            return "underlying.\(String(reflecting: type(of: error)))"
        }
    }
}

public protocol AttachmentSummaryGenerating: Sendable {
    func summarize(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> AttachmentSummaryResult?
}

public enum AttachmentSummaryPromptBuilder {
    /// Bound source evidence for both providers. Apple eligibility is measured
    /// separately against the live model window, including instructions,
    /// schema, and the reserved response.
    public static let textCharacterLimit = 16_000

    public static let instructions = """
    You are writing a short, substantive orientation to a piece of material that arrived alongside an email, for someone who has not opened it yet. \
    Ground every statement in the EXTRACTED CONTENTS provided below. Never invent details, and never claim a structural form — slides, charts, diagrams, figures, images, tables — unless the contents actually contain it.

    Adapt what you say to what the material genuinely is:
    - A written work (a thesis or dissertation chapter, an academic paper, a manuscript, a report, a letter, a memo): open by identifying it — name its author and title when they appear in the text, and state its approximate length — then give a real abstract of its argument and substance, in your own words.
    - A slide presentation: summarize the through-line and the key points it builds across its slides.
    - A spreadsheet or tabular data: say what the rows and columns represent and the scope of the figures; do not narrate it as prose.
    - A receipt, itinerary, invoice, form, or confirmation: state the concrete particulars — who, what, when, amounts.

    Close with one sentence on why it was sent or referenced, drawn from the surrounding email's subject and sender.

    Write three to five complete sentences, no more than 250 words, in flowing prose — no headings, no bullet lists, no labels, no preamble, and no ellipses. \
    Refer to the material by what it actually is; do not call it "an attachment", "a file", or address "the reader" or "the user". \
    Prefer the title and author you can read in the contents themselves; any file-embedded title or author given below is only a fallback for when the text is unclear and may be inaccurate. If a detail is not present, omit it rather than guess. \
    Do not include reasoning, analysis, planning, scratchpad text, or <think> tags. If the model supports thinking controls, disable thinking. \
    Write in the target system language named below.
    """

    public static let guide = "A substantive prose orientation to the material: identify what it actually is (for a written work, its author, title, and approximate length), give a real summary of its content grounded only in the extracted text, and end with why it was sent in the email's context. Three to five complete sentences, no more than 250 words, in flowing prose — no headings, bullets, labels, preamble, or ellipses. Never claim slides, charts, figures, or images the text does not contain."

    public static func prompt(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        promptParts(input: input, targetLanguage: targetLanguage).prompt
    }

    public static func promptParts(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> PrefixCachedPrompt {
        let prefix = [
            instructions,
            "",
            "Target system language: \(targetLanguage.promptDescription)",
            ""
        ].joined(separator: "\n") + "\n"

        let descriptor = documentKindDescriptor(
            rawKind: input.documentKind,
            mimeType: input.mimeType
        )

        var lines: [String] = []
        lines.append("Email context")
        lines.append("- Subject: \(clean(input.anchorSubject, limit: 180))")
        lines.append("- From: \(clean(input.anchorSenderName, limit: 120))")
        if let receivedAt = input.anchorReceivedAt {
            lines.append("- Received: \(Self.dateFormatter.string(from: receivedAt))")
        }
        if let purpose = input.anchorPurpose {
            lines.append("- Purpose: \(purpose.displayLabel)")
        }
        lines.append("")
        lines.append("Material metadata")
        lines.append("- This material is \(descriptor.label).")
        lines.append("- Filename: \(clean(input.filename, limit: 140))")
        if let lengthLine = approximateLengthLine(for: input) {
            lines.append("- \(lengthLine)")
        }
        if let structureLine = structureLine(for: input) {
            lines.append("- \(structureLine)")
        }
        if let title = trimmedMetadata(input.documentTitle) {
            lines.append("- File-embedded title (may be inaccurate; prefer the title in the contents): \(clean(title, limit: 200))")
        }
        if let author = trimmedMetadata(input.documentAuthor) {
            lines.append("- File-embedded author (may be inaccurate; prefer the author named in the contents): \(clean(author, limit: 160))")
        }
        lines.append("")
        lines.append("How to treat this material: \(descriptor.guidance)")
        lines.append("")
        lines.append("Extracted contents")
        lines.append(clean(input.extractedText, limit: textCharacterLimit))
        lines.append("")
        lines.append("Return only the orientation prose — no headings, no bullet lists, no labels, no preamble, no ellipses, no reasoning, no <think> tags.")
        lines.append("/no_think")
        return PrefixCachedPrompt(
            cacheKey: "attachment-summary-v3",
            prefix: prefix,
            suffix: lines.joined(separator: "\n")
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = neutralizeControlTokens(text)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let marker = " [content continues beyond this excerpt]"
        let budget = max(0, limit - marker.count)
        return collapsed.prefix(budget).trimmingCharacters(in: .whitespacesAndNewlines) + marker
    }

    /// Defuses chat-template control tokens that could otherwise be smuggled in
    /// through sender-controlled text — document-embedded title/author, the
    /// filename, the subject, or the extracted body — and forge a role turn in
    /// the prompt. Every untrusted field is interpolated through `clean`, so
    /// neutralizing here covers all of them. Runs on the input side, mirroring
    /// the `<think>`-tag stripping the post-processor already does on output.
    static func neutralizeControlTokens(_ text: String) -> String {
        var sanitized = text
        // Strip whole ChatML / Qwen special tokens (`<|im_start|>`, `<|im_end|>`,
        // `<|endoftext|>`, and any other `<|…|>` marker). Token names carry no
        // `|`/`>`, so the character class keeps adjacent tokens separate.
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|>]*\|>"#) {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: " "
            )
        }
        // Backstop any residual unpaired delimiters so a truncated marker can't
        // recombine with appended scaffolding into a live control token.
        sanitized = sanitized
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "|>", with: "| >")
        return sanitized
    }

    private static func trimmedMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Characters-per-word for the approximate-length line, matching
    /// `AttachmentReferenceText.charactersPerWord` in the UI so the prompt's
    /// stated length agrees with the FILES-row "~N words" fact.
    static let charactersPerWord = 5.5

    /// Human label + per-kind guidance the prompt uses to frame the material so
    /// a prose manuscript is read as written prose and never described as a
    /// slide deck. Falls back to MIME sniffing when the detected kind is absent.
    static func documentKindDescriptor(
        rawKind: String?,
        mimeType: String
    ) -> (label: String, guidance: String) {
        switch (rawKind ?? "").lowercased() {
        case "docx", "legacyword", "rtf":
            return (
                "a word-processor document",
                "Read it as written prose. If it is a chapter, paper, report, letter, or memo, name its author and title from the text, state its approximate length, and summarize its actual argument and substance."
            )
        case "pdf":
            return (
                "a PDF document",
                "Read it as a written work. Identify its author, title, and length when the text shows them, then summarize its content. Mention figures, charts, or images only if the text refers to them."
            )
        case "pptx", "legacypresentation":
            return (
                "a slide presentation",
                "Summarize the through-line and the key points the deck builds across its slides."
            )
        case "xlsx", "legacyspreadsheet", "csv", "tsv":
            return (
                "a spreadsheet of tabular data",
                "Describe what the rows and columns represent and the scope of the figures. Do not narrate it as prose or invent a storyline."
            )
        case "html", "markdown", "plaintext":
            return (
                "a text document",
                "Summarize its actual content as written prose."
            )
        case "image":
            return (
                "an image",
                "Describe what the image shows, based only on the extracted text and recognized content."
            )
        default:
            return descriptorFromMIME(mimeType)
        }
    }

    private static func descriptorFromMIME(_ mimeType: String) -> (label: String, guidance: String) {
        let mime = mimeType.lowercased()
        if mime.contains("presentation") {
            return ("a slide presentation", "Summarize the through-line and the key points the deck builds across its slides.")
        }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" || mime == "text/tab-separated-values" {
            return ("a spreadsheet of tabular data", "Describe what the rows and columns represent and the scope of the figures.")
        }
        if mime.contains("pdf") {
            return ("a PDF document", "Read it as a written work; identify its author, title, and length when present, then summarize its content.")
        }
        if mime.hasPrefix("image/") {
            return ("an image", "Describe what the image shows, based only on the extracted text and recognized content.")
        }
        return (
            "a written document",
            "Read it as written prose; identify its author and title when present, state its approximate length, and summarize its actual content."
        )
    }

    /// Approximate-length line for written works, mirroring the FILES-row word
    /// estimate so the prompt and the UI agree. Suppressed for kinds where a
    /// word count is not the meaningful measure (decks, sheets, images).
    private static func approximateLengthLine(for input: AttachmentSummaryInput) -> String? {
        guard let characterCount = input.characterCount, characterCount > 0 else { return nil }
        // Word count is the wrong measure for decks, sheets, and images — those
        // surface a slide/sheet count or pixel dimensions instead. Every other
        // kind (and the unknown/MIME-fallback case, which is framed as prose and
        // asked to state a length) gets the estimate.
        let nonWordMeasuredKinds: Set<String> = [
            "pptx", "legacypresentation", "xlsx", "legacyspreadsheet", "csv", "tsv", "image"
        ]
        guard !nonWordMeasuredKinds.contains((input.documentKind ?? "").lowercased()) else { return nil }
        let words = max(1, Int((Double(characterCount) / charactersPerWord).rounded()))
        return "Approximate length: \(words.formatted()) words"
    }

    /// Structural-unit line for paged formats — pages, slides, sheets. Word
    /// "section" counts are an XML-part artifact, so they are not surfaced.
    private static func structureLine(for input: AttachmentSummaryInput) -> String? {
        guard let kind = trimmedMetadata(input.structureUnitKind)?.lowercased(),
              let count = input.structureUnitCount, count > 0 else { return nil }
        let noun: String
        switch kind {
        case "page": noun = count == 1 ? "page" : "pages"
        case "slide": noun = count == 1 ? "slide" : "slides"
        case "sheet": noun = count == 1 ? "sheet" : "sheets"
        default: return nil
        }
        return "Structure: \(count) \(noun)"
    }
}

public enum AttachmentSummaryPostProcessor {
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return clean(raw)
    }

    public static func clean(_ raw: String) -> String? {
        var s = stripThinking(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = [
            "Summary:", "summary:",
            "Description:", "description:",
            "Sentence 1:", "Sentence 2:", "Sentence 3:",
            "Here's", "Here is"
        ]
        for prefix in leadIns where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count > 2 {
            s = String(s.dropFirst().dropLast())
        }
        let collapsed = s
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let withoutGenericLead = stripGenericTypeLead(from: collapsed)
        guard !withoutGenericLead.isEmpty else { return nil }
        guard !isGenericTypeOnlyDescription(withoutGenericLead) else { return nil }
        return withoutGenericLead
    }

    public static func isGenericTypeOnlyDescription(_ text: String) -> Bool {
        var normalized = text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "this is ",
            "it is ",
            "it s ",
            "the material is ",
            "this material is "
        ]
        for prefix in prefixes where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return genericTypeOnlyDescriptions.contains(normalized)
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
            working = String(working[..<openRange.lowerBound])
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
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            working = regex.stringByReplacingMatches(
                in: working,
                options: [],
                range: NSRange(location: 0, length: (working as NSString).length),
                withTemplate: ""
            )
        }
        return working
    }

    private static func stripGenericTypeLead(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: ".!?。！？:：-–—")
        guard let end = trimmed.firstIndex(where: { character in
            character.unicodeScalars.allSatisfy { separators.contains($0) }
        }) else {
            return trimmed
        }
        let firstSentence = String(trimmed[...end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: separators)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGenericTypeOnlyDescription(firstSentence) else {
            return trimmed
        }
        let rest = trimmed[trimmed.index(after: end)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? trimmed : rest
    }

    private static let genericTypeOnlyDescriptions: Set<String> = [
        "a document",
        "document",
        "a file",
        "file",
        "a word document",
        "word document",
        "a microsoft word document",
        "microsoft word document",
        "a word processing document",
        "word processing document",
        "a pdf document",
        "pdf document",
        "a spreadsheet",
        "spreadsheet",
        "a presentation",
        "presentation",
        "a slide deck",
        "slide deck"
    ]
}

// MARK: - MLX engine implementation

public final class MLXAttachmentSummarizer: AttachmentSummaryGenerating, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int

    public init(engine: any TrainingEngine, maxTokens: Int = 512) {
        self.engine = engine
        self.maxTokens = maxTokens
    }

    public func summarize(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> AttachmentSummaryResult? {
        guard engine.isModelLoaded else {
            throw AttachmentSummaryError.modelUnavailable
        }
        let prompt = AttachmentSummaryPromptBuilder.promptParts(
            input: input,
            targetLanguage: targetLanguage
        )
        let engine = self.engine
        let maxTokens = self.maxTokens
        let raw: String
        do {
            raw = try await Task.detached(priority: .utility) {
                try PrefixCachedGeneration.generate(
                    engine: engine,
                    prompt: prompt,
                    maxTokens: maxTokens
                )
            }.value
        } catch {
            throw AttachmentSummaryError.underlying(error)
        }
        guard let cleaned = AttachmentSummaryPostProcessor.clean(raw) else {
            return nil
        }
        return AttachmentSummaryResult(paragraph: cleaned)
    }
}

// MARK: - Apple Foundation Models implementation

#if canImport(FoundationModels)
public final class AppleFoundationAttachmentSummarizer: AttachmentSummaryGenerating, @unchecked Sendable {
    static let generationOptions = GenerationOptions(
        temperature: 0.1,
        maximumResponseTokens: 512
    )

    @Generable
    struct AttachmentParagraph {
        @Guide(description: AttachmentSummaryPromptBuilder.guide)
        let paragraph: String
    }

    public init() {}

    static func failureKind(
        for error: LanguageModelSession.GenerationError
    ) -> AttachmentSummaryGenerationFailureKind {
        switch error {
        case .exceededContextWindowSize:
            return .exceededContextWindowSize
        case .assetsUnavailable:
            return .assetsUnavailable
        case .guardrailViolation:
            return .guardrailViolation
        case .unsupportedGuide:
            return .unsupportedGuide
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale
        case .decodingFailure:
            return .decodingFailure
        case .rateLimited:
            return .rateLimited
        case .concurrentRequests:
            return .concurrentRequests
        case .refusal:
            return .refusal
        @unknown default:
            return .unknown
        }
    }

    public func summarize(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> AttachmentSummaryResult? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw AttachmentSummaryError.modelUnavailable
        }
        let session = LanguageModelSession(instructions: AttachmentSummaryPromptBuilder.instructions)
        let prompt = AttachmentSummaryPromptBuilder.prompt(input: input, targetLanguage: targetLanguage)
        do {
            try await ApplePromptBudget.requireFits(
                prompt: prompt, instructions: AttachmentSummaryPromptBuilder.instructions,
                schema: AttachmentParagraph.generationSchema, responseTokens: 512
            )
            let response = try await session.respond(
                to: prompt,
                generating: AttachmentParagraph.self,
                options: Self.generationOptions
            )
            guard let cleaned = AttachmentSummaryPostProcessor.clean(response.content.paragraph) else {
                throw AttachmentSummaryError.empty
            }
            return AttachmentSummaryResult(paragraph: cleaned)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw AttachmentSummaryError.empty
            default:
                throw AttachmentSummaryError.generationFailed(Self.failureKind(for: error))
            }
        } catch let error as AttachmentSummaryError {
            throw error
        } catch {
            throw AttachmentSummaryError.underlying(error)
        }
    }
}
#endif

// MARK: - Service actor (cache + Apple/MLX cascade)

public actor AttachmentSummaryService {
    public typealias AvailabilityProvider = @Sendable () -> AppleIntelligenceAvailability.State

    private let appleSummarizer: (any AttachmentSummaryGenerating)?
    private let mlxSummarizer: any AttachmentSummaryGenerating
    private let availabilityProvider: AvailabilityProvider
    private let persistentCacheURL: URL?
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let displayLanguageGuard: DisplayLanguageGuard?
    private var appleEnabled: Bool

    private var inFlight: [String: Task<AttachmentSummaryOutcome, Never>] = [:]
    private var memoryCache: [String: AttachmentSummaryResult] = [:]
    private var persistentCache: [String: PersistentCacheEntry] = [:]
    private var lru: [String] = []
    private let capacity: Int

    public init(
        apple: (any AttachmentSummaryGenerating)?,
        mlx: any AttachmentSummaryGenerating,
        appleEnabled: Bool,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        capacity: Int = 128,
        persistentCacheURL: URL? = nil,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        availabilityProvider: @escaping AvailabilityProvider = { AppleIntelligenceAvailability.current() }
    ) {
        self.appleSummarizer = apple
        self.mlxSummarizer = mlx
        self.appleEnabled = appleEnabled
        self.capacity = max(1, capacity)
        self.persistentCacheURL = persistentCacheURL
        self.availabilityProvider = availabilityProvider
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.displayLanguageGuard = displayLanguageGuard
        self.persistentCache = Self.loadPersistentCache(from: persistentCacheURL)
    }

    public func setAppleEnabled(_ enabled: Bool) {
        appleEnabled = enabled
    }

    /// Lazy entry point. Returns `nil` when the input has no extracted text,
    /// when both engines refuse / fail, or when the paragraph cannot be
    /// written in the reading language. Coalesces concurrent requests for
    /// the same `(attachmentID, fingerprint)` so a quick chevron toggle can't
    /// kick off multiple generations.
    public func summary(
        for attachmentID: UUID,
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        accountID: UUID? = nil
    ) async -> AttachmentSummaryResult? {
        await summaryOutcome(
            for: attachmentID,
            input: input,
            targetLanguage: targetLanguage,
            accountID: accountID
        ).result
    }

    /// `summary(for:)`, telling a paragraph withheld outside the reading
    /// language apart from other misses so the background lane can bound its
    /// retries.
    public func summaryOutcome(
        for attachmentID: UUID,
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        accountID: UUID? = nil
    ) async -> AttachmentSummaryOutcome {
        guard !AccountDisconnectionRequest.isPending else { return .unavailable }
        let fingerprint = Self.fingerprint(input: input, targetLanguage: targetLanguage)
        let cacheKey = Self.cacheKey(attachmentID: attachmentID, fingerprint: fingerprint)

        let guardrail = displayLanguageGuard
        if let cached = memoryCache[cacheKey],
           DisplayLanguageGuard.isDisplayable(cached.paragraph, targetLanguage: targetLanguage, guardrail: guardrail) {
            touch(cacheKey)
            return .summarized(cached)
        }
        if let entry = persistentCache[cacheKey],
           DisplayLanguageGuard.isDisplayable(entry.paragraph, targetLanguage: targetLanguage, guardrail: guardrail) {
            let persisted = AttachmentSummaryResult(paragraph: entry.paragraph)
            guard let cleaned = Self.cleanedResult(persisted) else {
                persistentCache[cacheKey] = nil
                try? persistCache()
                return .unavailable
            }
            storeInMemory(cacheKey, cleaned)
            return .summarized(cleaned)
        }
        if let task = inFlight[cacheKey] {
            let outcome = await task.value
            guard !task.isCancelled, !AccountDisconnectionRequest.isPending else { return .unavailable }
            return outcome
        }
        guard input.hasGeneratableEvidence else { return .unavailable }

        let apple = appleSummarizer
        let mlx = mlxSummarizer
        let enabled = appleEnabled
        let availability = availabilityProvider
        let activityPublisher = modelActivityStatusPublisher
        let task = Task<AttachmentSummaryOutcome, Never> {
            let activityToken = activityPublisher?.begin(
                .summarizing,
                source: "attachment-summary",
                accountID: accountID
            )
            defer {
                if let activityToken {
                    activityPublisher?.end(activityToken)
                }
            }
            guard let produced = await Self.produce(
                input: input,
                targetLanguage: targetLanguage,
                apple: apple,
                mlx: mlx,
                appleEnabled: enabled,
                availability: availability
            ), let cleaned = Self.cleanedResult(produced) else { return .unavailable }
            guard let guardrail,
                  DisplayLanguageGuard.needsResolution([cleaned.paragraph], targetLanguage: targetLanguage) else {
                return .summarized(cleaned)
            }
            // A paragraph that cannot be put in the reading language is not
            // a summary: nothing is shown or cached, and the next request
            // generates it again.
            let resolution = await guardrail.resolve(
                [cleaned.paragraph],
                targetLanguage: targetLanguage,
                source: DisplayLanguageGuard.Source(
                    languageHint: nil,
                    context: "\(input.filename)\n\(input.anchorSubject)\n\(input.extractedText.prefix(1_200))",
                    messageID: nil,
                    accountID: accountID
                )
            )
            guard resolution.isComplete, let paragraph = resolution.fields.first else {
                return resolution.isTransient ? .unavailable : .withheldOutsideReadingLanguage
            }
            return .summarized(AttachmentSummaryResult(paragraph: paragraph))
        }
        inFlight[cacheKey] = task
        let outcome = await task.value
        // A cache clear/disconnection may have cancelled this task while the
        // provider continued running. Never republish its late result.
        guard !task.isCancelled, !AccountDisconnectionRequest.isPending else { return .unavailable }
        inFlight[cacheKey] = nil
        guard case .summarized(let result) = outcome else { return outcome }
        guard let cleaned = Self.cleanedResult(result) else { return .unavailable }
        store(cacheKey, attachmentID: attachmentID, fingerprint: fingerprint, cleaned)
        return .summarized(cleaned)
    }

    public func clearCache() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        persistentCache.removeAll()
        lru.removeAll()
        try? persistCache()
    }

    /// Drops the cached paragraph for a single attachment and cancels any
    /// in-flight generation. Called when the `extractAttachments` worker
    /// persists fresh text for an attachment so the next chevron expand
    /// regenerates against the updated extraction.
    public func invalidate(attachmentID: UUID) {
        let prefix = "\(attachmentID.uuidString):"
        for key in inFlight.keys where key.hasPrefix(prefix) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
        persistentCache = persistentCache.filter { !$0.key.hasPrefix(prefix) }
        lru.removeAll { $0.hasPrefix(prefix) }
        try? persistCache()
    }

    private static func produce(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage,
        apple: (any AttachmentSummaryGenerating)?,
        mlx: any AttachmentSummaryGenerating,
        appleEnabled: Bool,
        availability: AvailabilityProvider
    ) async -> AttachmentSummaryResult? {
        if let apple, appleEnabled, availability().isAvailable {
            let appleStartedAt = Date()
            do {
                if let result = try await apple.summarize(input: input, targetLanguage: targetLanguage) {
                    attachmentSummaryLogger.info(
                        "Attachment summary generated with Apple durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public)"
                    )
                    return result
                }
                attachmentSummaryLogger.warning(
                    "Attachment summary Apple returned an empty result durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public)"
                )
            } catch AttachmentSummaryError.empty {
                attachmentSummaryLogger.info(
                    "Attachment summary Apple refused durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public); falling back to MLX"
                )
            } catch AttachmentSummaryError.modelUnavailable {
                attachmentSummaryLogger.info(
                    "Attachment summary Apple unavailable durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public); falling back to MLX"
                )
            } catch let error as AttachmentSummaryError {
                attachmentSummaryLogger.warning(
                    "Attachment summary Apple failed category=\(error.logCategory, privacy: .public) durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public); falling back to MLX"
                )
            } catch {
                attachmentSummaryLogger.warning(
                    "Attachment summary Apple failed category=unexpected.\(String(reflecting: type(of: error)), privacy: .public) durationMs=\(elapsedMilliseconds(since: appleStartedAt), privacy: .public); falling back to MLX"
                )
            }
        }
        do {
            if let result = try await mlx.summarize(input: input, targetLanguage: targetLanguage) {
                attachmentSummaryLogger.info("Attachment summary generated with MLX")
                return result
            }
            attachmentSummaryLogger.warning("Attachment summary MLX returned an empty result")
        } catch {
            attachmentSummaryLogger.warning(
                "Attachment summary MLX failed: \(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
        return nil
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }

    private static func cleanedResult(_ result: AttachmentSummaryResult) -> AttachmentSummaryResult? {
        guard let paragraph = AttachmentSummaryPostProcessor.clean(result.paragraph) else {
            return nil
        }
        return AttachmentSummaryResult(paragraph: paragraph)
    }

    private func store(
        _ key: String,
        attachmentID: UUID,
        fingerprint: String,
        _ result: AttachmentSummaryResult
    ) {
        persistentCache[key] = PersistentCacheEntry(
            attachmentID: attachmentID,
            fingerprint: fingerprint,
            paragraph: result.paragraph,
            updatedAt: Date()
        )
        storeInMemory(key, result)
        try? persistCache()
    }

    private func storeInMemory(_ key: String, _ result: AttachmentSummaryResult) {
        memoryCache[key] = result
        touch(key)
        while lru.count > capacity {
            let oldest = lru.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func persistCache() throws {
        guard let persistentCacheURL else { return }
        let container = PersistentCacheContainer(entries: persistentCache)
        let data = try JSONEncoder().encode(container)
        try FileManager.default.createDirectory(
            at: persistentCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistentCacheURL, options: .atomic)
    }

    private static func loadPersistentCache(from url: URL?) -> [String: PersistentCacheEntry] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(PersistentCacheContainer.self, from: data) else {
            return [:]
        }
        return container.entries.compactMapValues { entry in
            guard let cleaned = AttachmentSummaryPostProcessor.clean(entry.paragraph) else {
                return nil
            }
            var cleanedEntry = entry
            cleanedEntry.paragraph = cleaned
            return cleanedEntry
        }
    }

    private static func cacheKey(attachmentID: UUID, fingerprint: String) -> String {
        "\(attachmentID.uuidString):\(fingerprint)"
    }

    public static func fingerprint(
        input: AttachmentSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        let parts: [String] = [
            targetLanguage.identifier,
            targetLanguage.displayName,
            input.filename,
            input.mimeType,
            String(input.sizeBytes),
            input.documentKind ?? "",
            input.structureUnitKind ?? "",
            input.structureUnitCount.map(String.init) ?? "",
            input.characterCount.map(String.init) ?? "",
            input.documentTitle ?? "",
            input.documentAuthor ?? "",
            input.extractedText,
            input.anchorSubject,
            input.anchorSenderName,
            input.anchorReceivedAt.map { String($0.timeIntervalSince1970) } ?? "",
            input.anchorPurpose?.rawValue ?? ""
        ]
        return stableHash(parts.joined(separator: "\u{1F}"))
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

private struct PersistentCacheContainer: Codable {
    var entries: [String: PersistentCacheEntry]
}

private struct PersistentCacheEntry: Codable {
    var attachmentID: UUID
    var fingerprint: String
    var paragraph: String
    var updatedAt: Date
}
