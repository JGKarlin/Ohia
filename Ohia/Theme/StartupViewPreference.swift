import Foundation

enum StartupViewPreference: String, CaseIterable, Identifiable {
    static let storageKey = "startupView"
    static let defaultPreference: StartupViewPreference = .constellation

    case constellation
    case composer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .constellation: return "Constellation"
        case .composer: return "Composer"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> StartupViewPreference {
        guard let raw = defaults.string(forKey: storageKey) else {
            return defaultPreference
        }
        // "almanac" was a valid stored value before the Almanac was retired;
        // those installs land on the Constellation.
        guard let preference = StartupViewPreference(rawValue: raw) else {
            return defaultPreference
        }
        return preference
    }
}
