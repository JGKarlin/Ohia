import Foundation
import OhiaCore

struct MeetingCalendarMatchKey: Sendable, Equatable {
    let entryID: String
    let externalIdentifier: String?
    let title: String
    let startDate: Date
    let onlineMeetingURL: URL?
    let isRecurrenceInstance: Bool
    let threadID: String?
    let isCalendarInvitation: Bool
}

struct MeetingCalendarEventCandidate: Sendable, Equatable {
    let identifier: String
    let externalIdentifier: String?
    let calendarIdentifier: String
    let lastModifiedAt: Date
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let onlineMeetingURL: URL?
    let notes: String?
}

struct MeetingCalendarEventState: Sendable, Equatable {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let onlineMeetingURL: URL?
    let alarms: [DeadlineCalendarAlarmDescriptor]

    init(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        onlineMeetingURL: URL?,
        alarms: [DeadlineCalendarAlarmDescriptor]
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.onlineMeetingURL = onlineMeetingURL
        self.alarms = DeadlineCalendarChangePolicy.normalizedAlarms(alarms)
    }
}

enum MeetingCalendarImportAction: Sendable, Equatable {
    case unchanged
    case restoreEmailEvidence
    case override(MeetingCalendarEventState)
}

enum MeetingCalendarChangePolicy {
    static func importedChange(
        event: MeetingCalendarEventState,
        baseline: MeetingCalendarEventState,
        source: MeetingCalendarEventState,
        eventMatchesManagedFingerprint: Bool = true,
        hasCalendarOverride: Bool = false
    ) -> MeetingCalendarImportAction {
        guard eventMatchesManagedFingerprint else { return .override(event) }
        if event == source,
           hasCalendarOverride || event != baseline {
            return .restoreEmailEvidence
        }
        guard event != baseline else { return .unchanged }
        guard event != source else { return .restoreEmailEvidence }
        return .override(event)
    }

    static func importedChangeWithoutSource(
        event: MeetingCalendarEventState,
        baseline: MeetingCalendarEventState,
        eventMatchesManagedFingerprint: Bool
    ) -> MeetingCalendarImportAction {
        guard event == baseline,
              eventMatchesManagedFingerprint else {
            return .override(event)
        }
        return .unchanged
    }
}

enum MeetingCalendarOwnedDuplicateAction: Sendable, Equatable {
    case none
    case retire(preserveCalendarOverride: Bool)
}

enum MeetingCalendarDuplicatePolicy {
    static let markerPrefix = "[ohia-meeting:"
    static let sourceUpdatedPrefix = "[ohia-meeting-source:"
    static let fingerprintPrefix = "[ohia-meeting-fingerprint:"
    static let threadPrefix = "[ohia-meeting-thread:"
    static let kindPrefix = "[ohia-meeting-kind:"
    private static let startTolerance: TimeInterval = 15 * 60

    static func ownedDuplicateAction(
        canonicalCalendarIdentifier: String,
        managedCalendarIdentifier: String,
        hasOwnedCopy: Bool,
        ownedCopyMatchesManagedFingerprint: Bool
    ) -> MeetingCalendarOwnedDuplicateAction {
        guard hasOwnedCopy,
              canonicalCalendarIdentifier != managedCalendarIdentifier else {
            return .none
        }
        return .retire(
            preserveCalendarOverride: ownedCopyMatchesManagedFingerprint == false
        )
    }

    static func canonicalEvent(
        for key: MeetingCalendarMatchKey,
        candidates: [MeetingCalendarEventCandidate]
    ) -> MeetingCalendarEventCandidate? {
        candidates
            .filter { matches($0, key: key) }
            .sorted {
                if $0.lastModifiedAt != $1.lastModifiedAt {
                    return $0.lastModifiedAt > $1.lastModifiedAt
                }
                return $0.identifier < $1.identifier
            }
            .first
    }

    static func marker(entryID: String) -> String {
        "\(markerPrefix)\(entryID)]"
    }

    static func threadMarker(threadID: String) -> String {
        "\(threadPrefix)\(threadID)]"
    }

    static func eventFingerprint(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        onlineMeetingURL: URL?,
        alarms: [DeadlineCalendarAlarmDescriptor] = [],
        notes: String? = nil
    ) -> String {
        var components = [
            normalizedTitle(title),
            String(Int(startDate.timeIntervalSince1970)),
            String(Int(endDate.timeIntervalSince1970)),
            location?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            OnlineMeetingURL.identity(onlineMeetingURL) ?? "",
        ]
        if alarms.isEmpty == false {
            components.append(normalizedAlarmPayload(alarms))
        }
        components.append(normalizedUserNotes(notes))
        let payload = components.joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func normalizedAlarmPayload(
        _ alarms: [DeadlineCalendarAlarmDescriptor]
    ) -> String {
        DeadlineCalendarChangePolicy.normalizedAlarms(alarms)
            .map { alarm in
                switch alarm {
                case .absolute(let date):
                    return "a:\(date.timeIntervalSinceReferenceDate)"
                case .relative(let offset):
                    return "r:\(offset)"
                }
            }
            .joined(separator: ",")
    }

    static func markerValue(prefix: String, notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(prefix), line.hasSuffix("]") else { continue }
            return String(line.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    private static func matches(
        _ candidate: MeetingCalendarEventCandidate,
        key: MeetingCalendarMatchKey
    ) -> Bool {
        if candidate.notes?.contains(marker(entryID: key.entryID)) == true {
            return true
        }
        if key.isCalendarInvitation,
           let threadID = key.threadID,
           candidate.notes?.contains(threadMarker(threadID: threadID)) == true,
           markerValue(prefix: kindPrefix, notes: candidate.notes) == "body" {
            // A recognized invitation supersedes provisional prose details
            // from the same mail thread even when title and time changed.
            return true
        }
        if let externalIdentifier = key.externalIdentifier,
           candidate.externalIdentifier == externalIdentifier,
           key.isRecurrenceInstance == false
                || startsClose(candidate.startDate, key.startDate) {
            return true
        }
        if let expectedURL = OnlineMeetingURL.identity(key.onlineMeetingURL),
           OnlineMeetingURL.identity(candidate.onlineMeetingURL) == expectedURL,
           startsClose(candidate.startDate, key.startDate) {
            return true
        }
        return normalizedTitle(candidate.title) == normalizedTitle(key.title)
            && startsClose(candidate.startDate, key.startDate)
    }

    private static func startsClose(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= startTolerance
    }

    private static func normalizedUserNotes(_ notes: String?) -> String {
        guard let notes else { return "" }
        return notes
            .split(whereSeparator: \.isNewline)
            .filter {
                $0.hasPrefix(markerPrefix) == false
                    && $0.hasPrefix(sourceUpdatedPrefix) == false
                    && $0.hasPrefix(fingerprintPrefix) == false
                    && $0.hasPrefix(threadPrefix) == false
                    && $0.hasPrefix(kindPrefix) == false
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }
}
