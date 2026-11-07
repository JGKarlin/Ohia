import Foundation
import OhiaCore

/// End-to-end extraction for delimited tabular attachments (CSV / TSV).
///
/// Produces three artifacts from one parse:
/// - `normalizedIRJSON`: a `TabularDocumentIR` preserving the *typed grid*
///   (header, per-column inferred types, per-cell raw + type) for a future
///   deterministic compute path.
/// - `ragDocumentJSON` / `embeddingText`: the retrieval projection, built by
///   running the table through the shared `OfficeRAGNormalizer` so CSV/TSV reach
///   parity with XLSX (header-aware, row-range chunked).
/// - `text`: a readable structured rendering for storage and summarization.
enum TabularExtractor {
    /// Upper bound on rows retained in the typed grid (and chunked for RAG).
    /// Generous enough for any realistic email attachment; bounds the serialized
    /// IR for pathological inputs. Overflow is surfaced via
    /// `TabularDocumentIR.isTruncated`, never silently dropped.
    static let maxPreservedRows = 50_000

    struct Extraction: Sendable, Equatable {
        let text: String
        let embeddingText: String?
        let normalizedIRJSON: String?
        let ragDocumentJSON: String?
        let structureUnitKind: String
        let structureUnitCount: Int
    }

    enum ExtractionError: Error, Equatable {
        case undecodable
        case empty
    }

    static func extract(
        data: Data,
        kind: DocumentKind,
        filename: String,
        maxRows: Int = maxPreservedRows
    ) throws -> Extraction {
        let format: TabularFormat = (kind == .tsv) ? .tsv : .csv

        let parsed: DelimitedTextParser.ParsedTable
        do {
            parsed = try DelimitedTextParser.parse(data: data, format: format)
        } catch DelimitedTextParser.ParseError.undecodable {
            throw ExtractionError.undecodable
        } catch DelimitedTextParser.ParseError.empty {
            throw ExtractionError.empty
        }

        let headerCells = parsed.rows.first ?? []
        let dataGrid = Array(parsed.rows.dropFirst())
        let columnCount = max(headerCells.count, dataGrid.map(\.count).max() ?? 0)
        guard columnCount > 0 else { throw ExtractionError.empty }

        let columnLabels = (0..<columnCount).map { index -> String in
            let raw = index < headerCells.count
                ? headerCells[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return raw.isEmpty ? "Column \(index + 1)" : raw
        }

        let totalDataRows = dataGrid.count
        let preserved = Array(dataGrid.prefix(max(0, maxRows)))
        let isTruncated = totalDataRows > preserved.count

        let tabularRows = preserved.enumerated().map { rowIndex, row in
            TabularRow(
                index: rowIndex,
                cells: (0..<columnCount).map { column in
                    let raw = column < row.count ? row[column] : ""
                    return TabularCell(column: column, raw: raw, type: TabularValueType.infer(raw))
                }
            )
        }

        let columns = (0..<columnCount).map { column in
            TabularColumn(
                index: column,
                name: columnLabels[column],
                inferredType: dominantType(column: column, rows: tabularRows)
            )
        }

        let tabularIR = TabularDocumentIR(
            fileName: filename,
            format: format,
            delimiter: String(parsed.delimiter),
            encoding: parsed.encoding,
            hasHeader: true,
            columns: columns,
            rowCount: totalDataRows,
            preservedRowCount: preserved.count,
            isTruncated: isTruncated,
            rows: tabularRows
        )

        // Retrieval projection: render the preserved grid into row-range blocks
        // and run the shared Office RAG normalizer (XLSX parity).
        let dataRows = preserved.enumerated().map { rowIndex, row in
            TabularRegionBuilder.DataRow(
                sheetRow: rowIndex + 2, // header occupies sheet row 1
                cells: (0..<columnCount).map { column in
                    TabularRegionBuilder.Cell(value: column < row.count ? row[column] : "")
                }
            )
        }
        let officeBlocks = TabularRegionBuilder.blocks(
            idPrefix: format.rawValue,
            unitName: nil,
            columnLabels: columnLabels,
            dataRows: dataRows,
            minColumn: 1,
            maxColumn: max(1, columnCount),
            headerSheetRow: 1,
            startOrder: 0
        )
        let officeIR = OfficeDocumentIR(
            fileName: filename,
            fileType: (format == .tsv) ? .tsv : .csv,
            documentProperties: DocumentProperties(),
            blocks: officeBlocks
        )
        let projection = OfficeRAGNormalizer.normalize(officeIR)

        let text = projection.plainText.isEmpty
            ? columnLabels.joined(separator: String(parsed.delimiter))
            : projection.plainText

        return Extraction(
            text: text,
            embeddingText: projection.embeddingText,
            normalizedIRJSON: jsonString(tabularIR),
            ragDocumentJSON: jsonString(projection.ragDocument),
            structureUnitKind: "row",
            structureUnitCount: totalDataRows
        )
    }

    /// Dominant non-empty value type across the preserved rows. A column whose
    /// non-empty cells are all numeric resolves to `.decimal` when it mixes
    /// integers and decimals; an ≥80%-consistent single type wins; otherwise
    /// `.string`.
    private static func dominantType(column: Int, rows: [TabularRow]) -> TabularValueType {
        var counts: [TabularValueType: Int] = [:]
        for row in rows where column < row.cells.count {
            let type = row.cells[column].type
            guard type != .empty else { continue }
            counts[type, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let top = counts.max(by: { $0.value < $1.value }) else { return .string }
        if Double(top.value) >= 0.8 * Double(total) { return top.key }
        let numeric = (counts[.integer] ?? 0) + (counts[.decimal] ?? 0)
        if numeric == total { return .decimal }
        return .string
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
