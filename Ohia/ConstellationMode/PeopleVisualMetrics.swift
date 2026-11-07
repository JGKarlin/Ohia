import Foundation

nonisolated enum PeopleVisualMetrics {
    static let directStrokeWidthPixels: Float = 1.0
    static let sharedStrokeMinPixels: Float = 1.6
    static let sharedStrokeMaxPixels: Float = 3.4

    /// Missing or zero-span chronology should still produce a stable,
    /// readable orbit. Keep it closer than the midpoint so undated People
    /// islands do not look artificially stale.
    private static let fallbackAgeFraction: Float = 0.35

    static func eventDate(for row: MessageFilterRow) -> Date? {
        row.receivedAt
    }

    static func dateRange(rows: [MessageFilterRow]) -> ClosedRange<Date>? {
        let dates = rows.compactMap { eventDate(for: $0) }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
        return minDate...maxDate
    }

    static func temporalRadius(
        date: Date?,
        dateRange: ClosedRange<Date>?,
        minRadius: Float,
        maxRadius: Float
    ) -> Float {
        let lower = min(minRadius, maxRadius)
        let upper = max(minRadius, maxRadius)
        guard upper > lower else { return lower }
        guard let date, let dateRange else {
            return interpolateRadius(ageFraction: fallbackAgeFraction, minRadius: lower, maxRadius: upper)
        }

        let span = dateRange.upperBound.timeIntervalSince(dateRange.lowerBound)
        guard span > 0.001, span.isFinite else {
            return interpolateRadius(ageFraction: fallbackAgeFraction, minRadius: lower, maxRadius: upper)
        }

        let secondsFromNewest = dateRange.upperBound.timeIntervalSince(date)
        let ageFraction = Float(max(0, min(1, secondsFromNewest / span)))
        return interpolateRadius(ageFraction: ageFraction, minRadius: lower, maxRadius: upper)
    }

    static func messageOrbitalRadius(
        date: Date?,
        dateRange: ClosedRange<Date>?,
        centerRadius: Float,
        messageRadius: Float,
        minSurfaceGap: Float = 0.006,
        maxSurfaceGap: Float
    ) -> Float {
        let base = max(0, centerRadius) + max(0, messageRadius)
        let minimum = base + max(0, minSurfaceGap)
        let maximum = base + max(minSurfaceGap, maxSurfaceGap)
        return temporalRadius(
            date: date,
            dateRange: dateRange,
            minRadius: minimum,
            maxRadius: maximum
        )
    }

    static func sharedStrokeWidthPixels(
        isShared: Bool,
        sharedParticipantCount: Int = 0,
        sharedStrength: Float? = nil
    ) -> Float {
        guard isShared else { return directStrokeWidthPixels }

        let normalized: Float
        if let sharedStrength, sharedStrength.isFinite {
            normalized = max(0, min(1, sharedStrength))
        } else {
            normalized = max(0, min(1, Float(max(1, sharedParticipantCount) - 1) / 4))
        }
        let eased = sqrt(normalized)
        return sharedStrokeMinPixels + (sharedStrokeMaxPixels - sharedStrokeMinPixels) * eased
    }

    private static func interpolateRadius(
        ageFraction: Float,
        minRadius: Float,
        maxRadius: Float
    ) -> Float {
        minRadius + (maxRadius - minRadius) * max(0, min(1, ageFraction))
    }
}
