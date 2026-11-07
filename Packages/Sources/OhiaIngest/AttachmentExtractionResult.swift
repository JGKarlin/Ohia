import Foundation
import OhiaCore

public enum AttachmentExtractionStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case completed
    case unsupportedType
    case parseFailed
    case encryptedOrPasswordProtected
    case tooLarge
    case emptyText
}

public enum AttachmentExtractionMethod: String, Codable, CaseIterable, Sendable, Equatable {
    case utf8Decode = "utf8-decode"
    case delimitedTable = "delimited-table"
    case nsAttributedStringHTML = "nsattributedstring-html"
    case nsAttributedStringRTF = "nsattributedstring-rtf"
    case liteParsePDF = "liteparse-pdf"
    case pdfKit = "pdfkit"
    case swiftOOXML = "swift-ooxml"
    case nsAttributedStringOffice = "nsattributedstring-office"
    case visionOCR = "vision-ocr"
    case visionSummary = "vision-summary"
}

public struct AttachmentExtractionResult: Sendable, Equatable {
    public let text: String?
    public let kind: DocumentKind
    public let status: AttachmentExtractionStatus
    public let method: AttachmentExtractionMethod?
    public let parserVersion: String?
    public let extractedCharacterCount: Int
    public let embeddingText: String?
    public let normalizedIRJSON: String?
    public let ragDocumentJSON: String?
    public let structureUnitKind: String?
    public let structureUnitCount: Int?
    /// Document-embedded title/author parsed from the source file's metadata
    /// (OOXML core properties, PDF document attributes). `nil` when the format
    /// carries no such metadata or the field was blank. Persisted onto
    /// `Attachment` so the attachment-summary prompt can cross-check the title
    /// and author it reads from the document's own text.
    public let documentTitle: String?
    public let documentAuthor: String?
    public let failureReason: String?

    public init(
        text: String?,
        kind: DocumentKind,
        status: AttachmentExtractionStatus,
        method: AttachmentExtractionMethod?,
        parserVersion: String? = nil,
        extractedCharacterCount: Int? = nil,
        embeddingText: String? = nil,
        normalizedIRJSON: String? = nil,
        ragDocumentJSON: String? = nil,
        structureUnitKind: String? = nil,
        structureUnitCount: Int? = nil,
        documentTitle: String? = nil,
        documentAuthor: String? = nil,
        failureReason: String? = nil
    ) {
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmbeddingText = embeddingText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIRJSON = normalizedIRJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRAGJSON = ragDocumentJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = normalizedText?.isEmpty == false ? text : nil
        self.kind = kind
        self.status = status
        self.method = method
        self.parserVersion = parserVersion
        self.extractedCharacterCount = extractedCharacterCount ?? self.text?.count ?? 0
        self.embeddingText = normalizedEmbeddingText?.isEmpty == false ? embeddingText : nil
        self.normalizedIRJSON = normalizedIRJSON?.isEmpty == false ? normalizedIRJSON : nil
        self.ragDocumentJSON = normalizedRAGJSON?.isEmpty == false ? normalizedRAGJSON : nil
        self.structureUnitKind = structureUnitKind
        self.structureUnitCount = structureUnitCount
        self.documentTitle = Self.normalizedMetadata(documentTitle)
        self.documentAuthor = Self.normalizedMetadata(documentAuthor)
        self.failureReason = failureReason
    }

    private static func normalizedMetadata(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public static func completed(
        text: String,
        kind: DocumentKind,
        method: AttachmentExtractionMethod,
        parserVersion: String? = nil,
        embeddingText: String? = nil,
        normalizedIRJSON: String? = nil,
        ragDocumentJSON: String? = nil,
        structureUnitKind: String? = nil,
        structureUnitCount: Int? = nil,
        documentTitle: String? = nil,
        documentAuthor: String? = nil
    ) -> AttachmentExtractionResult {
        AttachmentExtractionResult(
            text: text,
            kind: kind,
            status: .completed,
            method: method,
            parserVersion: parserVersion,
            embeddingText: embeddingText,
            normalizedIRJSON: normalizedIRJSON,
            ragDocumentJSON: ragDocumentJSON,
            structureUnitKind: structureUnitKind,
            structureUnitCount: structureUnitCount,
            documentTitle: documentTitle,
            documentAuthor: documentAuthor
        )
    }

    public static func failure(
        kind: DocumentKind,
        status: AttachmentExtractionStatus,
        method: AttachmentExtractionMethod?,
        parserVersion: String? = nil,
        failureReason: String? = nil,
        structureUnitKind: String? = nil,
        structureUnitCount: Int? = nil
    ) -> AttachmentExtractionResult {
        AttachmentExtractionResult(
            text: nil,
            kind: kind,
            status: status,
            method: method,
            parserVersion: parserVersion,
            structureUnitKind: structureUnitKind,
            structureUnitCount: structureUnitCount,
            failureReason: failureReason
        )
    }

    public var hasExtractedText: Bool {
        status == .completed && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public extension Attachment {
    func applyExtractionResult(_ result: AttachmentExtractionResult) {
        detectedDocumentKind = result.kind.rawValue
        extractionStatus = result.status.rawValue
        extractionMethod = result.method?.rawValue
        extractionFailureReason = result.failureReason
        extractionParserVersion = result.parserVersion
        extractionCharacterCount = result.extractedCharacterCount
        extractionStructureUnitKind = result.structureUnitKind
        extractionStructureUnitCount = result.structureUnitCount
        documentTitle = result.documentTitle
        documentAuthor = result.documentAuthor
    }
}
