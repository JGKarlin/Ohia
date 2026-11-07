import Foundation
import OhiaCore

/// Helper that intersects a `VectorFilter` (from `state.filter`) with a
/// time window. Used by both Timeline's data fetch and the Ask-scope
/// computation in `ConstellationModeView`'s `activeFilterSpec()` so the
/// two paths can't drift.
public enum TimelineFilterIntersection {

    /// Returns a `VectorFilter` whose `timeRange` is the intersection of
    /// the existing filter's window with `viewportRange ∩ bracketedRange`.
    /// If the filter already has a tighter window, that wins.
    public static func intersect(
        filter: VectorFilter,
        viewportRange: ClosedRange<Date>,
        bracketedRange: ClosedRange<Date>?
    ) -> VectorFilter {
        var out = filter
        let combined = intersected(viewportRange, bracketedRange)
        if let existing = out.timeRange {
            out.timeRange = intersected(existing, combined)
        } else {
            out.timeRange = combined
        }
        return out
    }

    public static func intersected(
        _ lhs: ClosedRange<Date>,
        _ rhs: ClosedRange<Date>?
    ) -> ClosedRange<Date> {
        guard let rhs else { return lhs }
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        if lower > upper {
            // Empty intersection: the two ranges don't overlap. Collapse
            // to a zero-width range at `lhs.lowerBound` so the resulting
            // window is well-formed AND sits inside `lhs` (preserving the
            // invariant "intersected result is a subset of lhs"). Callers
            // see "no messages match" rather than silently jumping outside
            // the user's selected window — which would happen if we used
            // `upper...upper` since `upper` can be earlier than
            // `lhs.lowerBound` for disjoint pairs.
            return lhs.lowerBound ... lhs.lowerBound
        }
        return lower ... upper
    }
}
