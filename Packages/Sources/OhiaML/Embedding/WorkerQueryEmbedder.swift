import Foundation
import OhiaCore

/// Query-only embedding facade for processes that must not keep BGE-M3
/// resident. User query strings cross only a live request-scoped XPC call;
/// neither the request nor its vectors have a durable fallback.
public final class WorkerQueryEmbedder: EmbeddingProvider, Sendable {
    public static let defaultTimeout = WorkerGenerationEngine
        .interactiveModelHandoffReadinessTimeout
    public let embeddingDimension = BGE3Embedder.embeddingDimension
    public let embeddingVersion = BGE3Embedder.embeddingVersion

    private let commandSubmitter: any WorkerCommandSubmitting
    private let liveCommandSubmitter: any WorkerLiveCommandSubmitting
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        statusStore _: WorkerStatusStore = WorkerStatusStore(),
        commandSubmitter: any WorkerCommandSubmitting = WorkerCommandTransport.shared,
        liveCommandSubmitter: any WorkerLiveCommandSubmitting = WorkerCommandTransport.shared,
        timeout: TimeInterval = WorkerQueryEmbedder.defaultTimeout
    ) {
        self.commandSubmitter = commandSubmitter
        self.liveCommandSubmitter = liveCommandSubmitter
        self.timeout = max(0, timeout)
        self.now = { Date() }
    }

    init(
        commandSubmitter: any WorkerCommandSubmitting,
        liveCommandSubmitter: any WorkerLiveCommandSubmitting,
        timeout: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.commandSubmitter = commandSubmitter
        self.liveCommandSubmitter = liveCommandSubmitter
        self.timeout = max(0, timeout)
        self.now = now
    }

    public func embed(_ text: String) -> [Float]? {
        embedBatch([text]).first ?? nil
    }

    public func embedBatch(_ texts: [String]) -> [[Float]?] {
        guard !texts.isEmpty else { return [] }
        do {
            return try requestEmbeddings(for: texts)
        } catch {
            return Array(repeating: nil, count: texts.count)
        }
    }

    private func requestEmbeddings(for texts: [String]) throws -> [[Float]?] {
        try Task.checkCancellation()

        let commandID = UUID()
        let enqueuedAt = now()
        let request = WorkerQueryEmbeddingRequest(
            texts: texts,
            embeddingDimension: embeddingDimension,
            embeddingVersion: embeddingVersion,
            enqueuedAt: enqueuedAt,
            deadline: enqueuedAt.addingTimeInterval(timeout)
        )
        let command = WorkerCommandSnapshot(
            id: commandID,
            kind: .embedQueries,
            issuedAt: enqueuedAt,
            message: "query embedding request",
            queryEmbeddingRequest: request
        )

        var workerSettledRequest = false
        defer {
            if !workerSettledRequest {
                sendCancellation(for: commandID)
            }
        }
        let response = try liveCommandSubmitter.submitQueryEmbedding(
            command,
            timeout: timeout
        )
        workerSettledRequest = true
        try Task.checkCancellation()
        return try resolve(response, expectedCommandID: commandID, expectedCount: texts.count)
    }

    private func resolve(
        _ response: WorkerQueryEmbeddingResponseSnapshot,
        expectedCommandID: UUID,
        expectedCount: Int
    ) throws -> [[Float]?] {
        guard response.commandID == expectedCommandID else {
            throw RequestError.mismatchedResponse
        }
        switch response.status {
        case .success:
            guard response.embeddingDimension == embeddingDimension,
                  response.embeddingVersion == embeddingVersion,
                  let embeddings = response.embeddings,
                  embeddings.count == expectedCount,
                  embeddings.allSatisfy({
                      $0 == nil || $0?.count == embeddingDimension
                  }) else {
                throw RequestError.invalidResponse
            }
            return embeddings
        case .cancelled:
            throw CancellationError()
        case .modelNotLoaded:
            throw RequestError.modelNotLoaded
        case .failed:
            throw RequestError.workerFailed(response.errorMessage)
        }
    }

    private func sendCancellation(for commandID: UUID) {
        _ = try? commandSubmitter.submit(
            WorkerCommandSnapshot(
                kind: .cancelQueryEmbedding,
                issuedAt: now(),
                message: "query embedding cancellation",
                targetCommandID: commandID
            ),
            to: .bge
        )
    }

    private enum RequestError: Error, Sendable {
        case mismatchedResponse
        case invalidResponse
        case modelNotLoaded
        case workerFailed(String?)
    }
}
