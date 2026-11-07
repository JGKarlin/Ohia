import SwiftUI
import OhiaCore

/// Bottom multitrack area: row gutter on the left (one row per
/// `TimelineMultitrackRow`), canvas on the right (rows + context ticks
/// + focused-email chips). The playhead-input layer overlays the canvas
/// to capture pointer-driven scrub edge cases that the canvas's drag
/// gesture would miss (e.g., clicking inside the gutter strip).
///
/// The earlier filter strip (attachment-kind chips + correspondent chips)
/// lived above the canvas; both have been removed because they
/// duplicated information already surfaced by the focused-email chip
/// rows below.
struct TimelineMultitrackArea: View {

    @Bindable var workspace: TimelineWorkspaceState
    /// Constellation-wide filter state. Multitrack chips drive this
    /// directly (clicking the sender chip writes the correspondent
    /// filter; clicking the account chip toggles an account in
    /// `filter.accountIds`; etc.) so the chip activation is
    /// two-way-bound to the ConstellationTopBar's filter chips.
    @Bindable var constellationState: ConstellationState
    /// Forwarded to the canvas: clicks on attachment chips open the
    /// underlying file rather than toggling a filter. The
    /// `ModelContext` lookup lives in the parent so the canvas itself
    /// stays free of SwiftData access.
    let onOpenAttachment: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TimelineRowGutter(workspace: workspace)
                .frame(width: TimelineRuler.gutterAlignmentWidth)
                .background(OhiaColors.glassPanel)

            ZStack(alignment: .topLeading) {
                TimelineCanvasView(
                    workspace: workspace,
                    constellationState: constellationState,
                    onOpenAttachment: onOpenAttachment
                )
                TimelinePlayheadInput(workspace: workspace)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OhiaColors.spaceBackground)
            .background(
                TimelineEventCatcher(onScroll: { deltaY, modifiers in
                    workspace.handleScroll(deltaY: deltaY, modifiers: modifiers)
                })
            )
            .overlay(
                // ohiaGreen hairline sits exactly where the SwiftUI
                // focus ring used to draw (around the canvas only —
                // gutter labels stay outside the frame). The ring is
                // suppressed via `.focusEffectDisabled()` on
                // `TimelinePlayheadInput`, so this is the only border
                // visible around the workspace.
                Rectangle()
                    .strokeBorder(OhiaColors.ohiaGreen, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
