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

    private func request<Reply: Sendable>(
        timeout: TimeInterval,
        unavailable: Reply,
        cancelled: Reply,
        timedOut: Reply,
        send: (any PDFParserXPCProtocol, @escaping @Sendable (Reply) -> Void) -> Void
    ) -> Reply {
        let connection = NSXPCConnection(serviceName: Self.serviceIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: PDFParserXPCProtocol.self)
        connection.setCodeSigningRequirement(Self.peerCodeSigningRequirement)
        connection.resume()
        defer { connection.invalidate() }

        return PDFParserWait.wait(
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
    }
}
