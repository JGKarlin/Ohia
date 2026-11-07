import Foundation
import OhiaCore

/// A type with its classification score.
public struct TypeScore: Sendable {
    public let type: MessageType
    public let score: Double

    public init(type: MessageType, score: Double) {
        self.type = type
        self.score = score
    }
}

/// Result of classifying a message into a UI-facing type.
public struct MessageClassification: Sendable {
    public let type: MessageType
    public let confidence: Double
    public let alternatives: [TypeScore]
    public let draftEligible: Bool
    public let isUserOverride: Bool

    public init(
        type: MessageType,
        confidence: Double,
        alternatives: [TypeScore] = [],
        draftEligible: Bool,
        isUserOverride: Bool = false
    ) {
        self.type = type
        self.confidence = confidence
        self.alternatives = alternatives
        self.draftEligible = draftEligible
        self.isUserOverride = isUserOverride
    }
}
