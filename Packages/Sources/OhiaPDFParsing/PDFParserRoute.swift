import Foundation
import Synchronization

/// How a process reaches `OhiaPDFParser.xpc`: the app calls the service it
/// embeds; a worker service, which cannot, sends each request to the app over
/// its broker connection (`PDFParserRelay`). Any other process, such as a test
/// runner, has no route, and PDFs are then not read at all: PDFKit and
/// LiteParse never open an untrusted PDF outside the service.
public enum PDFParserRoute {
    public struct Service: Sendable {
        public let parse: @Sendable (_ pdf: Data, _ maxPages: Int) -> PDFParserReply
        public let renderPages: @Sendable (_ pdf: Data, _ maxPages: Int, _ maxPixelSize: Int) -> PDFRenderReply

        public init(
            parse: @escaping @Sendable (_ pdf: Data, _ maxPages: Int) -> PDFParserReply,
            renderPages: @escaping @Sendable (_ pdf: Data, _ maxPages: Int, _ maxPixelSize: Int) -> PDFRenderReply
        ) {
            self.parse = parse
            self.renderPages = renderPages
        }
    }

    private static let brokered = Mutex<Service?>(nil)

    /// Installs a worker's route through the app. Called once at worker
    /// startup.
    public static func installBrokered(_ service: Service) {
        brokered.withLock { $0 = service }
    }

    /// The service embedded in `bundle` when there is one, otherwise the
    /// installed brokered route, otherwise nil.
    public static func current(bundle: Bundle = .main) -> Service? {
        resolve(bundle: bundle, brokered: brokered.withLock { $0 })
    }

    static func resolve(bundle: Bundle, brokered: Service?) -> Service? {
        guard PDFParserXPCClient.isEmbedded(in: bundle) else { return brokered }
        let client = PDFParserXPCClient()
        return Service(
            parse: { pdf, maxPages in client.parse(pdf, maxPages: maxPages) },
            renderPages: { pdf, maxPages, maxPixelSize in
                client.renderPages(pdf, maxPages: maxPages, maxPixelSize: maxPixelSize)
            }
        )
    }
}
