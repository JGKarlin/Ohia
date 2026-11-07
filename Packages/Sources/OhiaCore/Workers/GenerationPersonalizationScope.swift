import Foundation

/// Selects whether a generation should use the user's LoRA adapter.
/// Personalization is intentionally explicit and reserved for final draft and
/// revision text; summaries, Ask, extraction, translation, and planning use
/// base-model behavior.
public enum GenerationPersonalizationScope: String, Codable, Equatable, Sendable {
    case base
    case personalized
}
