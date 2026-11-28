import Dispatch
import Foundation
import Synchronization

/// Runs work that blocks on `OhiaPDFParser.xpc` (a PDF parse or render, an
/// image's text recognition, or an attachment extraction that does one) for
/// an async caller, without holding one of Swift's task threads.
///
/// Each of those calls waits on a semaphore until the service, or the app
/// relaying for a worker, replies (`PDFParserWait`): up to two minutes for an
/// image whose recognizer broke, longer behind a busy relay lane. Swift's
/// cooperative pool has one thread per core and does not grow when one
/// blocks, so a few such waits on task threads would starve every other
/// task in the process, the timers that bound model work included. Each call
/// runs on a serial Dispatch queue of its own, at the caller's priority, and
/// resumes the caller when done. A serial queue runs on an overcommit thread,
/// which Dispatch starts even when all of its threads are blocked; the global
/// concurrent queues stop starting threads once the process has a fixed
/// number blocked (90 on an 18-core Mac, measured), after which a further
/// blocking call, and every other piece of work sent to those queues, would
/// wait for one of them to return.
///
/// The caller's task cancellation still reaches the wait: it is recorded
/// for the thread that runs the work, where `PDFParserWait` checks it
/// beside `Task.isCancelled`, which a Dispatch thread does not see.
public enum PDFParserBlockingCall {
    public static func run<Value: Sendable, Failure: Error>(
        priority: TaskPriority? = nil,
        _ work: @escaping @Sendable () throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let cancellation = Cancellation()
        let queue = DispatchQueue(
            label: queueLabel,
            qos: DispatchQoS(qosClass: qos(for: priority ?? Task.currentPriority), relativePriority: 0)
        )
        let result: Result<Value, Failure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = cancellation.bound { () -> Result<Value, Failure> in
                        do throws(Failure) {
                            return .success(try work())
                        } catch {
                            return .failure(error)
                        }
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    /// The label of each call's queue.
    static let queueLabel = "org.jgkarlin.Ohia.PDFParserBlockingCall"

    /// Whether the async caller whose blocking call runs on this thread was
    /// cancelled. False on any other thread.
    static var isCurrentCallCancelled: Bool {
        (Thread.current.threadDictionary[Cancellation.threadKey] as? Cancellation)?.isCancelled == true
    }

    static func qos(for priority: TaskPriority) -> DispatchQoS.QoSClass {
        switch priority.rawValue {
        case TaskPriority.high.rawValue...:
            return .userInitiated
        case TaskPriority.medium.rawValue...:
            return .default
        case TaskPriority.low.rawValue...:
            return .utility
        default:
            return .background
        }
    }

    /// One async caller's cancellation, bound to the thread that runs its
    /// blocking call for as long as the call runs.
    final class Cancellation: Sendable {
        static let threadKey = "org.jgkarlin.Ohia.PDFParserBlockingCall.cancellation"

        private let cancelled = Mutex(false)

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        func bound<T>(_ work: () -> T) -> T {
            let dictionary = Thread.current.threadDictionary
            let previous = dictionary[Self.threadKey]
            dictionary[Self.threadKey] = self
            defer { dictionary[Self.threadKey] = previous }
            return work()
        }
    }
}
