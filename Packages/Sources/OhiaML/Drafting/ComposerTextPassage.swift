import Foundation

struct ComposerTextPassage: Encodable, Sendable {
    let id: String
    let text: String
    let start: Int
    let end: Int
    enum CodingKeys: String, CodingKey { case id, text }

    static func index(_ text: String, prefix: String) -> [Self] {
        let characters = Array(text)
        var result: [Self] = [], start = 0
        func append(until end: Int) {
            var lower = start, upper = end
            while lower < upper && characters[lower].isWhitespace { lower += 1 }
            while upper > lower && characters[upper - 1].isWhitespace { upper -= 1 }
            if lower < upper {
                result.append(Self(id: "\(prefix)\(result.count + 1)", text: String(characters[lower..<upper]),
                    start: lower, end: upper))
            }
        }
        for offset in characters.indices {
            let character = characters[offset]
            if "。！？!?\n".contains(character)
                || (character == "." && (offset + 1 == characters.count || characters[offset + 1].isWhitespace)
                    && !isAbbreviation(characters, endingAt: offset)) {
                append(until: offset + 1)
                start = offset + 1
            }
        }
        if start < characters.count { append(until: characters.count) }
        return result
    }

    /// Titles, Latin abbreviations and initials whose period ends no
    /// sentence ("Dr. Smith", "3 p.m. on Monday", "A. Morgan"), and a list
    /// number opening its line ("1. Bring the slides.").
    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "a.m", "p.m",
        "approx", "dept", "fig", "vol", "ed", "eds", "cf", "u.s", "u.k"
    ]

    private static func isAbbreviation(_ characters: [Character], endingAt period: Int) -> Bool {
        var start = period
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        let token = String(characters[start..<period])
        guard !token.isEmpty else { return false }
        if abbreviations.contains(token.lowercased()) { return true }
        if token.count == 1, token.first?.isUppercase == true { return true }
        // A list number is the first thing on its line.
        if token.allSatisfy(\.isNumber), token.count <= 3 {
            var before = start
            while before > 0, characters[before - 1] == " " || characters[before - 1] == "\t" { before -= 1 }
            return before == 0 || characters[before - 1].isNewline
        }
        return false
    }

    static func quote(_ ids: [String], from passages: [Self], in text: String) throws -> String? {
        guard !ids.isEmpty else { return nil }
        let selected = passages.filter { ids.contains($0.id) }
        guard Set(selected.map(\.id)) == Set(ids), Set(ids).count == ids.count,
              let start = selected.map(\.start).min(), let end = selected.map(\.end).max() else {
            throw ComposerContentError.invalidAudit("The audit referenced an unknown or repeated candidate passage.")
        }
        return String(Array(text)[start..<end])
    }
}
