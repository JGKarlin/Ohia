import AppKit
import Foundation
import OhiaPDFParsing
import PDFKit

/// The only code in Ohia that opens a PDF with PDFKit. It is linked into
/// `OhiaPDFParser.xpc` alone (see `PDFParserServiceEngine`), so an untrusted
/// PDF never reaches PDFKit in the app or a worker.
enum PDFKitDocumentReader {
    enum TextResult: Equatable {
        /// Each page's text, possibly stopping short of the page count when
        /// the page limit or the deadline was reached.
        case read(PDFKitTextOutput)
        /// PDFKit could not open the PDF.
        case unopenable
        /// The deadline passed before a single page was read.
        case timedOut
    }

    enum RenderResult: Equatable {
        case rendered(PDFPageRenderOutput)
        case unreadable
        case timedOut
    }

    /// Each page's text, up to `maxPages` pages or until `deadline`, which is
    /// checked between pages.
    static func text(of pdf: Data, maxPages: Int, deadline: Date) -> TextResult {
        guard let document = PDFDocument(data: pdf) else { return .unopenable }
        guard !document.isLocked else {
            return .read(PDFKitTextOutput(pageCount: document.pageCount, isLocked: true, pages: []))
        }
        let pageLimit = min(document.pageCount, maxPages)
        var pages: [PDFKitTextOutput.Page] = []
        for index in 0..<pageLimit {
            guard Date() < deadline else { break }
            let page = autoreleasepool { () -> PDFKitTextOutput.Page in
                let pdfPage = document.page(at: index)
                let bounds = pdfPage?.bounds(for: .mediaBox) ?? .zero
                return PDFKitTextOutput.Page(
                    width: Double(bounds.width),
                    height: Double(bounds.height),
                    text: pdfPage?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            }
            pages.append(page)
        }
        if pages.isEmpty, pageLimit > 0 { return .timedOut }
        return .read(PDFKitTextOutput(pageCount: document.pageCount, isLocked: false, pages: pages))
    }

    /// Up to `maxPages` pages spread across the document, each as a PNG no
    /// larger than `maxPixelSize` on either side, rendered until `deadline`,
    /// which is checked between pages.
    static func render(_ pdf: Data, maxPages: Int, maxPixelSize: Int, deadline: Date) -> RenderResult {
        guard let document = PDFDocument(data: pdf), !document.isLocked else { return .unreadable }
        var pages: [PDFPageRenderOutput.Page] = []
        var ranOutOfTime = false
        for index in PDFPageSelection.spread(pageCount: document.pageCount, maximum: maxPages) {
            guard Date() < deadline else {
                ranOutOfTime = true
                break
            }
            guard let page = document.page(at: index),
                  let png = png(of: page, maxPixelSize: maxPixelSize) else { continue }
            pages.append(PDFPageRenderOutput.Page(index: index, png: png))
        }
        guard !pages.isEmpty else { return ranOutOfTime ? .timedOut : .unreadable }
        return .rendered(PDFPageRenderOutput(pageCount: document.pageCount, pages: pages))
    }

    private static func png(of page: PDFPage, maxPixelSize: Int) -> Data? {
        autoreleasepool {
            let side = CGFloat(maxPixelSize)
            let image = page.thumbnail(of: NSSize(width: side, height: side), for: .cropBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
    }
}

/// Stops the service when a PDFKit call runs far past its budget. Deadlines
/// are checked between pages, but opening a PDF, reading one page's text or
/// rendering one page cannot be interrupted, and a hostile PDF can make any
/// of them run forever. Once the caller has stopped waiting, such a call
/// would only hold a thread and memory, so the service exits instead and
/// launchd starts a fresh one for the next request.
struct PDFKitWatchdog: Sendable {
    let grace: TimeInterval
    let onOverrun: @Sendable () -> Void

    func run<T>(budget: TimeInterval, _ work: () -> T) -> T {
        let state = WatchdogState()
        let timer = DispatchWorkItem {
            if state.markOverrun() { onOverrun() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget + grace, execute: timer)
        defer {
            state.markFinished()
            timer.cancel()
        }
        return work()
    }
}

/// Whichever happens first, the work finishing or the timer firing, decides.
private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func markFinished() {
        lock.withLock { settled = true }
    }

    func markOverrun() -> Bool {
        lock.withLock {
            guard !settled else { return false }
            settled = true
            return true
        }
    }
}
