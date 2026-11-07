import Foundation
import OhiaCore

public enum VisualAttachmentExtractionStatus: String, Codable, Sendable, Equatable {
    case completed
    case unsupportedType
    case unavailable
    case parseFailed
    case guardrailViolation
    case tooLarge
    case emptyEvidence
}

public enum VisualAttachmentExtractionMethod: String, Codable, Sendable, Equatable {
    case appleVisionFoundationModelsLegacy = "apple-vision-foundation-models-legacy"
    case appleFoundationModelsMultimodal = "apple-foundation-models-multimodal"
}

public struct VisualAttachmentExtractionResult: Sendable, Equatable {
    public let status: VisualAttachmentExtractionStatus
    public let method: VisualAttachmentExtractionMethod?
    public let summary: String?
    public let evidenceJSON: String?
    public let parserVersion: String?
    public let signalCount: Int?
    public let ocrText: String?
    public let evidenceKind: String?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let imagePixelCount: Int?
    public let originalImageWidth: Int?
    public let originalImageHeight: Int?
    public let originalImagePixelCount: Int?
    public let wasDownsampled: Bool?
    public let mimeExtensionMismatch: Bool?
    public let ocrLineCount: Int?
    public let ocrBlockCount: Int?
    public let ocrCharacterCount: Int?
    public let classificationCount: Int?
    public let objectCount: Int?
    public let failureReason: String?
    public let generatedAt: Date?

    public init(
        status: VisualAttachmentExtractionStatus,
        method: VisualAttachmentExtractionMethod?,
        summary: String? = nil,
        evidenceJSON: String? = nil,
        parserVersion: String? = AppleIntelligenceModelProfile.legacyParserVersion,
        signalCount: Int? = nil,
        ocrText: String? = nil,
        evidenceKind: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        imagePixelCount: Int? = nil,
        originalImageWidth: Int? = nil,
        originalImageHeight: Int? = nil,
        originalImagePixelCount: Int? = nil,
        wasDownsampled: Bool? = nil,
        mimeExtensionMismatch: Bool? = nil,
        ocrLineCount: Int? = nil,
        ocrBlockCount: Int? = nil,
        ocrCharacterCount: Int? = nil,
        classificationCount: Int? = nil,
        objectCount: Int? = nil,
        failureReason: String? = nil,
        generatedAt: Date? = Date()
    ) {
        self.status = status
        self.method = method
        self.summary = summary
        self.evidenceJSON = evidenceJSON
        self.parserVersion = parserVersion
        self.signalCount = signalCount
        let normalizedOCRText = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ocrText = normalizedOCRText?.isEmpty == false ? normalizedOCRText : nil
        self.evidenceKind = evidenceKind
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imagePixelCount = imagePixelCount
        self.originalImageWidth = originalImageWidth
        self.originalImageHeight = originalImageHeight
        self.originalImagePixelCount = originalImagePixelCount
        self.wasDownsampled = wasDownsampled
        self.mimeExtensionMismatch = mimeExtensionMismatch
        self.ocrLineCount = ocrLineCount
        self.ocrBlockCount = ocrBlockCount
        self.ocrCharacterCount = ocrCharacterCount
        self.classificationCount = classificationCount
        self.objectCount = objectCount
        self.failureReason = failureReason
        self.generatedAt = generatedAt
    }

    public var hasVisualSummary: Bool {
        guard status == .completed,
              let summary else {
            return false
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The same extraction with its reader-facing summary replaced; every
    /// evidence field, including the encoded analysis, is kept as observed.
    public func replacingSummary(_ summary: String) -> VisualAttachmentExtractionResult {
        VisualAttachmentExtractionResult(
            status: status,
            method: method,
            summary: summary,
            evidenceJSON: evidenceJSON,
            parserVersion: parserVersion,
            signalCount: signalCount,
            ocrText: ocrText,
            evidenceKind: evidenceKind,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            imagePixelCount: imagePixelCount,
            originalImageWidth: originalImageWidth,
            originalImageHeight: originalImageHeight,
            originalImagePixelCount: originalImagePixelCount,
            wasDownsampled: wasDownsampled,
            mimeExtensionMismatch: mimeExtensionMismatch,
            ocrLineCount: ocrLineCount,
            ocrBlockCount: ocrBlockCount,
            ocrCharacterCount: ocrCharacterCount,
            classificationCount: classificationCount,
            objectCount: objectCount,
            failureReason: failureReason,
            generatedAt: generatedAt
        )
    }

    /// The same extraction without its reader-facing summary, for a summary
    /// that could not be put in the reading language. OCR text, analysis,
    /// and image measurements are kept as observed, so search and the
    /// attachment summary still read them; `failureReason` says why the
    /// summary is missing.
    public func withholdingSummary(failureReason: String) -> VisualAttachmentExtractionResult {
        VisualAttachmentExtractionResult(
            status: status,
            method: method,
            summary: nil,
            evidenceJSON: evidenceJSON,
            parserVersion: parserVersion,
            signalCount: signalCount,
            ocrText: ocrText,
            evidenceKind: evidenceKind,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            imagePixelCount: imagePixelCount,
            originalImageWidth: originalImageWidth,
            originalImageHeight: originalImageHeight,
            originalImagePixelCount: originalImagePixelCount,
            wasDownsampled: wasDownsampled,
            mimeExtensionMismatch: mimeExtensionMismatch,
            ocrLineCount: ocrLineCount,
            ocrBlockCount: ocrBlockCount,
            ocrCharacterCount: ocrCharacterCount,
            classificationCount: classificationCount,
            objectCount: objectCount,
            failureReason: failureReason,
            generatedAt: generatedAt
        )
    }

    public var hasOCRText: Bool {
        guard status == .completed,
              let ocrText else {
            return false
        }
        return ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func completed(
        summary: String,
        evidenceJSON: String?,
        signalCount: Int,
        ocrText: String? = nil,
        evidenceKind: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        imagePixelCount: Int? = nil,
        originalImageWidth: Int? = nil,
        originalImageHeight: Int? = nil,
        originalImagePixelCount: Int? = nil,
        wasDownsampled: Bool? = nil,
        mimeExtensionMismatch: Bool? = nil,
        ocrLineCount: Int? = nil,
        ocrBlockCount: Int? = nil,
        ocrCharacterCount: Int? = nil,
        classificationCount: Int? = nil,
        objectCount: Int? = nil,
        method: VisualAttachmentExtractionMethod = .appleVisionFoundationModelsLegacy,
        parserVersion: String = AppleIntelligenceModelProfile.legacyParserVersion,
        generatedAt: Date = Date()
    ) -> VisualAttachmentExtractionResult {
        VisualAttachmentExtractionResult(
            status: .completed,
            method: method,
            summary: summary,
            evidenceJSON: evidenceJSON,
            parserVersion: parserVersion,
            signalCount: signalCount,
            ocrText: ocrText,
            evidenceKind: evidenceKind,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            imagePixelCount: imagePixelCount,
            originalImageWidth: originalImageWidth,
            originalImageHeight: originalImageHeight,
            originalImagePixelCount: originalImagePixelCount,
            wasDownsampled: wasDownsampled,
            mimeExtensionMismatch: mimeExtensionMismatch,
            ocrLineCount: ocrLineCount,
            ocrBlockCount: ocrBlockCount,
            ocrCharacterCount: ocrCharacterCount,
            classificationCount: classificationCount,
            objectCount: objectCount,
            generatedAt: generatedAt
        )
    }

    public static func completed(
        summary: String,
        evidence: VisualAttachmentEvidence,
        evidenceJSON: String?,
        method: VisualAttachmentExtractionMethod = .appleVisionFoundationModelsLegacy,
        parserVersion: String = AppleIntelligenceModelProfile.legacyParserVersion,
        generatedAt: Date = Date()
    ) -> VisualAttachmentExtractionResult {
        completed(
            summary: summary,
            evidenceJSON: evidenceJSON,
            signalCount: evidence.signalCount,
            ocrText: evidence.ocrText,
            evidenceKind: evidence.evidenceKind.rawValue,
            imageWidth: evidence.imageMetadata.width,
            imageHeight: evidence.imageMetadata.height,
            imagePixelCount: evidence.imageMetadata.pixelCount,
            originalImageWidth: evidence.imageMetadata.originalWidth,
            originalImageHeight: evidence.imageMetadata.originalHeight,
            originalImagePixelCount: evidence.imageMetadata.originalPixelCount,
            wasDownsampled: evidence.imageMetadata.wasDownsampled,
            mimeExtensionMismatch: evidence.imageMetadata.mimeExtensionMismatch,
            ocrLineCount: evidence.ocrLines.count,
            ocrBlockCount: evidence.ocrBlocks.count,
            ocrCharacterCount: evidence.ocrCharacterCount,
            classificationCount: evidence.classifications.count,
            objectCount: evidence.detectedObjects.reduce(0) { $0 + $1.count },
            method: method,
            parserVersion: parserVersion,
            generatedAt: generatedAt
        )
    }

    public static func completed(
        analysis: VisualAttachmentAnalysisRecord,
        evidenceJSON: String?,
        method: VisualAttachmentExtractionMethod,
        parserVersion: String,
        generatedAt: Date = Date()
    ) -> VisualAttachmentExtractionResult {
        let evidence = analysis.legacyEvidence
        return completed(
            summary: analysis.summary,
            evidenceJSON: evidenceJSON,
            signalCount: analysis.signalCount,
            ocrText: analysis.visibleText,
            evidenceKind: analysis.contentKind.rawValue,
            imageWidth: evidence?.imageMetadata.width,
            imageHeight: evidence?.imageMetadata.height,
            imagePixelCount: evidence?.imageMetadata.pixelCount,
            originalImageWidth: evidence?.imageMetadata.originalWidth,
            originalImageHeight: evidence?.imageMetadata.originalHeight,
            originalImagePixelCount: evidence?.imageMetadata.originalPixelCount,
            wasDownsampled: evidence?.imageMetadata.wasDownsampled,
            mimeExtensionMismatch: evidence?.imageMetadata.mimeExtensionMismatch,
            ocrLineCount: evidence?.ocrLines.count,
            ocrBlockCount: evidence?.ocrBlocks.count,
            ocrCharacterCount: analysis.ocrCharacterCount,
            classificationCount: evidence?.classifications.count,
            objectCount: evidence?.detectedObjects.reduce(0) { $0 + $1.count },
            method: method,
            parserVersion: parserVersion,
            generatedAt: generatedAt
        )
    }

    public static func failure(
        status: VisualAttachmentExtractionStatus,
        method: VisualAttachmentExtractionMethod? = .appleVisionFoundationModelsLegacy,
        failureReason: String? = nil,
        parserVersion: String? = AppleIntelligenceModelProfile.legacyParserVersion,
        generatedAt: Date = Date()
    ) -> VisualAttachmentExtractionResult {
        VisualAttachmentExtractionResult(
            status: status,
            method: method,
            parserVersion: parserVersion,
            failureReason: failureReason,
            generatedAt: generatedAt
        )
    }
}

public extension AppleIntelligenceModelProfile {
    var visualExtractionMethod: VisualAttachmentExtractionMethod {
        switch imageAnalysisTier {
        case .legacy:
            return .appleVisionFoundationModelsLegacy
        case .multimodal:
            return .appleFoundationModelsMultimodal
        }
    }
}

public extension Attachment {
    func applyVisualExtractionResult(_ result: VisualAttachmentExtractionResult) {
        visualExtractionStatus = result.status.rawValue
        visualExtractionMethod = result.method?.rawValue
        visualExtractionFailureReason = result.failureReason
        visualExtractionParserVersion = result.parserVersion
        visualSignalCount = result.signalCount
        visualGeneratedAt = result.generatedAt
        visualEvidenceKind = result.evidenceKind
        visualImageWidth = result.imageWidth
        visualImageHeight = result.imageHeight
        visualImagePixelCount = result.imagePixelCount
        visualOriginalImageWidth = result.originalImageWidth
        visualOriginalImageHeight = result.originalImageHeight
        visualOriginalImagePixelCount = result.originalImagePixelCount
        visualWasDownsampled = result.wasDownsampled
        visualMimeExtensionMismatch = result.mimeExtensionMismatch
        visualOCRLineCount = result.ocrLineCount
        visualOCRBlockCount = result.ocrBlockCount
        visualOCRCharacterCount = result.ocrCharacterCount
        visualClassificationCount = result.classificationCount
        visualObjectCount = result.objectCount

        if result.hasVisualSummary {
            visualSummary = result.summary
            visualEvidenceJSON = result.evidenceJSON
        } else {
            visualSummary = nil
            visualEvidenceJSON = nil
        }
    }
}
