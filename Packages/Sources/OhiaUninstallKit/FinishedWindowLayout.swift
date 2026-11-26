import CoreGraphics

/// Where the uninstaller's window may be once it shows the outcome: it grows
/// to fit the report, but never taller than 620 points or its screen allows,
/// and never past the screen's visible edges.
public enum FinishedWindowLayout {
    /// The window's height in every other state, and the outcome's least.
    public static let minimumHeight: CGFloat = 420
    /// The tallest the whole window gets, title bar included.
    public static let maximumWindowHeight: CGFloat = 620
    /// Room kept free between the window and the edges of the visible area.
    public static let screenMargin: CGFloat = 20

    /// The most the window's content may be: the window, which is the content
    /// plus the title-bar inset (its frame height minus its content layout
    /// height), stays within 620 points and within the visible height less
    /// the margin. Never below the minimum, so the content's limits can't
    /// contradict each other on a very small screen.
    public static func contentHeightCap(visibleHeight: CGFloat, titleBarInset: CGFloat) -> CGFloat {
        let window = min(maximumWindowHeight, visibleHeight - screenMargin)
        return max(minimumHeight, window - max(0, titleBarInset))
    }

    /// `frame` moved, never resized, to lie inside `visible`: raised when its
    /// bottom is below the visible area, then lowered when its top is above
    /// it, so the title bar stays reachable if it can't fit at all.
    public static func keptInside(_ frame: CGRect, visible: CGRect) -> CGRect {
        var moved = frame
        if moved.minY < visible.minY {
            moved.origin.y = visible.minY
        }
        if moved.maxY > visible.maxY {
            moved.origin.y = visible.maxY - moved.height
        }
        if moved.minX < visible.minX {
            moved.origin.x = visible.minX
        }
        if moved.maxX > visible.maxX {
            moved.origin.x = max(visible.minX, visible.maxX - moved.width)
        }
        return moved
    }
}
