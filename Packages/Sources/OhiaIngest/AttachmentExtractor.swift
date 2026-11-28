import Foundation
import OhiaCore
import OhiaPDFParsing

#if canImport(AppKit)
import AppKit
#endif

public enum AttachmentExtractor {
    public enum TextExtractionPolicy: Sendable, Equatable {
        case full
        case lightweightOnly
        case bounded(maxBytes: Int)
    }

    public static func extract(
        data: Data,
        mimeType: String,
        filename: String,
        policy: TextExtractionPolicy = .full
    ) -> AttachmentExtractionResult? {
        let kind = DocumentKind.detect(mimeType: mimeType, filename: filename)
        guard kind != .unsupported else {
            return .failure(
                kind: .unsupported,
                status: .unsupportedType,
                method: nil,
                failureReason: "Unsupported attachment type"
            )
        }
        guard shouldAttemptExtraction(data: data, kind: kind, policy: policy) else {
            return nil
        }

        switch kind {
        case .plainText, .markdown:
            return extractDecodedText(data: data, kind: kind)
        case .csv, .tsv:
            return extractDelimited(data: data, kind: kind, filename: filename)
        case .html:
            return extractAttributedText(
                data: data,
                kind: kind,
                method: .nsAttributedStringHTML,
                documentType: .html
            )
        case .rtf:
            return extractAttributedText(
                data: data,
                kind: kind,
                method: .nsAttributedStringRTF,
                documentType: .rtf
            )
        case .pdf:
            return extractPDF(data: data, filename: filename)
        case .docx, .xlsx, .pptx:
            return extractOOXML(data: data, kind: kind, filename: filename)
        case .legacyWord, .legacySpreadsheet, .legacyPresentation:
            return extractLegacyOffice(data: data, kind: kind)
        case .image:
            return extractImage(data: data, kind: kind)
        case .unsupported:
            return .failure(
                kind: .unsupported,
                status: .unsupportedType,
                method: nil,
                failureReason: "Unsupported attachment type"
            )
        }
    }

    public static func extractText(
        data: Data,
        mimeType: String,
        filename: String,
        policy: TextExtractionPolicy = .full
    ) throws -> String? {
        extract(
            data: data,
            mimeType: mimeType,
            filename: filename,
            policy: policy
        )?.text
    }

    public static func extractionMethod(mimeType: String, filename: String) -> String? {
        let kind = DocumentKind.detect(mimeType: mimeType, filename: filename)
        return kind.defaultMethod?.rawValue
    }

    public static func shouldAttemptExtraction(
        data: Data,
        mimeType: String,
        filename: String,
        policy: TextExtractionPolicy
    ) -> Bool {
        let kind = DocumentKind.detect(mimeType: mimeType, filename: filename)
        return shouldAttemptExtraction(data: data, kind: kind, policy: policy)
    }

    public static func isTextBearing(mimeType: String, filename: String) -> Bool {
        DocumentKind.detect(mimeType: mimeType, filename: filename).isTextBearing
    }

    public static func isTextBearingDocument(mimeType: String, filename: String) -> Bool {
        DocumentKind.detect(mimeType: mimeType, filename: filename).isDocument
    }

    private static func shouldAttemptExtraction(
        data: Data,
        kind: DocumentKind,
        policy: TextExtractionPolicy
    ) -> Bool {
        switch policy {
        case .full:
            return kind.isTextBearing
        case .lightweightOnly:
            return data.count <= 512 * 1024 && kind.isCheapInlineText
        case .bounded(let maxBytes):
            guard kind != .image, kind != .pdf else { return false }
            if kind.isCheapInlineText, data.count <= 512 * 1024 { return true }
            return data.count <= max(0, maxBytes)
        }
    }

    private static func extractDecodedText(data: Data, kind: DocumentKind) -> AttachmentExtractionResult {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .utf8Decode,
                failureReason: "Could not decode text attachment"
            )
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(kind: kind, status: .emptyText, method: .utf8Decode)
        }
        return .completed(text: text, kind: kind, method: .utf8Decode)
    }

    private static func extractDelimited(
        data: Data,
        kind: DocumentKind,
        filename: String
    ) -> AttachmentExtractionResult {
        do {
            let extraction = try TabularExtractor.extract(data: data, kind: kind, filename: filename)
            return .completed(
                text: extraction.text,
                kind: kind,
                method: .delimitedTable,
                parserVersion: "delimited-1",
                embeddingText: extraction.embeddingText,
                normalizedIRJSON: extraction.normalizedIRJSON,
                ragDocumentJSON: extraction.ragDocumentJSON,
                structureUnitKind: extraction.structureUnitKind,
                structureUnitCount: extraction.structureUnitCount
            )
        } catch TabularExtractor.ExtractionError.empty {
            return .failure(kind: kind, status: .emptyText, method: .delimitedTable, parserVersion: "delimited-1")
        } catch {
            // Any other parse failure degrades to a flat decode so the raw text
            // is still captured rather than lost.
            return extractDecodedText(data: data, kind: kind)
        }
    }

    static func extractPDF(
        data: Data,
        filename: String,
        liteParse: LiteParsePDFExtractor = LiteParsePDFExtractor()
    ) -> AttachmentExtractionResult {
        do {
            let extraction = try liteParse.extract(data: data, filename: filename)
            return .completed(
                text: extraction.text,
                kind: .pdf,
                method: extraction.engine == .pdfKit ? .pdfKit : .liteParsePDF,
                parserVersion: extraction.parserVersion,
                embeddingText: extraction.embeddingText,
                normalizedIRJSON: extraction.normalizedIRJSON,
                ragDocumentJSON: extraction.ragDocumentJSON,
                structureUnitKind: "page",
                structureUnitCount: extraction.pageCount
            )
        } catch LiteParsePDFExtractor.ExtractorError.encrypted(let pageCount) {
            return .failure(
                kind: .pdf,
                status: .encryptedOrPasswordProtected,
                method: .pdfKit,
                parserVersion: "pdfkit",
                failureReason: LiteParsePDFExtractor.ExtractorError.encrypted(pageCount: pageCount).localizedDescription,
                structureUnitKind: "page",
                structureUnitCount: pageCount
            )
        } catch LiteParsePDFExtractor.ExtractorError.pdfKitEmptyText(let pageCount) {
            return .failure(
                kind: .pdf,
                status: .emptyText,
                method: .pdfKit,
                parserVersion: "pdfkit",
                failureReason: LiteParsePDFExtractor.ExtractorError.pdfKitEmptyText(pageCount: pageCount).localizedDescription,
                structureUnitKind: "page",
                structureUnitCount: pageCount
            )
        } catch {
            // Nothing was read: the service could not be reached, timed out,
            // or could open the PDF with neither LiteParse nor PDFKit. The PDF
            // is never opened in this process instead; a parse failure stays
            // retryable.
            let reason = error.localizedDescription
            let status: AttachmentExtractionStatus = reason.lowercased().contains("password")
                || reason.lowercased().contains("encrypted")
                ? .encryptedOrPasswordProtected
                : (error as? LiteParsePDFExtractor.ExtractorError) == .emptyText ? .emptyText : .parseFailed
            return .failure(
                kind: .pdf,
                status: status,
                method: .liteParsePDF,
                parserVersion: "liteparse",
                failureReason: reason,
                structureUnitKind: "page"
            )
        }
    }

    private static func extractOOXML(data: Data, kind: DocumentKind, filename: String) -> AttachmentExtractionResult {
        do {
            let extraction = try OOXMLTextExtractor.extract(data: data, kind: kind, filename: filename)
            return .completed(
                text: extraction.text,
                kind: kind,
                method: .swiftOOXML,
                parserVersion: "swift-ooxml",
                embeddingText: extraction.embeddingText,
                normalizedIRJSON: jsonString(extraction.ir),
                ragDocumentJSON: jsonString(extraction.ragDocument),
                structureUnitKind: extraction.structureUnitKind,
                structureUnitCount: extraction.structureUnitCount,
                documentTitle: extraction.ir.documentProperties.title,
                documentAuthor: extraction.ir.documentProperties.author
            )
        } catch {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .swiftOOXML,
                parserVersion: "swift-ooxml",
                failureReason: error.localizedDescription
            )
        }
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func extractAttributedText(
        data: Data,
        kind: DocumentKind,
        method: AttachmentExtractionMethod,
        documentType: NSAttributedString.DocumentType
    ) -> AttachmentExtractionResult {
#if canImport(AppKit)
        do {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            let attributed = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(kind: kind, status: .emptyText, method: method)
            }
            return .completed(text: text, kind: kind, method: method)
        } catch {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: method,
                failureReason: error.localizedDescription
            )
        }
#else
        return .failure(
            kind: kind,
            status: .parseFailed,
            method: method,
            failureReason: "AppKit is unavailable"
        )
#endif
    }

    private static func extractLegacyOffice(data: Data, kind: DocumentKind) -> AttachmentExtractionResult {
#if canImport(AppKit)
        var docAttributes: NSDictionary? = nil
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [:],
                documentAttributes: &docAttributes
            )
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(kind: kind, status: .emptyText, method: .nsAttributedStringOffice)
            }
            return .completed(text: text, kind: kind, method: .nsAttributedStringOffice)
        } catch {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .nsAttributedStringOffice,
                failureReason: error.localizedDescription
            )
        }
#else
        return .failure(
            kind: kind,
            status: .parseFailed,
            method: .nsAttributedStringOffice,
            failureReason: "AppKit is unavailable"
        )
#endif
    }

    /// Reads an image's text in `OhiaPDFParser.xpc`, through this process's
    /// `PDFParserRoute`; the image is never decoded here. In a process with
    /// no route (a test runner) the text is not read at all. A broken
    /// recognizer or an unreachable service is retried once right away
    /// (`ImageTextRecognition.recognize`). Failures that a later attempt could
    /// fix (the service timed out, or unreachable or broken twice in a row)
    /// are `.parseFailed`, the status `AttachmentExtractionRetryPolicy`
    /// retries later; a service whose recognizer broke has exited by then, so
    /// that retry runs in a fresh process. An image that does not decode, or
    /// that Vision fails on, keeps its earlier `.parseFailed` outcome; one
    /// without text is `.emptyText`; one too large, in bytes or pixels, is
    /// `.tooLarge`.
    static func extractImage(
        data: Data,
        kind: DocumentKind,
        recognizeText: ImageTextRecognition.Recognize? = PDFParserRoute.current()?.recognizeText
    ) -> AttachmentExtractionResult {
        guard !data.isEmpty else {
            return .failure(kind: kind, status: .parseFailed, method: .visionOCR, failureReason: "Could not decode image")
        }
        guard let recognizeText else {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .visionOCR,
                failureReason: "The image text recognition service is not available in this process"
            )
        }
        let reply = ImageTextRecognition.recognize(data, using: recognizeText)
        switch reply.outcome {
        case .recognized:
            let text = reply.lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(kind: kind, status: .emptyText, method: .visionOCR)
            }
            return .completed(text: text, kind: kind, method: .visionOCR)
        case .undecodable:
            return .failure(kind: kind, status: .parseFailed, method: .visionOCR, failureReason: "Could not decode image")
        case .failed:
            return .failure(kind: kind, status: .parseFailed, method: .visionOCR, failureReason: reply.detail)
        case .invalidRequest, .outputTooLarge:
            return .failure(
                kind: kind,
                status: .tooLarge,
                method: .visionOCR,
                failureReason: "The image or its text exceeds the text recognition service's size limit"
            )
        case .recognizerUnavailable:
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .visionOCR,
                failureReason: "Text recognition was unavailable in the parser service"
            )
        case .timedOut:
            return .failure(kind: kind, status: .parseFailed, method: .visionOCR, failureReason: "Image text recognition timed out")
        case .serviceUnavailable:
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .visionOCR,
                failureReason: "The image text recognition service could not be reached"
            )
        case .cancelled:
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .visionOCR,
                failureReason: "Image text recognition was cancelled before it finished"
            )
        }
    }
}
