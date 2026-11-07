// ProjectSummary.swift
// Generates the project-briefing copy shown when the user hovers a project
// title in the Projects-lens gutter. This is the project-level sibling of
// `ContextOrientation`: where orientation describes one message's place in the
// local constellation, this describes a whole project — what it is and its
// goals, how it began and developed, any dates / timetables / milestones, the
// current state and progress, and finally the single most current or recent
// open issue or question.
//
// The output is two parts: a flowing paragraph (project / goals / timeline /
// progress) followed by one sentence — prefixed with the literal token
// `OPEN ISSUE:` — naming the current open question. Both parts carry inline
// `[N]` citation markers resolved against the numbered project-timeline
// sources. Qwen/MLX is preferred (wide context); Apple Foundation Models is a
// small-prompt fallback. The output stop marker and post-processing reuse the
// context-orientation machinery so the two surfaces stay in lockstep.

import Foundation
import OSLog
import OhiaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

private let projectSummaryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "project-summary"
)

// MARK: - Inputs

/// One participant in the project, surfaced so the model can name who is
/// driving the work without inventing relationships.
public struct ProjectSummaryParticipant: Sendable, Equatable {
    public let name: String
    public let email: String
    public let messageCount: Int

    public init(name: String, email: String, messageCount: Int) {
        self.name = name
        self.email = email
        self.messageCount = messageCount
    }
}

/// A currently-open obligation (pending reply / confirmation) on the project,
/// used to ground the "current or most recent open issue" sentence.
public struct ProjectSummaryObligation: Sendable, Equatable {
    public let kindLabel: String
    public let summary: String
    public let openedAt: Date?
    public let citationTargetID: String?

    public init(kindLabel: String, summary: String, openedAt: Date?, citationTargetID: String?) {
        self.kindLabel = kindLabel
        self.summary = summary
        self.openedAt = openedAt
        self.citationTargetID = citationTargetID
    }
}

/// An evidence-backed deadline / date on the project.
public struct ProjectSummaryDeadline: Sendable, Equatable {
    public let label: String
    public let date: Date?
    public let evidenceText: String
    public let citationTargetID: String?

    public init(label: String, date: Date?, evidenceText: String, citationTargetID: String?) {
        self.label = label
        self.date = date
        self.evidenceText = evidenceText
        self.citationTargetID = citationTargetID
    }
}

/// One sampled message standing in for the project's correspondence. The input
/// builder samples a timeline-representative subset (origin + recent +
/// obligation/deadline-bearing) so the prompt scales to projects with
/// thousands of messages without feeding raw bodies.
public struct ProjectSummaryMessageDigest: Sendable, Equatable {
    public let role: String
    public let senderName: String
    public let subject: String
    public let excerpt: String
    public let receivedAt: Date?
    public let recipients: SummarizationContext.AnchorRecipients?
    public let obligationLabels: [String]
    public let isDeadlineBearing: Bool
    public let citationTargetID: String?

    public init(
        role: String,
        senderName: String,
        subject: String,
        excerpt: String,
        receivedAt: Date?,
        recipients: SummarizationContext.AnchorRecipients? = nil,
        obligationLabels: [String] = [],
        isDeadlineBearing: Bool = false,
        citationTargetID: String? = nil
    ) {
        self.role = role
        self.senderName = senderName
        self.subject = subject
        self.excerpt = excerpt
        self.receivedAt = receivedAt
        self.recipients = recipients?.isUseful == true ? recipients : nil
        self.obligationLabels = obligationLabels
        self.isDeadlineBearing = isDeadlineBearing
        self.citationTargetID = citationTargetID
    }
}

public struct ProjectSummaryInput: Sendable, Equatable {
    public let accountID: UUID?
    public let projectLabel: String
    public let statusLabel: String
    public let firstActivityAt: Date?
    public let lastActivityAt: Date?
    public let totalMessageCount: Int
    public let participants: [ProjectSummaryParticipant]
    public let obligations: [ProjectSummaryObligation]
    public let deadlines: [ProjectSummaryDeadline]
    /// Chronologically-ordered sampled digests. These are the numbered `[N]`
    /// sources the model cites; the input builder caps the count.
    public let digests: [ProjectSummaryMessageDigest]
    public let userIdentity: SummarizationUserIdentity?

    public init(
        accountID: UUID? = nil,
        projectLabel: String,
        statusLabel: String,
        firstActivityAt: Date?,
        lastActivityAt: Date?,
        totalMessageCount: Int,
        participants: [ProjectSummaryParticipant],
        obligations: [ProjectSummaryObligation],
        deadlines: [ProjectSummaryDeadline],
        digests: [ProjectSummaryMessageDigest],
        userIdentity: SummarizationUserIdentity? = nil
    ) {
        self.accountID = accountID
        self.projectLabel = projectLabel
        self.statusLabel = statusLabel
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.totalMessageCount = max(0, totalMessageCount)
        self.participants = participants
        self.obligations = obligations
        self.deadlines = deadlines
        self.digests = digests
        self.userIdentity = userIdentity?.isUseful == true ? userIdentity : nil
    }

    /// True when there is at least one sampled message to summarise. The
    /// service short-circuits to `nil` otherwise so the UI renders a neutral
    /// "no summary" copy instead of asking the model to invent a project.
    public var hasEvidence: Bool {
        !digests.isEmpty
    }
}

// MARK: - Result + citation

public struct ProjectSummaryCitation: Sendable, Equatable, Identifiable {
    public enum SourceKind: String, Sendable, Equatable, Codable {
        case message
        case obligation
        case deadline
    }

    public let id: String
    public let label: String
    public let kind: SourceKind
    public let title: String
    public let detail: String
    public let excerpt: String
    public let targetID: String?
    public let receivedAt: Date?
    public let senderDisplay: String?
    public let recipientsDisplay: String?
    public let subjectDisplay: String?

    public init(
        id: String,
        label: String,
        kind: SourceKind,
        title: String,
        detail: String,
        excerpt: String,
        targetID: String?,
        receivedAt: Date? = nil,
        senderDisplay: String? = nil,
        recipientsDisplay: String? = nil,
        subjectDisplay: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.title = title
        self.detail = detail
        self.excerpt = excerpt
        self.targetID = targetID
        self.receivedAt = receivedAt
        self.senderDisplay = senderDisplay
        self.recipientsDisplay = recipientsDisplay
        self.subjectDisplay = subjectDisplay
    }
}

public struct ProjectSummaryResult: Sendable, Equatable {
    /// Flowing project paragraph: project / goals / timeline / progress.
    public let paragraph: String
    /// The single current or most recent open issue or question. `nil` when
    /// the model did not emit an `OPEN ISSUE:` line (e.g. resolved project).
    public let openQuestion: String?
    public let citations: [ProjectSummaryCitation]

    public init(paragraph: String, openQuestion: String?, citations: [ProjectSummaryCitation] = []) {
        self.paragraph = paragraph
        self.openQuestion = openQuestion
        self.citations = citations
    }

    public func withCitations(_ citations: [ProjectSummaryCitation]) -> ProjectSummaryResult {
        ProjectSummaryResult(paragraph: paragraph, openQuestion: openQuestion, citations: citations)
    }
}

public enum ProjectSummaryError: Error {
    case empty
    case modelUnavailable
    case underlying(Error)
}

public protocol ProjectSummaryGenerating: Sendable {
    func summarize(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> ProjectSummaryResult?
}

// MARK: - Prompt builder

public enum ProjectSummaryPromptBuilder {
    public static let openIssueMarker = "OPEN ISSUE:"
    public static let excerptCharacterLimit = 220
    public static let maxDigests = 8
    public static let maxParticipants = 5
    public static let maxObligations = 4
    public static let maxDeadlines = 4
    public static let maxCitations = 8

    public static let instructions = """
    Write a briefing about a project assembled from a person's correspondence. Produce two parts. \
    Part one: a single flowing paragraph of 4-7 complete sentences that describes the project as a whole — what it is and what it is trying to achieve, where it appears to have started, how it developed, any concrete dates, timetables, or milestones, and the current state and progress. Prefer an origin-to-now shape: this began with..., then..., and the current state is.... \
    Part two: after the paragraph, on a new line, write the single most current or most recent open issue, decision, or question for this project as one sentence beginning with the exact prefix \(openIssueMarker). If nothing is genuinely open — the project is resolved or dormant with no pending question — write \(openIssueMarker) followed by a short statement that there is no open issue. \
    Lean on the project metadata, participants, open obligations, deadlines, and the numbered timeline entries as evidence. Weight more recent entries and open obligations most heavily when deciding the current state and the open issue. \
    Speak naturally in complete sentences. Do not write bullet lists or headings. Avoid the words "email", "message", "thread", "inbox", "node", "graph", "vector", "embedding", "constellation", "star", or "project lens". Refer to people by name and to topics by what they concern. If the origin or sequence is unclear, say the available history is limited rather than inventing it. \
    This briefing is shown to the account owner. Use reader identity only to disambiguate people. Use "you" or "your" only when the direction and identity evidence make the account owner unambiguous; never call the account owner "the user", and never rewrite a third party who shares the owner's first name as "you". \
    Cite supporting evidence inline using the markers [1], [2], … from the Numbered sources block below. Append the marker right after the phrase or clause it supports, in both the paragraph and the open-issue line. Use only marker numbers that appear in the Numbered sources block; never invent a number. The same marker may be used at most twice. Do not list citations separately; markers must be inline. \
    Do not include reasoning, analysis, scratchpad text, or <think> tags. If the model supports thinking controls, disable thinking. Write in the target system language named below.
    """

    public static let guide = "A project briefing in two parts: first one flowing paragraph (4-7 sentences) covering what the project is and its goal, its origin and development, dates/timetables/milestones, and current state and progress; then a new line beginning exactly with \"\(openIssueMarker)\" naming the single most current or recent open issue or question (or stating there is none). Weight recent timeline entries and open obligations most heavily. Use inline [N] markers from the numbered sources. Refer to people by name; use you/your only when identity evidence is unambiguous. No headings, no bullet lists, no reasoning, no <think> tags, and never use the forbidden vocabulary."

    public static func prompt(input: ProjectSummaryInput, targetLanguage: SummarizationTargetLanguage) -> String {
        promptParts(input: input, targetLanguage: targetLanguage).prompt
    }

    public static func promptParts(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> PrefixCachedPrompt {
        let prefix = [
            instructions,
            "",
            "Target system language: \(targetLanguage.promptDescription)",
            ""
        ].joined(separator: "\n") + "\n"

        var lines: [String] = []
        if let readerIdentity = readerIdentitySection(input.userIdentity) {
            lines.append(readerIdentity)
            lines.append("")
        }

        lines.append("Project metadata")
        lines.append("- Title: \(clean(input.projectLabel, limit: 160))")
        lines.append("- Status: \(clean(input.statusLabel, limit: 48))")
        if let first = input.firstActivityAt {
            lines.append("- First activity: \(dateFormatter.string(from: first))")
        }
        if let last = input.lastActivityAt {
            lines.append("- Most recent activity: \(dateFormatter.string(from: last))")
        }
        lines.append("- Total items in project: \(input.totalMessageCount); sampled below: \(min(input.digests.count, maxDigests)).")

        if !input.participants.isEmpty {
            lines.append("")
            lines.append("Participants (name · share of activity):")
            for participant in input.participants.prefix(maxParticipants) {
                let name = clean(participant.name.isEmpty ? participant.email : participant.name, limit: 80)
                lines.append("- \(name) · \(participant.messageCount) item\(suffix(participant.messageCount))")
            }
        }

        if !input.obligations.isEmpty {
            lines.append("")
            lines.append("Open obligations (most recent first; use these to ground the open issue):")
            for (index, obligation) in obligationsByRecency(input.obligations).prefix(maxObligations).enumerated() {
                let when = obligation.openedAt.map { dateFormatter.string(from: $0) } ?? "date unknown"
                let summary = clean(obligation.summary, limit: excerptCharacterLimit)
                lines.append("\(index + 1). [\(clean(obligation.kindLabel, limit: 40)) · \(when)] \(summary)")
            }
        }

        if !input.deadlines.isEmpty {
            lines.append("")
            lines.append("Deadlines / dates:")
            for (index, deadline) in deadlinesByDate(input.deadlines).prefix(maxDeadlines).enumerated() {
                let when = deadline.date.map { dateFormatter.string(from: $0) } ?? "date unknown"
                let evidence = clean(deadline.evidenceText, limit: excerptCharacterLimit)
                lines.append("\(index + 1). [\(clean(deadline.label, limit: 40)) · \(when)] \(evidence)")
            }
        }

        let numberedDigests = self.numberedDigests(for: input)
        if !numberedDigests.isEmpty {
            lines.append("")
            lines.append("Numbered sources — project timeline (oldest to newest; cite inline as [N]):")
            for (index, digest) in numberedDigests.enumerated() {
                let when = digest.receivedAt.map { dateFormatter.string(from: $0) } ?? "—"
                let sender = clean(digest.senderName, limit: 80)
                let subject = clean(digest.subject, limit: 120)
                let recipients = recipientList(digest.recipients?.to ?? [])
                let excerpt = clean(digest.excerpt, limit: excerptCharacterLimit)
                var tags: [String] = [digest.role]
                tags.append(contentsOf: digest.obligationLabels)
                if digest.isDeadlineBearing { tags.append("deadline") }
                let tagLine = tags.filter { !$0.isEmpty }.joined(separator: ", ")
                lines.append("[\(index + 1)] [\(tagLine); \(when); From: \(sender); To: \(recipients); Subject: \(subject)] \(excerpt)")
            }
            lines.append("Use this timeline to answer: What is this about? Where did it begin? What changed over time? What is the latest state? What is the open issue?")
        }

        lines.append("")
        lines.append("/no_think")
        lines.append("")
        lines.append("Output contract:")
        lines.append("Return exactly one paragraph, then a new line beginning with \(openIssueMarker) and one sentence, then write the single line \(GenerationStopPolicy.contextOrientationEndMarker) and stop immediately after it. Do not return /no_think, prompt text, role labels, chat markers, or special tokens such as <|im_start|>, <|im_end|>, <|endoftext|>, or </s>. Use no headings, no bullet lists, no preamble, no reasoning, no <think> tags, and no second paragraph beyond the open-issue line. Inline [N] markers from the Numbered sources block above are required wherever you draw on a numbered source.")
        lines.append("")
        lines.append("<one paragraph with inline [N] citation markers>")
        lines.append("\(openIssueMarker) <one sentence with inline [N] citation markers>")
        lines.append(GenerationStopPolicy.contextOrientationEndMarker)
        return PrefixCachedPrompt(
            cacheKey: "project-summary-v1",
            prefix: prefix,
            suffix: lines.joined(separator: "\n")
        )
    }

    /// The canonical numbered-source digest list shared by the prompt and the
    /// citation builder. Both number this exact list 1…n, so a `[N]` marker the
    /// model emits always resolves to `citations[N-1]`. Only digests with a
    /// non-empty, unique `citationTargetID` are eligible — an un-citable digest
    /// must never occupy a `[N]` slot the model could reference.
    static func numberedDigests(for input: ProjectSummaryInput) -> [ProjectSummaryMessageDigest] {
        var seen = Set<String>()
        var result: [ProjectSummaryMessageDigest] = []
        for digest in input.digests {
            guard let targetID = digest.citationTargetID, !targetID.isEmpty else { continue }
            guard seen.insert(targetID).inserted else { continue }
            result.append(digest)
            if result.count >= maxDigests { break }
        }
        return result
    }

    /// Numbered-source citations, 1:1 with the timeline digests shown in the
    /// prompt. The same rank order the prompt uses, so `[N]` resolves to
    /// `citations[N-1]`.
    public static func citations(for input: ProjectSummaryInput) -> [ProjectSummaryCitation] {
        var citations: [ProjectSummaryCitation] = []
        for (index, digest) in numberedDigests(for: input).enumerated() {
            let targetID = digest.citationTargetID ?? ""
            let kind: ProjectSummaryCitation.SourceKind = digest.isDeadlineBearing
                ? .deadline
                : (digest.obligationLabels.isEmpty ? .message : .obligation)
            let when = digest.receivedAt.map { dateFormatter.string(from: $0) } ?? "date unknown"
            var detailParts = [digest.role, when]
            detailParts.append(contentsOf: digest.obligationLabels)
            if digest.isDeadlineBearing { detailParts.append("deadline") }
            citations.append(
                ProjectSummaryCitation(
                    id: "\(kind.rawValue):\(index + 1):\(targetID)",
                    label: "\(index + 1)",
                    kind: kind,
                    title: clean(digest.subject.isEmpty ? digest.senderName : digest.subject, limit: 120),
                    detail: clean(detailParts.filter { !$0.isEmpty }.joined(separator: " · "), limit: 140),
                    excerpt: clean(digest.excerpt, limit: excerptCharacterLimit),
                    targetID: targetID,
                    receivedAt: digest.receivedAt,
                    senderDisplay: nonEmpty(digest.senderName),
                    recipientsDisplay: nonEmptyRecipientList(digest.recipients?.to ?? []),
                    subjectDisplay: nonEmpty(digest.subject)
                )
            )
        }
        return citations
    }

    // MARK: helpers

    private static func readerIdentitySection(_ identity: SummarizationUserIdentity?) -> String? {
        guard let identity, identity.isUseful else { return nil }
        var lines: [String] = ["Reader identity"]
        if !identity.displayName.isEmpty {
            lines.append("- Account owner display name: \(clean(identity.displayName, limit: 120))")
        }
        if !identity.primaryEmailAddress.isEmpty {
            lines.append("- Account owner primary address: \(clean(identity.primaryEmailAddress, limit: 160))")
        }
        if !identity.aliasEmailAddresses.isEmpty {
            let aliases = identity.aliasEmailAddresses.prefix(8).map { clean($0, limit: 120) }.joined(separator: ", ")
            if !aliases.isEmpty {
                lines.append("- Other outgoing addresses for the same person: \(aliases)")
            }
        }
        lines.append("- Use this identity only to resolve references to the account owner. Same first name alone is not enough; require full name or address evidence.")
        lines.append("- Prefer full names over \"you\" or \"your\" whenever there is any ambiguity. Do not call the account owner \"the user\".")
        return lines.joined(separator: "\n")
    }

    private static func obligationsByRecency(_ obligations: [ProjectSummaryObligation]) -> [ProjectSummaryObligation] {
        obligations.sorted { lhs, rhs in
            switch (lhs.openedAt, rhs.openedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.summary.localizedStandardCompare(rhs.summary) == .orderedAscending
            }
        }
    }

    private static func deadlinesByDate(_ deadlines: [ProjectSummaryDeadline]) -> [ProjectSummaryDeadline] {
        deadlines.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmptyRecipientList(_ recipients: [SummarizationContext.Recipient]) -> String? {
        guard !recipients.isEmpty else { return nil }
        let formatted = recipientList(recipients)
        return formatted == "unknown" ? nil : formatted
    }

    private static func recipientList(_ recipients: [SummarizationContext.Recipient]) -> String {
        let values = recipients
            .prefix(8)
            .map { recipient -> String in
                if let displayName = recipient.displayName, !recipient.address.isEmpty {
                    return "\(clean(displayName, limit: 80)) <\(clean(recipient.address, limit: 120))>"
                }
                if let displayName = recipient.displayName {
                    return clean(displayName, limit: 120)
                }
                return clean(recipient.address, limit: 120)
            }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "unknown" : values.joined(separator: ", ")
    }

    private static func suffix(_ count: Int) -> String { count == 1 ? "" : "s" }
}

// MARK: - Post-processor

public enum ProjectSummaryPostProcessor {
    /// Cleans the raw model output (reusing the orientation cleaner for thinking
    /// tags, control tokens, stop artifacts, and whitespace collapse) then
    /// splits it at the `OPEN ISSUE:` marker into the project paragraph and the
    /// open-issue sentence. Returns `nil` when there is no usable paragraph.
    public static func process(_ raw: String) -> ProjectSummaryResult? {
        guard let cleaned = ContextOrientationPostProcessor.clean(raw) else { return nil }
        let marker = ProjectSummaryPromptBuilder.openIssueMarker
        guard let markerRange = cleaned.range(of: marker, options: [.caseInsensitive]) else {
            // No marker — the whole output is the paragraph.
            let paragraph = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return paragraph.isEmpty ? nil : ProjectSummaryResult(paragraph: paragraph, openQuestion: nil)
        }
        let paragraph = String(cleaned[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var open = String(cleaned[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against the model repeating a second marker / paragraph.
        if let secondMarker = open.range(of: marker, options: [.caseInsensitive]) {
            open = String(open[..<secondMarker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let openQuestion = open.isEmpty ? nil : open
        if paragraph.isEmpty {
            // Marker came first / no leading paragraph — treat the open text as
            // the body rather than dropping everything.
            guard let fallback = openQuestion else { return nil }
            return ProjectSummaryResult(paragraph: fallback, openQuestion: nil)
        }
        return ProjectSummaryResult(paragraph: paragraph, openQuestion: openQuestion)
    }
}

// MARK: - MLX engine implementation

public final class MLXProjectSummarizer: ProjectSummaryGenerating, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        maxTokens: Int = 420,
        generationTaskPriority: TaskPriority = .utility
    ) {
        self.engine = engine
        self.maxTokens = maxTokens
        self.generationTaskPriority = generationTaskPriority
    }

    public func summarize(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> ProjectSummaryResult? {
        guard engine.isModelLoaded else {
            throw ProjectSummaryError.modelUnavailable
        }
        let prompt = ProjectSummaryPromptBuilder.promptParts(input: input, targetLanguage: targetLanguage)
        let engine = self.engine
        let maxTokens = self.maxTokens
        let priority = generationTaskPriority
        let raw: String
        do {
            raw = try await Task.detached(priority: priority) {
                try PrefixCachedGeneration.generate(engine: engine, prompt: prompt, maxTokens: maxTokens)
            }.value
        } catch {
            throw ProjectSummaryError.underlying(error)
        }
        return ProjectSummaryPostProcessor.process(raw)
    }
}

// MARK: - Apple Foundation Models implementation

#if canImport(FoundationModels)
public final class AppleFoundationProjectSummarizer: ProjectSummaryGenerating, @unchecked Sendable {
    private static let generationOptions = GenerationOptions(temperature: 0.1, maximumResponseTokens: ApplePromptBudget.summaryResponseTokens)

    @Generable
    struct ProjectBriefing {
        @Guide(description: ProjectSummaryPromptBuilder.guide)
        let briefing: String
    }

    public init() {}

    public func summarize(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) async throws -> ProjectSummaryResult? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw ProjectSummaryError.modelUnavailable
        }
        let session = LanguageModelSession(instructions: ProjectSummaryPromptBuilder.instructions)
        let prompt = ProjectSummaryPromptBuilder.prompt(input: input, targetLanguage: targetLanguage)
        do {
            try await ApplePromptBudget.requireFits(
                prompt: prompt, instructions: ProjectSummaryPromptBuilder.instructions, schema: ProjectBriefing.generationSchema
            )
            let response = try await session.respond(
                to: prompt,
                generating: ProjectBriefing.self,
                options: Self.generationOptions
            )
            guard let result = ProjectSummaryPostProcessor.process(response.content.briefing) else {
                throw ProjectSummaryError.empty
            }
            return result
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw ProjectSummaryError.empty
            default:
                throw ProjectSummaryError.underlying(error)
            }
        } catch let error as ProjectSummaryError {
            throw error
        } catch {
            throw ProjectSummaryError.underlying(error)
        }
    }
}
#endif

// MARK: - Service actor (cache + Apple/MLX cascade)

public actor ProjectSummaryService {
    public typealias AvailabilityProvider = @Sendable () -> AppleIntelligenceAvailability.State

    private let appleSummarizer: (any ProjectSummaryGenerating)?
    private let mlxSummarizer: any ProjectSummaryGenerating
    private let availabilityProvider: AvailabilityProvider
    private let persistentCacheURL: URL?
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private var appleEnabled: Bool

    private var inFlight: [String: Task<ProjectSummaryResult?, Never>] = [:]
    private var inFlightGenerations: [String: UUID] = [:]
    private var memoryCache: [String: ProjectSummaryResult] = [:]
    private var persistentCache: [String: PersistentCacheEntry] = [:]
    private var lru: [String] = []
    private let capacity: Int

    public init(
        apple: (any ProjectSummaryGenerating)?,
        mlx: any ProjectSummaryGenerating,
        appleEnabled: Bool,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        capacity: Int = 96,
        persistentCacheURL: URL? = nil,
        availabilityProvider: @escaping AvailabilityProvider = { AppleIntelligenceAvailability.current() }
    ) {
        self.appleSummarizer = apple
        self.mlxSummarizer = mlx
        self.appleEnabled = appleEnabled
        self.capacity = max(1, capacity)
        self.persistentCacheURL = persistentCacheURL
        self.availabilityProvider = availabilityProvider
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.persistentCache = Self.loadPersistentCache(from: persistentCacheURL)
    }

    public func setAppleEnabled(_ enabled: Bool) {
        appleEnabled = enabled
    }

    public func summary(
        for projectKey: String,
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) async -> ProjectSummaryResult? {
        guard !AccountDisconnectionRequest.isPending else { return nil }
        let fingerprint = Self.fingerprint(input: input, targetLanguage: targetLanguage)
        let cacheKey = Self.cacheKey(projectKey: projectKey, fingerprint: fingerprint)
        let citations = ProjectSummaryPromptBuilder.citations(for: input)

        if let cached = memoryCache[cacheKey] {
            touch(cacheKey)
            return cached.withCitations(citations)
        }

        if let entry = persistentCache[cacheKey] {
            let restored = ProjectSummaryResult(
                paragraph: entry.paragraph,
                openQuestion: entry.openQuestion,
                citations: citations
            )
            storeInMemory(cacheKey, restored)
            return restored
        }

        if let task = inFlight[cacheKey] {
            let result = await task.value
            guard !task.isCancelled, !AccountDisconnectionRequest.isPending else { return nil }
            return result?.withCitations(citations)
        }

        guard input.hasEvidence else { return nil }

        let apple = appleSummarizer
        let mlx = mlxSummarizer
        let enabled = appleEnabled
        let availability = availabilityProvider
        let activityPublisher = modelActivityStatusPublisher
        let generation = UUID()
        let task = Task<ProjectSummaryResult?, Never>(priority: .userInitiated) {
            let activityToken = activityPublisher?.begin(
                .summarizing,
                source: "project-summary",
                accountID: input.accountID
            )
            defer {
                if let activityToken {
                    activityPublisher?.end(activityToken)
                }
            }
            return await Self.produce(
                input: input,
                targetLanguage: targetLanguage,
                apple: apple,
                mlx: mlx,
                appleEnabled: enabled,
                availability: availability
            )
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
            store(cacheKey, projectKey: projectKey, fingerprint: fingerprint, result)
        }
        return result.withCitations(citations)
    }

    public func clearCache() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        inFlightGenerations.removeAll()
        memoryCache.removeAll()
        persistentCache.removeAll()
        lru.removeAll()
        try? persistCache()
    }

    /// Drops a single project's cached summary (e.g. after new mail lands).
    public func invalidate(projectKey: String) {
        let prefix = "\(projectKey):"
        for key in inFlight.keys where key.hasPrefix(prefix) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
            inFlightGenerations[key] = nil
        }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
        persistentCache = persistentCache.filter { !$0.key.hasPrefix(prefix) }
        lru.removeAll { $0.hasPrefix(prefix) }
        try? persistCache()
    }

    private static func produce(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage,
        apple: (any ProjectSummaryGenerating)?,
        mlx: any ProjectSummaryGenerating,
        appleEnabled: Bool,
        availability: AvailabilityProvider
    ) async -> ProjectSummaryResult? {
        do {
            if let result = try await mlx.summarize(input: input, targetLanguage: targetLanguage) {
                projectSummaryLogger.info("Project summary generated with Qwen")
                return result
            }
            projectSummaryLogger.warning("Project summary Qwen returned an empty result")
        } catch {
            projectSummaryLogger.warning("Project summary Qwen failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }

        guard let apple, appleEnabled, availability().isAvailable else {
            projectSummaryLogger.warning("Project summary Apple fallback skipped: unavailable or disabled")
            return nil
        }

        do {
            if let result = try await apple.summarize(input: input, targetLanguage: targetLanguage) {
                projectSummaryLogger.info("Project summary generated with Apple fallback")
                return result
            }
        } catch ProjectSummaryError.empty {
            projectSummaryLogger.warning("Project summary Apple fallback returned empty output")
        } catch ProjectSummaryError.modelUnavailable {
            projectSummaryLogger.warning("Project summary Apple fallback model unavailable")
        } catch {
            projectSummaryLogger.warning("Project summary Apple fallback failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
        return nil
    }

    private func store(
        _ key: String,
        projectKey: String,
        fingerprint: String,
        _ result: ProjectSummaryResult
    ) {
        persistentCache[key] = PersistentCacheEntry(
            projectKey: projectKey,
            fingerprint: fingerprint,
            paragraph: result.paragraph,
            openQuestion: result.openQuestion,
            updatedAt: Date()
        )
        storeInMemory(key, result)
        try? persistCache()
    }

    private func storeInMemory(_ key: String, _ result: ProjectSummaryResult) {
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
        return container.entries
    }

    private static func cacheKey(projectKey: String, fingerprint: String) -> String {
        "\(projectKey):\(fingerprint)"
    }

    private static let promptFingerprintVersion = "project-summary-v2"

    private static func fingerprint(
        input: ProjectSummaryInput,
        targetLanguage: SummarizationTargetLanguage
    ) -> String {
        var parts: [String] = [
            promptFingerprintVersion,
            targetLanguage.identifier,
            targetLanguage.displayName,
            input.projectLabel,
            input.statusLabel,
            input.firstActivityAt.map { String($0.timeIntervalSince1970) } ?? "",
            input.lastActivityAt.map { String($0.timeIntervalSince1970) } ?? "",
            String(input.totalMessageCount)
        ]
        parts.append(contentsOf: input.participants.flatMap { [$0.name, $0.email, String($0.messageCount)] })
        parts.append(contentsOf: input.obligations.flatMap {
            [$0.kindLabel, $0.summary, $0.openedAt.map { d in String(d.timeIntervalSince1970) } ?? "", $0.citationTargetID ?? ""]
        })
        parts.append(contentsOf: input.deadlines.flatMap {
            [$0.label, $0.evidenceText, $0.date.map { d in String(d.timeIntervalSince1970) } ?? "", $0.citationTargetID ?? ""]
        })
        parts.append(contentsOf: input.digests.flatMap { digest -> [String] in
            var d = [
                digest.role,
                digest.senderName,
                digest.subject,
                digest.excerpt,
                digest.receivedAt.map { String($0.timeIntervalSince1970) } ?? "",
                digest.isDeadlineBearing ? "1" : "0",
                digest.citationTargetID ?? ""
            ]
            d.append(contentsOf: digest.obligationLabels)
            return d
        })
        if let identity = input.userIdentity {
            parts.append(identity.displayName)
            parts.append(identity.primaryEmailAddress)
            parts.append(contentsOf: identity.aliasEmailAddresses)
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
}

private struct PersistentCacheEntry: Codable {
    var projectKey: String
    var fingerprint: String
    var paragraph: String
    var openQuestion: String?
    var updatedAt: Date
}
