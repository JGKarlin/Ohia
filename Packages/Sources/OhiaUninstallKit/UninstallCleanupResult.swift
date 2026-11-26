import Foundation

/// The JSON Ohia's cleanup mode hands to the uninstaller app.
///
/// Decoding reads any version from `oldestReadableVersion` up, keeps the
/// fields this build knows and ignores the rest, so a disk-image uninstaller
/// can read a newer Ohia's result. Version 2 is the first with the group
/// container outcome; nothing outside this development branch ever wrote
/// version 1, so it is not read.
public struct UninstallCleanupResult: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let oldestReadableVersion = 2

    public enum CalendarOutcome: String, Codable, Sendable {
        case deleted, notRegistered, noAccess, failed

        /// An outcome added by a newer Ohia decodes as `failed`, so the
        /// calendar is reported rather than assumed gone.
        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = CalendarOutcome(rawValue: rawValue) ?? .failed
        }
    }

    public struct KeychainLeftover: Codable, Equatable, Sendable {
        public var service: String
        public var count: Int

        public init(service: String, count: Int) {
            self.service = service
            self.count = count
        }
    }

    /// What Ohia's emptying of its group container left. macOS lets only
    /// Ohia, the container's owner, open it.
    ///
    /// Encoded as an object with a `kind` field. A kind this build does not
    /// know, from a newer Ohia, decodes as `unrecognized` instead of failing
    /// the whole result; it is never read as removed.
    public enum GroupContainerOutcome: Codable, Equatable, Sendable {
        /// Nothing is left but the bookkeeping file macOS keeps there.
        case removed
        /// There was no group container.
        case absent
        /// These entries at the container's root are still there.
        case leftovers([GroupContainerLeftover])
        /// The container itself could not be read, with the error number.
        case unreadable(errorNumber: Int32)
        /// A newer Ohia's outcome this build does not know. Ohia never writes
        /// it; the report treats it as not knowing whether the folder went.
        case unrecognized

        private enum CodingKeys: String, CodingKey {
            case kind, leftovers, errorNumber
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "removed":
                self = .removed
            case "absent":
                self = .absent
            case "leftovers":
                self = .leftovers(try container.decode([GroupContainerLeftover].self, forKey: .leftovers))
            case "unreadable":
                self = .unreadable(errorNumber: try container.decode(Int32.self, forKey: .errorNumber))
            default:
                self = .unrecognized
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .removed:
                try container.encode("removed", forKey: .kind)
            case .absent:
                try container.encode("absent", forKey: .kind)
            case .leftovers(let entries):
                try container.encode("leftovers", forKey: .kind)
                try container.encode(entries, forKey: .leftovers)
            case .unreadable(let errorNumber):
                try container.encode("unreadable", forKey: .kind)
                try container.encode(errorNumber, forKey: .errorNumber)
            case .unrecognized:
                try container.encode("unrecognized", forKey: .kind)
            }
        }
    }

    /// One entry at the group container's root that Ohia could not remove.
    public struct GroupContainerLeftover: Codable, Equatable, Sendable {
        public var name: String
        /// The error number its removal failed with; nil when it failed
        /// without one, or appeared after the removal pass.
        public var errorNumber: Int32?

        public init(name: String, errorNumber: Int32?) {
            self.name = name
            self.errorNumber = errorNumber
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
    }

    public var version: Int
    public var calendar: CalendarOutcome
    public var calendarError: String?
    public var keychainLeftovers: [KeychainLeftover]
    public var groupContainer: GroupContainerOutcome

    public init(
        version: Int = UninstallCleanupResult.currentVersion,
        calendar: CalendarOutcome,
        calendarError: String? = nil,
        keychainLeftovers: [KeychainLeftover],
        groupContainer: GroupContainerOutcome = .removed
    ) {
        self.version = version
        self.calendar = calendar
        self.calendarError = calendarError
        self.keychainLeftovers = keychainLeftovers
        self.groupContainer = groupContainer
    }

    /// `current` with what an earlier run's cleanup reported folded in. The
    /// uninstaller keeps the earlier result when Ohia ran its cleanup but
    /// didn't quit and the user tries again. A calendar the earlier cleanup
    /// could not delete (`failed` or `noAccess`) can come back from the retry
    /// as `notRegistered`, for example when Ohia's settings went in between;
    /// the earlier outcome is kept then.
    ///
    /// Keychain leftovers and the group container come from the current run
    /// only: each run's cleanup (or, for the keychain, the uninstaller's own
    /// sweep) goes over them again, and an Ohia that kept running after the
    /// earlier cleanup could have written to the group container since.
    /// Without a current result, the earlier one is returned with no keychain
    /// leftovers; the run reports the group container from its own cleanup
    /// alone.
    public static func merging(
        _ current: UninstallCleanupResult?,
        earlier: UninstallCleanupResult?
    ) -> UninstallCleanupResult? {
        guard let earlier else { return current }
        guard var merged = current else {
            var carried = earlier
            carried.keychainLeftovers = []
            return carried
        }
        if merged.calendar == .notRegistered, earlier.calendar == .failed || earlier.calendar == .noAccess {
            merged.calendar = earlier.calendar
            merged.calendarError = earlier.calendarError
        }
        return merged
    }

    /// Throws for a missing version, a version below `oldestReadableVersion`,
    /// or a missing field this build needs.
    public static func decode(_ data: Data) throws -> UninstallCleanupResult {
        let result = try JSONDecoder().decode(UninstallCleanupResult.self, from: data)
        guard result.version >= oldestReadableVersion else {
            throw DecodeError.unsupportedVersion(result.version)
        }
        return result
    }
}
