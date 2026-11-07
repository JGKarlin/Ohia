import SwiftUI

/// People-lens locked-overlay pane treatment: an inner-arc leader that
/// hugs the outermost ring's outer edge in the local neighbourhood of
/// the focused satellite, with a radial spoke running from the
/// satellite outward through the arc to the card edge.
///
/// Replaces `AnnotationPopup` + `AnnotationLeader` + `AnnotationWormhole`
/// for the four People-kind annotations. The leader idiom mirrors the
/// meanings-lens leader convention (anchored on the email node, length
/// adapts to the node's screen position so it never crosses the
/// correspondent hub) — but where meanings-lens leaders are a single
/// straight line, the People-lens leader is a *spoke + curved arc*
/// pair: the spoke carries the radial direction, and the arc carries
/// the local curvature of the outer ring it lifts off of.
///
/// Geometry that adapts with the satellite's position:
///   - **Inner arc radius**: fixed at `dialInnerRadius` (outermost ring's
///     outer edge + a small inset) so the arc's curvature always mirrors
///     the local outer-ring edge.
///   - **Inner arc angular span**: derived from the card's projected
///     angular footprint at the arc's radius, so the arc visually
///     frames the card without depending on a hard-coded constant.
///   - **Spoke length**: short when the satellite is on the outermost
///     tier (arc is right next to it); long when the satellite is on an
///     inner tier (spoke crosses intermediate ring bands), then continues
///     outward from the arc until it touches the popup's near edge. It
///     never reaches inward toward the correspondent hub and never draws
///     underneath the popup.
///   - **Card centre**: on the same radial line as the spoke, at a
///     distance from the hub that's projection-aware so the card's
///     near edge sits `cardGap` outside the arc regardless of the
///     satellite's angle (avoids the rectangular card clipping into
///     the arc near the horizontal axis).
///
/// The wedge is `Animatable` over `(anchorAngle, anchorRX)` so a single
/// `withAnimation` on those values produces dial-like motion around the
/// outer ring. `leaderProgress` is animatable too: `0` retracts the
/// leader into the satellite node, `1` draws it out to the popup edge.
/// SwiftUI re-invokes `body` on interpolated copies of the struct each
/// frame, the Canvas re-draws at intermediate values, and the card's
/// `.position` follows the same interpolation so the card slides with
/// the wedge rather than crossfading.
/// `PreferenceKey` used to surface the rendered AnnotationPopup
/// height back to the surrounding `PeopleDialWedge`. The wedge anchors
/// the card by its near edge, so the radial placement formula needs
/// the live height (the popup grows on Space / Shift-Space) — the
/// preference value travels up the view tree each time the card
/// re-lays out and the wedge stores it in `measuredCardHeight`.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 240
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PeopleDialWedge: View, Animatable {
    let hubCenter: CGPoint
    /// Animatable azimuth of the satellite the wedge is currently pointing
    /// at (radians, SwiftUI y-down convention). Declared `var` because
    /// `animatableData` mutates it during a transition.
    var anchorAngle: CGFloat
    /// Animatable screen-space distance from `hubCenter` to the satellite.
    /// Drives the spoke's length: short for the outermost ring (the arc
    /// itself sits just outside it), long for the innermost ring.
    var anchorRX: CGFloat
    /// Animatable draw fraction of the full satellite → arc → popup-edge
    /// leader. The host drives this to make Tab selection read as a line
    /// growing outward from the selected node, then retracting into that
    /// node before the next selected node grows its own leader.
    var leaderProgress: CGFloat
    /// Fixed screen-space distance from `hubCenter` to the inner arc.
    /// Used as a fallback when `ringPolyline` is empty (projection
    /// degenerate, or hub has no rings yet). Computed by the host as
    /// `max(satelliteDistance) + PeopleDialWedge.dialInset` so the
    /// fallback arc is always just outside the outermost ring at the
    /// current camera pose.
    let dialInnerRadius: CGFloat
    /// Screen-space polyline tracing the outermost ring's projected
    /// outline at the current camera pose. Provided by the host via
    /// `peopleRingPolyline()` — a 3D parametric circle sampled at
    /// `PeopleDialGeometry.ringPolylineSampleCount` points around the
    /// ring, each point projected through the live camera + view size.
    /// When non-empty, the inner arc traces this polyline instead of a
    /// flat circle, so a camera tilted away from the ring plane (the
    /// typical Saturn portrait) renders the arc as the same flattened
    /// ellipse the Metal renderer drew the ring as. Empty → fall back
    /// to a circular arc at `dialInnerRadius`.
    let ringPolyline: [CGPoint]
    /// Per-kind accent for the inner-arc rule, spoke, and tick marks.
    /// Resolved by the host through `AnnotationKind.peopleChipAccent(
    /// lockAccent:)` so the wedge accent matches the chip strip and the
    /// underlying ring band.
    let accent: Color
    /// The annotation whose content the card renders. The host gates the
    /// whole view on `active != nil`, so this parameter is non-optional
    /// at the body level.
    let item: AnnotationItem
    /// `true` when the host's `annotationStates` reports an expanded
    /// state for `item.id` (Space or Shift-Space already toggled it
    /// open). Passes straight through to `AnnotationPopup`.
    let expanded: Bool
    /// Whether the expanded pane currently shows the LLM summary or the
    /// original message body. Reflects what Space (`.summary`) vs
    /// Shift-Space (`.message`) requested. `AnnotationPopup` reads this
    /// only when `expanded` is `true`.
    let expandedMode: AnnotationExpandedContentMode
    /// Invoked when the user clicks the card header chevron. The mode
    /// argument carries the popup's current Shift state (`.message` when
    /// the user shift-clicked, `.summary` otherwise) so the host can
    /// route to `toggleExpandedAnnotation(item, requestedMode:)` and
    /// kick the right lazy generator.
    let onToggleExpanded: (AnnotationExpandedContentMode) -> Void
    /// Invoked when the user dismisses the popup (close button or
    /// out-of-popup interaction handled upstream). The host normally
    /// just closes the annotation state for the id.
    let onClose: () -> Void
    let summaryDisplay: AnnotationSummaryDisplay?
    /// Optional lazy body override. Used when Shift-Space asks a
    /// related-message pane to show the original message text instead
    /// of its generated summary. Routed through the host's existing
    /// `messageDisplay(for:)` helper so the People-lens dial shares
    /// the same lazy-body pipeline the meanings-lens annotations use.
    let messageDisplay: AnnotationMessageDisplay?
    /// Attachments for the same original-message preview, surfaced as
    /// external-open links below the body text.
    let messageAttachments: [AnnotationMessageAttachmentLink]
    /// Safe rectangle the card must stay inside (the locked overlay's
    /// scene minus the top toolbar). The card's centre is clamped to
    /// this rectangle so satellites at extreme angles don't push the
    /// card off-screen or under the menu bar.
    let sceneBounds: CGRect
    /// Live screen-space anchor of the satellite the wedge is
    /// currently pointing at. Sourced from the host's per-frame
    /// projection of `item.anchorWorld` so the spoke always lands on
    /// the visible node — never on a stale `(anchorAngle, anchorRX)`
    /// reconstruction whose polar floor (`max(1, hypot)`) collapses
    /// to `hubCenter` when the satellite briefly projects on top of
    /// the hub. `nil` falls back to the polar reconstruction so the
    /// wedge keeps animating during transitions where the @State
    /// polar values drive the visual.
    let liveSatelliteAnchor: CGPoint?

    /// Reports whether the pointer is currently over the card body (the
    /// positioned `AnnotationPopup`), not the scene-spanning wedge Canvas.
    /// The host's ring-selection deselect arbiter treats "over the card" as
    /// anchored so the user can move from the satellite onto the card to read
    /// or act without losing the selection. Scoped here — on the `.position`-ed
    /// popup, whose frame is the card's actual `cardWidth` × measured height —
    /// because attaching `.onHover` to the whole wedge would track the
    /// flexible, scene-sized Canvas frame and report `true` everywhere.
    var onCardHoverChanged: (Bool) -> Void = { _ in }

    /// Inset between the outermost ring's screen extent and the inner
    /// arc. Static so the host can compute the spoke-fully-retracted
    /// radius (= `dialInnerRadius`) without duplicating the constant.
    /// Small value so the inner-arc accent visually HUGS the outer
    /// ring's outer edge.
    static let dialInset: CGFloat = 6

    /// Card width and approximate height — the body is sized with
    /// `.fixedSize(vertical: true)` so the *actual* height grows with
    /// the summary text, but the approximate height is enough for
    /// radial placement and scene-bounds clamping. Both are constants
    /// rather than parameters so the wedge can stay self-contained;
    /// the host doesn't need to know about card dimensions.
    private let cardWidth: CGFloat = 320
    private let approxCardHeight: CGFloat = 240
    /// Gap between the inner arc and the card's projected inner edge.
    /// Small value so the card hugs the outermost ring on the Saturn
    /// side; growth on expand happens entirely on the far edge.
    private let cardGap: CGFloat = 8

    /// Live measurement of the rendered card's height, supplied by a
    /// `PreferenceKey` set inside the AnnotationPopup's frame. Starts at
    /// `approxCardHeight` so the first layout pass produces a sensible
    /// position; SwiftUI replaces it with the actual rendered height on
    /// the next pass. Drives the card's radial placement so the card's
    /// near edge stays at a fixed distance from the hub — when the
    /// popup expands (summary or original message), the height grows,
    /// and the card centre slides outward, away from Saturn.
    @State private var measuredCardHeight: CGFloat = 240

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(anchorAngle, anchorRX), leaderProgress) }
        set {
            anchorAngle = newValue.first.first
            anchorRX = newValue.first.second
            leaderProgress = newValue.second
        }
    }

    var body: some View {
        // Prefer the host-supplied live screen projection of the
        // satellite when available — it tracks the actual rendered
        // node every frame. Fall back to the @State polar reconstruction
        // only when no live anchor is available (e.g., briefly during
        // the contract/sweep/extend transition phases where the host
        // intentionally drives the visual through the animatable
        // (anchorAngle, anchorRX) pair).
        let polarSatellite = CGPoint(
            x: hubCenter.x + anchorRX * cos(anchorAngle),
            y: hubCenter.y + anchorRX * sin(anchorAngle)
        )
        let satellite = liveSatelliteAnchor ?? polarSatellite

        // Half-diagonal of the card. Drives the radial offset between
        // the projected ring and the card centre. `halfH` uses the live
        // measured height (refreshed via `CardHeightKey` whenever the
        // AnnotationPopup expands/collapses) so the card's near edge
        // stays anchored at `effectiveRingRadius + cardGap` while the
        // far edge moves outward with each expand step — Saturn-side
        // stays put, the card grows away from it. `halfDiagonal` is
        // C∞ in `anchorAngle`, so the angular sweep stays cusp-free.
        let halfW = cardWidth / 2
        let halfH = max(measuredCardHeight, 80) / 2
        let halfDiagonal = (halfW * halfW + halfH * halfH).squareRoot()

        // Use the projected ring's max screen-distance from the hub
        // when the polyline is available, so the card is placed outside
        // the *entire* ellipse (not just its closest point at the
        // current angle). Falls back to the scalar `dialInnerRadius`
        // when the polyline is empty (projection degenerate or hub has
        // no rings yet).
        let polylineMaxRadius = PeopleDialGeometry.polylineMaxRadius(
            polyline: ringPolyline,
            hub: hubCenter
        )
        let effectiveRingRadius = polylineMaxRadius > 0 ? polylineMaxRadius : dialInnerRadius
        let cardCenterDistance = effectiveRingRadius + cardGap + halfDiagonal

        // Arc angular span = the angle the half-diagonal subtends at the
        // hub from the card's centre distance. Constant in `anchorAngle`,
        // so the arc has the same angular width at every dial position.
        // The *visual* arc length changes when the projected ring is
        // non-uniform — which is exactly what we want for a flattened
        // ellipse: a fixed-angle slice of a tilted ring has more screen
        // length on the long axis, less on the short axis.
        let arcHalfAngle = atan(halfDiagonal / max(cardCenterDistance, 1))
        let arcSpan = max(2 * arcHalfAngle, 0.001)

        // Card centre on the spoke's radial line, beyond the inner arc.
        let rawCardCenterX = hubCenter.x + cardCenterDistance * cos(anchorAngle)
        let rawCardCenterY = hubCenter.y + cardCenterDistance * sin(anchorAngle)

        // Top inset accounts for the locked-overlay toolbar / chip
        // strip that overlays the scene; without it an expanded popup
        // (Space → summary, or Shift-Space → original email body)
        // would slide under the chrome and crop at the top. Bottom and
        // horizontal insets are smaller — the only chrome in those
        // directions is the scene-edge gutter. When the card is taller
        // than the available band (`minY > maxY`), `min(maxY,
        // rawCenterY)` folds first so the *top* of the card stays
        // visible — losing the bottom is preferable to losing the
        // header, since the chevron lives at the top.
        let topInset: CGFloat = 84
        let bottomInset: CGFloat = 24
        let sideInset: CGFloat = 12
        let minX = sceneBounds.minX + halfW + sideInset
        let maxX = sceneBounds.maxX - halfW - sideInset
        let minY = sceneBounds.minY + halfH + topInset
        let maxY = sceneBounds.maxY - halfH - bottomInset
        let clampedX = max(minX, min(maxX, rawCardCenterX))
        // For y: if the safe band is degenerate (minY > maxY) the
        // standard `max(minY, min(maxY, y))` would land on `maxY`,
        // hiding the card header under the toolbar. Pin to `minY` in
        // that case so the top stays visible.
        let clampedY: CGFloat = {
            if minY > maxY { return minY }
            return max(minY, min(maxY, rawCardCenterY))
        }()
        let cardCenter = CGPoint(x: clampedX, y: clampedY)
        let cardHeight = max(measuredCardHeight, 80)
        let cardRect = CGRect(
            x: cardCenter.x - halfW,
            y: cardCenter.y - cardHeight / 2,
            width: cardWidth,
            height: cardHeight
        )

        // Effective dial angle: the angle from the hub to the *clamped*
        // card centre. In the unclamped case this equals `anchorAngle`
        // exactly (the card sits on the radial). When the card has been
        // pushed off the radial by the scene-bounds clamp, the arc and
        // spoke-endpoint rotate with the card so they remain visually
        // connected — the spoke leaves the satellite, lands on the arc
        // at a slight angle, and the arc still frames the card.
        let dxClamped = cardCenter.x - hubCenter.x
        let dyClamped = cardCenter.y - hubCenter.y
        let dialAngle = (dxClamped * dxClamped + dyClamped * dyClamped) > 1
            ? atan2(dyClamped, dxClamped)
            : anchorAngle
        let clampedLeaderProgress = min(max(leaderProgress, 0), 1)

        // Resolve a "point on the projected ring at screen angle α from
        // the hub" once, falling back to the constant-radius circle
        // when the polyline isn't usable. Used for the arc samples,
        // the spoke endpoint, and the tick endpoints — they all need
        // to land on the same underlying curve.
        let polyline = ringPolyline
        let dialInnerFallback = dialInnerRadius
        let hub = hubCenter
        let ringPoint: (CGFloat) -> CGPoint = { a in
            if let p = PeopleDialGeometry.interpolatePolylinePoint(
                atAngle: a,
                polyline: polyline,
                hub: hub
            ) {
                return p
            }
            return CGPoint(
                x: hub.x + dialInnerFallback * cos(a),
                y: hub.y + dialInnerFallback * sin(a)
            )
        }

        ZStack {
            Canvas { gc, _ in
                let a0 = dialAngle - arcSpan / 2
                let a1 = dialAngle + arcSpan / 2
                let steps = 40

                // Inner-arc samples ride the projected ring's outline,
                // so the arc literally traces the same ellipse the
                // Metal renderer drew for the ring at the current
                // camera tilt — flat circle head-on, flattened ellipse
                // from above, rotated ellipse with camera roll.
                var inner = Path()
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let a = a0 + (a1 - a0) * t
                    let pt = ringPoint(a)
                    if i == 0 { inner.move(to: pt) } else { inner.addLine(to: pt) }
                }
                gc.stroke(inner, with: .color(accent.opacity(0.95)),
                          style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

                // Spoke matches the DesignSandbox idiom: a straight line
                // from the email node (`satellite`) outward through the
                // inner arc at `dialAngle`, stopping at the popup's near
                // edge. `leaderProgress` reveals this polyline from the
                // node outward; reversing it retracts the leader back into
                // the selected node before the next Tab destination grows.
                let spokeEnd = ringPoint(dialAngle)
                let minimumPaneDistance = hypot(
                    spokeEnd.x - hubCenter.x,
                    spokeEnd.y - hubCenter.y
                ) + 0.5
                let paneEdge = PeopleDialGeometry.radialRectEdgePoint(
                    origin: hubCenter,
                    angle: dialAngle,
                    rect: cardRect,
                    minimumDistance: minimumPaneDistance
                )
                let spokeLength = hypot(spokeEnd.x - satellite.x, spokeEnd.y - satellite.y)
                let extensionLength = paneEdge.map {
                    hypot($0.x - spokeEnd.x, $0.y - spokeEnd.y)
                } ?? 0
                let totalLeaderLength = spokeLength + extensionLength
                let visibleLeaderLength = totalLeaderLength * clampedLeaderProgress

                if totalLeaderLength > 0.5, visibleLeaderLength > 0.5 {
                    let interpolate: (CGPoint, CGPoint, CGFloat) -> CGPoint = { from, to, t in
                        CGPoint(
                            x: from.x + (to.x - from.x) * t,
                            y: from.y + (to.y - from.y) * t
                        )
                    }
                    var leader = Path()
                    leader.move(to: satellite)

                    if visibleLeaderLength <= spokeLength || paneEdge == nil {
                        let t = spokeLength > 0 ? min(visibleLeaderLength / spokeLength, 1) : 1
                        leader.addLine(to: interpolate(satellite, spokeEnd, t))
                    } else {
                        if spokeLength > 0.5 {
                            leader.addLine(to: spokeEnd)
                        }
                        if let paneEdge {
                            let remaining = visibleLeaderLength - spokeLength
                            let t = extensionLength > 0 ? min(remaining / extensionLength, 1) : 1
                            leader.addLine(to: interpolate(spokeEnd, paneEdge, t))
                        }
                    }

                    gc.stroke(leader, with: .color(accent.opacity(0.80)),
                              style: StrokeStyle(lineWidth: 1.2, lineCap: .butt, lineJoin: .round))
                }

                // Tick marks straddle each arc endpoint along the
                // local radial direction. With a polyline-driven arc
                // the "radial" at angle α is the line from the hub to
                // the projected ring point at α — not the (cos α, sin α)
                // unit vector at a fixed radius — so we derive the
                // tick direction from the endpoint's actual screen
                // vector.
                for a in [a0, a1] {
                    let endPoint = ringPoint(a)
                    let dx = endPoint.x - hubCenter.x
                    let dy = endPoint.y - hubCenter.y
                    let len = max(hypot(dx, dy), 1)
                    let ux = dx / len
                    let uy = dy / len
                    let inP = CGPoint(x: endPoint.x - 4 * ux, y: endPoint.y - 4 * uy)
                    let outP = CGPoint(x: endPoint.x + 4 * ux, y: endPoint.y + 4 * uy)
                    var tick = Path()
                    tick.move(to: inP)
                    tick.addLine(to: outP)
                    gc.stroke(tick, with: .color(accent.opacity(0.7)), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)

            AnnotationPopup(
                item: item,
                expanded: expanded,
                expandedMode: expandedMode,
                onToggleExpanded: onToggleExpanded,
                onClose: onClose,
                summaryDisplay: summaryDisplay,
                messageDisplay: messageDisplay,
                messageAttachments: messageAttachments,
                transparentChrome: true,
                heightLimit: max(160, sceneBounds.height - 108)
            )
            .frame(width: cardWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: CardHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(CardHeightKey.self) { newHeight in
                if abs(newHeight - measuredCardHeight) > 0.5 {
                    measuredCardHeight = newHeight
                }
            }
            // Tracks the card's own `cardWidth` × measured-height frame (applied
            // above), not the scene-spanning Canvas — so the host learns when
            // the pointer is genuinely over the card.
            .onHover { onCardHoverChanged($0) }
            .position(cardCenter)
        }
    }
}
