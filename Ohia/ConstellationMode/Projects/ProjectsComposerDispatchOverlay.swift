import SwiftUI
import OhiaCore

/// Draws the send-to-Composer dispatch comet over the Projects time canvas.
///
/// Projects send targets the focused project row's needs-reply messages (a bulk
/// set), each drawn as a dot on the scrolling canvas. The comet launches from
/// each queued message's dot — its rect recorded in the shared `ProjectsHitTester`
/// during the canvas draw, in the same content coordinate space this overlay
/// draws in — and streaks toward the Composer window, then fades. The message
/// stays in place (overlay flourish, like Meaning / People / Timeline; shared
/// drawing in `ComposerDispatchCometRenderer`).
///
/// Mounted as a sibling above the message canvas, inside the scroll content so it
/// tracks the rows vertically; its own `TimelineView` pauses whenever idle. A
/// dispatch whose message has no recorded dot — filtered out, or not in the
/// current draw — is simply skipped. A scrolled-off dot still has a rect (the
/// Canvas spans the full content height, not just the viewport), so its comet is
/// clipped by the visible viewport rather than skipped.
struct ProjectsComposerDispatchOverlay: View {
    let coordinator: ComposerDispatchCoordinator
    let hitTester: ProjectsHitTester
    /// The visible viewport size, used to scale the comet's travel distance. The
    /// hosting Canvas is content-height-sized (often much taller than the
    /// viewport), so travel must key off the viewport or the comet would streak
    /// far too fast.
    let viewportSize: CGSize
    var enabled: Bool = true

    var body: some View {
        // Reading `dispatches` here establishes observation, so a `begin()` while
        // idle re-evaluates this body and un-pauses the TimelineView below.
        let dispatches = coordinator.dispatches
        let active = enabled && !dispatches.isEmpty

        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, _ in
                guard active, viewportSize.width > 0, viewportSize.height > 0 else { return }
                let now = timeline.date
                for (id, dispatch) in dispatches {
                    guard let rect = hitTester.rect(forMessageID: id) else { continue }
                    let phase = ComposerDispatchPhase(elapsed: max(0, now.timeIntervalSince(dispatch.start)))
                    ComposerDispatchCometRenderer.draw(
                        &ctx,
                        size: viewportSize,
                        origin: CGPoint(x: rect.midX, y: rect.midY),
                        direction: dispatch.direction,
                        phase: phase,
                        tint: dispatch.tint
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
