import Foundation

/// The contract between Ohia and its PDF parsing service, which also reads
/// the text in images.
///
/// PDF and image attachments arrive from anyone who can send mail. Ohia reads
/// PDFs, and the text in images, only inside `OhiaPDFParser.xpc`, a service
/// whose sandbox has no network access and no access to Ohia's shared
/// container: the bundled LiteParse helper (Node.js with JIT, plus native
/// PDFium) parses PDFs there, and PDFKit, too, opens them only there, for the
/// text when LiteParse fails and to render pages as images. For text
/// recognition ImageIO decodes images and Vision reads them there as well. A
/// parser compromise is confined to the file it was handed: it can neither
/// read the mail store nor send anything off the Mac. Callers get back only
/// JSON text and PNG images.
@objc(OhiaPDFParserXPCProtocol)
public protocol PDFParserXPCProtocol {
    /// Parses one PDF. The reply carries the output (LiteParse's JSON for
    /// `PDFParserOutcome.parsed`, a `PDFKitTextOutput` for `.pdfKitText`),
    /// the outcome's raw value, the helper's exit status, and the start of
    /// its standard error.
    func parse(
        _ pdf: Data,
        maxPages: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Int32, String?) -> Void
    )

    /// Renders up to `maxPages` pages, spread across the document, as PNG
    /// images no larger than `maxPixelSize` on either side. The reply carries
    /// `PDFRenderReply.wireOutput` and the outcome's raw value.
    func renderPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        withReply reply: @escaping @Sendable (Data?, Int) -> Void
    )

    /// Recognizes the text in one image. The reply carries
    /// `TextRecognitionReply.wireOutput`, the outcome's raw value, and the
    /// reply's detail. A service whose recognizer broke replies
    /// `.recognizerUnavailable`, to this request and to every image after it,
    /// and exits once every open connection has closed or belongs to a
    /// caller that acknowledged that reply (`acknowledgeBrokenRecognizer`),
    /// or at the drain limit. A recognition that overruns is answered
    /// `.timedOut` before the service exits.
    func recognizeText(
        _ image: Data,
        withReply reply: @escaping @Sendable (Data?, Int, String?) -> Void
    )

    /// Sent on the same connection by a caller that received
    /// `.recognizerUnavailable`: it has its reply and keeps the connection
    /// open only to see the service exit, so the connection no longer holds
    /// the exit up. The caller's retry then reaches a fresh process. A service
    /// whose recognizer works ignores it.
    func acknowledgeBrokenRecognizer()

#if DEBUG
    /// Debug builds only, so mail content can never reach it: arms the
    /// service so that Vision's recognition fails from now on as a broken
    /// recognizer's does, for app-hosted tests of the reply, retirement,
    /// exit and retry path. Only the app that embeds the service can connect
    /// to it. Replies once armed.
    func armBrokenRecognizerForTesting(withReply reply: @escaping @Sendable () -> Void)

    /// Debug builds only: arms the service so that its next recognition of
    /// exactly `image` runs until the watchdog stops it, `seconds` after it
    /// starts, for app-hosted tests of the overrun reply and exit. The image
    /// is the marker the test's own request carries: any other image, such
    /// as one the test host's background work sends, is recognized as usual.
    /// Replies once armed.
    func armRecognitionOverrunForTesting(
        after seconds: Double,
        forImage image: Data,
        withReply reply: @escaping @Sendable () -> Void
    )

    /// Debug builds only: whether the service's recognizer reads its
    /// built-in probe image, the check that decides a Vision error that does
    /// not name the image (`ImageTextRecognizer.probe`), run inside the
    /// sandbox under the watchdog.
    func probeRecognizerForTesting(withReply reply: @escaping @Sendable (Bool) -> Void)
#endif
}

public enum PDFParserOutcome: Int, Sendable, Equatable {
    case parsed = 0
    /// The helper is not bundled with this build.
    case helperUnavailable = 1
    /// The PDF was empty or larger than `PDFParserLimits.maxInputBytes`.
    case invalidRequest = 2
    /// The output exceeded `PDFParserLimits.maxOutputBytes`.
    case outputTooLarge = 3
    /// LiteParse or PDFKit ran out of time, a PDFKit call overran and the
    /// service exited over it, or the caller stopped waiting. Not sent again
    /// at once; a later attempt may parse the PDF.
    case timedOut = 4
    case processFailed = 5
    case launchFailed = 6
    /// The XPC service could not be reached or dropped the request.
    case serviceUnavailable = 7
    /// The caller's task was cancelled while it waited. Produced on the
    /// caller's side only; the service never sends it.
    case cancelled = 8
    /// LiteParse could not parse the PDF, so the service read each page's
    /// text with PDFKit instead. The output is a `PDFKitTextOutput` as JSON;
    /// the status and standard error are LiteParse's.
    case pdfKitText = 9
}

public struct PDFParserReply: Sendable, Equatable {
    public let outcome: PDFParserOutcome
    public let output: Data?
    public let status: Int32
    public let stderr: String

    public init(outcome: PDFParserOutcome, output: Data? = nil, status: Int32 = 0, stderr: String = "") {
        self.outcome = outcome
        self.output = outcome.carriesOutput ? output : nil
        self.status = status
        self.stderr = stderr
    }

    /// A reply as it arrives over XPC. An outcome this build does not know
    /// is treated as the service being unavailable.
    public init(wireOutput: Data?, rawOutcome: Int, status: Int32, stderr: String?) {
        self.init(
            outcome: PDFParserOutcome(rawValue: rawOutcome) ?? .serviceUnavailable,
            output: wireOutput,
            status: status,
            stderr: String((stderr ?? "").prefix(PDFParserLimits.maxStderrBytes))
        )
    }
}

extension PDFParserOutcome {
    var carriesOutput: Bool {
        self == .parsed || self == .pdfKitText
    }
}

/// PDFKit's reading of a PDF that LiteParse could not parse: each page's
/// size and plain text. Pages may stop short of `pageCount` when the page
/// limit or the time allowed for the fallback ran out.
public struct PDFKitTextOutput: Codable, Sendable, Equatable {
    public struct Page: Codable, Sendable, Equatable {
        public let width: Double
        public let height: Double
        public let text: String

        public init(width: Double, height: Double, text: String) {
            self.width = width
            self.height = height
            self.text = text
        }
    }

    public let pageCount: Int
    /// The PDF is encrypted and needs a password to open; `pages` is empty.
    public let isLocked: Bool
    public let pages: [Page]

    public init(pageCount: Int, isLocked: Bool, pages: [Page]) {
        self.pageCount = pageCount
        self.isLocked = isLocked
        self.pages = pages
    }
}

/// How the app and the workers wait for the PDF parser service: until it
/// replies, the connection fails, the timeout passes, or the calling task is
/// cancelled (a Composer source the user removed, a worker shutting down),
/// checked every `cancellationCheckInterval`: the task itself when the wait
/// runs on one, or the async caller of `PDFParserBlockingCall` when the wait
/// runs on its Dispatch thread. The first reply wins: an XPC reply and a
/// connection error can both fire for one request.
public enum PDFParserWait {
    public static let cancellationCheckInterval: TimeInterval = 0.2

    public static func wait<Reply: Sendable>(
        timeout: TimeInterval,
        unavailable: Reply,
        cancelled: Reply,
        timedOut: Reply,
        send: (@escaping @Sendable (Reply) -> Void) -> Void
    ) -> Reply {
        let reply = FirstReply<Reply>()
        let done = DispatchSemaphore(value: 0)
        send { result in
            if reply.store(result) { done.signal() }
        }
        switch signal(done, timeout: timeout) {
        case .signalled:
            return reply.value ?? unavailable
        case .cancelled:
            return cancelled
        case .timedOut:
            return timedOut
        }
    }

    public enum Signal: Sendable, Equatable {
        case signalled
        case cancelled
        case timedOut
    }

    /// Waits for `semaphore` the same way: until it is signalled, the
    /// timeout passes, or the calling task is cancelled.
    public static func signal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Signal {
        let deadline = DispatchTime.now() + timeout
        while true {
            let slice = min(deadline, .now() + cancellationCheckInterval)
            if semaphore.wait(timeout: slice) == .success {
                return .signalled
            }
            if Task.isCancelled || PDFParserBlockingCall.isCurrentCallCancelled {
                return .cancelled
            }
            if DispatchTime.now() >= deadline {
                return .timedOut
            }
        }
    }
}

private final class FirstReply<Reply: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Reply?

    func store(_ value: Reply) -> Bool {
        lock.withLock {
            guard reply == nil else { return false }
            reply = value
            return true
        }
    }

    var value: Reply? {
        lock.withLock { reply }
    }
}

public enum PDFRenderOutcome: Int, Sendable, Equatable {
    case rendered = 0
    /// The PDF was empty or larger than `PDFParserLimits.maxInputBytes`.
    case invalidRequest = 1
    /// PDFKit could not open the PDF, it needs a password, or no page could
    /// be rendered.
    case unreadable = 2
    /// The rendered pages exceeded `PDFParserLimits.maxOutputBytes`.
    case outputTooLarge = 3
    /// Rendering ran out of time, a PDFKit call overran and the service
    /// exited over it, or the caller stopped waiting. Not sent again at once.
    case timedOut = 4
    /// The XPC service could not be reached, dropped the request, or sent a
    /// reply that does not decode.
    case serviceUnavailable = 5
    /// The caller's task was cancelled while it waited. Produced on the
    /// caller's side only; the service never sends it.
    case cancelled = 6
}

/// Pages rendered as PNG images, each with its zero-based index in the PDF.
public struct PDFPageRenderOutput: Codable, Sendable, Equatable {
    public struct Page: Codable, Sendable, Equatable {
        public let index: Int
        public let png: Data

        public init(index: Int, png: Data) {
            self.index = index
            self.png = png
        }
    }

    public let pageCount: Int
    public let pages: [Page]

    public init(pageCount: Int, pages: [Page]) {
        self.pageCount = pageCount
        self.pages = pages
    }

    /// At most `maxRenderPages` pages, each a page the PDF has, none twice.
    /// Decoded from another process, so no value may be assumed sane: a
    /// negative page count must not form a range.
    var isWellFormed: Bool {
        pageCount >= 0
            && pages.count <= PDFParserLimits.maxRenderPages
            && pages.allSatisfy { $0.index >= 0 && $0.index < pageCount }
            && Set(pages.map(\.index)).count == pages.count
    }
}

public struct PDFRenderReply: Sendable, Equatable {
    public let outcome: PDFRenderOutcome
    public let output: PDFPageRenderOutput?

    public init(outcome: PDFRenderOutcome, output: PDFPageRenderOutput? = nil) {
        if outcome == .rendered, output == nil {
            self.outcome = .serviceUnavailable
            self.output = nil
        } else {
            self.outcome = outcome
            self.output = outcome == .rendered ? output : nil
        }
    }

    /// The output as it crosses XPC: a binary property list, so the PNG
    /// bytes travel as they are.
    public var wireOutput: Data? {
        guard let output else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(output)
    }

    /// A reply as it arrives over XPC. An unknown outcome, or rendered pages
    /// that do not decode or name pages the PDF does not have, are treated as
    /// the service being unavailable.
    public init(wireOutput: Data?, rawOutcome: Int) {
        guard let outcome = PDFRenderOutcome(rawValue: rawOutcome) else {
            self.init(outcome: .serviceUnavailable)
            return
        }
        guard outcome == .rendered else {
            self.init(outcome: outcome)
            return
        }
        guard let wireOutput,
              let output = try? PropertyListDecoder().decode(PDFPageRenderOutput.self, from: wireOutput),
              output.isWellFormed else {
            self.init(outcome: .serviceUnavailable)
            return
        }
        self.init(outcome: .rendered, output: output)
    }
}

public enum PDFParserLimits {
    /// Mail providers cap messages far below this; a larger "PDF" is refused
    /// before it is written to disk.
    public static let maxInputBytes = 256 * 1024 * 1024
    public static let maxOutputBytes = 64 * 1024 * 1024
    public static let maxStderrBytes = 4 * 1024
    public static let maxPages = 1000
    public static let helperTimeout: TimeInterval = 45
    /// How long the service waits after stopping a LiteParse helper that ran
    /// past `helperTimeout`, before killing it.
    public static let helperKillGrace: TimeInterval = 4
    /// How long PDFKit may read text after LiteParse fails, checked between
    /// pages.
    public static let fallbackTimeout: TimeInterval = 15
    /// How long rendering may take, checked between pages.
    public static let renderTimeout: TimeInterval = 30
    /// How long decoding one image and recognizing its text may take. A
    /// process's first recognition prepares Vision's models, which took 25
    /// to 52 seconds under heavy ML load.
    public static let textRecognitionTimeout: TimeInterval = 90
    /// How large a copy of an image is decoded for text recognition, in
    /// bytes at the image's own depth (`ImageDecodeBudget`); a larger image is
    /// decoded straight to a smaller copy of that size, its aspect ratio
    /// kept. An image whose whole decode would need more than
    /// `ImageDecodeBudget.maxDecodedBytes` is refused. Vision's accurate
    /// recognizer works at its own internal scale: measured on macOS 27, it
    /// read text down to about 1/190 of the image's long side at every input
    /// size, read none at 1/230 at any size, and returned the same lines
    /// after scaling A4 pages of 6- and 8-point text from 35 megapixels to 6,
    /// and an 8,000-pixel square to 2,000. 64 MiB is 2^24 pixels of an 8-bit
    /// image (a 4,096-pixel square), 2^23 of a 16-bit one (2,896) and 2^22
    /// of a floating-point one (2,048): each keeps the smallest text Vision
    /// reads at all over 10 pixels tall.
    public static let imageRecognitionBytes = 1 << 26
    /// A single PDFKit or Vision call cannot be interrupted. When one runs
    /// this long past its budget, the service answers that request
    /// `timedOut` and exits once its caller, and every caller already given a
    /// reply, has it, so the call cannot hold a thread and memory forever;
    /// launchd starts a fresh service on the next request. Only `serviceUnavailable`, which the
    /// other callers' requests cut off by the exit see, is sent again at
    /// once, so a file that overruns costs one service exit per attempt.
    public static let pdfKitOverrunGrace: TimeInterval = 10
    /// The most pages one render request returns.
    public static let maxRenderPages = 16
    /// The largest side, in pixels, a rendered page may have.
    public static let maxRenderPixelSize = 2048
    /// Extra time the client allows for launching the service and moving the
    /// PDF and its output across the connection. launchd relaunches a
    /// service that exited young about 10 seconds after its previous launch,
    /// so a request right after an exit can wait that long to start.
    public static let clientTimeoutMargin: TimeInterval = 20
    /// The longest the app waits for a parse: LiteParse, then PDFKit if
    /// LiteParse fails.
    public static let parseClientTimeout = helperTimeout + fallbackTimeout + clientTimeoutMargin
    /// The longest the app waits for a render.
    public static let renderClientTimeout = renderTimeout + clientTimeoutMargin
    /// The longest the app waits for an image's text.
    public static let textRecognitionClientTimeout = textRecognitionTimeout + clientTimeoutMargin
    /// The longest a retiring service stays up for the connections still
    /// open that are not watchers', so that a request already running when
    /// the recognizer broke does not lose its reply: as long as the longest
    /// single request may run before the watchdog stops it. A request that
    /// arrives late in this window and is still running at its end is cut
    /// off by the exit; its caller sees the service unavailable and sends it
    /// once more, to a fresh process.
    public static let brokenServiceDrainLimit = textRecognitionTimeout + pdfKitOverrunGrace
    /// The longest the app waits, after acknowledging a
    /// `.recognizerUnavailable` reply, for the broken service process to
    /// exit, so that the retry reaches a fresh one. When every other open
    /// connection is a watcher's the service exits on the acknowledgment;
    /// otherwise once those connections close, and `brokenServiceDrainLimit`
    /// after the break at the latest.
    public static let brokenServiceExitWait = brokenServiceDrainLimit + 5
    /// The longest a worker's PDF or image may wait in the app's relay
    /// before its parse, render or text recognition starts. A request that
    /// waited longer is answered `timedOut` without running, because the
    /// worker has stopped waiting. A request holds its lane until the app's
    /// client returns, at most its client timeout unless the recognizer
    /// broke: an image that overruns is answered `timedOut` by the service
    /// `textRecognitionTimeout` + `pdfKitOverrunGrace` + 0.5 s of timer
    /// leeway (100.5 s) after its recognition starts, and the client stops
    /// waiting `textRecognitionClientTimeout` (110 s) after sending it,
    /// whichever comes first; neither is sent again at once. So the request
    /// queued right behind an overrunning image waits at most 110 s and
    /// still runs; one queued behind two such images expires, and its
    /// `timedOut` is retried later like any transient failure. (A broken
    /// recognizer holds a lane for its reply plus the exit wait,
    /// `textRecognitionClientTimeout` + `brokenServiceExitWait`, 215 s at
    /// most, as before.)
    public static let relayQueueAllowance: TimeInterval = 120
}

/// Which pages to look at when only some can be: all of a short document,
/// otherwise `maximum` pages spread evenly from the first to the last.
public enum PDFPageSelection {
    public static func spread(pageCount: Int, maximum: Int) -> [Int] {
        guard pageCount > 0, maximum > 0 else { return [] }
        if pageCount <= maximum { return Array(0..<pageCount) }
        if maximum == 1 { return [0] }
        return (0..<maximum).map { $0 * (pageCount - 1) / (maximum - 1) }
    }
}
