import Foundation

public struct ComposerDecisionResearchOverlayIdentity: Codable, Sendable, Equatable {
    public let inputFingerprint: String
    public let decisionDigestFingerprint: String
    public let researchContractVersion: Int

    public init(
        inputFingerprint: String,
        decisionDigestFingerprint: String,
        researchContractVersion: Int
    ) {
        self.inputFingerprint = inputFingerprint
        self.decisionDigestFingerprint = decisionDigestFingerprint
        self.researchContractVersion = researchContractVersion
    }
}

public enum ComposerDecisionResearchOverlayOutcome: String, Codable, Sendable, Equatable {
    case populated
    case empty
    case failed
}

public struct ComposerDecisionResearchOverlay: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let currentResearchContractVersion = 1

    public let schemaVersion: Int
    public let identity: ComposerDecisionResearchOverlayIdentity
    public let outcome: ComposerDecisionResearchOverlayOutcome
    public let sources: [ComposerSource]
    public let completedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        identity: ComposerDecisionResearchOverlayIdentity,
        outcome: ComposerDecisionResearchOverlayOutcome,
        sources: [ComposerSource],
        completedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.outcome = outcome
        self.sources = outcome == .populated ? sources : []
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case identity
        case outcome
        case sources
        case completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            identity: try container.decode(
                ComposerDecisionResearchOverlayIdentity.self,
                forKey: .identity
            ),
            outcome: try container.decode(
                ComposerDecisionResearchOverlayOutcome.self,
                forKey: .outcome
            ),
            sources: try container.decode([ComposerSource].self, forKey: .sources),
            completedAt: try container.decode(Date.self, forKey: .completedAt)
        )
    }

    public func matches(_ expectedIdentity: ComposerDecisionResearchOverlayIdentity) -> Bool {
        identity == expectedIdentity
    }

    public func isReusable(
        for expectedIdentity: ComposerDecisionResearchOverlayIdentity
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion && matches(expectedIdentity)
    }

    public var suppressesAutomaticRetry: Bool {
        outcome == .empty || outcome == .failed
    }
}

public enum ComposerDecisionResearchOverlayCoding {
    public static func decode(_ json: String?) -> ComposerDecisionResearchOverlay? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let overlay = try? decoder.decode(ComposerDecisionResearchOverlay.self, from: data),
              overlay.schemaVersion == ComposerDecisionResearchOverlay.currentSchemaVersion else {
            return nil
        }
        return overlay
    }

    public static func encode(_ overlay: ComposerDecisionResearchOverlay?) -> String? {
        guard let overlay else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(overlay) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
