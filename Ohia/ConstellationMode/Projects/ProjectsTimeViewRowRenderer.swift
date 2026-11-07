import SwiftUI
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ProjectsTimeProjection {
    let range: ClosedRange<Date>
    let width: CGFloat

    func x(for date: Date) -> CGFloat {
        let span = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
        let t = date.timeIntervalSince(range.lowerBound) / span
        return CGFloat(min(1, max(0, t))) * width
    }

    /// True when `date` falls inside the projection's range. Renderers use this to skip
    /// elements that would otherwise pile up against the canvas edges due to `x(for:)`'s
    /// clamping behavior — important when the projection is zoomed to one focused row
    /// and other rows' marks fall outside the visible window.
    func contains(_ date: Date) -> Bool {
        date >= range.lowerBound && date <= range.upperBound
    }
}

enum ProjectsTimeViewRowRenderer {
    /// Node diameter for a message dot. Shared with the hit tester's rects and
    /// the lane offset math so the whole vocabulary scales from one constant.
    static let markRadius: CGFloat = 9
    /// Gantt bar thickness. Thick enough that the per-burst obligation tint
    /// actually reads as a color, not a hairline.
    static let barHeight: CGFloat = 12
    /// Vertical distance from the lane spine to a message dot's center.
    /// Received mail sits above the spine, sent mail below — the Timeline
    /// minimap's diverging convention, applied per-message.
    static let markLaneOffset: CGFloat = barHeight / 2 + markRadius + 3

    static func draw(
        row: ProjectRow,
        index: Int,
        isFocused: Bool,
        hoveredTarget: ProjectsHoverTarget?,
        density: ProjectsDensityTier,
        now: Date,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect,
        hitTester: ProjectsHitTester
    ) {
        hitTester.addRow(rect: rect, projectKey: row.projectKey)
        if index % 2 == 1 {
            context.fill(Path(rect), with: .color(OhiaColors.glassPanel.opacity(0.22)))
        }
        // Selection is marked by the gutter card's accent ring + glow (the
        // Front Page grid-card treatment) — no canvas-side wash.
        drawDivider(context: &context, rect: rect, dashed: false)
        let baseOpacity: Double
        if isDormantLifecycleRow(row) {
            baseOpacity = isFocused ? 0.62 : 0.38
        } else {
            baseOpacity = 1
        }
        let opacity = baseOpacity
        let laneY = rect.midY
        if opacity < 1 {
            var fadedContext = context
            fadedContext.opacity = opacity
            drawRowContents(
                row: row,
                isFocused: isFocused,
                hoveredTarget: hoveredTarget,
                density: density,
                now: now,
                laneY: laneY,
                context: &fadedContext,
                projection: projection,
                rect: rect,
                hitTester: hitTester
            )
            return
        }
        drawRowContents(
            row: row,
            isFocused: isFocused,
            hoveredTarget: hoveredTarget,
            density: density,
            now: now,
            laneY: laneY,
            context: &context,
            projection: projection,
            rect: rect,
            hitTester: hitTester
        )
    }

    private static func drawRowContents(
        row: ProjectRow,
        isFocused: Bool,
        hoveredTarget: ProjectsHoverTarget?,
        density: ProjectsDensityTier,
        now: Date,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect,
        hitTester: ProjectsHitTester
    ) {
        drawActivityBars(row: row, laneY: laneY, context: &context, projection: projection, rect: rect)
        // Focus always wins over density: a focused row keeps all signals so
        // the user can see why the row was opened.
        let effective = isFocused ? ProjectsDensityTier.full : density
        if effective.rendersRevivalArcs {
            drawRevivalArcs(row: row, laneY: laneY, context: &context, projection: projection, rect: rect)
        }
        if effective.rendersDeadlineTicks {
            drawDeadlineMilestones(
                row: row,
                now: now,
                laneY: laneY,
                context: &context,
                projection: projection,
                rect: rect
            )
        }
        if effective.rendersEmergenceMarkers {
            drawEmergenceMarkers(row: row, laneY: laneY, context: &context, projection: projection, rect: rect)
        }
        drawMessageMarks(
            row: row,
            hoveredTarget: hoveredTarget,
            laneY: laneY,
            context: &context,
            projection: projection,
            rect: rect,
            hitTester: hitTester
        )
    }

    static func drawDivider(context: inout GraphicsContext, rect: CGRect, dashed: Bool = false) {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        let style: StrokeStyle = dashed
            ? StrokeStyle(lineWidth: 1, dash: [3, 3])
            : StrokeStyle(lineWidth: 1)
        let color: Color = dashed
            ? OhiaColors.glassBorder.opacity(0.55)
            : OhiaColors.glassBorder
        context.stroke(path, with: .color(color), style: style)
    }

    /// Gantt bars: one rounded segment per observed activity burst, joined
    /// by a thin dashed dormancy connector. Bars are evidence spans (mail
    /// that happened), never planned duration. Each segment carries the
    /// dominant obligation state of the mail inside it, so a row reads at a
    /// glance: yellow stretch = you owe them, green stretch = awaiting their
    /// confirmation, neutral = settled correspondence.
    private static func drawActivityBars(
        row: ProjectRow,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect
    ) {
        guard let first = row.marks.first, let last = row.marks.last else { return }
        // Skip rows whose entire activity span is outside the visible projection
        // window — important under focus-zoom where most non-focused rows have
        // marks earlier or later than the focused row's range.
        if last.date < projection.range.lowerBound || first.date > projection.range.upperBound {
            return
        }
        let rowIsQuiet = isDormantLifecycleRow(row)
        var previousEndX: CGFloat?

        for burst in row.activityBursts {
            // Clamp each burst to the visible window; drop bursts entirely
            // outside it, but keep the dormancy connector continuous across
            // the gap they leave behind.
            guard burst.end >= projection.range.lowerBound,
                  burst.start <= projection.range.upperBound else {
                continue
            }
            let clampedStart = max(burst.start, projection.range.lowerBound)
            let clampedEnd = min(burst.end, projection.range.upperBound)
            let startX = projection.x(for: clampedStart)
            // A single-message burst still deserves a visible chip of bar.
            let endX = max(startX + 6, projection.x(for: clampedEnd))

            if let previousEndX, startX > previousEndX + 2 {
                var connector = Path()
                connector.move(to: CGPoint(x: previousEndX, y: laneY))
                connector.addLine(to: CGPoint(x: startX, y: laneY))
                context.stroke(
                    connector,
                    with: .color(OhiaColors.textTertiary.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                )
            }

            let barRect = CGRect(
                x: startX,
                y: laneY - Self.barHeight / 2,
                width: endX - startX,
                height: Self.barHeight
            )
            context.fill(
                Path(roundedRect: barRect, cornerRadius: 4),
                with: .color(burstTint(for: row, burst: burst, rowIsQuiet: rowIsQuiet))
            )
            previousEndX = endX
        }
    }

    /// Dominant obligation state of the marks inside one burst, mapped onto
    /// the shared message-status palette. Pending replies dominate (mirrors
    /// the pip column's pending-before-confirmation ordering); confirmation
    /// waits are the calm green; settled bursts stay in the neutral text ramp
    /// so the canvas keeps a single color voice at rest.
    static func burstTint(
        for row: ProjectRow,
        burst: ProjectActivityBurst,
        rowIsQuiet: Bool
    ) -> Color {
        if rowIsQuiet {
            return OhiaColors.textTertiary.opacity(0.20)
        }
        let members = row.marks.filter { $0.date >= burst.start && $0.date <= burst.end }
        if members.contains(where: { $0.obligationKinds.contains(.pendingReply) }) {
            return MessageStatusColors.pendingReply.opacity(0.38)
        }
        if members.contains(where: { $0.obligationKinds.contains(.confirmation) }) {
            return MessageStatusColors.confirmation.opacity(0.34)
        }
        return OhiaColors.textSecondary.opacity(0.26)
    }

    private static func isDormantLifecycleRow(_ row: ProjectRow) -> Bool {
        row.status == .resolved
            || row.status == .quiet
            || row.lifecycleAssessment.state == .inactive
    }

    // MARK: - Message marks (shared status-dot vocabulary)

    /// One rendered dot: either a single message or a cluster of same-side
    /// messages too close together to draw individually. The representative
    /// mark carries the dominant obligation of the cluster and is the hit
    /// target hover/click resolve to.
    struct MarkCluster: Equatable {
        var marks: [ProjectMessageMark]
        /// Projected x of the earliest and latest member; the dot draws at
        /// their midpoint so a smear of near-coincident marks reads as one
        /// dot centered on the pile-up.
        var minX: CGFloat
        var maxX: CGFloat

        var x: CGFloat { (minX + maxX) / 2 }
        var count: Int { marks.count }

        /// Dominant mark: any pending reply first, then any confirmation,
        /// then the newest member — the same precedence the status palette
        /// uses, so the drawn dot always shows the loudest state inside.
        var representative: ProjectMessageMark {
            if let pending = marks.last(where: { $0.obligationKinds.contains(.pendingReply) }) {
                return pending
            }
            if let confirmation = marks.last(where: { $0.obligationKinds.contains(.confirmation) }) {
                return confirmation
            }
            return marks.max(by: { $0.date < $1.date }) ?? marks[0]
        }

        var isFlagged: Bool { marks.contains(where: \.isFlagged) }
    }

    /// Groups same-side marks whose projected centers would overlap into one
    /// cluster. `positions` must be ordered by x ascending. Pure and
    /// deterministic so it is unit-testable without a canvas.
    static func clusterMarks(
        _ positions: [(mark: ProjectMessageMark, x: CGFloat)],
        minimumSpacing: CGFloat
    ) -> [MarkCluster] {
        var clusters: [MarkCluster] = []
        for entry in positions {
            if var current = clusters.last,
               entry.x - current.maxX < minimumSpacing {
                current.marks.append(entry.mark)
                current.maxX = max(current.maxX, entry.x)
                clusters[clusters.count - 1] = current
            } else {
                clusters.append(MarkCluster(marks: [entry.mark], minX: entry.x, maxX: entry.x))
            }
        }
        return clusters
    }

    private static func drawMessageMarks(
        row: ProjectRow,
        hoveredTarget: ProjectsHoverTarget?,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect,
        hitTester: ProjectsHitTester
    ) {
        let radius = Self.markRadius
        // Received mail rides above the lane spine, sent below — direction is
        // structural, not a glyph the user has to decode.
        var received: [(mark: ProjectMessageMark, x: CGFloat)] = []
        var sent: [(mark: ProjectMessageMark, x: CGFloat)] = []
        for mark in row.marks {
            guard projection.contains(mark.date) else { continue }
            let rawX = projection.x(for: mark.date)
            // Clamp the dot's center so its full radius stays inside the canvas
            // and clear of the trailing obligation pip column.
            let x = min(
                rect.maxX - ProjectsTimeLayoutMetrics.pipColumnInset - radius,
                max(rect.minX + radius, rawX)
            )
            if mark.isSentByUser {
                sent.append((mark, x))
            } else {
                received.append((mark, x))
            }
        }
        let deadlineMessageIDs = Set(row.deadlineTicks.map(\.messageID))
        let spacing = radius * 2 - 2
        for (side, positions) in [(1, received), (-1, sent)] where !positions.isEmpty {
            let y = laneY - CGFloat(side) * Self.markLaneOffset
            for cluster in clusterMarks(positions, minimumSpacing: spacing) {
                drawCluster(
                    cluster,
                    at: CGPoint(x: cluster.x, y: y),
                    row: row,
                    rowTop: rect.minY,
                    hoveredTarget: hoveredTarget,
                    hasDeadline: cluster.marks.contains {
                        $0.hasDeadline || deadlineMessageIDs.contains($0.messageID)
                    },
                    context: &context,
                    hitTester: hitTester
                )
            }
        }
    }

    /// Draws one status dot (single message or cluster) in the shared
    /// `MessageStatusDot` vocabulary: obligation states fill the dot and carry
    /// their glyph, satisfied states hollow out with a tinted ring, plain read
    /// state falls back to the read-state palette. Sidecar chrome is limited
    /// to a flag badge and the cluster count — everything else lives in the
    /// dot itself so it stays legible at a glance.
    private static func drawCluster(
        _ cluster: MarkCluster,
        at center: CGPoint,
        row: ProjectRow,
        rowTop: CGFloat,
        hoveredTarget: ProjectsHoverTarget?,
        hasDeadline: Bool,
        context: inout GraphicsContext,
        hitTester: ProjectsHitTester
    ) {
        let representative = cluster.representative
        let isHovered = cluster.marks.contains { hoveredTarget == .message($0.messageID) }
        let radius = Self.markRadius * (isHovered ? 1.15 : 1)
        let markRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        // Register every member so rect(forMessageID:) resolves for comet
        // launches and focus requests; the representative registers last so
        // hover / click resolve to the dominant message.
        for mark in cluster.marks where mark.messageID != representative.messageID {
            hitTester.addMessage(rect: markRect, messageID: mark.messageID, projectKey: row.projectKey)
        }
        hitTester.addMessage(rect: markRect, messageID: representative.messageID, projectKey: row.projectKey)

        let descriptor = MessageStatusDescriptor(mark: representative, hasDeadline: hasDeadline)
        let style = dotStyle(for: descriptor)

        if let fill = style.fill {
            context.fill(Path(ellipseIn: markRect), with: .color(fill))
        } else {
            // Hollow dots knock back the lane behind them so their ring
            // and inner glyph stay legible over a tinted bar.
            context.fill(
                Path(ellipseIn: markRect),
                with: .color(OhiaColors.spaceBackground.opacity(0.85))
            )
        }
        context.stroke(
            Path(ellipseIn: markRect),
            with: .color(style.stroke),
            lineWidth: isHovered ? 2 : style.strokeWidth
        )
        if let symbol = style.symbolName {
            let resolved = context.resolve(
                Text(Image(systemName: symbol))
                    .font(.system(size: max(7.5, radius * 0.86), weight: .bold))
                    .foregroundStyle(style.symbolColor)
            )
            context.draw(resolved, at: center, anchor: .center)
        }

        if isHovered {
            context.stroke(
                Path(ellipseIn: markRect.insetBy(dx: -2.5, dy: -2.5)),
                with: .color(style.stroke.opacity(0.55)),
                lineWidth: 1
            )
        }

        if cluster.count > 1 {
            drawCountBadge(
                count: cluster.count,
                near: markRect,
                rowTop: rowTop,
                tint: style.stroke,
                context: &context
            )
        }
        if cluster.isFlagged {
            let badgeCenter = CGPoint(x: markRect.minX + 1, y: markRect.minY + 1)
            let resolved = context.resolve(
                Text(Image(systemName: MessageStatusSymbols.flagged))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(MessageStatusColors.flagged)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: badgeCenter.x - 5.5, y: badgeCenter.y - 5.5, width: 11, height: 11)),
                with: .color(OhiaColors.spaceBackground.opacity(0.9))
            )
            context.draw(resolved, at: badgeCenter, anchor: .center)
        }
    }

    private struct DotStyle {
        let fill: Color?
        let stroke: Color
        let strokeWidth: CGFloat
        let symbolName: String?
        let symbolColor: Color
    }

    /// Canvas mirror of `MessageStatusDot`'s color logic — one source of
    /// truth for hues (`MessageStatusColors` / `MessageReadStateMarkStyle`),
    /// re-expressed as plain values so `GraphicsContext` can draw it.
    private static func dotStyle(for descriptor: MessageStatusDescriptor) -> DotStyle {
        let symbol = MessageStatusSymbols.statusSymbol(
            needsReply: descriptor.needsReply,
            needsConfirmation: descriptor.needsConfirmation,
            isReplied: descriptor.isReplied,
            isConfirmed: descriptor.isConfirmed
        )
        if descriptor.needsReply, !descriptor.isSentByUser {
            return DotStyle(
                fill: MessageStatusColors.pendingReply,
                stroke: MessageStatusColors.pendingReply,
                strokeWidth: 1,
                symbolName: symbol,
                symbolColor: Color.black.opacity(0.78)
            )
        }
        if descriptor.needsConfirmation, !descriptor.isSentByUser {
            return DotStyle(
                fill: MessageStatusColors.confirmation,
                stroke: MessageStatusColors.confirmation,
                strokeWidth: 1,
                symbolName: symbol,
                symbolColor: Color.black.opacity(0.78)
            )
        }
        if descriptor.needsReply || descriptor.needsConfirmation {
            // Sent mail carrying an obligation renders hollow with the
            // obligation hue — mirrors MessageStatusDot's isHollow branch.
            let tint = descriptor.needsReply
                ? MessageStatusColors.pendingReply
                : MessageStatusColors.confirmation
            return DotStyle(fill: nil, stroke: tint, strokeWidth: 1, symbolName: symbol, symbolColor: tint)
        }
        if descriptor.isReplied {
            return DotStyle(
                fill: nil,
                stroke: MessageStatusColors.replied,
                strokeWidth: 1,
                symbolName: symbol,
                symbolColor: MessageStatusColors.replied
            )
        }
        if descriptor.isConfirmed {
            return DotStyle(
                fill: nil,
                stroke: MessageStatusColors.confirmation,
                strokeWidth: 1,
                symbolName: symbol,
                symbolColor: MessageStatusColors.confirmation
            )
        }
        if descriptor.isSentByUser {
            return DotStyle(
                fill: nil,
                stroke: MessageReadStateMarkStyle.strokeColor(isRead: true),
                strokeWidth: MessageReadStateMarkStyle.strokeWidth(isRead: true),
                symbolName: nil,
                symbolColor: .clear
            )
        }
        return DotStyle(
            fill: MessageReadStateMarkStyle.fillColor(isRead: descriptor.isRead),
            stroke: MessageReadStateMarkStyle.strokeColor(isRead: descriptor.isRead),
            strokeWidth: MessageReadStateMarkStyle.strokeWidth(isRead: descriptor.isRead),
            symbolName: nil,
            symbolColor: .clear
        )
    }

    private static func drawCountBadge(
        count: Int,
        near markRect: CGRect,
        rowTop: CGFloat,
        tint: Color,
        context: inout GraphicsContext
    ) {
        let text = context.resolve(
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        )
        let size = text.measure(in: CGSize(width: 40, height: 20))
        // Clamp inside the row so compressed rows never draw the badge over
        // the divider above; the Canvas has no per-row clipping.
        let center = CGPoint(
            x: markRect.maxX + 2 + size.width / 2,
            y: max(markRect.minY, rowTop + size.height / 2 + 2)
        )
        let capsuleRect = CGRect(
            x: center.x - size.width / 2 - 3,
            y: center.y - size.height / 2 - 1,
            width: size.width + 6,
            height: size.height + 2
        )
        context.fill(
            Path(roundedRect: capsuleRect, cornerRadius: capsuleRect.height / 2),
            with: .color(OhiaColors.spaceBackground.opacity(0.9))
        )
        context.stroke(
            Path(roundedRect: capsuleRect, cornerRadius: capsuleRect.height / 2),
            with: .color(tint.opacity(0.6)),
            lineWidth: 0.7
        )
        context.draw(text, at: center, anchor: .center)
    }

    /// Evidence-backed deadlines render as milestone diamonds on the row
    /// lane. A deadline later than the row's last activity gets a dotted
    /// runway from the last bar to the diamond. Overdue milestones whose
    /// source message still carries an open obligation fill petal-red;
    /// everything else stays an outline so red keeps meaning urgency.
    private static func drawDeadlineMilestones(
        row: ProjectRow,
        now: Date,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect
    ) {
        guard !row.deadlineTicks.isEmpty else { return }
        let openMessageIDs = Set(row.obligations.map(\.messageID))
        let lastActivity = row.marks.last?.date ?? row.lastActivityAt
        for tick in row.deadlineTicks {
            guard projection.contains(tick.date) else { continue }
            let x = projection.x(for: tick.date)
            let y = laneY

            if tick.date > lastActivity, projection.contains(lastActivity) {
                let runwayStart = projection.x(for: lastActivity)
                if x > runwayStart + 2 {
                    var runway = Path()
                    runway.move(to: CGPoint(x: runwayStart, y: y))
                    runway.addLine(to: CGPoint(x: x - 9, y: y))
                    context.stroke(
                        runway,
                        with: .color(OhiaColors.ohiaRed.opacity(0.38)),
                        style: StrokeStyle(lineWidth: 1, dash: [1.5, 3])
                    )
                }
            }

            let size: CGFloat = 9
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: y - size))
            diamond.addLine(to: CGPoint(x: x + size, y: y))
            diamond.addLine(to: CGPoint(x: x, y: y + size))
            diamond.addLine(to: CGPoint(x: x - size, y: y))
            diamond.closeSubpath()

            let isOverdueOpen = tick.date < now && openMessageIDs.contains(tick.messageID)
            if isOverdueOpen {
                context.fill(diamond, with: .color(OhiaColors.ohiaRed.opacity(0.88)))
            } else {
                context.fill(diamond, with: .color(OhiaColors.spaceBackground.opacity(0.85)))
                context.stroke(
                    diamond,
                    with: .color(OhiaColors.ohiaRed.opacity(tick.date >= now ? 0.75 : 0.4)),
                    lineWidth: 1.3
                )
            }
        }
    }

    private static func drawRevivalArcs(
        row: ProjectRow,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect
    ) {
        for arc in row.revivalArcs {
            // Skip arcs whose endpoints are entirely outside the visible window. An arc
            // with one endpoint outside would clamp visually misleadingly to the canvas
            // edge, so we require both endpoints to fall inside the projection.
            guard projection.contains(arc.fromDate), projection.contains(arc.toDate) else { continue }
            let startX = projection.x(for: arc.fromDate)
            let endX = projection.x(for: arc.toDate)
            guard endX > startX else { continue }
            var path = Path()
            path.move(to: CGPoint(x: startX, y: laneY - 2))
            path.addQuadCurve(
                to: CGPoint(x: endX, y: laneY - 2),
                control: CGPoint(x: (startX + endX) / 2, y: laneY - Self.markLaneOffset - Self.markRadius - 4)
            )
            context.stroke(path, with: .color(OhiaColors.accentTeal.opacity(0.45)), lineWidth: 1.2)
        }
    }

    private static func drawEmergenceMarkers(
        row: ProjectRow,
        laneY: CGFloat,
        context: inout GraphicsContext,
        projection: ProjectsTimeProjection,
        rect: CGRect
    ) {
        for marker in row.emergenceMarkers {
            guard projection.contains(marker.date) else { continue }
            let x = projection.x(for: marker.date)
            let size: CGFloat = 7
            var path = Path()
            path.move(to: CGPoint(x: x, y: laneY - size))
            path.addLine(to: CGPoint(x: x + size, y: laneY))
            path.addLine(to: CGPoint(x: x, y: laneY + size))
            path.addLine(to: CGPoint(x: x - size, y: laneY))
            path.closeSubpath()
            context.stroke(path, with: .color(OhiaColors.chipActiveBorder.opacity(0.55)), lineWidth: 1)
        }
    }
}
