// DeadlineResourceReadout.swift
// The guide pane's deep-read pass: one attached document (or the owner's own
// working file) is handed to the model together with the deadline's framing,
// and the model writes what completing or using that document actually
// involves — the sections a form asks for, who signs where, what must be
// attached or returned. This is the second, deeper pass over the same
// materials `DeadlineSummary` distills; where the summary orients the whole
// deadline, a readout reads one resource closely. Rendered beneath the
// resource's step row in the Deadlines guide pane.
//
// Same engine cascade as the summary (Qwen/MLX preferred, Apple Foundation
// Models as a small-prompt fallback) and the same output register: complete
// sentences, target-language, no invented tokens, no forbidden vocabulary.

import Foundation
import OhiaCore
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let deadlineReadoutLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "deadline-readout"
)

// MARK: - Input

/// Where the resource came from — the thread's attachments, or a file the
/// account owner dropped onto the guide pane.
public enum DeadlineResourceOrigin: String, Sendable, Equatable, Codable {
    case threadAttachment
    case workingFile
}

public struct DeadlineResourceReadoutInput: Sendable, Equatable {
    public let accountID: UUID?
    public let deadlineTitle: String
    public let deadlineLabel: String
    public let deadlineDateText: String
    /// The phrase in the email that stated the deadline.
    public let surfaceText: String
    public let resourceFilename: String
    public let resourceOrigin: DeadlineResourceOrigin
    /// The resource's extracted text, capped by the input builder.
    public let resourceText: String
    /// The already-generated briefing paragraph, when available, so the readout
    /// extends it instead of restating it.
    public let briefingParagraph: String?
    public let correspondents: [DeadlineSummaryParticipant]
    public let userIdentity: SummarizationUserIdentity?
    /// Deadline (dated obligation) or project (ongoing) register. For
    /// `.project`, `deadlineDateText` carries the activity period and
    /// `surfaceText` is empty.
    public let framing: DeadlineGuideFraming

    public init(
        accountID: UUID? = nil,
        deadlineTitle: String,
        deadlineLabel: String,
        deadlineDateText: String,
        surfaceText: String,
        resourceFilename: String,
        resourceOrigin: DeadlineResourceOrigin,
        resourceText: String,
        briefingParagraph: String? = nil,
        correspondents: [DeadlineSummaryParticipant] = [],
        userIdentity: SummarizationUserIdentity? = nil,
        framing: DeadlineGuideFraming = .deadline
    ) {
        self.accountID = accountID
        self.deadlineTitle = deadlineTitle
        self.deadlineLabel = deadlineLabel
        self.deadlineDateText = deadlineDateText
        self.surfaceText = surfaceText
        self.resourceFilename = resourceFilename
        self.resourceOrigin = resourceOrigin
        self.resourceText = resourceText
        self.briefingParagraph = briefingParagraph
        self.correspondents = correspondents
        self.userIdentity = userIdentity?.isUseful == true ? userIdentity : nil
        self.framing = framing
    }

    /// A readout needs real document text; the pane simply shows no readout
    /// for an unextractable resource.
    public var hasEvidence: Bool {
        resourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

// MARK: - Result

public struct DeadlineResourceReadout: Sendable, Equatable, Codable {
    /// Flowing prose: what completing or using the resource involves.
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public protocol DeadlineResourceReadoutGenerating: Sendable {
    func readout(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineResourceReadout?
}

// MARK: - Prompt builder

public enum DeadlineResourceReadoutPromptBuilder {
    public static let maxResourceCharacters = 4_000
    static let maxBriefingCharacters = 600

    /// Framing-specific first sentence; the reading rules are shared.
    public static func instructions(for framing: DeadlineGuideFraming) -> String {
        let opening: String
        switch framing {
        case .deadline:
            opening = "Read one document connected to a dated deadline in a person's correspondence and write a close reading for the account owner: what completing or using this document actually involves."
        case .project:
            opening = "Read one document connected to an ongoing project in a person's correspondence and write a close reading for the account owner: what completing or using this document involves for advancing the project."
        }
        let noun = framing.subjectNoun
        // The deadline path keeps its original clause byte-for-byte (prefix
        // KV continuity); the project register speaks of dates generally.
        let dateClause = framing == .deadline
            ? "Do not restate the deadline date mechanically"
            : "Do not restate dates mechanically"
        return opening + " " + """
        Write 2–3 complete sentences, at most 90 words, describing concretely what the document asks for — its sections or fields, who must sign or stamp and where, what must be attached, submitted, or returned, and any instructions it states about how or where to act. \
        If the document is the owner's own working file, describe what it already covers relative to what the \(noun) demands. \
        Ground every statement strictly in the document text and the \(noun) framing provided; if the text does not support a claim, omit the claim. Never invent, complete, or guess URLs, phone numbers, addresses, amounts, or dates. \
        \(dateClause) and do not repeat the briefing paragraph when one is provided — extend it. \
        Speak naturally in complete sentences. Avoid the words "email", "message", "thread", "inbox", "node", "graph", "vector", "embedding", "constellation", "star", or "lens". Refer to people by name. This reading is shown to the account owner; use "you" or "your" only when the direction and identity evidence make the account owner unambiguous, and never call the account owner "the user". \
        Do not include reasoning, analysis, scratchpad text, or <think> tags. If the model supports thinking controls, disable thinking. Write in the target system language named below; keep filenames, URLs, and proper nouns in their original form.
        """
    }

    /// The `@Generable` guide strings for the Apple Foundation path — one per
    /// framing so neither register leaks into the other's schema description.
    public static let deadlineGuide = "A 2–3 sentence close reading (at most 90 words) of one deadline-connected document: what completing or using it involves — sections, fields, signatures, what to attach or return — grounded strictly in the provided document text. No invented tokens, no headings, no reasoning, no <think> tags, and never use the forbidden vocabulary."
    public static let projectGuide = "A 2–3 sentence close reading (at most 90 words) of one project-connected document: what completing or using it involves for advancing the project — sections, fields, signatures, what to attach or return — grounded strictly in the provided document text. No invented tokens, no headings, no reasoning, no <think> tags, and never use the forbidden vocabulary."

    public static func prompt(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        promptParts(input: input, targetLanguage: targetLanguage).prompt
    }

    public static func promptParts(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> PrefixCachedPrompt {
        let prefix = [
            instructions(for: input.framing),
            "",
            "Target system language: \(targetLanguage.promptDescription)",
            ""
        ].joined(separator: "\n") + "\n"

        var lines: [String] = []
        if let readerIdentity = readerIdentitySection(input.userIdentity) {
            lines.append(readerIdentity)
            lines.append("")
        }

        switch input.framing {
        case .deadline:
            lines.append("Deadline")
            lines.append("- Subject: \(clean(input.deadlineTitle, limit: 160))")
            lines.append("- Kind: \(clean(input.deadlineLabel, limit: 48))")
            lines.append("- Due: \(clean(input.deadlineDateText, limit: 80))")
        case .project:
            lines.append("Project")
            lines.append("- Name: \(clean(input.deadlineTitle, limit: 160))")
            lines.append("- Active: \(clean(input.deadlineDateText, limit: 80))")
        }
        if input.surfaceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("- Stated in the correspondence as: \u{201C}\(clean(input.surfaceText, limit: 120))\u{201D}")
        }

        if input.correspondents.isEmpty == false {
            let names = input.correspondents.prefix(DeadlineSummaryPromptBuilder.maxCorrespondents)
                .map { participant -> String in
                    let name = participant.name.isEmpty ? participant.email : participant.name
                    return clean(name, limit: 80)
                }
            lines.append("- From / correspondents: \(names.joined(separator: ", "))")
        }

        if let briefing = input.briefingParagraph,
           briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("")
            lines.append("Briefing already shown to the owner (do not repeat it):")
            lines.append(clean(briefing, limit: maxBriefingCharacters))
        }

        lines.append("")
        switch input.resourceOrigin {
        case .threadAttachment:
            lines.append("The document to read (attached to the correspondence): \(clean(input.resourceFilename, limit: 120))")
        case .workingFile:
            lines.append("The document to read (the account owner's own working file): \(clean(input.resourceFilename, limit: 120))")
        }
        lines.append("Document text:")
        lines.append(String(collapse(input.resourceText).prefix(maxResourceCharacters)))

        lines.append("")
        lines.append("/no_think")
        lines.append("")
        lines.append("Output contract:")
        lines.append("Return the 2–3 sentence reading, then write the single line \(GenerationStopPolicy.contextOrientationEndMarker) and stop immediately after it. Do not return /no_think, prompt text, role labels, chat markers, or special tokens such as <|im_start|>, <|im_end|>, <|endoftext|>, or </s>. No headings, no bullet characters, no reasoning, no <think> tags.")
        lines.append("")
        lines.append("<2–3 sentence reading>")
        lines.append(GenerationStopPolicy.contextOrientationEndMarker)
        return PrefixCachedPrompt(
            cacheKey: input.framing == .deadline ? "deadline-readout-v1" : "project-readout-v1",
            prefix: prefix,
            suffix: lines.joined(separator: "\n")
        )
    }

    private static func readerIdentitySection(_ identity: SummarizationUserIdentity?) -> String? {
        guard let identity, identity.isUseful else { return nil }
        var lines: [String] = ["Reader identity"]
        if identity.displayName.isEmpty == false {
            lines.append("- Account owner display name: \(clean(identity.displayName, limit: 120))")
        }
        if identity.primaryEmailAddress.isEmpty == false {
            lines.append("- Account owner primary address: \(clean(identity.primaryEmailAddress, limit: 160))")
        }
        lines.append("- Use this identity only to resolve references to the account owner. Same first name alone is not enough; require full name or address evidence.")
        return lines.joined(separator: "\n")
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = collapse(text)
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Post-processor

public enum DeadlineResourceReadoutPostProcessor {
    /// Cleans the raw model output into a single flowing reading. Returns `nil`
    /// when nothing usable remains.
    public static func process(_ raw: String) -> DeadlineResourceReadout? {
        let cleaned = DeadlineSummaryPostProcessor.clean(raw)
        let collapsed = cleaned
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.isEmpty == false else { return nil }
        return DeadlineResourceReadout(text: collapsed)
    }
}

// MARK: - MLX engine implementation

public final class MLXDeadlineResourceReadoutGenerator: DeadlineResourceReadoutGenerating, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        maxTokens: Int = 220,
        generationTaskPriority: TaskPriority = .utility
    ) {
        self.engine = engine
        self.maxTokens = maxTokens
        self.generationTaskPriority = generationTaskPriority
    }

    public func readout(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineResourceReadout? {
        guard engine.isModelLoaded else {
            throw DeadlineSummaryError.modelUnavailable
        }
        let prompt = DeadlineResourceReadoutPromptBuilder.promptParts(input: input, targetLanguage: targetLanguage)
        let engine = self.engine
        let maxTokens = self.maxTokens
        let priority = generationTaskPriority
        let raw: String
        do {
            raw = try await Task.detached(priority: priority) {
                try PrefixCachedGeneration.generate(engine: engine, prompt: prompt, maxTokens: maxTokens)
            }.value
        } catch {
            throw DeadlineSummaryError.underlying(error)
        }
        return DeadlineResourceReadoutPostProcessor.process(raw)
    }
}

// MARK: - Apple Foundation Models implementation

#if canImport(FoundationModels)
public final class AppleFoundationDeadlineResourceReadoutGenerator: DeadlineResourceReadoutGenerating, @unchecked Sendable {
    private static let generationOptions = GenerationOptions(temperature: 0.1, maximumResponseTokens: ApplePromptBudget.summaryResponseTokens)

    @Generable
    struct DeadlineResourceReading {
        @Guide(description: DeadlineResourceReadoutPromptBuilder.deadlineGuide)
        let reading: String
    }

    @Generable
    struct ProjectResourceReading {
        @Guide(description: DeadlineResourceReadoutPromptBuilder.projectGuide)
        let reading: String
    }

    public init() {}

    public func readout(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineResourceReadout? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw DeadlineSummaryError.modelUnavailable
        }
        let session = LanguageModelSession(instructions: DeadlineResourceReadoutPromptBuilder.instructions(for: input.framing))
        let prompt = DeadlineResourceReadoutPromptBuilder.prompt(input: input, targetLanguage: targetLanguage)
        do {
            let schema = input.framing == .deadline ? DeadlineResourceReading.generationSchema : ProjectResourceReading.generationSchema
            try await ApplePromptBudget.requireFits(
                prompt: prompt, instructions: DeadlineResourceReadoutPromptBuilder.instructions(for: input.framing), schema: schema
            )
            let reading: String
            switch input.framing {
            case .deadline:
                reading = try await session.respond(
                    to: prompt,
                    generating: DeadlineResourceReading.self,
                    options: Self.generationOptions
                ).content.reading
            case .project:
                reading = try await session.respond(
                    to: prompt,
                    generating: ProjectResourceReading.self,
                    options: Self.generationOptions
                ).content.reading
            }
            guard let result = DeadlineResourceReadoutPostProcessor.process(reading) else {
                throw DeadlineSummaryError.empty
            }
            return result
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw DeadlineSummaryError.empty
            default:
                throw DeadlineSummaryError.underlying(error)
            }
        } catch let error as DeadlineSummaryError {
            throw error
        } catch {
            throw DeadlineSummaryError.underlying(error)
        }
    }
}
#endif
