import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Supporting Types

public struct ResourceState: Sendable {
    public let idleSeconds: TimeInterval
    public let thermalState: ThermalLevel
    public let isOnACPower: Bool
    public let isLowPowerModeEnabled: Bool
    public let memoryPressure: MemoryPressureLevel
    public let processResidentMemoryBytes: UInt64?
    public let physicalMemoryBytes: UInt64?

    public init(
        idleSeconds: TimeInterval,
        thermalState: ThermalLevel,
        isOnACPower: Bool,
        isLowPowerModeEnabled: Bool = false,
        memoryPressure: MemoryPressureLevel,
        processResidentMemoryBytes: UInt64? = nil,
        physicalMemoryBytes: UInt64? = nil
    ) {
        self.idleSeconds = idleSeconds
        self.thermalState = thermalState
        self.isOnACPower = isOnACPower
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.memoryPressure = memoryPressure
        self.processResidentMemoryBytes = processResidentMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public enum ThermalLevel: Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum MemoryPressureLevel: Sendable {
    case nominal
    case warning
    case critical
}

// MARK: - Protocol

public protocol SystemMonitor: Sendable {
    func currentState() -> ResourceState
}

// MARK: - Live

struct SystemPowerSnapshot: Sendable, Equatable {
    let isOnACPower: Bool
    let isLowPowerModeEnabled: Bool
}

public final class LiveSystemMonitor: @unchecked Sendable, SystemMonitor {
    static let memoryCriticalRetentionSeconds: TimeInterval = 30
    static let memoryWarningRetentionSeconds: TimeInterval = 120

    private let memoryPressureSource: DispatchSourceMemoryPressure
    private let powerSnapshotProvider: @Sendable () -> SystemPowerSnapshot
    private let memoryPressureLock = NSLock()
    private var observedMemoryPressure: MemoryPressureLevel = .nominal
    private var observedMemoryPressureAt: Date?

    public convenience init() {
        self.init(powerSnapshotProvider: { Self.currentPowerSnapshot() })
    }

    init(powerSnapshotProvider: @escaping @Sendable () -> SystemPowerSnapshot) {
        self.powerSnapshotProvider = powerSnapshotProvider
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "org.jgkarlin.Ohia.memory-pressure")
        )
        self.memoryPressureSource = source
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .nominal
            }
            self?.setObservedMemoryPressure(level, at: Date())
        }
        source.resume()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    public func currentState() -> ResourceState {
        let power = powerSnapshotProvider()
        return ResourceState(
            idleSeconds: idleSeconds(),
            thermalState: thermalLevel(),
            isOnACPower: power.isOnACPower,
            isLowPowerModeEnabled: power.isLowPowerModeEnabled,
            memoryPressure: currentObservedMemoryPressure(),
            processResidentMemoryBytes: processResidentMemoryBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    // MARK: Private helpers

    static func powerSnapshot(
        providingPowerSourceType: String?,
        lowPowerModeEnabled: Bool
    ) -> SystemPowerSnapshot {
        SystemPowerSnapshot(
            // UPS and unknown sources are intentionally conservative: only a
            // confirmed AC source should unlock discretionary catch-up work.
            isOnACPower: providingPowerSourceType == kIOPMACPowerKey,
            isLowPowerModeEnabled: lowPowerModeEnabled
        )
    }

    private static func currentPowerSnapshot() -> SystemPowerSnapshot {
        let sourceType: String?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            sourceType = type as String
        } else {
            sourceType = nil
        }

        return powerSnapshot(
            providingPowerSourceType: sourceType,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    static func retainedMemoryPressure(
        _ level: MemoryPressureLevel,
        observedAt: Date?,
        now: Date = Date()
    ) -> MemoryPressureLevel {
        guard let observedAt else { return level }
        let age = now.timeIntervalSince(observedAt)
        switch level {
        case .nominal:
            return .nominal
        case .warning:
            return age <= memoryWarningRetentionSeconds ? .warning : .nominal
        case .critical:
            if age <= memoryCriticalRetentionSeconds {
                return .critical
            }
            return age <= memoryWarningRetentionSeconds ? .warning : .nominal
        }
    }

    private func setObservedMemoryPressure(_ level: MemoryPressureLevel, at date: Date) {
        memoryPressureLock.lock()
        observedMemoryPressure = level
        observedMemoryPressureAt = date
        memoryPressureLock.unlock()
    }

    private func currentObservedMemoryPressure() -> MemoryPressureLevel {
        memoryPressureLock.lock()
        let level = observedMemoryPressure
        let observedAt = observedMemoryPressureAt
        memoryPressureLock.unlock()
        return Self.retainedMemoryPressure(level, observedAt: observedAt)
    }

    private func idleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as? [String: AnyObject] else {
            return 0
        }

        guard let hidIdleTime = dict["HIDIdleTime"] as? NSNumber else { return 0 }
        // HIDIdleTime is in nanoseconds
        return hidIdleTime.doubleValue / 1_000_000_000.0
    }

    private func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    private func processResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
