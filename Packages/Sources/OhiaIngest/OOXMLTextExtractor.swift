import Foundation
import OhiaCore
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

enum OOXMLTextExtractor {
    struct Extraction: Sendable, Equatable {
        let text: String
        let embeddingText: String?
        let structureUnitKind: String
        let structureUnitCount: Int
        let ir: OfficeDocumentIR
        let ragChunks: [RAGChunk]
        let ragDocument: AttachmentRAGDocument
    }

    enum ExtractionError: LocalizedError {
        case invalidArchive
        case missingPrimaryDocument

        var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return "OOXML archive could not be opened"
            case .missingPrimaryDocument:
                return "OOXML archive did not contain a readable document payload"
            }
        }
    }

    static func extract(data: Data, kind: DocumentKind, filename: String) throws -> Extraction {
        try withArchive(data: data) { archive in
            switch kind {
            case .docx:
                return try extractDOCX(from: archive, filename: filename)
            case .xlsx:
                return try extractXLSX(from: archive, filename: filename)
            case .pptx:
                return try extractPPTX(from: archive, filename: filename)
            default:
                throw ExtractionError.missingPrimaryDocument
            }
        }
    }

    private static func withArchive<T>(data: Data, _ body: (Archive) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhiaOOXML-\(UUID().uuidString).zip")
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ExtractionError.invalidArchive
        }
        return try body(archive)
    }

    private static func extractDOCX(from archive: Archive, filename: String) throws -> Extraction {
        let paths = [
            "word/document.xml"
        ] + archive.map(\.path)
            .filter { path in
                path.hasPrefix("word/header")
                    || path.hasPrefix("word/footer")
                    || path == "word/footnotes.xml"
                    || path == "word/endnotes.xml"
            }
            .sorted()

        var sections: [String] = []
        var blocks: [OfficeBlock] = []
        var order = 0
        for path in paths {
            guard let xml = try readUTF8(path, from: archive) else { continue }
            let parsed = PlainOOXMLTextParser.parse(xml)
            guard !parsed.isEmpty else { continue }
            if path == "word/document.xml" {
                sections.append(parsed)
                let paragraphs = DOCXParagraphParser.parse(xml)
                let normalized = docxBlocks(
                    paragraphs: paragraphs,
                    startOrder: order,
                    path: []
                )
                blocks.append(contentsOf: normalized.blocks)
                order = normalized.nextOrder
            } else {
                sections.append("--- \(docxSectionName(for: path)) ---\n\(parsed)")
                blocks.append(OfficeBlock(
                    id: "docx-\(order)",
                    type: docxPartBlockType(for: path),
                    text: parsed,
                    order: order,
                    metadata: BlockMetadata(sectionPath: [docxSectionName(for: path)])
                ))
                order += 1
            }
        }

        let text = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.missingPrimaryDocument }
        let ir = OfficeDocumentIR(
            fileName: filename,
            fileType: .docx,
            documentProperties: try documentProperties(from: archive),
            blocks: blocks
        )
        let projection = OfficeRAGNormalizer.normalize(ir)
        return Extraction(
            text: text,
            embeddingText: projection.embeddingText,
            structureUnitKind: "section",
            structureUnitCount: max(1, sections.count),
            ir: ir,
            ragChunks: projection.chunks,
            ragDocument: projection.ragDocument
        )
    }

    private static func extractXLSX(from archive: Archive, filename: String) throws -> Extraction {
        let sharedStrings = try readUTF8("xl/sharedStrings.xml", from: archive)
            .map(SharedStringsParser.parse) ?? []
        let sheetNames = try workbookSheetNames(from: archive)
        let sheetPaths = worksheetPaths(from: archive, sheetNames: sheetNames)

        var renderedSheets: [String] = []
        var blocks: [OfficeBlock] = []
        var order = 0
        for (index, path) in sheetPaths.enumerated() {
            guard let xml = try readUTF8(path, from: archive) else { continue }
            let parsedSheet = WorksheetRowsParser.parseDetailed(xml, sharedStrings: sharedStrings)
            let rows = parsedSheet.rows.map(\.rendered)
            guard !rows.isEmpty else { continue }
            let name = sheetNames.indices.contains(index) ? sheetNames[index].name : "Sheet \(index + 1)"
            renderedSheets.append("--- Sheet: \(name) ---\n\(rows.joined(separator: "\n"))")
            // Row-range blocks instead of one block per sheet: a large sheet now
            // yields several bounded chunks rather than one unbounded blob.
            let sheetBlocks = tabularBlocks(
                idPrefix: "xlsx-\(index)",
                unitName: name,
                sheet: parsedSheet,
                startOrder: order
            )
            blocks.append(contentsOf: sheetBlocks)
            order += sheetBlocks.count
        }

        let text = renderedSheets.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.missingPrimaryDocument }
        let ir = OfficeDocumentIR(
            fileName: filename,
            fileType: .xlsx,
            documentProperties: try documentProperties(from: archive),
            blocks: blocks
        )
        let projection = OfficeRAGNormalizer.normalize(ir)
        return Extraction(
            text: text,
            embeddingText: projection.embeddingText,
            structureUnitKind: "sheet",
            structureUnitCount: renderedSheets.count,
            ir: ir,
            ragChunks: projection.chunks,
            ragDocument: projection.ragDocument
        )
    }

    private static func extractPPTX(from archive: Archive, filename: String) throws -> Extraction {
        let slidePaths = indexedPaths(in: archive, prefix: "ppt/slides/slide", suffix: ".xml")
        var renderedSlides: [String] = []
        var blocks: [OfficeBlock] = []

        for (orderIndex, item) in slidePaths.enumerated() {
            let slideNumber = item.number
            let path = item.path
            guard let slideXML = try readUTF8(path, from: archive) else { continue }
            let slideText = PlainOOXMLTextParser.parse(slideXML)
            let notesPath = "ppt/notesSlides/notesSlide\(slideNumber).xml"
            let notesText = try readUTF8(notesPath, from: archive)
                .map(PlainOOXMLTextParser.parse) ?? ""

            var parts: [String] = ["--- Slide \(slideNumber) ---"]
            if !slideText.isEmpty {
                parts.append(slideText)
            }
            if !notesText.isEmpty {
                parts.append("Notes:\n\(notesText)")
            }
            guard parts.count > 1 else { continue }
            renderedSlides.append(parts.joined(separator: "\n"))
            let title = slideText.components(separatedBy: .newlines).first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !slideText.isEmpty {
                blocks.append(OfficeBlock(
                    id: "pptx-slide-\(slideNumber)",
                    type: .slide,
                    text: slideText,
                    order: orderIndex * 2,
                    metadata: BlockMetadata(
                        slideNumber: slideNumber,
                        slideTitle: title
                    )
                ))
            }
            if !notesText.isEmpty {
                blocks.append(OfficeBlock(
                    id: "pptx-notes-\(slideNumber)",
                    type: .speakerNotes,
                    text: notesText,
                    order: orderIndex * 2 + 1,
                    metadata: BlockMetadata(
                        slideNumber: slideNumber,
                        slideTitle: title
                    )
                ))
            }
        }

        let text = renderedSlides.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.missingPrimaryDocument }
        let ir = OfficeDocumentIR(
            fileName: filename,
            fileType: .pptx,
            documentProperties: try documentProperties(from: archive),
            blocks: blocks
        )
        let projection = OfficeRAGNormalizer.normalize(ir)
        return Extraction(
            text: text,
            embeddingText: projection.embeddingText,
            structureUnitKind: "slide",
            structureUnitCount: renderedSlides.count,
            ir: ir,
            ragChunks: projection.chunks,
            ragDocument: projection.ragDocument
        )
    }

    private static func readUTF8(_ path: String, from archive: Archive) throws -> String? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func workbookSheetNames(from archive: Archive) throws -> [(name: String, relationshipID: String?)] {
        guard let xml = try readUTF8("xl/workbook.xml", from: archive) else { return [] }
        return WorkbookSheetsParser.parse(xml)
    }

    private static func worksheetPaths(
        from archive: Archive,
        sheetNames: [(name: String, relationshipID: String?)]
    ) -> [String] {
        let relationships = (try? readUTF8("xl/_rels/workbook.xml.rels", from: archive))
            .flatMap(RelationshipsParser.parse) ?? [:]
        let namedPaths = sheetNames.compactMap { sheet -> String? in
            guard let relationshipID = sheet.relationshipID,
                  let target = relationships[relationshipID] else {
                return nil
            }
            return normalizedWorkbookTarget(target)
        }
        if !namedPaths.isEmpty { return namedPaths }
        return indexedPaths(in: archive, prefix: "xl/worksheets/sheet", suffix: ".xml").map(\.path)
    }

    private static func normalizedWorkbookTarget(_ target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        if target.hasPrefix("xl/") {
            return target
        }
        return "xl/" + target
    }

    private static func indexedPaths(in archive: Archive, prefix: String, suffix: String) -> [(number: Int, path: String)] {
        archive.map(\.path)
            .compactMap { path -> (number: Int, path: String)? in
                guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
                let numberText = path
                    .dropFirst(prefix.count)
                    .dropLast(suffix.count)
                guard let number = Int(numberText) else { return nil }
                return (number, path)
            }
            .sorted { $0.number < $1.number }
    }

    private static func docxSectionName(for path: String) -> String {
        if path.hasPrefix("word/header") { return "Header" }
        if path.hasPrefix("word/footer") { return "Footer" }
        if path == "word/footnotes.xml" { return "Footnotes" }
        if path == "word/endnotes.xml" { return "Endnotes" }
        return path
    }

    private static func docxPartBlockType(for path: String) -> BlockType {
        if path == "word/footnotes.xml" { return .footnote }
        if path == "word/endnotes.xml" { return .endnote }
        return .paragraph
    }

    private static func docxBlocks(
        paragraphs: [DOCXParagraphParser.Paragraph],
        startOrder: Int,
        path: [String]
    ) -> (blocks: [OfficeBlock], nextOrder: Int) {
        var sectionPath = path
        var order = startOrder
        var blocks: [OfficeBlock] = []
        for paragraph in paragraphs {
            let cleanText = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            let headingLevel = headingLevel(forStyle: paragraph.style)
            let type: BlockType
            if let headingLevel {
                type = .heading
                let index = max(0, headingLevel - 1)
                if sectionPath.count > index {
                    sectionPath = Array(sectionPath.prefix(index))
                }
                sectionPath.append(cleanText)
            } else if isListStyle(paragraph.style) || isListText(cleanText) {
                type = .listItem
            } else if paragraph.hyperlinkURL != nil {
                type = .hyperlink
            } else {
                type = .paragraph
            }
            blocks.append(OfficeBlock(
                id: "docx-\(order)",
                type: type,
                text: cleanText,
                order: order,
                metadata: BlockMetadata(
                    sectionPath: sectionPath,
                    hyperlinkURL: paragraph.hyperlinkURL
                )
            ))
            order += 1
        }
        return (blocks, order)
    }

    private static func headingLevel(forStyle style: String?) -> Int? {
        guard let normalized = style?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.contains("heading") || normalized.hasPrefix("h") else {
            return nil
        }
        let digits = normalized.filter(\.isNumber)
        guard let level = Int(String(digits)), (1...9).contains(level) else {
            return 1
        }
        return level
    }

    private static func isListStyle(_ style: String?) -> Bool {
        let normalized = style?.lowercased() ?? ""
        return normalized.contains("list") || normalized.contains("bullet")
    }

    private static func isListText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("•") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return true
        }
        guard let first = trimmed.first, first.isNumber else { return false }
        return trimmed.drop(while: \.isNumber).hasPrefix(".")
    }

    /// Convert a parsed worksheet into row-range `.worksheetRegion` blocks. The
    /// first parsed row is the header (column labels); remaining rows are data,
    /// each tagged with its sheet row number so `cellRange`s line up. Column
    /// span comes from the actual used columns so a sheet starting beyond
    /// column A keeps an accurate range.
    private static func tabularBlocks(
        idPrefix: String,
        unitName: String?,
        sheet: WorksheetRowsParser.Sheet,
        startOrder: Int
    ) -> [OfficeBlock] {
        guard let headerRow = sheet.rows.first else { return [] }
        let columnLabels = headerRow.cells.map(\.value)
        let dataRows = sheet.rows.dropFirst().enumerated().map { offset, row in
            TabularRegionBuilder.DataRow(
                sheetRow: row.number ?? (offset + 2),
                cells: row.cells.map { TabularRegionBuilder.Cell(value: $0.value, formula: $0.formula) }
            )
        }
        let columns = sheet.rows.flatMap(\.cells).compactMap(\.column)
        let minColumn = columns.min() ?? 1
        let maxColumn = columns.max() ?? max(1, columnLabels.count)
        return TabularRegionBuilder.blocks(
            idPrefix: idPrefix,
            unitName: unitName,
            columnLabels: columnLabels,
            dataRows: Array(dataRows),
            minColumn: minColumn,
            maxColumn: maxColumn,
            headerSheetRow: headerRow.number ?? 1,
            startOrder: startOrder
        )
    }

    private static func documentProperties(from archive: Archive) throws -> DocumentProperties {
        let core = try readUTF8("docProps/core.xml", from: archive)
            .map(CorePropertiesParser.parse)
        return core ?? DocumentProperties()
    }
}

private final class CorePropertiesParser: NSObject, XMLParserDelegate {
    private var currentElement: String?
    private var currentText = ""
    private var values: [String: String] = [:]

    static func parse(_ xml: String) -> DocumentProperties {
        let parserDelegate = CorePropertiesParser()
        guard let data = xml.data(using: .utf8) else { return DocumentProperties() }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return DocumentProperties(
            title: parserDelegate.values["title"],
            author: parserDelegate.values["creator"],
            subject: parserDelegate.values["subject"],
            createdAt: parserDelegate.values["created"],
            modifiedAt: parserDelegate.values["modified"]
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        switch name {
        case "title", "creator", "subject", "created", "modified":
            currentElement = name
            currentText = ""
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        guard currentElement == name else { return }
        values[name] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentElement = nil
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        currentText.append(string)
    }
}

private final class DOCXParagraphParser: NSObject, XMLParserDelegate {
    struct Paragraph: Sendable, Equatable {
        let text: String
        let style: String?
        let hyperlinkURL: String?
    }

    private var paragraphs: [Paragraph] = []
    private var paragraphDepth = 0
    private var inText = false
    private var currentText = ""
    private var currentStyle: String?
    private var currentHyperlinkURL: String?

    static func parse(_ xml: String) -> [Paragraph] {
        let parserDelegate = DOCXParagraphParser()
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.paragraphs
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "p":
            paragraphDepth += 1
            if paragraphDepth == 1 {
                currentText = ""
                currentStyle = nil
                currentHyperlinkURL = nil
            }
        case "pStyle":
            if paragraphDepth > 0 {
                currentStyle = attributeDict["w:val"] ?? attributeDict["val"]
            }
        case "hyperlink":
            if paragraphDepth > 0 {
                currentHyperlinkURL = attributeDict["r:id"] ?? attributeDict["id"] ?? attributeDict["anchor"]
            }
        case "t":
            if paragraphDepth > 0 { inText = true }
        case "tab":
            if paragraphDepth > 0 { currentText.append("\t") }
        case "br":
            if paragraphDepth > 0 { appendNewline() }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "t":
            inText = false
        case "p":
            paragraphDepth = max(0, paragraphDepth - 1)
            if paragraphDepth == 0 {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    paragraphs.append(Paragraph(
                        text: text,
                        style: currentStyle,
                        hyperlinkURL: currentHyperlinkURL
                    ))
                }
                currentText = ""
                currentStyle = nil
                currentHyperlinkURL = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        currentText.append(string)
    }

    private func appendNewline() {
        guard !currentText.hasSuffix("\n") else { return }
        currentText.append("\n")
    }
}

private final class PlainOOXMLTextParser: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var inText = false

    static func parse(_ xml: String) -> String {
        let parserDelegate = PlainOOXMLTextParser()
        guard let data = xml.data(using: .utf8) else { return "" }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.buffer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "t":
            inText = true
        case "tab":
            buffer.append("\t")
        case "br":
            appendNewline()
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "t":
            inText = false
        case "p":
            appendNewline()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        buffer.append(string)
    }

    private func appendNewline() {
        guard !buffer.hasSuffix("\n") else { return }
        buffer.append("\n")
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ xml: String) -> [String] {
        let parserDelegate = SharedStringsParser()
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "si":
            current = ""
        case "t":
            inText = true
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "t":
            inText = false
        case "si":
            strings.append(current)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        current.append(string)
    }
}

private final class WorkbookSheetsParser: NSObject, XMLParserDelegate {
    private var sheets: [(name: String, relationshipID: String?)] = []

    static func parse(_ xml: String) -> [(name: String, relationshipID: String?)] {
        let parserDelegate = WorkbookSheetsParser()
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.sheets
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "sheet" else { return }
        let name = attributeDict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relationshipID = attributeDict["r:id"] ?? attributeDict["id"]
        sheets.append((name?.isEmpty == false ? name! : "Sheet \(sheets.count + 1)", relationshipID))
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    static func parse(_ xml: String) -> [String: String] {
        let parserDelegate = RelationshipsParser()
        guard let data = xml.data(using: .utf8) else { return [:] }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.relationships
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else {
            return
        }
        relationships[id] = target
    }
}

private final class WorksheetRowsParser: NSObject, XMLParserDelegate {
    struct Cell: Sendable, Equatable {
        let reference: String
        let row: Int?
        let column: Int?
        let value: String
        let formula: String?
    }

    struct Row: Sendable, Equatable {
        let number: Int?
        let cells: [Cell]

        var rendered: String {
            cells.map(\.value).filter { !$0.isEmpty }.joined(separator: "\t")
        }
    }

    struct Sheet: Sendable, Equatable {
        let rows: [Row]
    }

    private let sharedStrings: [String]
    private var rows: [Row] = []
    private var currentRowNumber: Int?
    private var currentRow: [Cell] = []
    private var currentCellReference: String?
    private var currentType: String?
    private var currentValue = ""
    private var currentFormula = ""
    private var inValue = false
    private var inFormula = false
    private var inInlineStringText = false
    private var insideCell = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(_ xml: String, sharedStrings: [String]) -> [String] {
        parseDetailed(xml, sharedStrings: sharedStrings).rows.map(\.rendered)
    }

    static func parseDetailed(_ xml: String, sharedStrings: [String]) -> Sheet {
        let parserDelegate = WorksheetRowsParser(sharedStrings: sharedStrings)
        guard let data = xml.data(using: .utf8) else { return Sheet(rows: []) }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return Sheet(rows: parserDelegate.rows)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "row":
            currentRowNumber = attributeDict["r"].flatMap(Int.init)
            currentRow = []
        case "c":
            insideCell = true
            currentCellReference = attributeDict["r"]
            currentType = attributeDict["t"]
            currentValue = ""
            currentFormula = ""
        case "f":
            if insideCell { inFormula = true }
        case "v":
            if insideCell { inValue = true }
        case "t":
            if insideCell, currentType == "inlineStr" {
                inInlineStringText = true
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "f":
            inFormula = false
        case "v":
            inValue = false
        case "t":
            inInlineStringText = false
        case "c":
            let value = decodedCellValue()
            let reference = currentCellReference ?? ""
            let coordinate = Self.coordinate(reference: reference)
            if !value.isEmpty || !currentFormula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentRow.append(Cell(
                    reference: reference,
                    row: coordinate?.row ?? currentRowNumber,
                    column: coordinate?.column,
                    value: value,
                    formula: currentFormula.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ))
            }
            insideCell = false
            currentType = nil
            currentCellReference = nil
            currentValue = ""
            currentFormula = ""
        case "row":
            if !currentRow.isEmpty {
                rows.append(Row(number: currentRowNumber, cells: currentRow))
            }
            currentRow = []
            currentRowNumber = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFormula {
            currentFormula.append(string)
        } else if inValue || inInlineStringText {
            currentValue.append(string)
        }
    }

    private func decodedCellValue() -> String {
        let raw = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if currentType == "s",
           let index = Int(raw),
           sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        return raw
    }

    private static func coordinate(reference: String) -> (column: Int, row: Int)? {
        let letters = reference.prefix { $0.isLetter }
        let numbers = reference.drop { $0.isLetter }
        guard !letters.isEmpty, let row = Int(numbers) else { return nil }
        var column = 0
        for scalar in String(letters).uppercased().unicodeScalars {
            let lower = UnicodeScalar("A").value
            let upper = UnicodeScalar("Z").value
            guard (lower...upper).contains(scalar.value) else {
                return nil
            }
            let value = Int(scalar.value - lower + 1)
            column = column * 26 + value
        }
        return (column, row)
    }

}

private func localName(_ elementName: String) -> String {
    elementName.split(separator: ":").last.map(String.init) ?? elementName
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
