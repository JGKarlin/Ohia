import Foundation

public enum OhiaSharedDefaults {
    public static let suiteName = OhiaStorageRoot.appGroupIdentifier

    public static var store: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to open Ohia App Group defaults: \(suiteName)")
        }
        return defaults
    }
}
