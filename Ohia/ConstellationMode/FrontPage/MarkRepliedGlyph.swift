import SwiftUI

/// The "mark replied" action glyph: the reply arrow with a small check badge
/// at the bottom-trailing corner. SF Symbols has no reply+check symbol, so this
/// composites `arrowshape.turn.up.left.fill` (the same glyph the "Needs reply"
/// status uses) with a `checkmark.circle.fill` badge — keeping the reply
/// association while the badge flips the meaning from "compose a reply" to
/// "reply handled", so it no longer mimics a mail client's compose-reply button.
///
/// `haloColor` should match the surface directly behind the glyph so the badge
/// reads as a separate token instead of merging into the arrow's fill. Sizes
/// scale off `glyphSize` so the badge stays proportional at both the small card
/// cluster (12pt) and the larger control-column disc (18pt).
struct MarkRepliedGlyph: View {
    var glyphSize: CGFloat
    var tint: Color
    var badgeColor: Color
    var haloColor: Color

    var body: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(tint)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: glyphSize * 0.5, weight: .bold))
                    .foregroundStyle(badgeColor)
                    .background(Circle().fill(haloColor).padding(-0.5))
                    .offset(x: glyphSize * 0.16, y: glyphSize * 0.13)
            }
            .accessibilityHidden(true)
    }
}
