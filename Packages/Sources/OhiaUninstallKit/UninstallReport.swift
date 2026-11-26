import Foundation

/// The final account shown to the user: what could not be removed and what to
/// do about it, plus other Ohia copies the uninstaller left alone.
public struct UninstallReport: Equatable, Sendable {
    public struct Leftover: Equatable, Sendable {
        public var item: String
        public var reason: String
        public var nextStep: String

        public init(item: String, reason: String, nextStep: String) {
            self.item = item
            self.reason = reason
            self.nextStep = nextStep
        }
    }

    public var leftovers: [Leftover]
    public var otherCopies: [URL]

    public var isClean: Bool { leftovers.isEmpty }

    /// The line above the leftover list, so a list that scrolls still says
    /// how long it is; nil when nothing was left.
    public var leftoverCountLine: String? {
        switch leftovers.count {
        case 0: nil
        case 1: "1 item was not removed:"
        case let count: "\(count) items were not removed:"
        }
    }

    public init(
        removals: [RemovalOutcome],
        cleanup: UninstallCleanupResult?,
        keychainSweepLeftovers: [UninstallCleanupResult.KeychainLeftover] = [],
        privacyResetFailed: Bool = false,
        otherCopies: [URL],
        calendarWasRegistered: Bool
    ) {
        var leftovers: [Leftover] = []

        for outcome in removals {
            switch outcome {
            case .removed, .absent:
                break
            case .needsAdministrator(let url):
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "Removing it needs an administrator password, which was not provided.",
                    nextStep: "Move \(url.path) to the Trash in Finder, or run the uninstaller again and enter your password."))
            case .failed(let url, let message):
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "It could not be removed: \(Self.sentenceFragment(message)).",
                    nextStep: "Move \(url.path) to the Trash in Finder."))
            case .deniedByMacOS(let url):
                // An administrator can't help: macOS refuses root there too.
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "macOS didn't allow Uninstall Ohia to access it.",
                    nextStep: "In System Settings \u{203A} Privacy & Security \u{203A} Files & Folders, allow Uninstall Ohia to access data from other apps, then open Uninstall Ohia from the Ohia disk image."))
            case .onlyOhiaCanRemove(let url):
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "macOS lets only Ohia remove this folder, and Ohia could not remove it.",
                    nextStep: Self.groupContainerStep))
            case .ohiaDidNotReport(let url):
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "Ohia did not report whether it removed this folder.",
                    nextStep: Self.groupContainerStep))
            case .leftByOhia(let url, let errorNumber):
                let detail = errorNumber.map { ": \(Self.sentenceFragment(String(cString: strerror($0))))" } ?? ""
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "Ohia could not remove it during its cleanup\(detail).",
                    nextStep: Self.groupContainerStep))
            case .folderNotWhereExpected(let url):
                // Running the uninstaller again would refuse it again.
                leftovers.append(Leftover(
                    item: url.path,
                    reason: "Its folder isn't where Ohia expects it to be, and may have been moved or linked.",
                    nextStep: "Move \(url.path) to the Trash in Finder."))
            }
        }

        let calendarItem = "The \"Ohia\" calendar"
        let calendarStep = "Open Calendar, select the \"Ohia\" calendar in the sidebar, and delete it."
        switch cleanup?.calendar {
        case nil:
            if calendarWasRegistered {
                leftovers.append(Leftover(
                    item: calendarItem,
                    reason: "Ohia did not report back, so the calendar was not deleted.",
                    nextStep: calendarStep))
            }
        case .noAccess?:
            if calendarWasRegistered {
                leftovers.append(Leftover(
                    item: calendarItem,
                    reason: "Ohia does not have access to Calendar, so it could not delete the calendar.",
                    nextStep: calendarStep))
            }
        case .failed?:
            if calendarWasRegistered {
                let detail = cleanup?.calendarError.map { ": \(Self.sentenceFragment($0))" } ?? ""
                leftovers.append(Leftover(
                    item: calendarItem,
                    reason: "Deleting the calendar failed\(detail).",
                    nextStep: calendarStep))
            }
        case .deleted?, .notRegistered?:
            break
        }

        // The same service can come from Ohia's cleanup and the uninstaller's
        // own sweep; report it once with the larger count.
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in (cleanup?.keychainLeftovers ?? []) + keychainSweepLeftovers {
            if counts[entry.service] == nil { order.append(entry.service) }
            counts[entry.service] = max(counts[entry.service] ?? 0, entry.count)
        }
        for service in order {
            let keychain = UninstallCleanupResult.KeychainLeftover(service: service, count: counts[service] ?? 0)
            let noun = keychain.count == 1 ? "item" : "items"
            leftovers.append(Leftover(
                item: "Keychain \(noun) for the service \(keychain.service)",
                reason: "\(keychain.count) \(noun) could not be removed.",
                nextStep: "Open Keychain Access, search for \(keychain.service), and delete the \(noun)."))
        }

        if privacyResetFailed {
            leftovers.append(Leftover(
                item: "Ohia's privacy permissions in System Settings \u{203A} Privacy & Security",
                reason: "macOS did not let the uninstaller reset them.",
                nextStep: "Remove Ohia from System Settings \u{203A} Privacy & Security."))
        }

        self.leftovers = leftovers
        self.otherCopies = otherCopies
    }

    /// For what is left in Ohia's group container: with Full Disk Access the
    /// uninstaller can open it, and the disk image's copy outlives Ohia.app.
    static let groupContainerStep =
        "In System Settings \u{203A} Privacy & Security \u{203A} Full Disk Access, turn on Uninstall Ohia, then open Uninstall Ohia from the Ohia disk image."

    /// Cocoa error descriptions already end in a period; drop terminal
    /// punctuation so the sentence that embeds one adds exactly one.
    private static func sentenceFragment(_ message: String) -> String {
        var text = Substring(message)
        let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?\u{2026}"))
        while let last = text.unicodeScalars.last, trailing.contains(last) {
            text = text.dropLast()
        }
        return String(text)
    }
}
