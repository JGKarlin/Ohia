import Foundation
import OSLog
import OhiaPDFParserEngine
import OhiaPDFParsing

/// `OhiaPDFParser.xpc`: reads PDF attachments, with the bundled LiteParse
/// helper and with PDFKit, inside a sandbox that has no network access and no
/// access to Ohia's shared container (see `PDFParserXPCProtocol`).
@main
struct OhiaPDFParserMain {
    static func main() {
        let service = OhiaPDFParserService(
            engine: PDFParserServiceEngine(
                runner: LiteParseHelperRunner(command: LiteParseHelperRunner.bundledCommand(in: .main)),
                onPDFKitOverrun: {
                    // Requests still in flight fail as service-unavailable and
                    // are retried; launchd relaunches the service on demand.
                    Logger(subsystem: "org.jgkarlin.Ohia.PDFParser", category: "Engine")
                        .fault("A PDFKit call overran its budget; exiting the PDF parser service")
                    exit(EXIT_FAILURE)
                }
            )
        )
        let delegate = OhiaPDFParserListenerDelegate(service: service)
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        fatalError("NSXPCListener.service() unexpectedly returned")
    }
}

private final class OhiaPDFParserListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: OhiaPDFParserService

    init(service: OhiaPDFParserService) {
        self.service = service
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PDFParserXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class OhiaPDFParserService: NSObject, PDFParserXPCProtocol, @unchecked Sendable {
    private let engine: PDFParserServiceEngine

    init(engine: PDFParserServiceEngine) {
        self.engine = engine
    }

    func parse(
        _ pdf: Data,
        maxPages: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Int32, String?) -> Void
    ) {
        let result = engine.parse(pdf, maxPages: maxPages)
        reply(result.output, result.outcome.rawValue, result.status, result.stderr)
    }

    func renderPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        withReply reply: @escaping @Sendable (Data?, Int) -> Void
    ) {
        let result = engine.renderPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize)
        reply(result.wireOutput, result.outcome.rawValue)
    }
}
