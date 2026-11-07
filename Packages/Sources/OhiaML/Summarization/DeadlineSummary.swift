// DeadlineSummary.swift
// Generates the deadline-briefing copy shown when the user hovers a deadline in
// the Projects-lens Deadlines tab (agenda row or calendar day). This is the
// deadline-level sibling of `ProjectSummary`: where the project briefing covers
// a whole project's arc, this distills one dated deadline — what it is for, what
// the account owner is expected to do, and the concrete actions the deadline
// demands (a site to visit, a document to complete and return, a number to call).
//
// The output is two parts: a flowing paragraph (2–3 sentences: purpose + what the
// owner must do) followed by a `NEEDS:` block of inline `[[KIND|label|value]]`
// action items. Qwen/MLX is preferred (wide context); Apple Foundation Models is
// a small-prompt fallback. Every concrete token the model emits (a URL, phone
// number, or return address) is grounded verbatim against the source email text
// so the pane never invents an actionable; document actions are produced
// deterministically from the real attachment records, never by the model.

import Foundation
import OSLog
import OhiaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

private let deadlineSummaryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "deadline-summary"
)

// MARK: - Inputs

/// Which obligation the guide distills: a single dated deadline (the Deadlines
/// tab), or an ongoing project (the Projects workroom). One pipeline — prompt
/// register, cache keys, and fingerprints branch on this; parsing, grounding,
/// document actions, and the readout machinery are shared.
public enum DeadlineGuideFraming: String, Sendable, Equatable, Codable {
    case deadline
    case project

    /// The noun the prompts use for the obligation.
    var subjectNoun: String {
        switch self {
        case .deadline: return "deadline"
        case .project: return "project"
        }
    }
}

/// One real attachment on the deadline's thread, surfaced so the pane can offer
/// an openable document chip. Produced from the persisted `Attachment` rows — the
/// model never invents these.
public struct DeadlineSummaryAttachment: Sendable, Equatable, Codable {
    public let filename: String
    public let mimeType: String
    /// The saved file's path, when the attachment was persisted to disk. `nil`
    /// leaves the chip non-openable (name only).
    public let filePath: String?
    /// Coarse document-kind hint (`detectedDocumentKind`), e.g. "pdf"/"form".
    public let documentKind: String?
    /// The document's extracted text (ingestion's `extractedTextPath` contents,
    /// or the on-drop extraction for a working file), capped by the input
    /// builder. Feeds the distillation prompt and the grounding atoms — a URL
    /// or address stated inside a form is as actionable as one in the emails —
    /// and powers the per-resource readout. `nil` when extraction produced
    /// nothing (image-only scan, unsupported type).
    public let extractedText: String?

    public init(
        filename: String,
        mimeType: String,
        filePath: String?,
        documentKind: String? = nil,
        extractedText: String? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.filePath = filePath
        self.documentKind = documentKind
        self.extractedText = extractedText
    }
}

/// One message body feeding the deadline briefing — the deadline-bearing message
/// plus the most recent context in either direction, cleaned and capped by the
/// input builder.
public struct DeadlineSummaryMessageBody: Sendable, Equatable {
    public let role: String
    public let senderName: String
    public let receivedAt: Date?
    public let text: String

    public init(role: String, senderName: String, receivedAt: Date?, text: String) {
        self.role = role
        self.senderName = senderName
        self.receivedAt = receivedAt
        self.text = text
    }
}

public struct DeadlineSummaryInput: Sendable, Equatable {
    public let accountID: UUID?
    public let title: String
    public let deadlineLabel: String
    public let deadlineDate: Date
    /// Human-readable deadline date already formatted for the prompt.
    public let deadlineDateText: String
    /// The phrase in the email that stated the deadline ("by Friday", "5/30").
    public let surfaceText: String
    /// Non-user correspondents (display names / addresses), for grounding a
    /// return address and letting the model name who is asking.
    public let correspondents: [DeadlineSummaryParticipant]
    /// Deadline-bearing message body first, then recent context in either
    /// direction so outgoing replies can advance the reported status.
    public let bodies: [DeadlineSummaryMessageBody]
    /// Real, non-inline attachments across the thread.
    public let attachments: [DeadlineSummaryAttachment]
    /// Files the account owner is preparing for this deadline (dropped onto the
    /// guide pane). Context for the distillation and grounding only — they never
    /// mint document action rows; the pane's FILES section lists them itself.
    public let workingFiles: [DeadlineSummaryAttachment]
    public let userIdentity: SummarizationUserIdentity?
    /// Deadline (dated obligation) or project (ongoing) register. For
    /// `.project`, `deadlineDateText` carries the activity period and
    /// `surfaceText` is empty.
    public let framing: DeadlineGuideFraming

    public init(
        accountID: UUID? = nil,
        title: String,
        deadlineLabel: String,
        deadlineDate: Date,
        deadlineDateText: String,
        surfaceText: String,
        correspondents: [DeadlineSummaryParticipant],
        bodies: [DeadlineSummaryMessageBody],
        attachments: [DeadlineSummaryAttachment],
        workingFiles: [DeadlineSummaryAttachment] = [],
        userIdentity: SummarizationUserIdentity? = nil,
        framing: DeadlineGuideFraming = .deadline
    ) {
        self.accountID = accountID
        self.title = title
        self.deadlineLabel = deadlineLabel
        self.deadlineDate = deadlineDate
        self.deadlineDateText = deadlineDateText
        self.surfaceText = surfaceText
        self.correspondents = correspondents
        self.bodies = bodies
        self.attachments = attachments
        self.workingFiles = workingFiles
        self.userIdentity = userIdentity?.isUseful == true ? userIdentity : nil
        self.framing = framing
    }

    /// The concatenated body and document text used to ground model-emitted
    /// tokens. Document text is a legitimate grounding source: a submission URL
    /// or return address stated inside an attached form is as real as one in
    /// the correspondence.
    public var groundingText: String {
        var parts = bodies.map(\.text)
        parts.append(contentsOf: attachments.compactMap(\.extractedText))
        parts.append(contentsOf: workingFiles.compactMap(\.extractedText))
        return parts.joined(separator: "\n")
    }

    /// True when there is at least a body or a stated deadline phrase to work
    /// from. The service short-circuits to `nil` otherwise so the UI shows a
    /// neutral "no summary" copy instead of asking the model to invent one.
    public var hasEvidence: Bool {
        if attachments.isEmpty == false { return true }
        if surfaceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        return bodies.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
}

/// A non-user correspondent on the deadline thread.
public struct DeadlineSummaryParticipant: Sendable, Equatable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

// MARK: - Result

/// One concrete thing the deadline demands. `link`/`call`/`returnTo` carry a
/// grounded token in `value`; `document` carries a real attachment (`value` is
/// the filename, `filePath` opens it); `action` is a step with no token.
public struct DeadlineActionItem: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case link
        case document
        case call
        case returnTo
        case action
    }

    public let id: String
    public let kind: Kind
    /// What to do — the instruction phrasing.
    public let label: String
    /// The concrete token (URL / phone / email / filename), when the item carries
    /// one. Always grounded in the source for link/call/returnTo.
    public let value: String?
    /// Secondary line, e.g. the return-to address folded onto a document row.
    public let detail: String?
    /// Openable path for a `document` item backed by a saved attachment.
    public let filePath: String?

    public init(
        id: String,
        kind: Kind,
        label: String,
        value: String?,
        detail: String? = nil,
        filePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
        self.filePath = filePath
    }

    /// The id the post-processor mints for a document action. Exported so UI
    /// readout keys stay in lockstep with the step rows they attach to.
    public static func documentID(filename: String) -> String {
        "document:\(filename.lowercased())"
    }
}

public struct DeadlineSummaryResult: Sendable, Equatable, Codable {
    /// Flowing paragraph: what the deadline is for and what the owner must do.
    public let paragraph: String
    /// The concrete actions the deadline demands, in render order.
    public let actions: [DeadlineActionItem]

    public init(paragraph: String, actions: [DeadlineActionItem]) {
        self.paragraph = paragraph
        self.actions = actions
    }
}

public enum DeadlineSummaryError: Error {
    case empty
    case modelUnavailable
    case underlying(Error)
}

public protocol DeadlineSummaryGenerating: Sendable {
    func summarize(
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineSummaryResult?
}

// MARK: - Prompt builder

public enum DeadlineSummaryPromptBuilder {
    public static let needsMarker = "NEEDS:"
    public static let maxBodyCharacters = 4_000
    public static let maxAttachments = 6
    public static let maxCorrespondents = 5
    public static let maxActionItems = 6
    /// Per-document and whole-section caps for the extracted document contents
    /// fed to the distillation (the readout pass reads each document more
    /// deeply; this section only has to orient the summary and ground tokens).
    public static let maxDocumentCharacters = 1_800
    public static let maxDocumentSectionCharacters = 5_400
    public static let maxWorkingFiles = 6

    /// Framing-specific part one; part two and the register rules are shared.
    public static func instructions(for framing: DeadlineGuideFraming) -> String {
        let partOne: String
        switch framing {
        case .deadline:
            partOne = """
            Distil a single dated deadline drawn from a person's correspondence into a short briefing for the account owner. Produce two parts. \
            Part one: a flowing paragraph of 2–3 complete sentences saying what the deadline is for and its current status — the deliverable, decision, or reply that remains due. Use each correspondence item's direction label and date to determine the latest state. Treat an action the account owner states they completed in outgoing correspondence as completed. Sending an outgoing reply itself completes any requested reply or confirmation that its content answers. If the owner has acted and the next step belongs to a correspondent, say who or what the deadline is waiting on. Do not emit a completed action in NEEDS. Be concrete and specific to this deadline; do not restate the date mechanically.
            """
        case .project:
            partOne = """
            Distil an ongoing project drawn from a person's correspondence into a short briefing for the account owner. Produce two parts. \
            Part one: a flowing paragraph of 2–4 complete sentences saying what the project is about, where it stands, and what the account owner must do next to advance or complete it — the outstanding deliverables, decisions, or replies. Be concrete and specific to this project; do not merely recount who wrote.
            """
        }
        return partOne + " " + sharedContract(noun: framing.subjectNoun)
    }

    /// Part two (the NEEDS token contract) plus the grounding, vocabulary,
    /// identity, and thinking rules — identical for both framings.
    private static func sharedContract(noun: String) -> String {
        """
        Part two: on the same output, after the paragraph, write the literal marker \(needsMarker) followed by the concrete actions the \(noun) demands, each as one inline token of the exact form [[KIND|label|value]] with no line breaks. Use these KINDs only: \
        LINK — a website the owner must visit to act (label = what the site is for, value = the URL). \
        CALL — a phone number the owner must call (label = why to call, value = the phone number). \
        RETURN — an address the owner must send or return something to (label = what to send, value = the email address or postal address). \
        ACTION — a required step that has no website, number, or address (label = the step, value = -). \
        Do NOT emit a document or attachment action; attached files are surfaced separately. Emit at most \(maxActionItems) items, most important first, and omit the whole \(needsMarker) block if there is genuinely nothing concrete to do. \
        Grounding is mandatory: every URL, phone number, and address you place in a value MUST appear verbatim in the provided email text. Never invent, complete, guess, or normalise a URL, number, or address; if you are not certain it appears in the text, omit that item. \
        Speak naturally in complete sentences in part one. Avoid the words "email", "message", "thread", "inbox", "node", "graph", "vector", "embedding", "constellation", "star", or "lens". Refer to people by name. This briefing is shown to the account owner; use "you" or "your" only when the direction and identity evidence make the account owner unambiguous, and never call the account owner "the user". \
        Do not include reasoning, analysis, scratchpad text, or <think> tags. If the model supports thinking controls, disable thinking. Write part one and every action label in the target system language named below, translating source-language names and terms; keep KIND keywords and the values in their original form.
        """
    }

    /// The `@Generable` guide strings for the Apple Foundation path — one per
    /// framing so neither register leaks into the other's schema description.
    public static let deadlineGuide = "A deadline briefing in two parts: first a 2–3 sentence paragraph on what the deadline is for and its current status, treating the account owner's outgoing replies as completed progress and naming who or what it is waiting on; then the marker \"\(needsMarker)\" followed only by still-outstanding concrete actions as inline [[KIND|label|value]] tokens (KIND in LINK/CALL/RETURN/ACTION). Every URL, phone number, and address must appear verbatim in the source text — omit anything uncertain. No completed or document actions, no headings, no reasoning, no <think> tags, and never use the forbidden vocabulary."
    public static let projectGuide = "A project briefing in two parts: first a 2–4 sentence paragraph on what the project is about, where it stands, and what the account owner must do next to advance or complete it; then the marker \"\(needsMarker)\" followed by concrete actions as inline [[KIND|label|value]] tokens (KIND in LINK/CALL/RETURN/ACTION). Every URL, phone number, and address must appear verbatim in the source text — omit anything uncertain. No document actions, no headings, no reasoning, no <think> tags, and never use the forbidden vocabulary."

    public static func prompt(input: DeadlineSummaryInput, targetLanguage: SummarizationTargetLanguage) -> String {
        promptParts(input: input, targetLanguage: targetLanguage).prompt
    }

    public static func promptParts(
        input: DeadlineSummaryInput,
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
            lines.append("- Subject: \(clean(input.title, limit: 160))")
            lines.append("- Kind: \(clean(input.deadlineLabel, limit: 48))")
            lines.append("- Due: \(clean(input.deadlineDateText, limit: 80))")
        case .project:
            lines.append("Project")
            lines.append("- Name: \(clean(input.title, limit: 160))")
            lines.append("- Active: \(clean(input.deadlineDateText, limit: 80))")
        }
        if input.surfaceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("- Stated in the correspondence as: \u{201C}\(clean(input.surfaceText, limit: 120))\u{201D}")
        }

        if input.correspondents.isEmpty == false {
            let names = input.correspondents.prefix(maxCorrespondents).map { participant -> String in
                let name = participant.name.isEmpty ? participant.email : participant.name
                if participant.email.isEmpty || participant.name.isEmpty {
                    return clean(name, limit: 80)
                }
                return "\(clean(name, limit: 80)) <\(clean(participant.email, limit: 120))>"
            }
            lines.append("")
            lines.append("From / correspondents: \(names.joined(separator: ", "))")
        }

        if input.attachments.isEmpty == false {
            lines.append("")
            lines.append("Attached files (surfaced separately — reference by name if the owner must return one, but do not emit a document action):")
            for attachment in input.attachments.prefix(maxAttachments) {
                let kind = attachment.documentKind.map { " · \(clean($0, limit: 32))" } ?? ""
                lines.append("- \(clean(attachment.filename, limit: 120))\(kind)")
            }
        }

        if input.workingFiles.isEmpty == false {
            lines.append("")
            lines.append("Files the account owner is already preparing for this \(input.framing.subjectNoun) (do not tell the owner to obtain these; they exist):")
            for file in input.workingFiles.prefix(maxWorkingFiles) {
                lines.append("- \(clean(file.filename, limit: 120))")
            }
        }

        let bodyText = boundedBodyText(input)
        if bodyText.isEmpty == false {
            lines.append("")
            lines.append("Correspondence text (a valid source for URLs, phone numbers, and addresses):")
            lines.append(bodyText)
        }

        let documentText = boundedDocumentText(input)
        if documentText.isEmpty == false {
            lines.append("")
            lines.append("Attached document contents (also a valid source for URLs, phone numbers, and addresses):")
            lines.append(documentText)
        }

        lines.append("")
        lines.append("/no_think")
        lines.append("")
        lines.append("Output contract:")
        lines.append("Return the paragraph, then the marker \(needsMarker), then the [[KIND|label|value]] action tokens on the same flow, then write the single line \(GenerationStopPolicy.contextOrientationEndMarker) and stop immediately after it. Do not return /no_think, prompt text, role labels, chat markers, or special tokens such as <|im_start|>, <|im_end|>, <|endoftext|>, or </s>. No headings, no bullet characters, no reasoning, no <think> tags. Every value in a LINK/CALL/RETURN token must appear verbatim in the correspondence text above; omit the token otherwise.")
        lines.append("")
        lines.append(input.framing == .deadline ? "<2–3 sentence paragraph>" : "<2–4 sentence paragraph>")
        lines.append("\(needsMarker) [[LINK|label|value]] [[CALL|label|value]] [[RETURN|label|value]] [[ACTION|label|-]]")
        lines.append(GenerationStopPolicy.contextOrientationEndMarker)
        return PrefixCachedPrompt(
            cacheKey: input.framing == .deadline ? "deadline-summary-v4" : "project-guide-v2",
            prefix: prefix,
            suffix: lines.joined(separator: "\n")
        )
    }

    /// Concatenates the body texts, labelled by sender/direction, capped at
    /// `maxBodyCharacters` total so the prompt stays bounded for a hover.
    private static func boundedBodyText(_ input: DeadlineSummaryInput) -> String {
        let prepared = input.bodies.compactMap { body -> (body: DeadlineSummaryMessageBody, text: String)? in
            let text = collapse(body.text)
            return text.isEmpty ? nil : (body, text)
        }
        var remaining = maxBodyCharacters
        var blocks: [String] = []
        for (index, item) in prepared.enumerated() {
            guard remaining > 0 else { break }
            let bodiesRemaining = prepared.count - index
            let fairShare = max(1, remaining / bodiesRemaining)
            let slice = String(item.text.prefix(fairShare))
            remaining -= slice.count
            let when = item.body.receivedAt.map { dateFormatter.string(from: $0) } ?? "—"
            let sender = clean(item.body.senderName, limit: 80)
            blocks.append("[\(item.body.role); \(when); From: \(sender)] \(slice)")
        }
        return blocks.joined(separator: "\n")
    }

    /// Concatenates the extracted document texts (thread attachments first, then
    /// working files), labelled by filename, each capped per document and the
    /// whole section capped so the prompt stays bounded.
    private static func boundedDocumentText(_ input: DeadlineSummaryInput) -> String {
        var remaining = maxDocumentSectionCharacters
        var blocks: [String] = []
        let attachmentDocs = input.attachments.prefix(maxAttachments).map { ($0, "document") }
        let workingDocs = input.workingFiles.prefix(maxWorkingFiles).map { ($0, "owner's working file") }
        for (file, role) in attachmentDocs + workingDocs {
            guard remaining > 0 else { break }
            guard let raw = file.extractedText else { continue }
            let text = collapse(raw)
            guard text.isEmpty == false else { continue }
            let slice = String(text.prefix(min(remaining, maxDocumentCharacters)))
            remaining -= slice.count
            blocks.append("[\(role): \(clean(file.filename, limit: 120))] \(slice)")
        }
        return blocks.joined(separator: "\n")
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
        if identity.aliasEmailAddresses.isEmpty == false {
            let aliases = identity.aliasEmailAddresses.prefix(8).map { clean($0, limit: 120) }.joined(separator: ", ")
            if aliases.isEmpty == false {
                lines.append("- Other outgoing addresses for the same person: \(aliases)")
            }
        }
        lines.append("- Use this identity only to resolve references to the account owner. Same first name alone is not enough; require full name or address evidence.")
        return lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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

// MARK: - Post-processor (clean + parse + ground + assemble)

public enum DeadlineSummaryPostProcessor {
    /// Turns the raw model output into a grounded result. The model supplies the
    /// paragraph and the LINK/CALL/RETURN/ACTION tokens; every token's concrete
    /// value is validated against the source text, and document actions are added
    /// deterministically from the real attachments. Returns `nil` when there is no
    /// usable paragraph.
    public static func process(_ raw: String, input: DeadlineSummaryInput) -> DeadlineSummaryResult? {
        let cleaned = clean(raw)
        guard cleaned.isEmpty == false else { return nil }

        let marker = DeadlineSummaryPromptBuilder.needsMarker
        let paragraphSource: String
        let itemsSource: String
        if let markerRange = cleaned.range(of: marker, options: [.caseInsensitive]) {
            paragraphSource = String(cleaned[..<markerRange.lowerBound])
            itemsSource = String(cleaned[markerRange.upperBound...])
        } else {
            paragraphSource = cleaned
            itemsSource = ""
        }

        let paragraph = collapseWhitespace(paragraphSource)
        guard paragraph.isEmpty == false else { return nil }

        let modelActions = groundedModelActions(from: itemsSource, input: input)
        let documentActions = documentActions(from: input)
        let actions = assemble(documents: documentActions, model: modelActions)
        return DeadlineSummaryResult(paragraph: paragraph, actions: actions)
    }

    // MARK: Cleaning

    /// Self-contained cleaner that strips thinking tags, control tokens, and the
    /// stop marker while PRESERVING the inline `[[…]]` structure (unlike the
    /// shared context-orientation cleaner, which also dedups paragraphs).
    static func clean(_ raw: String) -> String {
        var s = raw
        // Drop <think>…</think> (and any unterminated trailing think block).
        s = s.replacingOccurrences(
            of: "(?is)<think>.*?</think>", with: " ", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "(?is)<think>.*", with: " ", options: .regularExpression
        )
        // Truncate at the end marker or any leaked chat/control artifact.
        for artifact in stopArtifacts {
            if let range = s.range(of: artifact, options: [.caseInsensitive]) {
                s = String(s[..<range.lowerBound])
            }
        }
        // Remove any residual special tokens.
        for token in controlTokens {
            s = s.replacingOccurrences(of: token, with: " ", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let stopArtifacts: [String] = [
        GenerationStopPolicy.contextOrientationEndMarker,
        "<|im_end|>",
        "<|im_start|>",
        "<|endoftext|>",
        "</s>"
    ]

    private static let controlTokens: [String] = [
        "<|im_end|>", "<|im_start|>", "<|endoftext|>", "</s>", "/no_think", "assistant:", "```"
    ]

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Parsing + grounding

    private struct ParsedToken {
        let kind: String
        let label: String
        let value: String?
    }

    private static func parseTokens(_ source: String) -> [ParsedToken] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(.*?)\]\]"#, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var tokens: [ParsedToken] = []
        for match in regex.matches(in: source, range: range) {
            guard match.numberOfRanges > 1, let inner = Range(match.range(at: 1), in: source) else { continue }
            let fields = source[inner].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { collapseWhitespace(String($0)) }
            guard fields.isEmpty == false else { continue }
            let kind = fields[0].uppercased()
            let label = fields.count > 1 ? fields[1] : ""
            let rawValue = fields.count > 2 ? fields[2] : nil
            let value = normalizeValue(rawValue)
            tokens.append(ParsedToken(kind: kind, label: label, value: value))
        }
        return tokens
    }

    private static func normalizeValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "-" || trimmed.lowercased() == "value" { return nil }
        return trimmed
    }

    private static func groundedModelActions(from source: String, input: DeadlineSummaryInput) -> [DeadlineActionItem] {
        guard source.isEmpty == false else { return [] }
        let atoms = GroundingAtoms(text: input.groundingText, knownEmails: knownEmailSet(input))

        var result: [DeadlineActionItem] = []
        var seen = Set<String>()
        for token in parseTokens(source) {
            guard result.count < DeadlineSummaryPromptBuilder.maxActionItems else { break }
            let item: DeadlineActionItem?
            switch token.kind {
            case "LINK":
                item = linkItem(token, atoms: atoms)
            case "CALL", "PHONE":
                item = callItem(token, atoms: atoms)
            case "RETURN", "REPLY", "SEND":
                item = returnItem(token, atoms: atoms)
            case "ACTION", "STEP", "TODO":
                item = actionItem(token)
            default:
                item = nil
            }
            guard let item, item.label.isEmpty == false || item.value != nil else { continue }
            // Dedupe on the normalized id (host/path for links, digits for
            // phones) — the raw value would let `https://acme.com/x` and
            // `www.acme.com/x` through as two rows with one ForEach id.
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
        }
        return result
    }

    private static func linkItem(_ token: ParsedToken, atoms: GroundingAtoms) -> DeadlineActionItem? {
        guard let value = token.value else { return nil }
        let (host, path) = urlHostPath(value)
        guard host.contains("."), atoms.groundsURL(host: host, path: path) else { return nil }
        return DeadlineActionItem(id: "link:\(host)/\(path)", kind: .link, label: token.label, value: value)
    }

    private static func callItem(_ token: ParsedToken, atoms: GroundingAtoms) -> DeadlineActionItem? {
        guard let value = token.value else { return nil }
        let digits = normalizedDigits(value)
        guard digits.count >= 7, atoms.phoneDigits.contains(digits) else { return nil }
        return DeadlineActionItem(id: "call:\(digits)", kind: .call, label: token.label, value: value)
    }

    private static func returnItem(_ token: ParsedToken, atoms: GroundingAtoms) -> DeadlineActionItem? {
        guard let value = token.value else { return nil }
        let lowered = value.lowercased()
        let grounded: Bool
        if value.contains("@") {
            // An email must match a known correspondent/owner address or an email
            // that actually occurs in the source — an exact atom match, never a
            // substring (so `reply@x` cannot ground off `noreply@x`).
            grounded = atoms.emails.contains(lowered)
        } else {
            // A postal / free-form address can't be atomised; require its
            // whitespace-collapsed form to occur in the collapsed source.
            let collapsedValue = collapseWhitespace(value).lowercased()
            grounded = collapsedValue.count >= 6 && atoms.collapsedText.contains(collapsedValue)
        }
        guard grounded else { return nil }
        return DeadlineActionItem(id: "return:\(lowered)", kind: .returnTo, label: token.label, value: value)
    }

    // MARK: Grounding atoms

    /// Source-derived atoms so a model token is grounded only by an EXACT atom
    /// match (a whole URL host+path, a whole phone number, a whole email), never
    /// a raw substring — closing the near-miss hole where `acme.com` could ground
    /// off `notacme.com`, or a fabricated number off a digit run spanning
    /// unrelated numbers.
    private struct GroundingAtoms {
        let urls: [(host: String, path: String)]
        let phoneDigits: Set<String>
        let emails: Set<String>
        let collapsedText: String

        init(text: String, knownEmails: Set<String>) {
            collapsedText = DeadlineSummaryPostProcessor.collapseWhitespace(text).lowercased()
            emails = knownEmails.union(
                DeadlineSummaryPostProcessor.matches(DeadlineSummaryPostProcessor.emailPattern, in: text)
                    .map { $0.lowercased() }
            )
            phoneDigits = Set(
                DeadlineSummaryPostProcessor.matches(DeadlineSummaryPostProcessor.phonePattern, in: text)
                    .map { DeadlineSummaryPostProcessor.normalizedDigits($0) }
                    .filter { $0.count >= 7 }
            )
            urls = DeadlineSummaryPostProcessor.matches(DeadlineSummaryPostProcessor.urlPattern, in: text)
                .map { DeadlineSummaryPostProcessor.urlHostPath($0) }
                .filter { $0.host.contains(".") }
        }

        /// Grounds when a source URL shares the EXACT host and the model path is
        /// the source path, empty (the domain root of a real deeper URL), or a
        /// real parent of the source path. A model-invented deeper/other path on
        /// a matching host is rejected.
        func groundsURL(host: String, path: String) -> Bool {
            for atom in urls where atom.host == host {
                if path == atom.path { return true }
                if path.isEmpty { return true }
                if atom.path.hasPrefix(path + "/") { return true }
            }
            return false
        }
    }

    private static let urlPattern = #"(?i)(?:https?://|www\.)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:/[^\s<>"'()\[\]]*)?"#
    private static let phonePattern = #"[\d\x{FF10}-\x{FF19}][\d\x{FF10}-\x{FF19} ().+\-\x{3000}\x{FF0D}]{5,}[\d\x{FF10}-\x{FF19}]"#
    private static let emailPattern = #"(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Normalises a URL to (host, path): drops scheme/`www.`, query, fragment,
    /// trailing punctuation, and a trailing slash, lowercased. Shared by both
    /// atom extraction and model-value checking so the two sides align.
    private static func urlHostPath(_ s: String) -> (host: String, path: String) {
        var v = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://", "mailto:"] where v.hasPrefix(scheme) {
            v = String(v.dropFirst(scheme.count))
        }
        if v.hasPrefix("www.") { v = String(v.dropFirst(4)) }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: " .,)]}>\"'"))
        let hostEnd = v.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
        let host = hostEnd.map { String(v[..<$0]) } ?? v
        var path = hostEnd.map { String(v[$0...]) } ?? ""
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<query])
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ .,)]}>\"'"))
        return (host, path)
    }

    /// Folds ASCII and full-width (`０-９`) decimal digits to a bare ASCII digit
    /// string, so a phone written in full-width grounds a model value written in
    /// ASCII and vice-versa.
    private static func normalizedDigits(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars where CharacterSet.decimalDigits.contains(scalar) {
            if let numeric = scalar.properties.numericValue,
               let digit = Int(exactly: numeric),
               (0...9).contains(digit),
               let ascii = Unicode.Scalar(48 + digit) {
                out.unicodeScalars.append(ascii)
            }
        }
        return out
    }

    private static func actionItem(_ token: ParsedToken) -> DeadlineActionItem? {
        let label = token.label.isEmpty ? (token.value ?? "") : token.label
        guard label.isEmpty == false else { return nil }
        return DeadlineActionItem(
            id: "action:\(label.lowercased())",
            kind: .action,
            label: label,
            value: nil
        )
    }

    // MARK: Deterministic document actions

    private static func documentActions(from input: DeadlineSummaryInput) -> [DeadlineActionItem] {
        input.attachments.prefix(DeadlineSummaryPromptBuilder.maxAttachments).map { attachment in
            DeadlineActionItem(
                id: DeadlineActionItem.documentID(filename: attachment.filename),
                kind: .document,
                label: "",
                value: attachment.filename,
                detail: nil,
                filePath: attachment.filePath
            )
        }
    }

    /// Orders the sections and folds a lone return address onto a lone document.
    private static func assemble(documents: [DeadlineActionItem], model: [DeadlineActionItem]) -> [DeadlineActionItem] {
        let links = model.filter { $0.kind == .link }
        let calls = model.filter { $0.kind == .call }
        var returns = model.filter { $0.kind == .returnTo }
        let actions = model.filter { $0.kind == .action }
        var documents = documents

        // A single document + single return address reads best as one row.
        if documents.count == 1, returns.count == 1, let ret = returns.first {
            let doc = documents[0]
            documents[0] = DeadlineActionItem(
                id: doc.id,
                kind: .document,
                label: doc.label,
                value: doc.value,
                detail: returnDetail(ret),
                filePath: doc.filePath
            )
            returns = []
        }

        return links + documents + calls + returns + actions
    }

    private static func returnDetail(_ item: DeadlineActionItem) -> String {
        if let value = item.value {
            let verb = item.label.isEmpty ? "Return to" : item.label
            return "\(verb): \(value)"
        }
        return item.label
    }

    // MARK: Helpers

    private static func knownEmailSet(_ input: DeadlineSummaryInput) -> Set<String> {
        var emails = Set<String>()
        for participant in input.correspondents {
            let email = participant.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if email.isEmpty == false { emails.insert(email) }
        }
        if let identity = input.userIdentity {
            let primary = identity.primaryEmailAddress.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if primary.isEmpty == false { emails.insert(primary) }
            for alias in identity.aliasEmailAddresses {
                let a = alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if a.isEmpty == false { emails.insert(a) }
            }
        }
        return emails
    }
}

// MARK: - MLX engine implementation

public final class MLXDeadlineSummarizer: DeadlineSummaryGenerating, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        maxTokens: Int = 360,
        generationTaskPriority: TaskPriority = .utility
    ) {
        self.engine = engine
        self.maxTokens = maxTokens
        self.generationTaskPriority = generationTaskPriority
    }

    public func summarize(
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineSummaryResult? {
        guard engine.isModelLoaded else {
            throw DeadlineSummaryError.modelUnavailable
        }
        let prompt = DeadlineSummaryPromptBuilder.promptParts(input: input, targetLanguage: targetLanguage)
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
        return DeadlineSummaryPostProcessor.process(raw, input: input)
    }
}

// MARK: - Apple Foundation Models implementation

#if canImport(FoundationModels)
public final class AppleFoundationDeadlineSummarizer: DeadlineSummaryGenerating, @unchecked Sendable {
    private static let generationOptions = GenerationOptions(temperature: 0.1, maximumResponseTokens: ApplePromptBudget.summaryResponseTokens)

    @Generable
    struct DeadlineBriefing {
        @Guide(description: DeadlineSummaryPromptBuilder.deadlineGuide)
        let briefing: String
    }

    @Generable
    struct ProjectBriefing {
        @Guide(description: DeadlineSummaryPromptBuilder.projectGuide)
        let briefing: String
    }

    public init() {}

    public func summarize(
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> DeadlineSummaryResult? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw DeadlineSummaryError.modelUnavailable
        }
        let session = LanguageModelSession(instructions: DeadlineSummaryPromptBuilder.instructions(for: input.framing))
        let prompt = DeadlineSummaryPromptBuilder.prompt(input: input, targetLanguage: targetLanguage)
        do {
            let schema = input.framing == .deadline ? DeadlineBriefing.generationSchema : ProjectBriefing.generationSchema
            try await ApplePromptBudget.requireFits(
                prompt: prompt, instructions: DeadlineSummaryPromptBuilder.instructions(for: input.framing), schema: schema
            )
            let briefing: String
            switch input.framing {
            case .deadline:
                briefing = try await session.respond(
                    to: prompt,
                    generating: DeadlineBriefing.self,
                    options: Self.generationOptions
                ).content.briefing
            case .project:
                briefing = try await session.respond(
                    to: prompt,
                    generating: ProjectBriefing.self,
                    options: Self.generationOptions
                ).content.briefing
            }
            guard let result = DeadlineSummaryPostProcessor.process(briefing, input: input) else {
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

// MARK: - Service actor (cache + Apple/MLX cascade)

public actor DeadlineSummaryService {
    public typealias AvailabilityProvider = @Sendable () -> AppleIntelligenceAvailability.State

    private let appleSummarizer: (any DeadlineSummaryGenerating)?
    private let mlxSummarizer: any DeadlineSummaryGenerating
    private let appleReadoutGenerator: (any DeadlineResourceReadoutGenerating)?
    private let mlxReadoutGenerator: (any DeadlineResourceReadoutGenerating)?
    private let availabilityProvider: AvailabilityProvider
    private let persistentCacheURL: URL?
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let displayLanguageGuard: DisplayLanguageGuard?
    private var appleEnabled: Bool

    private var inFlight: [String: Task<DeadlineSummaryResult?, Never>] = [:]
    private var inFlightGenerations: [String: UUID] = [:]
    private var memoryCache: [String: DeadlineSummaryResult] = [:]
    private var persistentCache: [String: PersistentCacheEntry] = [:]
    private var lru: [String] = []
    private var readoutInFlight: [String: Task<DeadlineResourceReadout?, Never>] = [:]
    private var readoutInFlightGenerations: [String: UUID] = [:]
    private var readoutMemoryCache: [String: DeadlineResourceReadout] = [:]
    private var readoutPersistentCache: [String: PersistentReadoutEntry] = [:]
    private var readoutLRU: [String] = []
    private let capacity: Int

    public init(
        apple: (any DeadlineSummaryGenerating)?,
        mlx: any DeadlineSummaryGenerating,
        appleReadout: (any DeadlineResourceReadoutGenerating)? = nil,
        mlxReadout: (any DeadlineResourceReadoutGenerating)? = nil,
        appleEnabled: Bool,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        capacity: Int = 96,
        persistentCacheURL: URL? = nil,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        availabilityProvider: @escaping AvailabilityProvider = { AppleIntelligenceAvailability.current() }
    ) {
        self.displayLanguageGuard = displayLanguageGuard
        self.appleSummarizer = apple
        self.mlxSummarizer = mlx
        self.appleReadoutGenerator = appleReadout
        self.mlxReadoutGenerator = mlxReadout
        self.appleEnabled = appleEnabled
        self.capacity = max(1, capacity)
        self.persistentCacheURL = persistentCacheURL
        self.availabilityProvider = availabilityProvider
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        let loaded = Self.loadPersistentCaches(from: persistentCacheURL)
        self.persistentCache = loaded.summaries
        self.readoutPersistentCache = loaded.readouts
    }

    public func setAppleEnabled(_ enabled: Bool) {
        appleEnabled = enabled
    }

    public func summary(
        for deadlineKey: String,
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) async -> DeadlineSummaryResult? {
        guard !AccountDisconnectionRequest.isPending else { return nil }
        let fingerprint = Self.fingerprint(input: input, targetLanguage: targetLanguage)
        let cacheKey = Self.cacheKey(deadlineKey: deadlineKey, fingerprint: fingerprint)

        let guardrail = displayLanguageGuard
        if let cached = memoryCache[cacheKey],
           Self.isDisplayable(cached, targetLanguage: targetLanguage, guardrail: guardrail) {
            touch(cacheKey)
            return cached
        }

        if let entry = persistentCache[cacheKey],
           Self.isDisplayable(entry.result, targetLanguage: targetLanguage, guardrail: guardrail) {
            let restored = entry.result
            storeInMemory(cacheKey, restored)
            return restored
        }

        if let task = inFlight[cacheKey] {
            let result = await task.value
            guard !task.isCancelled, !AccountDisconnectionRequest.isPending else { return nil }
            return result
        }

        guard input.hasEvidence else { return nil }

        let apple = appleSummarizer
        let mlx = mlxSummarizer
        let enabled = appleEnabled
        let availability = availabilityProvider
        let activityPublisher = modelActivityStatusPublisher
        let generation = UUID()
        let task = Task<DeadlineSummaryResult?, Never>(priority: .userInitiated) {
            let activityToken = activityPublisher?.begin(
                .summarizing,
                source: input.framing == .deadline ? "deadline-summary" : "project-guide",
                accountID: input.accountID
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
            ) else { return nil }
            guard let guardrail else { return produced }
            return await Self.displayed(produced, input: input, targetLanguage: targetLanguage, guardrail: guardrail)
        }
        inFlight[cacheKey] = task
        inFlightGenerations[cacheKey] = generation
        let result = await task.value
        let canStore = inFlightGenerations[cacheKey] == generation
        if canStore {
            inFlight[cacheKey] = nil
            inFlightGenerations[cacheKey] = nil
        }
        guard canStore, !AccountDisconnectionRequest.isPending, let result else { return nil }
        if canStore {
            store(cacheKey, deadlineKey: deadlineKey, fingerprint: fingerprint, result)
        }
        return result
    }

    /// The deep-read of one resource (an attached document or the owner's
    /// working file) for the guide pane. Same cache/in-flight discipline as
    /// `summary(for:input:)`; keys share the deadline's prefix so
    /// `invalidate(deadlineKey:)` drops readouts and summary together.
    public func readout(
        for deadlineKey: String,
        resourceKey: String,
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) async -> DeadlineResourceReadout? {
        guard !AccountDisconnectionRequest.isPending else { return nil }
        let fingerprint = Self.readoutFingerprint(input: input, targetLanguage: targetLanguage)
        let cacheKey = "\(deadlineKey):readout:\(resourceKey):\(fingerprint)"

        let guardrail = displayLanguageGuard
        if let cached = readoutMemoryCache[cacheKey],
           DisplayLanguageGuard.isDisplayable(cached.text, targetLanguage: targetLanguage, guardrail: guardrail) {
            touchReadout(cacheKey)
            return cached
        }

        if let entry = readoutPersistentCache[cacheKey],
           DisplayLanguageGuard.isDisplayable(entry.readout.text, targetLanguage: targetLanguage, guardrail: guardrail) {
            storeReadoutInMemory(cacheKey, entry.readout)
            return entry.readout
        }

        if let task = readoutInFlight[cacheKey] {
            let result = await task.value
            guard !task.isCancelled, !AccountDisconnectionRequest.isPending else { return nil }
            return result
        }

        guard input.hasEvidence else { return nil }

        let mlx = mlxReadoutGenerator
        let apple = appleReadoutGenerator
        let enabled = appleEnabled
        let availability = availabilityProvider
        let activityPublisher = modelActivityStatusPublisher
        let generation = UUID()
        let task = Task<DeadlineResourceReadout?, Never>(priority: .userInitiated) {
            let activityToken = activityPublisher?.begin(
                .summarizing,
                source: input.framing == .deadline ? "deadline-readout" : "project-readout",
                accountID: input.accountID
            )
            defer {
                if let activityToken {
                    activityPublisher?.end(activityToken)
                }
            }
            guard let produced = await Self.produceReadout(
                input: input,
                targetLanguage: targetLanguage,
                apple: apple,
                mlx: mlx,
                appleEnabled: enabled,
                availability: availability
            ) else { return nil }
            guard let guardrail else { return produced }
            // A readout that cannot be put in the reading language is
            // withheld uncached; the next request generates it again.
            return await guardrail.resolve(
                paragraph: produced.text,
                targetLanguage: targetLanguage,
                source: DisplayLanguageGuard.Source(
                    languageHint: nil,
                    context: "\(input.deadlineTitle)\n\(input.surfaceText)\n\(input.resourceText.prefix(1_200))",
                    messageID: nil,
                    accountID: input.accountID
                )
            ).map(DeadlineResourceReadout.init(text:))
        }
        readoutInFlight[cacheKey] = task
        readoutInFlightGenerations[cacheKey] = generation
        let result = await task.value
        let canStore = readoutInFlightGenerations[cacheKey] == generation
        if canStore {
            readoutInFlight[cacheKey] = nil
            readoutInFlightGenerations[cacheKey] = nil
        }
        guard canStore, !AccountDisconnectionRequest.isPending, let result else { return nil }
        if canStore {
            readoutPersistentCache[cacheKey] = PersistentReadoutEntry(
                deadlineKey: deadlineKey,
                fingerprint: fingerprint,
                readout: result,
                updatedAt: Date()
            )
            evictReadoutPersistentCacheIfNeeded()
            storeReadoutInMemory(cacheKey, result)
            try? persistCache()
        }
        return result
    }

    public func clearCache() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        inFlightGenerations.removeAll()
        memoryCache.removeAll()
        persistentCache.removeAll()
        lru.removeAll()
        readoutInFlight.values.forEach { $0.cancel() }
        readoutInFlight.removeAll()
        readoutInFlightGenerations.removeAll()
        readoutMemoryCache.removeAll()
        readoutPersistentCache.removeAll()
        readoutLRU.removeAll()
        try? persistCache()
    }

    /// Drops a single deadline's cached summary and readouts (e.g. after new
    /// mail lands or the deadline's file set changes).
    public func invalidate(deadlineKey: String) {
        invalidateKeys(withPrefix: "\(deadlineKey):")
    }

    /// Drops every cached summary/readout in a caller-owned key namespace.
    /// Manual-project deletion uses its UUID prefix so unrelated projects and
    /// the Deadlines tracker retain their caches.
    public func invalidate(deadlineKeyPrefix: String) {
        invalidateKeys(withPrefix: deadlineKeyPrefix)
    }

    private func invalidateKeys(withPrefix prefix: String) {
        for key in inFlight.keys where key.hasPrefix(prefix) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
            inFlightGenerations[key] = nil
        }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
        persistentCache = persistentCache.filter { !$0.key.hasPrefix(prefix) }
        lru.removeAll { $0.hasPrefix(prefix) }
        for key in readoutInFlight.keys where key.hasPrefix(prefix) {
            readoutInFlight[key]?.cancel()
            readoutInFlight[key] = nil
            readoutInFlightGenerations[key] = nil
        }
        readoutMemoryCache = readoutMemoryCache.filter { !$0.key.hasPrefix(prefix) }
        readoutPersistentCache = readoutPersistentCache.filter { !$0.key.hasPrefix(prefix) }
        readoutLRU.removeAll { $0.hasPrefix(prefix) }
        try? persistCache()
    }

    private static func isDisplayable(
        _ result: DeadlineSummaryResult,
        targetLanguage: SummarizationTargetLanguage,
        guardrail: DisplayLanguageGuard?
    ) -> Bool {
        guard guardrail != nil else { return true }
        return DisplayLanguageGuard.needsResolution(
            [result.paragraph] + result.actions.map(\.label),
            targetLanguage: targetLanguage
        ) == false
    }

    /// The briefing paragraph and step labels in the reader's language. Step
    /// ids and grounded values (URLs, numbers, addresses) are untouched. Nil
    /// when any of them carries a source-language passage that could not be
    /// translated: the briefing is withheld uncached and generated again on
    /// the next request.
    private static func displayed(
        _ result: DeadlineSummaryResult,
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage,
        guardrail: DisplayLanguageGuard
    ) async -> DeadlineSummaryResult? {
        let fields = [result.paragraph] + result.actions.map(\.label)
        guard DisplayLanguageGuard.needsResolution(fields, targetLanguage: targetLanguage) else { return result }
        let body = input.bodies.first.map { String($0.text.prefix(1_200)) } ?? ""
        let resolution = await guardrail.resolve(
            fields,
            targetLanguage: targetLanguage,
            source: DisplayLanguageGuard.Source(
                languageHint: nil,
                context: "\(input.title)\n\(input.surfaceText)\n\(body)",
                messageID: nil,
                accountID: input.accountID
            )
        )
        guard resolution.isComplete else { return nil }
        let resolved = resolution.fields
        return DeadlineSummaryResult(
            paragraph: resolved[0],
            actions: zip(result.actions, resolved.dropFirst()).map { action, label in
                DeadlineActionItem(
                    id: action.id,
                    kind: action.kind,
                    label: label,
                    value: action.value,
                    detail: action.detail,
                    filePath: action.filePath
                )
            }
        )
    }

    private static func produce(
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage,
        apple: (any DeadlineSummaryGenerating)?,
        mlx: any DeadlineSummaryGenerating,
        appleEnabled: Bool,
        availability: AvailabilityProvider
    ) async -> DeadlineSummaryResult? {
        let label = input.framing == .deadline ? "Deadline summary" : "Project guide"
        do {
            if let result = try await mlx.summarize(input: input, targetLanguage: targetLanguage) {
                deadlineSummaryLogger.info("\(label, privacy: .public) generated with Qwen")
                return result
            }
            deadlineSummaryLogger.warning("\(label, privacy: .public) Qwen returned an empty result")
        } catch {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Qwen failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }

        guard let apple, appleEnabled, availability().isAvailable else {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback skipped: unavailable or disabled")
            return nil
        }

        do {
            if let result = try await apple.summarize(input: input, targetLanguage: targetLanguage) {
                deadlineSummaryLogger.info("\(label, privacy: .public) generated with Apple fallback")
                return result
            }
        } catch DeadlineSummaryError.empty {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback returned empty output")
        } catch DeadlineSummaryError.modelUnavailable {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback model unavailable")
        } catch {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
        return nil
    }

    private static func produceReadout(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage,
        apple: (any DeadlineResourceReadoutGenerating)?,
        mlx: (any DeadlineResourceReadoutGenerating)?,
        appleEnabled: Bool,
        availability: AvailabilityProvider
    ) async -> DeadlineResourceReadout? {
        let label = input.framing == .deadline ? "Deadline readout" : "Project readout"
        if let mlx {
            do {
                if let result = try await mlx.readout(input: input, targetLanguage: targetLanguage) {
                    deadlineSummaryLogger.info("\(label, privacy: .public) generated with Qwen")
                    return result
                }
                deadlineSummaryLogger.warning("\(label, privacy: .public) Qwen returned an empty result")
            } catch {
                deadlineSummaryLogger.warning("\(label, privacy: .public) Qwen failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }

        guard let apple, appleEnabled, availability().isAvailable else {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback skipped: unavailable or disabled")
            return nil
        }

        do {
            if let result = try await apple.readout(input: input, targetLanguage: targetLanguage) {
                deadlineSummaryLogger.info("\(label, privacy: .public) generated with Apple fallback")
                return result
            }
        } catch DeadlineSummaryError.empty {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback returned empty output")
        } catch DeadlineSummaryError.modelUnavailable {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback model unavailable")
        } catch {
            deadlineSummaryLogger.warning("\(label, privacy: .public) Apple fallback failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
        return nil
    }

    private func store(
        _ key: String,
        deadlineKey: String,
        fingerprint: String,
        _ result: DeadlineSummaryResult
    ) {
        persistentCache[key] = PersistentCacheEntry(
            deadlineKey: deadlineKey,
            fingerprint: fingerprint,
            result: result,
            updatedAt: Date()
        )
        evictPersistentCacheIfNeeded()
        storeInMemory(key, result)
        try? persistCache()
    }

    /// Deadline summaries are hover-driven and their fingerprint includes the
    /// full body text, so every new message on a thread mints a fresh key. Bound
    /// the on-disk cache by evicting the oldest entries (by `updatedAt`) so the
    /// file cannot grow without limit.
    private static let persistentCapacity = 240

    private func evictPersistentCacheIfNeeded() {
        guard persistentCache.count > Self.persistentCapacity else { return }
        let overflow = persistentCache.count - Self.persistentCapacity
        let oldest = persistentCache
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
        for (key, _) in oldest {
            persistentCache.removeValue(forKey: key)
        }
    }

    private func storeInMemory(_ key: String, _ result: DeadlineSummaryResult) {
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

    private func storeReadoutInMemory(_ key: String, _ readout: DeadlineResourceReadout) {
        readoutMemoryCache[key] = readout
        touchReadout(key)
        while readoutLRU.count > capacity {
            let oldest = readoutLRU.removeFirst()
            readoutMemoryCache.removeValue(forKey: oldest)
        }
    }

    private func touchReadout(_ key: String) {
        readoutLRU.removeAll { $0 == key }
        readoutLRU.append(key)
    }

    private func evictReadoutPersistentCacheIfNeeded() {
        guard readoutPersistentCache.count > Self.persistentCapacity else { return }
        let overflow = readoutPersistentCache.count - Self.persistentCapacity
        let oldest = readoutPersistentCache
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
        for (key, _) in oldest {
            readoutPersistentCache.removeValue(forKey: key)
        }
    }

    private func persistCache() throws {
        guard let persistentCacheURL else { return }
        let container = PersistentCacheContainer(
            entries: persistentCache,
            readoutEntries: readoutPersistentCache
        )
        let data = try JSONEncoder().encode(container)
        try FileManager.default.createDirectory(
            at: persistentCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistentCacheURL, options: .atomic)
    }

    private static func loadPersistentCaches(
        from url: URL?
    ) -> (summaries: [String: PersistentCacheEntry], readouts: [String: PersistentReadoutEntry]) {
        guard let url,
              let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(PersistentCacheContainer.self, from: data) else {
            return ([:], [:])
        }
        return (container.entries, container.readoutEntries ?? [:])
    }

    private static func cacheKey(deadlineKey: String, fingerprint: String) -> String {
        "\(deadlineKey):\(fingerprint)"
    }

    private static func fingerprint(
        input: DeadlineSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        var parts: [String] = [
            input.framing == .deadline ? "deadline-summary-v3" : "deadline-summary-v2",
            targetLanguage.identifier,
            targetLanguage.displayName,
            input.title,
            input.deadlineLabel,
            input.deadlineDateText,
            String(input.deadlineDate.timeIntervalSince1970),
            input.surfaceText
        ]
        // Framing joins the fingerprint only for the project register. The
        // project branch retains its prior version above; deadline v3 re-keys
        // stale summaries after outgoing progress joined the prompt contract.
        if input.framing != .deadline {
            parts.append(input.framing.rawValue)
        }
        parts.append(contentsOf: input.correspondents.flatMap { [$0.name, $0.email] })
        parts.append(contentsOf: input.attachments.flatMap {
            [$0.filename, $0.filePath ?? "", $0.documentKind ?? "", $0.extractedText ?? ""]
        })
        parts.append(contentsOf: input.workingFiles.flatMap {
            [$0.filename, $0.filePath ?? "", $0.extractedText ?? ""]
        })
        parts.append(contentsOf: input.bodies.flatMap { body -> [String] in
            [body.role, body.senderName, body.receivedAt.map { String($0.timeIntervalSince1970) } ?? "", body.text]
        })
        if let identity = input.userIdentity {
            parts.append(identity.displayName)
            parts.append(identity.primaryEmailAddress)
            parts.append(contentsOf: identity.aliasEmailAddresses)
        }
        return stableHash(parts.joined(separator: "\u{1F}"))
    }

    private static let readoutFingerprintVersion = "deadline-readout-v1"

    private static func readoutFingerprint(
        input: DeadlineResourceReadoutInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        var parts: [String] = [
            readoutFingerprintVersion,
            targetLanguage.identifier,
            targetLanguage.displayName,
            input.deadlineTitle,
            input.deadlineLabel,
            input.deadlineDateText,
            input.surfaceText,
            input.resourceFilename,
            input.resourceOrigin.rawValue,
            input.resourceText,
            input.briefingParagraph ?? ""
        ]
        // Same discipline as the summary fingerprint: `.deadline` stays
        // byte-identical to persisted entries; only `.project` re-keys.
        if input.framing != .deadline {
            parts.append(input.framing.rawValue)
        }
        parts.append(contentsOf: input.correspondents.flatMap { [$0.name, $0.email] })
        if let identity = input.userIdentity {
            parts.append(identity.displayName)
            parts.append(identity.primaryEmailAddress)
        }
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
    /// Guide-pane resource readouts. Optional so cache files written before the
    /// readout pass existed still decode.
    var readoutEntries: [String: PersistentReadoutEntry]?
}

private struct PersistentReadoutEntry: Codable {
    var deadlineKey: String
    var fingerprint: String
    var readout: DeadlineResourceReadout
    var updatedAt: Date
}

private struct PersistentCacheEntry: Codable {
    var deadlineKey: String
    var fingerprint: String
    var result: DeadlineSummaryResult
    var updatedAt: Date
}
