import SwiftUI

/// Shared hover motion for card surfaces that borrow the Front Page interaction
/// register. Keeping these values in one place prevents the Projects workroom
/// from drifting back to a faster reveal or an immediate hover-exit collapse.
enum FrontPageCardHoverMotion {
    static let expansion = Animation.smooth(duration: 0.45, extraBounce: 0)
    static let highlight = Animation.easeOut(duration: 0.16)
    static let actionClusterReveal = Animation.easeOut(duration: 0.18).delay(0.34)
    static let actionClusterHide = Animation.easeOut(duration: 0.12)
    /// Front Page permanently reserves its action band, so controls need no
    /// wait for layout to settle. Other surfaces retain their expansion timing.
    static let stableActionReveal = Animation.easeOut(duration: 0.12)
    static let exitGracePeriod = Duration.milliseconds(300)
}
