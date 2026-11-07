import Foundation
import OhiaCore

public struct PDFDocumentIR: Codable, Sendable, Equatable {
    public let fileName: String
    public let pageCount: Int
    public let pages: [PDFPageIR]

    public init(fileName: String, pageCount: Int, pages: [PDFPageIR]) {
        self.fileName = fileName
        self.pageCount = max(0, pageCount)
        self.pages = pages
    }
}

public struct PDFPageIR: Codable, Sendable, Equatable {
    public let pageNumber: Int
    public let width: Double
    public let height: Double
    public let blocks: [PDFBlock]

    public init(pageNumber: Int, width: Double, height: Double, blocks: [PDFBlock]) {
        self.pageNumber = max(1, pageNumber)
        self.width = Self.finite(width)
        self.height = Self.finite(height)
        self.blocks = blocks.sorted { $0.order < $1.order }
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

public struct PDFBlock: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let blockType: PDFBlockType
    public let bbox: BoundingBox
    public let order: Int
    public let source: TextSource

    public init(
        id: String,
        text: String,
        blockType: PDFBlockType,
        bbox: BoundingBox,
        order: Int,
        source: TextSource
    ) {
        self.id = id
        self.text = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.blockType = blockType
        self.bbox = bbox
        self.order = max(0, order)
        self.source = source
    }

    public var isUseful: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum PDFBlockType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case title
    case heading
    case paragraph
    case table
    case tableRow
    case caption
    case listItem
    case header
    case footer
    case unknown
}

public enum TextSource: String, Codable, Sendable, Equatable, Hashable {
    case native
    case ocr
    case mixed
}

public struct BoundingBox: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = Self.finite(x)
        self.y = Self.finite(y)
        self.width = max(0, Self.finite(width))
        self.height = max(0, Self.finite(height))
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

public struct PDFRAGProjection: Sendable, Equatable {
    public let plainText: String
    public let embeddingText: String
    public let chunks: [AttachmentRAGChunk]
    public let ragDocument: AttachmentRAGDocument

    public init(
        plainText: String,
        embeddingText: String,
        chunks: [AttachmentRAGChunk],
        ragDocument: AttachmentRAGDocument
    ) {
        self.plainText = plainText
        self.embeddingText = embeddingText
        self.chunks = chunks
        self.ragDocument = ragDocument
    }
}

public enum PDFRAGNormalizer {
    public static let defaultChunkCharacterBudget = 3_200

    public static func normalize(
        _ ir: PDFDocumentIR,
        maxChunkCharacters: Int = defaultChunkCharacterBudget
    ) -> PDFRAGProjection {
        let filteredPages = ir.pages.map { page in
            let blocks = filteredBlocks(for: page, in: ir)
            return PDFPageIR(
                pageNumber: page.pageNumber,
                width: page.width,
                height: page.height,
                blocks: blocks
            )
        }

        var ragChunks: [AttachmentRAGChunk] = []
        for page in filteredPages {
            ragChunks.append(contentsOf: chunks(
                ir: ir,
                page: page,
                startIndex: ragChunks.count,
                maxChunkCharacters: max(600, maxChunkCharacters)
            ))
        }

        let plainText = filteredPages.compactMap { page -> String? in
            let text = page.blocks
                .map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return "--- Page \(page.pageNumber) ---\n\(text)"
        }.joined(separator: "\n\n")
        let embeddingText = ragChunks
            .map(\.embeddingText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n---\n\n")
        let ragDocument = AttachmentRAGDocument(
            fileName: ir.fileName,
            fileType: "pdf",
            plainText: plainText,
            embeddingText: embeddingText,
            chunks: ragChunks
        )
        return PDFRAGProjection(
            plainText: plainText,
            embeddingText: embeddingText.isEmpty ? plainText : embeddingText,
            chunks: ragChunks,
            ragDocument: ragDocument
        )
    }

    private static func filteredBlocks(for page: PDFPageIR, in ir: PDFDocumentIR) -> [PDFBlock] {
        let repeatedEdgeText = repeatedHeaderFooterTexts(in: ir)
        var seen = Set<String>()
        return page.blocks
            .filter(\.isUseful)
            .sorted { $0.order < $1.order }
            .filter { block in
                let normalized = normalizedText(block.text)
                guard !normalized.isEmpty else { return false }
                if isLikelyPageNumber(normalized) { return false }
                if repeatedEdgeText.contains(normalized), isNearVerticalEdge(block.bbox, page: page) {
                    return false
                }
                let key = "\(page.pageNumber):\(normalized)"
                return seen.insert(key).inserted
            }
    }

    private static func repeatedHeaderFooterTexts(in ir: PDFDocumentIR) -> Set<String> {
        var counts: [String: Set<Int>] = [:]
        for page in ir.pages {
            for block in page.blocks where block.isUseful && isNearVerticalEdge(block.bbox, page: page) {
                let normalized = normalizedText(block.text)
                guard !normalized.isEmpty, !isLikelyPageNumber(normalized) else { continue }
                counts[normalized, default: []].insert(page.pageNumber)
            }
        }
        let threshold = min(max(2, ir.pages.count / 2), max(2, ir.pages.count))
        return Set(counts.compactMap { text, pages in
            pages.count >= threshold ? text : nil
        })
    }

    private static func chunks(
        ir: PDFDocumentIR,
        page: PDFPageIR,
        startIndex: Int,
        maxChunkCharacters: Int
    ) -> [AttachmentRAGChunk] {
        guard !page.blocks.isEmpty else { return [] }
        var result: [AttachmentRAGChunk] = []
        var pending: [PDFBlock] = []

        func flush() {
            guard !pending.isEmpty else { return }
            result.append(chunk(
                ir: ir,
                page: page,
                blocks: pending,
                index: startIndex + result.count
            ))
            pending.removeAll()
        }

        for block in page.blocks {
            let currentLength = pending.reduce(0) { $0 + $1.text.count }
            let wouldOverflow = !pending.isEmpty && currentLength + block.text.count > maxChunkCharacters
            let startsNewSection = block.blockType == .title || block.blockType == .heading
            if wouldOverflow || startsNewSection {
                flush()
            }
            pending.append(block)
            if block.blockType == .table || block.blockType == .tableRow {
                continue
            }
        }
        flush()
        return result
    }

    private static func chunk(
        ir: PDFDocumentIR,
        page: PDFPageIR,
        blocks: [PDFBlock],
        index: Int
    ) -> AttachmentRAGChunk {
        let blockType = combinedBlockType(blocks)
        let source = combinedSource(blocks)
        let bbox = union(blocks.map(\.bbox))
        let sourceLocator = "Page \(page.pageNumber), \(blockType.rawValue)"
        let plainText = blocks.map(\.text).joined(separator: "\n")
        let title = blocks.first { $0.blockType == .title || $0.blockType == .heading }?.text
        let metadata = AttachmentRAGMetadata(
            sourceLocator: sourceLocator,
            pageNumber: page.pageNumber,
            pageWidth: page.width,
            pageHeight: page.height,
            boundingBox: bbox.map {
                AttachmentSourceBoundingBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            blockType: blockType.rawValue,
            textSource: source.rawValue,
            sourceOrderStart: blocks.map(\.order).min() ?? 0,
            sourceOrderEnd: blocks.map(\.order).max() ?? 0,
            chunkOrder: index
        )
        let embeddingText = renderEmbeddingText(
            fileName: ir.fileName,
            pageNumber: page.pageNumber,
            blockType: blockType,
            source: source,
            content: plainText
        )
        return AttachmentRAGChunk(
            id: "\(ir.fileName):pdf:\(index)",
            fileName: ir.fileName,
            fileType: "pdf",
            title: title,
            plainText: plainText,
            embeddingText: embeddingText,
            metadata: metadata
        )
    }

    private static func renderEmbeddingText(
        fileName: String,
        pageNumber: Int,
        blockType: PDFBlockType,
        source: TextSource,
        content: String
    ) -> String {
        [
            "File: \(fileName)",
            "Type: pdf",
            "Page: \(pageNumber)",
            "Region: \(blockType.rawValue)",
            "Text source: \(source.rawValue)",
            "Content:",
            content
        ].joined(separator: "\n")
    }

    private static func combinedBlockType(_ blocks: [PDFBlock]) -> PDFBlockType {
        let types = Set(blocks.map(\.blockType))
        if types.count == 1, let first = types.first { return first }
        if types.contains(.table) || types.contains(.tableRow) { return .table }
        if types.contains(.heading) { return .heading }
        if types.contains(.title) { return .title }
        if types.contains(.listItem) { return .listItem }
        return .paragraph
    }

    private static func combinedSource(_ blocks: [PDFBlock]) -> TextSource {
        let sources = Set(blocks.map(\.source))
        return sources.count == 1 ? (sources.first ?? .native) : .mixed
    }

    private static func union(_ boxes: [BoundingBox]) -> BoundingBox? {
        guard let first = boxes.first else { return nil }
        let minX = boxes.reduce(first.x) { min($0, $1.x) }
        let minY = boxes.reduce(first.y) { min($0, $1.y) }
        let maxX = boxes.reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = boxes.reduce(first.maxY) { max($0, $1.maxY) }
        return BoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func isNearVerticalEdge(_ box: BoundingBox, page: PDFPageIR) -> Bool {
        guard page.height > 0 else { return false }
        let topDistance = max(0, box.y)
        let bottomDistance = max(0, page.height - box.maxY)
        let threshold = max(24, page.height * 0.08)
        return topDistance <= threshold || bottomDistance <= threshold
    }

    private static func isLikelyPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(trimmed) != nil { return true }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("page ") else { return false }
        let rest = lower.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.allSatisfy { $0.isNumber || $0 == "/" || $0.isWhitespace }
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
