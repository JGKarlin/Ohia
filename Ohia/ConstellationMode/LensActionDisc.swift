import SwiftUI

enum LensLegendVisibilityPreference {
    static let storageKey = "constellationLensLegendsVisible"
    static let defaultValue = true

    static func showsLegend(
        requestedBySurface: Bool = true,
        legendsVisible: Bool
    ) -> Bool {
        requestedBySurface && legendsVisible
    }

    static func showsControl(label: String, legendsVisible: Bool) -> Bool {
        label != "Legend" || showsLegend(legendsVisible: legendsVisible)
    }
}

/// Shared 38pt action disc used by every Constellation lens control column
/// (Meaning / People / Front Page / Timeline / Projects rails and the inline
/// chrome discs in `ConstellationModeView`).
///
/// The disc keeps the established chrome — a faint `surface` fill that lights to
/// `chipActiveBackground` when engaged, a state-aware ring, visibly dim only
/// when disabled — and renders a unified circle-family glyph (`.circle.fill`
/// natively, or a non-circle glyph knocked out of a filled tinted disc) at ~26pt
/// for presence.
///
/// Beneath the disc it carries a one-word gloss label. Label visibility is
/// driven by `\.lensActionDiscLabelsVisible`, which each column flips off via
/// `responsiveActionDiscLabels()` when the window is too short to fit both the
/// discs and their labels. There is intentionally no `.help()` tooltip — the
/// gloss label is the affordance.
struct LensActionDisc: View {
    @Environment(\.lensActionDiscLabelsVisible) private var labelsVisible
    @AppStorage(LensLegendVisibilityPreference.storageKey)
    private var legendsVisible = LensLegendVisibilityPreference.defaultValue

    let glyph: ActionDiscGlyph
    let label: String
    /// VoiceOver label (the gloss text is decorative / accessibility-hidden).
    let accessibility: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    /// When set, the glyph/ring render in this colour instead of the
    /// default `chipActiveForeground`/`chipActiveBorder` pair — full
    /// strength while active, dimmed by the same inactive fraction as every
    /// other disc otherwise, so status discs match the rest of the column's
    /// active/inactive weight rather than staying permanently lit.
    var tint: Color?
    var destructive: Bool = false
    /// Front Page rails opt in so a control moving during card reflow records
    /// the press before SwiftUI's normal mouse-up activation can be cancelled.
    var capturesPressDown: Bool = false
    let action: () -> Void

    /// Glyph point size inside the 38pt disc.
    private let glyphSize: CGFloat = 26

    @ViewBuilder var body: some View {
        if LensLegendVisibilityPreference.showsControl(
            label: label,
            legendsVisible: legendsVisible
        ) {
            VStack(spacing: 3) {
                RapidActionButton(capturesPressDown: capturesPressDown, action: action) {
                    discFace
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(accessibility)
                if labelsVisible {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(labelTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: 62)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var discFace: some View {
        ZStack {
            Circle().fill(isActive ? OhiaColors.chipActiveBackground : OhiaColors.surface(isEnabled ? 0.14 : 0.10))
            ActionDiscGlyphView(glyph: glyph, tint: glyphTint, size: glyphSize)
        }
        .frame(width: 38, height: 38)
        .overlay { Circle().strokeBorder(ringTint, lineWidth: 1) }
        .contentShape(Circle())
    }

    /// Inactive discs dim to this fraction of their active glyph/ring
    /// strength — applied uniformly whether the disc uses the default
    /// `chipActiveForeground`/`chipActiveBorder` pair or a custom `tint`, so
    /// every "not currently active" disc reads at the same visual weight.
    private static let inactiveGlyphOpacity: Double = 0.72
    private static let inactiveRingOpacity: Double = 0.56

    private var glyphTint: Color {
        if !isEnabled { return OhiaColors.chipActiveBorder.opacity(0.18) }
        if destructive { return OhiaColors.ohiaRed }
        let base = tint ?? OhiaColors.chipActiveForeground
        return isActive ? base : base.opacity(Self.inactiveGlyphOpacity)
    }

    private var ringTint: Color {
        if !isEnabled { return OhiaColors.chipActiveBorder.opacity(0.18) }
        if destructive { return OhiaColors.ohiaRed.opacity(0.5) }
        if let tint {
            return isActive
                ? tint.opacity(0.5)
                : tint.opacity(0.5 * Self.inactiveRingOpacity)
        }
        return isActive ? OhiaColors.chipActiveBorder : OhiaColors.chipActiveBorder.opacity(Self.inactiveRingOpacity)
    }

    private var labelTint: Color {
        guard isEnabled else { return OhiaColors.textTertiary }
        return OhiaColors.textSecondary
    }
}

/// The glyph a `LensActionDisc` renders. `.native` adopts an SF `.circle.fill`
/// symbol directly; `.knockout` punches a non-circle glyph out of a filled
/// tinted disc so it matches the `.circle.fill` family; `.markReplied` is the
/// bespoke reply-circle-plus-check composite.
enum ActionDiscGlyph: Equatable {
    case native(String)
    case knockout(String)
    case markReplied
}

/// Renders an `ActionDiscGlyph` at `size`, tinted `tint`, sized to read like a
/// `.circle.fill` whether native or knocked out.
///
/// When `cutoutFill` is set the glyph's inner cutout — the dark hole that shows
/// the surface through it at rest — is filled with that colour instead. The
/// disc keeps `tint`; only the inner icon lifts to a contrasting hue. This is
/// the §3.10 button-chip hover state (see `ClusterButtonChip`); the 38pt
/// `LensActionDisc` never passes it, so its chrome discs are unaffected.
struct ActionDiscGlyphView: View {
    let glyph: ActionDiscGlyph
    let tint: Color
    let size: CGFloat
    var cutoutFill: Color? = nil

    var body: some View {
        switch glyph {
        case .native(let name):
            filledCircleGlyph(name)
        case .knockout(let name):
            KnockoutGlyph(symbol: name, tint: tint, cutoutFill: cutoutFill, diameter: size * 0.92)
        case .markReplied:
            MarkRepliedCircleGlyph(tint: tint, cutoutFill: cutoutFill, size: size)
        }
    }

    /// A `.circle.fill` SF symbol. At rest it renders monochrome — the inner
    /// glyph is a transparent cutout, so the dark surface reads through it. On
    /// hover it switches to two-tone palette rendering: the inner glyph layer
    /// fills `cutoutFill` while the disc layer keeps `tint`. It recolours the
    /// symbol's own layers in place, so the disc never shifts size between rest
    /// and hover — the same technique the Withheld row's restore/delete chip
    /// relies on (it renders through this very `ClusterButtonChip`).
    @ViewBuilder private func filledCircleGlyph(_ name: String) -> some View {
        let symbol = Image(systemName: name).font(.system(size: size, weight: .semibold))
        if let cutoutFill {
            symbol.symbolRenderingMode(.palette).foregroundStyle(cutoutFill, tint)
        } else {
            symbol.foregroundStyle(tint)
        }
    }
}

/// A filled tinted circle with the glyph punched out, matching how `.circle.fill`
/// symbols render. `.compositingGroup()` flattens the stack first so
/// `.destinationOut` carves the glyph from the disc; the hole shows the disc
/// fill behind it.
private struct KnockoutGlyph: View {
    let symbol: String
    let tint: Color
    var cutoutFill: Color? = nil
    let diameter: CGFloat

    var body: some View {
        ZStack {
            // On hover, a backing disc in `cutoutFill` shows through the punched
            // glyph; the tinted compositing group above occludes it elsewhere.
            if let cutoutFill {
                Circle().fill(cutoutFill)
            }
            ZStack {
                Circle().fill(tint)
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.58, weight: .bold))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Circle-family analog of `MarkRepliedGlyph`: the filled reply circle with a
/// small confirmation-tinted check badge ("reply handled"). The badge halo
/// matches the engaged disc fill so it reads as a separate token.
private struct MarkRepliedCircleGlyph: View {
    let tint: Color
    var cutoutFill: Color? = nil
    let size: CGFloat

    var body: some View {
        replyCircle
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(MessageStatusColors.confirmation)
                    .background(Circle().fill(OhiaColors.chipActiveBackground).padding(-1))
                    .offset(x: size * 0.14, y: size * 0.12)
            }
    }

    /// The reply circle; on hover its inner arrow fills `cutoutFill` via the same
    /// palette technique as `filledCircleGlyph`. The confirmation badge is a
    /// separate "reply handled" token and keeps its green.
    @ViewBuilder private var replyCircle: some View {
        let symbol = Image(systemName: "arrowshape.turn.up.left.circle.fill")
            .font(.system(size: size, weight: .semibold))
        if let cutoutFill {
            symbol.symbolRenderingMode(.palette).foregroundStyle(cutoutFill, tint)
        } else {
            symbol.foregroundStyle(tint)
        }
    }
}

// MARK: - Button chip (§3.10)

/// The §3.10 button chip: a compact, glyph-only inline message-status action
/// (reply / confirm / resolve / flag / delete) rendered through the shared 16pt
/// `ActionDiscGlyphView` in a 26×24 hit target, with no disc chrome. The
/// canonical references are the Front Page card hover cluster and the Composer
/// queue row actions.
///
/// At rest the inner icon is knocked out of the tinted disc (the dark surface
/// shows through). On hover the chip reads as *active*: the inner icon and a ring
/// hugging the disc edge both fill the contrasting emblem hue from
/// `clusterButtonHoverFill(forDiscTint:)` — so the ring stays crisp against the
/// disc on every chip — and the whole chip lifts ~1.08× so it sits
/// pressed-forward. The disc `tint` is invariant across the transition — only the
/// inner icon, ring, and scale move. The lift honours Reduce Motion (colour still
/// changes; the scale snaps).
struct ClusterButtonChip: View {
    let glyph: ActionDiscGlyph
    let tint: Color
    let help: String
    /// Hit-frame width around the 16pt glyph (height is fixed at 24). Defaults to
    /// 26 — the Front Page / Composer cluster width. The Withheld row passes a
    /// narrower value so the restore/delete glyph carries less padding on its
    /// left/right sides.
    var width: CGFloat = 26
    /// Front Page cards opt in because their hit targets can move while a
    /// neighbouring card exits and the mosaic reflows.
    var capturesPressDown: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Diameter of the hover ring — sized to hug the ~16pt disc edge.
    private let ringDiameter: CGFloat = 17

    var body: some View {
        RapidActionButton(capturesPressDown: capturesPressDown, action: action) {
            let hoverHue = clusterButtonHoverFill(forDiscTint: tint)
            ActionDiscGlyphView(
                glyph: glyph,
                tint: tint,
                size: 16,
                cutoutFill: isHovering ? hoverHue : nil
            )
            .frame(width: width, height: 24)
            .overlay {
                if isHovering {
                    Circle()
                        .stroke(hoverHue, lineWidth: 1.5)
                        .frame(width: ringDiameter, height: ringDiameter)
                }
            }
            .scaleEffect(isHovering ? 1.08 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }
}

/// De-duplicates the press-down capture from the standard Button activation
/// that follows on mouse-up. Kept as a value type so the exact input sequence
/// is covered without UI automation.
struct RapidActionButtonActivationGate {
    private var capturedCurrentPress = false

    mutating func capturePressDown() -> Bool {
        guard capturedCurrentPress == false else { return false }
        capturedCurrentPress = true
        return true
    }

    func captureStandardActivation() -> Bool {
        capturedCurrentPress == false
    }

    mutating func finishPress() {
        capturedCurrentPress = false
    }
}

/// A normal SwiftUI Button with an opt-in mouse-down capture path. Keyboard and
/// accessibility activation retain the standard Button action; pointer presses
/// fire immediately, before an animated reflow can move the control out from
/// under the pending mouse-up.
private struct RapidActionButton<Label: View>: View {
    let capturesPressDown: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var activationGate = RapidActionButtonActivationGate()

    var body: some View {
        let button = Button {
            if activationGate.captureStandardActivation() {
                action()
            }
        } label: {
            label()
        }

        if capturesPressDown {
            button.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if activationGate.capturePressDown() {
                            action()
                        }
                    }
                    .onEnded { _ in
                        // Button's mouse-up action is delivered in this event
                        // turn. Reset on the next turn so it sees the captured
                        // press and does not dispatch a duplicate command.
                        Task { @MainActor in
                            await Task.yield()
                            activationGate.finishPress()
                        }
                    }
            )
        } else {
            button
        }
    }
}

/// Inner-icon fill revealed when a §3.10 button chip is hovered, paired to
/// contrast with the disc's own `tint` in both light and dark. The confirmation
/// (green) disc and the delete (red) disc both take flat stamen yellow; every
/// other disc uses the mode-aware active accent, so it takes the inverse-accent
/// fill.
///
/// The comparison is against the exact `MessageStatusColors` / `OhiaColors`
/// tokens the cluster call sites pass, so `Color` value-equality is reliable
/// here — each branch resolves to a single shared static value.
func clusterButtonHoverFill(forDiscTint tint: Color) -> Color {
    if tint == OhiaColors.ohiaRed {
        return OhiaColors.clusterHoverFillOnRed
    }
    if tint == MessageStatusColors.confirmation {
        return OhiaColors.clusterHoverFillOnGreen
    }
    return OhiaColors.clusterHoverFillOnAccent
}

// MARK: - Responsive label visibility

private struct LensActionDiscLabelsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether `LensActionDisc` should show its one-word gloss label. Flipped off
    /// by `responsiveActionDiscLabels()` on short windows.
    var lensActionDiscLabelsVisible: Bool {
        get { self[LensActionDiscLabelsVisibleKey.self] }
        set { self[LensActionDiscLabelsVisibleKey.self] = newValue }
    }
}

extension View {
    /// Wraps a control-column disc stack so its gloss labels show when the
    /// labelled layout fits the available height and are dropped when the window
    /// is too short. Backed by `ViewThatFits`: the labels-on candidate is
    /// preferred; the labels-off candidate is the fallback.
    ///
    /// Apply to the column's inner stack (the `VStack` of discs), before the
    /// `.frame` / `.background` / starburst-overlay chrome.
    func responsiveActionDiscLabels() -> some View {
        ViewThatFits(in: .vertical) {
            environment(\.lensActionDiscLabelsVisible, true)
            environment(\.lensActionDiscLabelsVisible, false)
        }
    }
}

/// Reserves the 38pt slot the overlaid starburst beacon occupies at the top of a
/// control column, and — when labels are visible — carries the beacon's own
/// "Beacon" gloss label beneath it so the beacon matches the labelled discs.
/// Lives inside the responsive disc stack, so it reads the same label-visibility
/// decision and hides on short windows alongside the disc labels.
struct StarburstLabelSlot: View {
    @Environment(\.lensActionDiscLabelsVisible) private var labelsVisible

    var body: some View {
        VStack(spacing: 3) {
            Color.clear.frame(height: 38)
            if labelsVisible {
                Text("Beacon")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 62)
                    .accessibilityHidden(true)
            }
        }
    }
}
