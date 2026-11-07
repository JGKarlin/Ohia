import Foundation
import OhiaCore

/// Decodes and parses delimited text (CSV / TSV) attachments into a raw string
/// grid. Three concerns, each isolated and testable:
///
/// 1. **Encoding** — BOM sniffing, strict UTF-8, then Apple's `NSString`
///    encoding detector with a CJK-inclusive suggestion list, then explicit
///    Shift-JIS / EUC-JP / Windows-1252, with ISO Latin-1 as a guaranteed last
///    resort. No path assumes UTF-8 or any single locale (a flat UTF-8/Latin-1
///    decoder silently mangles Japanese Excel exports).
/// 2. **Delimiter** — the extension default (`,` for CSV, `\t` for TSV); only
///    when that default resolves the sample to a single column does it sniff
///    among `,` `\t` `;` `|` for a consistently wider split.
/// 3. **Grid** — a full RFC 4180 tokenizer: quoted fields, `""` escapes,
///    embedded delimiters / newlines inside quotes, and CR / LF / CRLF record
///    separators.
enum DelimitedTextParser {
    struct ParsedTable: Sendable, Equatable {
        /// All non-empty records; `rows[0]` is the header row.
        let rows: [[String]]
        let delimiter: Character
        /// Human-readable encoding name (e.g. `"utf-8"`, `"shift_jis"`).
        let encoding: String
    }

    enum ParseError: Error, Equatable {
        case undecodable
        case empty
    }

    static func parse(data: Data, format: TabularFormat) throws -> ParsedTable {
        guard let decoded = decodeText(data) else { throw ParseError.undecodable }
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }
        let delimiter = selectDelimiter(text: decoded.text, format: format)
        let grid = parseGrid(decoded.text, delimiter: delimiter).filter { !isBlankRow($0) }
        guard !grid.isEmpty else { throw ParseError.empty }
        return ParsedTable(rows: grid, delimiter: delimiter, encoding: decoded.encoding)
    }

    // MARK: - Delimiter selection

    static func defaultDelimiter(for format: TabularFormat) -> Character {
        format == .tsv ? "\t" : ","
    }

    /// Extension default unless it collapses the sample to one column, in which
    /// case the highest-scoring candidate wins.
    static func selectDelimiter(text: String, format: TabularFormat) -> Character {
        let preferred = defaultDelimiter(for: format)
        if delimiterScore(text, preferred) > 0 { return preferred }

        let candidates: [Character] = [",", "\t", ";", "|"]
        var best = preferred
        var bestScore = 0
        for candidate in candidates where candidate != preferred {
            let score = delimiterScore(text, candidate)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /// Higher is better: rewards a delimiter that splits the leading sample rows
    /// into a *consistent* width > 1. Returns 0 when the delimiter never yields
    /// more than one column.
    private static func delimiterScore(_ text: String, _ delimiter: Character) -> Int {
        let sample = String(text.prefix(16_384))
        let rows = parseGrid(sample, delimiter: delimiter)
            .filter { !isBlankRow($0) }
            .prefix(20)
        guard let columnCount = rows.first?.count, columnCount > 1 else { return 0 }
        let consistent = rows.filter { $0.count == columnCount }.count
        return consistent * 1_000 + columnCount
    }

    // MARK: - RFC 4180 tokenizer

    static func parseGrid(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var sawAnyField = false

        func endField() {
            row.append(field)
            field = ""
            sawAnyField = true
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
            sawAnyField = false
        }

        var index = text.startIndex
        let end = text.endIndex
        while index < end {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < end, text[next] == "\"" {
                        field.append("\"")
                        index = next // consume the escaped quote pair
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    // RFC 4180 §2.5: a quote is only special as the first
                    // character of a field. A bare quote mid-field is a literal,
                    // so malformed input degrades to merged text rather than
                    // swallowing the rest of the line.
                    inQuotes = true
                case delimiter:
                    endField()
                // Swift collapses a CR+LF pair into a single grapheme `Character`,
                // so CRLF, lone CR, and lone LF are matched as three literals
                // rather than peeked apart.
                case "\r\n", "\r", "\n":
                    endRow()
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }

        // Flush a final record that did not end with a newline. A file ending in
        // a newline leaves no pending field, so no spurious trailing row.
        if !field.isEmpty || sawAnyField || !row.isEmpty {
            endRow()
        }
        return rows
    }

    private static func isBlankRow(_ row: [String]) -> Bool {
        row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Encoding detection

    private static func decodeText(_ data: Data) -> (text: String, encoding: String)? {
        guard !data.isEmpty else { return nil }

        if let viaBOM = decodeWithBOM(data) { return viaBOM }

        if let utf8 = String(data: data, encoding: .utf8) {
            return (stripBOM(utf8), "utf-8")
        }

        if let detected = detectWithFoundation(data) { return detected }

        let orderedFallbacks: [(String.Encoding, String)] = [
            (.shiftJIS, "shift_jis"),
            (.japaneseEUC, "euc-jp"),
            (.windowsCP1252, "windows-1252"),
            (.isoLatin1, "iso-8859-1") // maps every byte; guaranteed to succeed
        ]
        for (encoding, name) in orderedFallbacks {
            if let text = String(data: data, encoding: encoding) {
                return (stripBOM(text), name)
            }
        }
        return nil
    }

    private static func decodeWithBOM(_ data: Data) -> (text: String, encoding: String)? {
        let prefix = [UInt8](data.prefix(4))
        // UTF-32 BOMs must precede the UTF-16 checks (FF FE 00 00 starts like FF FE).
        if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return decode(data.dropFirst(4), .utf32LittleEndian, "utf-32le")
        }
        if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return decode(data.dropFirst(4), .utf32BigEndian, "utf-32be")
        }
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            return decode(data.dropFirst(3), .utf8, "utf-8")
        }
        if prefix.starts(with: [0xFF, 0xFE]) {
            return decode(data.dropFirst(2), .utf16LittleEndian, "utf-16le")
        }
        if prefix.starts(with: [0xFE, 0xFF]) {
            return decode(data.dropFirst(2), .utf16BigEndian, "utf-16be")
        }
        return nil
    }

    private static func decode(
        _ data: Data,
        _ encoding: String.Encoding,
        _ name: String
    ) -> (text: String, encoding: String)? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        return (stripBOM(text), name)
    }

    /// Apple's encoding detector, seeded with a CJK-inclusive suggestion list so
    /// Shift-JIS / EUC-JP exports are recognized rather than mojibake'd.
    private static func detectWithFoundation(_ data: Data) -> (text: String, encoding: String)? {
        var converted: NSString?
        let suggested: [Any] = [
            String.Encoding.utf8.rawValue,
            String.Encoding.shiftJIS.rawValue,
            String.Encoding.japaneseEUC.rawValue,
            String.Encoding.windowsCP1252.rawValue,
            String.Encoding.isoLatin1.rawValue,
            String.Encoding.utf16.rawValue
        ]
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: suggested,
            .useOnlySuggestedEncodingsKey: false,
            .allowLossyKey: false
        ]
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: options,
            convertedString: &converted,
            usedLossyConversion: nil
        )
        guard raw != 0, let converted else { return nil }
        return (stripBOM(converted as String), encodingName(String.Encoding(rawValue: raw)))
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func encodingName(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "utf-8"
        case .ascii: return "us-ascii"
        case .utf16: return "utf-16"
        case .utf16LittleEndian: return "utf-16le"
        case .utf16BigEndian: return "utf-16be"
        case .utf32: return "utf-32"
        case .utf32LittleEndian: return "utf-32le"
        case .utf32BigEndian: return "utf-32be"
        case .shiftJIS: return "shift_jis"
        case .japaneseEUC: return "euc-jp"
        case .isoLatin1: return "iso-8859-1"
        case .isoLatin2: return "iso-8859-2"
        case .windowsCP1252: return "windows-1252"
        case .macOSRoman: return "macintosh"
        default: return "encoding-\(encoding.rawValue)"
        }
    }
}
