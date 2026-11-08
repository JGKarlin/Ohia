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
/// images come back to this process.
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
        guard let original = AttachmentExtractor.extract(data: data, mimeType: mimeType, filename: filename, policy: .full) else {
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
            let reply = renderPages(data, maximumPages, pagePixelSize)
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
        let existing = original.ragDocumentJSON.flatMap { try? JSONDecoder().decode(AttachmentRAGDocument.self, from: Data($0.utf8)) }
        for (index, imageData) in rasters {
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
                guard let analysis = try await analyze(reference), analysis.hasSignals else { continue }
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
        guard !additions.isEmpty else { return original }
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
        return .completed(
            text: text, kind: original.kind, method: original.method ?? .visionSummary,
            parserVersion: "\(original.parserVersion ?? "text")+apple-pixels-v1",
            embeddingText: embedding, normalizedIRJSON: original.normalizedIRJSON,
            ragDocumentJSON: String(decoding: try JSONEncoder().encode(rag), as: UTF8.self),
            structureUnitKind: original.structureUnitKind, structureUnitCount: original.structureUnitCount ?? renderedPageCount,
            documentTitle: original.documentTitle, documentAuthor: original.documentAuthor
        )
    }

    private static func png(imageData: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pagePixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
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
