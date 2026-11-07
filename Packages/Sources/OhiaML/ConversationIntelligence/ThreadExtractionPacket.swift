import Foundation
import CryptoKit

/// Immutable, per-message input to thread-unit discourse extraction. Bodies
/// arrive already cleaned and quote-stripped by the caller (ingestion /
/// worker layer) — this type and `ThreadExtractionPacketBuilder` do no I/O
/// and no SwiftData access; they are pure, deterministic value transforms.
public struct ThreadPacketMessage: Sendable, Equatable {
    public let messageID: UUID
    public let isSentByUser: Bool
    public let fromName: String?
    public let fromAddress: String
    public let recipients: [String]
    public let timestamp: Date
    public let attachmentNotes: [String]
    /// Already cleaned + quote-stripped by the caller.
    public let bodyText: String

    public init(
        messageID: UUID,
        isSentByUser: Bool,
        fromName: String?,
        fromAddress: String,
        recipients: [String],
        timestamp: Date,
        attachmentNotes: [String],
        bodyText: String
    ) {
        self.messageID = messageID
        self.isSentByUser = isSentByUser
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.recipients = recipients
        self.timestamp = timestamp
        self.attachmentNotes = attachmentNotes
        self.bodyText = bodyText
    }
}

/// A whole email thread rendered into one deterministic prompt INPUT block,
/// with budget-bounded elision and a version-sensitive fingerprint so
/// callers can detect staleness without re-rendering.
public struct ThreadExtractionPacket: Sendable, Equatable {
    public let subject: String
    /// Chronological, post-elision.
    public let messages: [ThreadPacketMessage]
    /// Count of dropped middle messages (0 when the thread fit in budget).
    public let elidedCount: Int
    public let fingerprint: String
    /// Rendered INPUT block: one line-group per kept message, in order,
    /// with an omission marker where middle messages were elided.
    public let promptSection: String
    /// 1-based prompt index → messageID (for evidence attribution).
    public let messageIDByIndex: [Int: UUID]

    // No public initializer: per the interface, packets are constructed only
    // via `ThreadExtractionPacketBuilder.make`, which uses the synthesized
    // memberwise (internal) init from within this file.
}

/// Stateless builder: sorts, clips, elides, renders, and fingerprints a
/// thread's messages into a `ThreadExtractionPacket`. Pure and
/// deterministic — no SwiftData, no I/O, no locale/timezone dependence
/// (dates render as fixed-UTC ISO 8601).
public enum ThreadExtractionPacketBuilder {
    /// Per-message body clip applied before budget accounting.
    public static let perMessageCharacterCap = 2_000
    /// Total body-character budget for the whole rendered packet.
    public static let packetCharacterBudget = 9_000

    /// Hex SHA-256 of `version + "\u{1F}" + memberIDs.map(\.uuidString).sorted().joined(separator: ",")`.
    /// Order-invariant in `memberIDs`; sensitive to membership and `version`.
    public static func fingerprint(memberIDs: [UUID], version: String) -> String {
        let sortedIDs = memberIDs.map(\.uuidString).sorted().joined(separator: ",")
        let payload = version + "\u{1F}" + sortedIDs
        return sha256Hex(payload)
    }

    /// Builds the packet: sorts `messages` chronologically (stable tiebreak
    /// by `messageID.uuidString` for callers passing unsorted input), clips
    /// each body to `perMessageCharacterCap`, elides middle messages when
    /// the clipped total exceeds `packetCharacterBudget` (keeping the first
    /// message and as many of the most recent as fit), renders the INPUT
    /// block, and fingerprints the full (pre-elision) member set against
    /// `DiscourseMemory.threadVersion` so the result is directly comparable
    /// to a persisted `DiscourseMemory.threadFingerprint`.
    public static func make(subject: String, messages: [ThreadPacketMessage], now: Date) -> ThreadExtractionPacket {
        let sorted = messages.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.messageID.uuidString < rhs.messageID.uuidString
        }

        let clipped = sorted.map(clipBody)
        let (kept, elidedCount) = elide(clipped)
        let (promptSection, messageIDByIndex) = render(messages: kept, elidedCount: elidedCount)
        let fingerprintValue = fingerprint(memberIDs: sorted.map(\.messageID), version: DiscourseMemory.threadVersion)

        return ThreadExtractionPacket(
            subject: subject,
            messages: kept,
            elidedCount: elidedCount,
            fingerprint: fingerprintValue,
            promptSection: promptSection,
            messageIDByIndex: messageIDByIndex
        )
    }

    // MARK: - Clipping

    private static func clipBody(_ message: ThreadPacketMessage) -> ThreadPacketMessage {
        guard message.bodyText.count > perMessageCharacterCap else { return message }
        return ThreadPacketMessage(
            messageID: message.messageID,
            isSentByUser: message.isSentByUser,
            fromName: message.fromName,
            fromAddress: message.fromAddress,
            recipients: message.recipients,
            timestamp: message.timestamp,
            attachmentNotes: message.attachmentNotes,
            bodyText: String(message.bodyText.prefix(perMessageCharacterCap))
        )
    }

    // MARK: - Elision

    /// `messages` must already be chronologically sorted and body-clipped.
    /// Keeps the first message plus a maximal contiguous suffix (most
    /// recent messages) whose combined body length fits the remaining
    /// budget after the first message; everything between is elided.
    private static func elide(_ messages: [ThreadPacketMessage]) -> (kept: [ThreadPacketMessage], elidedCount: Int) {
        guard messages.count > 1 else { return (messages, 0) }

        let total = messages.reduce(0) { $0 + $1.bodyText.count }
        guard total > packetCharacterBudget else { return (messages, 0) }

        let first = messages[0]
        var remainingBudget = packetCharacterBudget - first.bodyText.count

        var trailing: [ThreadPacketMessage] = []
        var index = messages.count - 1
        while index > 0 {
            let candidate = messages[index]
            let length = candidate.bodyText.count
            guard length <= remainingBudget else { break }
            trailing.insert(candidate, at: 0)
            remainingBudget -= length
            index -= 1
        }

        let elidedCount = messages.count - 1 - trailing.count
        return ([first] + trailing, elidedCount)
    }

    // MARK: - Rendering

    /// `messages` is the post-elision, chronological, already-clipped list.
    private static func render(
        messages: [ThreadPacketMessage],
        elidedCount: Int
    ) -> (promptSection: String, messageIDByIndex: [Int: UUID]) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")

        var blocks: [String] = []
        var messageIDByIndex: [Int: UUID] = [:]

        for (offset, message) in messages.enumerated() {
            let index = offset + 1
            messageIDByIndex[index] = message.messageID

            let directionLabel: String
            if message.isSentByUser {
                directionLabel = "you wrote (to \(message.recipients.joined(separator: ", ")))"
            } else {
                directionLabel = "from \(message.fromName ?? message.fromAddress) <\(message.fromAddress)>"
            }

            let dateISO = formatter.string(from: message.timestamp)
            var lines = ["[\(index)] \(directionLabel) — \(dateISO)"]
            if !message.attachmentNotes.isEmpty {
                lines.append("attachments: \(message.attachmentNotes.joined(separator: ", "))")
            }
            lines.append(message.bodyText)
            blocks.append(lines.joined(separator: "\n"))

            if index == 1 && elidedCount > 0 {
                blocks.append("[\(elidedCount) earlier messages omitted]")
            }
        }

        return (blocks.joined(separator: "\n\n"), messageIDByIndex)
    }

    // MARK: - Hashing

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        var output: [UInt8] = []
        output.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}
