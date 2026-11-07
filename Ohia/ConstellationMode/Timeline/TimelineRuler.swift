import AppKit
import SwiftUI
import OhiaCore

/// Adaptive time-axis ruler. Tick cadence (year / month / week / day) is
/// chosen from the current zoom and viewport span. Owns the playhead
/// handle and the playhead's vertical cursor line; together with the
/// matching line drawn by `TimelineCanvasView`, the cursor reads as one
/// continuous yellow column descending from the ruler through the lanes.
///
/// Gestures: plain drag / click scrubs the playhead. Shift-drag paints
/// `workspace.bracketedRange`. Cmd-click clears the bracket. Transport
/// chrome (Threads, magnification, message / chapter arrows) lives in
/// `TimelineRightControlColumn` — the trailing transport column that
/// used to live on the ruler was moved there so every Constellation lens
/// shares the same right-edge button grammar.
struct TimelineRuler: View {

    @Bindable var workspace: TimelineWorkspaceState

    @State private var dragAnchor: Date?
    @State private var dragCurrent: Date?

    var body: some View {
        // Prime `@Observable` tracking so the Canvas closure re-renders
        // when these stored properties change. Reads inside the Canvas
        // draw closure don't register on their own — the body has to
        // touch them eagerly.
        _ = workspace.viewportRange
        _ = workspace.viewportPixelsPerDay
        _ = workspace.bracketedRange
        _ = workspace.playhead
        _ = workspace.currentSnapshot

        return HStack(spacing: 0) {
            // Leading spacer matches the multitrack's `TimelineRowGutter`
            // width so the ruler canvas and the multitrack canvas share
            // the same x-origin. Without this, the playhead arrow drawn
            // here and the focused-email chip column drawn below would
            // sit in different screen columns for the same date.
            Color.clear
                .frame(width: Self.gutterAlignmentWidth, height: Self.rulerHeight)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let projector = makeProjector(width: size.width)
                        drawTicks(context: context, size: size, projector: projector)
                        drawBracketOverlay(context: context, size: size, projector: projector)
                        drawPlayhead(context: context, size: size, projector: projector)
                    }
                    .gesture(rulerGesture(width: proxy.size.width))
                }
                .frame(height: Self.rulerHeight)
            }
            .frame(height: Self.rulerHeight)
        }
        .frame(height: Self.rulerHeight)
        .background(OhiaColors.glassPanel)
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }

    /// Total height of the ruler band. Tall enough to host a date bubble,
    /// 11pt tick labels, major / minor ticks, and the playhead handle
    /// without any of them overlapping each other.
    static let rulerHeight: CGFloat = 40

    /// Leading column width — matches `TimelineRowGutter.width` so the
    /// ruler canvas and the multitrack canvas share an x-origin and the
    /// playhead arrow aligns with the focused-email chip column. Sized
    /// for the longest row label ("Attachments") at 11pt regular plus
    /// the 14pt icon column and 8+8pt horizontal padding — 110pt covers
    /// it with no slack now that the S/M toggles are gone.
    static let gutterAlignmentWidth: CGFloat = 110

    // MARK: - Projector

    private func makeProjector(width: CGFloat) -> TimelineProjector {
        let span = workspace.viewportRange.upperBound.timeIntervalSince(workspace.viewportRange.lowerBound)
        let days = span / TimelineProjector.secondsPerDay
        let ppd = days > 0 ? Double(width) / days : workspace.viewportPixelsPerDay
        return TimelineProjector(
            viewportRange: workspace.viewportRange,
            viewportPixelsPerDay: ppd,
            originX: 0,
            laneOrder: [],
            laneHeight: 0
        )
    }

    // MARK: - Ticks

    private func drawTicks(
        context: GraphicsContext,
        size: CGSize,
        projector: TimelineProjector
    ) {
        let cadence = TimelineRulerCadence.choose(
            viewportRange: workspace.viewportRange,
            pixelsPerDay: projector.viewportPixelsPerDay
        )
        let dates = cadence.ticks(in: workspace.viewportRange)
        // Stronger contrast for major ticks than the previous
        // secondary/tertiary pair — major now reads at primary text
        // weight so the ruler is legible without leaning into the
        // multitrack.
        let majorTickColor = OhiaColors.textPrimary
        let minorTickColor = OhiaColors.textSecondary.opacity(0.6)
        let majorLabelColor = OhiaColors.textPrimary

        for tick in dates {
            let x = projector.x(for: tick.date)
            guard x >= -2 && x <= size.width + 2 else { continue }
            let tickLength: CGFloat = tick.major ? 14 : 7
            var path = Path()
            path.move(to: CGPoint(x: x, y: size.height - tickLength))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path,
                with: .color(tick.major ? majorTickColor : minorTickColor),
                lineWidth: tick.major ? 1.25 : 1
            )

            if tick.major, let label = cadence.label(for: tick.date) {
                let text = Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(majorLabelColor)
                context.draw(
                    text,
                    at: CGPoint(x: x + 3, y: size.height - tickLength - 11),
                    anchor: .leading
                )
            }
        }
    }

    // MARK: - Bracket overlay

    private func drawBracketOverlay(
        context: GraphicsContext,
        size: CGSize,
        projector: TimelineProjector
    ) {
        guard let range = effectiveDragRange() ?? workspace.bracketedRange else { return }
        let x0 = projector.x(for: range.lowerBound)
        let x1 = projector.x(for: range.upperBound)
        let rect = CGRect(
            x: min(x0, x1),
            y: 0,
            width: abs(x1 - x0),
            height: size.height
        )
        context.fill(
            Path(rect),
            with: .color(OhiaColors.ohiaYellow.opacity(0.18))
        )
        var marker = Path()
        marker.move(to: CGPoint(x: rect.minX, y: 0))
        marker.addLine(to: CGPoint(x: rect.minX, y: size.height))
        marker.move(to: CGPoint(x: rect.maxX, y: 0))
        marker.addLine(to: CGPoint(x: rect.maxX, y: size.height))
        context.stroke(marker, with: .color(OhiaColors.ohiaYellow), lineWidth: 1)
    }

    private func effectiveDragRange() -> ClosedRange<Date>? {
        guard let anchor = dragAnchor, let current = dragCurrent else { return nil }
        let lower = min(anchor, current)
        let upper = max(anchor, current)
        return lower...upper
    }

    // MARK: - Playhead

    private func drawPlayhead(
        context: GraphicsContext,
        size: CGSize,
        projector: TimelineProjector
    ) {
        let x = projector.x(for: workspace.playhead)

        // Vertical cursor line spanning the full ruler band; meets the
        // multitrack canvas's playhead line one hairline below so the
        // cursor reads as a single continuous column.
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(OhiaColors.ohiaYellow), lineWidth: 1.5)

        // Downward-pointing triangle handle sitting just above the ruler's
        // bottom border so the apex visually descends into the multitrack
        // canvas without the hairline border clipping its tip.
        let handleHalfWidth: CGFloat = 8
        let handleHeight: CGFloat = 11
        let handleBaseY = size.height - 1
        var handle = Path()
        handle.move(to: CGPoint(x: x, y: handleBaseY))
        handle.addLine(to: CGPoint(x: x - handleHalfWidth, y: handleBaseY - handleHeight))
        handle.addLine(to: CGPoint(x: x + handleHalfWidth, y: handleBaseY - handleHeight))
        handle.closeSubpath()
        context.fill(handle, with: .color(OhiaColors.ohiaYellow))

        // Date bubble. Anchored to the right of the handle by default; flips
        // to the left when the playhead is too close to the right edge to
        // fit a right-anchored label.
        let labelString = TimelinePlayheadLabel.format(
            date: workspace.playhead,
            cadence: TimelineRulerCadence.choose(
                viewportRange: workspace.viewportRange,
                pixelsPerDay: projector.viewportPixelsPerDay
            )
        )
        let labelText = Text(labelString)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.black)
        let resolved = context.resolve(labelText)
        let textSize = resolved.measure(in: CGSize(width: 220, height: 18))
        let bubblePadX: CGFloat = 5
        let bubblePadY: CGFloat = 2
        let bubbleWidth = textSize.width + bubblePadX * 2
        let bubbleHeight = textSize.height + bubblePadY * 2
        let preferredX = x + handleHalfWidth + 3
        let labelX: CGFloat = (preferredX + bubbleWidth > size.width)
            ? max(0, x - handleHalfWidth - 3 - bubbleWidth)
            : preferredX
        let bubbleRect = CGRect(
            x: labelX,
            y: 1,
            width: bubbleWidth,
            height: bubbleHeight
        )
        context.fill(
            Path(roundedRect: bubbleRect, cornerRadius: 3),
            with: .color(OhiaColors.ohiaYellow)
        )
        context.draw(
            resolved,
            at: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY),
            anchor: .center
        )
    }

    // MARK: - Gestures

    private func rulerGesture(width: CGFloat) -> some Gesture {
        // `minimumDistance: 0` lets a bare click on the ruler snap the
        // playhead to that x — a tap is just a drag of length zero.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let projector = makeProjector(width: width)
                if NSEvent.modifierFlags.contains(.shift) {
                    // Shift-drag paints the bracketed working range.
                    if dragAnchor == nil {
                        dragAnchor = projector.date(forX: value.startLocation.x)
                    }
                    dragCurrent = projector.date(forX: value.location.x)
                } else {
                    // Plain drag / click scrubs the playhead.
                    workspace.setPlayhead(projector.date(forX: value.location.x))
                }
            }
            .onEnded { _ in
                if let range = effectiveDragRange() {
                    workspace.applyBracket(range)
                }
                dragAnchor = nil
                dragCurrent = nil
            }
            .simultaneously(with:
                TapGesture()
                    .modifiers(.command)
                    .onEnded {
                        workspace.applyBracket(nil)
                    }
            )
    }
}

// MARK: - Playhead label

/// Compact date string for the playhead bubble. Format adapts to the
/// ruler cadence so the bubble stays narrow: hours/days show the time of
/// day; weeks show day + month; months/quarters show month + day; years
/// show month + year.
private enum TimelinePlayheadLabel {
    static func format(date: Date, cadence: TimelineRulerCadence) -> String {
        switch cadence {
        case .hours, .days:
            return TimelinePlayheadFormatters.compact.string(from: date)
        case .weeks:
            return TimelinePlayheadFormatters.dayMonth.string(from: date)
        case .months, .quarters:
            return TimelinePlayheadFormatters.dayMonthYear.string(from: date)
        case .years:
            return TimelinePlayheadFormatters.monthYear.string(from: date)
        }
    }
}

private enum TimelinePlayheadFormatters {
    static let compact: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mma"
        return f
    }()
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

// MARK: - Cadence

private enum TimelineRulerCadence {
    case years
    case quarters
    case months
    case weeks
    case days
    case hours

    struct Tick { let date: Date; let major: Bool }

    static func choose(
        viewportRange: ClosedRange<Date>,
        pixelsPerDay: Double
    ) -> TimelineRulerCadence {
        // Approximate: aim for major ticks ~80-160 pixels apart.
        let spanDays = viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound)
            / TimelineProjector.secondsPerDay
        switch spanDays {
        case ..<2.5:    return .hours
        case ..<14:     return .days
        case ..<70:     return .weeks
        case ..<400:    return .months
        case ..<1500:   return .quarters
        default:        return .years
        }
    }

    func ticks(in range: ClosedRange<Date>) -> [Tick] {
        let cal = Calendar.current
        var ticks: [Tick] = []
        switch self {
        case .hours:
            var current = cal.dateInterval(of: .hour, for: range.lowerBound)?.start ?? range.lowerBound
            while current <= range.upperBound {
                let hour = cal.component(.hour, from: current)
                ticks.append(Tick(date: current, major: hour % 6 == 0))
                guard let next = cal.date(byAdding: .hour, value: 1, to: current) else { break }
                current = next
            }
        case .days:
            var current = cal.startOfDay(for: range.lowerBound)
            while current <= range.upperBound {
                let weekday = cal.component(.weekday, from: current)
                ticks.append(Tick(date: current, major: weekday == cal.firstWeekday))
                guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
        case .weeks:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: range.lowerBound)
            var current = cal.date(from: comps) ?? range.lowerBound
            var index = 0
            while current <= range.upperBound {
                ticks.append(Tick(date: current, major: index % 2 == 0))
                guard let next = cal.date(byAdding: .day, value: 7, to: current) else { break }
                current = next
                index += 1
            }
        case .months:
            var current = cal.date(from: cal.dateComponents([.year, .month], from: range.lowerBound)) ?? range.lowerBound
            while current <= range.upperBound {
                let month = cal.component(.month, from: current)
                ticks.append(Tick(date: current, major: month == 1 || month == 7))
                guard let next = cal.date(byAdding: .month, value: 1, to: current) else { break }
                current = next
            }
        case .quarters:
            var current = cal.date(from: cal.dateComponents([.year, .month], from: range.lowerBound)) ?? range.lowerBound
            while current <= range.upperBound {
                let month = cal.component(.month, from: current)
                if [1, 4, 7, 10].contains(month) {
                    ticks.append(Tick(date: current, major: month == 1))
                }
                guard let next = cal.date(byAdding: .month, value: 1, to: current) else { break }
                current = next
            }
        case .years:
            var current = cal.date(from: cal.dateComponents([.year], from: range.lowerBound)) ?? range.lowerBound
            while current <= range.upperBound {
                ticks.append(Tick(date: current, major: true))
                guard let next = cal.date(byAdding: .year, value: 1, to: current) else { break }
                current = next
            }
        }
        return ticks
    }

    func label(for date: Date) -> String? {
        switch self {
        case .hours:
            return TimelineRulerFormatters.hour.string(from: date)
        case .days:
            return TimelineRulerFormatters.dayWithMonth.string(from: date)
        case .weeks:
            return TimelineRulerFormatters.dayWithMonth.string(from: date)
        case .months, .quarters:
            return TimelineRulerFormatters.monthYear.string(from: date)
        case .years:
            return TimelineRulerFormatters.year.string(from: date)
        }
    }
}

/// Cached `DateFormatter` instances. CLAUDE.md flags chained
/// `Date.FormatStyle` calls for hitting type-checker limits in this
/// codebase — formatters here are pre-built and reused.
private enum TimelineRulerFormatters {
    static let hour: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f
    }()
    static let dayWithMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
    static let year: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()
}
