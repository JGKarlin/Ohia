import CoreGraphics
import simd

/// Per-frame layout snapshot produced once at the top of `LockedNodeOverlay.body`.
///
/// The overlay body re-evaluates at 60 Hz inside a `TimelineView` so the
/// reticle, tether, and card stay anchored to the locked node while the
/// camera moves. The math that derives the card size, telemetry pane frame,
/// focal point, and layer plan from the current scene size is purely
/// derivative — collapsing it into one value keeps the view tree readable and
/// gives every subview a single consistent snapshot to draw against.
struct LockedOverlayLayoutResolution {
    let sceneSize: CGSize
    let world: SIMD3<Float>?
    let focalPoint: CGPoint
    let telemetryAttachments: [LockedAttachmentSummary]
    let telemetryPaneSize: CGSize
    let liveCenter: CGPoint
    let lockCardFrame: CGRect
    let telemetryFrame: CGRect?
    let layerPlan: LockedOverlayLayoutCoordinator.LayerPlan
}
