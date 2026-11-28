import CoreGraphics
import Foundation
import ImageIO
import OSLog
import OhiaPDFParsing
import Synchronization

private let engineLogger = Logger(subsystem: "org.jgkarlin.Ohia.PDFParser", category: "Engine")

/// What `OhiaPDFParser.xpc` does with each request. Only the service's
/// executable depends on this target, so PDFKit and the LiteParse helper read
/// untrusted PDFs, and Vision recognizes text in untrusted images, in the
/// service's sandbox and nowhere else. The service reports each connection it
/// accepts and each that closes (`connectionOpened`, `connectionClosed`), so a
/// service whose recognizer broke can retire without cutting off any caller
/// (`ServiceRetirement`).
///
/// Each request hands its reply to a function, at most once. When a PDFKit
/// or Vision call overruns (`PDFKitWatchdog`), that request is answered
/// `timedOut` before the service exits, so its caller sees a timeout, which
/// it does not send again at once; only the other callers' requests in
/// flight, cut off by the exit, see the service unavailable.
public struct PDFParserServiceEngine: Sendable {
    /// Reads every line of text in a decoded, upright image; throws Vision's
    /// error.
    typealias TextRecognizer = @Sendable (_ image: CGImage) throws -> [RecognizedTextLine]
    /// PDFKit's text of each page until a deadline (`PDFKitDocumentReader.text`).
    typealias PDFKitText = @Sendable (_ pdf: Data, _ maxPages: Int, _ deadline: Date) -> PDFKitDocumentReader.TextResult
    /// PDFKit's page renders until a deadline (`PDFKitDocumentReader.render`).
    typealias PDFKitRender = @Sendable (
        _ pdf: Data,
        _ maxPages: Int,
        _ maxPixelSize: Int,
        _ deadline: Date
    ) -> PDFKitDocumentReader.RenderResult

    public let runner: LiteParseHelperRunner
    public let fallbackTimeout: TimeInterval
    public let renderTimeout: TimeInterval
    public let textRecognitionTimeout: TimeInterval
    let watchdog: PDFKitWatchdog
    let pdfKitText: PDFKitText
    let pdfKitRender: PDFKitRender
    let recognizer: TextRecognizer
    /// Whether the recognizer still reads text, asked after a Vision error
    /// that does not name the image (`ImageTextRecognizer.failure(of:recognizerWorks:)`).
    let recognizerWorks: @Sendable () -> Bool
    let retirement: ServiceRetirement
#if DEBUG
    let testHooks = TextRecognitionTestHookState()
#endif

    /// `onOverrun` runs when a PDFKit or Vision call is still going
    /// `PDFParserLimits.pdfKitOverrunGrace` after its budget, once the
    /// request that overran has been answered `timedOut`.
    /// `onRetired` runs, once, when every open connection of a service whose
    /// recognizer broke has closed or is a watcher's, or `drainLimit` after
    /// the break. For each the service passes a function that waits until
    /// the callers given a reply have it (`OpenConnections.exiting`) and
    /// exits the process.
    public init(
        runner: LiteParseHelperRunner,
        fallbackTimeout: TimeInterval = PDFParserLimits.fallbackTimeout,
        renderTimeout: TimeInterval = PDFParserLimits.renderTimeout,
        textRecognitionTimeout: TimeInterval = PDFParserLimits.textRecognitionTimeout,
        overrunGrace: TimeInterval = PDFParserLimits.pdfKitOverrunGrace,
        drainLimit: TimeInterval = PDFParserLimits.brokenServiceDrainLimit,
        onOverrun: @escaping @Sendable () -> Void = {},
        onRetired: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            runner: runner,
            fallbackTimeout: fallbackTimeout,
            renderTimeout: renderTimeout,
            textRecognitionTimeout: textRecognitionTimeout,
            overrunGrace: overrunGrace,
            recognizer: ImageTextRecognizer.recognize,
            retirement: ServiceRetirement(drainLimit: drainLimit, exit: onRetired),
            onOverrun: onOverrun
        )
    }

    /// For tests, with seams for PDFKit and Vision. `recognizerWorks`
    /// defaults to reading `ImageTextRecognizer`'s probe image with
    /// `recognizer`.
    init(
        runner: LiteParseHelperRunner,
        fallbackTimeout: TimeInterval = PDFParserLimits.fallbackTimeout,
        renderTimeout: TimeInterval = PDFParserLimits.renderTimeout,
        textRecognitionTimeout: TimeInterval = PDFParserLimits.textRecognitionTimeout,
        overrunGrace: TimeInterval = PDFParserLimits.pdfKitOverrunGrace,
        pdfKitText: @escaping PDFKitText = { PDFKitDocumentReader.text(of: $0, maxPages: $1, deadline: $2) },
        pdfKitRender: @escaping PDFKitRender = {
            PDFKitDocumentReader.render($0, maxPages: $1, maxPixelSize: $2, deadline: $3)
        },
        recognizer: @escaping TextRecognizer,
        recognizerWorks: (@Sendable () -> Bool)? = nil,
        retirement: ServiceRetirement = ServiceRetirement(exit: {}),
        onOverrun: @escaping @Sendable () -> Void = {}
    ) {
        self.runner = runner
        self.fallbackTimeout = fallbackTimeout
        self.renderTimeout = renderTimeout
        self.textRecognitionTimeout = textRecognitionTimeout
        self.watchdog = PDFKitWatchdog(grace: overrunGrace, onOverrun: onOverrun)
        self.pdfKitText = pdfKitText
        self.pdfKitRender = pdfKitRender
        self.recognizer = recognizer
        self.recognizerWorks = recognizerWorks ?? { ImageTextRecognizer.probe(using: recognizer) }
        self.retirement = retirement
    }

    // MARK: Connections

    /// The service accepted a connection. A retiring service waits for it.
    public func connectionOpened(_ caller: ObjectIdentifier) {
        retirement.opened(caller)
    }

    /// A connection closed: its caller has its replies.
    public func connectionClosed(_ caller: ObjectIdentifier) {
        retirement.closed(caller)
    }

    /// Parses with LiteParse. When LiteParse fails, or succeeds without
    /// finding any text, PDFKit reads each page's text instead and the reply
    /// is `.pdfKitText`. When PDFKit cannot open the PDF either, LiteParse's
    /// reply stands; when PDFKit runs out of time before reading a page, or
    /// overruns, the reply is `.timedOut`, so the parse can be retried later.
    public func parse(_ pdf: Data, maxPages: Int, reply: @escaping @Sendable (PDFParserReply) -> Void) {
        let reply = ReplyOnce(reply)
        reply(parseReply(pdf, maxPages: maxPages, reply: reply))
    }

    /// Renders pages as PNG images. Page and size requests are clamped to
    /// `PDFParserLimits`. A render that overruns is answered `.timedOut`.
    public func renderPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        reply: @escaping @Sendable (PDFRenderReply) -> Void
    ) {
        let reply = ReplyOnce(reply)
        reply(renderReply(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize, reply: reply))
    }

    /// Recognizes the text in one image and hands the reply to `reply`.
    /// When Vision's recognizer breaks, the service retires before replying
    /// `.recognizerUnavailable`: it keeps serving PDFs, answers every later
    /// image `.recognizerUnavailable` at once without calling Vision, and
    /// exits once every open connection has closed or belongs to a watcher
    /// (`ServiceRetirement`). A request that arrives late in that window and
    /// is still running at the drain limit is cut off by the exit; its
    /// caller sees the service unavailable and sends it once more, to a
    /// fresh process (`ImageTextRecognition.recognize`). A recognition that
    /// overruns is answered `.timedOut`.
    public func recognizeText(_ image: Data, reply: @escaping @Sendable (TextRecognitionReply) -> Void) {
        let reply = ReplyOnce(reply)
        reply(textRecognition(of: image, reply: reply))
    }

    /// `caller` received a `.recognizerUnavailable` reply and waits only for
    /// the exit, so its open connection no longer holds the exit up. Every
    /// acknowledging caller counts. A service whose recognizer works ignores
    /// it.
    public func acknowledgeBrokenRecognizer(from caller: ObjectIdentifier?) {
        guard let caller else { return }
        retirement.watch(caller)
    }

#if DEBUG
    /// Debug builds only, reached through the debug-only XPC method
    /// `PDFParserXPCProtocol.armBrokenRecognizerForTesting`: from now on
    /// Vision's recognition in this engine fails as a broken recognizer's
    /// does, the probe included, so app-hosted tests drive the real reply,
    /// retirement, exit and retry path.
    public func armBrokenRecognizerForTesting() {
        testHooks.armBrokenRecognizer()
    }

    /// Debug builds only, reached through
    /// `PDFParserXPCProtocol.armRecognitionOverrunForTesting`: the next
    /// recognition of exactly `image` runs until the watchdog stops it,
    /// `seconds` after it starts, so app-hosted tests drive the real overrun
    /// reply and exit. Any other image, such as one the test host's own
    /// background work sends meanwhile, is recognized as usual and leaves
    /// the arming in place.
    public func armRecognitionOverrunForTesting(after seconds: TimeInterval, forImage image: Data) {
        testHooks.armOverrun(after: seconds, forImage: image)
    }

    /// Debug builds only, reached through
    /// `PDFParserXPCProtocol.probeRecognizerForTesting`: the probe an
    /// unexplained Vision error runs, run on its own, under the watchdog
    /// like any Vision call. An overrun answers false.
    public func probeRecognizerForTesting(reply: @escaping @Sendable (Bool) -> Void) {
        let reply = ReplyOnce(reply)
        reply(watchdog.run(budget: textRecognitionTimeout, overrun: { reply(false) }) {
            recognizerStillWorks()
        })
    }
#endif

    // MARK: Requests

    private func parseReply(_ pdf: Data, maxPages: Int, reply: ReplyOnce<PDFParserReply>) -> PDFParserReply {
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
        let timedOut = PDFParserReply(outcome: .timedOut, status: liteParse.status, stderr: liteParse.stderr)
        let result = watchdog.run(budget: fallbackTimeout, overrun: { reply(timedOut) }) {
            pdfKitText(pdf, pages, deadline)
        }
        switch result {
        case .unopenable:
            return liteParse
        case .timedOut:
            return timedOut
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

    private func renderReply(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        reply: ReplyOnce<PDFRenderReply>
    ) -> PDFRenderReply {
        guard !pdf.isEmpty, pdf.count <= PDFParserLimits.maxInputBytes else {
            return PDFRenderReply(outcome: .invalidRequest)
        }
        let pages = min(max(1, maxPages), PDFParserLimits.maxRenderPages)
        let pixels = min(max(64, maxPixelSize), PDFParserLimits.maxRenderPixelSize)
        let deadline = Date().addingTimeInterval(renderTimeout)
        let result = watchdog.run(budget: renderTimeout, overrun: { reply(PDFRenderReply(outcome: .timedOut)) }) {
            pdfKitRender(pdf, pages, pixels, deadline)
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

    private enum Recognition {
        case recognized([RecognizedTextLine])
        case undecodable
        case tooLarge(ImageDecodeBudget.Header)
        case failed(any Error)
        case broken(any Error)
    }

    private func textRecognition(of image: Data, reply: ReplyOnce<TextRecognitionReply>) -> TextRecognitionReply {
        guard !image.isEmpty, image.count <= PDFParserLimits.maxInputBytes else {
            return TextRecognitionReply(outcome: .invalidRequest)
        }
        guard !retirement.isRetiring else {
            return TextRecognitionReply(
                outcome: .recognizerUnavailable,
                detail: "Text recognition broke in this parser service process, which is exiting"
            )
        }
#if DEBUG
        let armedOverrun = testHooks.takeArmedOverrun(for: image)
        let budget = armedOverrun?.seconds ?? textRecognitionTimeout
        let grace: TimeInterval? = armedOverrun == nil ? nil : 0
#else
        let budget = textRecognitionTimeout
        let grace: TimeInterval? = nil
#endif
        let overrunReply = TextRecognitionReply(
            outcome: .timedOut,
            detail: "Decoding the image and recognizing its text overran; the parser service is exiting"
        )
        // Decoding and recognition run under the watchdog: a hostile image
        // can make ImageIO or Vision run indefinitely, and neither can be
        // interrupted.
        let recognition = watchdog.run(budget: budget, grace: grace, overrun: {
            reply(overrunReply)
#if DEBUG
            armedOverrun?.release()
#endif
        }) { () -> Recognition in
#if DEBUG
            if let armedOverrun {
                armedOverrun.waitForOverrun()
                return .recognized([])
            }
#endif
            let decoded: CGImage
            switch ImageTextRecognizer.decode(image) {
            case .image(let image):
                decoded = image
            case .undecodable:
                return .undecodable
            case .tooLarge(let header):
                return .tooLarge(header)
            }
            do {
#if DEBUG
                if testHooks.isBrokenRecognizerArmed {
                    throw NSError(
                        domain: ImageTextRecognizer.brokenRecognizerErrorDomain,
                        code: ImageTextRecognizer.brokenRecognizerErrorCode
                    )
                }
#endif
                return .recognized(try recognizer(decoded))
            } catch {
                switch ImageTextRecognizer.failure(of: error, recognizerWorks: recognizerStillWorks) {
                case .image:
                    return .failed(error)
                case .brokenRecognizer:
                    return .broken(error)
                }
            }
        }
        switch recognition {
        case .recognized(let lines):
            guard let output = try? JSONEncoder().encode(lines) else {
                return TextRecognitionReply(outcome: .failed, detail: "The recognized text could not be encoded")
            }
            guard output.count <= runner.maxOutputBytes else {
                return TextRecognitionReply(outcome: .outputTooLarge)
            }
            return TextRecognitionReply(outcome: .recognized, lines: lines)
        case .undecodable:
            return TextRecognitionReply(outcome: .undecodable)
        case .tooLarge(let header):
            return TextRecognitionReply(
                outcome: .invalidRequest,
                detail: "The image is \(header.width) by \(header.height) pixels at up to \(header.bytesPerPixel) bytes a pixel, more than \(ImageDecodeBudget.maxDecodedBytes) bytes to decode"
            )
        case .failed(let error):
            return TextRecognitionReply(outcome: .failed, detail: error.localizedDescription)
        case .broken(let error):
            let nsError = error as NSError
            engineLogger.fault(
                "Vision's text recognizer is broken in this process errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public); retiring the parser service"
            )
            // Before the reply: once the caller has it, its acknowledgment
            // must find the service retiring.
            retirement.retire()
            return TextRecognitionReply(outcome: .recognizerUnavailable, detail: error.localizedDescription)
        }
    }

    /// The probe, except that an armed debug engine's recognizer is broken
    /// for it too.
    private func recognizerStillWorks() -> Bool {
#if DEBUG
        if testHooks.isBrokenRecognizerArmed { return false }
#endif
        return recognizerWorks()
    }
}

/// Hands a request's reply on once: the watchdog's `timedOut` or the work's
/// own, whichever comes first. An XPC reply block must not run twice.
final class ReplyOnce<Reply: Sendable>: Sendable {
    private let send: @Sendable (Reply) -> Void
    private let sent = Mutex(false)

    init(_ send: @escaping @Sendable (Reply) -> Void) {
        self.send = send
    }

    func callAsFunction(_ reply: Reply) {
        let first = sent.withLock { sent -> Bool in
            defer { sent = true }
            return !sent
        }
        if first { send(reply) }
    }
}

#if DEBUG
/// Debug builds only: what the debug-only XPC methods armed in this engine.
/// Once the recognizer is armed broken, every recognition fails as a broken
/// recognizer does, as in a real broken process. An armed overrun applies to
/// the next recognition of the image it was armed for only.
final class TextRecognitionTestHookState: Sendable {
    private struct State {
        var brokenRecognizer = false
        var overrun: ArmedOverrun?
    }

    private let state = Mutex(State())

    var isBrokenRecognizerArmed: Bool { state.withLock { $0.brokenRecognizer } }

    func armBrokenRecognizer() {
        state.withLock { $0.brokenRecognizer = true }
    }

    func armOverrun(after seconds: TimeInterval, forImage image: Data) {
        state.withLock { $0.overrun = ArmedOverrun(seconds: seconds, image: image) }
    }

    /// The armed overrun, taken, when it was armed for exactly `image`.
    func takeArmedOverrun(for image: Data) -> ArmedOverrun? {
        state.withLock { state in
            guard let overrun = state.overrun, overrun.image == image else { return nil }
            state.overrun = nil
            return overrun
        }
    }
}

/// A recognition armed to overrun: it waits until the watchdog has answered
/// it, which in the real service is followed by the exit.
final class ArmedOverrun: Sendable {
    let seconds: TimeInterval
    /// The image whose recognition overruns, the marker the test's own
    /// request carries.
    let image: Data
    private let overran = DispatchSemaphore(value: 0)

    init(seconds: TimeInterval, image: Data) {
        self.seconds = seconds
        self.image = image
    }

    func waitForOverrun() {
        _ = overran.wait(timeout: .now() + 120)
    }

    func release() {
        overran.signal()
    }
}
#endif

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
