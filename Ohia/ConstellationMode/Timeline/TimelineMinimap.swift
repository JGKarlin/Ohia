import SwiftUI

/// Range navigator sitting between the time ruler and the multitrack
/// canvas. Premiere/Resolve convention: the entire `outerRange` (the
/// Moments preset's duration) renders as a thin horizontal strip, with
/// the current `viewportRange` drawn on top as a draggable "window."
///
/// Interactions match the NLE idiom:
///   - **Drag the window body** → pan the viewport (span preserved)
///   - **Drag the window edges** → zoom in / out (the opposite edge
///     stays anchored)
///   - **Click outside the window** → jump the window so its centre
///     lands at the click (pan to that time)
///   - **Double-click outside** → zoom to fit (`workspace.resetZoom()`)
///
/// The minimap also surfaces a density preview of the messages in the
/// outer range so the user can spot where their mail concentrates
/// without having to scroll the multitrack. Density bars use the same
/// sortedEligibleEntries the snapshot already pre-computes.
struct TimelineMinimap: View {

    @Bindable var workspace: TimelineWorkspaceState

    @State private var dragMode: DragMode?
    @State private var dragStartViewport: ClosedRange<Date>?

    private enum DragMode {
        case panBody
        case resizeLeft
        case resizeRight
    }

    /// Total minimap height. The bottom 24pt hosts the strip itself
    /// (density preview + yellow viewport window); the top 14pt is
    /// reserved for the floating viewport-range labels that anchor to
    /// the yellow window's edges so the user can see exactly which
    /// slice of time they've magnified into.
    static let minimapHeight: CGFloat = 38

    /// Vertical position of the strip (density + viewport window).
    /// The space above it (`0 ..< stripTopY`) hosts the viewport
    /// labels that float above the yellow window's left / right edges.
    private static let stripTopY: CGFloat = 14

    /// Width threshold below which the click is treated as an edge-grab
    /// (zoom) rather than a body-grab (pan). Generous enough to be
    /// hit-friendly even with a trackpad.
    private static let edgeHitWidth: CGFloat = 8

    var body: some View {
        // Prime tracking — Canvas closures execute outside the body's
        // observation context, so the body has to touch every observed
        // property up front.
        _ = workspace.outerRange
        _ = workspace.viewportRange
        _ = workspace.playhead
        _ = workspace.currentSnapshot

        // Match the ruler / multitrack column structure so the minimap's
        // outer-range projection horizontally aligns with the scrubable
        // events below: 110pt row-label gutter on the left, scrubable
        // canvas filling the rest. The trailing transport column moved
        // into `TimelineRightControlColumn`, which sits as a sibling of
        // the entire VStack in `TimelineWorkspaceView` — so the minimap
        // no longer needs a matching trailing spacer.
        return HStack(spacing: 0) {
            Color.clear
                .frame(width: TimelineRuler.gutterAlignmentWidth)

            GeometryReader { proxy in
                Canvas { context, size in
                    draw(context: context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(minimapGesture(width: proxy.size.width))
            }
        }
        .frame(height: Self.minimapHeight)
        .background(OhiaColors.glassPanel)
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
        .help("Range navigator — drag the window to pan, drag the edges to zoom, click outside to jump")
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize) {
        let outer = workspace.outerRange
        let outerSpan = outer.upperBound.timeIntervalSince(outer.lowerBound)
        guard outerSpan > 0 else { return }

        let inset: CGFloat = 4
        // Strip is offset from the top to leave room for the viewport
        // labels that float above the yellow window. `stripTopY` is
        // the gap; the strip itself runs from there to `size.height-6`.
        let trackTop: CGFloat = Self.stripTopY
        let trackBottom: CGFloat = size.height - 6
        let trackHeight = trackBottom - trackTop

        // Density preview: a thin bar across the outer range with vertical
        // hairlines wherever messages cluster. Uses `sortedEligibleEntries`
        // so density reflects the user's active filter, not the entire
        // archive. Bars dim out at very high density so a single mega-day
        // doesn't burn out the rest of the visualization.
        let trackRect = CGRect(
            x: inset,
            y: trackTop,
            width: size.width - 2 * inset,
            height: trackHeight
        )
        context.fill(
            Path(roundedRect: trackRect, cornerRadius: 3),
            with: .color(OhiaColors.spaceBackground.opacity(0.8))
        )
        context.stroke(
            Path(roundedRect: trackRect, cornerRadius: 3),
            with: .color(OhiaColors.glassBorderBright),
            lineWidth: 1
        )

        drawDensityHistogram(
            context: context,
            outer: outer,
            outerSpan: outerSpan,
            trackRect: trackRect
        )

        // Viewport "window" — translucent yellow rectangle with stronger
        // border on the resize edges.
        let viewport = workspace.viewportRange
        let xLeft = x(for: viewport.lowerBound, in: trackRect, outer: outer)
        let xRight = x(for: viewport.upperBound, in: trackRect, outer: outer)
        let windowRect = CGRect(
            x: xLeft,
            y: trackTop - 1,
            width: max(2, xRight - xLeft),
            height: trackHeight + 2
        )
        context.fill(
            Path(roundedRect: windowRect, cornerRadius: 3),
            with: .color(OhiaColors.ohiaYellow.opacity(0.20))
        )
        context.stroke(
            Path(roundedRect: windowRect, cornerRadius: 3),
            with: .color(OhiaColors.ohiaYellow),
            lineWidth: 1.25
        )
        // Slightly thicker edge grips so the resize affordance reads.
        for edgeX in [windowRect.minX, windowRect.maxX] {
            var grip = Path()
            grip.move(to: CGPoint(x: edgeX, y: windowRect.minY))
            grip.addLine(to: CGPoint(x: edgeX, y: windowRect.maxY))
            context.stroke(grip, with: .color(OhiaColors.ohiaYellow), lineWidth: 2.5)
        }

        // No playhead tick on the minimap: the ruler's arrow already
        // owns the playhead position signal, and its viewport-range
        // projection didn't align with the minimap's outer-range
        // projection except at fit-zoom. The yellow viewport window
        // here remains the "where am I in the archive" cue.

        drawRangeLabels(
            context: context,
            outer: outer,
            outerSpan: outerSpan,
            viewport: viewport,
            trackRect: trackRect,
            windowRect: windowRect
        )
    }

    /// Paint four date labels so the user can read both the archive's
    /// endpoints and the magnified slice without guessing. All labels
    /// live in the label row **above** the strip — none of them sit
    /// inside the strip's rectangle, so the yellow viewport window
    /// never overplots them and they never crowd into its area.
    ///
    /// - Outer-range start / end → faint greyed text at the strip's
    ///   extreme left and right edges, above the strip top.
    /// - Viewport start / end → `ohiaYellow` text placed **outside**
    ///   the yellow window — the start label sits just to the left
    ///   of the window's left edge, the end label sits just to the
    ///   right of the window's right edge. They flank the window
    ///   rather than overlay it.
    ///
    /// Granularity adapts to the span so a multi-year archive shows
    /// "Jan 2024" while a one-day viewport shows "Mar 15, 2:00 PM".
    private func drawRangeLabels(
        context: GraphicsContext,
        outer: ClosedRange<Date>,
        outerSpan: TimeInterval,
        viewport: ClosedRange<Date>,
        trackRect: CGRect,
        windowRect: CGRect
    ) {
        // Shared baseline for every label in this row — centred in
        // the gap between minimap top (y = 0) and the strip top.
        let labelY = Self.stripTopY * 0.5

        let outerStart = Self.formatDate(outer.lowerBound, span: outerSpan)
        let outerEnd   = Self.formatDate(outer.upperBound, span: outerSpan)

        // Outer-range labels — above the strip, anchored to the
        // strip's left / right edges so they mark the archive's true
        // endpoints regardless of where the viewport window sits.
        context.draw(
            Text(outerStart)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary),
            at: CGPoint(x: trackRect.minX, y: labelY),
            anchor: .leading
        )
        context.draw(
            Text(outerEnd)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary),
            at: CGPoint(x: trackRect.maxX, y: labelY),
            anchor: .trailing
        )

        // Skip the viewport labels when the magnified slice equals
        // the outer range — they'd just overplot the outer labels.
        let viewportSpan = viewport.upperBound.timeIntervalSince(viewport.lowerBound)
        let isFullyZoomedOut = abs(viewportSpan - outerSpan) < 1
        guard !isFullyZoomedOut else { return }

        let vpStart = Self.formatDate(viewport.lowerBound, span: viewportSpan)
        let vpEnd   = Self.formatDate(viewport.upperBound, span: viewportSpan)

        // Viewport labels — placed *outside* the yellow window
        // horizontally (start label to the left of its left edge,
        // end label to the right of its right edge) and vertically
        // centred to the yellow box itself (same y as the strip's
        // mid-line) so they read as flanking the magnification
        // window rather than floating above it. Skip a side when
        // there's not enough room between the window edge and the
        // strip edge for the label to live without colliding with
        // the corresponding outer-range label.
        let gap: CGFloat = 6
        let minClearance: CGFloat = 8
        let viewportLabelY = trackRect.midY

        if windowRect.minX - trackRect.minX > minClearance {
            context.draw(
                Text(vpStart)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OhiaColors.ohiaYellow),
                at: CGPoint(x: windowRect.minX - gap, y: viewportLabelY),
                anchor: .trailing
            )
        }
        if trackRect.maxX - windowRect.maxX > minClearance {
            context.draw(
                Text(vpEnd)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OhiaColors.ohiaYellow),
                at: CGPoint(x: windowRect.maxX + gap, y: viewportLabelY),
                anchor: .leading
            )
        }
    }

    // MARK: - Date formatting

    // Cached DateFormatters — CLAUDE.md flags chained `.formatted(...)`
    // for hitting the Swift type-checker on dense draw paths, so
    // these are constructed once and reused.

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    /// Pick a date format that matches the granularity of the span.
    /// Multi-year spans collapse to "MMM yyyy"; multi-week spans show
    /// "MMM d, yyyy"; sub-week spans show "MMM d, h:mm a".
    private static func formatDate(_ date: Date, span: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        let week: TimeInterval = day * 7
        let twoYears: TimeInterval = day * 365 * 2
        if span > twoYears {
            return monthYearFormatter.string(from: date)
        } else if span > week {
            return monthDayYearFormatter.string(from: date)
        } else {
            return dayTimeFormatter.string(from: date)
        }
    }

    /// Diverging density histogram split by send-direction: received mail
    /// rises **above** the midline (stamen-yellow `ohiaYellow`), sent mail
    /// drops **below** it (leaf-green `ohiaGreen`) — mirroring the sender /
    /// receiver multitrack chip colours. Direction (above / below), not
    /// just colour, carries the distinction: the received bars share the
    /// hue of the translucent yellow viewport window that overplots them,
    /// so the up/down split is what keeps them legible where the window
    /// overlaps. Reads in both light and dark habitats.
    private func drawDensityHistogram(
        context: GraphicsContext,
        outer: ClosedRange<Date>,
        outerSpan: TimeInterval,
        trackRect: CGRect
    ) {
        guard let snapshot = workspace.currentSnapshot else { return }
        let entries = snapshot.sortedEligibleEntries
        guard entries.isEmpty == false else { return }
        let direction = snapshot.messageDirectionLookup
        // Bucket the outer range into ~120 columns. Wider canvases get
        // sharper histograms; narrower ones get coarser bars. 120 keeps
        // each bucket ~3-4 px wide at 480-720 pt minimap widths.
        let buckets = 120
        var received = Array(repeating: 0, count: buckets)
        var sent = Array(repeating: 0, count: buckets)
        let outerLower = outer.lowerBound.timeIntervalSinceReferenceDate
        let outerUpper = outer.upperBound.timeIntervalSinceReferenceDate
        let bucketSpan = (outerUpper - outerLower) / Double(buckets)
        guard bucketSpan > 0 else { return }
        for entry in entries {
            let t = entry.date.timeIntervalSinceReferenceDate
            guard t >= outerLower, t <= outerUpper else { continue }
            let idx = min(buckets - 1, max(0, Int((t - outerLower) / bucketSpan)))
            // Unknown direction (id missing from the lookup) is treated as
            // received — the conservative default, since the bulk of mail
            // is inbound and a stray sent message reading as received is a
            // far smaller distortion than the reverse.
            if direction[entry.id] == true {
                sent[idx] += 1
            } else {
                received[idx] += 1
            }
        }
        // Shared scale across both directions so a received bar and a sent
        // bar of equal count read as the same length on opposite sides of
        // the midline.
        let maxCount = max(1, max(received.max() ?? 0, sent.max() ?? 0))
        let bucketWidth = trackRect.width / CGFloat(buckets)
        let midY = trackRect.midY
        // A 0.5pt gap on each side of the midline keeps the two stacks from
        // merging into one solid bar where both directions are present.
        let gap: CGFloat = 0.5
        let halfHeight = max(1, trackRect.height / 2 - gap)

        // Midline baseline so the up/down split still reads in buckets where
        // only one direction is present (or none).
        var baseline = Path()
        baseline.move(to: CGPoint(x: trackRect.minX, y: midY))
        baseline.addLine(to: CGPoint(x: trackRect.maxX, y: midY))
        context.stroke(
            baseline,
            with: .color(OhiaColors.glassBorderBright.opacity(0.5)),
            lineWidth: 0.5
        )

        let barWidth = max(1, bucketWidth - 0.5)
        let receivedColor = OhiaColors.ohiaYellow
        let sentColor = OhiaColors.ohiaGreen
        for idx in 0..<buckets {
            let x = trackRect.minX + CGFloat(idx) * bucketWidth
            let recvCount = received[idx]
            if recvCount > 0 {
                let h = max(1, CGFloat(recvCount) / CGFloat(maxCount) * halfHeight)
                let rect = CGRect(x: x, y: midY - gap - h, width: barWidth, height: h)
                context.fill(Path(rect), with: .color(receivedColor))
            }
            let sentCount = sent[idx]
            if sentCount > 0 {
                let h = max(1, CGFloat(sentCount) / CGFloat(maxCount) * halfHeight)
                let rect = CGRect(x: x, y: midY + gap, width: barWidth, height: h)
                context.fill(Path(rect), with: .color(sentColor))
            }
        }
    }

    private func x(for date: Date, in rect: CGRect, outer: ClosedRange<Date>) -> CGFloat {
        let span = outer.upperBound.timeIntervalSince(outer.lowerBound)
        guard span > 0 else { return rect.minX }
        let t = date.timeIntervalSince(outer.lowerBound) / span
        return rect.minX + CGFloat(max(0, min(1, t))) * rect.width
    }

    private func date(forX dx: CGFloat, in rect: CGRect, outer: ClosedRange<Date>) -> Date {
        let span = outer.upperBound.timeIntervalSince(outer.lowerBound)
        guard rect.width > 0 else { return outer.lowerBound }
        let t = max(0, min(1, (dx - rect.minX) / rect.width))
        return outer.lowerBound.addingTimeInterval(Double(t) * span)
    }

    // MARK: - Gestures

    private func minimapGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let outer = workspace.outerRange
                let outerSpan = outer.upperBound.timeIntervalSince(outer.lowerBound)
                guard outerSpan > 0 else { return }
                let inset: CGFloat = 4
                let trackRect = CGRect(
                    x: inset,
                    y: 0,
                    width: width - 2 * inset,
                    height: Self.minimapHeight
                )
                if dragMode == nil {
                    dragStartViewport = workspace.viewportRange
                    dragMode = classify(
                        startX: value.startLocation.x,
                        trackRect: trackRect,
                        outer: outer
                    )
                }
                guard let mode = dragMode, let start = dragStartViewport else { return }
                let dragDate = date(forX: value.location.x, in: trackRect, outer: outer)
                let startDate = date(forX: value.startLocation.x, in: trackRect, outer: outer)
                switch mode {
                case .panBody:
                    // Move the viewport by the drag delta, span preserved.
                    let delta = dragDate.timeIntervalSince(startDate)
                    let newLower = start.lowerBound.addingTimeInterval(delta)
                    let newUpper = start.upperBound.addingTimeInterval(delta)
                    workspace.setViewportRange(newLower...newUpper)
                case .resizeLeft:
                    // Drag the left edge — right edge stays fixed.
                    workspace.setViewportRange(dragDate...start.upperBound)
                case .resizeRight:
                    // Drag the right edge — left edge stays fixed.
                    workspace.setViewportRange(start.lowerBound...dragDate)
                }
            }
            .onEnded { value in
                defer {
                    dragMode = nil
                    dragStartViewport = nil
                }
                // Treat a near-zero drag translation as a click. If it
                // landed outside the viewport window, recentre the
                // window on that time. (In-window taps are handled by
                // the .panBody branch above with a zero delta — no-op.)
                let isTap = abs(value.translation.width) < 2
                    && abs(value.translation.height) < 2
                guard isTap else { return }
                let outer = workspace.outerRange
                let inset: CGFloat = 4
                let trackRect = CGRect(
                    x: inset,
                    y: 0,
                    width: width - 2 * inset,
                    height: Self.minimapHeight
                )
                let xLeft = x(for: workspace.viewportRange.lowerBound, in: trackRect, outer: outer)
                let xRight = x(for: workspace.viewportRange.upperBound, in: trackRect, outer: outer)
                guard value.location.x < xLeft - Self.edgeHitWidth
                        || value.location.x > xRight + Self.edgeHitWidth else { return }
                let target = date(forX: value.location.x, in: trackRect, outer: outer)
                let span = workspace.viewportRange.upperBound
                    .timeIntervalSince(workspace.viewportRange.lowerBound)
                let halfSpan = span / 2
                workspace.setViewportRange(
                    target.addingTimeInterval(-halfSpan)
                    ... target.addingTimeInterval(halfSpan)
                )
            }
    }

    private func classify(
        startX: CGFloat,
        trackRect: CGRect,
        outer: ClosedRange<Date>
    ) -> DragMode {
        let xLeft = x(for: workspace.viewportRange.lowerBound, in: trackRect, outer: outer)
        let xRight = x(for: workspace.viewportRange.upperBound, in: trackRect, outer: outer)
        if abs(startX - xLeft) <= Self.edgeHitWidth {
            return .resizeLeft
        }
        if abs(startX - xRight) <= Self.edgeHitWidth {
            return .resizeRight
        }
        // Inside the window → pan. Outside → recentre via the onEnded
        // tap-handler.
        return .panBody
    }
}
