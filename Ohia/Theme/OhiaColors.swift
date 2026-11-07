import SwiftUI
import AppKit

// OhiaColors — two paired palettes.
//
// Dark is the authored aesthetic: Ghost-in-the-Shell neon on near-black.
// Light is system-standard macOS: semantic NSColor tokens, desaturated
// accents, black.opacity surfaces in place of white.opacity.
//
// Every token resolves via NSColor(name:dynamicProvider:) and therefore
// tracks the window's effective appearance — including the user's
// override set in Settings → General (preferredColorScheme cascades to
// NSAppearance inside SwiftUI windows).

private func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [
            .darkAqua,
            .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark
        ]) != nil
        return isDark ? dark : light
    }
}

private func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: dynamicNSColor(light: light, dark: dark))
}

private func semanticColor(light: NSColor, dark: NSColor) -> Color {
    dynamicColor(light: light, dark: dark)
}

private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
}

enum OhiaColors {
    // MARK: - Backgrounds

    static let spaceBackground = dynamicColor(
        light: NSColor.windowBackgroundColor,
        dark: srgb(0.02, 0.02, 0.03)                // #050508
    )
    static let wizardBackground = dynamicColor(
        light: NSColor.windowBackgroundColor,
        dark: srgb(0.04, 0.04, 0.06)                // #0a0a10
    )
    /// Cool cloud tints layered over the night sky when a spatial surface
    /// needs a stronger sense of depth. These stay fixed across appearances
    /// because `NightSkyView` is intentionally always dark.
    static let nightSkyNebulaBlue = Color(.sRGB, red: 0.11, green: 0.28, blue: 0.58, opacity: 1)
    static let nightSkyNebulaTeal = Color(.sRGB, red: 0.10, green: 0.44, blue: 0.50, opacity: 1)
    /// Fill for a card in the Settings window. Black in dark so the card reads
    /// as a cut-out against the night sky framing the pane — the app's usual
    /// `glassPanel` is a translucent white overlay, which over stars renders as
    /// sky-plus-haze rather than a surface. Light keeps the system card colour.
    ///
    /// Scoped to Settings: the Constellation surfaces still want `glassPanel`,
    /// whose translucency is the point there.
    static let settingsCard = dynamicColor(
        light: NSColor.controlBackgroundColor,
        dark: NSColor.black
    )
    static let glassPanel = surface(0.03)
    static let glassBorder = surface(0.08)
    /// Slightly brighter than glassBorder, for dividers that signal a
    /// peer-cluster grouping (e.g., the toolbar's display-controls cluster).
    static let glassBorderBright = surface(0.15)

    // MARK: - Accents
    //
    // Neon in dark, desaturated-but-still-hued in light so they read as
    // colored signal rather than system gray.

    static let accentBlue = dynamicColor(
        light: srgb(0.14, 0.39, 0.88),              // #2463e0
        dark: srgb(0.39, 0.53, 1.0)                 // #6488ff
    )
    static let accentBlueGlow = dynamicColor(
        light: srgb(0.24, 0.48, 0.94),              // #3d7bf0
        dark: srgb(0.50, 0.66, 1.0)                 // #80a8ff
    )
    static let accentGreen = dynamicColor(
        light: srgb(0.09, 0.58, 0.36),              // #17955b
        dark: srgb(0.27, 0.80, 0.53)                // #44cc88
    )
    static let accentOrange = dynamicColor(
        light: srgb(0.85, 0.40, 0.09),              // #d96518
        dark: srgb(1.0, 0.53, 0.27)                 // #ff8844
    )
    /// Legacy token retained for call-site stability. Teal signals now use
    /// the canonical Ohia green so confirmation/resolved affordances match
    /// the app's emblem grammar.
    static let accentTeal = ohiaGreen
    static let confirmationSignal = ohiaGreen
    static let accentPink = dynamicColor(
        light: srgb(0.66, 0.23, 0.49),              // #a83b7d
        dark: srgb(0.80, 0.40, 0.67)                // #cc66aa
    )
    static let accentPurple = dynamicColor(
        light: srgb(0.49, 0.21, 0.75),              // #7c36bf
        dark:  srgb(0.63, 0.39, 0.86)               // #a064dc
    )

    // Canonical ʻōhiʻa lehua pair — taken from the Get Started button in
    // WelcomeStepView. Green is the leaf, yellow is the stamen yolk.
    // These are flat values that read across modes; pair them with the
    // mode-aware chipActive* tokens below for tinted UI surfaces.
    static let ohiaGreen = Color(.sRGB, red: 112 / 255, green: 184 / 255, blue: 24 / 255, opacity: 1)
    static let ohiaYellow = Color(.sRGB, red: 248 / 255, green: 248 / 255, blue: 56 / 255, opacity: 1)
    static let ohiaRed = Color(.sRGB, red: 232 / 255, green: 56 / 255, blue: 56 / 255, opacity: 1)

    // MARK: - Active-filter chip (mode-aware)
    //
    // The single accent the Constellation top bar uses to mean
    // "this filter is shaping the constellation right now." Resolves to
    // ohiaGreen on light surfaces (mid-luminance — carries on near-white)
    // and ohiaYellow on dark surfaces (high-luminance — sings on near-black).
    // The text/foreground value is deepened in light mode for legibility on
    // the tinted fill; dark mode uses the yellow directly.

    static let chipActiveBackground = dynamicColor(
        light: srgb(112 / 255, 184 / 255, 24 / 255, 0.14),
        dark:  srgb(248 / 255, 248 / 255, 56 / 255, 0.18)
    )
    static let chipActiveBorder = dynamicColor(
        light: srgb(112 / 255, 184 / 255, 24 / 255, 0.60),
        dark:  srgb(248 / 255, 248 / 255, 56 / 255, 0.60)
    )
    static let chipActiveForeground = dynamicColor(
        light: srgb(0.31, 0.518, 0.063),            // #4f8410 — deepened ohia green
        dark:  srgb(248 / 255, 248 / 255, 56 / 255) // #F8F838 — ohia yellow itself
    )

    // MARK: - Button-chip hover fill (§3.10)
    //
    // The inner icon of a button chip is a knockout at rest (the dark surface
    // shows through the disc glyph). On hover the chip reads as *active*: the
    // inner icon fills a contrasting emblem hue so it lifts off the disc. The
    // fill must contrast with the disc's own tint in BOTH modes:
    //   • Reply / flag discs use the mode-aware active accent — green in light,
    //     yellow in dark — so their hover fill is the INVERSE accent (yellow in
    //     light against the green disc, green in dark against the yellow disc).
    //   • The always-green confirmation disc takes flat stamen yellow.
    //   • The always-red delete disc also takes flat stamen yellow.
    // Sanctioned direct use of the flat emblem hues outside the emblem-button
    // motif (cf. §3.1) — these are the named tokens that route it.
    static let clusterHoverFillOnAccent = dynamicColor(
        light: srgb(248 / 255, 248 / 255, 56 / 255), // ohia yellow on the green light-mode disc
        dark:  srgb(112 / 255, 184 / 255, 24 / 255)  // ohia green on the yellow dark-mode disc
    )
    static let clusterHoverFillOnGreen = ohiaYellow // yellow inner on the green confirmation disc
    static let clusterHoverFillOnRed = ohiaYellow   // yellow inner on the red delete disc

    // MARK: - Chip rest state
    //
    // Background and border for an unpressed filter chip — slightly
    // stronger than the previous `surface(0.03)` / `glassBorder`
    // values so the chip's rectangle reads as a discrete shape on the
    // dark toolbar surface rather than blending in. Matches the design
    // preview's `--D-chip` (0.06) and `--D-chip-stroke` (0.10) tokens.

    static let chipRestBackground = dynamicColor(
        light: NSColor(white: 0, alpha: 0.04),
        dark:  srgb(0.122, 0.122, 0.125)            // solid #1f1f20 — same
                                                    // "lighter dark shade"
                                                    // as iconPillBackground
                                                    // so chips and pulldowns
                                                    // share one rest tone
                                                    // in dark mode
    )
    static let chipRestBorder = dynamicColor(
        light: NSColor(white: 0, alpha: 0.085),
        dark:  NSColor(white: 1, alpha: 0.12)
    )

    // MARK: - Toolbar surfaces (Constellation top bar)
    //
    // Mail.app-aligned solid surfaces. Replaces the prior translucent
    // `.ultraThinMaterial` background for the bar, and gives the section
    // headers a small NSPopUpButton-shaped icon-pill backdrop.
    //
    // The bar background is intentionally NOT a `surface(_:)` overlay —
    // it sits below all content and needs an opaque value to stop the
    // Constellation scene behind from bleeding through.

    /// Toolbar bg follows light/dark. Dark = `#050508` (matches the
    /// constellation 3D scene's space backdrop, so the bar reads as
    /// part of the same surface). Light = `#f6f6f6` (Mail.app's light
    /// surface from the design preview). Both values are literal sRGB
    /// to avoid binding to macOS's `windowBackgroundColor`, which
    /// follows the system appearance rather than Ohia's preferred
    /// scheme — that was causing the light-mode bar to render dark
    /// when macOS was set to Dark while Ohia was forced to Light.
    static let toolbarBackground = dynamicColor(
        light: srgb(0.965, 0.965, 0.965),           // #f6f6f6
        dark:  srgb(0.02, 0.02, 0.03)               // #050508
    )

    /// Structural Composer surfaces. In Dark Mode these use the same pure-
    /// black card language as Settings; Light Mode preserves the Composer's
    /// existing Mail.app-aligned surfaces.
    static let composerPanelBackground = dynamicColor(
        light: srgb(0.965, 0.965, 0.965),
        dark: NSColor.black
    )
    static let composerRaisedPanelBackground = dynamicColor(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor.black
    )

    /// Backdrop for section-header icon pills, pulldowns, and the
    /// search field. Reads as a "lighter dark shade" against the dark
    /// toolbar bg, and as a faint darker tint against the light bg —
    /// chrome is always slightly stronger than the surface so the
    /// affordance is visible in both modes.
    static let iconPillBackground = dynamicColor(
        light: NSColor(white: 0, alpha: 0.045),
        dark:  srgb(0.122, 0.122, 0.125)            // solid #1f1f20
    )
    static let iconPillBorder = dynamicColor(
        light: NSColor(white: 0, alpha: 0.085),
        dark:  NSColor(white: 1, alpha: 0.12)
    )
    /// SF Symbol color inside an icon pill — slightly subdued from
    /// textPrimary so the pill reads as inert chrome at rest.
    static let iconPillForeground = dynamicColor(
        light: srgb(0.227, 0.227, 0.227),           // #3a3a3a
        dark:  srgb(0.847, 0.847, 0.847)            // #d8d8d8
    )

    /// Fill for the selected option inside a segmented control
    /// (FrameSelectorBar). The HTML preview lifts the active option to a
    /// solid white pill in light mode (so the chosen frame reads as
    /// elevated chrome against the segmented track) and to a translucent
    /// white at 18% alpha in dark mode (where solid white would shout).
    /// Pairs with a 1pt y-shadow on the segment for the lifted effect.
    static let segmentedSelectedFill = dynamicColor(
        light: NSColor.white,
        dark:  NSColor(white: 1, alpha: 0.18)
    )

    // MARK: - Hover readout (Constellation node tooltip)
    //
    // Atmospheric vertical gradient — a hint of cooler / brighter tone at
    // the top fading to a slightly cooler base at the bottom. The popup
    // reads as part of the constellation's atmosphere rather than a flat
    // Mac dialog, while staying within the framework's calm, solid-surface
    // register (no neon, no frosted glass, no gradient noise).
    //
    // Stops are flattened from the browser mockup's base+overlay layers
    // so the SwiftUI render matches the preview exactly.

    static let hoverReadoutGradientTop = dynamicColor(
        light: srgb(0.992, 0.992, 0.996),           // #fdfdfe — base + 85% white
        dark:  srgb(0.067, 0.086, 0.141)            // #111624 — base + cool tint
    )
    static let hoverReadoutGradientBottom = dynamicColor(
        light: srgb(0.906, 0.925, 0.957),           // #e7ecf4 — base + cool wash
        dark:  srgb(0.039, 0.047, 0.078)            // #0a0c14 — solid base
    )

    // MARK: - Text

    static let textPrimary = semanticColor(
        light: NSColor.labelColor,
        dark: srgb(0.88, 0.88, 0.91)                // #e0e0e8
    )
    static let nsTextPrimary = dynamicNSColor(
        light: NSColor.labelColor,
        dark: srgb(0.88, 0.88, 0.91)                // #e0e0e8
    )
    static let textSecondary = semanticColor(
        light: NSColor.secondaryLabelColor,
        dark: srgb(0.53, 0.53, 0.63)                // #8888a0
    )
    static let nsTextSecondary = dynamicNSColor(
        light: NSColor.secondaryLabelColor,
        dark: srgb(0.53, 0.53, 0.63)                // #8888a0
    )
    static let textTertiary = semanticColor(
        light: NSColor.tertiaryLabelColor,
        dark: srgb(0.33, 0.33, 0.42)                // #555568
    )
    static let nsTextTertiary = dynamicNSColor(
        light: NSColor.tertiaryLabelColor,
        dark: srgb(0.33, 0.33, 0.42)                // #555568
    )
    static let nsLinkText = dynamicNSColor(
        light: srgb(0.14, 0.39, 0.88),              // #2463e0 — accentBlue
        dark:  srgb(0.39, 0.53, 1.0)                // #6488ff — accentBlue
    )
    static let textDim = semanticColor(
        light: NSColor.quaternaryLabelColor,
        dark: srgb(0.27, 0.27, 0.35)                // #444458
    )
    /// Fill behind the locked-overlay direction strip (the "sent /
    /// received" pill). Low-alpha opposite-of-mode tint so the
    /// ohiaYellow glyphs read against both the void and bright nebula
    /// patches without the strip becoming a solid chip.
    static let annotationMarkBackground = dynamicColor(
        light: srgb(0, 0, 0, 0.45),
        dark:  srgb(0, 0, 0, 0.55)
    )
    /// Border around the direction strip. Mode-different by design:
    /// each side ties to its mode's own accent — deepened ohia green
    /// at high alpha in light mode (the same green token the active
    /// chips use), ohia yellow at moderate alpha in dark mode — so the
    /// pill outline reads as part of the §18 accent family rather than
    /// generic chrome.
    static let annotationMarkBorder = dynamicColor(
        light: srgb(0.31, 0.518, 0.063, 0.85),       // deepened ohia green
        dark:  srgb(248 / 255, 248 / 255, 56 / 255, 0.65)
    )

    // MARK: - Interactive

    static let buttonBackground = dynamicColor(
        light: srgb(0.14, 0.39, 0.88, 0.12),
        dark: srgb(0.39, 0.53, 1.0, 0.15)
    )
    static let buttonBorder = dynamicColor(
        light: srgb(0.14, 0.39, 0.88, 0.35),
        dark: srgb(0.39, 0.53, 1.0, 0.30)
    )
    static let buttonText = dynamicColor(
        light: srgb(0.12, 0.31, 0.77),              // #1f4fc4
        dark: srgb(0.50, 0.66, 1.0)                 // #80a8ff
    )

    // MARK: - Language chips

    static let chipSelected = dynamicColor(
        light: srgb(0.08, 0.58, 0.31),              // #15934e
        dark: srgb(0.39, 0.78, 0.55)                // #64c88c
    )
    static let chipSelectedBackground = dynamicColor(
        light: srgb(0.08, 0.58, 0.31, 0.12),
        dark: srgb(0.39, 0.78, 0.55, 0.10)
    )
    static let chipSelectedBorder = dynamicColor(
        light: srgb(0.08, 0.58, 0.31, 0.40),
        dark: srgb(0.39, 0.78, 0.55, 0.30)
    )

    // MARK: - Activity strip pipeline dots
    // Distinct neon signals in dark mode; still saturated but less hot in
    // light mode so the bottom strip stays readable.

    static let pipelineIngested = accentGreen
    static let pipelineParsed = accentBlue
    static let pipelineInterpreted = accentPurple
    static let pipelineSummarized = accentPink
    // Not accentTeal — that now aliases ohiaGreen (see accentTeal doc comment
    // above), which collides with the `trained` dot's flat ohiaGreen. Orange
    // is the only accent-family token unused elsewhere in this strip.
    static let pipelineEmbedded = accentOrange
    static let pipelineCreated = accentBlueGlow
    static let pipelinePlaced = dynamicColor(
        light: srgb(0.73, 0.24, 0.95),              // #ba3df2
        dark: srgb(0.72, 0.42, 1.0)                 // #b86bff
    )
    /// Bespoke, not accent-family: `trained` previously hardcoded flat
    /// `ohiaGreen`, which collides with `ingested`'s green and also breaks
    /// the design-system rule against using `ohiaGreen` outside the
    /// emblem-button motif (docs/design-system.md §3.9). Cyan/turquoise is
    /// the one hue family not already claimed by another pipeline dot.
    static let pipelineTrained = dynamicColor(
        light: srgb(0.02, 0.55, 0.62),               // #048c9e
        dark: srgb(0.20, 0.85, 0.90)                 // #33d9e6
    )

    // MARK: - Map Mode — pane borders

    static let paneAction = dynamicColor(
        light: srgb(0.82, 0.28, 0.19),              // #d14830
        dark: srgb(1.0, 0.34, 0.27)                 // #ff5844
    )
    static let paneDrafts = accentGreen
    static let paneReports = accentTeal
    static let paneNewsletters = accentPurple
    static let paneReceipts = dynamicColor(
        light: srgb(0.78, 0.48, 0.12),              // #c77a1f
        dark: srgb(1.0, 0.66, 0.27)                 // #ffaa44
    )

    // MARK: - Map Mode — status badges

    static let statusAwaiting = paneReceipts
    static let statusReady = accentGreen
    static let statusOverride = accentBlue

    // MARK: - Map Mode — frame colors (urgency)

    static let frameUrgencyLow = accentBlue
    static let frameUrgencyMid = paneReceipts
    static let frameUrgencyHigh = paneAction

    // MARK: - Map Mode — glass panels

    static let glassPanelBackground = surface(0.03)
    static let glassPanelBorder = surface(0.08)
    static let glassPanelBackgroundBright = surface(0.045)
    static let glassPanelBorderBright = surface(0.12)

    // MARK: - Focus Mode

    static let focusSources = accentTeal
    static let focusStyle = paneNewsletters
    static let focusEditor = accentBlue
    static let focusTraining = paneReceipts
    static let annotationTeal = ohiaGreen.opacity(0.30)
    static let annotationPurple = dynamicColor(
        light: srgb(0.49, 0.21, 0.75, 0.25),
        dark: srgb(0.63, 0.39, 0.86, 0.30)
    )
    static let annotationOrange = dynamicColor(
        light: srgb(0.85, 0.40, 0.09, 0.25),
        dark: srgb(1.0, 0.53, 0.27, 0.30)
    )

    // MARK: - Adaptive surfaces
    //
    // Replacement for every `Color.white.opacity(x)` in views. In dark
    // mode the fill is white (lifts off near-black); in light mode it
    // flips to black (a subtle shade on near-white). Opacity value is
    // the same across modes — kept as the original author tuned it.

    static func surface(_ opacity: Double) -> Color {
        dynamicColor(
            light: NSColor(white: 0, alpha: CGFloat(opacity)),
            dark: NSColor(white: 1, alpha: CGFloat(opacity))
        )
    }
}
