// Ohia/ConstellationMode/Filters/FilterDefaults.swift
import Foundation
import OhiaCore

/// Canonical preferences for render-time vector collection visibility.
/// These are diagnostic kill-switches now that the toolbar's Layers section
/// has been retired, so they live under Developer Settings rather than the
/// general default-filter surface.
public enum VectorCollectionVisibilityPreferences {
    public enum Keys {
        public static let entity = "constellationShowEntities"
        public static let context = "constellationVectorContext"
        public static let attachment = "constellationVectorAttachment"
        public static let style = "constellationVectorStyle"
    }

    private enum LegacyKeys {
        static let context = "ohiaFilterDefaultCollectionContext"
        static let style = "ohiaFilterDefaultCollectionStyle"
        static let attachment = "ohiaFilterDefaultCollectionAttach"
        static let entity = "ohiaFilterDefaultCollectionEntity"
    }

    public static let defaultCollections: Set<VectorCollection> = [.context, .attachment, .entity]

    public static func registerDefaults(_ defaults: UserDefaults = .standard) {
        migrateLegacyValuesIfNeeded(defaults)
        defaults.register(defaults: [
            Keys.entity: true,
            Keys.context: true,
            Keys.attachment: true,
            Keys.style: false,
        ])
    }

    public static func collections(_ defaults: UserDefaults = .standard) -> Set<VectorCollection> {
        var collections: Set<VectorCollection> = []
        if defaults.object(forKey: Keys.entity) as? Bool ?? true { collections.insert(.entity) }
        if defaults.object(forKey: Keys.context) as? Bool ?? true { collections.insert(.context) }
        if defaults.object(forKey: Keys.attachment) as? Bool ?? true { collections.insert(.attachment) }
        if defaults.object(forKey: Keys.style) as? Bool ?? false { collections.insert(.style) }
        return collections
    }

    private static func migrateLegacyValuesIfNeeded(_ defaults: UserDefaults) {
        migrateBool(from: LegacyKeys.entity, to: Keys.entity, defaults: defaults)
        migrateBool(from: LegacyKeys.context, to: Keys.context, defaults: defaults)
        migrateBool(from: LegacyKeys.attachment, to: Keys.attachment, defaults: defaults)
        migrateBool(from: LegacyKeys.style, to: Keys.style, defaults: defaults)
    }

    private static func migrateBool(from oldKey: String, to newKey: String, defaults: UserDefaults) {
        guard defaults.object(forKey: newKey) == nil,
              let value = defaults.object(forKey: oldKey) as? Bool else {
            return
        }
        defaults.set(value, forKey: newKey)
    }
}
