// StyleRegisterDistiller.swift
// Describes a discovered style for the Style pane's hover help. Given the
// style's measured slider centroid, the author's other styles in the same
// language, and sample excerpts of member emails, the generative model
// writes one or two sentences about the style's habits. The description is
// display text only: it never enters a drafting or training prompt, because
// the voice itself is learned by the adapter.

import Foundation
import OhiaCore

public enum StyleRegisterDistiller {

    public static let distillVersion = "style-register-v5"

    /// The fixed-width Composer Style selector has room for this many
    /// characters across two lines at its 11-point semibold label font.
    public static let maxGeneratedNameCharacters = 24

    /// Sample excerpts per prompt.
    static let maxSamples = 6
    /// Characters per sample excerpt.
    static let maxSampleChars = 240
    /// Characters kept from the model's summary.
    static let maxSummaryCharacters = 280

    /// Static instruction stem, identical across calls for KV prefix caching.
    static let promptPrefix = """
    You describe one writing style found in a single author's sent email. \
    The style was found by measuring six sliders (0.0–1.0) on every sent \
    email: detail (concise→detailed), formality (casual→formal), urgency \
    (relaxed→pressing), technicality (plain→technical), warmth \
    (reserved→warm), seriousness (playful→earnest). You will see this \
    style's measured centroid, the author's other styles in the same \
    language, and sample excerpts of emails in this style.

    Write one or two sentences describing the STYLE's habits — typical \
    length, openings and closings, sentence shape, tone — and what sets it \
    apart from the author's other styles. Never describe topics, facts, or \
    people. Never make "the user", "the author", "the writer", "they", or \
    any person the subject; describe the writing directly (e.g. "Short \
    replies that open with the first name and close with a one-word \
    sign-off; direct, friendly, and free of technical terms."). Do not name \
    the language. Return JSON only — no prose, no code fences:
    {"summary":"…"}


    """

    /// Builds the description prompt for one style. `otherStyles` are the
    /// language's other active styles as (name, centroid) for contrast.
    public static func buildPrompt(
        name: String,
        centroid: StyleAxisValues,
        memberCount: Int,
        otherStyles: [(name: String, centroid: StyleAxisValues)],
        sampleReplies: [String],
        outputLanguage: SummarizationTargetLanguage? = nil
    ) -> PrefixCachedPrompt {
        var lines: [String] = []
        if let outputLanguage {
            // The description is read in the Style panel, in the reading
            // language, whichever language the samples are written in.
            lines.append("[OUTPUT LANGUAGE] Write the summary in \(outputLanguage.promptDescription).")
        }
        lines.append("""
        [THIS STYLE]
        Name: \(name)
        Sent emails: \(memberCount)
        Measured centroid: \(centroid.jsonString ?? "unavailable")
        """)
        if !otherStyles.isEmpty {
            var others = ["[OTHER STYLES IN THIS LANGUAGE]"]
            for other in otherStyles {
                others.append("\(other.name): \(other.centroid.jsonString ?? "unavailable")")
            }
            lines.append(others.joined(separator: "\n"))
        }
        var samples = ["[SAMPLES — excerpts of sent emails in this style]"]
        for (index, sample) in sampleReplies.prefix(maxSamples).enumerated() {
            samples.append("\(index + 1). \(sample)")
        }
        lines.append(samples.joined(separator: "\n"))
        lines.append("JSON:")
        return PrefixCachedPrompt(
            cacheKey: distillVersion,
            prefix: promptPrefix,
            suffix: lines.joined(separator: "\n\n")
        )
    }

    /// Extracts the summary from model output. Tolerates leading/trailing
    /// prose and code fences; nil when unparseable, empty, or written about
    /// a person rather than the writing.
    public static func parseSummary(_ raw: String) -> String? {
        struct Payload: Decodable { let summary: String }
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"),
              start < end,
              let data = String(stripped[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let summary = decoded.summary
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= maxSummaryCharacters else { return nil }
        let opening = summary.lowercased()
        let personSubjects = ["the user", "the author", "the writer", "they ", "he ", "she "]
        guard !personSubjects.contains(where: opening.hasPrefix) else { return nil }
        return summary
    }

    /// Display-ready sample excerpts from member completions, spread evenly
    /// across the members so one prolific thread doesn't dominate.
    public static func sampleExcerpts(from completions: [String]) -> [String] {
        guard !completions.isEmpty else { return [] }
        let stride = max(1, completions.count / maxSamples)
        var samples: [String] = []
        var index = 0
        while index < completions.count && samples.count < maxSamples {
            let cleaned = completions[index]
                .replacingOccurrences(of: GenerationStopPolicy.draftEndMarker, with: "")
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                samples.append(String(cleaned.prefix(maxSampleChars)))
            }
            index += stride
        }
        return samples
    }

    /// Values ordered by descending frequency, ties broken alphabetically.
    public static func frequencyOrdered(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty {
            counts[value, default: 0] += 1
        }
        return counts
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .map(\.key)
    }
}
