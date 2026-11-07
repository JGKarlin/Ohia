import SwiftUI
import OhiaCore

/// The NLE-style multitrack canvas. The seven rows (sender / receiver /
/// attachments / Purpose / thread / account / status) each describe one
/// attribute of the playhead-focused email as an NLE clip anchored at the
/// playhead's x-position. Other emails in the visible window render as
/// faded context ticks across every row at their x-positions so the user
/// can see where the rest of the archive sits and scrub to it.
///
/// Layers, back-to-front:
/// 1. row backgrounds (alternating stripes + hairline dividers)
/// 2. faded context ticks (one pip per email at its x, per visible row)
/// 3. thread span clip (on `.thread` row only — spans focused email's
///    thread start → end, with member ticks highlighted)
/// 4. focused-email chips (one or more NLE clips per row, drawn at the
///    playhead — sender chip, receiver chips, attachment chips, etc.)
/// 5. bracketed-range overlay
/// 6. chapter separators (conv mode)
/// 7. playhead line
struct TimelineCanvasView: View {

    @Bindable var workspace: TimelineWorkspaceState
    /// Constellation-wide filter. The multitrack chips are two-way
    /// bound to it — clicking a sender chip writes
    /// `filter.correspondentQuery`, clicking an account chip toggles
    /// an entry in `filter.accountIds`, etc., so the same activation
    /// shows up on the ConstellationTopBar's filter chips and vice
    /// versa. Rows without a clean filter mapping (attachments per-
    /// instance, orphan thread) fall back to workspace-local
    /// activation via `workspace.activeRowChips`.
    @Bindable var constellationState: ConstellationState
    /// Open-attachment handler. Attachment chips don't have a clean
    /// filter mapping (per-instance vs `filter.hasAttachmentsOnly`'s
    /// global boolean), so clicking one opens the file in its default
    /// app via NSWorkspace instead of toggling an activation state.
    /// The parent owns the `ModelContext` lookup.
    let onOpenAttachment: (UUID) -> Void

    @State private var lastDragLocation: CGPoint?
    @State private var dragMoved = false
    @State private var zoomBaseline: Double?
    @State private var panBaselineStart: Date?
    @State private var panBaselineSpan: TimeInterval?
    /// Per-frame chip rect index — used to dispatch chip taps to
    /// `workspace.toggleRowChip` before the gesture falls through to
    /// "move playhead to click point". The Canvas draw closure writes
    /// into this on every render; the tap handler reads from it on
    /// click. Lives on a class so closure-side mutation doesn't trip
    /// SwiftUI's @State invalidation tracking.
    @State private var chipHitTester = TimelineChipHitTester()
    @State private var contextTickHitTester = TimelineContextTickHitTester()

    var body: some View {
        // Touch every observable property the closure reads so SwiftUI's
        // `@Observable` machinery registers them on this view — Canvas
        // closures execute outside the body's observation context and the
        // tracking would otherwise miss snapshot/playhead flips.
        _ = workspace.currentSnapshot
        _ = workspace.playhead
        _ = workspace.viewportRange
        _ = workspace.viewportPixelsPerDay
        _ = workspace.conversationModeEnabled
        _ = workspace.isolatedCorrespondentEmail
        _ = workspace.bracketedRange
        _ = workspace.soloedRows
        _ = workspace.mutedRows
        _ = workspace.activeRowChips
        _ = workspace.hoveredEntity
        _ = constellationState.filter

        return GeometryReader { proxy in
            Canvas { ctx, size in
                draw(context: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(combinedGesture(size: proxy.size))
            .simultaneousGesture(magnifyGesture(size: proxy.size))
            .onContinuousHover { phase in
                handleHover(phase: phase, size: proxy.size)
            }
        }
    }

    // MARK: - Zoom

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomBaseline == nil { zoomBaseline = workspace.viewportPixelsPerDay }
                let baseline = zoomBaseline ?? workspace.viewportPixelsPerDay
                let proposed = max(0.005, min(2400, baseline * value.magnification))
                applyZoom(newPixelsPerDay: proposed, anchorX: size.width / 2, width: size.width)
            }
            .onEnded { _ in
                zoomBaseline = nil
            }
    }

    /// Apply a zoom level while keeping the date under `anchorX` stable.
    private func applyZoom(newPixelsPerDay: Double, anchorX: CGFloat, width: CGFloat) {
        let span = workspace.viewportRange.upperBound.timeIntervalSince(workspace.viewportRange.lowerBound)
        guard span > 0 else { return }
        let oldDays = span / TimelineProjector.secondsPerDay
        let oldPPD = Double(width) / oldDays
        let proj = TimelineProjector(
            viewportRange: workspace.viewportRange,
            viewportPixelsPerDay: oldPPD,
            laneOrder: [],
            laneHeight: 0
        )
        let anchorDate = proj.date(forX: anchorX)
        let newDays = Double(width) / newPixelsPerDay
        let leftRatio = Double(anchorX) / Double(width)
        let newLower = anchorDate.addingTimeInterval(-leftRatio * newDays * TimelineProjector.secondsPerDay)
        let newUpper = newLower.addingTimeInterval(newDays * TimelineProjector.secondsPerDay)
        workspace.setViewportRange(newLower...newUpper)
        workspace.viewportPixelsPerDay = newPixelsPerDay
    }

    // MARK: - Drawing entry point

    private func draw(context: GraphicsContext, size: CGSize) {
        // Fresh frame — discard the previous render's chip rects so
        // stale ones don't haunt the hit tester if a chip disappears.
        chipHitTester.reset()
        contextTickHitTester.reset()
        guard let snapshot = workspace.currentSnapshot else {
            return
        }
        let visibleRows = visibleRowOrder(snapshot: snapshot)
        guard visibleRows.isEmpty == false else {
            drawEmptyState(context: context, size: size, text: "All rows muted")
            return
        }
        let projector = makeProjector(size: size, snapshot: snapshot, rows: visibleRows)

        drawRowBackgrounds(context: context, projector: projector, size: size)
        drawContextTicks(context: context, projector: projector, snapshot: snapshot)
        // Thread row's span clip is rendered as part of the focused
        // Threads chip itself — `drawThreadsChip` becomes the wide
        // span when threading is on and the focused message is in a
        // multi-message thread. Keeping them merged means one single
        // affordance per row instead of an overlapping chip+clip.
        drawFocusedChips(context: context, projector: projector, snapshot: snapshot)
        // Dim everything that lives outside the painted bracket so the
        // user immediately sees the scope narrowing. Drawn over the
        // content but under the bracket band, so the bracket region
        // stays at full intensity while regions to its left and right
        // fade back. Has no effect when no bracket is set.
        drawDimOutsideBracket(context: context, projector: projector, size: size)
        drawBracketOverlay(context: context, projector: projector, size: size)
        if workspace.conversationModeEnabled {
            drawChapterSeparators(context: context, projector: projector, snapshot: snapshot, size: size)
        }
        // No multitrack playhead line — the focused-email chip column at
        // the playhead's x carries the position signal. The ruler above
        // still draws its own playhead marker for time readout; this
        // canvas stays line-free so the chips read as the focal element.
    }

    private func drawEmptyState(context: GraphicsContext, size: CGSize, text: String) {
        let label = Text(text)
            .font(.system(size: 11))
            .foregroundColor(OhiaColors.textTertiary)
        context.draw(label, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private func makeProjector(
        size: CGSize,
        snapshot: TimelineLayoutSnapshot,
        rows: [TimelineMultitrackRow]
    ) -> TimelineProjector {
        let laneHeight = max(20, size.height / CGFloat(max(1, rows.count)))
        let span = workspace.viewportRange.upperBound.timeIntervalSince(workspace.viewportRange.lowerBound)
        let days = span / TimelineProjector.secondsPerDay
        let ppd = days > 0 ? Double(size.width) / days : workspace.viewportPixelsPerDay
        return TimelineProjector(
            viewportRange: workspace.viewportRange,
            viewportPixelsPerDay: ppd,
            originX: 0,
            laneOrder: rows,
            laneHeight: laneHeight,
            laneTopY: 0
        )
    }

    /// Solo overrides mute. If anything is soloed, only soloed rows
    /// render; otherwise, muted rows are removed from the visible set.
    private func visibleRowOrder(snapshot: TimelineLayoutSnapshot) -> [TimelineMultitrackRow] {
        let base = snapshot.laneOrder
        if workspace.soloedRows.isEmpty == false {
            return base.filter { workspace.soloedRows.contains($0) }
        }
        return base.filter { workspace.mutedRows.contains($0) == false }
    }

    // MARK: - Layer 1: row backgrounds

    private func drawRowBackgrounds(
        context: GraphicsContext,
        projector: TimelineProjector,
        size: CGSize
    ) {
        for (index, _) in projector.laneOrder.enumerated() {
            let y = projector.laneTopY + CGFloat(index) * projector.laneHeight
            let rect = CGRect(x: 0, y: y, width: size.width, height: projector.laneHeight)
            if index % 2 == 1 {
                context.fill(Path(rect), with: .color(OhiaColors.glassPanel.opacity(0.18)))
            }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y + projector.laneHeight))
            path.addLine(to: CGPoint(x: size.width, y: y + projector.laneHeight))
            context.stroke(path, with: .color(OhiaColors.glassBorder), lineWidth: 1)
        }
    }

    // MARK: - Layer 2: per-row context ticks (AccountColor)

    /// Per-row indicator pips. Each row only renders ticks for events
    /// share the focused email's value for that row's attribute —
    /// the sender row only marks emails from the same sender; the
    /// attachments row only marks emails with attachments; etc. Pips
    /// inherit the event's account hue from `AccountColorPalette` so
    /// multi-account archives stay legible at a glance.
    ///
    /// LoD ladder: at `.yearPlus` zoom (≤ 0.05 px/day) the pip strip
    /// would render at sub-pixel separation and the loop would do
    /// O(events × rows) work per frame for thousands of overlapping
    /// marks — skip entirely. At `.months` zoom, downsample to every
    /// Nth event so the strip still reads as "mail lives here" without
    /// the per-frame cost spiking on multi-year archives.
    private func drawContextTicks(
        context: GraphicsContext,
        projector: TimelineProjector,
        snapshot: TimelineLayoutSnapshot
    ) {
        guard snapshot.zoomTier >= .months else { return }
        let stride: Int = snapshot.zoomTier == .months ? max(1, snapshot.events.count / 400) : 1
        let activeMessageID = workspace.playheadMessageID
        let focused = workspace.playheadMessage
        let isolatedEmail = workspace.isolatedCorrespondentEmail?.lowercased()
        // Pre-compute row centerlines once. Inside the event loop we
        // only need the y-positions of the currently visible rows.
        let rowCenters: [(TimelineMultitrackRow, CGFloat)] = projector.laneOrder.compactMap {
            guard let y = projector.centerY(for: $0) else { return nil }
            return ($0, y)
        }
        // Pre-compute the active value set per visible row from the
        // filter bridge. Done once per draw — feeding it into the
        // event loop avoids a switch-per-event-per-row.
        var activeValuesByRow: [TimelineMultitrackRow: Set<String>] = [:]
        for (row, _) in rowCenters {
            let values = chipFilterActiveValues(for: row)
            if !values.isEmpty {
                activeValuesByRow[row] = values
            }
        }
        for (index, event) in snapshot.events.enumerated() {
            if stride > 1 && index % stride != 0 { continue }
            if event.messageID == activeMessageID { continue }
            let x = projector.x(for: event.date)
            guard x >= -3 && x <= projector.contentWidth + 3 else { continue }
            guard let eventMeta = snapshot.messageMetadata[event.messageID] else { continue }
            // Honor correspondent isolation: dim non-matching events so
            // the isolated correspondent's marks read brighter. Both
            // alphas stay low — the chip column at the playhead is the
            // foreground signal; these per-row ticks live in the
            // peripheral register and should never compete with the
            // focused-email chip text.
            let matchesIsolation: Bool = {
                guard let isolatedEmail else { return true }
                return eventMeta.fromAddress == isolatedEmail
            }()
            let baseAlpha = matchesIsolation ? 0.4 : 0.1
            let accountColor = AccountColorPalette.color(forIndex: eventMeta.accountColorIndex)
            for (row, centerY) in rowCenters {
                let isHovered = isContextTickHovered(messageID: event.messageID, row: row)
                let alpha = isHovered ? 1.0 : baseAlpha
                let accountTickColor = Color(
                    hue: accountColor.hue,
                    saturation: accountColor.saturation,
                    brightness: isHovered ? 1.0 : 0.85
                ).opacity(alpha)
                // Row tick policy:
                //   - When the row has any active chip, render ticks
                //     for events matching one of those chip values.
                //     Account row: each event's AccountColor. Other
                //     rows: ohiaYellow (clicked chip → highlighted
                //     matches).
                //   - Otherwise fall back to the focused-email match
                //     so the row still reads as a contextual lens on
                //     whichever email the playhead is on.
                let activeValues = activeValuesByRow[row] ?? []
                let tickColor: Color
                if activeValues.isEmpty {
                    guard contextTickMatches(event: eventMeta, focused: focused, row: row) else { continue }
                    tickColor = accountTickColor
                } else {
                    guard eventMatchesActiveChip(eventMeta, row: row, activeValues: activeValues) else { continue }
                    // Account row: each pip carries its event's
                    // AccountColor (same hue as the account chip). Other
                    // rows take their chip's active-highlight colour so the
                    // lit pips read as one colour with the chip — sender
                    // green, receiver / Purpose / thread yellow.
                    tickColor = row == .account
                        ? accountTickColor
                        : activeHighlightColor(for: row).opacity(alpha)
                }
                let pipPath = Self.contextTickPipPath(centerX: x, centerY: centerY)
                contextTickHitTester.record(
                    Self.contextTickPipHitRect(centerX: x, centerY: centerY),
                    messageID: event.messageID,
                    row: row
                )
                context.fill(pipPath, with: .color(tickColor))
            }
        }
    }

    private func isContextTickHovered(messageID: UUID, row: TimelineMultitrackRow) -> Bool {
        if case .contextTick(let hoveredID, let hoveredRow) = workspace.hoveredEntity {
            return hoveredID == messageID && hoveredRow == row
        }
        return false
    }

    private static let contextTickPipWidth: CGFloat = 2.32
    private static let contextTickPipHeight: CGFloat = 13

    private static func contextTickPipPath(centerX: CGFloat, centerY: CGFloat) -> Path {
        let cornerRadius = min(1, contextTickPipWidth / 2)
        return Path(
            roundedRect: contextTickPipRect(centerX: centerX, centerY: centerY),
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }

    /// Slightly larger than the painted pip so hover is easier to land.
    private static func contextTickPipHitRect(centerX: CGFloat, centerY: CGFloat) -> CGRect {
        contextTickPipRect(centerX: centerX, centerY: centerY)
            .insetBy(dx: -3, dy: -2)
    }

    private static func contextTickPipRect(centerX: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(
            x: centerX - contextTickPipWidth / 2,
            y: centerY - contextTickPipHeight / 2,
            width: contextTickPipWidth,
            height: contextTickPipHeight
        )
    }

    // MARK: - Chip ↔ filter bridge

    /// Is the chip for `(row, value)` currently active on the
    /// ConstellationTopBar's filter (and therefore yellow on the
    /// multitrack)? Rows with a clean filter mapping read the filter
    /// directly; rows without one (attachments per-instance, orphan
    /// thread) fall back to `workspace.activeRowChips`.
    private func chipFilterActive(row: TimelineMultitrackRow, value: String) -> Bool {
        let filter = constellationState.filter
        switch row {
        case .sender:
            return filter.correspondentScopes.contains(.from) && filter.correspondentQuery == value
        case .receiver:
            return filter.correspondentScopes.contains(.to) && filter.correspondentQuery == value
        case .account:
            // Match the top-bar `AccountFilterChips` convention:
            // nil = all on, so an account chip is "on / yellow"
            // whenever it's currently in the visible set. Default
            // unfiltered state paints every account chip yellow
            // (mirrors the top bar where all accounts read as
            // selected at rest).
            guard let uuid = UUID(uuidString: value) else { return false }
            return filter.accountIds?.contains(uuid) ?? true
        case .purpose:
            // Purpose chip is yellow when the Purpose filter has
            // been narrowed to exactly this Purpose — the
            // "isolate to one" mode that clicking the chip puts
            // the filter into. Default-all and other subsets read
            // as not-isolated so the row stays quiet at rest.
            // Custom-category chips use the same isolate semantics
            // across both filter domains.
            if value.hasPrefix("custom.") {
                return filter.customCategoryKeys == [value] && filter.purposes == []
            }
            guard let purpose = MailPurpose(rawValue: value) else { return false }
            return filter.purposes == [purpose]
        case .attachments:
            // Attachment chips are file openers, not activatable
            // filters — they never render in their "active" state.
            return false
        case .thread:
            // Thread chip is the threading-mode toggle, mirroring
            // the side column's Threads disc. Yellow iff conversation
            // mode is on.
            return value == "toggle" && workspace.conversationModeEnabled
        }
    }

    /// Click handler dispatch — toggles the chip's row in the filter
    /// (drives the ConstellationTopBar) for rows with clean mappings,
    /// or in `workspace.activeRowChips` for rows without.
    private func chipFilterToggle(row: TimelineMultitrackRow, value: String) {
        switch row {
        case .sender:
            if chipFilterActive(row: .sender, value: value) {
                constellationState.filter.correspondentQuery = ""
            } else {
                constellationState.filter.correspondentQuery = value
                constellationState.filter.correspondentScopes = [.from]
            }
        case .receiver:
            if chipFilterActive(row: .receiver, value: value) {
                constellationState.filter.correspondentQuery = ""
            } else {
                constellationState.filter.correspondentQuery = value
                constellationState.filter.correspondentScopes = [.to]
            }
        case .account:
            // Mirror `AccountFilterChips.toggle` so click semantics
            // match the top bar exactly:
            //   - `nil` means "all accounts on" (default rest state)
            //   - Clicking an active chip removes that one account
            //     from the visible set, leaving the rest on
            //   - Clicking the last off account back in collapses
            //     accountIds to nil so the filter reads as "no filter"
            //     again instead of "explicitly listing every account"
            //
            // The "known" account set is derived from the current
            // snapshot's metadata — same source the multitrack
            // already uses to render chips, so any account the user
            // can see a chip for is necessarily in this set.
            guard let uuid = UUID(uuidString: value),
                  let snapshot = workspace.currentSnapshot else { return }
            let known = Set(snapshot.messageMetadata.values.compactMap { $0.accountID })
            var active = constellationState.filter.accountIds ?? known
            if active.contains(uuid) {
                active.remove(uuid)
            } else {
                active.insert(uuid)
            }
            constellationState.filter.accountIds = active == known ? nil : active
        case .purpose:
            // Single-isolate semantics: clicking a Purpose chip
            // narrows the Purpose filter to just that value;
            // clicking the already-isolated chip restores the
            // default unconstrained state. This intentionally
            // overwrites any multi-select state from the top bar
            // — the multitrack click is a "show me only this"
            // affordance, not a union-add. Isolation spans both
            // filter domains: isolating a Purpose excludes
            // custom-tagged-only mail and vice versa; restoring
            // returns both domains to their default-all rest
            // state (customCategoryKeys == nil).
            if value.hasPrefix("custom.") {
                if chipFilterActive(row: .purpose, value: value) {
                    constellationState.filter.purposes = nil
                    constellationState.filter.customCategoryKeys = nil
                } else {
                    constellationState.filter.purposes = []
                    constellationState.filter.customCategoryKeys = [value]
                }
                return
            }
            guard let purpose = MailPurpose(rawValue: value) else { return }
            if constellationState.filter.purposes == [purpose] {
                constellationState.filter.purposes = nil
                constellationState.filter.customCategoryKeys = nil
            } else {
                constellationState.filter.purposes = [purpose]
                constellationState.filter.customCategoryKeys = []
            }
        case .attachments:
            // Open the attachment instead of toggling a filter —
            // attachments are file pointers, and the "show only
            // attachments" filter (filter.hasAttachmentsOnly) is a
            // global boolean that doesn't map to a single
            // attachment instance.
            guard let uuid = UUID(uuidString: value) else { return }
            onOpenAttachment(uuid)
        case .thread:
            // Click the Threads chip = flip threading mode, same as
            // the side button. AppStorage stays in sync via the
            // `.onChange(of: workspace.conversationModeEnabled)`
            // observer in `TimelineWorkspaceView`.
            guard value == "toggle" else { return }
            workspace.conversationModeEnabled.toggle()
        }
    }

    /// Snapshot of the active values for `row`, used by tick
    /// recoloring to drive highlighted pips for matching events.
    private func chipFilterActiveValues(for row: TimelineMultitrackRow) -> Set<String> {
        let filter = constellationState.filter
        switch row {
        case .sender:
            guard filter.correspondentScopes.contains(.from),
                  !filter.correspondentQuery.isEmpty else { return [] }
            return [filter.correspondentQuery]
        case .receiver:
            guard filter.correspondentScopes.contains(.to),
                  !filter.correspondentQuery.isEmpty else { return [] }
            return [filter.correspondentQuery]
        case .account:
            // Account row pips carry each event's AccountColor.
            // Any account whose chip is active gets its events'
            // pips painted on the account row. The chip is active
            // when (a) the filter is narrowed and the account's id
            // appears in `accountIds`, or (b) the filter is
            // default-all-on (`accountIds == nil`) so every
            // account's chip is active by definition.
            if let ids = filter.accountIds {
                return Set(ids.map(\.uuidString))
            }
            return [Self.allAccountsWildcardValue]
        case .purpose:
            // Tick recoloring fires when the classification filter has
            // been narrowed below the default-all set in either
            // domain. The filtered-in Purpose rawValues
            // plus the selected custom keys go yellow on the
            // Purpose row.
            let fixedNarrowed = filter.purposes != nil
            let customNarrowed = filter.customCategoryKeys != nil
            guard fixedNarrowed || customNarrowed else { return [] }
            var values = Set<String>()
            if let purposes = filter.purposes {
                values.formUnion(purposes.map(\.rawValue))
            }
            if let custom = filter.customCategoryKeys {
                values.formUnion(custom)
            }
            return values
        case .attachments:
            // Attachments aren't a filter — no row recoloring.
            return []
        case .thread:
            // Thread chip toggles a global mode; per-event tick
            // recoloring on the thread row isn't driven by chip
            // activation (the `drawThreadClip` span carries the
            // visual signal when threading is on).
            return []
        }
    }

    /// Does this event match any of the active chip values on `row`?
    /// Value semantics mirror what each chip drawer records into the
    /// hit tester — keep these two paths in sync (one writes, one
    /// reads).
    private func eventMatchesActiveChip(
        _ event: TimelineLayoutSnapshot.MessageMeta,
        row: TimelineMultitrackRow,
        activeValues: Set<String>
    ) -> Bool {
        switch row {
        case .sender:
            return activeValues.contains(event.fromAddress)
        case .receiver:
            return event.recipients.contains { activeValues.contains($0.email) }
        case .attachments:
            return event.attachmentIDs.contains { activeValues.contains($0.uuidString) }
        case .purpose:
            // Active values may hold fixed rawValues and `custom.*` keys
            // (see `chipFilterActiveValues`); an event matches on either
            // its resolved Purpose or any of its custom tags.
            if let purpose = event.purposeState.purpose,
               activeValues.contains(purpose.rawValue) { return true }
            return event.customCategories.contains { activeValues.contains($0.key) }
        case .thread:
            // Thread row's chip is the threading-mode toggle, not a
            // per-event highlight — `chipFilterActiveValues` always
            // returns empty for this row, so this branch is
            // unreachable. Kept for switch exhaustiveness.
            return false
        case .account:
            if activeValues.contains(Self.allAccountsWildcardValue) { return true }
            guard let id = event.accountID else { return false }
            return activeValues.contains(id.uuidString)
        }
    }

    /// Sentinel inserted into the `.account` row's active-values set
    /// when the filter is in default-all-on mode (`accountIds == nil`).
    /// `eventMatchesActiveChip` short-circuits to `true` when it sees
    /// this value, so every account's events get the account-color
    /// tick treatment. Picked to be UUID-string-shaped enough not to
    /// collide with any real account id (UUIDs are 36 chars; this
    /// literal is 1).
    private static let allAccountsWildcardValue = "*"

    /// Decide whether `event` should produce a context tick on `row`
    /// given the currently focused email. Each row uses a different
    /// matching predicate so the strip reads as a contextual lens, not
    /// a uniform "every email" dot field.
    private func contextTickMatches(
        event: TimelineLayoutSnapshot.MessageMeta,
        focused: TimelineLayoutSnapshot.MessageMeta?,
        row: TimelineMultitrackRow
    ) -> Bool {
        guard let focused else {
            // No focus → show the inherent-content rows.
            switch row {
            case .sender, .receiver, .purpose, .account: return true
            case .attachments: return event.attachmentIDs.isEmpty == false
            case .thread:      return event.threadID != nil
            }
        }
        switch row {
        case .sender:
            // Same sender address (case-insensitive — both sides are
            // already lower-cased by the engine).
            return event.fromAddress == focused.fromAddress
        case .receiver:
            // Overlap on any recipient email.
            let focusedRecipients = Set(focused.recipients.map(\.email))
            return event.recipients.contains { focusedRecipients.contains($0.email) }
        case .attachments:
            // Only emails that have attachments.
            return event.attachmentIDs.isEmpty == false
        case .purpose:
            // Same explicit Purpose state, or overlap on a user-defined tag.
            // Pending and uncertain remain distinct from resolved `.other`.
            if focused.customCategories.isEmpty == false {
                let focusedKeys = Set(focused.customCategories.map(\.key))
                if event.customCategories.contains(where: { focusedKeys.contains($0.key) }) {
                    return true
                }
            }
            return event.purposeState == focused.purposeState
        case .thread:
            if let threadID = focused.threadID {
                return event.threadID == threadID
            }
            // Focused is orphan → mark other orphans.
            return event.threadID == nil
        case .account:
            return event.accountID == focused.accountID
        }
    }

    // MARK: - Layer 3: thread span clip

    /// On the `.thread` row, draw an NLE-style clip spanning the focused
    /// email's thread (first message → last). Member messages render as
    /// ticks inside the clip; the focused tick is emphasized in yellow.
    /// Orphan-message focus renders a single tick at its position (no
    /// surrounding clip).

    private func sentReceivedCounts(
        in chapter: TimelineChapter,
        snapshot: TimelineLayoutSnapshot
    ) -> (sent: Int, received: Int) {
        var sent = 0
        var received = 0
        for id in chapter.messageIDs {
            guard let meta = snapshot.messageMetadata[id] else { continue }
            if meta.isSentByUser { sent += 1 } else { received += 1 }
        }
        return (sent, received)
    }

    /// Builds the "X sent · Y received" label, omitting zero counts.
    /// Returns nil when both counts are zero (defensive — empty
    /// chapters should already be filtered upstream).
    private func formatSentReceived(sent: Int, received: Int) -> String? {
        switch (sent, received) {
        case (0, 0):
            return nil
        case (0, let r):
            return "\(r) received"
        case (let s, 0):
            return "\(s) sent"
        case (let s, let r):
            return "\(s) sent · \(r) received"
        }
    }

    // MARK: - Layer 4: focused-email chips

    private func drawFocusedChips(
        context: GraphicsContext,
        projector: TimelineProjector,
        snapshot: TimelineLayoutSnapshot
    ) {
        guard let meta = workspace.playheadMessage else { return }
        // Anchor chips at the playhead column rather than the focused
        // email's actual time. The playhead is the user's pointer; chips
        // stay under it as they scrub, and the focused-message tick on
        // the thread row carries the "this is the message at meta.date"
        // signal so the spatial link is still visible.
        let focusX = projector.x(for: workspace.playhead)
        let canvasWidth = projector.contentWidth
        // Pre-build an attachment lookup so the attachments row chip
        // doesn't re-scan `snapshot.attachmentMarks` linearly per attachment
        // every frame. Built once per draw, used only if the focused email
        // has attachments.
        let attachmentByID: [UUID: TimelineLayoutSnapshot.AttachmentMark]
        if meta.attachmentIDs.isEmpty {
            attachmentByID = [:]
        } else {
            attachmentByID = Dictionary(
                uniqueKeysWithValues: snapshot.attachmentMarks.map { ($0.attachmentID, $0) }
            )
        }
        for row in projector.laneOrder {
            guard let centerY = projector.centerY(for: row) else { continue }
            switch row {
            case .sender:
                drawSenderChip(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, canvasWidth: canvasWidth)
            case .receiver:
                drawReceiverChips(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, canvasWidth: canvasWidth)
            case .attachments:
                drawAttachmentChips(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, attachmentByID: attachmentByID, canvasWidth: canvasWidth)
            case .purpose:
                drawPurposeChip(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, canvasWidth: canvasWidth)
            case .thread:
                drawThreadsChip(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, snapshot: snapshot, canvasWidth: canvasWidth)
            case .account:
                drawAccountChip(context: context, meta: meta, anchorX: focusX, centerY: centerY, projector: projector, canvasWidth: canvasWidth)
            }
        }
    }

    private func drawSenderChip(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        canvasWidth: CGFloat
    ) {
        let label: String
        if meta.fromName.isEmpty == false && meta.fromAddress.isEmpty == false {
            label = "\(meta.fromName) · \(meta.fromAddress)"
        } else if meta.fromName.isEmpty == false {
            label = meta.fromName
        } else if meta.fromAddress.isEmpty == false {
            label = meta.fromAddress
        } else {
            label = "(unknown sender)"
        }
        drawChip(
            context: context,
            text: label,
            symbol: "person.crop.circle.fill",
            accent: TimelineMultitrackRowPalette.accent(for: .sender),
            anchor: .center(x: anchorX),
            centerY: centerY,
            chipHeight: chipHeight(for: projector),
            canvasWidth: canvasWidth,
            activationKey: meta.fromAddress.isEmpty
                ? nil
                : TimelineChipHitTester.Key(row: .sender, value: meta.fromAddress)
        )
    }

    private func drawReceiverChips(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        canvasWidth: CGFloat
    ) {
        let accent = TimelineMultitrackRowPalette.accent(for: .receiver)
        let height = chipHeight(for: projector)
        if meta.recipients.isEmpty {
            drawEmptyChip(
                context: context,
                anchorX: anchorX,
                centerY: centerY,
                chipHeight: height,
                placeholder: "—",
                canvasWidth: canvasWidth
            )
            return
        }
        // Order: To first, then Cc, then Bcc; preserve original order
        // inside each role bucket.
        let roleOrder: [TimelineLayoutSnapshot.Recipient.Role] = [.to, .cc, .bcc]
        let ordered = roleOrder.flatMap { role in
            meta.recipients.filter { $0.role == role }
        }
        let chips: [StackedChip] = ordered.map { recipient in
            let prefix: String
            switch recipient.role {
            case .to: prefix = ""
            case .cc: prefix = "cc:"
            case .bcc: prefix = "bcc:"
            }
            let name = recipient.displayName.isEmpty ? recipient.email : recipient.displayName
            return StackedChip(
                label: prefix.isEmpty ? name : "\(prefix) \(name)",
                symbol: "person.fill",
                activationValue: recipient.email
            )
        }
        drawStackedChips(
            context: context,
            row: .receiver,
            chips: chips,
            accent: accent,
            anchorX: anchorX,
            centerY: centerY,
            chipHeight: height,
            canvasWidth: canvasWidth
        )
    }

    private func drawAttachmentChips(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        attachmentByID: [UUID: TimelineLayoutSnapshot.AttachmentMark],
        canvasWidth: CGFloat
    ) {
        let accent = TimelineMultitrackRowPalette.accent(for: .attachments)
        let height = chipHeight(for: projector)
        let attachments = meta.attachmentIDs.compactMap { attachmentByID[$0] }
        guard attachments.isEmpty == false else {
            drawEmptyChip(
                context: context,
                anchorX: anchorX,
                centerY: centerY,
                chipHeight: height,
                placeholder: "—",
                canvasWidth: canvasWidth
            )
            return
        }
        let chips: [StackedChip] = attachments.map { attachment in
            StackedChip(
                label: attachment.name,
                symbol: TimelineAttachmentSublayer.symbolName(for: attachment.kind),
                activationValue: attachment.attachmentID.uuidString,
                // Per-kind tint — `accentOrange` for PDF, `accentGreen`
                // for spreadsheets, etc. The same `TimelineAttachmentKind.tint`
                // is used by `LockedAttachmentsList` so the chip color
                // matches the icon color in the locked-node overlay.
                accentOverride: attachment.kind.tint
            )
        }
        drawStackedChips(
            context: context,
            row: .attachments,
            chips: chips,
            accent: accent,
            anchorX: anchorX,
            centerY: centerY,
            chipHeight: height,
            canvasWidth: canvasWidth
        )
    }

    private func drawPurposeChip(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        canvasWidth: CGFloat
    ) {
        // Purpose is always explicit, including pending and uncertain. Only a
        // resolved Purpose is filter-activatable; custom keys remain separate
        // secondary chips and never become the primary Purpose.
        var chips: [StackedChip] = [
            StackedChip(
                label: meta.purposeState.displayLabel,
                symbol: meta.purposeState.systemImageName,
                activationValue: meta.purposeState.purpose?.rawValue ?? ""
            )
        ]
        for tag in meta.customCategories {
            chips.append(StackedChip(
                label: tag.displayName,
                // Plain `tag` (vs the fixed chip's `tag.fill`) — the
                // app-wide custom-category mark from ToggleIconography.
                symbol: ToggleIconography.customCategorySymbolName,
                activationValue: tag.key
            ))
        }
        drawStackedChips(
            context: context,
            row: .purpose,
            chips: chips,
            accent: TimelineMultitrackRowPalette.accent(for: .purpose),
            anchorX: anchorX,
            centerY: centerY,
            chipHeight: chipHeight(for: projector),
            canvasWidth: canvasWidth
        )
    }

    private func drawThreadsChip(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        snapshot: TimelineLayoutSnapshot,
        canvasWidth: CGFloat
    ) {
        // Single Threads affordance, three states:
        //  - Threading OFF → small "Threads" pill at the playhead
        //  - Threading ON, multi-message thread → wide span clip
        //    from `chapter.start → chapter.end`, count label inside,
        //    member ticks (focused yellow). Clip itself is the toggle
        //    hit target — clicking anywhere on it flips threading off.
        //  - Threading ON, orphan / single-message → small "1 sent"
        //    or "1 received" pill at the playhead.
        let isThreadingOn = workspace.conversationModeEnabled
        let chapter: TimelineChapter? = isThreadingOn
            ? (meta.threadID.flatMap { tid in snapshot.chapters.first(where: { $0.id == tid }) }
               ?? snapshot.chapters.first(where: { $0.id == meta.chapterID }))
            : nil

        // Branch 1 & 3 share a small-pill rendering; only the label
        // text differs. Branch 2 needs the span treatment.
        if !isThreadingOn || chapter == nil || (chapter?.messageIDs.count ?? 0) <= 1 {
            let label: String
            if isThreadingOn {
                // Orphan / single-message thread — render the count
                // explicitly so the chip reads as "this conversation
                // is 1 message" rather than just "received." Matches
                // the wide-span branch's count grammar below.
                label = "1 message"
            } else {
                label = "Threads"
            }
            drawChip(
                context: context,
                text: label,
                symbol: "list.bullet.indent",
                accent: TimelineMultitrackRowPalette.accent(for: .thread),
                anchor: .center(x: anchorX),
                centerY: centerY,
                chipHeight: chipHeight(for: projector),
                canvasWidth: canvasWidth,
                activationKey: TimelineChipHitTester.Key(row: .thread, value: "toggle")
            )
            return
        }

        guard let chapter else { return }

        // Wide span — replaces both the standalone clip and the chip.
        let startX = projector.x(for: chapter.start)
        let endX = projector.x(for: chapter.end)
        let rawWidth = endX - startX
        // Minimum useful span width: enough room for the icon + a
        // short count label like "3 messages". Below this we fall
        // back to a normal-width chip at the playhead so the user
        // still gets a legible affordance (instead of a tall thin
        // yellow sliver with no glyph and no count, which is what
        // a tightly-clustered thread used to collapse to). The
        // member-tick visualization needs proportional horizontal
        // room to be useful anyway.
        let minSpanWidth: CGFloat = 60
        if rawWidth < minSpanWidth {
            let counts = sentReceivedCounts(in: chapter, snapshot: snapshot)
            let total = chapter.messageIDs.count
            let label = formatSentReceived(sent: counts.sent, received: counts.received)
                ?? "\(total) message\(total == 1 ? "" : "s")"
            drawChip(
                context: context,
                text: label,
                symbol: "list.bullet.indent",
                accent: TimelineMultitrackRowPalette.accent(for: .thread),
                anchor: .center(x: anchorX),
                centerY: centerY,
                chipHeight: chipHeight(for: projector),
                canvasWidth: canvasWidth,
                activationKey: TimelineChipHitTester.Key(row: .thread, value: "toggle")
            )
            return
        }
        let width = max(6, rawWidth)
        let clipHeight = chipHeight(for: projector)
        let rect = CGRect(
            x: startX,
            y: centerY - clipHeight / 2,
            width: width,
            height: clipHeight
        )
        let shape = Path(roundedRect: rect, cornerRadius: 6)

        // Threading-on = chip's "active" state, so the span renders
        // in `ohiaYellow` (matches every other active-chip in the
        // multitrack vocabulary). Paint an opaque surface first so
        // timeline marks cannot show through the chip.
        context.fill(shape, with: .color(OhiaColors.spaceBackground))
        context.fill(
            shape,
            with: .color(OhiaColors.ohiaYellow.opacity(0.32))
        )
        context.stroke(
            shape,
            with: .color(OhiaColors.ohiaYellow),
            lineWidth: 1.5
        )

        // Member ticks inside the span. The focused message's tick is
        // brighter and taller; siblings render at lower alpha so the
        // user can locate themselves within the conversation.
        let activeID = meta.messageID
        for messageID in chapter.messageIDs {
            guard let date = snapshot.messageDateLookup[messageID] else { continue }
            let x = projector.x(for: date)
            let isActive = messageID == activeID
            let tickColor = isActive
                ? OhiaColors.ohiaYellow
                : OhiaColors.ohiaYellow.opacity(0.55)
            let tickHeight = isActive ? rect.height * 0.85 : rect.height * 0.55
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.midY - tickHeight / 2))
            path.addLine(to: CGPoint(x: x, y: rect.midY + tickHeight / 2))
            context.stroke(path, with: .color(tickColor), lineWidth: isActive ? 2 : 1)
        }

        // Count label centered inside the clip when there's room.
        if width > 60 {
            let counts = sentReceivedCounts(in: chapter, snapshot: snapshot)
            if let countLabel = formatSentReceived(sent: counts.sent, received: counts.received) {
                let labelText = Text(countLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OhiaColors.ohiaYellow)
                var labelCtx = context
                labelCtx.clip(to: Path(rect.insetBy(dx: 6, dy: 0)))
                labelCtx.draw(
                    labelText,
                    at: CGPoint(x: rect.minX + 8, y: rect.midY),
                    anchor: .leading
                )
            }
        }

        // The whole span is the toggle hit target — click anywhere on
        // the clip and threading turns off (same dispatch as the
        // small-pill branch above).
        chipHitTester.record(rect, for: TimelineChipHitTester.Key(row: .thread, value: "toggle"))
    }

    private func drawAccountChip(
        context: GraphicsContext,
        meta: TimelineLayoutSnapshot.MessageMeta,
        anchorX: CGFloat,
        centerY: CGFloat,
        projector: TimelineProjector,
        canvasWidth: CGFloat
    ) {
        let label = meta.accountName.isEmpty ? "(unknown account)" : meta.accountName
        let accountContentColor = AccountColorPalette
            .color(forIndex: meta.accountColorIndex)
            .swiftUIColor
        drawChip(
            context: context,
            text: label,
            symbol: "envelope.fill",
            accent: TimelineMultitrackRowPalette.accent(for: .account),
            contentColor: accountContentColor,
            anchor: .center(x: anchorX),
            centerY: centerY,
            chipHeight: chipHeight(for: projector),
            canvasWidth: canvasWidth,
            activationKey: meta.accountID.map {
                TimelineChipHitTester.Key(row: .account, value: $0.uuidString)
            }
        )
    }

    // MARK: - Chip primitives

    private enum ChipAnchor {
        case center(x: CGFloat)
        case leadingFrom(x: CGFloat)
    }

    private func chipHeight(for projector: TimelineProjector) -> CGFloat {
        max(16, min(22, projector.laneHeight * 0.62))
    }

    /// Render a single NLE-style chip. Returns the chip's rect so callers
    /// can chain (stacked chips advance from the trailing edge). When
    /// `activationKey` is non-nil the chip:
    /// - Records its rect into `chipHitTester` so taps can dispatch to
    ///   `workspace.toggleRowChip`.
    /// - Switches to a yellow fill / border when the key is currently
    ///   in `workspace.activeRowChips[row]`, signaling that the chip
    ///   is the active highlight source for its row. Account chips
    ///   use AccountColor for fill / border instead of ohiaYellow.
    /// Active-state highlight colour for a multitrack chip and its row
    /// pips. Defaults to `ohiaYellow` — the universal "this filter is on"
    /// colour — while the sender row uses `ohiaGreen` so it keeps the
    /// green identity it already carries at rest. (The receiver row's rest
    /// accent is already `ohiaYellow`, so it needs no special case.)
    private func activeHighlightColor(for row: TimelineMultitrackRow?) -> Color {
        row == .sender ? OhiaColors.ohiaGreen : OhiaColors.ohiaYellow
    }

    @discardableResult
    private func drawChip(
        context: GraphicsContext,
        text: String,
        symbol: String?,
        accent: Color,
        contentColor: Color? = nil,
        anchor: ChipAnchor,
        centerY: CGFloat,
        chipHeight: CGFloat,
        canvasWidth: CGFloat? = nil,
        activationKey: TimelineChipHitTester.Key? = nil
    ) -> CGRect {
        let isActive: Bool
        if let activationKey {
            isActive = chipFilterActive(row: activationKey.row, value: activationKey.value)
        } else {
            isActive = false
        }
        let chipAccent: Color
        if let contentColor {
            // Account chips: fill + border carry the same AccountColor
            // as the glyph and label; active/inactive strength is
            // encoded by the existing opacity ramp below.
            chipAccent = contentColor
        } else {
            chipAccent = isActive ? activeHighlightColor(for: activationKey?.row) : accent
        }
        // Text color: textPrimary at rest. When active, the fill is
        // `ohiaYellow.opacity(0.32)` — painting the label in
        // `ohiaYellow` too left the count invisible on the threads
        // chip (yellow on yellow). textPrimary stays legible on both
        // active and rest states; the active *border* + bolder
        // weight already carry the "active" signal.
        //
        // Account chips pass `contentColor` for the envelope glyph,
        // fill, and border. The label stays on `textPrimary` like
        // every other multitrack chip.
        let label = Text(text)
            .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            .foregroundStyle(OhiaColors.textPrimary)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: CGSize(width: 600, height: chipHeight))
        let iconWidth: CGFloat = symbol == nil ? 0 : 16
        let chipWidth = max(28, textSize.width + 16 + iconWidth)
        let chipX: CGFloat
        switch anchor {
        case .center(let x):
            let naturalX = x - chipWidth / 2
            chipX = canvasWidth.map {
                edgeAwareLeadingX(naturalLeadingX: naturalX, width: chipWidth, canvasWidth: $0)
            } ?? naturalX
        case .leadingFrom(let x):
            chipX = x
        }
        let rect = CGRect(
            x: chipX,
            y: centerY - chipHeight / 2,
            width: chipWidth,
            height: chipHeight
        )
        let shape = Path(roundedRect: rect, cornerRadius: 4)
        // The accent remains a tint, but it sits on a solid surface so
        // dense timeline marks never compete with the chip's contents.
        context.fill(shape, with: .color(OhiaColors.spaceBackground))
        context.fill(
            shape,
            with: .color(chipAccent.opacity(isActive ? 0.32 : 0.18))
        )
        context.stroke(
            shape,
            with: .color(chipAccent.opacity(isActive ? 1.0 : 0.7)),
            lineWidth: isActive ? 1.5 : 1
        )
        var textOriginX = rect.minX + 8
        if let symbol {
            let iconText = Text(Image(systemName: symbol))
                .font(.system(size: 11))
                // Active fills are `ohiaYellow.opacity(0.32)`. Rendering
                // the glyph in `chipAccent` (= ohiaYellow) on top vanished
                // the icon. Use textPrimary on active and the row accent
                // at rest so the glyph stays legible in both states.
                // Account chips: glyph in AccountColor when active,
                // textSecondary when filtered off (matches toolbar).
                .foregroundStyle(
                    contentColor.map { isActive ? $0 : OhiaColors.textSecondary }
                        ?? (isActive ? OhiaColors.textPrimary : chipAccent)
                )
            let iconResolved = context.resolve(iconText)
            context.draw(
                iconResolved,
                at: CGPoint(x: rect.minX + 12, y: rect.midY),
                anchor: .center
            )
            textOriginX = rect.minX + 22
        }
        var clippedCtx = context
        clippedCtx.clip(to: Path(rect.insetBy(dx: 4, dy: 0)))
        clippedCtx.draw(
            resolved,
            at: CGPoint(x: textOriginX, y: rect.midY),
            anchor: .leading
        )
        if let activationKey {
            chipHitTester.record(rect, for: activationKey)
        }
        return rect
    }

    /// One element of a stacked-chip row (receiver / attachments). The
    /// `activationValue` is the row-specific identifier the activation
    /// hit tester records — receiver email or attachment UUID string.
    private struct StackedChip {
        let label: String
        let symbol: String
        let activationValue: String
        /// Per-chip accent override. Used by the attachments row so
        /// each chip picks up its file-type tint from
        /// `TimelineAttachmentKind.tint`. `nil` falls back to the
        /// row-level accent passed to `drawStackedChips`, which is
        /// what every other multi-valued row (receivers) relies on.
        let accentOverride: Color?

        init(label: String, symbol: String, activationValue: String, accentOverride: Color? = nil) {
            self.label = label
            self.symbol = symbol
            self.activationValue = activationValue
            self.accentOverride = accentOverride
        }
    }

    /// Render multiple chips for a multi-valued row (receiver, attachments).
    /// Chips center as a group on `anchorX` so the playhead column sits in
    /// the middle of the collected chips rather than at the leading edge.
    /// Each chip records its own activation key so taps on individual
    /// recipients / attachments toggle independently.
    private func drawStackedChips(
        context: GraphicsContext,
        row: TimelineMultitrackRow,
        chips: [StackedChip],
        accent: Color,
        anchorX: CGFloat,
        centerY: CGFloat,
        chipHeight: CGFloat,
        canvasWidth: CGFloat
    ) {
        // Cap the number of chips to keep multi-recipient threads from
        // running off the end of the canvas; the `+ N more` chip carries
        // the overflow count.
        let maxChips = 4
        let visible = Array(chips.prefix(maxChips))
        let overflow = chips.count - visible.count
        // Pre-measure to center the group on anchorX.
        var widths: [CGFloat] = []
        for chip in visible {
            let isActive = chip.activationValue.isEmpty
                ? false
                : chipFilterActive(row: row, value: chip.activationValue)
            let labelText = Text(chip.label)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(OhiaColors.textPrimary)
            let resolved = context.resolve(labelText)
            let size = resolved.measure(in: CGSize(width: 600, height: chipHeight))
            let iconWidth: CGFloat = chip.symbol.isEmpty ? 0 : 16
            widths.append(max(28, size.width + 16 + iconWidth))
        }
        if overflow > 0 {
            let overflowText = Text("+\(overflow) more")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)
            let resolved = context.resolve(overflowText)
            let size = resolved.measure(in: CGSize(width: 200, height: chipHeight))
            widths.append(max(28, size.width + 16))
        }
        let gap: CGFloat = 4
        let totalWidth = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        let naturalGroupX = anchorX - totalWidth / 2
        var cursorX = edgeAwareLeadingX(
            naturalLeadingX: naturalGroupX,
            width: totalWidth,
            canvasWidth: canvasWidth
        )
        for (index, chip) in visible.enumerated() {
            _ = drawChip(
                context: context,
                text: chip.label,
                symbol: chip.symbol.isEmpty ? nil : chip.symbol,
                accent: chip.accentOverride ?? accent,
                anchor: .leadingFrom(x: cursorX),
                centerY: centerY,
                chipHeight: chipHeight,
                activationKey: chip.activationValue.isEmpty
                    ? nil
                    : TimelineChipHitTester.Key(row: row, value: chip.activationValue)
            )
            cursorX += widths[index] + gap
        }
        if overflow > 0 {
            _ = drawChip(
                context: context,
                text: "+\(overflow) more",
                symbol: nil,
                accent: OhiaColors.textSecondary,
                anchor: .leadingFrom(x: cursorX),
                centerY: centerY,
                chipHeight: chipHeight
                // Overflow chip is a count placeholder — not tied to a
                // specific value, so leave activation off.
            )
        }
    }

    private func drawEmptyChip(
        context: GraphicsContext,
        anchorX: CGFloat,
        centerY: CGFloat,
        chipHeight: CGFloat,
        placeholder: String,
        canvasWidth: CGFloat
    ) {
        let placeholderText = Text(placeholder)
            .font(.system(size: 11))
            .foregroundStyle(OhiaColors.textTertiary)
        let resolved = context.resolve(placeholderText)
        let textSize = resolved.measure(in: CGSize(width: 200, height: chipHeight))
        let naturalX = anchorX - textSize.width / 2
        let x = edgeAwareLeadingX(
            naturalLeadingX: naturalX,
            width: textSize.width,
            canvasWidth: canvasWidth
        ) + textSize.width / 2
        context.draw(
            resolved,
            at: CGPoint(x: x, y: centerY),
            anchor: .center
        )
    }

    /// Shift a focused chip or chip group back inside the canvas while
    /// preserving centered playhead tracking whenever the element fits
    /// naturally. If the element is wider than the canvas, pin its
    /// leading edge so the readable start remains visible.
    private func edgeAwareLeadingX(
        naturalLeadingX: CGFloat,
        width: CGFloat,
        canvasWidth: CGFloat
    ) -> CGFloat {
        guard naturalLeadingX.isFinite,
              width.isFinite,
              canvasWidth.isFinite else {
            return naturalLeadingX
        }
        let maxLeadingX = max(0, canvasWidth - width)
        return max(0, min(maxLeadingX, naturalLeadingX))
    }

    // MARK: - Layer 5a: dim outside bracket

    /// Darkens the canvas regions that fall outside the painted bracket
    /// so the scope-narrowing effect of the bracket reads visually. No
    /// effect when no bracket is set. The opacity is chosen low enough
    /// that context ticks underneath remain perceptible — the goal is
    /// "these are out of scope," not "these are gone."
    private func drawDimOutsideBracket(
        context: GraphicsContext,
        projector: TimelineProjector,
        size: CGSize
    ) {
        guard let range = workspace.bracketedRange else { return }
        let x0 = projector.x(for: range.lowerBound)
        let x1 = projector.x(for: range.upperBound)
        let left = min(x0, x1)
        let right = max(x0, x1)
        let dim: GraphicsContext.Shading = .color(.black.opacity(0.42))
        if left > 0 {
            let leftRect = CGRect(x: 0, y: 0, width: left, height: size.height)
            context.fill(Path(leftRect), with: dim)
        }
        if right < size.width {
            let rightRect = CGRect(x: right, y: 0, width: size.width - right, height: size.height)
            context.fill(Path(rightRect), with: dim)
        }
    }

    // MARK: - Layer 5: bracketed-range overlay

    private func drawBracketOverlay(
        context: GraphicsContext,
        projector: TimelineProjector,
        size: CGSize
    ) {
        guard let range = workspace.bracketedRange else { return }
        let x0 = projector.x(for: range.lowerBound)
        let x1 = projector.x(for: range.upperBound)
        let rect = CGRect(
            x: min(x0, x1),
            y: 0,
            width: abs(x1 - x0),
            height: size.height
        )
        context.fill(Path(rect), with: .color(OhiaColors.ohiaYellow.opacity(0.06)))
        var marker = Path()
        marker.move(to: CGPoint(x: rect.minX, y: 0))
        marker.addLine(to: CGPoint(x: rect.minX, y: size.height))
        marker.move(to: CGPoint(x: rect.maxX, y: 0))
        marker.addLine(to: CGPoint(x: rect.maxX, y: size.height))
        context.stroke(marker, with: .color(OhiaColors.ohiaYellow.opacity(0.7)), lineWidth: 1)
    }

    // MARK: - Layer 6: chapter separators

    private func drawChapterSeparators(
        context: GraphicsContext,
        projector: TimelineProjector,
        snapshot: TimelineLayoutSnapshot,
        size: CGSize
    ) {
        for chapter in snapshot.chapters {
            let x = projector.x(for: chapter.start)
            guard x >= 0 && x <= size.width else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(OhiaColors.glassBorder.opacity(0.7)), lineWidth: 0.5)
        }
    }

    // MARK: - Layer 7: playhead

    private func drawPlayhead(
        context: GraphicsContext,
        projector: TimelineProjector,
        size: CGSize
    ) {
        let x = projector.x(for: workspace.playhead)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(OhiaColors.ohiaYellow), lineWidth: 1.5)
    }

    // MARK: - Gestures

    private func combinedGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let snapshot = workspace.currentSnapshot else { return }
                let projector = makeProjector(
                    size: size,
                    snapshot: snapshot,
                    rows: visibleRowOrder(snapshot: snapshot)
                )
                if lastDragLocation == nil {
                    lastDragLocation = value.startLocation
                    dragMoved = false
                    panBaselineStart = workspace.viewportRange.lowerBound
                    panBaselineSpan = workspace.viewportRange.upperBound
                        .timeIntervalSince(workspace.viewportRange.lowerBound)
                }
                if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                    dragMoved = true
                }
                if NSEvent.modifierFlags.contains(.option) {
                    panViewport(
                        startBaseline: panBaselineStart ?? workspace.viewportRange.lowerBound,
                        dragTranslation: -value.translation.width,
                        projector: projector
                    )
                } else if dragMoved {
                    // Only scrub the playhead once the gesture has
                    // crossed the >2pt drag threshold. On a plain tap
                    // (mouse-down + mouse-up with no movement), this
                    // branch never runs and `.onEnded` gets first crack
                    // at the chip hit-test against rects from the
                    // pre-press render — so the sender / receiver /
                    // Purpose / threads chips don't reflow under the
                    // cursor between press and release. Without this
                    // gate, `DragGesture(minimumDistance: 0)` fires
                    // `.onChanged` on the initial press and moves the
                    // playhead, which re-anchors every focused-email
                    // chip, and the click resolves against the
                    // wrong layout — the "jitter" effect.
                    workspace.setPlayhead(projector.date(forX: value.location.x))
                }
            }
            .onEnded { value in
                guard let snapshot = workspace.currentSnapshot else { return }
                let projector = makeProjector(
                    size: size,
                    snapshot: snapshot,
                    rows: visibleRowOrder(snapshot: snapshot)
                )
                if dragMoved == false {
                    // Chip hit-test first — a click that lands on a
                    // multitrack chip toggles its row's active-chip
                    // set instead of moving the playhead, so the user
                    // can scope a row's tick highlight to a specific
                    // sender / recipient / Purpose / etc.
                    if let chipKey = chipHitTester.hitTest(value.location) {
                        chipFilterToggle(row: chipKey.row, value: chipKey.value)
                    } else {
                        let hitter = TimelineHitTester(snapshot: snapshot, projector: projector)
                        switch hitter.hit(at: value.location) {
                        case .event(_, let date):
                            workspace.setPlayhead(date)
                        default:
                            // The new row-based hit tester only emits `.event`
                            // or `.empty`; the legacy cases (`.clip`, `.attachment`,
                            // `.chapter`, etc.) are preserved on the enum for
                            // call-site stability but are unreachable here.
                            workspace.setPlayhead(projector.date(forX: value.location.x))
                        }
                    }
                }
                lastDragLocation = nil
                panBaselineStart = nil
                panBaselineSpan = nil
                dragMoved = false
            }
    }

    private func panViewport(
        startBaseline: Date,
        dragTranslation: CGFloat,
        projector: TimelineProjector
    ) {
        let ppd = projector.viewportPixelsPerDay
        guard ppd > 0 else { return }
        let daysOffset = Double(dragTranslation) / ppd
        let secondsOffset = daysOffset * TimelineProjector.secondsPerDay
        let span = panBaselineSpan ?? workspace.viewportRange.upperBound
            .timeIntervalSince(workspace.viewportRange.lowerBound)
        let newLower = startBaseline.addingTimeInterval(secondsOffset)
        let newUpper = newLower.addingTimeInterval(span)
        workspace.setViewportRange(newLower...newUpper)
    }

    private func handleHover(phase: HoverPhase, size: CGSize) {
        switch phase {
        case .ended:
            workspace.hoveredEntity = nil
        case .active(let point):
            guard let snapshot = workspace.currentSnapshot else { return }
            let projector = makeProjector(
                size: size,
                snapshot: snapshot,
                rows: visibleRowOrder(snapshot: snapshot)
            )
            let hitter = TimelineHitTester(snapshot: snapshot, projector: projector)
            if chipHitTester.hitTest(point) != nil {
                workspace.hoveredEntity = nil
            } else if let tickHit = contextTickHitTester.hitTest(point) {
                workspace.hoveredEntity = .contextTick(
                    messageID: tickHit.messageID,
                    row: tickHit.row
                )
            } else {
                switch hitter.hit(at: point) {
                case .event(let id, _):
                    workspace.hoveredEntity = .event(messageID: id)
                default:
                    let date = projector.date(forX: point.x)
                    workspace.hoveredEntity = .ruler(date: date)
                }
            }
        @unknown default:
            workspace.hoveredEntity = nil
        }
    }
}
