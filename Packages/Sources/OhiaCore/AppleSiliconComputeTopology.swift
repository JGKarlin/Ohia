import Darwin
import Foundation

/// Shared view of Apple silicon's asymmetric CPU topology. Newer chips expose
/// Super, Performance, and (where present) Efficiency levels; older chips
/// expose Performance and Efficiency levels. Systems without named perflevel
/// sysctls fall back to the legacy ordering or one uniform pool so detection
/// never disables useful work.
public struct AppleSiliconComputeTopology: Sendable, Equatable {
    public let superCoreCount: Int
    public let performanceCoreCount: Int
    public let efficiencyCoreCount: Int
    public let activeProcessorCount: Int

    public init(
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        activeProcessorCount: Int
    ) {
        self.init(
            superCoreCount: 0,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount,
            activeProcessorCount: activeProcessorCount
        )
    }

    public init(
        superCoreCount: Int,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        activeProcessorCount: Int
    ) {
        self.superCoreCount = max(0, superCoreCount)
        self.performanceCoreCount = max(0, performanceCoreCount)
        self.efficiencyCoreCount = max(0, efficiencyCoreCount)
        self.activeProcessorCount = max(1, activeProcessorCount)
    }

    public static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        let activeCount = max(1, processInfo.activeProcessorCount)
        let reportedLevelCount = sysctlInteger("hw.nperflevels")
        let levelCount = min(
            max(1, reportedLevelCount.flatMap { $0 > 0 ? $0 : nil } ?? 16),
            16
        )
        let levels = (0..<levelCount).compactMap { index -> PerfLevel? in
            guard let logicalCoreCount = sysctlInteger("hw.perflevel\(index).logicalcpu") else {
                return nil
            }
            return PerfLevel(
                name: sysctlString("hw.perflevel\(index).name"),
                logicalCoreCount: logicalCoreCount
            )
        }
        return resolve(activeProcessorCount: activeCount, perfLevels: levels)
    }

    public var weightedComputeCapacity: Int {
        superCoreCount * 3 + performanceCoreCount * 2 + efficiencyCoreCount
    }

    static func resolve(
        activeProcessorCount: Int,
        perfLevels: [PerfLevel]
    ) -> Self {
        let activeCount = max(1, activeProcessorCount)
        let usableLevels = perfLevels.filter { $0.logicalCoreCount > 0 }
        guard usableLevels.isEmpty == false else {
            return uniform(activeProcessorCount: activeCount)
        }

        var superCount = 0
        var performanceCount = 0
        var efficiencyCount = 0
        var unrecognizedCount = 0
        var recognizedNamedLevel = false
        var hasNamedLevel = false

        for level in usableLevels {
            hasNamedLevel = hasNamedLevel || level.normalizedName != nil
            switch level.normalizedName {
            case "super":
                superCount += level.logicalCoreCount
                recognizedNamedLevel = true
            case "performance":
                performanceCount += level.logicalCoreCount
                recognizedNamedLevel = true
            case "efficiency":
                efficiencyCount += level.logicalCoreCount
                recognizedNamedLevel = true
            default:
                unrecognizedCount += level.logicalCoreCount
            }
        }

        guard recognizedNamedLevel else {
            if hasNamedLevel {
                return Self(
                    performanceCoreCount: max(activeCount, unrecognizedCount),
                    efficiencyCoreCount: 0,
                    activeProcessorCount: activeCount
                )
            }
            // Older macOS releases exposed counts without level names. Preserve
            // the historic level-0 Performance / remaining Efficiency fallback.
            return Self(
                performanceCoreCount: usableLevels[0].logicalCoreCount,
                efficiencyCoreCount: usableLevels.dropFirst().reduce(0) {
                    $0 + $1.logicalCoreCount
                },
                activeProcessorCount: activeCount
            )
        }

        // A future named level should still contribute useful capacity until
        // Ohia understands its relative performance. Treat it conservatively
        // as Performance rather than discarding it.
        performanceCount += unrecognizedCount
        let classifiedCount = superCount + performanceCount + efficiencyCount
        if classifiedCount < activeCount {
            performanceCount += activeCount - classifiedCount
        }

        return Self(
            superCoreCount: superCount,
            performanceCoreCount: performanceCount,
            efficiencyCoreCount: efficiencyCount,
            activeProcessorCount: activeCount
        )
    }

    private static func uniform(activeProcessorCount: Int) -> Self {
        Self(
            performanceCoreCount: activeProcessorCount,
            efficiencyCoreCount: 0,
            activeProcessorCount: activeProcessorCount
        )
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = name.withCString { pointer in
            sysctlbyname(pointer, &value, &size, nil, 0)
        }
        guard result == 0, value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        let sizeResult = name.withCString { pointer in
            sysctlbyname(pointer, nil, &size, nil, 0)
        }
        guard sizeResult == 0, size > 1 else { return nil }

        var bytes = [UInt8](repeating: 0, count: size)
        let valueResult = bytes.withUnsafeMutableBytes { buffer in
            name.withCString { pointer in
                sysctlbyname(pointer, buffer.baseAddress, &size, nil, 0)
            }
        }
        guard valueResult == 0 else { return nil }
        let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let value = String(decoding: bytes[..<terminator], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    struct PerfLevel: Sendable, Equatable {
        let name: String?
        let logicalCoreCount: Int

        var normalizedName: String? {
            name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
