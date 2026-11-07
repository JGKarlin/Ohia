import Foundation
import SwiftData

/// Lifecycle of a user-created mail category.
///
/// - `collecting`: the user is still tagging example messages; the category
///   participates in tagging UI and topic filtering but does not steer the
///   LLM categorizer yet.
/// - `active`: the activation threshold was reached and the local model has
///   written a definition; the category now participates in ingestion-time
///   categorization as an independent user-authored overlay.
public enum CustomMailCategoryStatus: String, Codable, Sendable {
    case collecting
    case active
}

/// A user-defined mail category. Custom categories are SwiftData rows whose
/// stable `key` (always `custom.<slug>`) is stored independently in
/// `MessageAnalysis.customCategoryKeysJSON`.
@Model
public final class CustomMailCategory {
    /// Stable canonical key, e.g. `custom.surf_trips`. Never changes after
    /// creation; this is the token persisted in message classification storage and in
    /// `VectorFilter.customCategoryKeys`.
    @Attribute(.unique) public var key: String
    /// User-typed display name shown in chips, pickers, and menus.
    public var displayName: String
    /// Raw `CustomMailCategoryStatus`. Stored as a string column so
    /// `#Predicate` translation never has to see a custom Codable enum.
    public var statusRaw: String
    /// LLM-generated definition with boundaries and disambiguation rules
    /// against the fixed taxonomy. Nil while `collecting`.
    public var definition: String?
    /// JSON-encoded `[String]` of example `Message.id` UUID strings the user
    /// tagged while the category was collecting.
    public var exampleMessageIDsJSON: String
    public var createdAt: Date
    public var activatedAt: Date?

    public init(displayName: String, key: String) {
        self.key = key
        self.displayName = displayName
        self.statusRaw = CustomMailCategoryStatus.collecting.rawValue
        self.definition = nil
        self.exampleMessageIDsJSON = "[]"
        self.createdAt = Date()
        self.activatedAt = nil
    }

    public var status: CustomMailCategoryStatus {
        get { CustomMailCategoryStatus(rawValue: statusRaw) ?? .collecting }
        set { statusRaw = newValue.rawValue }
    }

    /// Number of tagged examples needed before the definition-generation job
    /// runs and the category activates. Paired with
    /// `CustomMailCategoryCatalog.activationMinimumDistinctSenders`, which
    /// gates on the examples' correspondent diversity independently of this
    /// count; tune either in one place only.
    public static let activationExampleThreshold = 5

    public var exampleMessageIDs: [UUID] {
        get {
            guard let data = exampleMessageIDsJSON.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return raw.compactMap(UUID.init(uuidString:))
        }
        set {
            let raw = newValue.map(\.uuidString)
            if let data = try? JSONEncoder().encode(raw),
               let json = String(data: data, encoding: .utf8) {
                exampleMessageIDsJSON = json
            } else {
                exampleMessageIDsJSON = "[]"
            }
        }
    }

    public var exampleCount: Int {
        exampleMessageIDs.count
    }

    public var hasReachedActivationThreshold: Bool {
        exampleCount >= Self.activationExampleThreshold
    }

    /// Adds an example message id if not already present. Returns true when
    /// the set changed.
    @discardableResult
    public func addExample(_ messageID: UUID) -> Bool {
        var ids = exampleMessageIDs
        guard !ids.contains(messageID) else { return false }
        ids.append(messageID)
        exampleMessageIDs = ids
        return true
    }

    /// Removes an example message id. Returns true when the set changed.
    @discardableResult
    public func removeExample(_ messageID: UUID) -> Bool {
        var ids = exampleMessageIDs
        guard let index = ids.firstIndex(of: messageID) else { return false }
        ids.remove(at: index)
        exampleMessageIDs = ids
        return true
    }

    // MARK: - Key derivation

    /// Derives a stable canonical key for a user-typed display name.
    ///
    /// The slug keeps Unicode alphanumerics (so Japanese / CJK names retain
    /// their identity instead of degenerating to underscores), lowercases,
    /// and maps every other scalar to `_`. The mandatory `custom.` prefix
    /// keeps the namespace separate from built-in classification facets,
    /// and the slug alphabet excludes punctuation and whitespace so the key
    /// remains stable in JSON storage. Collisions with existing custom keys resolve by
    /// appending `_2`, `_3`, and so on.
    public static func canonicalKey(
        forDisplayName displayName: String,
        existingKeys: Set<String>
    ) -> String {
        let base = CustomCategoryKeysJSON.keyPrefix + slug(forDisplayName: displayName)
        guard existingKeys.contains(base) else { return base }
        var suffix = 2
        while existingKeys.contains("\(base)_\(suffix)") {
            suffix += 1
        }
        return "\(base)_\(suffix)"
    }

    public static func slug(forDisplayName displayName: String) -> String {
        var output = ""
        var lastWasSeparator = true
        for scalar in displayName.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                output.append("_")
                lastWasSeparator = true
            }
        }
        while output.hasSuffix("_") {
            output.removeLast()
        }
        return output.isEmpty ? "category" : output
    }
}

// MARK: - Catalog snapshot

/// Sendable snapshot of one custom category, safe to hand to detached
/// loaders, prompt builders, and UI surfaces.
public struct CustomMailCategoryDescriptor: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let key: String
    public let displayName: String
    public let status: CustomMailCategoryStatus
    public let definition: String?
    public let exampleCount: Int
    public let createdAt: Date
    /// Whether the tagged examples span at least
    /// `CustomMailCategoryCatalog.activationMinimumDistinctSenders` distinct
    /// correspondent addresses. Defaults to `true` for callers that only
    /// construct a descriptor for display/testing and don't resolve message
    /// senders; the real value is computed by
    /// `CustomMailCategoryCatalog.descriptors(in:)`.
    public let hasSenderDiversity: Bool

    public var id: String { key }

    public var isActive: Bool { status == .active }

    public init(
        key: String,
        displayName: String,
        status: CustomMailCategoryStatus,
        definition: String?,
        exampleCount: Int,
        createdAt: Date,
        hasSenderDiversity: Bool = true
    ) {
        self.key = key
        self.displayName = displayName
        self.status = status
        self.definition = definition
        self.exampleCount = exampleCount
        self.createdAt = createdAt
        self.hasSenderDiversity = hasSenderDiversity
    }

    public init(_ category: CustomMailCategory, hasSenderDiversity: Bool) {
        self.init(
            key: category.key,
            displayName: category.displayName,
            status: category.status,
            definition: category.definition,
            exampleCount: category.exampleCount,
            createdAt: category.createdAt,
            hasSenderDiversity: hasSenderDiversity
        )
    }

    // Manual Decodable so a JSON payload written before `hasSenderDiversity`
    // existed (e.g. the mirrored UserDefaults catalog from a prior build)
    // decodes instead of throwing `keyNotFound` — synthesized Decodable
    // would require the key even though the memberwise initializer treats
    // it as optional.
    private enum CodingKeys: String, CodingKey {
        case key, displayName, status, definition, exampleCount, createdAt, hasSenderDiversity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        displayName = try container.decode(String.self, forKey: .displayName)
        status = try container.decode(CustomMailCategoryStatus.self, forKey: .status)
        definition = try container.decodeIfPresent(String.self, forKey: .definition)
        exampleCount = try container.decode(Int.self, forKey: .exampleCount)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        hasSenderDiversity = try container.decodeIfPresent(Bool.self, forKey: .hasSenderDiversity) ?? true
    }
}

/// Catalog lookups over the `CustomMailCategory` table. This is the API the
/// dreaming pipeline (`AccountMemoryRefreshWorker`), the summarization
/// context assemblers, and the UI stores share so "which custom categories
/// exist right now" has exactly one definition.
public enum CustomMailCategoryCatalog {
    /// Every custom category, collecting and active, ordered by creation
    /// time so UI lists are stable.
    ///
    /// Isolation follows the passed `context` — see `allKeys(in:)`.
    public static func descriptors(in context: ModelContext) -> [CustomMailCategoryDescriptor] {
        let rows = (try? context.fetch(FetchDescriptor<CustomMailCategory>())) ?? []
        return rows
            .map { row in
                // Diversity only ever affects the `.collecting` menu label
                // (`CustomCategoryStore.menuLabel` short-circuits to the
                // plain display name for every other status), so skip the
                // per-example Message lookups for already-active rows.
                guard row.status == .collecting else {
                    return CustomMailCategoryDescriptor(row, hasSenderDiversity: true)
                }
                return CustomMailCategoryDescriptor(
                    row,
                    hasSenderDiversity: hasSenderDiversity(
                        exampleMessageIDs: row.exampleMessageIDs,
                        context: context
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.key < rhs.key
            }
    }

    /// Minimum number of distinct correspondent addresses that must appear
    /// among a collecting category's tagged examples before it may
    /// activate. A category whose examples are all from the same sender
    /// risks a definition that bakes in that sender's incidental traits
    /// (sender-specific phrasing, one recurring subject template) instead of
    /// the category's actual boundary. This is independent of account —
    /// one connected account with two different correspondents satisfies it.
    public static let activationMinimumDistinctSenders = 2

    /// Resolves tagged example message ids to their normalized `fromAddress`
    /// values. Looked up one id at a time (mirroring
    /// `CustomCategoryDefinitionWorker.examples`) since example sets are
    /// always small (`activationExampleThreshold` + a handful more).
    public static func distinctSenderAddresses(
        exampleMessageIDs: [UUID],
        context: ModelContext
    ) -> Set<String> {
        var senders: Set<String> = []
        for messageID in exampleMessageIDs {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            guard let message = try? context.fetch(descriptor).first else { continue }
            let normalized = message.fromAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalized.isEmpty == false else { continue }
            senders.insert(normalized)
        }
        return senders
    }

    public static func hasSenderDiversity(
        exampleMessageIDs: [UUID],
        context: ModelContext
    ) -> Bool {
        distinctSenderAddresses(exampleMessageIDs: exampleMessageIDs, context: context).count
            >= activationMinimumDistinctSenders
    }

    /// Whether a collecting category has both enough tagged examples and
    /// enough correspondent diversity among them to activate. The single
    /// gate both `CustomCategoryStore` (enqueue decision) and
    /// `CustomCategoryDefinitionWorker` (actual activation) must agree on —
    /// see call sites for why duplicating this check would be unsafe.
    public static func isEligibleForActivation(
        _ category: CustomMailCategory,
        context: ModelContext
    ) -> Bool {
        category.hasReachedActivationThreshold
            && hasSenderDiversity(exampleMessageIDs: category.exampleMessageIDs, context: context)
    }

    /// Only activated categories — the ones that steer the LLM categorizer
    /// and participate in classification memories.
    public static func activeDescriptors(in context: ModelContext) -> [CustomMailCategoryDescriptor] {
        descriptors(in: context).filter(\.isActive)
    }

    /// Every known custom key (collecting + active). Rows whose JSON storage
    /// still carries the key of a *removed* category are filtered against
    /// this set at decode seams, so removal takes effect everywhere without
    /// a store-walking backfill.
    ///
    /// Isolation follows the passed `context`: callable from the main actor
    /// over the main context, or from a detached lens gather over its own
    /// background context.
    public static func allKeys(in context: ModelContext) -> Set<String> {
        Set(descriptors(in: context).map(\.key))
    }

    public static func activeKeys(in context: ModelContext) -> Set<String> {
        Set(activeDescriptors(in: context).map(\.key))
    }

    /// Substantive-vs-transactional treatment for custom-category memory dossiers.
    /// Custom categories are user-curated topics, so they always get the
    /// substantive / standard-strictness treatment (the strict assembler is
    /// reserved for bulk transactional built-in purposes such as promotion
    /// or notification).
    public static func isSubstantive(customKey: String) -> Bool {
        CustomCategoryKeysJSON.isCanonicalKey(customKey)
    }
}

public extension Notification.Name {
    /// Posted after any mutation of the `CustomMailCategory` table —
    /// creation, removal, example tagging, or background activation — so
    /// open UI surfaces and caches can reload their catalog snapshots.
    static let ohiaCustomCategoriesDidChange = Notification.Name("ohia.customCategories.didChange")
}
