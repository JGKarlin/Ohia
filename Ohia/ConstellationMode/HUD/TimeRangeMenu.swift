import SwiftUI
import OhiaCore

/// Top-bar pull-down menu for `TimeRangePreset` selection. When the user
/// picks `.custom`, a popover anchored to the trigger button presents two
/// `DatePicker`s (via the existing `DateRangeFilterControl`). The trigger
/// label shows the formatted range when `.custom` is active.
///
/// Rendered as `Button + popover` rather than SwiftUI `Menu` because
/// `.menuStyle(.borderlessButton)` silently strips trailing chrome from
/// custom labels on macOS — the trailing chevron was disappearing under
/// the Menu API. Same pattern as `ToolbarSection`'s pulldown.
public struct TimeRangeMenu: View {

    @Binding public var selected: TimeRangePreset
    @Binding public var customRange: ClosedRange<Date>?
    /// Per-preset message counts shown in parens after each row label and
    /// after the trigger pill. Counts are raw population counts by time
    /// window; the TopBar filter and lens pipelines own visible narrowing.
    /// `.custom` only carries a count when a `customRange` has been
    /// configured; otherwise the row stays plain.
    public let counts: [TimeRangePreset: Int]
    /// Called after the binding is mutated so the parent can apply
    /// downstream side effects (e.g. logging, refresh kick).
    public let onSelect: (TimeRangePreset) -> Void

    @State private var presetPopoverShown = false
    @State private var customPopoverShown = false

    public init(
        selected: Binding<TimeRangePreset>,
        customRange: Binding<ClosedRange<Date>?>,
        counts: [TimeRangePreset: Int] = [:],
        onSelect: @escaping (TimeRangePreset) -> Void
    ) {
        self._selected = selected
        self._customRange = customRange
        self.counts = counts
        self.onSelect = onSelect
    }

    public var body: some View {
        Button {
            if selected == .custom {
                customPopoverShown = true
            } else {
                presetPopoverShown.toggle()
            }
        } label: {
            triggerLabel
        }
        .buttonStyle(.plain)
        .fixedSize()
        .tooltip("Time range")
        .popover(isPresented: $presetPopoverShown, arrowEdge: .bottom) {
            presetPicker
        }
        .popover(isPresented: $customPopoverShown, arrowEdge: .bottom) {
            DateRangeFilterControl(range: $customRange)
                .padding(12)
                .frame(minWidth: 280)
        }
    }

    private var triggerLabel: some View {
        // Mirrors `.menu` in the design preview HTML: 22pt-tall pill,
        // horizontal padding 8, gap 5, 11pt label, 9pt chevron at 0.55
        // opacity, 1px border. The time range is *always* an active filter
        // — even `.all` is a deliberate "no upper bound" choice — so the
        // pill uses the Ohia accent (green in light, amber/yellow in dark)
        // to match the `chip on` styling rather than the neutral pill
        // chrome. Font weight 600 mirrors `.intents.on` / `.chip.on`.
        HStack(spacing: 5) {
            Text(triggerTitle)
                .font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.55)
        }
        .foregroundStyle(OhiaColors.chipActiveForeground)
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(OhiaColors.chipActiveBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(OhiaColors.chipActiveBorder, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TimeRangePreset.allCases) { preset in
                Button {
                    selected = preset
                    presetPopoverShown = false
                    if preset == .custom {
                        Task { @MainActor in customPopoverShown = true }
                    } else {
                        customRange = nil
                    }
                    onSelect(preset)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preset.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(rowLabel(for: preset))
                            .font(.system(size: 12))
                        Spacer()
                        if preset == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 160, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    /// Popover row label. The count suffix is suppressed entirely when no
    /// counts have been computed yet (cold launch) so the menu never
    /// flashes a misleading `(0)` for every preset. `.custom` keeps the
    /// plain `Custom…` label until a real range is configured — the
    /// helper omits its key from the dict in that case so the
    /// `counts[preset] ?? 0` fallback never fires for it.
    private func rowLabel(for preset: TimeRangePreset) -> String {
        let baseTitle = preset.title
        if counts.isEmpty { return baseTitle }
        if preset == .custom && counts[.custom] == nil { return baseTitle }
        let count = counts[preset] ?? 0
        return "\(baseTitle) (\(count.formatted(.number)))"
    }

    private var triggerTitle: String {
        let base: String
        if selected == .custom, let range = customRange {
            // `triggerTitle` is read on every body pass; previously a fresh
            // `DateFormatter` was constructed each time, which is expensive
            // (locale / calendar / timezone tables). `Date.FormatStyle` is a
            // value type with cached internals — safe to call inline.
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            base = "\(range.lowerBound.formatted(style)) – \(range.upperBound.formatted(style))"
        } else {
            base = selected.title
        }
        if counts.isEmpty { return base }
        if selected == .custom && counts[.custom] == nil { return base }
        let count = counts[selected] ?? 0
        return "\(base) (\(count.formatted(.number)))"
    }

}
