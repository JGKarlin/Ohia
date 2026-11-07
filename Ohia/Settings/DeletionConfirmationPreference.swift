import Foundation

enum DeletionConfirmationPreference {
    static let moveToTrashConfirmationKey = "ohia.deletion.confirmMoveToTrash"
    static let permanentDeleteConfirmationKey = "ohia.deletion.confirmPermanentDelete"
    static let defaultShowsConfirmation = true

    static func showsMoveToTrashConfirmation(defaults: UserDefaults = .standard) -> Bool {
        storedBool(forKey: moveToTrashConfirmationKey, defaults: defaults)
    }

    static func showsPermanentDeleteConfirmation(defaults: UserDefaults = .standard) -> Bool {
        storedBool(forKey: permanentDeleteConfirmationKey, defaults: defaults)
    }

    private static func storedBool(forKey key: String, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultShowsConfirmation
        }
        return defaults.bool(forKey: key)
    }
}
