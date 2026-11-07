import Foundation

public enum DeletionSyncPreferences {
    public static let defaultNonGmailGracePeriodSeconds: TimeInterval = 10 * 60
    private static let retiredNonGmailGracePeriodSecondsKey = "ohia.deletionSync.nonGmailGracePeriodSeconds"

    public static func nonGmailGracePeriodSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        defaults.removeObject(forKey: retiredNonGmailGracePeriodSecondsKey)
        return defaultNonGmailGracePeriodSeconds
    }
}
