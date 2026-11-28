import Foundation

/// The connections `OhiaPDFParser.xpc` has accepted and not seen close, and
/// which of them have been given a reply their caller may not have yet, so
/// that the service's exits lose no reply already given: an overrun's, whose
/// own request's `timedOut` matters above all, and a retiring service's
/// (`ServiceRetirement`), where a reply may have been handed over in the last
/// moments before the drain limit.
///
/// A reply handed to NSXPC is not yet the caller's: NSXPC sends it later,
/// and a caller whose service exits first sees the connection interrupted
/// instead. Measured against the real service, an exit right after the
/// reply, even once the connection's send barrier
/// (`NSXPCConnection.scheduleSendBarrierBlock`) had run, left the caller
/// with `serviceUnavailable`. A caller closes its connection once it has
/// processed its reply (`PDFParserXPCClient`), so an exit waits for each
/// connection given a reply to close (`exiting`). A caller that acknowledged
/// a `.recognizerUnavailable` reply is a watcher: it has its reply and keeps
/// its connection open only to see the exit, so no exit waits for it. NSXPC
/// reports a close on the connection's queue, which must be free while a
/// stuck call runs, so the service runs requests on queues of their own.
public final class OpenConnections: @unchecked Sendable {
    /// How long an overrun's exit waits for callers given a reply to close
    /// their connections: a caller closes within milliseconds of its reply,
    /// so only one that has stopped reading takes this long, and the exit
    /// goes on without it.
    public static let overrunReceiptTimeout: TimeInterval = 10
    /// The same for a retiring service's exit, which must still come inside
    /// the time an acknowledging caller waits for it
    /// (`PDFParserLimits.brokenServiceExitWait`) when it is the drain
    /// limit's.
    public static let retiredReceiptTimeout: TimeInterval = 2

    /// What a wait for receipts found.
    public struct Receipt: Sendable, Equatable {
        /// Replies whose callers had not closed their connections when the
        /// wait began, and replies given during it.
        public let given: Int
        /// Of those, how many callers closed their connections, or became
        /// watchers, before the wait ended.
        public let received: Int
        public let milliseconds: Int
    }

    private let condition = NSCondition()
    private var open: Set<ObjectIdentifier> = []
    private var awaitingReceipt: Set<ObjectIdentifier> = []
    /// Every reply ever recorded in `awaitingReceipt`, so a wait counts the
    /// replies given while it runs.
    private var repliesGiven = 0

    public init() {}

    /// The service accepted `connection`.
    public func opened(_ connection: ObjectIdentifier) {
        condition.withLock { _ = open.insert(connection) }
    }

    /// `connection` closed: its caller has every reply it was given. Called
    /// before the service tells its retirement, whose exit then finds the
    /// connection gone.
    public func closed(_ connection: ObjectIdentifier) {
        condition.withLock {
            open.remove(connection)
            if awaitingReceipt.remove(connection) != nil { condition.broadcast() }
        }
    }

    /// `connection` is about to be given a reply. Ignored once it has
    /// closed: its caller stopped waiting.
    public func replying(on connection: ObjectIdentifier?) {
        guard let connection else { return }
        condition.withLock {
            guard open.contains(connection), awaitingReceipt.insert(connection).inserted else { return }
            repliesGiven += 1
        }
    }

    /// `connection`'s caller acknowledged a `.recognizerUnavailable` reply:
    /// it has its reply, so no exit waits for its connection to close.
    /// Called before the service tells its retirement, whose exit may follow
    /// at once.
    public func watching(_ connection: ObjectIdentifier?) {
        guard let connection else { return }
        condition.withLock {
            if awaitingReceipt.remove(connection) != nil { condition.broadcast() }
        }
    }

    /// Returns once every open connection given a reply has closed or become
    /// a watcher's, replies given during the wait included, or `timeout`
    /// has passed.
    public func awaitRepliesReceived(timeout: TimeInterval) -> Receipt {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        let pendingAtStart = awaitingReceipt.count
        let givenAtStart = repliesGiven
        while !awaitingReceipt.isEmpty, condition.wait(until: deadline) {}
        let given = pendingAtStart + (repliesGiven - givenAtStart)
        return Receipt(
            given: given,
            received: given - awaitingReceipt.count,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    /// A function that waits for receipts, at most `timeout`, then calls
    /// `exit` with what the wait found: the service's exits are built from
    /// it.
    public func exiting(
        timeout: TimeInterval,
        _ exit: @escaping @Sendable (Receipt) -> Void
    ) -> @Sendable () -> Void {
        { [self] in exit(awaitRepliesReceived(timeout: timeout)) }
    }
}
