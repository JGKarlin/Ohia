import Foundation

/// Per-frame rendering vocabulary. Sibling to `FrameForceWeights`.
///
/// `FrameForceWeights` decides *where* nodes land; `FrameVisualLanguage`
/// decides *how* the scene speaks once they're there — which channels carry
/// meaning in this lens and which recede. Substrate behavior — node
/// identity, hover/lock affordances, search and selection highlights,
/// accessibility cues — is invariant across frames and lives in the
/// renderer, not here.
///
/// The governing rule:
/// > Each frame has one dominant carrier of meaning, one secondary cue, and
/// > one suppressed class of noise. The user should know the active frame
/// > from the scene before reading the toolbar. Suppressed does not mean
/// > hidden; it means demoted until hover, lock, search, or filter
/// > activation, then it punches through.
public struct FrameVisualLanguage: Sendable, Equatable {

    // MARK: - Channels

    /// Modulation applied on top of the account-derived node color.
    ///
    /// The account color (from `AccountColorPalette`) is the node's
    /// identity hue and is preserved across every frame. Frame-specific
    /// signals — triage state, arc identity, classification — live in glyph
    /// rings, halos, strands, motion, and nebulae; they never overwrite
    /// the node's hue. Coloration only adjusts saturation/brightness on
    /// the existing account base.
    public enum Coloration: Sendable, Equatable {
        /// Full account color, no modulation. Today's baseline. Used by
        /// every frame except `.people`.
        case accountColor
        /// Account hue preserved at full saturation for the user's top-N
        /// correspondents; long-tail correspondents desaturate against
        /// the same account base so the colored regions read as the
        /// user's major relationship clusters. Used by `.people`.
        ///
        /// `.accountColorRecencyDesaturated` retired with the Timeline
        /// Metal scene (the NLE workspace surfaces age in the ruler and
        /// chapter strip instead of via per-node saturation).
        case accountColorMajorOnly
    }

    /// Per-node mark treatment. Direction asymmetry lives on the node
    /// itself because both signals must be readable per-point, not just
    /// at cluster scale.
    public enum Glyph: Sendable, Equatable {
        /// Uniform filled dot. Baseline.
        case dot
        /// Filled = received, hollow = sent. Renders the sent/received
        /// duality as a per-node mark. The `.directional` family also
        /// admits "included" variants (filled dashed / hollow dashed)
        /// when the renderer sets `glyphCode` to 2 or 3 via callers like
        /// `PeopleGraphBuilder` — `encode(isSentByUser:)` only encodes
        /// the direct vs. included axis when direction is enough; the
        /// included-tier override happens downstream of this enum.
        case directional

        /// Encode a per-message glyph code for the renderer instance.
        /// Stable wire format read by the Metal star fragment shader
        /// (which branches on `lock.y`):
        ///
        /// - `0` — filled dot (`.dot`; `.directional` received-direct).
        /// - `1` — hollow ring (`.directional` sent-direct).
        /// - `2` — filled dashed (`.directional` received-included; set
        ///         by `PeopleGraphBuilder` per-placement, not from this
        ///         enum's direction-only encoder).
        /// - `3` — hollow dashed (`.directional` sent-included; same).
        public func encode(isSentByUser: Bool) -> UInt8 {
            switch self {
            case .dot:
                return 0
            case .directional:
                return isSentByUser ? 1 : 0
            }
        }
    }

    /// Persistent arc-halo treatment for Metal constellation packets. Arcs
    /// travel across the remaining Metal frames so the user always sees
    /// matter identity at least faintly. The Projects lens now renders its
    /// correspondence workspace outside Metal, so it does not request this
    /// channel.
    public enum ArcHaloPresence: Sendable, Equatable {
        /// No arc halos rendered.
        case off
        /// Faint halos for pinned / high-confidence arcs only, no labels.
        /// Default across non-`.projects` frames.
        case ambient
        /// Full halos plus, when `labelTopClusters > 0`, up to that many
        /// floating cluster labels at centroids — only for clusters above
        /// the size + confidence floor.
        case prominent(nestedAspects: Bool, labelTopClusters: Int)
    }

    /// Strand rendering. Each frame picks the edge kind whose relationships
    /// it wants visible as connection lines — correspondent strands in
    /// `.people` (lines connect senders who share
    /// correspondence with the same person, so tight clusters carry visible
    /// internal links). Distance still reads as the primary affinity signal;
    /// strands are reinforcement, not replacement.
    public enum ThreadStrandPolicy: Sendable, Equatable {
        case off
        /// Strongest edges of the given kind, plus interaction-revealed
        /// chains for hovered / locked / search-matched nodes. Keeps the
        /// dense corpus from going hairball by filtering to one kind at
        /// a time.
        case selective(VectorEdgeKind)
        /// Every edge rendered regardless of kind. Rarely useful; listed
        /// so the renderer has a clear escape hatch.
        case dense
    }

    /// Animation channel for action posture. Motion is expensive
    /// perceptually — restrict it to genuinely current items, not "every
    /// actionable node ever seen."
    public enum ActionMotion: Sendable, Equatable {
        case off
        /// Pulse only nodes that are actionable, unresolved, and recent.
        case currentOnly
        case allActionable
    }

    /// Local-density "breathing" — soft luminance modulation by cosine
    /// neighbor count. Reads as terrain, not activity.
    public enum DensityNebula: Sendable, Equatable {
        case off
        case atmospheric
    }

    /// Chronology rendering. With the Timeline NLE workspace replacing the
    /// Metal scene for that lens, the constellation no longer renders a
    /// `.strata` accent in any spatial-lens packet — every remaining lens
    /// returns `.off`. The case is preserved as a single-case enum so
    /// existing per-frame default tables keep their explicit reading.
    public enum TemporalAccent: Sendable, Equatable {
        case off
    }

    /// Per-frame hover readout idiom. Tags the relationship kind the frame
    /// foregrounds; the hover popup itself no longer renders explanatory
    /// copy from this — the spatial layout carries the meaning.
    public enum HoverFraming: Sendable, Equatable {
        case semanticNeighborhood
        case exchangePath
        case correspondentGroup
        case temporalContext
        case obligationState
        case projectArc
    }

    /// Suppression-as-demotion: which suppressed channels re-acquire on
    /// hover / lock / search-match. Surfaces a node's full context
    /// transiently without forcing the user to switch frames.
    public struct EmergeOnInteract: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Triggered node re-acquires its major-correspondent tint.
        public static let correspondentTint = EmergeOnInteract(rawValue: 1 << 0)
        /// Triggered node emits transient fibres along its thread chain.
        public static let threadStrand      = EmergeOnInteract(rawValue: 1 << 1)
        /// Triggered node emits transient fibres to other nodes sharing
        /// the same arc label hash.
        public static let arcHaloLabel      = EmergeOnInteract(rawValue: 1 << 2)
        /// Triggered node emits transient fibres to its temporal peers.
        public static let temporalContext   = EmergeOnInteract(rawValue: 1 << 3)
    }

    // MARK: - Fields

    public var coloration: Coloration
    public var glyph: Glyph
    public var arcHalos: ArcHaloPresence
    public var threadStrands: ThreadStrandPolicy
    public var actionMotion: ActionMotion
    public var densityNebula: DensityNebula
    public var temporalAccent: TemporalAccent
    public var hoverFraming: HoverFraming
    public var emergeOnInteract: EmergeOnInteract

    public init(
        coloration: Coloration = .accountColor,
        glyph: Glyph = .dot,
        arcHalos: ArcHaloPresence = .ambient,
        threadStrands: ThreadStrandPolicy = .off,
        actionMotion: ActionMotion = .off,
        densityNebula: DensityNebula = .off,
        temporalAccent: TemporalAccent = .off,
        hoverFraming: HoverFraming = .semanticNeighborhood,
        emergeOnInteract: EmergeOnInteract = []
    ) {
        self.coloration = coloration
        self.glyph = glyph
        self.arcHalos = arcHalos
        self.threadStrands = threadStrands
        self.actionMotion = actionMotion
        self.densityNebula = densityNebula
        self.temporalAccent = temporalAccent
        self.hoverFraming = hoverFraming
        self.emergeOnInteract = emergeOnInteract
    }

    // MARK: - Per-frame defaults

    /// Canonical reading vocabulary per visible spatial frame. Legacy frame
    /// keys resolve through `FrameKey.spatialLens` so persisted payloads
    /// keep yielding a coherent visual treatment.
    public static func forFrame(_ frame: FrameKey) -> FrameVisualLanguage {
        switch frame.spatialLens {
        case .people:
            return FrameVisualLanguage(
                coloration: .accountColorMajorOnly,
                glyph: .directional,
                arcHalos: .ambient,
                threadStrands: .selective(.correspondent),
                hoverFraming: .correspondentGroup,
                emergeOnInteract: [.threadStrand, .arcHaloLabel, .temporalContext]
            )
        case .timeline:
            // `.timeline` no longer mounts the Metal scene — the lens
            // renders the NLE workspace in `Ohia/ConstellationMode/Timeline/`
            // and never reaches this dispatch from a live renderer path.
            // The explicit arm here is defensive: any future tweak to the
            // `default` arm can't accidentally collide with a legacy
            // frame-burst payload tagged `.timeline`, and the
            // `visibleFramesAreDistinct` test stays unambiguously satisfied.
            return FrameVisualLanguage(
                coloration: .accountColor,
                glyph: .dot,
                arcHalos: .ambient,
                hoverFraming: .temporalContext
            )
        case .projects:
            // `.projects` no longer mounts the Metal constellation scene.
            // The live lens renders the correspondence workspace in
            // `Ohia/ConstellationMode/Projects/`, where row timing,
            // obligations, revived threads, and cross-project links are
            // explicit UI rather than top-cluster arc halos. Keep a distinct
            // neutral record here only for legacy callers/tests that still
            // ask for a frame visual language.
            return FrameVisualLanguage(
                coloration: .accountColor,
                glyph: .dot,
                arcHalos: .off,
                threadStrands: .off,
                hoverFraming: .projectArc
            )
        case .frontPage:
            // `.frontPage` never mounts the Metal scene — it renders the
            // newspaper reading workspace in `Ohia/ConstellationMode/FrontPage/`.
            // Keep a distinct neutral record here only for legacy callers /
            // tests that still ask for a frame visual language.
            return FrameVisualLanguage(
                coloration: .accountColor,
                glyph: .dot,
                arcHalos: .off,
                threadStrands: .off,
                hoverFraming: .temporalContext
            )
        case .defaultFrame:
            return FrameVisualLanguage(
                coloration: .accountColor,
                glyph: .dot,
                arcHalos: .ambient,
                densityNebula: .atmospheric,
                hoverFraming: .semanticNeighborhood,
                emergeOnInteract: [.correspondentTint, .arcHaloLabel, .temporalContext]
            )
        default:
            return FrameVisualLanguage()
        }
    }
}
