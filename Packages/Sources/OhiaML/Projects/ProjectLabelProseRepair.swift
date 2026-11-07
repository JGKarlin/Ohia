import Foundation

enum ProjectLabelProseRepair {
    private static let trimCharacters = CharacterSet(charactersIn: " -_|/=:()[]{}\"'")

    static func repairedDisplayLabel(_ raw: String) -> String {
        let normalized = normalizedWhitespace(raw)
            .trimmingCharacters(in: trimCharacters)
        guard normalized.isEmpty == false else { return "" }
        if emptyFragments.contains(normalizedIdentity(normalized)) {
            return ""
        }
        if let canonical = extractedCanonicalLabel(in: normalized) {
            return canonical
        }
        if let mainProject = extractedMainProjectLabel(in: normalized) {
            return mainProject
        }
        if isExplanatoryMetadataSentence(normalized) {
            return ""
        }
        if let strippedMetadata = strippedTrailingMetadata(from: normalized) {
            return strippedMetadata
        }
        return normalized
    }

    private static func extractedCanonicalLabel(in raw: String) -> String? {
        firstCapture(
            in: raw,
            patterns: [
                #"\bcanonical\s*(?:_|\s)?key\b\s*(?:would\s+be|should\s+be|is|:|=)?\s+(.+?)(?:\s+\bas\s+the\s+label\b|\s+\bcentrality\b|\s+\bconfidence\b|\s+\broles?\b|\s+\bscore\b|[.;|]|$)"#
            ],
            stripPersonQualifier: false
        )
    }

    private static func extractedMainProjectLabel(in raw: String) -> String? {
        firstCapture(
            in: raw,
            patterns: [
                #"^(?:the\s+)?main\s+project\s+(?:here\s+)?(?:is|would\s+be|should\s+be)\s+(.+?)(?:\s+\bcanonical\s*(?:_|\s)?key\b|\s+\bcentrality\b|\s+\bconfidence\b|[.;]|$)"#
            ],
            stripPersonQualifier: true
        )
    }

    private static func firstCapture(
        in raw: String,
        patterns: [String],
        stripPersonQualifier: Bool
    ) -> String? {
        let nsRange = NSRange(raw.startIndex ..< raw.endIndex, in: raw)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: raw, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: raw) else {
                continue
            }
            let repaired = cleanedExtractedLabel(
                String(raw[range]),
                stripPersonQualifier: stripPersonQualifier
            )
            guard repaired.isEmpty == false else { continue }
            return repaired
        }
        return nil
    }

    private static func strippedTrailingMetadata(from raw: String) -> String? {
        let markers = [
            #"\s+\bcentrality\b\s*(?:is|:|=|\bprimary\b|\bsecondary\b|\bmention\b)"#,
            #"\s+\bconfidence\b\s*(?:is|:|=)"#,
            #"\s+\broles?\b\s*(?:is|:|=)"#
        ]
        for marker in markers {
            guard let range = raw.range(of: marker, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let prefix = String(raw[..<range.lowerBound])
            let repaired = cleanedExtractedLabel(prefix, stripPersonQualifier: false)
            return repaired.isEmpty ? nil : repaired
        }
        return nil
    }

    private static func isExplanatoryMetadataSentence(_ raw: String) -> Bool {
        let patterns = [
            #"^\s*roles?\s+(?:include|includes|are|is)\b"#,
            #"^\s*confidence\s+(?:is|would\s+be|should\s+be|:|=)\b"#,
            #"^\s*centrality\s+(?:is|would\s+be|should\s+be|:|=)\b"#,
            #"^\s*score\s*(?:is|:|=)\b"#,
            #"^\s*(?:the\s+)?main\s+topic\b"#
        ]
        return patterns.contains { pattern in
            raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func cleanedExtractedLabel(
        _ raw: String,
        stripPersonQualifier: Bool
    ) -> String {
        var value = normalizedWhitespace(raw)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: #"(?i)^\s*(?:label|name|canonical\s*(?:_|\s)?key|key)\s*(?:would\s+be|should\s+be|is|:|=)\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\bas\s+the\s+label\b.*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\bcentrality\b\s*(?:is|:|=|\bprimary\b|\bsecondary\b|\bmention\b).*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\bconfidence\b\s*(?:is|:|=).*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\broles?\b\s*(?:include|includes|is|are|:|=).*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\bscore\b\s*(?:is|:|=).*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+\bso\b\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: trimCharacters)

        value = value.replacingOccurrences(
            of: #"(?i)^(?:the)\s+"#,
            with: "",
            options: .regularExpression
        )
        if stripPersonQualifier {
            value = strippingLikelyPersonQualifier(from: value)
        }
        return normalizedWhitespace(value)
            .trimmingCharacters(in: trimCharacters)
    }

    private static func strippingLikelyPersonQualifier(from raw: String) -> String {
        guard let range = raw.range(of: " for ", options: [.caseInsensitive, .backwards]) else {
            return raw
        }
        let prefix = String(raw[..<range.lowerBound])
            .trimmingCharacters(in: trimCharacters)
        let suffix = String(raw[range.upperBound...])
            .trimmingCharacters(in: trimCharacters)
        guard shouldDropPersonQualifier(prefix: prefix, suffix: suffix) else {
            return raw
        }
        return prefix
    }

    private static func shouldDropPersonQualifier(prefix: String, suffix: String) -> Bool {
        let normalizedPrefix = prefix.lowercased()
        guard normalizedPrefix.contains("committee setup")
            || normalizedPrefix.contains("review committee")
            || normalizedPrefix.contains("doctoral thesis") else {
            return false
        }
        let nameTokens = suffix.split(whereSeparator: \.isWhitespace)
        guard (1 ... 4).contains(nameTokens.count) else { return false }
        return nameTokens.allSatisfy(isLikelyCapitalizedNameToken)
    }

    private static func isLikelyCapitalizedNameToken(_ token: Substring) -> Bool {
        let value = token.trimmingCharacters(in: trimCharacters)
        guard let first = value.unicodeScalars.first,
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return false
        }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    private static func normalizedWhitespace(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedIdentity(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let emptyFragments: Set<String> = [
        "as the label",
        "the label",
        "would be",
        "should be"
    ]
}
