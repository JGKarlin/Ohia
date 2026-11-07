import CryptoKit
import Foundation
import OhiaCore

public struct SemanticTagQualifierSignature: Sendable, Equatable {
    public let hardValuesByKind: [String: Set<String>]

    public init(hardValuesByKind: [String: Set<String>]) {
        self.hardValuesByKind = hardValuesByKind
    }

    public func conflicts(with other: Self) -> Bool {
        hardValuesByKind.contains { kind, values in
            guard let otherValues = other.hardValuesByKind[kind] else { return false }
            return values.isDisjoint(with: otherValues)
        }
    }
}

public enum SemanticTagNormalizer {
    private static let hardQualifierKinds: Set<String> = [
        "application", "campaign", "case", "claim", "course", "event",
        "institution", "location", "order", "program", "property", "ticket",
        "trip", "version", "year",
    ]

    public static func normalizedText(_ raw: String) -> String {
        let compatible = raw.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let mappedScalars = compatible.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mappedScalars)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    public static func aliasKey(_ raw: String) -> String {
        normalizedText(raw)
            .split(separator: " ")
            .map(String.init)
            .sorted()
            .joined(separator: " ")
    }

    public static func qualifierSignature(
        label: String,
        qualifiers: [SemanticTagQualifier]
    ) -> SemanticTagQualifierSignature {
        var valuesByKind: [String: Set<String>] = [:]

        for qualifier in qualifiers {
            let kind = normalizedText(qualifier.kind)
            guard hardQualifierKinds.contains(kind) else { continue }
            let value = normalizedText(qualifier.value)
            guard !value.isEmpty else { continue }
            valuesByKind[kind, default: []].insert(value)
        }

        for year in fourDigitYears(in: label) {
            valuesByKind["year", default: []].insert(year)
        }

        return SemanticTagQualifierSignature(hardValuesByKind: valuesByKind)
    }

    public static func logicalMessageKey(for message: Message) -> String {
        if let messageID = nonEmpty(message.messageIdHeader) {
            let normalized = messageID
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            if !normalized.isEmpty {
                return "message-id:\(normalized)"
            }
        }
        if let contentHash = nonEmpty(message.contentHash) {
            return "content-hash:\(contentHash.lowercased(with: Locale(identifier: "en_US_POSIX")))"
        }
        return "message:\(message.id.uuidString.lowercased())"
    }

    public static func observationFingerprint(
        message: Message,
        candidate: SemanticTagCandidate,
        extractionVersion: String
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let candidateData = (try? encoder.encode(candidate)) ?? Data()
        let input = [
            logicalMessageKey(for: message),
            extractionVersion,
            String(decoding: candidateData, as: UTF8.self),
        ].joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fourDigitYears(in raw: String) -> Set<String> {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = yearExpression.matches(in: raw, range: range)
        return Set(matches.compactMap { match in
            guard let swiftRange = Range(match.range, in: raw) else { return nil }
            return String(raw[swiftRange])
        })
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static let yearExpression = try! NSRegularExpression(
        pattern: #"(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])"#
    )
}
