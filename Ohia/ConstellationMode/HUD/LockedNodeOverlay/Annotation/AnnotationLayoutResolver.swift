import CoreGraphics
import Foundation
import SwiftUI

struct AnnotationLayoutResolver {
    struct LayoutSolution: Equatable {
        let framesByID: [String: CGRect]
        let visibleItems: [ScreenAnnotationItem]
    }

    func layout(
        items: [ScreenAnnotationItem],
        lockCardFrame: CGRect,
        sceneSize: CGSize,
        focalPoint: CGPoint? = nil,
        preferredSide: HorizontalEdge = .trailing,
        manualCenters: [String: CGPoint] = [:],
        hoverPriorityIDs: Set<String> = []
    ) -> LayoutSolution {
        layout(
            items: items,
            avoidanceFrames: [lockCardFrame],
            sceneSize: sceneSize,
            focalPoint: focalPoint,
            preferredSide: preferredSide,
            manualCenters: manualCenters,
            hoverPriorityIDs: hoverPriorityIDs
        )
    }

    func layout(
        items: [ScreenAnnotationItem],
        avoidanceFrames: [CGRect],
        sceneSize: CGSize,
        focalPoint: CGPoint? = nil,
        preferredSide: HorizontalEdge = .trailing,
        manualCenters: [String: CGPoint] = [:],
        hoverPriorityIDs: Set<String> = []
    ) -> LayoutSolution {
        guard sceneSize.width > 1, sceneSize.height > 1 else {
            return LayoutSolution(framesByID: [:], visibleItems: [])
        }

        let visible = items.filter {
            $0.anchor.x >= 0
                && $0.anchor.y >= 0
                && $0.anchor.x <= sceneSize.width
                && $0.anchor.y <= sceneSize.height
        }
        let ordered = visible.sorted { lhs, rhs in
            let leftHover = hoverPriorityIDs.contains(lhs.id)
            let rightHover = hoverPriorityIDs.contains(rhs.id)
            if leftHover != rightHover { return leftHover }
            if lhs.item.kind.priority != rhs.item.kind.priority {
                return lhs.item.kind.priority < rhs.item.kind.priority
            }
            if lhs.item.radialAffinity != rhs.item.radialAffinity {
                return (lhs.item.radialAffinity ?? -Double.infinity)
                    > (rhs.item.radialAffinity ?? -Double.infinity)
            }
            if lhs.item.importance != rhs.item.importance {
                return lhs.item.importance > rhs.item.importance
            }
            return lhs.id < rhs.id
        }
        let resolvedFocalPoint = focalPoint ?? CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        let frames = FocusedOverlayPaneLayoutCoordinator().annotationFrames(
            items: ordered,
            manualCenters: manualCenters,
            focalPoint: resolvedFocalPoint,
            sceneSize: sceneSize,
            preferredSide: preferredSide,
            reservedFrames: avoidanceFrames
        )
        return LayoutSolution(framesByID: frames, visibleItems: ordered)
    }
}
