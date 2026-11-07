import Foundation

/// Shared keys for AppStorage-backed Constellation state that crosses
/// the view / menu-bar boundary. Keep both writer (ConstellationModeView)
/// and reader (OhiaMenuCommands) addressing the same string so a typo
/// in one place can't silently break the other.
enum ConstellationDefaultsKey {
    /// UUID-string of the currently locked node, or empty when nothing
    /// is locked. Drives Edit-menu item enablement.
    static let lockedNodeID = "constellationLockedNodeID"

    /// Canonical classification JSON for the currently locked node. Empty
    /// when nothing is locked or classification is pending. Drives the
    /// Edit-menu axis checkmarks without a second projection format.
    static let lockedNodeClassificationJSON = "constellationLockedNodeClassificationJSON"

    /// Canonical custom-category JSON for the currently locked node.
    static let lockedNodeCustomCategoryKeysJSON = "constellationLockedNodeCustomCategoryKeysJSON"

    /// JSON-encoded `[CustomMailCategoryDescriptor]` snapshot of the custom
    /// category catalog, mirrored by `CustomCategoryStore` after every
    /// reload. Lets the menu-bar Commands scene (which has no SwiftData
    /// environment) render the custom rows in the Selected Node Categories
    /// submenu with the same data the in-scene surfaces use.
    static let customCategoryCatalogJSON = "constellationCustomCategoryCatalogJSON"
}
