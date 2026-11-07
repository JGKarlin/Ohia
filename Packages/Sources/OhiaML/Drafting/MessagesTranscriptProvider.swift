import Foundation
import OhiaCore

public struct AutomaticMessagesRequest: Codable, Equatable, Sendable {
    public enum Context: Codable, Equatable, Sendable {
        case reply(messageID: UUID, draftID: UUID?)
        case compose(draftID: UUID)
    }

    public let context: Context
    public let correspondentAddress: String
    public let limit: Int
    public let maxAge: TimeInterval

    public init(
        context: Context,
        correspondentAddress: String,
        limit: Int,
        maxAge: TimeInterval
    ) {
        self.context = context
        self.correspondentAddress = correspondentAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.limit = min(max(0, limit), 200)
        self.maxAge = min(max(0, maxAge), 365 * 24 * 60 * 60)
    }

    public var draftID: UUID? {
        switch context {
        case .reply(_, let draftID): draftID
        case .compose(let draftID): draftID
        }
    }
}

public struct AutomaticMessagesTranscript: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public let date: Date
        public let isFromMe: Bool
        public let text: String

        public init(date: Date, isFromMe: Bool, text: String) {
            self.date = date
            self.isFromMe = isFromMe
            self.text = text
        }
    }

    public let correspondentName: String
    /// Oldest first.
    public let lines: [Line]

    public init(correspondentName: String, lines: [Line]) {
        self.correspondentName = correspondentName
        self.lines = lines
    }

    public func formattedTranscript() -> String {
        formattedLines().joined(separator: "\n\n")
    }

    public func formattedLines() -> [String] {
        lines.map { line in
            let who = line.isFromMe ? "You" : correspondentName
            return "\(Self.lineFormatter.string(from: line.date)) · \(who): \(line.text)"
        }
    }

    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}

public enum AutomaticMessagesResult: Codable, Equatable, Sendable {
    case found(AutomaticMessagesTranscript)
    case contactNotFound
    case noMatchingChat
    case contactResolvedDatabaseUnavailable
    case unavailable

    public func composerSource(messageID: UUID? = nil) -> ComposerSource? {
        guard case .found(let transcript) = self, !transcript.lines.isEmpty else {
            return nil
        }
        return ComposerSource(
            kind: .messages,
            label: "Messages with \(transcript.correspondentName)",
            snippet: transcript.formattedTranscript(),
            messageID: messageID,
            transcriptMessageCount: transcript.lines.count
        )
    }
}

public protocol MessagesTranscriptProviding: Sendable {
    func transcript(for request: AutomaticMessagesRequest) async -> AutomaticMessagesResult
}

public struct UnavailableMessagesTranscriptProvider: MessagesTranscriptProviding {
    public init() {}

    public func transcript(for request: AutomaticMessagesRequest) async -> AutomaticMessagesResult {
        .unavailable
    }
}
