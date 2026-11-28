import Foundation
import OhiaPDFParsing
import Synchronization

/// How `OhiaPDFParser.xpc` exits once its text recognizer broke. Every caller
/// shares the one service process, so exiting at once would cut off other
/// callers' requests in flight (a PDF parse, a render) and lose their replies.
/// A retiring service instead keeps serving, PDFs as before and images with
/// an immediate `.recognizerUnavailable` (see `PDFParserServiceEngine`), and
/// exits once every open connection has closed or is a watcher's. A caller
/// closes its connection once it has its reply, so no reply is lost. A
/// watcher is a caller that acknowledged a `.recognizerUnavailable` reply: it
/// already has its reply and keeps its connection open only to see the exit,
/// so it does not hold the exit up. Every acknowledging caller becomes one.
/// `drainLimit` after retiring starts, the service exits regardless, once
/// any caller given a reply in the window's last moments has it
/// (`OpenConnections`).
public final class ServiceRetirement: Sendable {
    /// How late the drain timer may fire (`ServiceTimer`): a retiring
    /// service exits by `drainLimit + drainTimerLeeway`, before an
    /// acknowledging caller stops waiting for the exit
    /// (`PDFParserLimits.brokenServiceExitWait`).
    static let drainTimerLeeway = ServiceTimer.leeway
    /// The drain timer's queue. A user-initiated queue keeps busy work, or a
    /// quiet or throttled service, from running it late.
    static let drainTimerQoS = ServiceTimer.qos

    private struct State {
        var open: Set<ObjectIdentifier> = []
        var watchers: Set<ObjectIdentifier> = []
        var retiring = false
        var exited = false
        var drainTimer: (any DispatchSourceTimer)?

        var isDrained: Bool { open.subtracting(watchers).isEmpty }
    }

    private let state = Mutex(State())
    private let drainLimit: TimeInterval
    private let exit: @Sendable () -> Void

    public init(
        drainLimit: TimeInterval = PDFParserLimits.brokenServiceDrainLimit,
        exit: @escaping @Sendable () -> Void
    ) {
        self.drainLimit = drainLimit
        self.exit = exit
    }

    deinit {
        state.withLock { $0.drainTimer?.cancel() }
    }

    /// True once the recognizer broke and the service is on its way out.
    public var isRetiring: Bool {
        state.withLock { $0.retiring }
    }

    /// A connection was accepted. A retiring service waits for it too.
    public func opened(_ connection: ObjectIdentifier) {
        state.withLock { state in
            _ = state.open.insert(connection)
        }
    }

    /// A connection was invalidated: its caller is done with it.
    public func closed(_ connection: ObjectIdentifier) {
        let exitNow = state.withLock { state -> Bool in
            state.open.remove(connection)
            state.watchers.remove(connection)
            return Self.claimExit(&state)
        }
        if exitNow { exit() }
    }

    /// Starts retiring; later calls do nothing more. The service exits as
    /// soon as every open connection has closed or is a watcher's, and at the
    /// latest `drainLimit` later, when a request that arrived late in the
    /// window and is still running is cut off; its caller re-sends it once
    /// to a fresh process (`ImageTextRecognition.recognize`).
    public func retire() {
        let exitNow = state.withLock { state -> Bool in
            guard !state.retiring else { return false }
            state.retiring = true
            if Self.claimExit(&state) { return true }
            state.drainTimer = ServiceTimer.schedule(after: drainLimit) { [weak self] in
                self?.drainLimitPassed()
            }
            return false
        }
        if exitNow { exit() }
    }

    /// `connection`'s caller acknowledged a `.recognizerUnavailable` reply:
    /// it has its reply and waits only for the exit. Ignored unless the
    /// service is retiring and the connection is open.
    public func watch(_ connection: ObjectIdentifier) {
        let exitNow = state.withLock { state -> Bool in
            guard state.retiring, state.open.contains(connection) else { return false }
            state.watchers.insert(connection)
            return Self.claimExit(&state)
        }
        if exitNow { exit() }
    }

    private func drainLimitPassed() {
        let exitNow = state.withLock { state -> Bool in
            guard !state.exited else { return false }
            state.exited = true
            return true
        }
        if exitNow { exit() }
    }

    /// True, once, when every open connection of a retiring service has
    /// closed or is a watcher's.
    private static func claimExit(_ state: inout State) -> Bool {
        guard state.retiring, !state.exited, state.isDrained else { return false }
        state.exited = true
        state.drainTimer?.cancel()
        return true
    }
}
