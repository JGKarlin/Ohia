import Foundation
import OhiaCore

public struct DocumentProperties: Codable, Sendable, Equatable {
    public let title: String?
    public let author: String?
    public let subject: String?
    public let createdAt: String?
    public let modifiedAt: String?

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        createdAt: String? = nil,
        modifiedAt: String? = nil
    ) {
        self.title = Self.clean(title)
        self.author = Self.clean(author)
        self.subject = Self.clean(subject)
        self.createdAt = Self.clean(createdAt)
        self.modifiedAt = Self.clean(modifiedAt)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public struct OfficeDocumentIR: Codable, Sendable, Equatable {
    public let fileName: String
    public let fileType: OfficeFileType
    public let documentProperties: DocumentProperties
    public let blocks: [OfficeBlock]

    public init(
        fileName: String,
        fileType: OfficeFileType,
        documentProperties: DocumentProperties = DocumentProperties(),
        blocks: [OfficeBlock]
    ) {
        self.fileName = fileName
        self.fileType = fileType
        self.documentProperties = documentProperties
        self.blocks = blocks
    }
}

public enum OfficeFileType: String, Codable, Sendable, Equatable {
    case docx
    case xlsx
    case pptx
    case csv
    case tsv
}

public struct OfficeBlock: Codable, Sendable, Equatable {
    public let id: String
    public let type: BlockType
    public let text: String
    public let order: Int
    public let metadata: BlockMetadata

    public init(
        id: String,
        type: BlockType,
        text: String,
        order: Int,
        metadata: BlockMetadata = BlockMetadata()
    ) {
        self.id = id
        self.type = type
        self.text = Self.clean(text)
        self.order = order
        self.metadata = metadata
    }

    public var isUseful: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public enum BlockType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case heading
    case paragraph
    case listItem
    case table
    case tableRow
    case tableCell
    case footnote
    case endnote
    case comment
    case hyperlink
    case slide
    case speakerNotes
    case worksheetRegion
    case formula
    case imageAltText
}

public struct BlockMetadata: Codable, Sendable, Equatable {
    public let sectionPath: [String]
    public let slideNumber: Int?
    public let slideTitle: String?
    public let sheetName: String?
    public let cellRange: String?
    public let tableName: String?
    public let rowLabel: String?
    public let columnLabel: String?
    public let hyperlinkURL: String?
    public let commentAuthor: String?
    public let formula: String?
    public let cachedValue: String?
    public let isHidden: Bool?
    public let isMerged: Bool?

    public init(
        sectionPath: [String] = [],
        slideNumber: Int? = nil,
        slideTitle: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        tableName: String? = nil,
        rowLabel: String? = nil,
        columnLabel: String? = nil,
        hyperlinkURL: String? = nil,
        commentAuthor: String? = nil,
        formula: String? = nil,
        cachedValue: String? = nil,
        isHidden: Bool? = nil,
        isMerged: Bool? = nil
    ) {
        self.sectionPath = sectionPath.map(Self.clean).filter { !$0.isEmpty }
        self.slideNumber = slideNumber
        self.slideTitle = Self.clean(slideTitle).nilIfEmpty
        self.sheetName = Self.clean(sheetName).nilIfEmpty
        self.cellRange = Self.clean(cellRange).nilIfEmpty
        self.tableName = Self.clean(tableName).nilIfEmpty
        self.rowLabel = Self.clean(rowLabel).nilIfEmpty
        self.columnLabel = Self.clean(columnLabel).nilIfEmpty
        self.hyperlinkURL = Self.clean(hyperlinkURL).nilIfEmpty
        self.commentAuthor = Self.clean(commentAuthor).nilIfEmpty
        self.formula = Self.clean(formula).nilIfEmpty
        self.cachedValue = Self.clean(cachedValue).nilIfEmpty
        self.isHidden = isHidden
        self.isMerged = isMerged
    }

    public func replacingSectionPath(_ sectionPath: [String]) -> BlockMetadata {
        BlockMetadata(
            sectionPath: sectionPath,
            slideNumber: slideNumber,
            slideTitle: slideTitle,
            sheetName: sheetName,
            cellRange: cellRange,
            tableName: tableName,
            rowLabel: rowLabel,
            columnLabel: columnLabel,
            hyperlinkURL: hyperlinkURL,
            commentAuthor: commentAuthor,
            formula: formula,
            cachedValue: cachedValue,
            isHidden: isHidden,
            isMerged: isMerged
        )
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct RAGChunk: Codable, Sendable, Equatable {
    public let id: String
    public let fileName: String
    public let fileType: OfficeFileType
    public let title: String?
    public let sourceLocator: String
    public let plainText: String
    public let embeddingText: String
    public let metadata: ChunkMetadata

    public init(
        id: String,
        fileName: String,
        fileType: OfficeFileType,
        title: String?,
        sourceLocator: String,
        plainText: String,
        embeddingText: String,
        metadata: ChunkMetadata
    ) {
        self.id = id
        self.fileName = fileName
        self.fileType = fileType
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sourceLocator = sourceLocator
        self.plainText = plainText
        self.embeddingText = embeddingText
        self.metadata = metadata
    }
}

public struct ChunkMetadata: Codable, Sendable, Equatable {
    public let sectionPath: [String]
    public let slideNumber: Int?
    public let sheetName: String?
    public let cellRange: String?
    public let blockTypes: [BlockType]
    public let sourceOrderStart: Int
    public let sourceOrderEnd: Int

    public init(
        sectionPath: [String] = [],
        slideNumber: Int? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        blockTypes: [BlockType],
        sourceOrderStart: Int,
        sourceOrderEnd: Int
    ) {
        self.sectionPath = sectionPath
        self.slideNumber = slideNumber
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.blockTypes = blockTypes
        self.sourceOrderStart = sourceOrderStart
        self.sourceOrderEnd = sourceOrderEnd
    }
}

public struct OfficeRAGProjection: Sendable, Equatable {
    public let plainText: String
    public let embeddingText: String
    public let chunks: [RAGChunk]
    public let ragDocument: AttachmentRAGDocument

    public init(
        plainText: String,
        embeddingText: String,
        chunks: [RAGChunk],
        ragDocument: AttachmentRAGDocument
    ) {
        self.plainText = plainText
        self.embeddingText = embeddingText
        self.chunks = chunks
        self.ragDocument = ragDocument
    }
}

public enum OfficeRAGNormalizer {
    public static let defaultChunkCharacterBudget = 3_600

    public static func normalize(
        _ ir: OfficeDocumentIR,
        maxChunkCharacters: Int = defaultChunkCharacterBudget
    ) -> OfficeRAGProjection {
        let chunks: [RAGChunk]
        switch ir.fileType {
        case .docx:
            chunks = DOCXNormalizer.chunks(ir: ir, maxChunkCharacters: max(600, maxChunkCharacters))
        case .xlsx, .csv, .tsv:
            chunks = TabularNormalizer.chunks(ir: ir)
        case .pptx:
            chunks = PPTXNormalizer.chunks(ir: ir)
        }
        let plainText = chunks
            .map(\.plainText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let embeddingText = chunks
            .map(\.embeddingText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n---\n\n")
        let ragDocument = AttachmentRAGDocument(
            fileName: ir.fileName,
            fileType: ir.fileType.rawValue,
            plainText: plainText,
            embeddingText: embeddingText.isEmpty ? plainText : embeddingText,
            chunks: chunks.enumerated().map { index, chunk in
                AttachmentRAGChunk(
                    id: chunk.id,
                    fileName: chunk.fileName,
                    fileType: chunk.fileType.rawValue,
                    title: chunk.title,
                    plainText: chunk.plainText,
                    embeddingText: chunk.embeddingText,
                    metadata: AttachmentRAGMetadata(
                        sourceLocator: chunk.sourceLocator,
                        blockType: chunk.metadata.blockTypes.map(\.rawValue).joined(separator: ", "),
                        sectionPath: chunk.metadata.sectionPath,
                        slideNumber: chunk.metadata.slideNumber,
                        slideTitle: chunk.title,
                        sheetName: chunk.metadata.sheetName,
                        cellRange: chunk.metadata.cellRange,
                        sourceOrderStart: chunk.metadata.sourceOrderStart,
                        sourceOrderEnd: chunk.metadata.sourceOrderEnd,
                        chunkOrder: index
                    )
                )
            }
        )
        return OfficeRAGProjection(
            plainText: plainText,
            embeddingText: embeddingText.isEmpty ? plainText : embeddingText,
            chunks: chunks,
            ragDocument: ragDocument
        )
    }
}

private enum DOCXNormalizer {
    static func chunks(ir: OfficeDocumentIR, maxChunkCharacters: Int) -> [RAGChunk] {
        let blocks = ir.blocks.filter(\.isUseful).sorted { $0.order < $1.order }
        guard !blocks.isEmpty else { return [] }

        var chunks: [RAGChunk] = []
        var pending: [OfficeBlock] = []
        var pendingPath: [String] = []

        func flush() {
            guard !pending.isEmpty else { return }
            chunks.append(chunk(
                ir: ir,
                blocks: pending,
                index: chunks.count,
                sectionPath: pendingPath
            ))
            pending.removeAll()
        }

        for block in blocks {
            let sectionPath = block.metadata.sectionPath
            let blockTextLength = block.text.count
            let currentLength = pending.reduce(0) { $0 + $1.text.count }
            let sectionChanged = !pending.isEmpty && sectionPath != pendingPath
            let wouldOverflow = !pending.isEmpty && currentLength + blockTextLength > maxChunkCharacters
            if sectionChanged || wouldOverflow || block.type == .heading {
                flush()
            }
            pendingPath = sectionPath
            pending.append(block)
        }
        flush()
        return chunks
    }

    private static func chunk(
        ir: OfficeDocumentIR,
        blocks: [OfficeBlock],
        index: Int,
        sectionPath: [String]
    ) -> RAGChunk {
        let blockTypes = uniqueBlockTypes(blocks)
        let title = sectionPath.last
        let sourceLocator = sectionPath.isEmpty ? "Document" : sectionPath.joined(separator: " > ")
        let plainText = blocks.map(\.text).joined(separator: "\n\n")
        let metadata = ChunkMetadata(
            sectionPath: sectionPath,
            blockTypes: blockTypes,
            sourceOrderStart: blocks.map(\.order).min() ?? 0,
            sourceOrderEnd: blocks.map(\.order).max() ?? 0
        )
        return RAGChunk(
            id: "\(ir.fileName):docx:\(index)",
            fileName: ir.fileName,
            fileType: ir.fileType,
            title: title,
            sourceLocator: sourceLocator,
            plainText: plainText,
            embeddingText: EmbeddingTextRenderer.render(
                ir: ir,
                title: title,
                sourceLocator: sourceLocator,
                contentLabel: "Content",
                content: plainText,
                metadata: metadata,
                extraLines: sectionPath.isEmpty ? [] : ["Section: \(sectionPath.joined(separator: " > "))"]
            ),
            metadata: metadata
        )
    }
}

/// Chunks any tabular IR — XLSX sheets and CSV/TSV tables alike. One chunk per
/// `.worksheetRegion` block; because the extractor now emits row-range regions,
/// large tables produce several bounded chunks instead of one unbounded blob.
private enum TabularNormalizer {
    static func chunks(ir: OfficeDocumentIR) -> [RAGChunk] {
        ir.blocks
            .filter(\.isUseful)
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, block in
                let metadata = ChunkMetadata(
                    sheetName: block.metadata.sheetName,
                    cellRange: block.metadata.cellRange,
                    blockTypes: [block.type],
                    sourceOrderStart: block.order,
                    sourceOrderEnd: block.order
                )
                let locatorParts = [
                    block.metadata.sheetName.map { "Sheet \($0)" },
                    block.metadata.cellRange
                ].compactMap { $0 }
                let sourceLocator = locatorParts.isEmpty ? ir.fileName : locatorParts.joined(separator: " ")
                return RAGChunk(
                    id: "\(ir.fileName):\(ir.fileType.rawValue):\(index)",
                    fileName: ir.fileName,
                    fileType: ir.fileType,
                    title: block.metadata.sheetName,
                    sourceLocator: sourceLocator,
                    plainText: block.text,
                    embeddingText: EmbeddingTextRenderer.render(
                        ir: ir,
                        title: block.metadata.sheetName,
                        sourceLocator: sourceLocator,
                        contentLabel: "Content",
                        content: block.text,
                        metadata: metadata,
                        extraLines: [
                            block.metadata.sheetName.map { "Sheet: \($0)" },
                            block.metadata.cellRange.map { "Range: \($0)" }
                        ].compactMap { $0 }
                    ),
                    metadata: metadata
                )
            }
    }
}

private enum PPTXNormalizer {
    static func chunks(ir: OfficeDocumentIR) -> [RAGChunk] {
        let blocks = Dictionary(grouping: ir.blocks.filter(\.isUseful)) { block in
            block.metadata.slideNumber ?? block.order
        }
        return blocks.keys.sorted().enumerated().compactMap { index, slideKey in
            guard let slideBlocks = blocks[slideKey]?.sorted(by: { $0.order < $1.order }),
                  let first = slideBlocks.first else {
                return nil
            }
            let slideNumber = first.metadata.slideNumber ?? slideKey
            let slideTitle = slideBlocks.compactMap(\.metadata.slideTitle).first
                ?? first.text.components(separatedBy: .newlines).first
            let visible = slideBlocks
                .filter { $0.type != .speakerNotes }
                .map(\.text)
                .joined(separator: "\n")
            let notes = slideBlocks
                .filter { $0.type == .speakerNotes }
                .map(\.text)
                .joined(separator: "\n")
            let plainParts = [
                visible,
                notes.isEmpty ? nil : "Speaker notes:\n\(notes)"
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            let plainText = plainParts.joined(separator: "\n\n")
            let metadata = ChunkMetadata(
                slideNumber: slideNumber,
                blockTypes: uniqueBlockTypes(slideBlocks),
                sourceOrderStart: slideBlocks.map(\.order).min() ?? first.order,
                sourceOrderEnd: slideBlocks.map(\.order).max() ?? first.order
            )
            let sourceLocator = "Slide \(slideNumber)"
            return RAGChunk(
                id: "\(ir.fileName):pptx:\(index)",
                fileName: ir.fileName,
                fileType: ir.fileType,
                title: slideTitle,
                sourceLocator: sourceLocator,
                plainText: plainText,
                embeddingText: EmbeddingTextRenderer.render(
                    ir: ir,
                    title: slideTitle,
                    sourceLocator: sourceLocator,
                    contentLabel: "Content",
                    content: visible,
                    metadata: metadata,
                    extraLines: [
                        "Slide: \(slideNumber)",
                        slideTitle.map { "Title: \($0)" },
                        notes.isEmpty ? nil : "Speaker notes:\n\(notes)"
                    ].compactMap { $0 }
                ),
                metadata: metadata
            )
        }
    }
}

public enum EmbeddingTextRenderer {
    public static func render(
        ir: OfficeDocumentIR,
        title: String?,
        sourceLocator: String,
        contentLabel: String,
        content: String,
        metadata: ChunkMetadata,
        extraLines: [String] = []
    ) -> String {
        var lines = [
            "File: \(ir.fileName)",
            "Type: \(ir.fileType.rawValue)"
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Title: \(title)")
        }
        lines.append("Source: \(sourceLocator)")
        if !metadata.blockTypes.isEmpty {
            lines.append("Blocks: \(metadata.blockTypes.map(\.rawValue).joined(separator: ", "))")
        }
        lines.append(contentsOf: extraLines)
        lines.append("\(contentLabel):")
        lines.append(content)
        return lines.joined(separator: "\n")
    }
}

private func uniqueBlockTypes(_ blocks: [OfficeBlock]) -> [BlockType] {
    var seen = Set<BlockType>()
    return blocks.compactMap { block in
        seen.insert(block.type).inserted ? block.type : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
