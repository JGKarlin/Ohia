import Foundation

#if canImport(Vision)
import Vision
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(PDFKit)
import PDFKit
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

    private static func extractPDF(data: Data, filename: String) -> AttachmentExtractionResult {
        do {
            let extraction = try LiteParsePDFExtractor().extract(data: data, filename: filename)
            return .completed(
                text: extraction.text,
                kind: .pdf,
                method: .liteParsePDF,
                parserVersion: extraction.parserVersion,
                embeddingText: extraction.embeddingText,
                normalizedIRJSON: extraction.normalizedIRJSON,
                ragDocumentJSON: extraction.ragDocumentJSON,
                structureUnitKind: "page",
                structureUnitCount: extraction.pageCount
            )
        } catch {
            if let fallback = extractPDFWithPDFKit(data: data, filename: filename) {
                return fallback
            }

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

    private static func extractPDFWithPDFKit(data: Data, filename: String) -> AttachmentExtractionResult? {
#if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            return .failure(
                kind: .pdf,
                status: .parseFailed,
                method: .pdfKit,
                parserVersion: "pdfkit",
                failureReason: "PDFKit could not open the PDF",
                structureUnitKind: "page"
            )
        }

        if document.isEncrypted && document.isLocked {
            return .failure(
                kind: .pdf,
                status: .encryptedOrPasswordProtected,
                method: .pdfKit,
                parserVersion: "pdfkit",
                failureReason: "PDF is encrypted or password-protected",
                structureUnitKind: "page",
                structureUnitCount: document.pageCount
            )
        }

        let pages = (0..<document.pageCount).map { index -> PDFPageIR in
            let pdfPage = document.page(at: index)
            let bounds = pdfPage?.bounds(for: .mediaBox) ?? .zero
            let text = pdfPage?
                .string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let blocks = text.isEmpty ? [] : [
                PDFBlock(
                    id: "\(filename):pdfkit:\(index + 1):0",
                    text: text,
                    blockType: .paragraph,
                    bbox: BoundingBox(
                        x: Double(bounds.origin.x),
                        y: Double(bounds.origin.y),
                        width: Double(bounds.width),
                        height: Double(bounds.height)
                    ),
                    order: 0,
                    source: .native
                )
            ]
            return PDFPageIR(
                pageNumber: index + 1,
                width: Double(bounds.width),
                height: Double(bounds.height),
                blocks: blocks
            )
        }
        let ir = PDFDocumentIR(fileName: filename, pageCount: document.pageCount, pages: pages)
        let projection = PDFRAGNormalizer.normalize(ir)
        let text = projection.plainText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return .failure(
                kind: .pdf,
                status: .emptyText,
                method: .pdfKit,
                parserVersion: "pdfkit",
                failureReason: "PDFKit found no extractable text",
                structureUnitKind: "page",
                structureUnitCount: document.pageCount
            )
        }

        return .completed(
            text: text,
            kind: .pdf,
            method: .pdfKit,
            parserVersion: "pdfkit",
            embeddingText: projection.embeddingText,
            normalizedIRJSON: jsonString(ir),
            ragDocumentJSON: jsonString(projection.ragDocument),
            structureUnitKind: "page",
            structureUnitCount: document.pageCount
        )
#else
        return nil
#endif
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

    private static func extractImage(data: Data, kind: DocumentKind) -> AttachmentExtractionResult {
#if canImport(Vision)
        do {
            guard let cgImage = cgImageFromData(data) else {
                return .failure(
                    kind: kind,
                    status: .parseFailed,
                    method: .visionOCR,
                    failureReason: "Could not decode image"
                )
            }

            var lines: [String] = []
            var capturedError: Error?

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    capturedError = error
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                for obs in observations {
                    if let candidate = obs.topCandidates(1).first {
                        lines.append(candidate.string)
                    }
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "ja-JP"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            if let capturedError { throw capturedError }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(kind: kind, status: .emptyText, method: .visionOCR)
            }
            return .completed(text: text, kind: kind, method: .visionOCR)
        } catch {
            return .failure(
                kind: kind,
                status: .parseFailed,
                method: .visionOCR,
                failureReason: error.localizedDescription
            )
        }
#else
        return .failure(
            kind: kind,
            status: .parseFailed,
            method: .visionOCR,
            failureReason: "Vision is unavailable"
        )
#endif
    }

#if canImport(Vision)
    private static func cgImageFromData(_ data: Data) -> CGImage? {
#if canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#else
        return nil
#endif
    }
#endif
}
