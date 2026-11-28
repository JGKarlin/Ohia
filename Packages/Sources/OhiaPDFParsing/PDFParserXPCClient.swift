import Foundation

/// Connects only to Ohia's embedded PDF parsing service. `serviceName:`
/// resolves in the containing application's private XPC namespace, whose
/// entry is the signed service bundle with this exact identifier.
public final class PDFParserXPCClient: Sendable {
    public static let serviceIdentifier = "org.jgkarlin.Ohia.PDFParser"
    public static let serviceBundleName = "OhiaPDFParser.xpc"
    static let peerCodeSigningRequirement = """
    identifier "org.jgkarlin.Ohia.PDFParser" and anchor apple generic and \
    certificate leaf[subject.OU] = "3T72U4Q7A5"
    """

    public init() {}

    /// True only in a process whose own bundle embeds the service — the Ohia
    /// app itself. Worker XPC services and test runners have no such bundle.
    public static func isEmbedded(in bundle: Bundle = .main) -> Bool {
        let service = bundle.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent(serviceBundleName, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: service.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Parses one PDF in the service and blocks until it replies, fails, the
    /// calling task is cancelled, or the time LiteParse and the PDFKit
    /// fallback may take, plus a launch margin, passes.
    public func parse(_ pdf: Data, maxPages: Int) -> PDFParserReply {
        request(
            timeout: PDFParserLimits.parseClientTimeout,
            unavailable: PDFParserReply(outcome: .serviceUnavailable),
            cancelled: PDFParserReply(outcome: .cancelled),
            timedOut: PDFParserReply(outcome: .timedOut)
        ) { parser, complete in
            parser.parse(pdf, maxPages: maxPages) { output, rawOutcome, status, stderr in
                complete(PDFParserReply(wireOutput: output, rawOutcome: rawOutcome, status: status, stderr: stderr))
            }
        }
    }

    /// Renders pages of one PDF in the service, waiting the same way as
    /// `parse`, up to the render time plus a launch margin.
    public func renderPages(_ pdf: Data, maxPages: Int, maxPixelSize: Int) -> PDFRenderReply {
        request(
            timeout: PDFParserLimits.renderClientTimeout,
            unavailable: PDFRenderReply(outcome: .serviceUnavailable),
            cancelled: PDFRenderReply(outcome: .cancelled),
            timedOut: PDFRenderReply(outcome: .timedOut)
        ) { parser, complete in
            parser.renderPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize) { output, rawOutcome in
                complete(PDFRenderReply(wireOutput: output, rawOutcome: rawOutcome))
            }
        }
    }

    /// Recognizes the text in one image in the service, waiting the same way
    /// as `parse`, up to the recognition time plus a launch margin. A
    /// `.recognizerUnavailable` reply is acknowledged, so the broken service
    /// stops waiting on this connection, and returned once that process has
    /// exited (or `brokenServiceExitWait` has passed), so a retry reaches a
    /// fresh process. A task cancelled during that wait gets `.cancelled`.
    public func recognizeText(_ image: Data) -> TextRecognitionReply {
        request(
            timeout: PDFParserLimits.textRecognitionClientTimeout,
            unavailable: TextRecognitionReply(outcome: .serviceUnavailable),
            cancelled: TextRecognitionReply(outcome: .cancelled),
            timedOut: TextRecognitionReply(outcome: .timedOut),
            releasesBrokenService: { $0.outcome == .recognizerUnavailable }
        ) { parser, complete in
            parser.recognizeText(image) { output, rawOutcome, detail in
                complete(TextRecognitionReply(wireOutput: output, rawOutcome: rawOutcome, detail: detail))
            }
        }
    }

    private func request<Reply: Sendable>(
        timeout: TimeInterval,
        unavailable: Reply,
        cancelled: Reply,
        timedOut: Reply,
        releasesBrokenService: (Reply) -> Bool = { _ in false },
        send: (any PDFParserXPCProtocol, @escaping @Sendable (Reply) -> Void) -> Void
    ) -> Reply {
        let connection = NSXPCConnection(serviceName: Self.serviceIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: PDFParserXPCProtocol.self)
        connection.setCodeSigningRequirement(Self.peerCodeSigningRequirement)
        // Called when the service process exits or crashes, after any reply
        // it sent on this connection.
        let serviceExited = DispatchSemaphore(value: 0)
        connection.interruptionHandler = { serviceExited.signal() }
        connection.resume()
        defer { connection.invalidate() }

        let reply = PDFParserWait.wait(
            timeout: timeout,
            unavailable: unavailable,
            cancelled: cancelled,
            timedOut: timedOut
        ) { complete in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in complete(unavailable) }
            guard let parser = proxy as? any PDFParserXPCProtocol else {
                complete(unavailable)
                return
            }
            send(parser, complete)
        }
        guard releasesBrokenService(reply) else { return reply }
        let exit = Self.awaitBrokenServiceExit(serviceExited, timeout: PDFParserLimits.brokenServiceExitWait) {
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
            (proxy as? any PDFParserXPCProtocol)?.acknowledgeBrokenRecognizer()
        }
        switch exit {
        case .signalled, .timedOut:
            return reply
        case .cancelled:
            return cancelled
        }
    }

    /// After a `.recognizerUnavailable` reply: acknowledges it with
    /// `acknowledge` and waits, the way `PDFParserWait` does, for the broken
    /// service process to exit, so that the caller's retry reaches a fresh
    /// one. The acknowledgment can only follow the reply, and the service
    /// retired before replying, so from then on this connection does not
    /// hold the exit up: the service exits once every other open connection
    /// has closed or is a watcher's, or at the drain limit. When the process
    /// has already exited (the drain limit, an overrun, a crash), nothing is
    /// sent: an acknowledgment would only launch a fresh service to deliver
    /// a message it ignores.
    static func awaitBrokenServiceExit(
        _ serviceExited: DispatchSemaphore,
        timeout: TimeInterval,
        acknowledge: () -> Void
    ) -> PDFParserWait.Signal {
        if serviceExited.wait(timeout: .now()) == .success { return .signalled }
        acknowledge()
        return PDFParserWait.signal(serviceExited, timeout: timeout)
    }
}
