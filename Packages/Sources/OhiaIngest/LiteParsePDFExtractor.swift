import Foundation
import OSLog
import OhiaPDFParsing

private let pdfParserLogger = Logger(subsystem: "org.jgkarlin.Ohia", category: "PDFParser")

/// Turns a PDF into Ohia's document IR. The PDF is never opened in the
/// calling process: `OhiaPDFParser.xpc` (no network, no shared container)
/// parses it with the bundled LiteParse helper, or reads its text with PDFKit
/// when LiteParse fails, and only that JSON comes back to be decoded and
/// normalized here. The service is reached directly from the app and through
/// the app from the worker services (`PDFParserRoute`).
public struct LiteParsePDFExtractor: Sendable {
    public enum Engine: Sendable, Equatable {
        case liteParse
        /// The service's PDFKit fallback, after LiteParse failed.
        case pdfKit
    }

    public struct Extraction: Sendable, Equatable {
        public let text: String
        public let pageCount: Int
        public let parserVersion: String
        public let engine: Engine
        public let ir: PDFDocumentIR
        public let embeddingText: String?
        public let normalizedIRJSON: String?
        public let ragDocumentJSON: String?
    }

    public enum ExtractorError: LocalizedError, Equatable {
        case helperUnavailable
        case processFailed(status: Int32, stderr: String)
        case timedOut
        case tooLarge
        case invalidJSON
        case emptyText
        case cancelled
        /// PDFKit, reading after LiteParse failed, found the PDF locked.
        case encrypted(pageCount: Int)
        /// PDFKit, reading after LiteParse failed, found no text.
        case pdfKitEmptyText(pageCount: Int)

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return "The PDF parser service is not available in this process"
            case .processFailed(let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "LiteParse helper exited with status \(status)"
                    : "LiteParse helper exited with status \(status): \(detail)"
            case .timedOut:
                return "LiteParse helper timed out"
            case .tooLarge:
                return "The PDF or its extracted text exceeds the parser's size limit"
            case .invalidJSON:
                return "LiteParse helper did not produce valid JSON"
            case .emptyText:
                return "LiteParse helper produced no text"
            case .cancelled:
                return "The PDF parse was cancelled before it finished"
            case .encrypted:
                return "PDF is encrypted or password-protected"
            case .pdfKitEmptyText:
                return "PDFKit found no extractable text"
            }
        }
    }

    /// What the service sent back for a PDF it could read.
    public enum ServiceOutput: Sendable, Equatable {
        /// LiteParse's JSON.
        case liteParse(Data)
        /// A `PDFKitTextOutput` as JSON, read after LiteParse failed.
        case pdfKit(Data)
    }

    /// Sends PDF bytes to the service and returns its output, or throws an
    /// `ExtractorError`.
    public typealias Parse = @Sendable (_ pdf: Data, _ maxPages: Int) throws -> ServiceOutput

    public var parse: Parse?
    public var maxPages: Int

    public init(
        parse: Parse? = Self.isolatedParse(),
        maxPages: Int = PDFParserLimits.maxPages
    ) {
        self.parse = parse
        self.maxPages = min(max(1, maxPages), PDFParserLimits.maxPages)
    }

    /// The parse function backed by `OhiaPDFParser.xpc` through this process's
    /// `PDFParserRoute`. Nil in a process with no route (tests), where PDFs
    /// are then not parsed at all.
    public static func isolatedParse(bundle: Bundle = .main) -> Parse? {
        PDFParserRoute.current(bundle: bundle).map { parse(using: $0.parse) }
    }

    /// Wraps a service route as a `Parse`: failures and fallbacks are logged,
    /// and failures thrown as `ExtractorError`.
    static func parse(using request: @escaping @Sendable (_ pdf: Data, _ maxPages: Int) -> PDFParserReply) -> Parse {
        return { pdf, maxPages in
            let reply = request(pdf, maxPages)
            switch reply.outcome {
            case .parsed, .cancelled:
                break
            case .pdfKitText:
                pdfParserLogger.notice(
                    "LiteParse failed status=\(reply.status, privacy: .public); the parser service read the text with PDFKit"
                )
            default:
                // Record why nothing was parsed, so a broken service (signing,
                // sandbox, crash) is visible.
                pdfParserLogger.error(
                    "Isolated PDF parse failed outcome=\(String(describing: reply.outcome), privacy: .public) status=\(reply.status, privacy: .public)"
                )
            }
            return try output(of: reply)
        }
    }

    static func output(of reply: PDFParserReply) throws -> ServiceOutput {
        switch reply.outcome {
        case .parsed:
            guard let output = reply.output else { throw ExtractorError.invalidJSON }
            return .liteParse(output)
        case .pdfKitText:
            guard let output = reply.output else { throw ExtractorError.invalidJSON }
            return .pdfKit(output)
        case .helperUnavailable, .launchFailed, .serviceUnavailable:
            throw ExtractorError.helperUnavailable
        case .invalidRequest, .outputTooLarge:
            throw ExtractorError.tooLarge
        case .timedOut:
            throw ExtractorError.timedOut
        case .processFailed:
            throw ExtractorError.processFailed(status: reply.status, stderr: reply.stderr)
        case .cancelled:
            throw ExtractorError.cancelled
        }
    }

    public func extract(data: Data, filename: String = "attachment.pdf") throws -> Extraction {
        guard let parse else { throw ExtractorError.helperUnavailable }
        switch try parse(data, maxPages) {
        case .liteParse(let output):
            return try liteParseExtraction(output, filename: filename)
        case .pdfKit(let output):
            return try pdfKitExtraction(output, filename: filename)
        }
    }

    private func liteParseExtraction(_ outputData: Data, filename: String) throws -> Extraction {
        guard let parsed = try? JSONDecoder().decode(LiteParseJSON.self, from: outputData) else {
            throw ExtractorError.invalidJSON
        }
        let ir = LiteParsePDFNormalizer.documentIR(
            filename: filename,
            parsed: parsed
        )
        let projection = PDFRAGNormalizer.normalize(ir)
        var text = projection.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !text.isEmpty else { throw ExtractorError.emptyText }
        return Extraction(
            text: text,
            pageCount: max(ir.pageCount, ir.pages.count),
            parserVersion: "liteparse",
            engine: .liteParse,
            ir: ir,
            embeddingText: projection.embeddingText,
            normalizedIRJSON: Self.jsonString(ir),
            ragDocumentJSON: Self.jsonString(projection.ragDocument)
        )
    }

    /// One block per page, the page's whole text, as PDFKit gives no layout.
    private func pdfKitExtraction(_ outputData: Data, filename: String) throws -> Extraction {
        guard let output = try? JSONDecoder().decode(PDFKitTextOutput.self, from: outputData) else {
            throw ExtractorError.invalidJSON
        }
        let pageCount = max(output.pageCount, output.pages.count)
        if output.isLocked { throw ExtractorError.encrypted(pageCount: pageCount) }
        let pages = output.pages.enumerated().map { index, page -> PDFPageIR in
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFPageIR(
                pageNumber: index + 1,
                width: page.width,
                height: page.height,
                blocks: text.isEmpty ? [] : [
                    PDFBlock(
                        id: "\(filename):pdfkit:\(index + 1):0",
                        text: text,
                        blockType: .paragraph,
                        bbox: BoundingBox(x: 0, y: 0, width: page.width, height: page.height),
                        order: 0,
                        source: .native
                    )
                ]
            )
        }
        let ir = PDFDocumentIR(fileName: filename, pageCount: pageCount, pages: pages)
        let projection = PDFRAGNormalizer.normalize(ir)
        let text = projection.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractorError.pdfKitEmptyText(pageCount: pageCount) }
        return Extraction(
            text: text,
            pageCount: pageCount,
            parserVersion: "pdfkit",
            engine: .pdfKit,
            ir: ir,
            embeddingText: projection.embeddingText,
            normalizedIRJSON: Self.jsonString(ir),
            ragDocumentJSON: Self.jsonString(projection.ragDocument)
        )
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct LiteParseJSON: Decodable {
    struct TextItem: Decodable {
        let text: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        let fontName: String?
        let fontSize: Double?
        let confidence: Double?
        let source: String?
    }

    struct Page: Decodable {
        let pageNum: Int?
        let page: Int?
        let width: Double?
        let height: Double?
        let text: String?
        let textItems: [TextItem]?
    }

    let text: String?
    let pages: [Page]?
}

private enum LiteParsePDFNormalizer {
    static func documentIR(filename: String, parsed: LiteParseJSON) -> PDFDocumentIR {
        let pages = (parsed.pages ?? []).enumerated().map { index, page in
            pageIR(filename: filename, index: index, page: page)
        }
        if !pages.isEmpty {
            return PDFDocumentIR(fileName: filename, pageCount: pages.count, pages: pages)
        }
        let fallbackText = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackPage = PDFPageIR(
            pageNumber: 1,
            width: 0,
            height: 0,
            blocks: fallbackText.isEmpty ? [] : [
                PDFBlock(
                    id: "\(filename):pdf:1:0",
                    text: fallbackText,
                    blockType: .paragraph,
                    bbox: BoundingBox(x: 0, y: 0, width: 0, height: 0),
                    order: 0,
                    source: .native
                )
            ]
        )
        return PDFDocumentIR(fileName: filename, pageCount: fallbackText.isEmpty ? 0 : 1, pages: [fallbackPage])
    }

    private static func pageIR(filename: String, index: Int, page: LiteParseJSON.Page) -> PDFPageIR {
        let pageNumber = page.page ?? page.pageNum ?? index + 1
        let width = page.width ?? 0
        let height = page.height ?? 0
        let blocks = layoutBlocks(
            filename: filename,
            pageNumber: pageNumber,
            pageWidth: width,
            pageHeight: height,
            textItems: page.textItems ?? [],
            fallbackText: page.text
        )
        return PDFPageIR(
            pageNumber: pageNumber,
            width: width,
            height: height,
            blocks: blocks
        )
    }

    private static func layoutBlocks(
        filename: String,
        pageNumber: Int,
        pageWidth: Double,
        pageHeight: Double,
        textItems: [LiteParseJSON.TextItem],
        fallbackText: String?
    ) -> [PDFBlock] {
        let usefulItems = textItems.compactMap(LayoutItem.init(raw:))
        if usefulItems.isEmpty {
            return fallbackBlocks(
                filename: filename,
                pageNumber: pageNumber,
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                fallbackText: fallbackText
            )
        }

        let lines = lineGroups(from: usefulItems)
        let averageFontSize = usefulItems.map(\.fontSize).average
        return lines.enumerated().map { index, line in
            let text = line.items
                .sorted { $0.x < $1.x }
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFBlock(
                id: "\(filename):pdf:\(pageNumber):\(index)",
                text: text,
                blockType: blockType(
                    text: text,
                    items: line.items,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    averageFontSize: averageFontSize
                ),
                bbox: union(line.items.map(\.bbox)),
                order: index,
                source: combinedSource(line.items.map(\.source))
            )
        }
    }

    private static func fallbackBlocks(
        filename: String,
        pageNumber: Int,
        pageWidth: Double,
        pageHeight: Double,
        fallbackText: String?
    ) -> [PDFBlock] {
        let text = fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return [] }
        return [
            PDFBlock(
                id: "\(filename):pdf:\(pageNumber):0",
                text: text,
                blockType: .paragraph,
                bbox: BoundingBox(x: 0, y: 0, width: pageWidth, height: pageHeight),
                order: 0,
                source: .native
            )
        ]
    }

    private static func lineGroups(from items: [LayoutItem]) -> [LineGroup] {
        let sorted = items.sorted {
            if abs($0.y - $1.y) > max(2, min($0.height, $1.height) * 0.6) {
                return $0.y < $1.y
            }
            return $0.x < $1.x
        }
        var lines: [LineGroup] = []
        for item in sorted {
            if let index = lines.indices.last,
               lines[index].canAccept(item) {
                lines[index].items.append(item)
            } else {
                lines.append(LineGroup(items: [item]))
            }
        }
        return lines
    }

    private static func blockType(
        text: String,
        items: [LayoutItem],
        pageWidth: Double,
        pageHeight: Double,
        averageFontSize: Double
    ) -> PDFBlockType {
        let bbox = union(items.map(\.bbox))
        let lower = text.lowercased()
        if pageHeight > 0, bbox.y <= pageHeight * 0.08 { return .header }
        if pageHeight > 0, pageHeight - bbox.maxY <= pageHeight * 0.08 { return .footer }
        if lower.hasPrefix("figure ") || lower.hasPrefix("fig. ") || lower.hasPrefix("table ") {
            return .caption
        }
        if text.hasPrefix("•") || text.hasPrefix("- ") || text.hasPrefix("* ") {
            return .listItem
        }
        if let first = text.first, first.isNumber, text.drop(while: \.isNumber).hasPrefix(".") {
            return .listItem
        }
        if items.count >= 3, hasColumnLikeGaps(items: items, pageWidth: pageWidth) {
            return .tableRow
        }
        let maxFont = items.map(\.fontSize).max() ?? 0
        if maxFont > 0, averageFontSize > 0, maxFont >= averageFontSize + 3 {
            return bbox.y <= max(120, pageHeight * 0.25) ? .title : .heading
        }
        return .paragraph
    }

    private static func hasColumnLikeGaps(items: [LayoutItem], pageWidth: Double) -> Bool {
        guard items.count >= 3 else { return false }
        let sorted = items.sorted { $0.x < $1.x }
        let gaps = zip(sorted, sorted.dropFirst()).map { left, right in
            right.x - left.bbox.maxX
        }
        let threshold = max(18, pageWidth * 0.035)
        return gaps.filter { $0 >= threshold }.count >= 2
    }

    private static func union(_ boxes: [BoundingBox]) -> BoundingBox {
        guard let first = boxes.first else {
            return BoundingBox(x: 0, y: 0, width: 0, height: 0)
        }
        let minX = boxes.reduce(first.x) { min($0, $1.x) }
        let minY = boxes.reduce(first.y) { min($0, $1.y) }
        let maxX = boxes.reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = boxes.reduce(first.maxY) { max($0, $1.maxY) }
        return BoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func combinedSource(_ sources: [TextSource]) -> TextSource {
        let unique = Set(sources)
        return unique.count == 1 ? (unique.first ?? .native) : .mixed
    }

    private struct LayoutItem: Sendable, Equatable {
        let text: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let fontSize: Double
        let source: TextSource

        init?(raw: LiteParseJSON.TextItem) {
            let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            self.text = text
            self.x = raw.x ?? 0
            self.y = raw.y ?? 0
            self.width = raw.width ?? 0
            self.height = raw.height ?? 0
            self.fontSize = raw.fontSize ?? 0
            if let source = raw.source?.lowercased(), source.contains("ocr") {
                self.source = .ocr
            } else {
                self.source = .native
            }
        }

        var bbox: BoundingBox {
            BoundingBox(x: x, y: y, width: width, height: height)
        }
    }

    private struct LineGroup: Sendable, Equatable {
        var items: [LayoutItem]

        func canAccept(_ item: LayoutItem) -> Bool {
            guard let first = items.first else { return true }
            let tolerance = max(2, max(first.height, item.height) * 0.65)
            return abs(first.y - item.y) <= tolerance
        }
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
