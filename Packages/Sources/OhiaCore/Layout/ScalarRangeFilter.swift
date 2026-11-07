import Foundation

/// Returns true if a scalar dimension passes the given range filter.
///
/// Honors §14 graceful deconstruction: when the filter range is the
/// inert default `0.0...1.0`, any value (including nil) passes. When
/// the range has been narrowed, a nil value (no analyzer output for
/// this dimension) fails the filter — we don't pretend an unset
/// signal exists.
public enum ScalarRangeFilter {
    public static func passes(
        _ value: Double?,
        against range: ClosedRange<Double>
    ) -> Bool {
        guard range != 0.0...1.0 else { return true }
        guard let v = value, range.contains(v) else { return false }
        return true
    }
}
