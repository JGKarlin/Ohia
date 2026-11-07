import Foundation
import OhiaCore
import OhiaML

#if canImport(FoundationModels)
import FoundationModels
#endif

enum MeaningClusterTitleConfidence: String, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low
}

struct MeaningClusterEvidenceTerm: Sendable, Equatable {
    let term: String
    let weight: Double

    nonisolated init(term: String, weight: Double) {
        self.term = term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        self.weight = min(max(weight, 0), 1)
    }
}

struct MeaningClusterEvidenceSample: Sendable, Equatable {
    let messageId: String
    let subject: String
    let summary: String?

    nonisolated init(messageId: String, subject: String, summary: String?) {
        self.messageId = messageId
        self.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.summary = trimmedSummary.isEmpty ? nil : trimmedSummary
    }
}

struct MeaningClusterTitleInput: Sendable, Equatable {
    let memberCount: Int
    let weightedTerms: [MeaningClusterEvidenceTerm]
    let semanticTags: [MeaningClusterEvidenceTerm]
    let samples: [MeaningClusterEvidenceSample]

    nonisolated var hasGeneratableEvidence: Bool {
        !weightedTerms.isEmpty && !samples.isEmpty
    }

    nonisolated var evidenceSignature: String {
        [
            "members:\(memberCount)",
            "terms:\(Self.signatureTerms(weightedTerms))",
            "semantic:\(Self.signatureTerms(semanticTags))",
            "samples:\(samples.map(Self.signatureSample).joined(separator: "|"))"
        ].joined(separator: "\n")
    }

    private nonisolated static func signatureTerms(_ terms: [MeaningClusterEvidenceTerm]) -> String {
        terms
            .map { term in
                "\(signatureComponent(term.term)):\(Int((term.weight * 100).rounded()))"
            }
            .joined(separator: "|")
    }

    private nonisolated static func signatureSample(_ sample: MeaningClusterEvidenceSample) -> String {
        [
            signatureComponent(sample.messageId),
            signatureComponent(sample.subject),
            signatureComponent(sample.summary ?? "")
        ].joined(separator: ":")
    }

    private nonisolated static func signatureComponent(_ value: String) -> String {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}

struct MeaningClusterGeneratedTitle: Sendable, Equatable {
    let title: String
    let confidence: MeaningClusterTitleConfidence
}

enum MeaningClusterTitleGenerationError: Error {
    case empty
    case modelUnavailable
    case underlying(Error)
}

protocol MeaningClusterTitleGenerating: Sendable {
    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle?
}

enum MeaningClusterTitlePromptBuilder {
    nonisolated static let instructions = """
    You are summarizing the shared meaning of a cluster of related emails.

    The goal is not to classify the emails into a category.
    The goal is to synthesize the specific subject that makes these emails belong together.

    Use:
    - term weights to decide which concepts matter most
    - representative subjects and summaries to disambiguate the terms
    - semantic labels only as supporting evidence, not as a required title
    - specific language when the evidence supports it

    Avoid:
    - repeating the evidence terms verbatim
    - generic placeholders like Meaning cluster, Semantic cluster, Related emails, or Topic cluster
    - generic labels like travel, finance, work, receipt, promotion, newsletter, notification, personal, automated, or spam
    - project names unless the evidence clearly points to a project
    - prose, punctuation, headings, explanations, or quoted text

    Return a concise semantic overview of the cluster.
    """

    nonisolated static let titleGuide = "A specific 2-6 word semantic overview of what the related emails are about. It must be broader than one keyword, narrower than a generic category, and must not simply repeat the evidence terms."
    nonisolated static let confidenceGuide = "One of: high, medium, low. Use high when the evidence clearly supports one shared subject, medium when the title is plausible but broad, and low when the evidence is weak or mixed."

    nonisolated static func prompt(input: MeaningClusterTitleInput) -> String {
        var lines: [String] = []
        lines.append("Cluster size: \(input.memberCount) messages")
        lines.append("")
        lines.append("Weighted evidence terms")
        if input.weightedTerms.isEmpty {
            lines.append("- none")
        } else {
            for term in input.weightedTerms {
                lines.append("- \(clean(term.term, limit: 48)), weight \(format(term.weight))")
            }
        }

        lines.append("")
        lines.append("Canonical tags from message interpretation")
        if input.semanticTags.isEmpty {
            lines.append("- none")
        } else {
            for label in input.semanticTags {
                lines.append("- \(clean(label.term, limit: 72)), weight \(format(label.weight))")
            }
        }

        lines.append("")
        lines.append("Representative email evidence")
        if input.samples.isEmpty {
            lines.append("- none")
        } else {
            for (index, sample) in input.samples.enumerated() {
                lines.append("\(index + 1). Subject: \(clean(sample.subject, limit: 140))")
                if let summary = sample.summary {
                    lines.append("   Summary: \(clean(summary, limit: 240))")
                }
            }
        }

        lines.append("")
        lines.append("Write the title in \(SummarizationTargetLanguage.ohiaPreferred().promptDescription), translating source-language names and terms.")
        lines.append("Create the semantic overview now.")
        return lines.joined(separator: "\n")
    }

    private nonisolated static func clean(_ value: String, limit: Int) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func format(_ value: Double) -> String {
        String(format: "%.2f", min(max(value, 0), 1))
    }
}

enum MeaningClusterTitlePostProcessor {
    private nonisolated static let blockedGenericTitles: Set<String> = [
        "automated",
        "calendar",
        "finance",
        "legal",
        "newsletter",
        "notification",
        "notifications",
        "personal",
        "promotion",
        "promotions",
        "receipt",
        "receipts",
        "security",
        "shipping",
        "social",
        "spam",
        "support",
        "travel",
        "update",
        "updates",
        "work"
    ]

    nonisolated static func clean(
        title rawTitle: String,
        confidence rawConfidence: String,
        rawTerms: [String]
    ) -> MeaningClusterGeneratedTitle? {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        while let last = title.last, ".:;,!?:".contains(last) {
            title.removeLast()
        }
        title = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !title.isEmpty,
              title.count <= 64,
              !MeaningClusterLabel.isGenericPlaceholderTitle(title),
              !MeaningClusterLabel.matchesRawTerms(title, topTerms: rawTerms) else {
            return nil
        }

        let words = title.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words.count <= 6 else { return nil }

        let normalizedTitle = title.lowercased()
        guard !blockedGenericTitles.contains(normalizedTitle) else { return nil }

        let confidence = MeaningClusterTitleConfidence(rawValue: rawConfidence.lowercased()) ?? .medium
        return MeaningClusterGeneratedTitle(title: title, confidence: confidence)
    }
}

enum MeaningClusterQwenOutputParser {
    private nonisolated struct Payload: Decodable {
        let title: String
        let confidence: String
    }

    nonisolated static func parse(
        _ rawOutput: String,
        rawTerms: [String]
    ) -> MeaningClusterGeneratedTitle? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openingBrace = trimmed.firstIndex(of: "{"),
              let closingBrace = trimmed.lastIndex(of: "}"),
              openingBrace <= closingBrace else {
            return nil
        }

        let json = String(trimmed[openingBrace...closingBrace])
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return MeaningClusterTitlePostProcessor.clean(
            title: payload.title,
            confidence: payload.confidence,
            rawTerms: rawTerms
        )
    }
}

final class QwenMeaningClusterTitleGenerator: MeaningClusterTitleGenerating, @unchecked Sendable {
    typealias RawGeneration = @Sendable (
        _ prompt: String,
        _ cancellation: GenerationCancellation
    ) throws -> String

    nonisolated init(engine: WorkerGenerationEngine = WorkerGenerationEngine()) {
        self.generateRaw = { prompt, cancellation in
            try engine.generate(
                prompt: prompt,
                maxTokens: 96,
                cancellation: cancellation,
                lane: .lensAssist,
                leaseTTL: 30,
                activityKind: .clustering,
                personalization: .base
            )
        }
    }

    nonisolated init(generateRaw: @escaping RawGeneration) {
        self.generateRaw = generateRaw
    }

    private let generateRaw: RawGeneration
    private let turnGate = MeaningClusterQwenGenerationGate()

    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle? {
        guard input.hasGeneratableEvidence else {
            throw MeaningClusterTitleGenerationError.empty
        }

        let cancellation = GenerationCancellation()
        let generateRaw = generateRaw
        let turnGate = turnGate
        let turnID = UUID()
        let prompt = Self.qwenPrompt(input: input)
        let rawTerms = input.weightedTerms.map(\.term)

        await turnGate.register(id: turnID)
        return try await withTaskCancellationHandler {
            do {
                try await turnGate.acquire(id: turnID)
                defer {
                    Task {
                        await turnGate.release(id: turnID)
                    }
                }
                try Task.checkCancellation()
                return try await Task.detached(priority: .utility) {
                    try cancellation.checkCancellation()
                    let rawOutput = try generateRaw(prompt, cancellation)
                    try cancellation.checkCancellation()
                    guard let result = MeaningClusterQwenOutputParser.parse(
                        rawOutput,
                        rawTerms: rawTerms
                    ) else {
                        throw MeaningClusterTitleGenerationError.empty
                    }
                    return result
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MeaningClusterTitleGenerationError {
                throw error
            } catch {
                throw MeaningClusterTitleGenerationError.underlying(error)
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                await turnGate.cancel(id: turnID)
            }
        }
    }

    private nonisolated static func qwenPrompt(input: MeaningClusterTitleInput) -> String {
        """
        \(MeaningClusterTitlePromptBuilder.instructions)

        \(MeaningClusterTitlePromptBuilder.prompt(input: input))

        Return only one JSON object in exactly this shape:
        {"title":"specific 2-6 word overview","confidence":"high|medium|low"}
        """
    }
}

/// Holds concurrent Meaning-lens requests before they reach
/// `WorkerGenerationEngine`. The worker deadline therefore starts only after a
/// title owns the Qwen turn, instead of expiring while earlier clusters decode.
private actor MeaningClusterQwenGenerationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeID: UUID?
    private var waiters: [Waiter] = []
    private var registeredIDs: Set<UUID> = []
    private var cancelledIDs: Set<UUID> = []

    func register(id: UUID) {
        registeredIDs.insert(id)
    }

    func acquire(id: UUID) async throws {
        if cancelledIDs.remove(id) != nil {
            registeredIDs.remove(id)
            throw CancellationError()
        }
        guard activeID != nil else {
            activeID = id
            return
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            if cancelledIDs.remove(id) != nil {
                registeredIDs.remove(id)
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    func cancel(id: UUID) {
        if activeID == id {
            return
        }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            registeredIDs.remove(id)
            waiter.continuation.resume(throwing: CancellationError())
        } else if registeredIDs.contains(id) {
            cancelledIDs.insert(id)
        }
    }

    func release(id: UUID) {
        guard activeID == id else { return }
        registeredIDs.remove(id)
        if waiters.isEmpty {
            activeID = nil
            return
        }

        let waiter = waiters.removeFirst()
        activeID = waiter.id
        waiter.continuation.resume()
    }
}

final class QwenFirstMeaningClusterTitleGenerator: MeaningClusterTitleGenerating, @unchecked Sendable {
    private let qwen: any MeaningClusterTitleGenerating
    private let apple: any MeaningClusterTitleGenerating
    private let activityPublisher: ModelActivityStatusPublisher
    private let displayLanguageGuard: DisplayLanguageGuard?

    nonisolated init(
        qwen: any MeaningClusterTitleGenerating,
        apple: any MeaningClusterTitleGenerating,
        activityPublisher: ModelActivityStatusPublisher,
        displayLanguageGuard: DisplayLanguageGuard? = nil
    ) {
        self.qwen = qwen
        self.apple = apple
        self.activityPublisher = activityPublisher
        self.displayLanguageGuard = displayLanguageGuard
    }

    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle? {
        let activity = activityPublisher.begin(
            .clustering,
            source: "meaning-cluster-title"
        )
        defer {
            activityPublisher.end(activity)
        }

        do {
            if let title = try await qwen.generateTitle(for: input),
               let shown = await displayed(title, input: input) {
                return shown
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Apple Intelligence is the local fallback for a missing,
            // unavailable, or invalid Qwen result, including one that
            // cannot be shown in the reading language.
        }

        try Task.checkCancellation()
        guard let title = try await apple.generateTitle(for: input) else { return nil }
        return await displayed(title, input: input)
    }

    /// The title in the reading language. A rendering that no longer fits the
    /// title contract (2-6 words, specific) yields no title rather than one
    /// in the source language, and so does a source-language passage that
    /// could not be translated: kept as written, the labeler would find it
    /// outside the reading language and regenerate it on every update, while
    /// a missing title enters the labeler's failure backoff.
    private func displayed(
        _ title: MeaningClusterGeneratedTitle,
        input: MeaningClusterTitleInput
    ) async -> MeaningClusterGeneratedTitle? {
        guard let displayLanguageGuard else { return title }
        guard let rendered = await displayLanguageGuard.resolve(
            paragraph: title.title,
            targetLanguage: .ohiaPreferred(),
            source: DisplayLanguageGuard.Source(
                languageHint: nil,
                context: input.samples.prefix(4).map { "\($0.subject)\n\($0.summary ?? "")" }.joined(separator: "\n"),
                messageID: nil,
                accountID: nil
            )
        ) else { return nil }
        guard rendered != title.title else { return title }
        return MeaningClusterTitlePostProcessor.clean(
            title: rendered,
            confidence: title.confidence.rawValue,
            rawTerms: input.weightedTerms.map(\.term)
        )
    }
}

#if canImport(FoundationModels)
final class AppleMeaningClusterTitleGenerator: MeaningClusterTitleGenerating, @unchecked Sendable {
    static let shared = AppleMeaningClusterTitleGenerator()
    private static let queue = AppleMeaningClusterTitleGenerationQueue()

    private init() {}

    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle? {
        try await Self.queue.generateTitle(for: input)
    }
}

private actor AppleMeaningClusterTitleGenerationQueue {
    private static let generationOptions = GenerationOptions(temperature: 0.1)

    @Generable
    struct GeneratedTitle {
        @Guide(description: MeaningClusterTitlePromptBuilder.titleGuide)
        let title: String

        @Guide(description: MeaningClusterTitlePromptBuilder.confidenceGuide)
        let confidence: String
    }

    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw MeaningClusterTitleGenerationError.modelUnavailable
        }
        guard input.hasGeneratableEvidence else {
            throw MeaningClusterTitleGenerationError.empty
        }

        let session = LanguageModelSession(instructions: MeaningClusterTitlePromptBuilder.instructions)
        let prompt = MeaningClusterTitlePromptBuilder.prompt(input: input)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedTitle.self,
                options: Self.generationOptions
            )
            guard let result = MeaningClusterTitlePostProcessor.clean(
                title: response.content.title,
                confidence: response.content.confidence,
                rawTerms: input.weightedTerms.map(\.term)
            ) else {
                throw MeaningClusterTitleGenerationError.empty
            }
            return result
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw MeaningClusterTitleGenerationError.empty
            default:
                throw MeaningClusterTitleGenerationError.underlying(error)
            }
        } catch let error as MeaningClusterTitleGenerationError {
            throw error
        } catch {
            throw MeaningClusterTitleGenerationError.underlying(error)
        }
    }
}
#else
final class AppleMeaningClusterTitleGenerator: MeaningClusterTitleGenerating, @unchecked Sendable {
    static let shared = AppleMeaningClusterTitleGenerator()

    private init() {}

    func generateTitle(for input: MeaningClusterTitleInput) async throws -> MeaningClusterGeneratedTitle? {
        throw MeaningClusterTitleGenerationError.modelUnavailable
    }
}
#endif
