import Foundation
import OhiaCore

/// Builds row-range `.worksheetRegion` blocks for a single tabular unit — one
/// XLSX sheet or one whole CSV/TSV table. Splitting a table into ordered
/// row-range regions under a character budget is the shared behavior behind two
/// goals: giving CSV/TSV the same chunked RAG projection XLSX gets, and fixing
/// XLSX's previous habit of emitting one unbounded chunk per sheet (a 100k-row
/// sheet became a single multi-megabyte embedding).
///
/// Each region repeats the `Columns:` header line so every chunk is
/// self-describing for retrieval, and carries an A1-style `cellRange` so the
/// chunk can be located back in the source.
enum TabularRegionBuilder {
    /// Default per-region character budget. Matched to
    /// `OfficeRAGNormalizer.defaultChunkCharacterBudget` so one region maps to
    /// roughly one downstream chunk.
    static let defaultRegionCharacterBudget = 3_600

    /// A rendering cell: its display value plus an optional formula annotation
    /// (XLSX cells carry formulas; CSV cells never do).
    struct Cell: Sendable, Equatable {
        let value: String
        let formula: String?

        init(value: String, formula: String? = nil) {
            self.value = value
            self.formula = formula
        }
    }

    /// One data row (header excluded) tagged with its 1-based sheet row number
    /// so emitted `cellRange`s line up with the source.
    struct DataRow: Sendable, Equatable {
        let sheetRow: Int
        let cells: [Cell]

        init(sheetRow: Int, cells: [Cell]) {
            self.sheetRow = sheetRow
            self.cells = cells
        }
    }

    static func blocks(
        idPrefix: String,
        unitName: String?,
        columnLabels: [String],
        dataRows: [DataRow],
        minColumn: Int,
        maxColumn: Int,
        headerSheetRow: Int,
        startOrder: Int,
        regionCharacterBudget: Int = defaultRegionCharacterBudget
    ) -> [OfficeBlock] {
        let budget = max(600, regionCharacterBudget)
        let headerLine = "Columns: " + columnLabels.joined(separator: " | ")
        let resolvedMinColumn = max(1, min(minColumn, maxColumn))
        let resolvedMaxColumn = max(resolvedMinColumn, maxColumn)

        // Header-only table: still worth one descriptive block.
        guard !dataRows.isEmpty else {
            let range = cellRange(
                firstRow: headerSheetRow,
                lastRow: headerSheetRow,
                minColumn: resolvedMinColumn,
                maxColumn: resolvedMaxColumn
            )
            return [
                block(
                    id: "\(idPrefix):0",
                    order: startOrder,
                    text: headerLine,
                    unitName: unitName,
                    cellRange: range
                )
            ]
        }

        var blocks: [OfficeBlock] = []
        var current: [DataRow] = []
        var currentLength = headerLine.count

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let lines = [headerLine] + current.map { renderRow($0, columnLabels: columnLabels) }
            let regionIndex = blocks.count
            // The first region owns the header row; later regions span only their
            // own data rows.
            let firstRow = regionIndex == 0 ? min(headerSheetRow, first.sheetRow) : first.sheetRow
            let range = cellRange(
                firstRow: firstRow,
                lastRow: last.sheetRow,
                minColumn: resolvedMinColumn,
                maxColumn: resolvedMaxColumn
            )
            blocks.append(
                block(
                    id: "\(idPrefix):\(regionIndex)",
                    order: startOrder + regionIndex,
                    text: lines.joined(separator: "\n"),
                    unitName: unitName,
                    cellRange: range
                )
            )
            current = []
            currentLength = headerLine.count
        }

        for row in dataRows {
            let lineLength = renderRow(row, columnLabels: columnLabels).count + 1
            if !current.isEmpty, currentLength + lineLength > budget {
                flush()
            }
            current.append(row)
            currentLength += lineLength
        }
        flush()
        return blocks
    }

    private static func block(
        id: String,
        order: Int,
        text: String,
        unitName: String?,
        cellRange: String
    ) -> OfficeBlock {
        OfficeBlock(
            id: id,
            type: .worksheetRegion,
            text: text,
            order: order,
            metadata: BlockMetadata(sheetName: unitName, cellRange: cellRange)
        )
    }

    private static func renderRow(_ row: DataRow, columnLabels: [String]) -> String {
        let label = row.cells.first?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowLabel = (label?.isEmpty == false ? label : nil) ?? "Row \(row.sheetRow)"
        let parts = row.cells.enumerated().map { index, cell -> String in
            let columnLabel = index < columnLabels.count ? columnLabels[index] : "Column \(index + 1)"
            let formula = cell.formula.map { " formula=\($0)" } ?? ""
            return "\(columnLabel): \(cell.value)\(formula)"
        }
        return "Row: \(rowLabel) | " + parts.joined(separator: " | ")
    }

    static func cellRange(firstRow: Int, lastRow: Int, minColumn: Int, maxColumn: Int) -> String {
        "\(columnName(minColumn))\(firstRow):\(columnName(maxColumn))\(lastRow)"
    }

    /// 1-based column index to spreadsheet column letters (1 → A, 27 → AA).
    static func columnName(_ column: Int) -> String {
        var value = max(1, column)
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            let scalar = UnicodeScalar(Int(UnicodeScalar("A").value) + remainder)!
            result.insert(Character(scalar), at: result.startIndex)
            value = (value - 1) / 26
        }
        return result
    }
}
