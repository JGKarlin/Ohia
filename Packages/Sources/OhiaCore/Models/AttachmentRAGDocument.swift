import Foundation

public struct AttachmentSourceBoundingBox: Codable, Sendable, Equatable {
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

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

public struct AttachmentRAGMetadata: Codable, Sendable, Equatable {
    public let sourceLocator: String?
    public let pageNumber: Int?
    public let pageWidth: Double?
    public let pageHeight: Double?
    public let boundingBox: AttachmentSourceBoundingBox?
    public let blockType: String?
    public let textSource: String?
    public let sectionPath: [String]
    public let slideNumber: Int?
    public let slideTitle: String?
    public let sheetName: String?
    public let cellRange: String?
    public let sourceOrderStart: Int
    public let sourceOrderEnd: Int
    public let chunkOrder: Int

    public init(
        sourceLocator: String? = nil,
        pageNumber: Int? = nil,
        pageWidth: Double? = nil,
        pageHeight: Double? = nil,
        boundingBox: AttachmentSourceBoundingBox? = nil,
        blockType: String? = nil,
        textSource: String? = nil,
        sectionPath: [String] = [],
        slideNumber: Int? = nil,
        slideTitle: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        sourceOrderStart: Int,
        sourceOrderEnd: Int,
        chunkOrder: Int
    ) {
        self.sourceLocator = Self.clean(sourceLocator)
        self.pageNumber = pageNumber
        self.pageWidth = pageWidth?.isFinite == true ? pageWidth : nil
        self.pageHeight = pageHeight?.isFinite == true ? pageHeight : nil
        self.boundingBox = boundingBox
        self.blockType = Self.clean(blockType)
        self.textSource = Self.clean(textSource)
        self.sectionPath = sectionPath.compactMap(Self.clean)
        self.slideNumber = slideNumber
        self.slideTitle = Self.clean(slideTitle)
        self.sheetName = Self.clean(sheetName)
        self.cellRange = Self.clean(cellRange)
        self.sourceOrderStart = sourceOrderStart
        self.sourceOrderEnd = max(sourceOrderStart, sourceOrderEnd)
        self.chunkOrder = max(0, chunkOrder)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public struct AttachmentRAGChunk: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileType: String
    public let title: String?
    public let plainText: String
    public let embeddingText: String
    public let metadata: AttachmentRAGMetadata

    public init(
        id: String,
        fileName: String,
        fileType: String,
        title: String? = nil,
        plainText: String,
        embeddingText: String,
        metadata: AttachmentRAGMetadata
    ) {
        self.id = id
        self.fileName = fileName
        self.fileType = fileType
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmbeddingText = embeddingText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.embeddingText = normalizedEmbeddingText.isEmpty ? self.plainText : normalizedEmbeddingText
        self.metadata = metadata
    }
}

public struct AttachmentRAGDocument: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let fileName: String
    public let fileType: String
    public let plainText: String
    public let embeddingText: String
    public let chunks: [AttachmentRAGChunk]

    public init(
        schemaVersion: Int = 1,
        fileName: String,
        fileType: String,
        plainText: String,
        embeddingText: String,
        chunks: [AttachmentRAGChunk]
    ) {
        self.schemaVersion = schemaVersion
        self.fileName = fileName
        self.fileType = fileType
        self.plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmbeddingText = embeddingText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.embeddingText = normalizedEmbeddingText.isEmpty ? self.plainText : normalizedEmbeddingText
        self.chunks = chunks
    }
}
