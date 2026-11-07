import Foundation

/// Structured intermediate representation for a delimited tabular attachment
/// (CSV / TSV). Unlike the flat-text path it replaces, this preserves the typed
/// grid — header, per-column inferred types, and per-cell raw value + type — so
/// a future deterministic compute path (e.g. answering "sum of column C") can
/// query the table instead of relying on embed-and-retrieve over rendered text.
///
/// This is the value persisted as the attachment's `normalizedIRJSON`. The
/// retrieval-side projection (embedding text + RAG chunks) is produced
/// separately via the Office RAG normalizer so CSV/TSV reach parity with XLSX.
public struct TabularDocumentIR: Codable, Sendable, Equatable {
    /// Bumped when the on-disk shape changes in a non-additive way.
    public let schemaVersion: Int
    public let fileName: String
    public let format: TabularFormat
    /// The delimiter actually used to parse the grid (after sniffing). One of
    /// `","`, `"\t"`, `";"`, `"|"`.
    public let delimiter: String
    /// Human-readable name of the text encoding the bytes were decoded with
    /// (e.g. `"utf-8"`, `"shift_jis"`, `"windows-1252"`, `"iso-8859-1"`).
    public let encoding: String
    /// Whether the first parsed record was treated as a header row. Always
    /// `true` in the current pipeline (parity with the XLSX assumption that
    /// row 1 holds column labels), but modeled explicitly so a future
    /// headerless mode is a data change, not a code change.
    public let hasHeader: Bool
    public let columns: [TabularColumn]
    /// Total non-empty data rows discovered in the source (excludes the header),
    /// before any preservation cap is applied.
    public let rowCount: Int
    /// Number of rows actually retained in `rows`. Equal to `rowCount` unless
    /// the source exceeded the preservation cap.
    public let preservedRowCount: Int
    /// `true` when `rows` holds fewer than `rowCount` rows because the source
    /// exceeded the preservation cap. Surfaced (not silent) so downstream
    /// computation knows the grid is partial.
    public let isTruncated: Bool
    public let rows: [TabularRow]

    public init(
        schemaVersion: Int = 1,
        fileName: String,
        format: TabularFormat,
        delimiter: String,
        encoding: String,
        hasHeader: Bool,
        columns: [TabularColumn],
        rowCount: Int,
        preservedRowCount: Int,
        isTruncated: Bool,
        rows: [TabularRow]
    ) {
        self.schemaVersion = schemaVersion
        self.fileName = fileName
        self.format = format
        self.delimiter = delimiter
        self.encoding = encoding
        self.hasHeader = hasHeader
        self.columns = columns
        self.rowCount = max(0, rowCount)
        self.preservedRowCount = max(0, preservedRowCount)
        self.isTruncated = isTruncated
        self.rows = rows
    }
}

public enum TabularFormat: String, Codable, Sendable, Equatable {
    case csv
    case tsv
}

/// The value class inferred for a cell or the dominant class for a column.
/// Deliberately narrow and serialization-token based (not natural-language):
/// booleans are only the literal tokens `true`/`false`, never localized words
/// like yes/no/はい, so the inference carries no English-only assumption.
public enum TabularValueType: String, Codable, Sendable, Equatable {
    case empty
    case integer
    case decimal
    case boolean
    case string

    /// Classify a raw cell string. ASCII-digit based; full-width or
    /// locale-specific numeral forms classify as `.string` rather than being
    /// silently coerced.
    public static func infer(_ raw: String) -> TabularValueType {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let lowered = trimmed.lowercased()
        if lowered == "true" || lowered == "false" { return .boolean }
        if isInteger(trimmed) { return .integer }
        if isDecimal(trimmed) { return .decimal }
        return .string
    }

    private static func isInteger(_ value: String) -> Bool {
        var digits = Substring(value)
        if let first = digits.first, first == "+" || first == "-" {
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return false }
        return digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isDecimal(_ value: String) -> Bool {
        // A decimal must contain a fractional or exponent marker and parse as a
        // finite Double. `Double("12")` succeeds, so the marker check is what
        // separates decimal from integer.
        guard value.contains(".") || value.lowercased().contains("e") else { return false }
        guard let parsed = Double(value), parsed.isFinite else { return false }
        return true
    }
}

public struct TabularColumn: Codable, Sendable, Equatable {
    /// 0-based column position.
    public let index: Int
    /// Header label, or `"Column N"` (1-based) when the header cell was blank.
    public let name: String
    /// Dominant non-empty value type across the preserved data rows; `.string`
    /// when the column mixes types or is entirely empty.
    public let inferredType: TabularValueType

    public init(index: Int, name: String, inferredType: TabularValueType) {
        self.index = index
        self.name = name
        self.inferredType = inferredType
    }
}

public struct TabularRow: Codable, Sendable, Equatable {
    /// 0-based index among data rows (the header is not a data row).
    public let index: Int
    public let cells: [TabularCell]

    public init(index: Int, cells: [TabularCell]) {
        self.index = index
        self.cells = cells
    }
}

public struct TabularCell: Codable, Sendable, Equatable {
    /// 0-based column position this cell belongs to.
    public let column: Int
    public let raw: String
    public let type: TabularValueType

    public init(column: Int, raw: String, type: TabularValueType) {
        self.column = column
        self.raw = raw
        self.type = type
    }

    /// The numeric value when this cell is `.integer` or `.decimal`, else `nil`.
    /// Parses from `raw` on demand so the serialized grid stays compact.
    public var doubleValue: Double? {
        switch type {
        case .integer, .decimal:
            return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        case .empty, .boolean, .string:
            return nil
        }
    }

    /// The boolean value when this cell is `.boolean`, else `nil`.
    public var boolValue: Bool? {
        guard type == .boolean else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}
