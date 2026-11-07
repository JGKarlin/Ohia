import Foundation

/// Pure helpers that translate Timeline workspace state to/from
/// `@AppStorage`-friendly representations.
///
/// - `aiLayers`: persisted as a comma-separated string (`timelineAIDisplayedLayers`).
/// - `defaultZoomTier`: persisted as the tier's raw `Int`; the read path
///   maps the tier back to a representative `pixelsPerDay`.
///
/// Both surfaces are pure, free-function-style, and `internal` so the
/// `OhiaTests` target can drive them directly. Extracting them out of
/// `TimelineWorkspaceView` was the M3 fix from the adversarial review —
/// in-view `private` helpers were untestable.
enum TimelinePersistence {

    // MARK: - AI layers (CSV)

    static func encodeAILayers(
        _ set: Set<TimelineLayoutSnapshot.AIAnnotation.Kind>
    ) -> String {
        // Deterministic order so AppStorage churn stays minimal across
        // semantically-equal sets.
        TimelineLayoutSnapshot.AIAnnotation.Kind.allCases
            .filter { set.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func decodeAILayers(
        _ csv: String
    ) -> Set<TimelineLayoutSnapshot.AIAnnotation.Kind> {
        let tokens = csv
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var set: Set<TimelineLayoutSnapshot.AIAnnotation.Kind> = []
        for token in tokens where token.isEmpty == false {
            if let kind = TimelineLayoutSnapshot.AIAnnotation.Kind(rawValue: token) {
                set.insert(kind)
            }
        }
        return set
    }

    // MARK: - Default zoom tier (Int rawValue ↔ pixelsPerDay)

    /// Representative `pixelsPerDay` for each tier — chosen so the inverse
    /// `TimelineZoomTier.tier(forPixelsPerDay:)` lookup recovers the same
    /// tier (each value sits inside its tier's interval).
    static func defaultPixelsPerDay(forTier tier: TimelineZoomTier) -> Double {
        switch tier {
        case .yearPlus:     return 0.04
        case .months:       return 1.0
        case .weeks:        return 12.0
        case .daysAndHours: return 80.0
        }
    }

    /// Round-trip: tier → ppd → tier. Stable by construction (each
    /// representative ppd sits inside its tier's interval). Exposed for
    /// the unit test that protects future boundary tweaks.
    static func roundTripTier(_ tier: TimelineZoomTier) -> TimelineZoomTier {
        TimelineZoomTier.tier(forPixelsPerDay: defaultPixelsPerDay(forTier: tier))
    }
}
