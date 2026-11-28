import Foundation
import OhiaCore
import OhiaPDFParsing

/// A worker's route to `OhiaPDFParser.xpc`: the PDF or image goes to the app
/// over the worker's broker connection, the app relays it to the sandboxed
/// service (`PDFParserRelay`), and the reply comes back the same way.
public final class WorkerPDFParserClient: Sendable {
    public typealias RequestHandler = @Sendable (
        Data,
        Int,
        @escaping @Sendable (PDFParserReply) -> Void
    ) -> Void
    public typealias RenderHandler = @Sendable (
        Data,
        Int,
        Int,
        @escaping @Sendable (PDFRenderReply) -> Void
    ) -> Void
    public typealias RecognizeHandler = @Sendable (
        Data,
        @escaping @Sendable (TextRecognitionReply) -> Void
    ) -> Void

    private let requestHandler: RequestHandler
    private let renderHandler: RenderHandler
    private let recognizeHandler: RecognizeHandler
    private let timeout: TimeInterval
    private let renderTimeout: TimeInterval
    private let recognizeTimeout: TimeInterval

    public convenience init(connection: NSXPCConnection) {
        self.init(connection: connection, timeout: Self.defaultTimeout)
    }

    convenience init(
        connection: NSXPCConnection,
        timeout: TimeInterval,
        renderTimeout: TimeInterval = WorkerPDFParserClient.defaultRenderTimeout,
        recognizeTimeout: TimeInterval = WorkerPDFParserClient.defaultRecognizeTimeout
    ) {
        let connectionBox = WorkerPDFParserConnectionBox(connection)
        self.init(
            timeout: timeout,
            renderTimeout: renderTimeout,
            recognizeTimeout: recognizeTimeout,
            renderHandler: { pdf, maxPages, maxPixelSize, reply in
                guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply(PDFRenderReply(outcome: .serviceUnavailable))
                }) as? any WorkerXPCCommandBrokerProtocol else {
                    reply(PDFRenderReply(outcome: .serviceUnavailable))
                    return
                }
                proxy.renderPDFPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize) { output, rawOutcome in
                    reply(PDFRenderReply(wireOutput: output, rawOutcome: rawOutcome))
                }
            },
            recognizeHandler: { image, reply in
                guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply(TextRecognitionReply(outcome: .serviceUnavailable))
                }) as? any WorkerXPCCommandBrokerProtocol else {
                    reply(TextRecognitionReply(outcome: .serviceUnavailable))
                    return
                }
                proxy.recognizeImageText(image) { output, rawOutcome, detail in
                    reply(TextRecognitionReply(wireOutput: output, rawOutcome: rawOutcome, detail: detail))
                }
            },
            requestHandler: { pdf, maxPages, reply in
                guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply(PDFParserReply(outcome: .serviceUnavailable))
                }) as? any WorkerXPCCommandBrokerProtocol else {
                    reply(PDFParserReply(outcome: .serviceUnavailable))
                    return
                }
                proxy.parsePDF(pdf, maxPages: maxPages) { output, rawOutcome, status, stderr in
                    reply(PDFParserReply(wireOutput: output, rawOutcome: rawOutcome, status: status, stderr: stderr))
                }
            }
        )
    }

    /// The app handles each lane's files one at a time, so a request may
    /// wait up to `relayQueueAllowance` before its own parse, render or text
    /// recognition starts. After a broken-recognizer reply the app also waits
    /// for the broken service to exit before answering.
    static let defaultTimeout = PDFParserLimits.parseClientTimeout + PDFParserLimits.relayQueueAllowance
    static let defaultRenderTimeout = PDFParserLimits.renderClientTimeout + PDFParserLimits.relayQueueAllowance
    static let defaultRecognizeTimeout = PDFParserLimits.textRecognitionClientTimeout
        + PDFParserLimits.brokenServiceExitWait
        + PDFParserLimits.relayQueueAllowance

    init(
        timeout: TimeInterval = WorkerPDFParserClient.defaultTimeout,
        renderTimeout: TimeInterval = WorkerPDFParserClient.defaultRenderTimeout,
        recognizeTimeout: TimeInterval = WorkerPDFParserClient.defaultRecognizeTimeout,
        renderHandler: @escaping RenderHandler = { _, _, _, reply in
            reply(PDFRenderReply(outcome: .serviceUnavailable))
        },
        recognizeHandler: @escaping RecognizeHandler = { _, reply in
            reply(TextRecognitionReply(outcome: .serviceUnavailable))
        },
        requestHandler: @escaping RequestHandler
    ) {
        self.timeout = timeout
        self.renderTimeout = renderTimeout
        self.recognizeTimeout = recognizeTimeout
        self.renderHandler = renderHandler
        self.recognizeHandler = recognizeHandler
        self.requestHandler = requestHandler
    }

    /// Blocks until the app replies, the connection fails, the timeout
    /// passes, or the calling task is cancelled (`PDFParserWait`). Callers
    /// run off the main actor: background extraction and the Composer web
    /// crawl.
    public func parse(_ pdf: Data, maxPages: Int) -> PDFParserReply {
        PDFParserWait.wait(
            timeout: timeout,
            unavailable: PDFParserReply(outcome: .serviceUnavailable),
            cancelled: PDFParserReply(outcome: .cancelled),
            timedOut: PDFParserReply(outcome: .timedOut)
        ) { complete in
            requestHandler(pdf, maxPages, complete)
        }
    }

    /// Renders pages, waiting the same way as `parse`.
    public func renderPages(_ pdf: Data, maxPages: Int, maxPixelSize: Int) -> PDFRenderReply {
        PDFParserWait.wait(
            timeout: renderTimeout,
            unavailable: PDFRenderReply(outcome: .serviceUnavailable),
            cancelled: PDFRenderReply(outcome: .cancelled),
            timedOut: PDFRenderReply(outcome: .timedOut)
        ) { complete in
            renderHandler(pdf, maxPages, maxPixelSize, complete)
        }
    }

    /// Recognizes an image's text, waiting the same way as `parse`.
    public func recognizeText(_ image: Data) -> TextRecognitionReply {
        PDFParserWait.wait(
            timeout: recognizeTimeout,
            unavailable: TextRecognitionReply(outcome: .serviceUnavailable),
            cancelled: TextRecognitionReply(outcome: .cancelled),
            timedOut: TextRecognitionReply(outcome: .timedOut)
        ) { complete in
            recognizeHandler(image, complete)
        }
    }
}

private final class WorkerPDFParserConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}
