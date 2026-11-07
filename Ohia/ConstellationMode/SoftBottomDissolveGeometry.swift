import SwiftUI

enum SoftBottomDissolveGeometry {
    static let defaultFadeBand: CGFloat = 22
    static let defaultOverflowTolerance: CGFloat = 0.5

    static func roundedHalfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded(.toNearestOrAwayFromZero) / 2
    }

    static func roundedNonnegativeHalfPoint(_ value: CGFloat) -> CGFloat {
        max(0, roundedHalfPoint(value))
    }

    static func fadeFraction(
        height: CGFloat,
        fadeBand: CGFloat = defaultFadeBand
    ) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(0.5, fadeBand / height)
    }

    static func contentOverflows(
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        tolerance: CGFloat = defaultOverflowTolerance
    ) -> Bool {
        contentHeight > visibleHeight + tolerance
    }

    static func hiddenContentBelow(
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        contentMinY: CGFloat
    ) -> CGFloat {
        max(0, contentHeight + contentMinY - visibleHeight)
    }

    static func shouldDissolveBottomEdge(
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        contentMinY: CGFloat,
        tolerance: CGFloat = defaultOverflowTolerance
    ) -> Bool {
        contentOverflows(
            contentHeight: contentHeight,
            visibleHeight: visibleHeight,
            tolerance: tolerance
        ) && hiddenContentBelow(
            contentHeight: contentHeight,
            visibleHeight: visibleHeight,
            contentMinY: contentMinY
        ) > tolerance
    }
}
