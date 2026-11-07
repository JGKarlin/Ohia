import Foundation
import FoundationModels

/// A fresh session's input allowance, after reserving its schema, instructions,
/// response, and framing. Never infer model capacity from the OS version.
struct ApplePromptBudget: Sendable {
    static let summaryResponseTokens = 768
    static let analysisResponseTokens = 1200
    static let framingTokens = 256

    let promptTokens: Int

    init(contextSize: Int, overheadTokens: Int, responseTokens: Int) {
        promptTokens = max(0, contextSize - max(0, overheadTokens)
            - max(0, responseTokens) - Self.framingTokens)
    }

    func fits(promptTokens count: Int) -> Bool {
        promptTokens > 0 && count >= 0 && count <= promptTokens
    }

    static func current(
        instructions: String,
        schema: GenerationSchema,
        responseTokens: Int,
        model: SystemLanguageModel = .default
    ) async throws -> Self {
        try Task.checkCancellation()
        let overhead: Int
        if #available(macOS 26.4, *) {
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let schemaTokens = try await model.tokenCount(for: schema)
            overhead = instructionTokens + schemaTokens
        } else {
            let schemaJSON = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
            overhead = estimatedTokens(instructions) + estimatedTokens(schemaJSON)
        }
        return Self(contextSize: model.contextSize, overheadTokens: overhead, responseTokens: responseTokens)
    }

    func fits(prompt: String, model: SystemLanguageModel = .default) async throws -> Bool {
        try Task.checkCancellation()
        let count: Int
        if #available(macOS 26.4, *) {
            count = try await model.tokenCount(for: Prompt(prompt))
        } else {
            count = Self.estimatedTokens(prompt)
        }
        return fits(promptTokens: count)
    }

    enum CapacityError: Error { case insufficientContext }

    static func requireFits(
        prompt: String,
        instructions: String,
        schema: GenerationSchema,
        responseTokens: Int = summaryResponseTokens
    ) async throws {
        let budget = try await current(instructions: instructions, schema: schema, responseTokens: responseTokens)
        guard try await budget.fits(prompt: prompt) else {
            throw CapacityError.insufficientContext
        }
    }

    private static func estimatedTokens(_ text: String) -> Int {
        // macOS 26.0–26.3 has no tokenizer API. UTF-8 accounts for multilingual
        // input more conservatively than the former character-only estimate.
        max(Int(ceil(Double(text.utf8.count) / 3)),
            Int(ceil(Double(text.split(whereSeparator: \.isWhitespace).count) * 1.35)))
    }

    static func fitBody(
        _ body: String,
        maximumCharacters: Int,
        fits: (String) async throws -> Bool
    ) async throws -> String? {
        let characters = Array(body.prefix(max(0, maximumCharacters)))
        let entire = String(characters)
        if try await fits(entire) { return entire }
        guard try await fits("") else { return nil }
        var lower = 0
        var upper = characters.count
        // Search only prefixes and return a prefix actually measured as fitting.
        // Token counts need not be strictly monotonic at a word boundary.
        var best = ""
        while lower + 1 < upper {
            try Task.checkCancellation()
            let middle = lower + (upper - lower) / 2
            let candidate = String(characters.prefix(middle))
            if try await fits(candidate) {
                best = candidate
                lower = middle
            } else {
                upper = middle
            }
        }
        return best.isEmpty && !body.isEmpty ? nil : best
    }
}
