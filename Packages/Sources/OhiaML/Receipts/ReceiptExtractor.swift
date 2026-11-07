// Packages/Sources/OhiaML/Receipts/ReceiptExtractor.swift
import Foundation

public protocol ReceiptExtracting: Sendable {
    func extract(subject: String, bodyText: String, senderAddress: String) -> ReceiptSummary
}

/// Deterministic pattern-matching extractor. Used on its own until the
/// language model is loaded, and as the fallback layer inside
/// `LLMReceiptExtractor` for fields the model couldn't produce.
public final class HeuristicReceiptExtractor: ReceiptExtracting, Sendable {

    public init() {}

    public func extract(subject: String, bodyText: String, senderAddress: String) -> ReceiptSummary {
        let vendor = extractVendor(subject: subject, senderAddress: senderAddress)
        let amount = extractAmount(from: bodyText) ?? extractAmount(from: subject) ?? "—"
        let item = extractItem(subject: subject, bodyText: bodyText)
        let orderNumber = extractPattern(from: bodyText, pattern: #"(?:Order|order)\s*#?\s*([A-Za-z0-9\-]+)"#)
        let tracking = extractPattern(from: bodyText, pattern: #"(?:Tracking|tracking)\s*#?\s*([A-Za-z0-9]+)"#)

        return ReceiptSummary(
            vendor: vendor,
            itemDescription: item,
            amount: amount,
            date: Date(),
            trackingNumber: tracking,
            orderNumber: orderNumber
        )
    }

    private func extractVendor(subject: String, senderAddress: String) -> String {
        let lowerSender = senderAddress.lowercased()
        if lowerSender.contains("apple") { return "Apple Store" }
        if lowerSender.contains("amazon") { return "Amazon" }
        if lowerSender.contains("aws") { return "AWS" }

        // Fall back to domain name
        if let atIndex = senderAddress.firstIndex(of: "@") {
            let domain = String(senderAddress[senderAddress.index(after: atIndex)...])
            let parts = domain.split(separator: ".")
            if let name = parts.first {
                return String(name).capitalized
            }
        }
        return "Unknown vendor"
    }

    private func extractAmount(from text: String) -> String? {
        let pattern = #"\$[\d,]+\.?\d{0,2}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private func extractItem(subject: String, bodyText: String) -> String {
        let lines = bodyText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.lowercased().hasPrefix("thank") && !trimmed.lowercased().hasPrefix("your ") {
                if trimmed.count > 5 && trimmed.count < 100 {
                    if let dashRange = trimmed.range(of: " - $") {
                        return String(trimmed[trimmed.startIndex..<dashRange.lowerBound])
                    }
                    if let dotRange = trimmed.range(of: ". Amount") {
                        return String(trimmed[trimmed.startIndex..<dotRange.lowerBound])
                    }
                }
            }
        }
        let cleaned = subject.replacingOccurrences(of: "Your receipt from ", with: "")
            .replacingOccurrences(of: "Your Amazon.com order of ", with: "")
            .replacingOccurrences(of: "Payment confirmation", with: "Purchase")
        return cleaned
    }

    private func extractPattern(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
