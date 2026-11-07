import SwiftUI
import OhiaCore

/// Overlay layer that decorates the multitrack area (NOT the top pane) with
/// AI-derived annotations: action items, unresolved threads, deadlines,
/// contradictions, duplicates. Toggled via the AI-layer strip near the
/// ruler.
///
/// Initial scaffold — `TimelineDataController` does not yet populate
/// `aiAnnotations` in the snapshot. Full integration with
/// `ConstellationQAService` is a follow-up.
struct TimelineAIAnnotationLayer: View {
    @Bindable var workspace: TimelineWorkspaceState

    var body: some View {
        Canvas { context, size in
            guard let snapshot = workspace.currentSnapshot else { return }
            for annotation in snapshot.aiAnnotations
                where workspace.aiLayers.contains(annotation.kind) {
                let x = TimelineProjector(
                    viewportRange: workspace.viewportRange,
                    viewportPixelsPerDay: workspace.viewportPixelsPerDay,
                    laneOrder: snapshot.laneOrder,
                    laneHeight: 0
                ).x(for: annotation.date)
                let dot = CGRect(x: x - 3, y: 4, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(tint(for: annotation.kind)))
            }
        }
        .allowsHitTesting(false)
    }

    private func tint(for kind: TimelineLayoutSnapshot.AIAnnotation.Kind) -> Color {
        switch kind {
        case .actionItems:    return OhiaColors.accentBlue
        case .unresolved:     return OhiaColors.accentOrange
        case .deadlines:      return OhiaColors.accentPink
        case .contradictions: return OhiaColors.accentTeal
        case .duplicates:     return OhiaColors.textSecondary
        }
    }
}
