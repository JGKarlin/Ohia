import Foundation

/// The uninstaller's wait for Ohia's cleanup result: where it looks, how long
/// it waits and when it stops. The file checks, the clock and the sleeps are
/// injected, so the decisions can be tested without launching Ohia.
public struct CleanupResultPoller: Sendable {
    public static let pollInterval: Duration = .milliseconds(250)
    /// How long to look for a result when Launch Services reported an error
    /// and no Ohia process runs.
    public static let openErrorGrace: Duration = .seconds(60)

    private let fileExists: @Sendable (URL) -> Bool
    private let read: @Sendable (URL) -> Data?
    private let remove: @Sendable (URL) -> Void
    private let elapsed: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` throws only when the task is cancelled, as `Task.sleep` does.
    public init(
        fileExists: @escaping @Sendable (URL) -> Bool,
        read: @escaping @Sendable (URL) -> Data?,
        remove: @escaping @Sendable (URL) -> Void,
        elapsed: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.fileExists = fileExists
        self.read = read
        self.remove = remove
        self.elapsed = elapsed
        self.sleep = sleep
    }

    /// Waits for a result in `candidates`, taking the first that exists, in
    /// order. The file it takes is read, then deleted; one that does not
    /// decode counts as no result.
    ///
    /// While the Ohia Launch Services started (`launched`) runs, it waits up
    /// to `timeout`. When Launch Services reported an error, it waits up to
    /// `timeout` while an Ohia process runs anyway (`ohiaIsRunning`), and
    /// `openErrorGrace` otherwise. It stops after one last look when the
    /// launched Ohia has exited (Ohia writes the result before it exits),
    /// when its limit has passed, and when its task is cancelled.
    public func wait(
        for candidates: [URL],
        launched: Bool,
        hasExited: @Sendable () -> Bool,
        ohiaIsRunning: @Sendable () -> Bool,
        timeout: Duration
    ) async -> UninstallCleanupResult? {
        while true {
            if let found = candidates.first(where: fileExists) {
                return take(found)
            }
            if Task.isCancelled || (launched && hasExited()) {
                return lastLook(candidates)
            }
            let limit = launched || ohiaIsRunning() ? timeout : min(timeout, Self.openErrorGrace)
            if elapsed() >= limit {
                return lastLook(candidates)
            }
            do {
                try await sleep(Self.pollInterval)
            } catch {
                // Cancelled: stop rather than poll again without pausing.
                return lastLook(candidates)
            }
        }
    }

    /// A result Ohia wrote just before the wait stopped is still taken.
    private func lastLook(_ candidates: [URL]) -> UninstallCleanupResult? {
        candidates.first(where: fileExists).flatMap(take)
    }

    private func take(_ url: URL) -> UninstallCleanupResult? {
        let data = read(url)
        remove(url)
        return data.flatMap { try? UninstallCleanupResult.decode($0) }
    }
}
