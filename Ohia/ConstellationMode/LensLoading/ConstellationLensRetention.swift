import Foundation
import OhiaCore

/// The exact user-visible request represented by a retained Metal surface.
/// Retention is intentionally scoped to the selected lens, its complete
/// filter, and lens-specific display controls so stale content cannot flash.
struct ConstellationMetalDisplayRequest: Equatable {
    let frame: FrameKey
    let filter: VectorFilter
    let selectedTimeRange: TimeRangePreset
    let meaningClusterDisplayLimit: Int?
}

/// Transient scene state that must never be captured or restored as a stable
/// lens surface.
struct ConstellationMetalRetentionContext: Equatable {
    var hasLock = false
    var hasHover = false
    var hasSearch = false
    var hasCitations = false
    var hasPendingFocus = false
    var hasTransitions = false

    static let stableUnlocked = Self()
}

struct ConstellationRetainedMetalSurface {
    let request: ConstellationMetalDisplayRequest
    let packet: ConstellationRenderPacket
    let filterCameraResetSignature: ConstellationFilterCameraResetRequest?
    let visibleRecords: [Int64: VectorRecord]
}

enum ConstellationMetalRetentionPolicy {
    static func canCapture(context: ConstellationMetalRetentionContext) -> Bool {
        context == .stableUnlocked
    }

    static func canCapture(
        context: ConstellationMetalRetentionContext,
        renderedGeneration: UInt64?,
        hydratedGeneration: UInt64?
    ) -> Bool {
        canCapture(context: context)
            && renderedGeneration != nil
            && renderedGeneration == hydratedGeneration
    }

    static func canRestore(
        retainedRequest: ConstellationMetalDisplayRequest,
        currentRequest: ConstellationMetalDisplayRequest,
        context: ConstellationMetalRetentionContext
    ) -> Bool {
        retainedRequest == currentRequest && canCapture(context: context)
    }

    static func shouldInstallPlannedPacket(
        passGeneration: UInt64,
        currentGeneration: UInt64,
        plannedRequest: ConstellationMetalDisplayRequest,
        currentRequest: ConstellationMetalDisplayRequest
    ) -> Bool {
        // A newer data generation for the same visible request must not starve
        // first paint. The serialized renderer will build the pending fresher
        // pass next; a changed lens/filter request still rejects this packet.
        _ = passGeneration
        _ = currentGeneration
        return plannedRequest == currentRequest
    }
}

/// Makes a true Metal cache miss cheaper without reducing the message
/// population. The full effects budget is restored silently after the first
/// frame from this packet reaches the renderer.
enum ConstellationColdFirstPaintPolicy {
    static func budget(
        base: RenderBudget,
        isColdCacheMiss: Bool
    ) -> RenderBudget {
        guard isColdCacheMiss else { return base }
        return base.reducingForPressure()
    }

    static func isFirstDrawOfColdPacket(
        awaitingFirstDraw: ConstellationMetalDisplayRequest?,
        renderedRequest: ConstellationMetalDisplayRequest?,
        currentRequest: ConstellationMetalDisplayRequest,
        drawnPacketGeneratedAt: TimeInterval,
        coldPacketGeneratedAts: Set<TimeInterval>
    ) -> Bool {
        guard let awaitingFirstDraw else { return false }
        return awaitingFirstDraw == renderedRequest
            && awaitingFirstDraw == currentRequest
            && coldPacketGeneratedAts.contains(drawnPacketGeneratedAt)
    }
}
