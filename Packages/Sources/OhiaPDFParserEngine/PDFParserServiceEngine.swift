import Foundation
import OSLog
import OhiaPDFParsing

private let engineLogger = Logger(subsystem: "org.jgkarlin.Ohia.PDFParser", category: "Engine")

/// What `OhiaPDFParser.xpc` does with each request. Only the service's
/// executable depends on this target, so PDFKit and the LiteParse helper read
/// untrusted PDFs in the service's sandbox and nowhere else.
public struct PDFParserServiceEngine: Sendable {
    public let runner: LiteParseHelperRunner
    public let fallbackTimeout: TimeInterval
    public let renderTimeout: TimeInterval
    let watchdog: PDFKitWatchdog

    /// `onPDFKitOverrun` runs when a PDFKit call is still going
    /// `PDFParserLimits.pdfKitOverrunGrace` after its budget; the service
    /// passes a function that exits the process.
    public init(
        runner: LiteParseHelperRunner,
        fallbackTimeout: TimeInterval = PDFParserLimits.fallbackTimeout,
        renderTimeout: TimeInterval = PDFParserLimits.renderTimeout,
        overrunGrace: TimeInterval = PDFParserLimits.pdfKitOverrunGrace,
        onPDFKitOverrun: @escaping @Sendable () -> Void = {}
    ) {
        self.runner = runner
        self.fallbackTimeout = fallbackTimeout
        self.renderTimeout = renderTimeout
        self.watchdog = PDFKitWatchdog(grace: overrunGrace, onOverrun: onPDFKitOverrun)
    }

    /// Parses with LiteParse. When LiteParse fails, or succeeds without
    /// finding any text, PDFKit reads each page's text instead and the reply
    /// is `.pdfKitText`. When PDFKit cannot open the PDF either, LiteParse's
    /// reply stands; when PDFKit runs out of time before reading a page, the
    /// reply is `.timedOut`, so the parse can be retried.
    public func parse(_ pdf: Data, maxPages: Int) -> PDFParserReply {
        guard !pdf.isEmpty, pdf.count <= PDFParserLimits.maxInputBytes else {
            return PDFParserReply(outcome: .invalidRequest)
        }
        let liteParse = runner.parse(pdf, maxPages: maxPages)
        switch liteParse.outcome {
        case .parsed:
            guard let output = liteParse.output, !LiteParseOutput.hasText(output) else { return liteParse }
        case .invalidRequest, .serviceUnavailable, .cancelled, .pdfKitText:
            return liteParse
        case .helperUnavailable, .outputTooLarge, .timedOut, .processFailed, .launchFailed:
            break
        }
        engineLogger.notice(
            "LiteParse gave no text outcome=\(String(describing: liteParse.outcome), privacy: .public) status=\(liteParse.status, privacy: .public); reading text with PDFKit"
        )
        let pages = min(max(1, maxPages), PDFParserLimits.maxPages)
        let deadline = Date().addingTimeInterval(fallbackTimeout)
        let result = watchdog.run(budget: fallbackTimeout) {
            PDFKitDocumentReader.text(of: pdf, maxPages: pages, deadline: deadline)
        }
        switch result {
        case .unopenable:
            return liteParse
        case .timedOut:
            return PDFParserReply(outcome: .timedOut, status: liteParse.status, stderr: liteParse.stderr)
        case .read(let text):
            guard let output = try? JSONEncoder().encode(text) else { return liteParse }
            guard output.count <= runner.maxOutputBytes else {
                return PDFParserReply(outcome: .outputTooLarge, status: liteParse.status, stderr: liteParse.stderr)
            }
            return PDFParserReply(
                outcome: .pdfKitText,
                output: output,
                status: liteParse.status,
                stderr: liteParse.stderr
            )
        }
    }

    /// Renders pages as PNG images. Page and size requests are clamped to
    /// `PDFParserLimits`.
    public func renderPages(_ pdf: Data, maxPages: Int, maxPixelSize: Int) -> PDFRenderReply {
        guard !pdf.isEmpty, pdf.count <= PDFParserLimits.maxInputBytes else {
            return PDFRenderReply(outcome: .invalidRequest)
        }
        let pages = min(max(1, maxPages), PDFParserLimits.maxRenderPages)
        let pixels = min(max(64, maxPixelSize), PDFParserLimits.maxRenderPixelSize)
        let deadline = Date().addingTimeInterval(renderTimeout)
        let result = watchdog.run(budget: renderTimeout) {
            PDFKitDocumentReader.render(pdf, maxPages: pages, maxPixelSize: pixels, deadline: deadline)
        }
        switch result {
        case .unreadable:
            return PDFRenderReply(outcome: .unreadable)
        case .timedOut:
            return PDFRenderReply(outcome: .timedOut)
        case .rendered(let output):
            guard output.pages.reduce(0, { $0 + $1.png.count }) <= runner.maxOutputBytes else {
                return PDFRenderReply(outcome: .outputTooLarge)
            }
            return PDFRenderReply(outcome: .rendered, output: output)
        }
    }
}

/// Whether LiteParse's JSON holds any text: in the document, a page, or one
/// of a page's text items. JSON that does not decode counts as none.
enum LiteParseOutput {
    private struct Document: Decodable {
        struct Page: Decodable {
            struct Item: Decodable {
                let text: String?
            }

            let text: String?
            let textItems: [Item]?
        }

        let text: String?
        let pages: [Page]?
    }

    static func hasText(_ output: Data) -> Bool {
        guard let document = try? JSONDecoder().decode(Document.self, from: output) else { return false }
        func meaningful(_ text: String?) -> Bool {
            !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if meaningful(document.text) { return true }
        return (document.pages ?? []).contains { page in
            meaningful(page.text) || (page.textItems ?? []).contains { meaningful($0.text) }
        }
    }
}
