import Foundation
import Metal
import OhiaCore
import OhiaScheduler

/// Coarse scene-capacity classes derived from the resources that materially
/// bound a unified-memory Metal renderer. The class changes visual density,
/// never correctness or which user-selected records are forced into a packet.
enum ConstellationRenderHardwareClass: Sendable, Equatable {
    case compact
    case balanced
    case workstation
    case ultra
}

struct ConstellationRenderHardwareProfile: Sendable, Equatable {
    let hardwareClass: ConstellationRenderHardwareClass
    let baseBudget: RenderBudget

    static func current(
        processInfo: ProcessInfo = .processInfo,
        device: MTLDevice,
        lowPowerModeEnabled: Bool? = nil
    ) -> Self {
        let topology = AppleSiliconComputeTopology.current(processInfo: processInfo)
        return resolve(
            physicalMemoryBytes: processInfo.physicalMemory,
            superCoreCount: topology.superCoreCount,
            performanceCoreCount: topology.performanceCoreCount,
            efficiencyCoreCount: topology.efficiencyCoreCount,
            recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize,
            lowPowerModeEnabled: lowPowerModeEnabled ?? processInfo.isLowPowerModeEnabled
        )
    }

    static func resolve(
        physicalMemoryBytes: UInt64,
        superCoreCount: Int = 0,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        recommendedMaxWorkingSetSize: UInt64,
        lowPowerModeEnabled: Bool = false
    ) -> Self {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let memoryGiB = physicalMemoryBytes / gibibyte
        let workingSetGiB = recommendedMaxWorkingSetSize / gibibyte
        let workingSetIsKnown = recommendedMaxWorkingSetSize > 0
        let weightedComputeCapacity = max(0, superCoreCount) * 3
            + max(0, performanceCoreCount) * 2
            + max(0, efficiencyCoreCount)

        let hardwareClass: ConstellationRenderHardwareClass
        if memoryGiB >= 64,
           weightedComputeCapacity >= 32,
           workingSetIsKnown == false || workingSetGiB >= 48 {
            hardwareClass = .ultra
        } else if memoryGiB >= 32,
                  weightedComputeCapacity >= 18,
                  workingSetIsKnown == false || workingSetGiB >= 24 {
            hardwareClass = .workstation
        } else if memoryGiB <= 8
                    || weightedComputeCapacity <= 12
                    || (workingSetIsKnown && workingSetGiB <= 6) {
            hardwareClass = .compact
        } else {
            hardwareClass = .balanced
        }

        var budget = baseBudget(for: hardwareClass)
        if lowPowerModeEnabled {
            // Apple recommends reducing graphics detail in Low Power Mode.
            // Two steps retain the record population while removing the
            // costliest ambient fibers and satellite effects first.
            budget = budget.reducingForPressure().reducingForPressure()
        }

        return Self(
            hardwareClass: hardwareClass,
            baseBudget: budget
        )
    }

    private static func baseBudget(
        for hardwareClass: ConstellationRenderHardwareClass
    ) -> RenderBudget {
        switch hardwareClass {
        case .compact:
            return RenderBudget(
                maxStars: 1_200,
                maxNebulae: 384,
                maxFibers: 1_800,
                maxSatellites: 120
            )
        case .balanced:
            return .conservative
        case .workstation:
            return RenderBudget(
                maxStars: 2_400,
                maxNebulae: 768,
                maxFibers: 3_600,
                maxSatellites: 240
            )
        case .ultra:
            return RenderBudget(
                maxStars: 3_200,
                maxNebulae: 1_024,
                maxFibers: 4_800,
                maxSatellites: 320
            )
        }
    }
}

/// Applies render degradation only after sustained frame pressure and restores
/// one tier at a time after a longer healthy run. This prevents packet refreshes
/// from oscillating between density tiers around a single frame-time threshold.
struct AdaptiveRenderBudgetController: Sendable, Equatable {
    static let pressureSampleCount = 3
    static let severePressureSampleCount = 2
    static let recoverySampleCount = 16
    static let maximumPressureLevel = 4

    private(set) var baseBudget: RenderBudget
    private(set) var pressureLevel = 0
    private var pressureStreak = 0
    private var severePressureStreak = 0
    private var healthyStreak = 0

    init(baseBudget: RenderBudget = .conservative) {
        self.baseBudget = baseBudget
    }

    var currentBudget: RenderBudget {
        (0..<pressureLevel).reduce(baseBudget) { budget, _ in
            budget.reducingForPressure()
        }
    }

    @discardableResult
    mutating func setBaseBudget(_ budget: RenderBudget) -> Bool {
        guard budget != baseBudget else { return false }
        let previousBudget = currentBudget
        baseBudget = budget
        collapseRedundantPressureLevels()
        return currentBudget != previousBudget
    }

    /// Returns true only when the effective degradation tier changes.
    @discardableResult
    mutating func observe(_ stats: ConstellationMetalFrameStats) -> Bool {
        let gpuKnown = stats.gpuFrameMilliseconds > 0
        let severePressure = stats.cpuEncodingMilliseconds >= 24
            || (gpuKnown && stats.gpuFrameMilliseconds >= 24)
        let pressure = Self.isUnderPressure(stats)
        let healthy = stats.cpuEncodingMilliseconds <= 10
            && (gpuKnown == false || stats.gpuFrameMilliseconds <= 11.5)

        if pressure {
            pressureStreak += 1
            severePressureStreak = severePressure ? severePressureStreak + 1 : 0
            healthyStreak = 0

            let requiredSamples = severePressure
                ? Self.severePressureSampleCount
                : Self.pressureSampleCount
            let activeStreak = severePressure ? severePressureStreak : pressureStreak
            guard activeStreak >= requiredSamples,
                  pressureLevel < Self.maximumPressureLevel else {
                return false
            }
            let previousBudget = currentBudget
            pressureLevel += 1
            pressureStreak = 0
            severePressureStreak = 0
            if currentBudget == previousBudget {
                pressureLevel -= 1
                return false
            }
            return true
        }

        pressureStreak = 0
        severePressureStreak = 0
        guard healthy else {
            healthyStreak = 0
            return false
        }

        healthyStreak += 1
        guard healthyStreak >= Self.recoverySampleCount,
              pressureLevel > 0 else {
            return false
        }
        let previousBudget = currentBudget
        pressureLevel -= 1
        healthyStreak = 0
        return currentBudget != previousBudget
    }

    static func isUnderPressure(_ stats: ConstellationMetalFrameStats) -> Bool {
        stats.cpuEncodingMilliseconds >= 15
            || (stats.gpuFrameMilliseconds > 0 && stats.gpuFrameMilliseconds >= 16.5)
    }

    /// A more restrictive base (for example after Low Power Mode turns on)
    /// can make the highest pressure levels visually identical. Keep only
    /// the minimum level that produces the effective budget so recovery does
    /// not spend healthy samples unwinding invisible degradation levels.
    private mutating func collapseRedundantPressureLevels() {
        let effectiveBudget = currentBudget
        while pressureLevel > 0 {
            let candidateLevel = pressureLevel - 1
            let candidateBudget = (0..<candidateLevel).reduce(baseBudget) { budget, _ in
                budget.reducingForPressure()
            }
            guard candidateBudget == effectiveBudget else { return }
            pressureLevel = candidateLevel
        }
    }
}
