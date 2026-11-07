import Foundation
import OhiaCore
import OhiaML

public final class WorkerMessagesTranscriptClient: MessagesTranscriptProviding, @unchecked Sendable {
    private let connection: NSXPCConnection

    public init(connection: NSXPCConnection) {
        self.connection = connection
    }

    public func transcript(for request: AutomaticMessagesRequest) async -> AutomaticMessagesResult {
        guard let requestData = try? JSONEncoder().encode(request) else {
            return .unavailable
        }
        return await withCheckedContinuation { continuation in
            let reply = WorkerMessagesReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.resume(returning: .unavailable)
            }) as? any WorkerXPCCommandBrokerProtocol else {
                reply.resume(returning: .unavailable)
                return
            }
            proxy.resolveMessagesTranscript(requestData) { responseData, error in
                guard error == nil,
                      let responseData,
                      let result = try? JSONDecoder().decode(
                        AutomaticMessagesResult.self,
                        from: responseData
                      ) else {
                    reply.resume(returning: .unavailable)
                    return
                }
                reply.resume(returning: result)
            }
        }
    }
}

private final class WorkerMessagesReplyOnce<Value: Sendable>: @unchecked Sendable {
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
