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

/// Stops the service when a PDFKit or Vision call runs far past its budget.
/// Deadlines are checked between pages, but opening a PDF, reading one page's
/// text, rendering one page, or decoding an image and recognizing its text
/// cannot be interrupted, and a hostile file can make any of them run
/// forever. Such a call would only hold a thread and memory, so the service
/// answers the request that overran `timedOut` and exits; launchd starts a
/// fresh service for the next request.
struct PDFKitWatchdog: Sendable {
    let grace: TimeInterval
    /// Exits the service, after `overrun` has answered the request.
    let onOverrun: @Sendable () -> Void

    /// Runs `work`. When it is still running `grace` (the watchdog's own
    /// unless given) after `budget`, `overrun` answers the request it serves,
    /// and then `onOverrun` runs. The work's own reply, should it still come,
    /// is the caller's to drop.
    func run<T>(
        budget: TimeInterval,
        grace: TimeInterval? = nil,
        overrun: @escaping @Sendable () -> Void,
        _ work: () -> T
    ) -> T {
        let state = WatchdogState()
        let timer = ServiceTimer.schedule(after: budget + (grace ?? self.grace)) { [onOverrun] in
            guard state.markOverrun() else { return }
            overrun()
            onOverrun()
        }
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
