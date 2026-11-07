import Foundation
import OhiaCore

// MARK: - EmbeddingProvider Protocol

public protocol EmbeddingProvider: Sendable {
    var embeddingDimension: Int { get }
    var embeddingVersion: String { get }
    func embed(_ text: String) -> [Float]?
    func embedBatch(_ texts: [String]) -> [[Float]?]
}

public extension EmbeddingProvider {
    func embedBatch(_ texts: [String]) -> [[Float]?] {
        texts.map { embed($0) }
    }
}

public protocol AsyncEmbeddingProvider: EmbeddingProvider {
    func embedBatchAsync(_ texts: [String], priority: TaskPriority) async -> [[Float]?]
}

public protocol RuntimeLaneLimitedEmbeddingProvider: AsyncEmbeddingProvider {
    var parallelLaneCount: Int { get }
    func embedBatchAsync(
        _ texts: [String],
        priority: TaskPriority,
        laneLimit: Int
    ) async -> [[Float]?]
}

public extension RuntimeLaneLimitedEmbeddingProvider {
    func embedBatchAsync(_ texts: [String], priority: TaskPriority) async -> [[Float]?] {
        await embedBatchAsync(texts, priority: priority, laneLimit: parallelLaneCount)
    }
}

/// Stable embedding provider handle whose implementation can be loaded later.
/// App launch can publish the correct version/dimension immediately, while the
/// expensive Core ML model compile/load work happens off the main actor.
public final class SwappableEmbedder: RuntimeLaneLimitedEmbeddingProvider, @unchecked Sendable {
    public let embeddingDimension: Int
    public let embeddingVersion: String

    private let lock = NSLock()
    private var provider: EmbeddingProvider
    private var activeOperationCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(initial: EmbeddingProvider) {
        self.embeddingDimension = initial.embeddingDimension
        self.embeddingVersion = initial.embeddingVersion
        self.provider = initial
    }

    public func replace(with replacement: EmbeddingProvider) throws {
        try validate(replacement)

        lock.lock()
        defer { lock.unlock() }
        provider = replacement
    }

    /// Stops new calls from reaching the current provider, then waits until
    /// every call that already captured it has returned. Resource arbitration
    /// uses this before publishing a nonresident heartbeat so another helper
    /// cannot load a large model while Core ML is still executing the old one.
    public func replaceAndDrain(with replacement: EmbeddingProvider) async throws {
        try validate(replacement)

        await withCheckedContinuation { continuation in
            lock.lock()
            provider = replacement
            if activeOperationCount == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public var isUsingUnavailableProvider: Bool {
        lock.lock()
        defer { lock.unlock() }
        return provider is UnavailableEmbedder
    }

    public var parallelLaneCount: Int {
        let activeProvider = currentProvider()
        return (activeProvider as? RuntimeLaneLimitedEmbeddingProvider)?.parallelLaneCount ?? 1
    }

    public func embed(_ text: String) -> [Float]? {
        let activeProvider = beginOperation()
        defer { endOperation() }
        return activeProvider.embed(text)
    }

    public func embedBatch(_ texts: [String]) -> [[Float]?] {
        let activeProvider = beginOperation()
        defer { endOperation() }
        return activeProvider.embedBatch(texts)
    }

    public func embedBatchAsync(_ texts: [String], priority: TaskPriority) async -> [[Float]?] {
        let activeProvider = beginOperation()
        defer { endOperation() }
        if let asyncProvider = activeProvider as? AsyncEmbeddingProvider {
            return await asyncProvider.embedBatchAsync(texts, priority: priority)
        }
        return activeProvider.embedBatch(texts)
    }

    public func embedBatchAsync(
        _ texts: [String],
        priority: TaskPriority,
        laneLimit: Int
    ) async -> [[Float]?] {
        let activeProvider = beginOperation()
        defer { endOperation() }
        if let laneLimitedProvider = activeProvider as? RuntimeLaneLimitedEmbeddingProvider {
            return await laneLimitedProvider.embedBatchAsync(
                texts,
                priority: priority,
                laneLimit: laneLimit
            )
        }
        if let asyncProvider = activeProvider as? AsyncEmbeddingProvider {
            return await asyncProvider.embedBatchAsync(texts, priority: priority)
        }
        return activeProvider.embedBatch(texts)
    }

    private func validate(_ replacement: EmbeddingProvider) throws {
        guard replacement.embeddingVersion == embeddingVersion else {
            throw SwapError.embeddingVersionMismatch(
                expected: embeddingVersion,
                actual: replacement.embeddingVersion
            )
        }
        guard replacement.embeddingDimension == embeddingDimension else {
            throw SwapError.embeddingDimensionMismatch(
                expected: embeddingDimension,
                actual: replacement.embeddingDimension
            )
        }
    }

    private func beginOperation() -> EmbeddingProvider {
        lock.lock()
        activeOperationCount += 1
        let activeProvider = provider
        lock.unlock()
        return activeProvider
    }

    private func endOperation() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        activeOperationCount -= 1
        if activeOperationCount == 0 {
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func currentProvider() -> EmbeddingProvider {
        lock.lock()
        defer { lock.unlock() }
        let activeProvider = provider
        return activeProvider
    }

    public enum SwapError: Error, Sendable, Equatable {
        case embeddingVersionMismatch(expected: String, actual: String)
        case embeddingDimensionMismatch(expected: Int, actual: Int)
    }
}
