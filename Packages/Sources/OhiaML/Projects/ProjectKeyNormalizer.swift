import Foundation

public enum ProjectKeyNormalizer {
    public static func canonicalKey(_ raw: String) -> String {
        let cleaned = wordSpaced(ProjectLabelProseRepair.repairedDisplayLabel(raw))
            .lowercased()
        let scalars = cleaned.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let key = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
        return key.isEmpty ? "unknown" : key
    }

    public static func displayLabel(_ raw: String) -> String {
        wordSpaced(ProjectLabelProseRepair.repairedDisplayLabel(raw))
            .split(whereSeparator: \.isWhitespace)
            .map(titleCasedDisplayToken)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let displayTokenOverrides: [String: String] = [
        "ai": "AI",
        "api": "API",
        "dc": "DC",
        "epic": "EPIC",
        "hoa": "HOA",
        "id": "ID",
        "imap": "IMAP",
        "llm": "LLM",
        "mlx": "MLX",
        "oauth": "OAuth",
        "pdf": "PDF",
        "pw": "PW",
        "rfi": "RFI",
        "rfp": "RFP",
        "rfq": "RFQ",
        "smtp": "SMTP",
        "ui": "UI",
        "url": "URL",
        "ux": "UX"
    ]

    private static func titleCasedDisplayToken(_ raw: Substring) -> String {
        let token = String(raw)
        if let override = displayTokenOverrides[token.lowercased()] {
            return override
        }

        let scalars = token.unicodeScalars
        let hasUppercase = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasLowercase = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        guard hasUppercase || hasLowercase else {
            return token
        }

        if hasDigit,
           startsWithLowercaseScalar(token),
           token.count <= 6 || containsIdentifierSeparator(token) {
            return token.uppercased()
        }

        if hasUppercase && hasLowercase {
            return token
        }

        if hasUppercase {
            return token.count <= 4 || hasDigit
                ? token
                : capitalizingFirstCharacter(of: token.lowercased())
        }

        return capitalizingFirstCharacter(of: token)
    }

    private static func startsWithLowercaseScalar(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        return CharacterSet.lowercaseLetters.contains(first)
    }

    private static func containsIdentifierSeparator(_ token: String) -> Bool {
        token.unicodeScalars.contains { !CharacterSet.alphanumerics.contains($0) }
    }

    private static func capitalizingFirstCharacter(of token: String) -> String {
        guard let first = token.first else { return token }
        return String(first).uppercased() + token.dropFirst()
    }

    private static func wordSpaced(_ raw: String) -> String {
        let scalars = Array(
            raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .unicodeScalars
        )
        guard !scalars.isEmpty else { return "" }

        var output = String.UnicodeScalarView()
        for index in scalars.indices {
            let scalar = scalars[index]
            if shouldInsertBoundary(before: index, in: scalars) {
                output.append(" ")
            }
            output.append(scalar)
        }
        return String(output)
    }

    private static func shouldInsertBoundary(
        before index: Int,
        in scalars: [UnicodeScalar]
    ) -> Bool {
        guard index > scalars.startIndex else { return false }
        let previous = scalars[scalars.index(before: index)]
        let current = scalars[index]
        guard CharacterSet.uppercaseLetters.contains(current) else { return false }

        let hasNext = scalars.indices.contains(scalars.index(after: index))
        let next = hasNext ? scalars[scalars.index(after: index)] : nil
        if CharacterSet.lowercaseLetters.contains(previous)
            || CharacterSet.decimalDigits.contains(previous) {
            if next.map({ CharacterSet.lowercaseLetters.contains($0) }) == true {
                return true
            }
            guard CharacterSet.lowercaseLetters.contains(previous),
                  !hasDigitImmediatelyBefore(index: index, in: scalars) else {
                return false
            }
            return !hasNext
        }
        guard CharacterSet.uppercaseLetters.contains(previous),
              let next,
              scalars.index(before: index) > scalars.startIndex else {
            return false
        }
        return CharacterSet.lowercaseLetters.contains(next)
    }

    private static func hasDigitImmediatelyBefore(
        index: Int,
        in scalars: [UnicodeScalar]
    ) -> Bool {
        let previousIndex = scalars.index(before: index)
        guard previousIndex > scalars.startIndex else { return false }
        let previousPrevious = scalars[scalars.index(before: previousIndex)]
        return CharacterSet.decimalDigits.contains(previousPrevious)
    }
}
