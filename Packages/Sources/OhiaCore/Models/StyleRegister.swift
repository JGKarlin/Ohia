import Foundation
import SwiftData

/// Lifecycle constants for `StyleRegister` rows.
public enum StyleRegisterLifecycle {
    /// Measured sent emails a language needs before styles are discovered in
    /// it at all. Below this the six-axis distribution is too thin to split.
    public static let minimumCorpusPairs = 12
    /// A discovered style must hold at least this many sent emails…
    public static let minimumStyleMembers = 8
    /// …and at least this fraction of the language's measured emails, so a
    /// large corpus never surfaces a handful of outliers as a voice.
    public static let minimumStyleShare = 0.05
    /// Upper bound on distinct styles discovered in one language.
    public static let maximumStylesPerLanguage = 6
    /// Mean simplified-silhouette a split into two or more styles must reach;
    /// below it the user writes in one voice in that language.
    public static let minimumSilhouette = 0.25
    /// Minimum root-mean-square distance (0–1 axes) between two discovered
    /// style centroids. Closer clusters are one voice.
    public static let minimumSeparation = 0.12
    /// A re-clustering keeps a style's identity when the new centroid lies
    /// within this RMS distance of the stored one.
    public static let identityRadius = 0.10
    /// A different number of styles replaces the previous split only when its
    /// silhouette beats the previous count's by this margin, so one new email
    /// never makes styles appear and vanish.
    public static let splitHysteresis = 0.05
    /// Centroid movement (RMS) after which a style's description is renewed.
    public static let redescribeCentroidShift = 0.05
    /// Fraction of membership that must change before the description is
    /// renewed (damping — statistics update every run, prose only on drift).
    public static let redescribeMembershipDelta = 0.2
    /// Accepted sends using a saved custom style's unchanged sliders before
    /// that style counts as learned.
    public static let savedStylePromotionSends = 3
    /// Cap on stored covered-correspondent addresses per style,
    /// most-frequent first.
    public static let maxStoredCorrespondents = 500
}

/// One writing style: either a cluster Ohia discovered in the six measured
/// style axes of the user's sent email in one language, or a slider profile
/// the user saved. Styles span every account — the voice belongs to the
/// author, not the mailbox — and are scoped by output language. Uses:
///
/// 1. **Draft-time controls** — the style's six axes are the writer's
///    presentation defaults. The adapter learned the author's voice at every
///    measured setting, so selecting a style asks for that voice at that
///    setting; no style description is ever put in the prompt.
/// 2. **Composer UI** — the Style pane's pulldown lists the language's
///    styles, with training extent and provenance for the selected one.
@Model
public final class StyleRegister {
    public var id: UUID

    /// Stable identity key: `style|<language>|<uuid>` for discovered styles,
    /// `saved|<language>|<uuid>` for saved custom styles.
    public var registerKey: String

    /// Short display name. Discovered styles are named from the two axes
    /// that most distinguish them from the author's other writing in the
    /// language ("Brief casual"); preserved verbatim once `userRenamed`.
    public var name: String

    /// One or two sentences describing the style's habits, shown as hover
    /// help. Never part of a prompt.
    public var summary: String

    /// JSON `StyleAxisValues`: the centroid of the member emails' measured
    /// axes (discovered) or the saved slider values (saved custom). Optional
    /// so a store written before the six axes existed stays loadable.
    public var styleAxesJSON: String?

    /// JSON `[String]` — normalized recipient addresses covered, capped at
    /// `StyleRegisterLifecycle.maxStoredCorrespondents`, most-frequent first.
    public var correspondentsJSON: String

    /// JSON `[String]` — the language the style belongs to (one entry).
    public var languagesJSON: String

    /// Member sent emails at the last discovery pass.
    public var exemplarCount: Int

    /// Member training pairs currently folded into the promoted adapter.
    public var trainedPairCount: Int

    /// Accepted sends that used a saved style's unchanged sliders.
    public var preferenceEventCount: Int?
    public var latestPreferenceAt: Date?

    /// Bumped whenever the name, summary, or axes materially change.
    public var revision: Int

    /// Retired styles (no longer supported by the corpus) keep their row for
    /// draft provenance but are excluded from resolution and the pulldown.
    public var isActive: Bool

    /// True when the style began as a slider profile the user saved.
    public var isUserSaved: Bool?

    /// Whether accepted sends have promoted a saved style to learned status.
    /// Discovered styles are learned by definition, so nil resolves to true.
    public var isLearned: Bool?

    /// A user deletion is a soft retirement. The row remains to explain
    /// historical draft revisions and stops discovery from recreating a style
    /// at the same centroid.
    public var userDeletedAt: Date?

    /// Set when the user renames the style; discovery never overwrites
    /// `name` afterwards.
    public var userRenamed: Bool

    public var lastDistilledAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        registerKey: String,
        name: String,
        summary: String,
        styleAxes: StyleAxisValues? = nil,
        correspondents: [String] = [],
        languages: [String] = [],
        exemplarCount: Int = 0,
        trainedPairCount: Int = 0,
        preferenceEventCount: Int = 0,
        latestPreferenceAt: Date? = nil,
        revision: Int = 1,
        isActive: Bool = true,
        isUserSaved: Bool? = nil,
        isLearned: Bool? = nil,
        userDeletedAt: Date? = nil,
        userRenamed: Bool = false,
        lastDistilledAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.registerKey = registerKey
        self.name = name
        self.summary = summary
        self.styleAxesJSON = styleAxes?.jsonString
        self.correspondentsJSON = StyleRegister.encode(correspondents)
        self.languagesJSON = StyleRegister.encode(languages)
        self.exemplarCount = exemplarCount
        self.trainedPairCount = trainedPairCount
        self.preferenceEventCount = preferenceEventCount
        self.latestPreferenceAt = latestPreferenceAt
        self.revision = revision
        self.isActive = isActive
        self.isUserSaved = isUserSaved
        self.isLearned = isLearned
        self.userDeletedAt = userDeletedAt
        self.userRenamed = userRenamed
        self.lastDistilledAt = lastDistilledAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - JSON accessors

    public var styleAxes: StyleAxisValues? {
        get { StyleAxisValues.decodeJSON(styleAxesJSON) }
        set { styleAxesJSON = newValue?.jsonString }
    }

    public var correspondents: [String] {
        get { StyleRegister.decode(correspondentsJSON) }
        set { correspondentsJSON = StyleRegister.encode(newValue) }
    }

    public var languages: [String] {
        get { StyleRegister.decode(languagesJSON) }
        set { languagesJSON = StyleRegister.encode(newValue) }
    }

    public var resolvedPreferenceEventCount: Int {
        preferenceEventCount ?? 0
    }

    /// Discovered styles are learned. A newly saved slider profile remains
    /// custom until repeated accepted sends promote it in place.
    public var resolvedIsLearned: Bool {
        isLearned ?? true
    }

    public var isUserSavedStyle: Bool {
        isUserSaved == true
    }

    public var isSavedCustomStyle: Bool {
        isUserSavedStyle && !resolvedIsLearned
    }

    public var isUserDeletedStyle: Bool {
        userDeletedAt != nil
    }

    /// User-managed styles exist independently of corpus membership:
    /// discovery never retires them.
    public var isProtectedFromAutomaticRetirement: Bool {
        isUserSavedStyle && !isUserDeletedStyle
    }

    // MARK: - Private helpers

    private static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}
