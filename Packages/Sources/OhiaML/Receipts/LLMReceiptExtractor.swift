// LLMReceiptExtractor.swift
// LLM-backed implementation of ReceiptExtracting. Merges language model
// output with a heuristic fallback so every field has a best-effort value
// regardless of whether the model is loaded or parsing succeeds.
//
// Strategy:
//   1. Run the heuristic extractor first — cheap, deterministic, always
//      returns a complete ReceiptSummary.
//   2. If the engine isn't loaded, return the heuristic result unchanged.
//   3. Otherwise prompt the engine for structured JSON and overlay any
//      non-empty fields on top of the heuristic result. LLM wins where it
//      speaks; heuristic fills gaps.
//
// The merge strategy means a partial or malformed LLM response degrades
// gracefully — callers always get a fully populated summary.

import Foundation
import OhiaCore

public final class LLMReceiptExtractor: ReceiptExtracting, @unchecked Sendable {

    private let engine: any TrainingEngine
    private let fallback: any ReceiptExtracting
    private let maxTokens: Int
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?

    public init(
        engine: any TrainingEngine,
        fallback: any ReceiptExtracting = HeuristicReceiptExtractor(),
        maxTokens: Int = 220,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil
    ) {
        self.engine = engine
        self.fallback = fallback
        self.maxTokens = maxTokens
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
    }

    public func extract(subject: String, bodyText: String, senderAddress: String) -> ReceiptSummary {
        let heuristic = fallback.extract(
            subject: subject,
            bodyText: bodyText,
            senderAddress: senderAddress
        )

        guard engine.isModelLoaded else { return heuristic }

        guard let parsed = tryGenerate(
            subject: subject,
            bodyText: bodyText,
            senderAddress: senderAddress
        ) else {
            return heuristic
        }

        return ReceiptSummary(
            vendor: nonEmpty(parsed.vendor) ?? heuristic.vendor,
            itemDescription: nonEmpty(parsed.item) ?? heuristic.itemDescription,
            amount: nonEmpty(parsed.amount) ?? heuristic.amount,
            // Date extraction from LLM is error-prone — keep heuristic's
            // ingestion date unless the LLM produces a parseable ISO-8601.
            date: parseISODate(parsed.date) ?? heuristic.date,
            trackingNumber: nonEmpty(parsed.trackingNumber) ?? heuristic.trackingNumber,
            orderNumber: nonEmpty(parsed.orderNumber) ?? heuristic.orderNumber,
            subscriptionPeriod: nonEmpty(parsed.subscriptionPeriod) ?? heuristic.subscriptionPeriod
        )
    }

    // MARK: - LLM call

    private struct ParsedReceipt: Decodable {
        let vendor: String?
        let item: String?
        let amount: String?
        let date: String?
        let orderNumber: String?
        let trackingNumber: String?
        let subscriptionPeriod: String?
    }

    private func tryGenerate(
        subject: String,
        bodyText: String,
        senderAddress: String
    ) -> ParsedReceipt? {
        let prompt = Self.buildPrompt(
            subject: subject,
            bodyText: bodyText,
            senderAddress: senderAddress
        )
        let activityToken = modelActivityStatusPublisher?.begin(.extracting, source: "receipt-extraction")
        defer {
            if let activityToken {
                modelActivityStatusPublisher?.end(activityToken)
            }
        }

        guard let raw = try? PrefixCachedGeneration.generate(
            engine: engine,
            prompt: prompt,
            maxTokens: maxTokens
        ) else {
            return nil
        }
        return Self.parseJSON(raw)
    }

    /// Static instruction stem; identical across every call, so it is the
    /// prompt's `.instructions` checkpoint and the worker's saved prompt state
    /// (`MLXTrainingEngine.generateWithCheckpoints`) skips reprefilling these
    /// tokens after the first request.
    private static let promptPrefix = """
    Extract receipt fields from this email. Return JSON only — no prose, \
    no code fences. Omit a field (or pass null) when the email does not \
    state it. Do NOT invent values.

    Schema:
    {
      "vendor": "...",
      "item": "short description (<60 chars)",
      "amount": "$12.99 or €9,90",
      "date": "ISO-8601 date if present, else null",
      "orderNumber": "...",
      "trackingNumber": "...",
      "subscriptionPeriod": "monthly / annual / null"
    }


    """

    static func buildPrompt(
        subject: String,
        bodyText: String,
        senderAddress: String
    ) -> PrefixCachedPrompt {
        let trimmed = bodyText.prefix(1800)
        let suffix = """
        From: \(senderAddress)
        Subject: \(subject)

        Body:
        \(trimmed)

        JSON:
        """
        return PrefixCachedPrompt(
            cacheKey: "receipt-extraction-v1",
            prefix: promptPrefix,
            suffix: suffix
        )
    }

    // MARK: - Parsing

    /// Extracts the first `{ ... }` object from the model's output and
    /// decodes it. Tolerates prose/code fences around the JSON.
    private static func parseJSON(_ raw: String) -> ParsedReceipt? {
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let slice = stripped[start...end]
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParsedReceipt.self, from: data)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed == "—" || trimmed.lowercased() == "null" || trimmed.lowercased() == "none" {
            return nil
        }
        return trimmed
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }
}
