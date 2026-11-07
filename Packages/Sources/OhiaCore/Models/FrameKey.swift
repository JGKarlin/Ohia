import Foundation

/// Opaque string key identifying a Constellation layout frame. A struct
/// wrapper (instead of `typealias String`) keeps the named constants scoped
/// to `FrameKey` rather than polluting `String`'s global namespace — e.g.
/// preventing `String.type` from clashing with a `.type` callsite on any
/// `String`-typed parameter. Still openable via string literal so forks
/// can add custom frames without editing OhiaCore.
public struct FrameKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

// Explicit single-value Codable: encode as a bare JSON string so wire-format
// stays independent of Swift's auto-synthesis (which for a one-field struct
// would produce `{"rawValue": "..."}`). Keeps `.frameBurst` job payloads
// compact and debuggable.
extension FrameKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension FrameKey {
    static let defaultFrame: FrameKey = "default"
    static let meaning: FrameKey      = defaultFrame
    static let people: FrameKey       = "people"
    static let timeline: FrameKey     = "timeline"
    static let projects: FrameKey     = "projects"
    static let frontPage: FrameKey    = "frontPage"

    static let visibleSpatialFrames: [FrameKey] = [
        .frontPage,
        .meaning,
        .people,
        .timeline,
        .projects
    ]

    /// Identity. Retained as a stable seam so call sites read uniformly and
    /// forks can canonicalize custom frame keys onto a built-in lens here.
    var spatialLens: FrameKey { self }
}

/// Per-source weights applied when merging edges for the force kernel.
/// 0 disables the source; 1 is the canonical weight. All values
/// must be finite; weights are clamped to `[0, 2]` in the builder.
public struct FrameForceWeights: Sendable, Equatable {
    public var cosine: Float
    public var thread: Float
    public var correspondent: Float
    public var temporal: Float
    public var action: Float
    public var classification: Float
    public var arc: Float

    public init(
        cosine: Float = 1,
        thread: Float = 0,
        correspondent: Float = 0,
        temporal: Float = 0,
        action: Float = 0,
        classification: Float = 0,
        arc: Float = 0
    ) {
        self.cosine = cosine
        self.thread = thread
        self.correspondent = correspondent
        self.temporal = temporal
        self.action = action
        self.classification = classification
        self.arc = arc
    }

    /// Canonical per-frame defaults. `.meaning` / `.default` is cosine-only
    /// (matches Phase 1). Visible non-Metal workspace lenses such as Timeline
    /// and Projects keep neutral fallback weights.
    ///
    /// Every non-`.meaning` frame holds its dominant force at 1.0. Secondaries
    /// sit around the People profile (one structural ally at ~0.25, background
    /// at ~0.15) so cluster identity reads clearly without isolating clusters
    /// from each other.
    public static func forFrame(_ frame: FrameKey) -> FrameForceWeights {
        switch frame.spatialLens {
        case .people:
            // Reference profile — one secondary (thread) at 0.25, background
            // at 0.15. Unchanged.
            return FrameForceWeights(cosine: 0.15, thread: 0.25, correspondent: 1.0, arc: 0.15)
        // `.timeline` no longer participates in the force-directed layout
        // pipeline — the lens is rendered by the NLE workspace in
        // `Ohia/ConstellationMode/Timeline/`, not by the Metal scene.
        // Persisted frame-burst payloads tagged `.timeline` decode through
        // the `default` branch (cosine-only), which is a benign placeholder
        // since no scene consumes them anymore.
        case .projects:
            // The Projects lens is a SwiftUI/Canvas correspondence
            // workspace, not a force-directed arc layout. Returning the
            // neutral fallback keeps old frame-burst payloads harmless
            // without reviving the retired Metal Projects scene.
            return FrameForceWeights(cosine: 1.0)
        case .frontPage:
            // The Front Page lens is a SwiftUI reading workspace, not a
            // force-directed layout. Neutral fallback, defensive like
            // `.projects` — no Metal scene consumes it.
            return FrameForceWeights(cosine: 1.0)
        case .meaning:
            // Cosine dominates so messages cluster by semantic similarity
            // first. Arc (project / team / topic) and Purpose + Domain
            // classification affinity are kept as background secondaries so
            // the resulting meaning clusters still respect both structures
            // rather than smearing into one pure-similarity
            // cloud. Thread / correspondent / temporal / action are zero —
            // the meaning lens is intentionally identity-free.
            return FrameForceWeights(cosine: 1.0, classification: 0.15, arc: 0.35)
        case .defaultFrame:
            return FrameForceWeights(cosine: 1.0)
        default:
            return FrameForceWeights(cosine: 1.0)
        }
    }
}
