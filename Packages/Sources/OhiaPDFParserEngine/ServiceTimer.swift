import Foundation

/// The parser service's deadlines: the watchdog over a PDFKit or Vision call
/// (`PDFKitWatchdog`) and a retiring service's drain limit
/// (`ServiceRetirement`). Each fires on a strict timer on a user-initiated
/// queue, so neither the work it guards nor a busy machine delays it past
/// `leeway`: a `.utility` timer was seen to fire more than 10 seconds late
/// while user-initiated work kept every core busy, and a late deadline lets
/// a caller give up before the service acts.
enum ServiceTimer {
    /// How late a deadline may fire.
    static let leeway: DispatchTimeInterval = .milliseconds(500)
    static let qos: DispatchQoS.QoSClass = .userInitiated

    /// Runs `handler` once, `delay` from now, unless the returned timer is
    /// cancelled first.
    static func schedule(after delay: TimeInterval, _ handler: @escaping @Sendable () -> Void) -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: qos))
        timer.schedule(deadline: .now() + delay, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
