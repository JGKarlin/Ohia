import SwiftUI

/// Animation token for Constellation hover popups — a snappy spring with
/// mild overshoot. The same curve runs both directions so the pane reads
/// as "drawn out of, and sucked back into, the hovered dot."
enum ConstellationHoverPopupMotion {
    static let appear = Animation.spring(response: 0.30, dampingFraction: 0.74)
}

/// Computes the genie scale anchor — the UnitPoint within the popup's
/// frame that the hovered dot sits at. The popup's collapsed state is
/// pinned at that point so it appears to draw out of (and suck back
/// into) the dot, independent of which quadrant the placement code
/// chose for the pane.
enum HoverPopupGenieAnchor {
    static func compute(
        nodePoint: CGPoint,
        popupCenter: CGPoint,
        popupSize: CGSize
    ) -> UnitPoint {
        let width = max(1, popupSize.width)
        let height = max(1, popupSize.height)
        let topLeftX = popupCenter.x - popupSize.width / 2
        let topLeftY = popupCenter.y - popupSize.height / 2
        return UnitPoint(
            x: (nodePoint.x - topLeftX) / width,
            y: (nodePoint.y - topLeftY) / height
        )
    }
}

/// Interpolates the popup from a dot-pinned sliver to full size.
private struct GenieCollapseModifier: ViewModifier, Animatable {
    let anchor: UnitPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scale.x, y: scale.y, anchor: anchor)
            .opacity(min(max(progress, 0), 1))
    }

    private var scale: CGPoint {
        let along: CGFloat = 0.02
        let across: CGFloat = 0.10
        let xOff = abs(anchor.x - 0.5)
        let yOff = abs(anchor.y - 0.5)
        // The "along" axis is the one with the larger anchor offset —
        // that's the direction the pane points at the dot, so it's the
        // axis the pane should pinch tightest along.
        let collapsed = yOff >= xOff
            ? CGPoint(x: across, y: along)
            : CGPoint(x: along, y: across)
        return CGPoint(
            x: collapsed.x + (1 - collapsed.x) * progress,
            y: collapsed.y + (1 - collapsed.y) * progress
        )
    }
}

/// Scales opacity for a manually driven genie popup whose final position is
/// already chosen. The anchor is the hovered dot's unit-space location in the
/// popup's final frame, so the pane pinches into the dot without center travel.
private struct GeniePinnedModifier: ViewModifier, Animatable {
    let anchor: UnitPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scale.x, y: scale.y, anchor: anchor)
            .opacity(visibleOpacity)
    }

    private var scale: CGPoint {
        let along: CGFloat = 0.02
        let across: CGFloat = 0.10
        let xOff = abs(anchor.x - 0.5)
        let yOff = abs(anchor.y - 0.5)
        let collapsed = yOff >= xOff
            ? CGPoint(x: across, y: along)
            : CGPoint(x: along, y: across)
        return CGPoint(
            x: collapsed.x + (1 - collapsed.x) * progress,
            y: collapsed.y + (1 - collapsed.y) * progress
        )
    }

    private var visibleOpacity: CGFloat {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        return max(0.18, clamped)
    }
}

private struct ConstellationHoverPopupEmergeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.transition(.opacity)
    }
}

private struct ConstellationHoverNodeIndicatorEmergeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: 0.25, anchor: .center).combined(with: .opacity)
    }
}

extension View {
    /// Pane body — appears at its already-computed screen position without
    /// resizing or moving between hover targets.
    func constellationHoverPopupEmerge() -> some View {
        modifier(ConstellationHoverPopupEmergeModifier())
    }

    /// Squeeze/stretch for a manually retained genie popup whose final frame
    /// is stable and whose scale anchor is the hovered dot.
    func constellationHoverPopupGenie(progress: CGFloat, anchor: UnitPoint) -> some View {
        modifier(GeniePinnedModifier(anchor: anchor, progress: progress))
    }

    /// Reticle at the hovered dot — blooms from the dot center.
    func constellationHoverNodeIndicatorEmerge() -> some View {
        modifier(ConstellationHoverNodeIndicatorEmergeModifier())
    }
}
