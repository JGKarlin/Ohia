import Foundation

/// Six normalized, bipolar controls describing the visible shape of an email
/// draft. Every value is clamped to `0...1`; the UI presents the endpoints in
/// plain language and the Composer renders them as ten discrete positions.
public struct StyleAxisValues: Codable, Sendable, Equatable {
    /// 0 = concise, 1 = detailed.
    public let detail: Double
    /// 0 = casual/direct, 1 = formal/polite.
    public let formality: Double
    /// 0 = relaxed, 1 = urgent.
    public let urgency: Double
    /// 0 = plain, 1 = technical/dense.
    public let technicality: Double
    /// 0 = reserved, 1 = warm/emotional.
    public let warmth: Double
    /// 0 = humorous, 1 = serious.
    public let seriousness: Double

    public init(
        detail: Double,
        formality: Double,
        urgency: Double,
        technicality: Double,
        warmth: Double,
        seriousness: Double
    ) {
        self.detail = Self.clamp(detail)
        self.formality = Self.clamp(formality)
        self.urgency = Self.clamp(urgency)
        self.technicality = Self.clamp(technicality)
        self.warmth = Self.clamp(warmth)
        self.seriousness = Self.clamp(seriousness)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            detail: try container.decode(Double.self, forKey: .detail),
            formality: try container.decode(Double.self, forKey: .formality),
            urgency: try container.decode(Double.self, forKey: .urgency),
            technicality: try container.decode(Double.self, forKey: .technicality),
            warmth: try container.decode(Double.self, forKey: .warmth),
            seriousness: try container.decode(Double.self, forKey: .seriousness)
        )
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeJSON(_ json: String?) -> StyleAxisValues? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StyleAxisValues.self, from: data)
    }

    /// Stable decile bucket used only to let repeated explicit controls form
    /// their own style stratum. Nearby slider positions deliberately coalesce.
    public var quantizedSignature: String {
        components
            .map { String(Int(($0 * 10).rounded())) }
            .joined(separator: "-")
    }

    /// Similarity in `0...1`, with 1 meaning identical controls. Root mean
    /// square distance keeps a large move on one axis meaningful without
    /// allowing six small moves to grow without bound.
    public func similarity(to other: StyleAxisValues) -> Double {
        let differences = zip(components, other.components).map { lhs, rhs in
            let delta = lhs - rhs
            return delta * delta
        }
        let rms = (differences.reduce(0, +) / Double(differences.count)).squareRoot()
        return max(0, 1 - rms)
    }

    public static func mean(_ values: [StyleAxisValues]) -> StyleAxisValues? {
        guard !values.isEmpty else { return nil }
        let count = Double(values.count)
        let sums = values.reduce(into: [Double](repeating: 0, count: 6)) { result, value in
            for (index, component) in value.components.enumerated() {
                result[index] += component
            }
        }
        return StyleAxisValues(
            detail: sums[0] / count,
            formality: sums[1] / count,
            urgency: sums[2] / count,
            technicality: sums[3] / count,
            warmth: sums[4] / count,
            seriousness: sums[5] / count
        )
    }

    public func differs(from other: StyleAxisValues, tolerance: Double = 0.001) -> Bool {
        zip(components, other.components).contains { abs($0 - $1) > tolerance }
    }

    public var components: [Double] {
        [detail, formality, urgency, technicality, warmth, seriousness]
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }
}
