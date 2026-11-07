import Foundation
import SwiftData
import OhiaCore

/// Canonical flat categories projected once for drafting, style,
/// memory, and semantic-affinity consumers.
///
/// Purpose and active user categories are the only taxonomy keys. Deterministic
/// automated/bulk traffic facts remain a structural correspondent-memory gate.
public struct DraftingMemoryFacets: Sendable, Equatable {
    public let draftingAffinityKeys: [String]
    public let styleKeys: [String]
    public let semanticAffinityKeys: [String]
    public let memoryKeys: [String]
    public let excludesCorrespondentMemory: Bool

    public init(
        draftingAffinityKeys: [String],
        styleKeys: [String],
        semanticAffinityKeys: [String],
        memoryKeys: [String],
        excludesCorrespondentMemory: Bool
    ) {
        self.draftingAffinityKeys = draftingAffinityKeys
        self.styleKeys = styleKeys
        self.semanticAffinityKeys = semanticAffinityKeys
        self.memoryKeys = memoryKeys
        self.excludesCorrespondentMemory = excludesCorrespondentMemory
    }

    public static func displayName(for key: String) -> String {
        if let raw = key.removingPrefix("purpose."),
           let purpose = MailPurpose(rawValue: raw) {
            return purpose.displayLabel
        }
        if let raw = key.removingPrefix("custom.") {
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return key
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Pure projection used by both persisted-message and value-type callers.
/// Persisted callers first cross the strict `MailClassificationJSON.decode`
/// boundary; independently valid custom keys remain available when decoding
/// the built-in classification fails.
public func draftingMemoryFacets<S: Sequence>(
    classification: MailClassification?,
    customCategoryKeys: S,
    isNonHumanTraffic: Bool = false
) -> DraftingMemoryFacets where S.Element == String {
    let customKeys = CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys)

    let purposeKey: String? = classification?.purpose.map {
        "purpose.\($0.rawValue)"
    }
    let specificPurposeKey: String? = classification?.purpose.flatMap { purpose -> String? in
        switch purpose {
        case .correspondence, .other:
            nil
        default:
            "purpose.\(purpose.rawValue)"
        }
    }
    let specificPurposeKeys = specificPurposeKey.map { [$0] } ?? []
    let resolvedPurposeKeys = purposeKey.map { [$0] } ?? []

    return DraftingMemoryFacets(
        draftingAffinityKeys: specificPurposeKeys + customKeys,
        styleKeys: specificPurposeKeys,
        semanticAffinityKeys: specificPurposeKeys,
        memoryKeys: resolvedPurposeKeys + customKeys,
        excludesCorrespondentMemory: isNonHumanTraffic
    )
}

/// Persisted-message overload. This is the only classification-storage read
/// path used by training and inference consumers in OhiaML.
@MainActor
public func draftingMemoryFacets(
    for message: Message,
    knownCustomCategoryKeys: Set<String>
) -> DraftingMemoryFacets {
    let storedCustomKeys = CustomCategoryKeysJSON.decode(
        message.analysis?.customCategoryKeysJSON
    )
    return draftingMemoryFacets(
        classification: MailClassificationJSON.decode(message.analysis?.mailClassificationJSON),
        customCategoryKeys: storedCustomKeys.filter(knownCustomCategoryKeys.contains),
        isNonHumanTraffic: DeterministicMessageTrafficFacts.isNonHumanTraffic(message: message)
    )
}

/// Convenience for one-off persisted-message callers. Batch callers should
/// fetch the catalog once and use the explicit snapshot overload above.
@MainActor
public func draftingMemoryFacets(for message: Message) -> DraftingMemoryFacets {
    let knownCustomKeys = message.modelContext.map {
        CustomMailCategoryCatalog.allKeys(in: $0)
    } ?? []
    return draftingMemoryFacets(
        for: message,
        knownCustomCategoryKeys: knownCustomKeys
    )
}
