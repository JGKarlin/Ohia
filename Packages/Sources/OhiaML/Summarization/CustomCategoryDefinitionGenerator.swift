// CustomCategoryDefinitionGenerator.swift
// Writes the LLM definition for a user-created custom mail category once
// the user has tagged enough example messages. The definition is persisted
// on `CustomMailCategory.definition` and from then on steers ingestion-time
// categorization through `SummarizationPromptBuilder.customCategoryGuide`.

import Foundation
import OhiaCore

/// Inputs for one definition-generation request.
public struct CustomCategoryDefinitionRequest: Sendable, Equatable {
    public struct Example: Sendable, Equatable {
        public let subject: String
        public let senderLine: String
        public let excerpt: String

        public init(subject: String, senderLine: String, excerpt: String) {
            self.subject = subject
            self.senderLine = senderLine
            self.excerpt = excerpt
        }
    }

    public let displayName: String
    public let key: String
    public let examples: [Example]
    /// Other already-active custom categories, included so the new
    /// definition can disambiguate against them as well as against the
    /// fixed taxonomy.
    public let otherCustomCategories: [CustomMailCategoryDescriptor]

    public init(
        displayName: String,
        key: String,
        examples: [Example],
        otherCustomCategories: [CustomMailCategoryDescriptor] = []
    ) {
        self.displayName = displayName
        self.key = key
        self.examples = examples
        self.otherCustomCategories = otherCustomCategories
    }
}

public enum CustomCategoryDefinitionPromptBuilder {
    static let exampleLimit = 8
    static let exampleExcerptCharacterLimit = 700
    static let definitionCharacterLimit = 1_400

    public static func prompt(for request: CustomCategoryDefinitionRequest) -> String {
        let exampleBlocks = request.examples
            .prefix(exampleLimit)
            .enumerated()
            .map { index, example in
                """
                Example \(index + 1):
                From: \(clean(example.senderLine, limit: 160))
                Subject: \(clean(example.subject, limit: 200))
                Content: \(clean(example.excerpt, limit: exampleExcerptCharacterLimit))
                """
            }
            .joined(separator: "\n\n")

        let otherCustomSection: String
        if request.otherCustomCategories.isEmpty {
            otherCustomSection = ""
        } else {
            let entries = request.otherCustomCategories.map { descriptor in
                "- \(descriptor.key) (\(descriptor.displayName)): \(clean(descriptor.definition ?? "", limit: 320))"
            }
            otherCustomSection = """

            Existing user-defined categories (disambiguate against these too):
            \(entries.joined(separator: "\n"))
            """
        }

        return """
        You are writing the classifier definition for a new user-defined mail category in Ohia's mail taxonomy. The user named the category "\(clean(request.displayName, limit: 120))" (canonical key: \(request.key)) and tagged the example messages below as members.

        Write one compact heuristic definition that states (1) what belongs to the custom category, grounded in the shared central characteristics, (2) the evidence a classifier should require, and (3) explicit disambiguation rules against other user-defined categories when relevant. Keep the custom category additive to the shared purpose vocabulary: describe its own boundary without using it as a substitute for a built-in purpose. The definition must be general enough to match future messages, not merely restate the supplied material. Do not mention the words "example", "tagged", or "user" in the definition. Write the definition in English. 3 to 7 sentences.

        Reference taxonomy (fixed category definitions, for style and disambiguation targets):
        \(SummarizationPromptBuilder.classificationGuide)
        \(otherCustomSection)

        Tagged member messages:
        \(exampleBlocks)

        /no_think

        Return exactly the field line below. Do not return reasoning, analysis, JSON, bullets, or the /no_think control token. End with the single line \(GenerationStopPolicy.summaryEndMarker) and stop immediately after it.

        Definition: <the definition>
        \(GenerationStopPolicy.summaryEndMarker)
        """
    }

    /// Extracts the definition text from raw model output. Tolerates think
    /// blocks, a missing `Definition:` label, and a missing end marker, but
    /// rejects empty output so the caller can retry instead of activating a
    /// category with a blank definition.
    public static func parseDefinition(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Drop <think> blocks (and any unterminated trailing one).
        text = text.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<think>.*"#,
            with: " ",
            options: .regularExpression
        )
        if let markerRange = text.range(of: GenerationStopPolicy.summaryEndMarker) {
            text = String(text[..<markerRange.lowerBound])
        }
        if let labelRange = text.range(
            of: #"(?i)definition\s*:"#,
            options: .regularExpression
        ) {
            text = String(text[labelRange.upperBound...])
        }
        let cleaned = text
            .replacingOccurrences(of: "/no_think", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 20 else { return nil }
        guard cleaned.count > definitionCharacterLimit else { return cleaned }
        return String(cleaned.prefix(definitionCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CustomCategoryDefinitionError: Error, Sendable {
    case unusableModelOutput
}

/// Drives one definition generation through the local engine. The
/// generation runs on a detached background task (matching the summarizer
/// paths) and cancellation is cooperative through `GenerationCancellation`.
public final class CustomCategoryDefinitionGenerator: @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int

    public init(engine: any TrainingEngine, maxTokens: Int = 480) {
        self.engine = engine
        self.maxTokens = maxTokens
    }

    public func generateDefinition(
        for request: CustomCategoryDefinitionRequest,
        priority: TaskPriority = .utility
    ) async throws -> String {
        let prompt = CustomCategoryDefinitionPromptBuilder.prompt(for: request)
        let engine = self.engine
        let maxTokens = self.maxTokens
        let cancellation = GenerationCancellation()
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        let raw = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
        guard let definition = CustomCategoryDefinitionPromptBuilder.parseDefinition(raw) else {
            throw CustomCategoryDefinitionError.unusableModelOutput
        }
        return definition
    }
}
