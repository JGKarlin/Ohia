import Foundation

public struct LiteParsePDFExtractor: Sendable {
    public struct Extraction: Sendable, Equatable {
        public let text: String
        public let pageCount: Int
        public let parserVersion: String
        public let ir: PDFDocumentIR
        public let embeddingText: String?
        public let normalizedIRJSON: String?
        public let ragDocumentJSON: String?
    }

    public struct Command: Sendable, Equatable {
        public let executableURL: URL
        public let baseArguments: [String]

        public init(executableURL: URL, baseArguments: [String] = []) {
            self.executableURL = executableURL
            self.baseArguments = baseArguments
        }
    }

    public enum ExtractorError: LocalizedError, Equatable {
        case helperUnavailable
        case processFailed(status: Int32, stderr: String)
        case timedOut
        case invalidJSON
        case emptyText

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return "LiteParse helper is not bundled or configured"
            case .processFailed(let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "LiteParse helper exited with status \(status)"
                    : "LiteParse helper exited with status \(status): \(detail)"
            case .timedOut:
                return "LiteParse helper timed out"
            case .invalidJSON:
                return "LiteParse helper did not produce valid JSON"
            case .emptyText:
                return "LiteParse helper produced no text"
            }
        }
    }

    public var command: Command?
    public var timeout: TimeInterval
    public var maxPages: Int
    public var runProcess: @Sendable (Command, URL, URL, Int, TimeInterval) throws -> ProcessResult

    public init(
        command: Command? = Self.defaultCommand(),
        timeout: TimeInterval = 45,
        maxPages: Int = 1000,
        runProcess: @escaping @Sendable (Command, URL, URL, Int, TimeInterval) throws -> ProcessResult = Self.runLiteParseProcess
    ) {
        self.command = command
        self.timeout = timeout
        self.maxPages = max(1, maxPages)
        self.runProcess = runProcess
    }

    public func extract(data: Data, filename: String = "attachment.pdf") throws -> Extraction {
        guard let command else { throw ExtractorError.helperUnavailable }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhiaLiteParse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.pdf")
        let outputURL = directory.appendingPathComponent("output.json")
        try data.write(to: inputURL, options: [.atomic])

        let result = try runProcess(command, inputURL, outputURL, maxPages, timeout)
        guard result.status == 0 else {
            throw ExtractorError.processFailed(status: result.status, stderr: result.stderr)
        }
        let outputData = try Data(contentsOf: outputURL)
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
            ir: ir,
            embeddingText: projection.embeddingText,
            normalizedIRJSON: Self.jsonString(ir),
            ragDocumentJSON: Self.jsonString(projection.ragDocument)
        )
    }

    public static func defaultCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Command? {
        if let override = environment["OHIA_LITEPARSE_HELPER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return Command(executableURL: URL(fileURLWithPath: override))
        }

        if let direct = bundledExecutable(named: "lit", bundle: bundle) {
            return Command(executableURL: direct)
        }
        if let direct = bundledExecutable(named: "liteparse", bundle: bundle) {
            return Command(executableURL: direct)
        }
        for root in ["LiteParseHelper", "Resources/LiteParseHelper"] {
            if let node = bundle.url(
                forResource: "node",
                withExtension: nil,
                subdirectory: "\(root)/node/bin"
            ),
               let cli = bundledNodeCLI(root: root, bundle: bundle) {
                return Command(executableURL: node, baseArguments: [cli.path])
            }
        }
        return nil
    }

    private static func bundledExecutable(named name: String, bundle: Bundle) -> URL? {
        let subdirectories = [
            "LiteParseHelper",
            "LiteParseHelper/bin",
            "Resources/LiteParseHelper",
            "Resources/LiteParseHelper/bin"
        ]
        for subdirectory in subdirectories {
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    private static func bundledNodeCLI(root: String, bundle: Bundle) -> URL? {
        let candidates = [
            (name: "cli", subdirectory: "\(root)/node_modules/@llamaindex/liteparse/dist"),
            (name: "index", subdirectory: "\(root)/node_modules/@llamaindex/liteparse/dist/src")
        ]
        for candidate in candidates {
            if let url = bundle.url(
                forResource: candidate.name,
                withExtension: "js",
                subdirectory: candidate.subdirectory
            ) {
                return url
            }
        }
        return nil
    }

    public static func runLiteParseProcess(
        command: Command,
        inputURL: URL,
        outputURL: URL,
        maxPages: Int,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let stderrURL = outputURL.deletingLastPathComponent().appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.baseArguments + [
            "parse",
            inputURL.path,
            "--format",
            "json",
            "--no-ocr",
            "--max-pages",
            "\(maxPages)",
            "-o",
            outputURL.path
        ]
        process.standardError = stderrHandle

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        try process.run()
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ExtractorError.timedOut
        }
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return ProcessResult(status: process.terminationStatus, stderr: stderr)
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stderr: String

    public init(status: Int32, stderr: String = "") {
        self.status = status
        self.stderr = stderr
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
