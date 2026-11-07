// TrainingPromptFormatter.swift
// The completion side of a training example. Prompts are rendered by
// `ComposerWriterPrompt`, the same function the runtime writer uses.

import Foundation
import OhiaCore

/// A prompt-completion pair suitable for fine-tuning.
public struct TrainingExample: Sendable {
    public let prompt: String
    public let completion: String
    /// Relative contribution of this example's completion tokens to the
    /// normalized loss. This preserves fractional evidence weights instead of
    /// rounding every pair up to one duplicated full-strength example.
    public let weight: Double

    public init(prompt: String, completion: String, weight: Double = 1) {
        self.prompt = prompt
        self.completion = completion
        self.weight = weight
    }
}

public enum TrainingPromptFormatter {
    /// Wraps the authored text as a completion: the text and then the end
    /// marker on its own line. Signature and quoted-history hygiene happens
    /// once, at the pair-building seam via `AuthoredReplyText.extract`, never
    /// here: a second pass is not idempotent.
    public static func formatCompletion(_ userReply: String) -> String {
        userReply + "\n" + GenerationStopPolicy.draftEndMarker
    }

    /// The stored completion's body with the end marker stripped — the
    /// inverse of `formatCompletion`'s wrapping.
    public static func storedCompletionBody(_ stored: String) -> String {
        guard let markerRange = stored.range(
            of: GenerationStopPolicy.draftEndMarker, options: .backwards
        ) else { return stored }
        return String(stored[..<markerRange.lowerBound])
    }

    /// Re-derives a completion from a stored pair's completion text: strips
    /// the end marker, cuts any quoted-history tail an older format retained,
    /// and re-wraps. Nil when nothing authored remains.
    public static func reformatCompletion(fromStored stored: String) -> String? {
        let authored = AuthoredReplyText.extract(from: storedCompletionBody(stored))
        guard !authored.isEmpty else { return nil }
        return formatCompletion(authored)
    }
}
