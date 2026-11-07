import CoreGraphics
import Foundation
import SwiftUI

struct FocusedOverlayPaneLayoutCoordinator {
    enum PaneRole: Int, Equatable {
        case primary
        case context
        case annotation
    }

    struct Pane: Identifiable, Equatable {
        let id: String
        let role: PaneRole
        let size: CGSize
        let anchor: CGPoint?
        let priority: Int
        let preferredAngle: CGFloat?
        let manualCenter: CGPoint?
        let radialAffinity: CGFloat?

        init(
            id: String,
            role: PaneRole,
            size: CGSize,
            anchor: CGPoint? = nil,
            priority: Int,
            preferredAngle: CGFloat? = nil,
            manualCenter: CGPoint? = nil,
            radialAffinity: CGFloat? = nil
        ) {
            self.id = id
            self.role = role
            self.size = size
            self.anchor = anchor
            self.priority = priority
            self.preferredAngle = preferredAngle
            self.manualCenter = manualCenter
            self.radialAffinity = radialAffinity
        }
    }

    struct LayoutSolution: Equatable {
        let framesByID: [String: CGRect]
        let orderedPanes: [Pane]
        let focalPoint: CGPoint
        let focalAvoidanceFrame: CGRect
    }

    private struct Candidate {
        let frame: CGRect
        let angle: CGFloat
        let anglePenalty: CGFloat
        let ring: Int
        let order: Int
    }

    static let sceneMargin: CGFloat = 14
    static let paneGap: CGFloat = 28
    private static let relatedAffinityFloor: CGFloat = 0.85
    private static let relatedAffinityRadialSpread: CGFloat = 180

    func layout(
        panes: [Pane],
        focalPoint: CGPoint,
        sceneSize: CGSize,
        preferredSide: HorizontalEdge,
        reservedFrames: [CGRect] = []
    ) -> LayoutSolution {
        guard sceneSize.width > 1, sceneSize.height > 1 else {
            return LayoutSolution(
                framesByID: [:],
                orderedPanes: [],
                focalPoint: focalPoint,
                focalAvoidanceFrame: .zero
            )
        }

        let focalAvoidanceFrame = Self.focalAvoidanceFrame(
            focalPoint: focalPoint,
            sceneSize: sceneSize
        )
        let ordered = panes.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.role.rawValue != $1.role.rawValue { return $0.role.rawValue < $1.role.rawValue }
            return $0.id < $1.id
        }
        var framesByID: [String: CGRect] = [:]
        var avoidanceFrames = [focalAvoidanceFrame] + reservedFrames

        for (index, pane) in ordered.enumerated() {
            let frame = frame(
                for: pane,
                index: index,
                count: ordered.count,
                existingFrames: Array(framesByID.values),
                avoidanceFrames: avoidanceFrames,
                focalPoint: focalPoint,
                sceneSize: sceneSize,
                preferredSide: preferredSide
            )
            framesByID[pane.id] = frame
            avoidanceFrames.append(frame)
        }

        return LayoutSolution(
            framesByID: framesByID,
            orderedPanes: ordered,
            focalPoint: focalPoint,
            focalAvoidanceFrame: focalAvoidanceFrame
        )
    }

    static func focalPoint(projected: CGPoint?, sceneSize: CGSize) -> CGPoint {
        guard let projected,
              projected.x.isFinite,
              projected.y.isFinite,
              projected.x >= 0,
              projected.y >= 0,
              projected.x <= sceneSize.width,
              projected.y <= sceneSize.height else {
            return CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        }
        return projected
    }

    static func focalClearanceRadius(sceneSize: CGSize) -> CGFloat {
        min(180, max(104, min(sceneSize.width, sceneSize.height) * 0.16))
    }

    static func focalAvoidanceFrame(focalPoint: CGPoint, sceneSize: CGSize) -> CGRect {
        let radius = focalClearanceRadius(sceneSize: sceneSize)
        return CGRect(
            x: focalPoint.x - radius,
            y: focalPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    static func frame(center: CGPoint, size: CGSize, sceneSize: CGSize) -> CGRect {
        let clamped = LockedCardGeometry.clampedCenter(
            center,
            cardSize: size,
            sceneSize: sceneSize,
            margin: sceneMargin
        )
        return CGRect(
            x: clamped.x - size.width / 2,
            y: clamped.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func primaryFrame(
        id: String,
        size: CGSize,
        manualCenter: CGPoint?,
        focalPoint: CGPoint,
        sceneSize: CGSize,
        preferredSide: HorizontalEdge
    ) -> CGRect {
        let solution = layout(
            panes: [
                Pane(
                    id: id,
                    role: .primary,
                    size: size,
                    priority: 0,
                    manualCenter: manualCenter
                )
            ],
            focalPoint: focalPoint,
            sceneSize: sceneSize,
            preferredSide: preferredSide
        )
        return solution.framesByID[id] ?? Self.frame(
            center: CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2),
            size: size,
            sceneSize: sceneSize
        )
    }

    func contextFrame(
        id: String,
        size: CGSize,
        manualCenter: CGPoint?,
        focalPoint: CGPoint,
        sceneSize: CGSize,
        sidebarSide: HorizontalEdge,
        reservedFrames: [CGRect]
    ) -> CGRect {
        if let manualCenter {
            return Self.frame(center: manualCenter, size: size, sceneSize: sceneSize)
        }
        return sidebarAdjacentContextFrame(
            size: size,
            sceneSize: sceneSize,
            sidebarSide: sidebarSide
        )
    }

    /// Pin the telemetry strip to the same horizontal edge the search/ask
    /// sidebar lives on. Sidebar leading → strip in the top-left corner of
    /// the scene; sidebar trailing → strip in the top-right corner.
    /// Decoupled from the email card's preferred side so a future change
    /// to card placement can't silently swap the telemetry corner.
    private func sidebarAdjacentContextFrame(
        size: CGSize,
        sceneSize: CGSize,
        sidebarSide: HorizontalEdge
    ) -> CGRect {
        let originX = sidebarSide == .leading
            ? LockedNodeOverlayMetrics.telemetryOrigin.x
            : sceneSize.width - LockedNodeOverlayMetrics.telemetryOrigin.x - size.width
        let center = CGPoint(
            x: originX + size.width / 2,
            y: LockedNodeOverlayMetrics.telemetryOrigin.y + size.height / 2
        )
        return Self.frame(center: center, size: size, sceneSize: sceneSize)
    }

    func annotationFrames(
        items: [ScreenAnnotationItem],
        manualCenters: [String: CGPoint],
        focalPoint: CGPoint,
        sceneSize: CGSize,
        preferredSide: HorizontalEdge,
        reservedFrames: [CGRect]
    ) -> [String: CGRect] {
        let panes = items.enumerated().map { index, item in
            Pane(
                id: item.id,
                role: .annotation,
                // Per-item collapsed size — neighbour popups get a tighter
                // height because they don't render a `contextReason` line,
                // so the layout doesn't reserve a ~28pt slot the popup will
                // never fill.
                size: item.item.popupSize,
                anchor: item.anchor,
                priority: 100 + index,
                manualCenter: manualCenters[item.id],
                radialAffinity: item.item.radialAffinity.map { CGFloat($0) }
            )
        }
        return layout(
            panes: panes,
            focalPoint: focalPoint,
            sceneSize: sceneSize,
            preferredSide: preferredSide,
            reservedFrames: reservedFrames
        ).framesByID
    }

    private func frame(
        for pane: Pane,
        index: Int,
        count: Int,
        existingFrames: [CGRect],
        avoidanceFrames: [CGRect],
        focalPoint: CGPoint,
        sceneSize: CGSize,
        preferredSide: HorizontalEdge
    ) -> CGRect {
        if let manualCenter = pane.manualCenter {
            return Self.frame(center: manualCenter, size: pane.size, sceneSize: sceneSize)
        }

        let candidates = candidates(
            for: pane,
            index: index,
            count: count,
            focalPoint: focalPoint,
            sceneSize: sceneSize,
            preferredSide: preferredSide
        )
        return candidates.min {
            penalty(
                $0,
                pane: pane,
                existingFrames: existingFrames,
                avoidanceFrames: avoidanceFrames
            )
                < penalty(
                    $1,
                    pane: pane,
                    existingFrames: existingFrames,
                    avoidanceFrames: avoidanceFrames
                )
        }?.frame ?? Self.frame(center: focalPoint, size: pane.size, sceneSize: sceneSize)
    }

    private func candidates(
        for pane: Pane,
        index: Int,
        count: Int,
        focalPoint: CGPoint,
        sceneSize: CGSize,
        preferredSide: HorizontalEdge
    ) -> [Candidate] {
        let angles = preferredAngles(
            for: pane,
            index: index,
            count: count,
            preferredSide: preferredSide,
            focalPoint: focalPoint
        )
        let radialOffset = radialOffset(for: pane)
        let maxRing = maxRingCount(for: count)
        var candidates: [Candidate] = []
        var order = 0
        for ring in 0..<maxRing {
            for angle in angles {
                let center = orbitalCenter(
                    focalPoint: focalPoint,
                    paneSize: pane.size,
                    sceneSize: sceneSize,
                    angle: angle,
                    role: pane.role,
                    ring: ring,
                    radialOffset: radialOffset
                )
                candidates.append(
                    Candidate(
                        frame: Self.frame(center: center, size: pane.size, sceneSize: sceneSize),
                        angle: angle,
                        anglePenalty: abs(normalizedAngle(angle - (angles.first ?? angle))),
                        ring: ring,
                        order: order
                    )
                )
                order += 1
            }
        }
        return deduplicate(candidates)
    }

    private func preferredAngles(
        for pane: Pane,
        index: Int,
        count: Int,
        preferredSide: HorizontalEdge,
        focalPoint: CGPoint
    ) -> [CGFloat] {
        var angles: [CGFloat] = []
        if let preferredAngle = pane.preferredAngle {
            angles.append(preferredAngle)
        }

        let sideAngle: CGFloat = preferredSide == .trailing ? 0 : .pi
        let oppositeSideAngle: CGFloat = preferredSide == .trailing ? .pi : 0
        switch pane.role {
        case .primary:
            angles.append(contentsOf: [
                sideAngle,
                sideAngle - CGFloat.pi / 4,
                sideAngle + CGFloat.pi / 4,
                -CGFloat.pi / 2,
                CGFloat.pi / 2,
                oppositeSideAngle
            ])
        case .context:
            let upperOpposite = preferredSide == .trailing ? -3 * CGFloat.pi / 4 : -CGFloat.pi / 4
            let lowerOpposite = preferredSide == .trailing ? 3 * CGFloat.pi / 4 : CGFloat.pi / 4
            angles.append(contentsOf: [
                upperOpposite,
                lowerOpposite,
                -CGFloat.pi / 2,
                CGFloat.pi / 2,
                oppositeSideAngle,
                sideAngle
            ])
        case .annotation:
            angles.append(distributedAngle(index: index, count: count))
            if let anchorAngle = anchorAngle(for: pane, focalPoint: focalPoint) {
                angles.append(anchorAngle)
            }
            angles.append(contentsOf: compassAngles(startingNear: angles.first ?? 0))
        }
        return uniquedAngles(angles)
    }

    private func orbitalCenter(
        focalPoint: CGPoint,
        paneSize: CGSize,
        sceneSize: CGSize,
        angle: CGFloat,
        role: PaneRole,
        ring: Int,
        radialOffset: CGFloat = 0
    ) -> CGPoint {
        let unit = unitVector(angle: angle)
        let halfExtent = abs(unit.dx) * paneSize.width / 2 + abs(unit.dy) * paneSize.height / 2
        let roleGap: CGFloat = role == .primary ? 64 : 16
        let ringGap = CGFloat(ring) * ringStride(for: paneSize)
        let distance = Self.focalClearanceRadius(sceneSize: sceneSize)
            + halfExtent
            + Self.paneGap
            + roleGap
            + radialOffset
            + ringGap
        return LockedCardGeometry.clampedCenter(
            CGPoint(
                x: focalPoint.x + unit.dx * distance,
                y: focalPoint.y + unit.dy * distance
            ),
            cardSize: paneSize,
            sceneSize: sceneSize,
            margin: Self.sceneMargin
        )
    }

    private func penalty(
        _ candidate: Candidate,
        pane: Pane,
        existingFrames: [CGRect],
        avoidanceFrames: [CGRect]
    ) -> CGFloat {
        var score = CGFloat(candidate.order) * 0.1
            + CGFloat(candidate.ring) * ringPenalty(for: pane)
        score += candidate.anglePenalty * (pane.role == .annotation ? 80 : 34)
        score += overlapPenalty(candidate.frame, frames: avoidanceFrames, weight: 42)
        score += overlapPenalty(candidate.frame, frames: existingFrames, weight: 28)
        if let anchor = pane.anchor {
            let dx = candidate.frame.midX - anchor.x
            let dy = candidate.frame.midY - anchor.y
            score += sqrt(dx * dx + dy * dy) * 0.18
        }
        return score
    }

    private func ringPenalty(for pane: Pane) -> CGFloat {
        if pane.role == .primary {
            return 270
        }
        guard let normalized = normalizedRadialAffinity(for: pane) else {
            return 90
        }
        return 90 + normalized * 220
    }

    private func radialOffset(for pane: Pane) -> CGFloat {
        guard let normalized = normalizedRadialAffinity(for: pane) else {
            return 0
        }
        return (1 - normalized) * Self.relatedAffinityRadialSpread
    }

    private func normalizedRadialAffinity(for pane: Pane) -> CGFloat? {
        guard pane.role == .annotation,
              let affinity = pane.radialAffinity,
              affinity.isFinite else {
            return nil
        }
        return max(
            0,
            min(
                1,
                (affinity - Self.relatedAffinityFloor)
                    / (1 - Self.relatedAffinityFloor)
            )
        )
    }

    private func overlapPenalty(_ rect: CGRect, frames: [CGRect], weight: CGFloat) -> CGFloat {
        frames.reduce(CGFloat(0)) { partial, frame in
            let expanded = frame.insetBy(dx: -8, dy: -8)
            guard rect.intersects(expanded) else { return partial }
            let intersection = rect.intersection(expanded)
            return partial + max(0, intersection.width) * max(0, intersection.height) * weight
        }
    }

    private func anchorAngle(for pane: Pane, focalPoint: CGPoint) -> CGFloat? {
        guard let anchor = pane.anchor else { return nil }
        let dx = anchor.x - focalPoint.x
        let dy = anchor.y - focalPoint.y
        guard hypot(dx, dy) > 24 else { return nil }
        return atan2(dy, dx)
    }

    private func distributedAngle(index: Int, count: Int) -> CGFloat {
        let slots: [CGFloat] = [
            -CGFloat.pi / 3,
            CGFloat.pi / 3,
            -2 * CGFloat.pi / 3,
            2 * CGFloat.pi / 3,
            -CGFloat.pi / 2,
            CGFloat.pi / 2,
            CGFloat.pi,
            0
        ]
        if index < slots.count {
            return slots[index]
        }
        let total = max(count, slots.count + 1)
        return -CGFloat.pi / 2 + (2 * CGFloat.pi * CGFloat(index)) / CGFloat(total)
    }

    private func compassAngles(startingNear angle: CGFloat) -> [CGFloat] {
        let base: [CGFloat] = [
            0,
            -CGFloat.pi / 4,
            CGFloat.pi / 4,
            CGFloat.pi,
            -3 * CGFloat.pi / 4,
            3 * CGFloat.pi / 4,
            -CGFloat.pi / 2,
            CGFloat.pi / 2
        ]
        return base.sorted {
            abs(normalizedAngle($0 - angle)) < abs(normalizedAngle($1 - angle))
        }
    }

    private func maxRingCount(for paneCount: Int) -> Int {
        if paneCount <= 4 { return 2 }
        if paneCount <= 10 { return 3 }
        return 5
    }

    private func ringStride(for size: CGSize) -> CGFloat {
        max(118, min(260, max(size.width, size.height) * 0.56 + Self.paneGap))
    }

    private func unitVector(angle: CGFloat) -> CGVector {
        CGVector(dx: cos(angle), dy: sin(angle))
    }

    private func deduplicate(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        for candidate in candidates {
            let alreadyPresent = result.contains {
                abs($0.frame.midX - candidate.frame.midX) < 0.5
                    && abs($0.frame.midY - candidate.frame.midY) < 0.5
                    && abs($0.frame.width - candidate.frame.width) < 0.5
                    && abs($0.frame.height - candidate.frame.height) < 0.5
            }
            if !alreadyPresent {
                result.append(candidate)
            }
        }
        return result
    }

    private func uniquedAngles(_ angles: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for angle in angles {
            let alreadyPresent = result.contains { existing in
                abs(normalizedAngle(existing - angle)) < 0.001
            }
            if !alreadyPresent {
                result.append(angle)
            }
        }
        return result
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
