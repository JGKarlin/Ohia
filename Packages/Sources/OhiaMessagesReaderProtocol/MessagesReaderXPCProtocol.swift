import Foundation

@objc(OhiaMessagesReaderXPCProtocol)
public protocol MessagesReaderXPCProtocol {
    func accessStatus(withReply reply: @escaping @Sendable (Bool, NSError?) -> Void)

    func recentTranscript(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
}

public enum MessagesReaderPayloadCodec {
    public static func encode(_ request: MessagesReaderRequest) throws -> Data {
        try encoder().encode(request)
    }

    public static func decodeRequest(from data: Data) throws -> MessagesReaderRequest {
        try decoder().decode(MessagesReaderRequest.self, from: data)
    }

    public static func encode(_ response: MessagesReaderResponse) throws -> Data {
        try encoder().encode(response)
    }

    public static func decodeResponse(from data: Data) throws -> MessagesReaderResponse {
        try decoder().decode(MessagesReaderResponse.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
