import Foundation

/// The contract between Ohia and its PDF parsing service.
///
/// PDF attachments arrive from anyone who can send mail. Ohia reads them only
/// inside `OhiaPDFParser.xpc`, a service whose sandbox has no network access
/// and no access to Ohia's shared container: the bundled LiteParse helper
/// (Node.js with JIT, plus native PDFium) parses them there, and PDFKit, too,
/// opens them only there, for the text when LiteParse fails and to render
/// pages as images. A parser compromise is confined to the PDF it was handed:
/// it can neither read the mail store nor send anything off the Mac. Callers
/// get back only JSON text and PNG images.
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
}

public enum PDFParserOutcome: Int, Sendable, Equatable {
    case parsed = 0
    /// The helper is not bundled with this build.
    case helperUnavailable = 1
    /// The PDF was empty or larger than `PDFParserLimits.maxInputBytes`.
    case invalidRequest = 2
    /// The output exceeded `PDFParserLimits.maxOutputBytes`.
    case outputTooLarge = 3
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
/// checked every `cancellationCheckInterval`. The first reply wins: an XPC
/// reply and a connection error can both fire for one request.
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
        let deadline = DispatchTime.now() + timeout
        while true {
            let slice = min(deadline, .now() + cancellationCheckInterval)
            if done.wait(timeout: slice) == .success {
                return reply.value ?? unavailable
            }
            if Task.isCancelled {
                return cancelled
            }
            if DispatchTime.now() >= deadline {
                return timedOut
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
    /// A single PDFKit call cannot be interrupted. When one runs this long
    /// past its budget, the service exits so the call cannot hold a thread
    /// and memory forever; launchd starts a fresh service on the next request.
    public static let pdfKitOverrunGrace: TimeInterval = 10
    /// The most pages one render request returns.
    public static let maxRenderPages = 16
    /// The largest side, in pixels, a rendered page may have.
    public static let maxRenderPixelSize = 2048
    /// Extra time the client allows for launching the service and moving the
    /// PDF and its output across the connection.
    public static let clientTimeoutMargin: TimeInterval = 20
    /// The longest the app waits for a parse: LiteParse, then PDFKit if
    /// LiteParse fails.
    public static let parseClientTimeout = helperTimeout + fallbackTimeout + clientTimeoutMargin
    /// The longest the app waits for a render.
    public static let renderClientTimeout = renderTimeout + clientTimeoutMargin
    /// The longest a worker's PDF may wait in the app's relay before its
    /// parse or render starts. A request that waited longer is answered
    /// `timedOut` without running, because the worker has stopped waiting.
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
