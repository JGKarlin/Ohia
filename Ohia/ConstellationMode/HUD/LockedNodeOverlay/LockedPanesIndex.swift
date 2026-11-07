import SwiftUI
import OhiaCore

/// Pure data shape describing what the kind-chip strip should render.
/// The overlay computes this once per body pass
/// from `rankedAnnotations`; the view never touches the controller or
/// the items directly. Stays Sendable / Equatable so SwiftUI can cheap-
/// diff it between layout passes.
struct LockedPanesIndexData: Equatable {
    /// One entry per kind that has at least one pane. The main email stays
    /// first; evidence kinds follow by the strongest pane in that kind.
    struct KindGroup: Identifiable, Equatable {
        let kind: AnnotationKind
        /// Total number of panes of this kind.
        let count: Int
        /// Global rank indices (into the parent's `rankedAnnotations`
        /// array) for every pane of this kind, in rank order.
        let globalIndices: [Int]
        /// Position of the focused pane within this kind, or `nil` when
        /// no pane of this kind is currently focused. 1-based for the
        /// user-facing label (`👥 2/4`).
        let activeSubIndex: Int?

        var id: String { kind.rawValue }
    }

    let groups: [KindGroup]
    let totalCount: Int
    /// Caption text rendered under the chips when a pane is focused —
    /// e.g. `from same person · 2 of 4 · 0.92` for a neighbour, or
    /// `attachment · 1 of 2` for an attachment. `nil` when nothing is
    /// focused; the view falls back to a generic "Tab to step" hint.
    let focusCaption: String?
    /// Optional lens-specific caption used when no pane is focused. The People
    /// correspondent card uses this to summarize the ring as emails instead of
    /// exposing the generic pane-navigation hint.
    let fallbackCaption: String?
}

struct LockedPanesIndex: View {
    let data: LockedPanesIndexData
    /// `nil` when no pane is rank-focused. Drives chip highlight.
    let focusedGlobalIndex: Int?
    /// Accent that overrides the focal chip (`.mainEmail` for normal
    /// locks, `.correspondent` for People locks), so focal chrome matches
    /// the rendered node/hub.
    var mainEmailAccentOverride: Color? = nil
    /// Whether to render the caption row beneath the chips. The caption
    /// names the selected pane (`this email · 1 of 1`, `received · 2 of 4`,
    /// etc.) so lens panes can explain which chip is currently active
    /// without duplicating that state elsewhere.
    var showsCaption: Bool = true
    /// People-lens ring band colors keyed by `PersonRingInstance.Tier.insideOutIndex`
    /// (order: `receivedDirect`, `included`, `sentDirect`, `sentIncluded`).
    /// When non-empty the People-tier chips colour-match the rendered Saturn
    /// ring bands one-to-one — the user can read the chip strip as a legend
    /// for the rings around the hub planet. When empty (preview / test
    /// paths) the chips fall back to the static Twilight `tier.tierColor`
    /// palette via `peopleChipAccent(lockAccent:)`.
    var peopleRingTierColors: [Color] = []
    /// Cycle to the next pane within `kind`. The host advances the global
    /// rank index within that kind, wrapping at the end.
    let onChipClick: (AnnotationKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipStrip
            if showsCaption {
                captionLine
            }
        }
    }

    private func accent(for kind: AnnotationKind) -> Color {
        if kind.isFocalPaneKind, let override = mainEmailAccentOverride {
            return override
        }
        // People-kind chips colour-match the rendered Saturn ring bands.
        // Each `PersonRingInstance.Tier` indexes into `peopleRingTierColors`
        // (which the host computed via `AccountColorPalette.tierBandColorsRGB`
        // — the same picker the Metal renderer uses to paint the bands).
        // The chip then applies the tier's `ringAlpha` so the chip's
        // opacity tracks the band's translucency — direct tiers solid,
        // included tiers dim. Falls back to the static Twilight
        // `tier.tierColor` palette only when the host hasn't supplied
        // ring colors (preview / test paths).
        if let tier = kind.personRingTier {
            let idx = tier.insideOutIndex
            if peopleRingTierColors.indices.contains(idx) {
                return peopleRingTierColors[idx].opacity(Double(tier.ringAlpha))
            }
            return kind.peopleChipAccent(lockAccent: mainEmailAccentOverride)
        }
        return kind.accent
    }

    private var chipStrip: some View {
        // Wrap so a long kind list (rare, but possible with 4+ kinds at
        // narrow widths) breaks onto a second row instead of clipping.
        FlowingRow(spacing: 6) {
            ForEach(data.groups) { group in
                KindChip(
                    group: group,
                    isAnyFocused: focusedGlobalIndex != nil,
                    accent: accent(for: group.kind),
                    onTap: { onChipClick(group.kind) }
                )
            }
        }
    }

    private var captionLine: some View {
        let label: String = data.focusCaption
            ?? data.fallbackCaption
            ?? "\(data.totalCount) pane\(data.totalCount == 1 ? "" : "s") · ⇥ to step · space to expand"
        let foreground: Color = data.focusCaption == nil
            ? OhiaColors.textTertiary
            : OhiaColors.accentTeal
        return Text(label)
            .font(OhiaTypography.annotationBody)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

private struct KindChip: View {
    let group: LockedPanesIndexData.KindGroup
    let isAnyFocused: Bool
    /// Resolved accent for this chip. For focal kinds this is threaded
    /// from the host; for evidence kinds it's the kind's static accent.
    let accent: Color
    let onTap: () -> Void

    private var isActive: Bool { group.activeSubIndex != nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: group.kind.symbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                if let sub = group.activeSubIndex {
                    Text("\(sub)/\(group.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                } else {
                    Text("\(group.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.opacity(isActive ? 0.22 : 0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        accent.opacity(isActive ? 0.95 : 0.45),
                        lineWidth: isActive ? 1.5 : 1
                    )
            }
            // Slightly desaturate / dim when *another* kind has focus —
            // makes the active chip pop without hiding the other counts.
            .opacity(isAnyFocused && !isActive ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help(chipHelpText)
        .accessibilityLabel(chipAccessibilityLabel)
    }

    private var chipHelpText: String {
        // A terse one-line phrase naming what the chip represents. The count
        // is already visible on the chip and click-to-cycle is self-evident,
        // so neither is repeated here — appending them produced a multi-line
        // tooltip that wrapped into an awkward block. The full sentence still
        // backs the VoiceOver label below.
        group.kind.tabTooltip
    }

    private var chipAccessibilityLabel: String {
        if let sub = group.activeSubIndex {
            return "\(group.kind.pluralLabel) chip, \(sub) of \(group.count), active. \(group.kind.description)"
        }
        return "\(group.kind.pluralLabel) chip, \(group.count) total. \(group.kind.description)"
    }
}

private extension AnnotationKind {
    var isFocalPaneKind: Bool {
        self == .mainEmail || self == .correspondent
    }
}

/// Lightweight flow layout used by the chip strip so a long row of kinds
/// wraps to a second line at narrow widths instead of clipping or
/// triggering SwiftUI's truncation. Doesn't try to be a general-purpose
/// flow — just the minimum needed for `LockedPanesIndex`.
private struct FlowingRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
