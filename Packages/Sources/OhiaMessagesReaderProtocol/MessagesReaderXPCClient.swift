import Foundation

public protocol MessagesReaderClient: Sendable {
    func accessStatus() async -> Bool
    func recentTranscript(_ request: MessagesReaderRequest) async -> MessagesReaderResponse
}

/// Connects only to Ohia's embedded Messages service. `serviceName:` resolves
/// in the containing application's private XPC namespace, whose entry is the
/// signed service bundle with this exact identifier.
public final class MessagesReaderXPCClient: MessagesReaderClient, @unchecked Sendable {
    public static let serviceIdentifier = "org.jgkarlin.Ohia.MessagesReader"
    static let peerCodeSigningRequirement = """
    identifier "org.jgkarlin.Ohia.MessagesReader" and anchor apple generic and \
    certificate leaf[subject.OU] = "3T72U4Q7A5"
    """

    private let connection: NSXPCConnection

    public init() {
        let connection = NSXPCConnection(serviceName: Self.serviceIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: MessagesReaderXPCProtocol.self)
        connection.setCodeSigningRequirement(Self.peerCodeSigningRequirement)
        connection.resume()
        self.connection = connection
    }

    deinit {
        connection.invalidate()
    }

    public func accessStatus() async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = MessagesReaderReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.resume(returning: false)
            }) as? any MessagesReaderXPCProtocol else {
                reply.resume(returning: false)
                return
            }
            proxy.accessStatus { available, error in
                reply.resume(returning: error == nil && available)
            }
        }
    }

    public func recentTranscript(
        _ request: MessagesReaderRequest
    ) async -> MessagesReaderResponse {
        guard let requestData = try? MessagesReaderPayloadCodec.encode(request) else {
            return .serviceUnavailable
        }

        return await withCheckedContinuation { continuation in
            let reply = MessagesReaderReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.resume(returning: .serviceUnavailable)
            }) as? any MessagesReaderXPCProtocol else {
                reply.resume(returning: .serviceUnavailable)
                return
            }
            proxy.recentTranscript(requestData) { responseData, error in
                guard error == nil,
                      let responseData,
                      let response = try? MessagesReaderPayloadCodec.decodeResponse(from: responseData) else {
                    reply.resume(returning: .serviceUnavailable)
                    return
                }
                reply.resume(returning: response)
            }
        }
    }
}

private final class MessagesReaderReplyOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume(returning: value)
    }
}
