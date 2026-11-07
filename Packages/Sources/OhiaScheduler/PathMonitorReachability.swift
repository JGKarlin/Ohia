import Foundation
import Network

public final class PathMonitorReachability: NetworkReachability, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _isOnline: Bool = true

    public var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isOnline
    }

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.ohia.reachability")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self._isOnline = (path.status == .satisfied)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
