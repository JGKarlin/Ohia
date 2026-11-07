import Foundation

/// Static language choice shown during onboarding.
public struct ContentLanguageOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// The sole onboarding catalog, in the local model's supported order.
    public static let supported: [ContentLanguageOption] =
        LocalModelLanguageSupport.supportedLanguageIDs.map { id in
            ContentLanguageOption(
                id: id,
                displayName: LocalModelLanguageSupport.displayName(for: id) ?? id
            )
        }

    public static func supportedID(for identifier: String) -> String? {
        LocalModelLanguageSupport.canonicalLanguageID(for: identifier)
    }

    public static func option(for identifier: String) -> ContentLanguageOption? {
        guard let supportedID = supportedID(for: identifier) else { return nil }
        return supported.first { $0.id == supportedID }
    }
}
