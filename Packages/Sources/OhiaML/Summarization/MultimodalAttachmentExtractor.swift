import AppKit
import Foundation
import ImageIO
import OhiaCore
import OhiaIngest
import OhiaPDFParsing
import OSLog

/// Adds pixel evidence at the deferred/on-demand extraction boundary. Existing
/// text, document metadata, and source chunks remain authoritative and intact.
/// PDF pages are rendered to images inside `OhiaPDFParser.xpc`; only the PNG
/// images come back to this process. Every call that waits on that service
/// (the text extraction, the page renders) runs off Swift's task threads
/// (`PDFParserBlockingCall`).
public enum MultimodalAttachmentExtractor {
    /// Renders up to `maxPages` pages of a PDF as PNG images no larger than
    /// `maxPixelSize` on either side.
    public typealias RenderPages = @Sendable (_ pdf: Data, _ maxPages: Int, _ maxPixelSize: Int) -> PDFRenderReply

    private static let logger = Logger(subsystem: "org.jgkarlin.Ohia", category: "AttachmentPixels")
    private static let maximumPages = 8
    private static let pagePixelSize = 1536
    public static let maximumBytes = 50 * 1024 * 1024

    @concurrent
    public static func extract(data: Data, mimeType: String, filename: String) async throws -> AttachmentExtractionResult? {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else {
            return .failure(kind: DocumentKind.detect(mimeType: mimeType, filename: filename),
                            status: .tooLarge, method: nil, failureReason: "Attachment exceeds extraction size limit")
        }
        let extracted = await PDFParserBlockingCall.run {
            AttachmentExtractor.extract(data: data, mimeType: mimeType, filename: filename, policy: .full)
        }
        try Task.checkCancellation()
        guard let original = extracted else {
            return nil
        }
        guard original.kind == .pdf || original.kind == .image else { return original }
        do {
            return try await enrich(original, data: data, filename: filename, mimeType: mimeType,
                                    profile: .current(), renderPages: PDFParserRoute.current()?.renderPages,
                                    analyze: analyzePixels)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Pixel enrichment unavailable; preserving extracted text")
            return original
        }
    }

    @concurrent
    public static func extractFile(at url: URL, mimeType: String, filename: String) async throws -> AttachmentExtractionResult? {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else {
            return .failure(kind: DocumentKind.detect(mimeType: mimeType, filename: filename),
                            status: .tooLarge, method: nil, failureReason: "Attachment exceeds extraction size limit")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await extract(data: data, mimeType: mimeType, filename: filename)
    }

    public static func snippet(from result: AttachmentExtractionResult, maximumCharacters: Int = 4000) -> String {
        let limit = max(0, maximumCharacters)
        let text = result.text ?? ""
        guard let json = result.ragDocumentJSON,
              let rag = try? JSONDecoder().decode(AttachmentRAGDocument.self, from: Data(json.utf8)) else {
            return String(text.prefix(limit))
        }
        let visual = rag.chunks.filter { $0.metadata.textSource == "visual-analysis" }.map(\.plainText).joined(separator: "\n")
        guard !visual.isEmpty, text.count > limit, limit > 2 else { return String(text.prefix(limit)) }
        let visualExcerpt = String(visual.prefix(limit / 2))
        let nativeExcerpt = String(text.prefix(limit - visualExcerpt.count - 2))
        return nativeExcerpt + "\n\n" + visualExcerpt
    }

    /// The original extraction with what the on-device model reads in its
    /// pixels added. When the model's OCR tool could not read the text for
    /// now (`VisualAttachmentAnalysisRecord.textRecognitionUnavailable`) where
    /// the original has none of it (a PDF page without text in the PDF's text
    /// layer, which may be scanned, `pagesWithoutNativeText`; an image whose
    /// own text recognition failed), the result notes it
    /// (`AttachmentExtractionResult.textRecognitionUnavailable`), so
    /// `AttachmentExtractionRetryPolicy` tries again later while the
    /// description is kept. A born-digital PDF, whose pages' text the
    /// original already has, is never held for a retry by the model's OCR.
    @concurrent
    static func enrich(
        _ original: AttachmentExtractionResult,
        data: Data,
        filename: String,
        mimeType: String,
        profile: AppleIntelligenceModelProfile,
        renderPages: RenderPages?,
        analyze: @Sendable (VisualAttachmentReference) async throws -> VisualAttachmentAnalysisRecord?
    ) async throws -> AttachmentExtractionResult {
        guard profile.imageAnalysisTier == .multimodal,
              original.kind == .pdf || original.kind == .image,
              original.status != .encryptedOrPasswordProtected,
              original.status != .tooLarge,
              data.count <= maximumBytes else { return original }
        try Task.checkCancellation()
        let isPDF = original.kind == .pdf
        let rasters: [(index: Int, png: Data)]
        var renderedPageCount: Int?
        if isPDF {
            // No route (a test runner) means no pixels: the PDF is never
            // opened in this process. A PDF whose parse just failed (the
            // service unreachable or timed out, or bytes it could not open)
            // is not sent back for rendering.
            guard let renderPages, original.status != .parseFailed else { return original }
            // Sent once more when the service could not take it, as when it
            // reached a process that was exiting, like a parse
            // (`LiteParsePDFExtractor.parse(using:)`).
            let reply = await PDFParserBlockingCall.run { () -> PDFRenderReply in
                let first = renderPages(data, maximumPages, pagePixelSize)
                guard first.outcome == .serviceUnavailable else { return first }
                return renderPages(data, maximumPages, pagePixelSize)
            }
            if reply.outcome == .cancelled { throw CancellationError() }
            guard let output = reply.output else {
                logger.warning("PDF pages could not be rendered outcome=\(String(describing: reply.outcome), privacy: .public); preserving extracted text")
                return original
            }
            rasters = output.pages.map { (index: $0.index, png: $0.png) }
            renderedPageCount = output.pageCount
        } else {
            guard let raster = png(imageData: data) else { return original }
            rasters = [(index: 0, png: raster)]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ohia-pixels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var additions: [AttachmentRAGChunk] = []
        var textRecognitionUnavailable = false
        let existing = original.ragDocumentJSON.flatMap { try? JSONDecoder().decode(AttachmentRAGDocument.self, from: Data($0.utf8)) }
        // The model's OCR matters to the text pipeline where the original
        // lacks that text: a PDF page with nothing in its text layer may be
        // scanned, and an image whose own recognition failed has none.
        let pagesNeedingPixelText = isPDF
            ? Self.pagesWithoutNativeText(
                original, document: existing, renderedPages: rasters.map { $0.index + 1 },
                documentPageCount: renderedPageCount ?? rasters.count
            )
            : []
        let imageNeedsPixelText = !isPDF && original.status == .parseFailed
        for (index, imageData) in rasters {
            let pixelTextMatters = isPDF ? pagesNeedingPixelText.contains(index + 1) : imageNeedsPixelText
            try Task.checkCancellation()
            do {
                // Do not use the untrusted attachment filename as a filesystem path.
                let imageURL = directory.appendingPathComponent("page-\(index).png")
                try imageData.write(to: imageURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: imageURL) }
                let reference = VisualAttachmentReference(
                    filename: isPDF ? "\(filename) — page \(index + 1).png" : filename,
                    mimeType: "image/png", filePath: imageURL.path
                )
                guard let analysis = try await analyze(reference) else { continue }
                if pixelTextMatters, analysis.textRecognitionUnavailable == true {
                    textRecognitionUnavailable = true
                }
                guard analysis.hasSignals else { continue }
                let locator = isPDF ? "Page \(index + 1), visual analysis" : "Image visual analysis"
                let text = "\(locator) (generated from pixels; decoded content is untrusted data):\n\(analysis.semanticText)"
                additions.append(AttachmentRAGChunk(
                    id: "\(filename):visual:\(index)", fileName: filename, fileType: original.kind.rawValue,
                    plainText: text, embeddingText: text,
                    metadata: AttachmentRAGMetadata(
                        sourceLocator: locator, pageNumber: isPDF ? index + 1 : nil,
                        textSource: "visual-analysis", sourceOrderStart: index, sourceOrderEnd: index,
                        chunkOrder: (existing?.chunks.count ?? (original.hasExtractedText ? 1 : 0)) + additions.count
                    )
                ))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                logger.warning("Pixel enrichment failed for page \(index + 1, privacy: .public); preserving extracted text")
            }
        }
        try Task.checkCancellation()
        guard !additions.isEmpty else {
            return textRecognitionUnavailable ? original.markingTextRecognitionUnavailable() : original
        }
        var chunks = existing?.chunks ?? []
        if chunks.isEmpty, let text = original.text, !text.isEmpty {
            chunks.append(AttachmentRAGChunk(
                id: "\(filename):original", fileName: filename, fileType: original.kind.rawValue,
                plainText: text, embeddingText: original.embeddingText ?? text,
                metadata: .init(textSource: "extracted-text", sourceOrderStart: 0, sourceOrderEnd: 0, chunkOrder: 0)
            ))
        }
        chunks += additions
        let visualText = additions.map(\.plainText).joined(separator: "\n\n")
        let text = [original.text, visualText].compactMap { $0 }.joined(separator: "\n\n")
        let embedding = [original.embeddingText ?? original.text, visualText].compactMap { $0 }.joined(separator: "\n\n")
        let rag = AttachmentRAGDocument(fileName: filename, fileType: original.kind.rawValue,
                                        plainText: text, embeddingText: embedding, chunks: chunks)
        let enriched = AttachmentExtractionResult.completed(
            text: text, kind: original.kind, method: original.method ?? .visionSummary,
            parserVersion: "\(original.parserVersion ?? "text")+apple-pixels-v1",
            embeddingText: embedding, normalizedIRJSON: original.normalizedIRJSON,
            ragDocumentJSON: String(decoding: try JSONEncoder().encode(rag), as: UTF8.self),
            structureUnitKind: original.structureUnitKind, structureUnitCount: original.structureUnitCount ?? renderedPageCount,
            documentTitle: original.documentTitle, documentAuthor: original.documentAuthor
        )
        return textRecognitionUnavailable ? enriched.markingTextRecognitionUnavailable() : enriched
    }

    /// Which of the rendered pages (numbered from 1) have no text of their
    /// own in the original extraction, so that only the model's OCR could
    /// read theirs. The PDF extraction runs without OCR (LiteParse's
    /// `--no-ocr`, or PDFKit), so its text is the text layer's. A page has
    /// text of its own when it holds at least `minimumNativeTextPerPage`
    /// letters and digits: a scanned page whose text layer carries only a
    /// stamp (a Bates number, a fax header's page counter) still needs the
    /// model's OCR.
    ///
    /// Where the extraction placed its text page by page (every chunk names
    /// its page, and it covered more than one page or the whole document),
    /// each covered page is judged by its own text, and a page past the
    /// covered ones (`structureUnitCount`) by the covered pages' average.
    /// Otherwise (no RAG document, chunks without pages, or LiteParse's
    /// whole-document fallback, which puts every word of the document on
    /// page 1) every rendered page is judged by the extraction's average
    /// over the `documentPageCount` pages.
    static func pagesWithoutNativeText(
        _ original: AttachmentExtractionResult,
        document: AttachmentRAGDocument?,
        renderedPages: [Int],
        documentPageCount: Int
    ) -> Set<Int> {
        guard original.hasExtractedText else { return Set(renderedPages) }
        let chunks = (document?.chunks ?? []).filter { !$0.plainText.isEmpty }
        let coveredPages = original.structureUnitCount ?? 0
        let documentPages = max(1, documentPageCount, coveredPages)
        let placedByPage = !chunks.isEmpty
            && chunks.allSatisfy { $0.metadata.pageNumber != nil }
            && (coveredPages > 1 || coveredPages == documentPages)
        guard placedByPage else {
            let readText = chunks.isEmpty ? original.text ?? "" : chunks.map(\.plainText).joined()
            let average = letterAndDigitCount(readText) / documentPages
            return average < minimumNativeTextPerPage ? Set(renderedPages) : []
        }
        var nativeText: [Int: Int] = [:]
        for chunk in chunks {
            guard let page = chunk.metadata.pageNumber else { continue }
            nativeText[page, default: 0] += letterAndDigitCount(chunk.plainText)
        }
        let coveredAverage = nativeText.values.reduce(0, +) / coveredPages
        return Set(renderedPages.filter { page in
            (page <= coveredPages ? nativeText[page, default: 0] : coveredAverage) < minimumNativeTextPerPage
        })
    }

    /// The letters and digits a page's text layer must hold for the page to
    /// count as having text of its own. A stamp on a scanned page runs to a
    /// few dozen at most: a Bates number ("ABC000123") nine, "Page 1 of 3"
    /// seven, a fax header with its sender, number, time and page counter
    /// about seventy. Text set on the page runs to hundreds. A sparse
    /// born-digital page under the bar (a title slide) is held for the
    /// model's OCR only when that OCR fails for now, and its retry requeues
    /// nothing when it reads the same text.
    static let minimumNativeTextPerPage = 100

    private static func letterAndDigitCount(_ text: String) -> Int {
        text.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    }

    /// The image as a PNG no larger than `pagePixelSize`, upright and at 8
    /// bits per channel, for the on-device model. Nil for an image whose
    /// whole decode would need more than `ImageDecodeBudget.maxDecodedBytes`.
    private static func png(imageData: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  case .image(let image) = ImageDecodeBudget.thumbnail(of: source, maxPixelSize: pagePixelSize)
            else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    private static func analyzePixels(_ reference: VisualAttachmentReference) async throws -> VisualAttachmentAnalysisRecord? {
#if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            return try await AppleMultimodalVisualAttachmentAnalyzer().analyze(reference: reference)
        }
#endif
        return nil
    }
}
