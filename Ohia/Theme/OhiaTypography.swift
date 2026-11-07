import SwiftUI

// Typography tokens for Ohia. See docs/design-system.md for the spec.
// SF Mono is banned app-wide; every token below resolves to SF Pro.
// Where a token used to carry `design: .monospaced`, the mono has
// been removed and the call site should rely on layout-based
// alignment for any column behavior it needs.
enum OhiaTypography {
    static let appTitle = Font.system(size: 36, weight: .bold)
    static let stepHeading = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 15)
    static let bodySecondary = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    /// Historically `Font.system(size: 11, design: .monospaced)`. Mono
    /// is banned (docs/design-system.md §1); the token name is kept to
    /// avoid churn at existing call sites but resolves to plain SF Pro
    /// — identical to `caption`. New code should prefer `caption`.
    static let mono = Font.system(size: 11)
    static let button = Font.system(size: 14, weight: .medium)
    static let buttonLarge = Font.system(size: 15, weight: .semibold)
    static let chip = Font.system(size: 14)

    // Map Mode — cards
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let cardBody = Font.system(size: 13)
    static let cardDetail = Font.system(size: 11)
    static let cardSignal = Font.system(size: 10)
    static let cardLedger = Font.system(size: 13)

    // Map Mode — header bar
    static let headerFrame = Font.system(size: 12, weight: .medium)
    static let headerScope = Font.system(size: 11)
    static let headerCount = Font.system(size: 11)

    // Map Mode — questions
    static let questionText = Font.system(size: 14)
    static let questionOption = Font.system(size: 13, weight: .medium)

    // Focus Mode
    static let editorBody = Font.system(size: 15)
    static let editorAnnotation = Font.system(size: 10)
    static let neighborTitle = Font.system(size: 13, weight: .medium)
    static let neighborExcerpt = Font.system(size: 12)
    static let neighborScore = Font.system(size: 10)
    static let diffSignal = Font.system(size: 13)

    // MARK: - Constellation telemetry register (docs/design-system.md §2.7)
    //
    // Locked-node overlay readout register. Plain SF Pro at compact
    // sizes; column alignment is achieved through layout (fixed-width
    // label column, right-aligned), never through font metrics.

    /// Left column of a two-column telemetry row ("thread", "started",
    /// "last reply", "status"). Paired with `OhiaColors.textTertiary`
    /// and a `.frame(width: 72, alignment: .trailing)` so the value
    /// column starts at a stable x across rows.
    static let telemetryLabel = Font.system(size: 10)

    /// Right column of a two-column telemetry row — the value. Paired
    /// with `OhiaColors.textPrimary`.
    static let telemetryValue = Font.system(size: 11)

    /// Emphasized variant of `telemetryValue` for counters or status
    /// tokens that should pop ("47 unread", warn states).
    static let telemetryEmphasis = Font.system(size: 11, weight: .semibold)

    /// UPPERCASED small-caps banners inside the locked-node overlay
    /// ("CONTEXT", "ATTACHMENTS · 3"). Apply with
    /// `.tracking(1.0).textCase(.uppercase)` and
    /// `OhiaColors.chipActiveForeground` for the active-accent variant
    /// or `OhiaColors.textTertiary` for an inert banner.
    static let telemetrySectionCaps = Font.system(size: 9.5, weight: .semibold)

    /// Coordinate-style readout strip ("α 04ʰ28ᵐ · δ −12°45′ · …").
    /// Paired with `OhiaColors.textSecondary`.
    static let coordReadout = Font.system(size: 10.5)

    /// Body text inside an `AnnotationPopup` and the evidence /
    /// detail lines under a telemetry banner. Paired with
    /// `OhiaColors.textSecondary`.
    static let annotationBody = Font.system(size: 9.5)

    /// Filename line in an attachment row. Paired with
    /// `OhiaColors.textPrimary`.
    static let attachmentRowName = Font.system(size: 11)

    /// Trailing meta in an attachment row ("PDF · 2.4 MB"). Paired
    /// with `OhiaColors.textTertiary`.
    static let attachmentRowMeta = Font.system(size: 9.5)

    /// Reader-facing attachment summary paragraph in the Front Page mail view.
    /// Larger than telemetry meta so extracted document descriptions remain
    /// legible when the catalog sits below the message body.
    static let attachmentRowDescription = Font.system(size: 12.5)

    /// Single-line rows inside the locked-node overlay legend
    /// (keyboard-shortcut affordances). Paired with
    /// `OhiaColors.textTertiary`.
    static let legendLine = Font.system(size: 10)
}
