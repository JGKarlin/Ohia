import Foundation

/// Runs worker-requested PDF parses, page renders and image text recognition
/// in the app, where `OhiaPDFParser.xpc` can be reached. Worker XPC services
/// cannot embed or look up the service themselves, so they send the PDF or
/// image to the app over their existing broker connection and the app relays
/// it here.
///
/// Each lane handles one file at a time, so bulk extraction never launches a
/// Node process per queued PDF. The two lanes are independent: the
/// generative worker's Composer sources, which the user is waiting on, never
/// queue behind the retrieval worker's background extraction. Files the app
/// reads for itself use `PDFParserXPCClient` directly and skip both lanes.
public final class PDFParserRelay: Sendable {
    public enum Lane: Sendable {
        /// Background attachment extraction (the retrieval worker).
        case background
        /// Work the user is waiting on (the generative worker's Composer
        /// sources).
        case interactive
    }

    public typealias Request = @Sendable (_ pdf: Data, _ maxPages: Int) -> PDFParserReply
    public typealias RenderRequest = @Sendable (_ pdf: Data, _ maxPages: Int, _ maxPixelSize: Int) -> PDFRenderReply

    public static let shared = PDFParserRelay()

    private let request: Request
    private let render: RenderRequest
    private let recognize: ImageTextRecognition.Recognize
    private let maxQueueWait: TimeInterval
    private let backgroundQueue = DispatchQueue(label: "org.jgkarlin.Ohia.PDFParserRelay.background", qos: .utility)
    private let interactiveQueue = DispatchQueue(label: "org.jgkarlin.Ohia.PDFParserRelay.interactive", qos: .userInitiated)

    public convenience init(client: PDFParserXPCClient = PDFParserXPCClient()) {
        self.init(
            maxQueueWait: PDFParserLimits.relayQueueAllowance,
            render: { pdf, maxPages, maxPixelSize in
                client.renderPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize)
            },
            recognize: { image in
                client.recognizeText(image)
            },
            request: { pdf, maxPages in
                client.parse(pdf, maxPages: maxPages)
            }
        )
    }

    init(
        maxQueueWait: TimeInterval,
        render: @escaping RenderRequest = { _, _, _ in PDFRenderReply(outcome: .serviceUnavailable) },
        recognize: @escaping ImageTextRecognition.Recognize = { _ in TextRecognitionReply(outcome: .serviceUnavailable) },
        request: @escaping Request
    ) {
        self.maxQueueWait = maxQueueWait
        self.render = render
        self.recognize = recognize
        self.request = request
    }

    /// Replies on the lane's queue; never blocks the caller. An empty or
    /// oversized PDF is refused before it is queued, and a request that
    /// waited past `maxQueueWait` is answered `timedOut` without running,
    /// since the worker has already given up on it.
    public func parse(
        _ pdf: Data,
        maxPages: Int,
        lane: Lane,
        reply: @escaping @Sendable (PDFParserReply) -> Void
    ) {
        guard Self.isAcceptable(pdf) else {
            reply(PDFParserReply(outcome: .invalidRequest))
            return
        }
        enqueue(on: lane) { [request] in
            reply(request(pdf, maxPages))
        } expired: {
            reply(PDFParserReply(outcome: .timedOut))
        }
    }

    /// Renders pages in the same lanes as parses, with the same refusals.
    public func renderPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        lane: Lane,
        reply: @escaping @Sendable (PDFRenderReply) -> Void
    ) {
        guard Self.isAcceptable(pdf) else {
            reply(PDFRenderReply(outcome: .invalidRequest))
            return
        }
        enqueue(on: lane) { [render] in
            reply(render(pdf, maxPages, maxPixelSize))
        } expired: {
            reply(PDFRenderReply(outcome: .timedOut))
        }
    }

    /// Recognizes an image's text in the same lanes as PDFs, with the same
    /// refusals.
    public func recognizeText(
        _ image: Data,
        lane: Lane,
        reply: @escaping @Sendable (TextRecognitionReply) -> Void
    ) {
        guard Self.isAcceptable(image) else {
            reply(TextRecognitionReply(outcome: .invalidRequest))
            return
        }
        enqueue(on: lane) { [recognize] in
            reply(recognize(image))
        } expired: {
            reply(TextRecognitionReply(outcome: .timedOut))
        }
    }

    private static func isAcceptable(_ file: Data) -> Bool {
        !file.isEmpty && file.count <= PDFParserLimits.maxInputBytes
    }

    private func enqueue(
        on lane: Lane,
        run: @escaping @Sendable () -> Void,
        expired: @escaping @Sendable () -> Void
    ) {
        let queuedAt = DispatchTime.now()
        let queue = lane == .interactive ? interactiveQueue : backgroundQueue
        queue.async { [maxQueueWait] in
            let waitedNanoseconds = DispatchTime.now().uptimeNanoseconds - queuedAt.uptimeNanoseconds
            guard TimeInterval(waitedNanoseconds) / 1_000_000_000 <= maxQueueWait else {
                expired()
                return
            }
            run()
        }
    }
}
