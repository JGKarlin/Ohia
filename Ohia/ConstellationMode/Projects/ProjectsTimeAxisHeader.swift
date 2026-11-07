import AppKit
import SwiftUI
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

/// Dedicated time-axis band rendered above the project rows.
///
/// Ticks snap to calendar boundaries (midnights, week starts, month starts)
/// via `ProjectsTimeAxisTicks`, so labels read "Jul 9 · Jul 10" rather than
/// interpolated instants like "Jul 9 at 17:11". The canvas gridlines below
/// draw from the same tick source, so label and line always coincide.
///
/// Range precedence mirrors the canvas projection: an explicit manual-zoom
/// window wins, then a focused/hovered row's activity span, then the whole
/// scope (`fallbackRange`). For projects whose entire span fits inside a
/// single 24-hour window the header collapses into one centered label
/// `Mar 14  ·  09:14 – 14:32`, since repeating the same calendar date across
/// every tick conveys no information.
struct ProjectsTimeAxisHeader: View {
    let row: ProjectRow?
    let canvasWidth: CGFloat
    /// When set (manual zoom active), the header labels this exact range —
    /// the same window the canvas projects onto — instead of a hovered or
    /// focused row's span. Guarantees label positions line up with dots.
    var explicitRange: ClosedRange<Date>? = nil
    /// The whole-scope range the canvas falls back to when nothing is
    /// focused, hovered, or zoomed. Supplying it keeps the axis labeled at
    /// rest instead of showing bare unlabeled ticks.
    var fallbackRange: ClosedRange<Date>? = nil

    static let bandHeight: CGFloat = 28
    private static let edgeInset: CGFloat = 30
    private static let subDayThreshold: TimeInterval = 86_400

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: ProjectsTimeLayoutMetrics.gutterWidth, height: Self.bandHeight)

            Canvas { context, size in
                if explicitRange == nil, let row, Self.isSubDay(row: row) {
                    drawSubDayLabel(context: &context, size: size, row: row)
                } else if let range = resolvedRange {
                    drawCalendarTicks(context: &context, size: size, range: range)
                }
            }
            .frame(width: max(1, canvasWidth), height: Self.bandHeight)
        }
        .frame(height: Self.bandHeight)
        .background(OhiaColors.glassPanel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The range the header describes, mirroring the canvas projection
    /// precedence: manual zoom > row span > whole scope.
    private var resolvedRange: ClosedRange<Date>? {
        if let explicitRange { return explicitRange }
        if let row { return Self.axisRange(for: row) }
        return fallbackRange
    }

    private var accessibilityLabel: String {
        if let explicitRange {
            return "Time axis zoomed: \(Self.tickFormatter.string(from: explicitRange.lowerBound)) to \(Self.tickFormatter.string(from: explicitRange.upperBound))"
        }
        if let row {
            if Self.isSubDay(row: row) {
                return "Time axis for \(row.displayLabel): \(Self.subDayLabel(for: row))"
            }
            let range = Self.axisRange(for: row)
            return "Time axis for \(row.displayLabel): \(Self.tickFormatter.string(from: range.lowerBound)) to \(Self.tickFormatter.string(from: range.upperBound))"
        }
        if let fallbackRange {
            return "Projects time axis: \(Self.tickFormatter.string(from: fallbackRange.lowerBound)) to \(Self.tickFormatter.string(from: fallbackRange.upperBound))"
        }
        return "Projects time axis."
    }

    private func drawSubDayLabel(context: inout GraphicsContext, size: CGSize, row: ProjectRow) {
        let label = Self.subDayLabel(for: row)
        context.draw(
            Text(label)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textSecondary),
            at: CGPoint(x: size.width / 2, y: 10)
        )
    }

    /// Draws boundary-aligned tick marks + labels. X positions map onto the
    /// same inset width the canvas projection uses, so a tick and its
    /// gridline sit exactly under the label.
    private func drawCalendarTicks(context: inout GraphicsContext, size: CGSize, range: ClosedRange<Date>) {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return }
        let projectedWidth = max(1, size.width - ProjectsTimeLayoutMetrics.pipColumnInset)
        var lastDrawnRight: CGFloat = -.infinity
        for tick in ProjectsTimeAxisTicks.ticks(in: range) {
            let t = tick.date.timeIntervalSince(range.lowerBound) / span
            let x = CGFloat(t) * projectedWidth

            var tickPath = Path()
            tickPath.move(to: CGPoint(x: x, y: size.height - 6))
            tickPath.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tickPath, with: .color(OhiaColors.glassBorder), lineWidth: 1)

            let clampedX = min(size.width - Self.edgeInset, max(Self.edgeInset, x))
            let halfWidth = Self.estimatedLabelHalfWidth(tick.label)
            // Skip labels that would visibly overlap the previous one at
            // narrow canvas widths; the tick line still draws.
            if clampedX - halfWidth < lastDrawnRight + Self.labelGap {
                continue
            }
            context.draw(
                Text(tick.label)
                    .font(.system(size: 10, weight: tick.isMajor ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(tick.isMajor ? OhiaColors.textPrimary : OhiaColors.textSecondary),
                at: CGPoint(x: clampedX, y: 10)
            )
            lastDrawnRight = clampedX + halfWidth
        }
    }

    private static let labelGap: CGFloat = 6
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private static func estimatedLabelHalfWidth(_ label: String) -> CGFloat {
        let width = (label as NSString).size(withAttributes: [.font: labelFont]).width
        return width / 2
    }

    /// Closed range covering the row's activity span — `firstActivityAt` to
    /// `lastActivityAt`, with a 4% pad on each side. Deadlines are intentionally
    /// excluded so the header reads as "when did this project actually happen"
    /// rather than "when might this project still be relevant by some deadline".
    /// Future/past deadline ticks still render as milestone diamonds on the
    /// canvas when they fall inside the visible range.
    static func axisRange(for row: ProjectRow) -> ClosedRange<Date> {
        let lower = min(row.firstActivityAt, row.lastActivityAt)
        let upper = max(row.firstActivityAt, row.lastActivityAt)
        let actualSpan = upper.timeIntervalSince(lower)
        guard actualSpan > 0 else { return lower ... upper }
        let pad = actualSpan * 0.04
        return lower.addingTimeInterval(-pad) ... upper.addingTimeInterval(pad)
    }

    /// True when the row's activity span fits inside a 24-hour window — the renderer
    /// collapses the tick layout in that case so the header doesn't print the same
    /// calendar date repeatedly. Mirrors `axisRange(for:)` by ignoring deadlines.
    static func isSubDay(row: ProjectRow) -> Bool {
        let lower = min(row.firstActivityAt, row.lastActivityAt)
        let upper = max(row.firstActivityAt, row.lastActivityAt)
        return upper.timeIntervalSince(lower) < subDayThreshold
    }

    /// Single-line label rendered for sub-day rows: `Mar 14  ·  09:14 – 14:32`, or just
    /// `Mar 14  ·  09:14` for instantaneous bursts where first and last activity coincide.
    static func subDayLabel(for row: ProjectRow) -> String {
        let dateString = tickFormatter.string(from: row.firstActivityAt)
        let start = timeFormatter.string(from: row.firstActivityAt)
        if row.firstActivityAt == row.lastActivityAt {
            return "\(dateString)  \u{00B7}  \(start)"
        }
        let end = timeFormatter.string(from: row.lastActivityAt)
        return "\(dateString)  \u{00B7}  \(start) \u{2013} \(end)"
    }

    private static let tickFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
