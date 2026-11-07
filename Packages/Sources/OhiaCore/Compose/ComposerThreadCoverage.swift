import Foundation

/// The conversation a reply's automatic sources were compiled from: every
/// thread message present at compile time (the replied-to message included)
/// plus the Message-ID of a missing parent whose text was recovered from the
/// incoming email's quoted history. Stored on the preparation and the Draft so
/// the scheduler can tell when the thread has since gained an earlier email
/// the draft never saw.
public struct ComposerThreadCoverage: Codable, Sendable, Equatable {
    public let messageIDs: [UUID]
    public let quotedMessageIDHeaders: [String]

    public init(messageIDs: Set<UUID>, quotedMessageIDHeaders: Set<String>) {
        self.messageIDs = messageIDs.sorted { $0.uuidString < $1.uuidString }
        self.quotedMessageIDHeaders = quotedMessageIDHeaders.sorted()
    }

    public static func decode(_ json: String?) -> ComposerThreadCoverage? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ComposerThreadCoverage.self, from: data)
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of UUIDs and strings cannot fail.
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The same covered set with additional thread messages.
    public func adding(messageIDs added: [UUID]) -> ComposerThreadCoverage {
        ComposerThreadCoverage(
            messageIDs: Set(messageIDs).union(added),
            quotedMessageIDHeaders: Set(quotedMessageIDHeaders)
        )
    }

    /// Thread messages that belong between the newest email this coverage
    /// saw before `message` and `message` itself, but that it never saw —
    /// emails that would change the conversation's latest state. Older
    /// history arriving later (mailbox backfill runs newest-first) is not
    /// reported: a reply is grounded in where the exchange now stands. A
    /// message whose Message-ID was recovered from a quote is covered: its
    /// content shaped the draft. Oldest first.
    public func missedEarlierMessages(for message: Message) -> [Message] {
        let covered = Set(messageIDs)
        let quoted = Set(quotedMessageIDHeaders)
        let targetDate = Self.ordering(message)
        let earlier = (message.thread?.messages ?? []).filter { member in
            member.id != message.id && !member.isTrashed && Self.ordering(member) < targetDate
        }
        let newestCovered = earlier
            .filter { covered.contains($0.id) }
            .map(Self.ordering)
            .max()
        return earlier
            .filter { member in
                guard !covered.contains(member.id) else { return false }
                if let newestCovered, Self.ordering(member) <= newestCovered {
                    return false
                }
                guard let header = Self.normalizedMessageIDHeader(member.messageIdHeader) else {
                    return true
                }
                return !quoted.contains(header)
            }
            .sorted {
                let left = Self.ordering($0)
                let right = Self.ordering($1)
                if left != right { return left < right }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Thread emails after `message` that this coverage never saw: when the
    /// replied-to email is the conversation's newest qualifying one, later
    /// emails that qualify for nothing (a CC'd colleague's "Thanks", an FYI)
    /// stay thread context and change where the exchange stands. Trashed
    /// emails and unsent Ohia Composer mailbox drafts are not context. A
    /// message whose Message-ID was recovered from a quote is covered.
    /// Oldest first.
    public func missedLaterMessages(for message: Message) -> [Message] {
        let covered = Set(messageIDs)
        let quoted = Set(quotedMessageIDHeaders)
        let targetDate = Self.ordering(message)
        return (message.thread?.messages ?? [])
            .filter { member in
                guard member.id != message.id,
                      !member.isTrashed,
                      Self.ordering(member) > targetDate,
                      !covered.contains(member.id),
                      !isOhiaComposerMailboxDraftMessageID(member.messageIdHeader) else {
                    return false
                }
                guard let header = Self.normalizedMessageIDHeader(member.messageIdHeader) else {
                    return true
                }
                return !quoted.contains(header)
            }
            .sorted {
                let left = Self.ordering($0)
                let right = Self.ordering($1)
                if left != right { return left < right }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Every `<id>` token in a Message-ID / In-Reply-To / References value,
    /// normalized (brackets dropped, lowercased). A value without brackets
    /// is one bare token.
    public static func messageIDTokens(_ raw: String?) -> [String] {
        guard let raw, raw.utf16.count <= 16_384 else { return [] }
        var tokens: [String] = []
        var remainder = raw[...]
        while let open = remainder.firstIndex(of: "<"),
              let close = remainder[open...].firstIndex(of: ">") {
            let token = remainder[remainder.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !token.isEmpty { tokens.append(token) }
            remainder = remainder[remainder.index(after: close)...]
        }
        if tokens.isEmpty {
            let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !bare.isEmpty, !bare.contains(where: \.isWhitespace) { tokens.append(bare) }
        }
        return tokens
    }

    /// The first Message-ID token of a header value.
    public static func normalizedMessageIDHeader(_ raw: String?) -> String? {
        messageIDTokens(raw).first
    }

    private static func ordering(_ message: Message) -> Date {
        message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }
}
