import Foundation

/// The model exhausted its bounded content checks. Repeating the same
/// request automatically cannot repair this outcome; Composer keeps the
/// existing body and pending request available for an explicit retry.
public enum DraftContentValidationError: Error, LocalizedError, Sendable, Equatable {
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let reason): reason
        }
    }
}
