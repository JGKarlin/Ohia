import Foundation
import OSLog
import OhiaPDFParserEngine
import OhiaPDFParsing

/// `OhiaPDFParser.xpc`: reads PDF attachments, with the bundled LiteParse
/// helper and with PDFKit, and the text in images, with ImageIO and Vision,
/// inside a sandbox that has no network access and no access to Ohia's
/// shared container (see `PDFParserXPCProtocol`).
@main
struct OhiaPDFParserMain {
    static func main() {
        let logger = Logger(subsystem: "org.jgkarlin.Ohia.PDFParser", category: "Engine")
        let connections = OpenConnections()
        let service = OhiaPDFParserService(
            engine: PDFParserServiceEngine(
                runner: LiteParseHelperRunner(command: LiteParseHelperRunner.bundledCommand(in: .main)),
                // The request that overran has been answered timedOut; its
                // caller does not send it again at once. The exit waits until
                // that caller, and every other caller already given a reply,
                // has it. Requests still running fail as service-unavailable,
                // their callers re-send once, and launchd relaunches the
                // service on demand.
                onOverrun: connections.exiting(timeout: OpenConnections.overrunReceiptTimeout) { receipt in
                    logger.fault(
                        "A PDFKit or Vision call overran its budget; \(receipt.received, privacy: .public) of \(receipt.given, privacy: .public) callers given a reply closed their connections in \(receipt.milliseconds, privacy: .public) ms; exiting"
                    )
                    // `_exit`, not `exit`: the stuck call's thread is still
                    // running, and exit handlers must not wait on it.
                    _exit(EXIT_FAILURE)
                },
                // Text recognition broke in this process, and every open
                // connection has closed or is a watcher's, or the drain limit
                // passed; a reply given in its last moments is waited for
                // too. The next request, a caller's retry included, launches
                // a fresh service.
                onRetired: connections.exiting(timeout: OpenConnections.retiredReceiptTimeout) { receipt in
                    logger.fault(
                        "The retiring parser service is drained; \(receipt.received, privacy: .public) of \(receipt.given, privacy: .public) callers given a reply closed their connections in \(receipt.milliseconds, privacy: .public) ms; exiting"
                    )
                    _exit(EXIT_FAILURE)
                }
            ),
            connections: connections
        )
        let delegate = OhiaPDFParserListenerDelegate(service: service, connections: connections)
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        fatalError("NSXPCListener.service() unexpectedly returned")
    }
}

private final class OhiaPDFParserListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: OhiaPDFParserService
    private let connections: OpenConnections

    init(service: OhiaPDFParserService, connections: OpenConnections) {
        self.service = service
        self.connections = connections
        super.init()
    }

    /// Every connection is reported to the engine, so a retiring service
    /// exits only once each caller has its reply, and kept, so each of the
    /// service's exits waits for the callers already given a reply. A close
    /// reaches the receipts before the retirement, whose exit then finds the
    /// connection gone.
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let identifier = ObjectIdentifier(connection)
        let engine = service.engine
        let connections = self.connections
        connections.opened(identifier)
        engine.connectionOpened(identifier)
        connection.invalidationHandler = {
            connections.closed(identifier)
            engine.connectionClosed(identifier)
        }
        connection.exportedInterface = NSXPCInterface(with: PDFParserXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class OhiaPDFParserService: NSObject, PDFParserXPCProtocol, @unchecked Sendable {
    let engine: PDFParserServiceEngine
    private let connections: OpenConnections

    init(engine: PDFParserServiceEngine, connections: OpenConnections) {
        self.engine = engine
        self.connections = connections
    }

    /// Runs a request's work on a serial queue of its own, at the request's
    /// quality of service, rather than on its connection's queue, where NSXPC
    /// delivers it and reports the connection closing: an exit waits for
    /// that report (`OpenConnections`), which a stuck PDFKit or Vision call
    /// on the queue would hold up. Not on the global concurrent queues
    /// either: those stop starting threads once the process has a fixed
    /// number blocked (`PDFParserBlockingCall`), and the watchdog's and the
    /// drain limit's timers run there (`ServiceTimer`). A serial queue runs
    /// on an overcommit thread, which Dispatch starts even when all of its
    /// threads are blocked. The engine replies from whichever thread
    /// finishes first, the work's or the watchdog's.
    private static func perform(_ work: @escaping @Sendable () -> Void) {
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .default
        DispatchQueue(label: requestQueueLabel, qos: DispatchQoS(qosClass: qos, relativePriority: 0))
            .async(execute: work)
    }

    private static let requestQueueLabel = "org.jgkarlin.Ohia.PDFParser.request"

    /// The connection delivering the current request, taken while NSXPC
    /// delivers it and held until the request's reply. `OpenConnections`
    /// keys connections by identity: held, a connection that closes while
    /// its request runs cannot have its address taken by a new connection,
    /// which the late reply would then mark as given one.
    private struct Caller: @unchecked Sendable {
        let connection: NSXPCConnection?
        var identifier: ObjectIdentifier? { connection.map(ObjectIdentifier.init) }
    }

    private static var caller: Caller {
        Caller(connection: NSXPCConnection.current())
    }

    func parse(
        _ pdf: Data,
        maxPages: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Int32, String?) -> Void
    ) {
        let engine = engine
        let connections = connections
        let caller = Self.caller
        Self.perform {
            engine.parse(pdf, maxPages: maxPages) { result in
                connections.replying(on: caller.identifier)
                reply(result.output, result.outcome.rawValue, result.status, result.stderr)
            }
        }
    }

    func renderPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        withReply reply: @escaping @Sendable (Data?, Int) -> Void
    ) {
        let engine = engine
        let connections = connections
        let caller = Self.caller
        Self.perform {
            engine.renderPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize) { result in
                connections.replying(on: caller.identifier)
                reply(result.wireOutput, result.outcome.rawValue)
            }
        }
    }

    func recognizeText(
        _ image: Data,
        withReply reply: @escaping @Sendable (Data?, Int, String?) -> Void
    ) {
        let engine = engine
        let connections = connections
        let caller = Self.caller
        Self.perform {
            engine.recognizeText(image) { result in
                connections.replying(on: caller.identifier)
                reply(result.wireOutput, result.outcome.rawValue, result.detail)
            }
        }
    }

    /// Runs on the acknowledging caller's connection, which
    /// `NSXPCConnection.current()` names. The connection stops awaiting
    /// receipt first: the retirement's exit may follow at once, and must not
    /// wait for a caller that has its reply.
    func acknowledgeBrokenRecognizer() {
        let caller = Self.caller.identifier
        connections.watching(caller)
        engine.acknowledgeBrokenRecognizer(from: caller)
    }

#if DEBUG
    func armBrokenRecognizerForTesting(withReply reply: @escaping @Sendable () -> Void) {
        engine.armBrokenRecognizerForTesting()
        connections.replying(on: Self.caller.identifier)
        reply()
    }

    func armRecognitionOverrunForTesting(
        after seconds: Double,
        forImage image: Data,
        withReply reply: @escaping @Sendable () -> Void
    ) {
        engine.armRecognitionOverrunForTesting(after: seconds, forImage: image)
        connections.replying(on: Self.caller.identifier)
        reply()
    }

    func probeRecognizerForTesting(withReply reply: @escaping @Sendable (Bool) -> Void) {
        let engine = engine
        let connections = connections
        let caller = Self.caller
        Self.perform {
            engine.probeRecognizerForTesting { works in
                connections.replying(on: caller.identifier)
                reply(works)
            }
        }
    }
#endif
}
