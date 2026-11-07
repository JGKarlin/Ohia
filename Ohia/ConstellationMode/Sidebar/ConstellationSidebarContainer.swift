import SwiftUI

/// Which phase of the slide the panel is in. Drives the AppKit divider animation
/// in `SplitNSView`. The split view is ALWAYS mounted (so the detail — the Metal
/// scene — is never re-parented / rebuilt); `.closed` collapses the sidebar pane
/// to width 0 and suppresses the divider so it reads as detail-only.
enum SidebarSlidePhase: Equatable {
    case closed
    case opening
    case open
    case closing
}

struct ConstellationSidebarContainer<Sidebar: View, Detail: View>: View {
    let placement: ConstellationSidebarPlacement
    let isVisible: Bool
    @Binding var sidebarWidth: Double
    let minSidebarWidth: CGFloat
    let maxSidebarWidth: CGFloat
    let onDetailFrameChange: (CGRect) -> Void
    let onSidebarWidthCommit: (CGFloat) -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    /// Duration of each slide direction (open and close are each ~1s).
    static var slideDuration: Double { 1.0 }

    // CRITICAL: the split view stays mounted in EVERY phase, including `.closed`.
    // The detail (the Metal `ConstellationMetalView`) is expensive to recreate — a
    // fresh mount builds a new `MTKView`/`CAMetalLayer` and re-installs the whole
    // render packet. The old design swapped the split out for a bare `detail()`
    // when closed, so OPENING re-parented and rebuilt the scene mid-animation (the
    // stutter); CLOSING didn't, which is why only closing was smooth. Keeping the
    // split permanently mounted means the scene is built once and only ever
    // resizes — so opening slides as smoothly as closing. Only the SIDEBAR slot is
    // mounted/unmounted (gated below), and that's light.
    @State private var slidePhase: SidebarSlidePhase = .closed
    @State private var didInitialize = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion collapses the slide to an instant change.
    private var effectiveSlideDuration: Double {
        reduceMotion ? 0 : Self.slideDuration
    }

    /// The panel's settled width — the width it's laid out at while sliding.
    /// Mirrors the split view's `clampSidebarWidth` (including its non-finite
    /// guard) so the wrapper's fixed width can't diverge from the divider's target.
    private var targetSidebarWidth: CGFloat {
        let width = CGFloat(sidebarWidth)
        guard width.isFinite else { return minSidebarWidth }
        return min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    /// While sliding, the full-width panel is pinned to its DIVIDER-side edge and
    /// clipped, so it translates in/out as a unit (its divider edge tracks the
    /// divider while the rest slides into view) rather than re-flowing.
    private var revealAlignment: Alignment {
        placement == .leading ? .trailing : .leading
    }

    var body: some View {
        ConstellationSidebarSplitView(
            placement: placement,
            sidebarWidth: $sidebarWidth,
            minSidebarWidth: minSidebarWidth,
            maxSidebarWidth: maxSidebarWidth,
            slidePhase: slidePhase,
            slideDuration: effectiveSlideDuration,
            onSlideOpened: {
                if slidePhase == .opening { slidePhase = .open }
            },
            onSlideClosed: {
                // Symmetric guard with `onSlideOpened`: if the user re-opened
                // during the async gap after a close finished, the phase is already
                // `.opening` and a fresh open slide is running — ignore the stale
                // close so we don't collapse a panel that's sliding back in.
                if slidePhase == .closing { slidePhase = .closed }
            },
            onDetailFrameChange: onDetailFrameChange,
            onSidebarWidthCommit: onSidebarWidthCommit,
            sidebar: { revealedSidebar() },
            detail: detail
        )
        .id(placement)
        .onAppear {
            // First appearance reflects the current visibility WITHOUT a slide —
            // a restored-open sidebar shouldn't animate in on launch.
            guard !didInitialize else { return }
            didInitialize = true
            slidePhase = isVisible ? .open : .closed
        }
        .onChange(of: isVisible) { _, nowVisible in
            slidePhase = nowVisible ? .opening : .closing
        }
    }

    /// The sidebar content for the split's sidebar pane. Mounted only while the
    /// panel is at all revealed (opening / open / closing); fully collapsed it's an
    /// empty placeholder so the panel's work (e.g. the Withheld IMAP fetch) doesn't
    /// run while hidden. While sliding the panel is pinned to a FIXED full width and
    /// revealed by clipping — laying the heavy tree out once instead of re-flowing
    /// at every intermediate width — and at `.open` the width constraint drops so
    /// the panel fills the host and live divider-resizing is unaffected. The
    /// opening/open transition keeps one identity (a conditional `width:` value, not
    /// an `if`/`else`), so the panel never rebuilds across it.
    @ViewBuilder private func revealedSidebar() -> some View {
        if slidePhase == .closed {
            Color.clear
        } else {
            let isSliding = slidePhase == .opening || slidePhase == .closing
            sidebar()
                .frame(width: isSliding ? targetSidebarWidth : nil)
                .frame(maxWidth: .infinity, alignment: revealAlignment)
                .clipped()
        }
    }
}
