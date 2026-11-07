import Foundation
import OhiaMessagesReaderProtocol
import OhiaMessagesReaderSupport

@main
struct OhiaMessagesReaderMain {
    static func main() {
        let service = OhiaMessagesReaderService()
        let delegate = OhiaMessagesReaderListenerDelegate(service: service)
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        fatalError("NSXPCListener.service() unexpectedly returned")
    }
}

private final class OhiaMessagesReaderListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: OhiaMessagesReaderService

    init(service: OhiaMessagesReaderService) {
        self.service = service
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MessagesReaderXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class OhiaMessagesReaderService: NSObject,
    MessagesReaderXPCProtocol,
    @unchecked Sendable {
    private let reader = MessagesChatDatabaseReader()

    func accessStatus(withReply reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        reply(reader.accessStatus(), nil)
    }

    func recentTranscript(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let request = try MessagesReaderPayloadCodec
                .decodeRequest(from: requestData)
                .constrainedForService()
            let response = reader.transcript(request: request)
            reply(try MessagesReaderPayloadCodec.encode(response), nil)
        } catch {
            reply(nil, Self.payloadError())
        }
    }

    private static func payloadError() -> NSError {
        NSError(
            domain: "org.jgkarlin.Ohia.MessagesReader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid Messages reader payload"]
        )
    }
}
