import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

enum ProjectsTimeLayoutMetrics {
    /// Wide enough for the Front Page-register project cards (title, byline,
    /// status line) the gutter renders — the project is the primary object of
    /// this lens and its card carries the reading weight.
    static let gutterWidth: CGFloat = 300
    static let defaultRowHeight: CGFloat = 64
    static let defaultCanvasWidth: CGFloat = 900
    /// Trailing reserved zone for `ProjectsObligationOverlay`'s per-row pip
    /// column (pip width + trailing padding + slack). The Projects time
    /// projection narrows by this amount so the rightmost-dated message dot
    /// never collides with the at-rest obligation pips floating over the
    /// canvas's trailing edge. Single source of truth — referenced by both
    /// `ProjectsTimeView.draw(...)` (projection width) and
    /// `ProjectsTimeViewRowRenderer.drawMessageMarks(...)` (clamp upper
    /// bound).
    static let pipColumnInset: CGFloat = 32
}

// MARK: - State

struct ProjectsMessageReadoutState: Equatable, Sendable {
    let messageID: UUID
    var anchorPoint: CGPoint
    var expanded: Bool
    var expandedMode: AnnotationExpandedContentMode
    var isPinned: Bool
    /// Content-space region the popup body must stay clear of. The
    /// Links lens passes the project circle + obligation chip so the
    /// readout never covers the node it annotates; the placement then
    /// restricts itself to above/below with the callout tip locked to
    /// the chip. `nil` (Time view) keeps the four-side placement.
    var avoidRect: CGRect?
}

// MARK: - Item builder

/// Display-derived fragments used by `ProjectsHoverPopup` for the
/// Variant-E header. Kept alongside the `AnnotationItem` so the
/// adapter (`ProjectsAnnotationItemBuilder`) is the single source of
/// truth for sender/date formatting across the popup surface.
struct ProjectsHoverDerived: Equatable {
    let senderPrefix: String
    let senderLabel: String
    let dateLabel: String
    let messageDate: Date?
    /// Display name of the To recipient(s) when the message was received
    /// but NOT addressed to the user — the routing line then reads
    /// "from <sender> to <toLabel>". Empty when the user is a To
    /// recipient (routing is implied), when the user's addresses are
    /// unknown, or for sent messages.
    let toLabel: String
    /// `true` when the user appears in the recipient set without being a
    /// To recipient — the routing line appends "cc you".
    let isUserCcd: Bool

    /// Plain-text rendition of the full sender · routing · date line.
    /// Used by `ProjectsHoverPopupLayout` to estimate how many lines the
    /// italic composite wraps to, so the popup frame reserves real height
    /// instead of a fixed single line.
    var senderLinePlainText: String {
        var line = ""
        if !senderLabel.isEmpty {
            line = senderPrefix.isEmpty ? senderLabel : "\(senderPrefix) \(senderLabel)"
        }
        if !toLabel.isEmpty {
            line += line.isEmpty ? "to \(toLabel)" : " to \(toLabel)"
        }
        if isUserCcd {
            line += line.isEmpty ? "cc you" : " · cc you"
        }
        if !dateLabel.isEmpty {
            line += line.isEmpty ? dateLabel : " · \(dateLabel)"
        }
        return line
    }
}

struct ProjectsAnnotationDisplay {
    let item: AnnotationItem
    let derived: ProjectsHoverDerived
}

enum ProjectsAnnotationItemBuilder {
    static func makeItem(
        messageID: UUID,
        row: MessageFilterRow,
        summaryOverride: String?
    ) -> AnnotationItem {
        makeDisplay(messageID: messageID, row: row, summaryOverride: summaryOverride).item
    }

    static func makeDisplay(
        messageID: UUID,
        row: MessageFilterRow,
        summaryOverride: String?,
        userAddresses: Set<String> = []
    ) -> ProjectsAnnotationDisplay {
        let messageIdString = messageID.uuidString
        let isSentByUser = row.isSentByUser
        let counterparty = counterpartyLabel(row: row, isSentByUser: isSentByUser)
        let routing = routingInfo(row: row, isSentByUser: isSentByUser, userAddresses: userAddresses)
        let directionPrefix = isSentByUser ? "to" : "from"
        let directedLabel = counterparty.isEmpty
            ? directionPrefix
            : "\(directionPrefix) \(counterparty)"
        let dateLabel = dateLabel(for: row.receivedAt)
        let purposeLabel = row.purpose?.displayLabel ?? "—"
        let briefParts = [directedLabel, dateLabel, purposeLabel].filter { !$0.isEmpty && $0 != "—" }
        let briefText = briefParts.isEmpty ? directedLabel : briefParts.joined(separator: " · ")
        let override = summaryOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (override?.isEmpty == false ? override : nil)
            ?? row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: AnnotationKind = isSentByUser ? .reply : .threadRelative
        let item = AnnotationItem(
            id: "projects:\(messageIdString)",
            kind: kind,
            anchorVectorId: nil,
            anchorMessageId: messageIdString,
            anchorWorld: .zero,
            title: row.subject.isEmpty ? "(no subject)" : row.subject,
            headerPrimaryDetail: "",
            detail: dateLabel,
            briefText: briefText,
            extras: [],
            relevance: nil,
            badgeText: "",
            importance: 0.5,
            contextReason: "",
            summary: summary?.isEmpty == false ? summary : nil,
            directionSymbol: isSentByUser ? "paperplane.fill" : "tray.and.arrow.down",
            radialAffinity: nil,
            badgeSortDate: row.receivedAt,
            attachmentReference: nil
        )
        let derived = ProjectsHoverDerived(
            senderPrefix: counterparty.isEmpty ? "" : directionPrefix,
            senderLabel: counterparty,
            dateLabel: dateLabel == "—" ? "" : dateLabel,
            messageDate: row.receivedAt,
            toLabel: routing.toLabel,
            isUserCcd: routing.isUserCcd
        )
        return ProjectsAnnotationDisplay(item: item, derived: derived)
    }

    /// Routing exposure for received messages the user wasn't addressed
    /// to directly. When the user appears in To, routing stays silent
    /// ("to you" is implied). Otherwise the To party is named, and "cc
    /// you" is claimed only when the user actually appears in the wider
    /// recipient set — list mail where the user appears nowhere shows
    /// the To party without asserting a cc role.
    private static func routingInfo(
        row: MessageFilterRow,
        isSentByUser: Bool,
        userAddresses: Set<String>
    ) -> (toLabel: String, isUserCcd: Bool) {
        guard !isSentByUser, !userAddresses.isEmpty else { return ("", false) }
        let userInTo = row.toAddresses.contains { userAddresses.contains($0.lowercased()) }
        guard !userInTo else { return ("", false) }
        let extraCount = max(0, row.toAddresses.count - 1)
        let extra = extraCount > 0 ? " +\(extraCount)" : ""
        let toLabel: String
        if let firstName = row.toDisplayNames.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            toLabel = firstName + extra
        } else if let firstAddress = row.toAddresses.first {
            toLabel = firstAddress + extra
        } else {
            toLabel = ""
        }
        let isUserCcd = row.recipientAddresses.contains { userAddresses.contains($0.lowercased()) }
        return (toLabel, isUserCcd)
    }

    private static func counterpartyLabel(row: MessageFilterRow, isSentByUser: Bool) -> String {
        if isSentByUser {
            let names = row.toDisplayNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let first = names.first {
                let extra = names.count > 1 ? " +\(names.count - 1)" : ""
                return first + extra
            }
            if let first = row.toAddresses.first {
                let extra = row.toAddresses.count > 1 ? " +\(row.toAddresses.count - 1)" : ""
                return first + extra
            }
            return ""
        }
        let fromName = row.fromName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromName.isEmpty ? row.fromAddress : fromName
    }

    private static func dateLabel(for date: Date?) -> String {
        guard let date else { return "—" }
        return projectsReadoutDateFormatter.string(from: date)
    }
}

private let projectsReadoutDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

// MARK: - Focused project category control

/// The same fixed-purpose plus additive custom-category editor used by the
/// other message readers, exposed only after a focused project card expands.
/// Category creation remains owned by ConstellationTopBar.
struct ProjectMessageCategoryControl: View {
    let classification: MailClassification?
    let customCategoryKeys: Set<String>
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    let onChange: (MailClassification?, Set<String>) -> Void

    @State private var pickerShown = false

    private var validCustomKeys: Set<String> {
        customCategoryKeys.intersection(Set(customCategoryCatalog.map(\.key)))
    }

    private var categoryLabel: String {
        classification?.purpose?.displayLabel ?? "Set Category"
    }

    var body: some View {
        Button {
            pickerShown.toggle()
        } label: {
            Label(categoryLabel, systemImage: classification?.purpose?.systemImageName ?? "tag")
        }
        .buttonStyle(.emblem)
        .help(classification == nil ? "Set category" : "Change category")
        .accessibilityLabel("Category: \(categoryLabel). Change category.")
        .popover(isPresented: $pickerShown, arrowEdge: .bottom) {
            MenuPopoverContent(headerLabel: "Category") {
                ForEach(MailPurpose.allCases, id: \.self) { purpose in
                    MenuRow(
                        name: purpose.displayLabel,
                        symbolName: purpose.systemImageName,
                        isChecked: classification?.purpose == purpose,
                        action: {
                            onChange(.userAssigned(purpose: purpose), validCustomKeys)
                        }
                    )
                }
                if !customCategoryCatalog.isEmpty {
                    Rectangle()
                        .fill(OhiaColors.glassBorder)
                        .frame(height: 1)
                        .padding(.vertical, 3)
                }
                ForEach(customCategoryCatalog) { descriptor in
                    MenuRow(
                        name: CustomCategoryStore.menuLabel(for: descriptor),
                        symbolName: ToggleIconography.customCategorySymbolName,
                        isChecked: validCustomKeys.contains(descriptor.key),
                        action: {
                            var next = validCustomKeys
                            if next.contains(descriptor.key) {
                                next.remove(descriptor.key)
                            } else {
                                next.insert(descriptor.key)
                            }
                            onChange(classification, next)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Popup placement

enum ProjectsPopupPlacement {
    static let margin: CGFloat = 12
    /// Extra envelope so the popup shadow stays inside the viewport.
    static let shadowPadding = CGSize(width: 10, height: 18)
    private static let calloutCornerRadius: CGFloat = 4

    struct Geometry {
        let layoutSize: CGSize
        let popupCenter: CGPoint
        /// `nil` only for expanded states whose compact notch would no
        /// longer point at the node (see `expandedGeometry`); every
        /// fresh placement carries a callout.
        let callout: AnnotationPopupCallout?
    }

    private enum Placement: CaseIterable {
        case above
        case below
        case trailing
        case leading

        var initialCallout: AnnotationPopupCallout {
            switch self {
            case .above:
                return AnnotationPopupCallout(edge: .bottom, anchor: 0.5)
            case .below:
                return AnnotationPopupCallout(edge: .top, anchor: 0.5)
            case .trailing:
                return AnnotationPopupCallout(edge: .leading, anchor: 0.5)
            case .leading:
                return AnnotationPopupCallout(edge: .trailing, anchor: 0.5)
            }
        }

        var preferencePenalty: CGFloat {
            switch self {
            case .above:
                return 0
            case .below:
                return 0.01
            case .trailing, .leading:
                return 0.02
            }
        }
    }

    private struct Candidate {
        let geometry: Geometry
        let score: CGFloat
    }

    static func geometry(
        for item: AnnotationItem,
        expanded: Bool,
        expandedMode: AnnotationExpandedContentMode = .summary,
        summaryDisplay: AnnotationSummaryDisplay? = nil,
        messageDisplay: AnnotationMessageDisplay? = nil,
        nodePoint: CGPoint,
        viewSize: CGSize
    ) -> Geometry {
        let baseSize = ProjectsHoverPopupLayout.messageReadoutBaseSize(
            item: item,
            expanded: expanded,
            expandedMode: expandedMode,
            summaryDisplay: summaryDisplay,
            messageDisplay: messageDisplay,
            maxViewportWidth: viewSize.width,
            maxViewportHeight: viewSize.height
        )
        return geometry(baseSize: baseSize, nodePoint: nodePoint, viewSize: viewSize)
    }

    /// Vertical-only placement for popups anchored to a chip hanging off
    /// a node, where the node itself must stay visible: the popup sits
    /// fully below `avoidRect` when there is room (callout on its top
    /// edge, tip just under the chip), otherwise fully above it (callout
    /// on the bottom edge). The tip's x is locked to `nodePoint.x` so the
    /// triangle always points at the chip, and the popup body never
    /// covers the exclusion zone unless neither side can hold it.
    static func verticalGeometry(
        baseSize: CGSize,
        nodePoint: CGPoint,
        avoidRect: CGRect,
        viewSize: CGSize
    ) -> Geometry {
        let depth = AnnotationPopupCallout(edge: .top, anchor: 0.5).depth
        let layoutSize = CGSize(width: baseSize.width, height: baseSize.height + depth)
        let halfW = layoutSize.width / 2
        let halfH = layoutSize.height / 2
        let tipGap: CGFloat = 2

        guard viewSize.width > 0, viewSize.height > 0 else {
            return Geometry(
                layoutSize: layoutSize,
                popupCenter: CGPoint(x: nodePoint.x, y: avoidRect.maxY + tipGap + halfH),
                callout: AnnotationPopupCallout(edge: .top, anchor: 0.5)
            )
        }

        let envelope = layoutEnvelope(for: layoutSize)
        let maxHalfW = max(20, (viewSize.width - 2 * margin) / 2)
        let maxHalfH = max(20, (viewSize.height - 2 * margin) / 2)
        let effectiveHalfW = min(envelope.width / 2, maxHalfW)
        let effectiveHalfH = min(envelope.height / 2, maxHalfH)

        let centerX = min(
            max(nodePoint.x, effectiveHalfW + margin),
            viewSize.width - effectiveHalfW - margin
        )

        func clampedY(_ y: CGFloat) -> CGFloat {
            min(max(y, effectiveHalfH + margin), viewSize.height - effectiveHalfH - margin)
        }
        let belowY = avoidRect.maxY + tipGap + halfH
        let aboveY = avoidRect.minY - tipGap - halfH
        let placeBelow: Bool
        if clampedY(belowY) == belowY {
            placeBelow = true
        } else if clampedY(aboveY) == aboveY {
            placeBelow = false
        } else {
            // Neither side has full clearance (e.g. an expanded popup in a
            // short viewport) — take the roomier side; the clamp keeps the
            // popup on-screen and partial overlap is unavoidable.
            placeBelow = (viewSize.height - avoidRect.maxY) >= avoidRect.minY
        }

        let popupCenter = CGPoint(x: centerX, y: clampedY(placeBelow ? belowY : aboveY))
        let anchorFraction = layoutSize.width > 0
            ? min(max((nodePoint.x - (centerX - halfW)) / layoutSize.width, 0), 1)
            : 0.5
        return Geometry(
            layoutSize: layoutSize,
            popupCenter: popupCenter,
            callout: AnnotationPopupCallout(
                edge: placeBelow ? .top : .bottom,
                anchor: anchorFraction
            )
        )
    }

    /// Geometry for an expanded readout derived from its compact
    /// placement. Expansion must never move the header row — the pointer
    /// sits on the chevron inside it, and a header shift drops hover
    /// residency and dismisses the card — so the compact frame's top
    /// edge and horizontal position are held fixed and the popup grows
    /// strictly downward, height-clamped at the viewport bottom. The
    /// callout notch survives only where it keeps pointing at the node:
    /// a `.top` notch shares the fixed top edge, side notches rescale
    /// their anchor fraction to the new height, and a `.bottom` notch —
    /// which would ride the growing bottom edge away from the node — is
    /// dropped for the expanded states and returns on collapse.
    static func expandedGeometry(
        compact: Geometry,
        expandedBaseSize: CGSize,
        viewSize: CGSize
    ) -> Geometry {
        let compactTop = compact.popupCenter.y - compact.layoutSize.height / 2
        let callout: AnnotationPopupCallout?
        let unclamped: CGSize
        switch compact.callout?.edge {
        case .top:
            callout = compact.callout
            unclamped = CGSize(
                width: expandedBaseSize.width,
                height: expandedBaseSize.height + (compact.callout?.depth ?? 0)
            )
        case .leading, .trailing:
            callout = compact.callout
            unclamped = CGSize(
                width: expandedBaseSize.width + (compact.callout?.depth ?? 0),
                height: expandedBaseSize.height
            )
        case .bottom, nil:
            callout = nil
            unclamped = expandedBaseSize
        }
        let maxHeight = max(40, viewSize.height - margin - compactTop)
        let height = min(unclamped.height, maxHeight)
        let layoutSize = CGSize(width: unclamped.width, height: height)
        let popupCenter = CGPoint(x: compact.popupCenter.x, y: compactTop + height / 2)
        var resolved = callout
        if var side = callout, side.edge == .leading || side.edge == .trailing, height > 0 {
            // Side anchors are fractions of the popup height; rescale so
            // the notch keeps its screen position (the node) as the
            // fixed-top popup grows beneath it.
            let fraction = side.anchor * compact.layoutSize.height / height
            side.anchor = min(max(fraction, 0), 1)
            resolved = side
        }
        return Geometry(layoutSize: layoutSize, popupCenter: popupCenter, callout: resolved)
    }

    /// Variant used by surfaces whose popup base size is not derived from an
    /// `AnnotationItem` — e.g. the Links lens project-summary hover popup.
    static func geometry(
        baseSize: CGSize,
        nodePoint: CGPoint,
        viewSize: CGSize
    ) -> Geometry {
        return Placement.allCases
            .map { candidate(for: $0, baseSize: baseSize, nodePoint: nodePoint, viewSize: viewSize) }
            .min { lhs, rhs in lhs.score < rhs.score }?
            .geometry
            ?? fallbackGeometry(baseSize: baseSize, nodePoint: nodePoint, viewSize: viewSize)
    }

    private static func candidate(
        for placement: Placement,
        baseSize: CGSize,
        nodePoint: CGPoint,
        viewSize: CGSize
    ) -> Candidate {
        var callout = placement.initialCallout

        for _ in 0..<8 {
            let layoutSize = popupSize(baseSize: baseSize, callout: callout)
            let envelope = layoutEnvelope(for: layoutSize)
            let popupCenter = center(
                placement: placement,
                nodePoint: nodePoint,
                viewSize: viewSize,
                popupSize: layoutSize,
                popupEnvelope: envelope
            )
            let resolvedCallout = AnnotationPopupCallout.pointing(
                to: nodePoint,
                from: popupCenter,
                popupSize: layoutSize
            )

            if resolvedCallout.edge == callout.edge {
                return Candidate(
                    geometry: Geometry(layoutSize: layoutSize, popupCenter: popupCenter, callout: resolvedCallout),
                    score: score(
                        for: resolvedCallout,
                        popupCenter: popupCenter,
                        popupSize: layoutSize,
                        nodePoint: nodePoint,
                        placement: placement
                    )
                )
            }
            callout = resolvedCallout
        }

        let layoutSize = popupSize(baseSize: baseSize, callout: callout)
        let envelope = layoutEnvelope(for: layoutSize)
        let popupCenter = center(
            placement: placement,
            nodePoint: nodePoint,
            viewSize: viewSize,
            popupSize: layoutSize,
            popupEnvelope: envelope
        )
        let resolvedCallout = AnnotationPopupCallout.pointing(
            to: nodePoint,
            from: popupCenter,
            popupSize: layoutSize
        )
        if resolvedCallout.edge == callout.edge {
            callout = resolvedCallout
        }
        return Candidate(
            geometry: Geometry(layoutSize: layoutSize, popupCenter: popupCenter, callout: callout),
            score: score(
                for: callout,
                popupCenter: popupCenter,
                popupSize: layoutSize,
                nodePoint: nodePoint,
                placement: placement
            )
        )
    }

    private static func fallbackGeometry(
        baseSize: CGSize,
        nodePoint: CGPoint,
        viewSize: CGSize
    ) -> Geometry {
        let callout = Placement.above.initialCallout
        let layoutSize = popupSize(baseSize: baseSize, callout: callout)
        let envelope = layoutEnvelope(for: layoutSize)
        let popupCenter = center(
            placement: .above,
            nodePoint: nodePoint,
            viewSize: viewSize,
            popupSize: layoutSize,
            popupEnvelope: envelope
        )
        return Geometry(layoutSize: layoutSize, popupCenter: popupCenter, callout: callout)
    }

    private static func popupSize(
        baseSize: CGSize,
        callout: AnnotationPopupCallout?
    ) -> CGSize {
        guard let callout else { return baseSize }
        if callout.edge.isHorizontal {
            return CGSize(width: baseSize.width, height: baseSize.height + callout.depth)
        }
        return CGSize(width: baseSize.width + callout.depth, height: baseSize.height)
    }

    static func layoutEnvelope(for popupSize: CGSize) -> CGSize {
        return CGSize(
            width: popupSize.width + shadowPadding.width,
            height: popupSize.height + shadowPadding.height
        )
    }

    /// Places the popup around the node, then clamps inside the viewport.
    /// Candidate scoring chooses the side whose actual callout tip stays
    /// closest to the node after clamping.
    private static func center(
        placement: Placement,
        nodePoint: CGPoint,
        viewSize: CGSize,
        popupSize: CGSize,
        popupEnvelope: CGSize
    ) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return CGPoint(x: nodePoint.x, y: nodePoint.y - popupSize.height / 2)
        }

        let halfW = popupSize.width / 2
        let halfH = popupSize.height / 2
        let envelopeHalfW = popupEnvelope.width / 2
        let envelopeHalfH = popupEnvelope.height / 2
        let maxHalfW = max(20, (viewSize.width - 2 * margin) / 2)
        let maxHalfH = max(20, (viewSize.height - 2 * margin) / 2)
        let effectiveHalfW = min(envelopeHalfW, maxHalfW)
        let effectiveHalfH = min(envelopeHalfH, maxHalfH)

        let unclamped: CGPoint
        switch placement {
        case .above:
            unclamped = CGPoint(x: nodePoint.x, y: nodePoint.y - halfH)
        case .below:
            unclamped = CGPoint(x: nodePoint.x, y: nodePoint.y + halfH)
        case .trailing:
            unclamped = CGPoint(x: nodePoint.x + halfW, y: nodePoint.y)
        case .leading:
            unclamped = CGPoint(x: nodePoint.x - halfW, y: nodePoint.y)
        }

        return clampCenter(
            unclamped,
            halfWidth: effectiveHalfW,
            halfHeight: effectiveHalfH,
            viewSize: viewSize
        )
    }

    static func calloutTip(
        callout: AnnotationPopupCallout,
        popupCenter: CGPoint,
        popupSize: CGSize
    ) -> CGPoint {
        let rect = CGRect(
            x: popupCenter.x - popupSize.width / 2,
            y: popupCenter.y - popupSize.height / 2,
            width: popupSize.width,
            height: popupSize.height
        )
        let bodyRect = bodyRect(in: rect, callout: callout)
        let radius = min(calloutCornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        switch callout.edge {
        case .top:
            return CGPoint(
                x: clampedHorizontalAnchor(in: bodyRect, callout: callout, radius: radius),
                y: rect.minY
            )
        case .trailing:
            return CGPoint(
                x: rect.maxX,
                y: clampedVerticalAnchor(in: bodyRect, callout: callout, radius: radius)
            )
        case .bottom:
            return CGPoint(
                x: clampedHorizontalAnchor(in: bodyRect, callout: callout, radius: radius),
                y: rect.maxY
            )
        case .leading:
            return CGPoint(
                x: rect.minX,
                y: clampedVerticalAnchor(in: bodyRect, callout: callout, radius: radius)
            )
        }
    }

    private static func score(
        for callout: AnnotationPopupCallout,
        popupCenter: CGPoint,
        popupSize: CGSize,
        nodePoint: CGPoint,
        placement: Placement
    ) -> CGFloat {
        let tip = calloutTip(callout: callout, popupCenter: popupCenter, popupSize: popupSize)
        let dx = tip.x - nodePoint.x
        let dy = tip.y - nodePoint.y
        return dx * dx + dy * dy + placement.preferencePenalty
    }

    private static func bodyRect(in rect: CGRect, callout: AnnotationPopupCallout) -> CGRect {
        let depth = max(0, callout.depth)
        switch callout.edge {
        case .top:
            return CGRect(
                x: rect.minX,
                y: min(rect.maxY, rect.minY + depth),
                width: rect.width,
                height: max(0, rect.height - depth)
            )
        case .trailing:
            return CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(0, rect.width - depth),
                height: rect.height
            )
        case .bottom:
            return CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: max(0, rect.height - depth)
            )
        case .leading:
            return CGRect(
                x: min(rect.maxX, rect.minX + depth),
                y: rect.minY,
                width: max(0, rect.width - depth),
                height: rect.height
            )
        }
    }

    private static func clampedHorizontalAnchor(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        let halfBase = horizontalHalfBase(in: bodyRect, callout: callout, radius: radius)
        let minX = bodyRect.minX + radius + halfBase
        let maxX = bodyRect.maxX - radius - halfBase
        guard minX <= maxX else { return bodyRect.midX }
        return min(max(bodyRect.minX + bodyRect.width * callout.anchor, minX), maxX)
    }

    private static func clampedVerticalAnchor(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        let halfBase = verticalHalfBase(in: bodyRect, callout: callout, radius: radius)
        let minY = bodyRect.minY + radius + halfBase
        let maxY = bodyRect.maxY - radius - halfBase
        guard minY <= maxY else { return bodyRect.midY }
        return min(max(bodyRect.minY + bodyRect.height * callout.anchor, minY), maxY)
    }

    private static func horizontalHalfBase(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        min(callout.baseWidth / 2, max(0, bodyRect.width - 2 * radius) / 2)
    }

    private static func verticalHalfBase(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        min(callout.baseWidth / 2, max(0, bodyRect.height - 2 * radius) / 2)
    }

    static func viewportAnchor(
        contentAnchor: CGPoint,
        scrollContentMinY: CGFloat
    ) -> CGPoint {
        CGPoint(x: contentAnchor.x, y: contentAnchor.y + scrollContentMinY)
    }

    private static func clampCenter(
        _ center: CGPoint,
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        viewSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(center.x, halfWidth + margin), viewSize.width - halfWidth - margin),
            y: min(max(center.y, halfHeight + margin), viewSize.height - halfHeight - margin)
        )
    }

}

// MARK: - Keyboard

struct ProjectsKeyboardCatcher: NSViewRepresentable {
    /// Returns true when Space was consumed.
    let onSpace: @MainActor () -> Bool
    /// Returns true when Shift+Space was consumed.
    let onShiftSpace: @MainActor () -> Bool
    /// Escape ladder. Returns true when a rung consumed the key — false
    /// passes the event through so popovers/system dismissal still work.
    /// Routed through this NSEvent monitor (like Space) because the
    /// workspace's SwiftUI `.onKeyPress(.escape)` only fires once the
    /// focusable container has key focus, which pure mouse use never
    /// grants — without this, a pinned readout was undismissable from
    /// the keyboard.
    let onEscape: @MainActor () -> Bool
    /// ↑/↓ selection stepping (delta −1 / +1). Returns true when the step
    /// consumed the key; false passes the event through (Links mode, empty
    /// roster) so default scrolling survives. Routed here for the same
    /// reason as Space/Escape: pure mouse use never grants the SwiftUI
    /// container key focus. Autorepeat comes free — held keys deliver
    /// repeating keyDown events to the monitor.
    let onStepSelection: @MainActor (Int) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.focusRingType = .none
        view.onSpace = onSpace
        view.onShiftSpace = onShiftSpace
        view.onEscape = onEscape
        view.onStepSelection = onStepSelection
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onShiftSpace = onShiftSpace
        nsView.onEscape = onEscape
        nsView.onStepSelection = onStepSelection
    }

    final class CatcherView: NSView {
        var onSpace: (@MainActor () -> Bool)?
        var onShiftSpace: (@MainActor () -> Bool)?
        var onEscape: (@MainActor () -> Bool)?
        var onStepSelection: (@MainActor (Int) -> Bool)?

        private var monitor: Any?
        private var monitorAttempted = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !monitorAttempted {
                monitorAttempted = true
                installMonitor()
            } else if window == nil {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                monitorAttempted = false
            }
        }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if Self.firstResponderIsTextInput(in: window) { return event }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let blocking: NSEvent.ModifierFlags = [.command, .option, .control]
                if event.keyCode == 53 {
                    // Escape — consume only when a ladder rung acted, so an
                    // open sheet or popover keeps its own dismissal.
                    guard window.attachedSheet == nil, mods.isDisjoint(with: blocking) else { return event }
                    if self.onEscape?() == true {
                        return nil
                    }
                    return event
                }
                if event.keyCode == 125 || event.keyCode == 126 {
                    // Bare arrows only — but arrow keys ALWAYS carry
                    // .function/.numericPad, so judge just the four real
                    // modifiers: ⇧ stays free for future range extension,
                    // and ⌘/⌥/⌃ combos belong to the system.
                    guard mods.intersection([.command, .option, .control, .shift]).isEmpty else {
                        return event
                    }
                    let delta = event.keyCode == 125 ? 1 : -1
                    if self.onStepSelection?(delta) == true {
                        return nil
                    }
                    return event
                }
                guard event.keyCode == 49 else { return event }
                if mods.contains(.shift) {
                    if self.onShiftSpace?() == true {
                        return nil
                    }
                    return event
                }
                if mods.isDisjoint(with: blocking) {
                    if self.onSpace?() == true {
                        return nil
                    }
                    return event
                }
                return event
            }
        }

        private static func firstResponderIsTextInput(in window: NSWindow) -> Bool {
            var responder: NSResponder? = window.firstResponder
            while let r = responder {
                if r is NSTextView || r is NSTextField || r is NSSearchField {
                    return true
                }
                responder = r.nextResponder
            }
            return false
        }
    }
}

// MARK: - Overlay

struct ProjectsMessageReadoutOverlay: View {
    @Bindable var workspace: ProjectsWorkspaceState
    let snapshot: ProjectsSnapshot
    /// Visible timeline / links canvas size (not scroll content extent).
    let viewportSize: CGSize
    /// Min-Y of scroll content in the Projects Time viewport; zero in Links mode.
    let scrollContentMinY: CGFloat
    let summaryByMessageId: [String: String]
    let summaryUnavailableReasonByMessageId: [String: String]
    let summaryUnavailableMessageIds: Set<String>
    let regeneratingSummaryMessageIds: Set<String>
    let modelContext: ModelContext

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var relatedSummaryStates: [String: RelatedSummaryState] = [:]
    @State private var relatedMessageBodyStates: [String: RelatedBodyState] = [:]
    @State private var presentedReadout: ProjectsMessageReadoutState?
    @State private var presentedReadoutProgress: CGFloat = 0
    @State private var presentationAnimationID = UUID()
    @State private var exitingReadout: ProjectsMessageReadoutState?
    @State private var exitingReadoutProgress: CGFloat = 0
    @State private var exitAnimationID = UUID()

    private enum RelatedSummaryState: Equatable {
        case loading
        case loaded(String)
        case failed
    }

    private enum RelatedBodyState: Equatable {
        case loading
        case loaded(String)
        case failed
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let exitingReadout {
                readoutPopup(
                    readout: exitingReadout,
                    progress: exitingReadoutProgress,
                    interactive: false
                )
            }
            if let presentedReadout {
                readoutPopup(
                    readout: presentedReadout,
                    progress: presentedReadoutProgress,
                    interactive: true
                )
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .onAppear {
            syncInitialReadoutProgress()
        }
        .onChange(of: workspace.messageReadout) { oldValue, newValue in
            handleReadoutChange(from: oldValue, to: newValue)
        }
    }

    @ViewBuilder
    private func readoutPopup(
        readout: ProjectsMessageReadoutState,
        progress: CGFloat,
        interactive: Bool
    ) -> some View {
        if let row = snapshot.messageFilterRows[readout.messageID.uuidString] {
            let messageId = readout.messageID.uuidString
            let display = ProjectsAnnotationItemBuilder.makeDisplay(
                messageID: readout.messageID,
                row: row,
                summaryOverride: summaryByMessageId[messageId],
                userAddresses: snapshot.userAddresses
            )
            let item = display.item
            let derived = display.derived
            let projectRow = snapshot.row(
                containing: readout.messageID,
                preferredProjectKey: workspace.focusedProjectKey
            )
            let obligationKinds: Set<ProjectOpenObligation.Kind> = Set(
                (projectRow?.obligations ?? [])
                    .filter { $0.messageID == readout.messageID }
                    .map { $0.kind }
            )
            let mark = projectRow?.marks.first { mark in
                mark.messageID == readout.messageID
            }
            let hasDeadline = (mark?.hasDeadline ?? false)
                || (projectRow?.deadlineTicks ?? []).contains { tick in
                    tick.messageID == readout.messageID
                }
            let deadlineText = mark?.deadlineText
                ?? projectRow?.deadlineTicks.first { tick in
                    tick.messageID == readout.messageID
                }?.evidenceText
            let statusDescriptor = mark.map { mark in
                MessageStatusDescriptor(
                    mark: mark,
                    hasDeadline: hasDeadline,
                    deadlineText: deadlineText
                )
            }
            let nodeInViewport = ProjectsPopupPlacement.viewportAnchor(
                contentAnchor: readout.anchorPoint,
                scrollContentMinY: scrollContentMinY
            )
            let readingTextScale = readingTextSize.pointSize(base: 11.5) / 11.5
            let popupBaseSize = ProjectsHoverPopupLayout.messageReadoutBaseSize(
                item: item,
                senderLineText: derived.senderLinePlainText,
                expanded: readout.expanded,
                expandedMode: readout.expandedMode,
                summaryDisplay: interactive
                    ? summaryDisplay(for: messageId, row: row, item: item)
                    : nil,
                messageDisplay: interactive
                    ? messageDisplay(for: messageId, row: row)
                    : nil,
                readingTextScale: readingTextScale,
                maxViewportWidth: viewportSize.width,
                maxViewportHeight: viewportSize.height
            )
            // Placement is anchored by the COMPACT card: expanded states
            // keep the compact frame's header position and grow downward
            // (ProjectsPopupPlacement.expandedGeometry), so toggling
            // summary/message can never re-place the card and move the
            // chevron out from under the pointer — which would drop hover
            // residency and dismiss the readout mid-read.
            let compactBaseSize: CGSize = readout.expanded
                ? ProjectsHoverPopupLayout.messageReadoutBaseSize(
                    item: item,
                    senderLineText: derived.senderLinePlainText,
                    expanded: false,
                    expandedMode: .summary,
                    summaryDisplay: nil,
                    messageDisplay: nil,
                    readingTextScale: readingTextScale,
                    maxViewportWidth: viewportSize.width,
                    maxViewportHeight: viewportSize.height
                )
                : popupBaseSize
            let compactGeometry: ProjectsPopupPlacement.Geometry = {
                if let avoidRect = readout.avoidRect {
                    return ProjectsPopupPlacement.verticalGeometry(
                        baseSize: compactBaseSize,
                        nodePoint: nodeInViewport,
                        avoidRect: avoidRect.offsetBy(dx: 0, dy: scrollContentMinY),
                        viewSize: viewportSize
                    )
                }
                return ProjectsPopupPlacement.geometry(
                    baseSize: compactBaseSize,
                    nodePoint: nodeInViewport,
                    viewSize: viewportSize
                )
            }()
            let popupGeometry: ProjectsPopupPlacement.Geometry = readout.expanded
                ? ProjectsPopupPlacement.expandedGeometry(
                    compact: compactGeometry,
                    expandedBaseSize: popupBaseSize,
                    viewSize: viewportSize
                )
                : compactGeometry
            // Height the viewport-bottom clamp shaved off the fixed-header
            // expansion; the popup's body sections shrink their scroll
            // windows by this much so clamped content scrolls, not clips.
            // Only a kept `.top` notch adds depth to the ideal height —
            // side notches pad width, and a dropped `.bottom` notch adds
            // nothing.
            let expandedIdealHeight = popupBaseSize.height
                + (compactGeometry.callout?.edge == .top ? (compactGeometry.callout?.depth ?? 0) : 0)
            let bodyHeightShortfall = readout.expanded
                ? max(0, expandedIdealHeight - popupGeometry.layoutSize.height)
                : 0
            let layoutSize = popupGeometry.layoutSize
            let popupCenter = popupGeometry.popupCenter
            let genieAnchor = HoverPopupGenieAnchor.compute(
                nodePoint: nodeInViewport,
                popupCenter: popupCenter,
                popupSize: layoutSize
            )
            let visualProgress = genieVisualProgress(progress)
            let popup = ProjectsHoverPopup(
                item: item,
                expanded: readout.expanded,
                expandedMode: readout.expandedMode,
                onToggleExpanded: { mode in
                    guard interactive else { return }
                    workspace.toggleMessageReadoutExpansion(requestedMode: mode)
                    if workspace.messageReadout?.expanded == true {
                        kickExpandedLoads(item: item, row: row)
                    }
                },
                onClose: {
                    guard interactive else { return }
                    workspace.dismissMessageReadout()
                },
                summaryDisplay: interactive ? summaryDisplay(for: messageId, row: row, item: item) : nil,
                messageDisplay: interactive ? messageDisplay(for: messageId, row: row) : nil,
                callout: popupGeometry.callout,
                obligationKinds: obligationKinds,
                hasDeadline: hasDeadline,
                statusDescriptor: statusDescriptor,
                messageDate: derived.messageDate,
                senderPrefix: derived.senderPrefix,
                senderLabel: derived.senderLabel,
                dateLabel: derived.dateLabel,
                toLabel: derived.toLabel,
                isUserCcd: derived.isUserCcd,
                bodyHeightShortfall: bodyHeightShortfall
            )
            // The placement math (`ProjectsPopupPlacement.geometry`) computes
            // the popup center assuming the popup's RENDERED size equals
            // `layoutSize`. Using `.fixedSize(vertical: true)` defers to the
            // content's natural height, which is often SHORTER than
            // `layoutSize.height` (the expandedSize formula reserves room for
            // worst-case summary/footer content). When that happens,
            // `.position(popupCenter)` centers the smaller actual popup at
            // popupCenter and the popup's edges drift inward from the
            // placement-assumed edges — so the callout notch on a `.top`
            // edge lands at `actualPopup.minY > nodePoint.y` (below the
            // node), and the user loses the "notch points at node" anchor.
            // Forcing the height to `layoutSize.height` keeps the rendered
            // popup geometry in lockstep with the placement math.
            .frame(width: layoutSize.width, height: layoutSize.height, alignment: .top)
            // Pointer residency: the workspace keeps an ephemeral
            // (hover-summoned) readout alive while the pointer is over
            // the popup itself, and dismisses only after the pointer has
            // left both the node and the popup. Attached here — before
            // `.position`, whose wrapper fills the whole viewport — so
            // the hover region is exactly the card's layout frame. The
            // exiting clone shares this chain but reports nothing: it is
            // hit-test-disabled and `interactive` gates the callback.
            .onHover { inside in
                guard interactive else { return }
                workspace.noteMessageReadoutHover(inside: inside)
            }
            .id(readout.messageID)
            .constellationHoverPopupGenie(progress: visualProgress, anchor: genieAnchor)
            .position(popupCenter)
            .zIndex(interactive ? 20 : 19)
            .allowsHitTesting(interactive)

            if interactive {
                popup
                    .onChange(of: readout.expanded) { _, expanded in
                        if expanded {
                            kickExpandedLoads(item: item, row: row)
                        }
                    }
                    .onChange(of: readout.expandedMode) { _, _ in
                        if readout.expanded {
                            kickExpandedLoads(item: item, row: row)
                        }
                    }
                    .task(id: expansionTaskKey(readout)) {
                        if readout.expanded {
                            kickExpandedLoads(item: item, row: row)
                        }
                    }
                    .onChange(of: readout.messageID) { _, _ in
                        relatedSummaryStates = [:]
                        relatedMessageBodyStates = [:]
                    }
            } else {
                popup
            }
        }
    }

    private func syncInitialReadoutProgress() {
        guard let readout = workspace.messageReadout else { return }
        let animationID = UUID()
        presentationAnimationID = animationID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentedReadout = readout
            presentedReadoutProgress = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard presentationAnimationID == animationID,
                  workspace.messageReadout?.messageID == readout.messageID else {
                return
            }
            withAnimation(ConstellationHoverPopupMotion.appear) {
                presentedReadoutProgress = 1
            }
        }
    }

    private func genieVisualProgress(_ progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped
    }

    private func handleReadoutChange(
        from oldValue: ProjectsMessageReadoutState?,
        to newValue: ProjectsMessageReadoutState?
    ) {
        if let newValue {
            exitingReadout = nil
            if presentedReadout?.messageID == newValue.messageID {
                presentedReadout = newValue
                return
            }
            let animationID = UUID()
            presentationAnimationID = animationID
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                presentedReadout = newValue
                presentedReadoutProgress = 0
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard presentationAnimationID == animationID,
                      workspace.messageReadout?.messageID == newValue.messageID else {
                    return
                }
                withAnimation(ConstellationHoverPopupMotion.appear) {
                    presentedReadoutProgress = 1
                }
            }
            return
        }

        guard let oldValue = presentedReadout ?? oldValue else { return }
        let animationID = UUID()
        exitAnimationID = animationID
        presentationAnimationID = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            exitingReadout = oldValue
            exitingReadoutProgress = max(0.02, presentedReadoutProgress)
            presentedReadout = nil
            presentedReadoutProgress = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            withAnimation(ConstellationHoverPopupMotion.appear) {
                exitingReadoutProgress = 0
            }
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard exitAnimationID == animationID,
                  workspace.messageReadout == nil else {
                return
            }
            exitingReadout = nil
        }
    }

    private func expansionTaskKey(_ readout: ProjectsMessageReadoutState) -> String {
        let mode = readout.expandedMode == .message ? "message" : "summary"
        return "\(readout.messageID.uuidString)|\(readout.expanded)|\(mode)"
    }

    private func summaryDisplay(
        for messageId: String,
        row: MessageFilterRow,
        item: AnnotationItem
    ) -> AnnotationSummaryDisplay? {
        guard workspace.messageReadout?.expanded == true,
              workspace.messageReadout?.expandedMode == .summary else {
            return nil
        }
        if regeneratingSummaryMessageIds.contains(messageId) {
            return .loading
        }
        if let cached = summaryByMessageId[messageId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return .ready(cached)
        }
        if let stored = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return .ready(stored)
        }
        if summaryUnavailableMessageIds.contains(messageId) {
            return .unavailable
        }
        switch relatedSummaryStates[messageId] {
        case .loading:
            return .loading
        case .loaded(let text):
            return .ready(text)
        case .failed:
            return .unavailable
        case nil:
            if shouldExpectSummary(row: row) {
                return .loading
            }
            return .unavailable
        }
    }

    private func messageDisplay(for messageId: String, row: MessageFilterRow) -> AnnotationMessageDisplay? {
        guard workspace.messageReadout?.expanded == true,
              workspace.messageReadout?.expandedMode == .message else {
            return nil
        }
        switch relatedMessageBodyStates[messageId] {
        case .loading:
            return .loading
        case .loaded(let text):
            return .ready(text)
        case .failed:
            return .unavailable
        case nil:
            return .loading
        }
    }

    private func shouldExpectSummary(row: MessageFilterRow) -> Bool {
        let hasBody = row.bodyTextPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasBody || row.hasAttachments
    }

    @MainActor
    private func kickExpandedLoads(item: AnnotationItem, row: MessageFilterRow) {
        guard let messageId = item.anchorMessageId else { return }
        if workspace.messageReadout?.expandedMode == .summary {
            kickRelatedSummaryIfNeeded(messageId: messageId, row: row, item: item)
        }
        if workspace.messageReadout?.expandedMode == .message {
            kickRelatedMessageBodyIfNeeded(messageId: messageId, row: row)
        }
    }

    @MainActor
    private func kickRelatedSummaryIfNeeded(messageId: String, row: MessageFilterRow, item: AnnotationItem) {
        if item.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return }
        if summaryByMessageId[messageId]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return }
        if relatedSummaryStates[messageId] == .loading { return }
        if !shouldExpectSummary(row: row) {
            relatedSummaryStates[messageId] = .failed
            return
        }
        relatedSummaryStates[messageId] = .loading
    }

    @MainActor
    private func kickRelatedMessageBodyIfNeeded(messageId: String, row: MessageFilterRow) {
        if relatedMessageBodyStates[messageId] != nil { return }
        relatedMessageBodyStates[messageId] = .loading
        let htmlPath = row.bodyHtmlPath
        let textPath = row.bodyTextPath
        let watchID = workspace.messageReadout?.messageID
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LockReadoutBodyLoader.load(
                    htmlPath: textPath == nil ? htmlPath : nil,
                    textPath: textPath
                )
            }.value
            guard workspace.messageReadout?.messageID == watchID else { return }
            guard case .loaded(let source) = result else {
                relatedMessageBodyStates[messageId] = .failed
                return
            }
            let bodyContent = LockReadoutBodyContent(source: source)
            // Full body, no character cap: the pane's message window
            // scrolls, so a long email is read in place instead of being
            // cut (a cap would also append the banned "..." marker).
            if let text = OriginalMessageText.cleaned(from: bodyContent.plainText) {
                relatedMessageBodyStates[messageId] = .loaded(text)
            } else {
                relatedMessageBodyStates[messageId] = .failed
            }
        }
    }
}
