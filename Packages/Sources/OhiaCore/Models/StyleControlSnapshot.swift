import Foundation

/// Why the effective style controls were used for one generated body.
public enum StyleControlIntent: String, Codable, Sendable {
    /// The user did not change the sliders; the register's calculated defaults
    /// shaped the body.
    case inheritedDefault
    /// The user deliberately moved one or more sliders away from the defaults.
    case explicitOverride
    /// The user deliberately returned a previously adjusted body to the
    /// register's defaults.
    case explicitResetToDefault
}

/// Which explicit user surface produced a style-control decision. Learning
/// treats every explicit source equally; the distinction exists so prompt and
/// revision provenance remain truthful.
public enum StyleControlDecisionSource: String, Codable, Sendable {
    case sliders
    case revisionInstruction
    case slidersAndRevisionInstruction

    public var includesRevisionInstruction: Bool {
        self != .sliders
    }
}

/// Immutable generation-time provenance for the Composer's style controls.
///
/// Both the calculated register defaults and the effective values are stored,
/// so an older revision remains truthful after the register is re-distilled.
/// `decisionID` is also the compare-and-swap token used to avoid consuming a
/// newer slider move when generation completes in another process.
public struct StyleControlSnapshot: Codable, Sendable, Equatable {
    public let decisionID: UUID
    public let registerID: UUID?
    public let registerRevision: Int?
    public let baseAxes: StyleAxisValues?
    public let effectiveAxes: StyleAxisValues?
    public let intent: StyleControlIntent
    public let decisionSource: StyleControlDecisionSource?
    public let decidedAt: Date

    public init(
        decisionID: UUID,
        registerID: UUID?,
        registerRevision: Int?,
        baseAxes: StyleAxisValues?,
        effectiveAxes: StyleAxisValues?,
        intent: StyleControlIntent,
        decisionSource: StyleControlDecisionSource? = nil,
        decidedAt: Date = .now
    ) {
        self.decisionID = decisionID
        self.registerID = registerID
        self.registerRevision = registerRevision
        self.baseAxes = baseAxes
        self.effectiveAxes = effectiveAxes
        self.intent = intent
        self.decisionSource = decisionSource
        self.decidedAt = decidedAt
    }

    public static func inherited(
        decisionID: UUID = UUID(),
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?,
        decidedAt: Date = .now
    ) -> StyleControlSnapshot {
        StyleControlSnapshot(
            decisionID: decisionID,
            registerID: registerID,
            registerRevision: registerRevision,
            baseAxes: defaults,
            effectiveAxes: defaults,
            intent: .inheritedDefault,
            decisionSource: nil,
            decidedAt: decidedAt
        )
    }

    public static func explicitOverride(
        decisionID: UUID = UUID(),
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?,
        effectiveAxes: StyleAxisValues,
        decidedAt: Date = .now
    ) -> StyleControlSnapshot {
        explicitOverride(
            decisionID: decisionID,
            registerID: registerID,
            registerRevision: registerRevision,
            defaults: defaults,
            effectiveAxes: effectiveAxes,
            decisionSource: .sliders,
            decidedAt: decidedAt
        )
    }

    public static func explicitOverride(
        decisionID: UUID = UUID(),
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?,
        effectiveAxes: StyleAxisValues,
        decisionSource: StyleControlDecisionSource,
        decidedAt: Date = .now
    ) -> StyleControlSnapshot {
        StyleControlSnapshot(
            decisionID: decisionID,
            registerID: registerID,
            registerRevision: registerRevision,
            baseAxes: defaults,
            effectiveAxes: effectiveAxes,
            intent: .explicitOverride,
            decisionSource: decisionSource,
            decidedAt: decidedAt
        )
    }

    public static func explicitReset(
        decisionID: UUID = UUID(),
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?,
        decidedAt: Date = .now
    ) -> StyleControlSnapshot {
        explicitReset(
            decisionID: decisionID,
            registerID: registerID,
            registerRevision: registerRevision,
            defaults: defaults,
            decisionSource: .sliders,
            decidedAt: decidedAt
        )
    }

    public static func explicitReset(
        decisionID: UUID = UUID(),
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?,
        decisionSource: StyleControlDecisionSource,
        decidedAt: Date = .now
    ) -> StyleControlSnapshot {
        StyleControlSnapshot(
            decisionID: decisionID,
            registerID: registerID,
            registerRevision: registerRevision,
            baseAxes: defaults,
            effectiveAxes: defaults,
            intent: .explicitResetToDefault,
            decisionSource: decisionSource,
            decidedAt: decidedAt
        )
    }

    /// The exact effective controls captured for this generation decision.
    /// Always emitting the snapshot keeps prompt behavior aligned with its
    /// immutable provenance even if the underlying register is re-distilled
    /// before generation or a later revision.
    public var promptAxisOverrides: StyleAxisValues? {
        effectiveAxes
    }

    /// Explicit accepted choices feed style discovery; untouched defaults do
    /// not. A reset is meaningful evidence for the base profile.
    public var preferenceAxes: StyleAxisValues? {
        switch intent {
        case .inheritedDefault:
            nil
        case .explicitOverride, .explicitResetToDefault:
            effectiveAxes
        }
    }

    public var isExplicitPreference: Bool {
        intent != .inheritedDefault
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeJSON(_ json: String?) -> StyleControlSnapshot? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StyleControlSnapshot.self, from: data)
    }
}
