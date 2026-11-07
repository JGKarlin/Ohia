import Foundation

public struct MessagesReaderRequest: Codable, Equatable, Sendable {
    public static let maximumLimit = 200
    public static let maximumAge: TimeInterval = 365 * 24 * 60 * 60

    public let emailHandles: [String]
    public let phoneHandles: [String]
    public let limit: Int
    public let cutoff: Date

    public init(
        emailHandles: [String],
        phoneHandles: [String],
        limit: Int,
        cutoff: Date
    ) {
        self.emailHandles = emailHandles
        self.phoneHandles = phoneHandles
        self.limit = limit
        self.cutoff = cutoff
    }

    /// Revalidates the app-provided payload at the service boundary. The
    /// service never trusts callers to preserve Ohia's 200-message/365-day
    /// ceilings or to send already-normalized handles.
    public func constrainedForService(now: Date = Date()) -> Self {
        let earliestCutoff = now.addingTimeInterval(-Self.maximumAge)
        let boundedCutoff = min(max(cutoff, earliestCutoff), now)
        return Self(
            emailHandles: Self.uniqueNormalized(
                emailHandles.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            ),
            phoneHandles: Self.uniqueNormalized(
                phoneHandles.map(Self.digitsOnly)
            ),
            limit: min(max(0, limit), Self.maximumLimit),
            cutoff: boundedCutoff
        )
    }

    private static func uniqueNormalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func digitsOnly(_ value: String) -> String {
        String(value.unicodeScalars.filter(CharacterSet.decimalDigits.contains))
    }
}

public struct MessagesReaderTranscriptLine: Codable, Equatable, Sendable {
    public let date: Date
    public let isFromMe: Bool
    public let text: String

    public init(date: Date, isFromMe: Bool, text: String) {
        self.date = date
        self.isFromMe = isFromMe
        self.text = text
    }
}

public enum MessagesReaderStatus: String, Codable, Equatable, Sendable {
    case found
    case noMatchingChat
    case databaseUnavailable
    case serviceUnavailable
}

public struct MessagesReaderResponse: Codable, Equatable, Sendable {
    public let status: MessagesReaderStatus
    public let lines: [MessagesReaderTranscriptLine]

    public init(status: MessagesReaderStatus, lines: [MessagesReaderTranscriptLine] = []) {
        self.status = status
        self.lines = lines
    }

    public static let databaseUnavailable = Self(status: .databaseUnavailable)
    public static let serviceUnavailable = Self(status: .serviceUnavailable)
}
