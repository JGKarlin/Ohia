import Foundation

public struct NewMailNotificationMessageSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let senderName: String?
    public let senderAddress: String
    public let subject: String
    public let summary: String?
    public let purpose: MailPurpose?
    public let isActionable: Bool
    public let requiresConfirmation: Bool
    public let hasDeadline: Bool
    public let deadlineText: String?
    public let isRead: Bool
    public let receivedAt: Date?

    public init(
        id: UUID,
        senderName: String? = nil,
        senderAddress: String,
        subject: String,
        summary: String? = nil,
        purpose: MailPurpose? = nil,
        isActionable: Bool = false,
        requiresConfirmation: Bool = false,
        hasDeadline: Bool = false,
        deadlineText: String? = nil,
        isRead: Bool = false,
        receivedAt: Date? = nil
    ) {
        self.id = id
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.subject = subject
        self.summary = summary
        self.purpose = purpose
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.hasDeadline = hasDeadline
        self.deadlineText = deadlineText
        self.isRead = isRead
        self.receivedAt = receivedAt
    }
}

public struct NewMailNotificationPresentation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case singleMessage
        case messageBatch
    }

    public enum InterruptionHint: Sendable, Equatable {
        case normal
        case timeSensitive
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let body: String
    public let threadIdentifier: String
    public let relevanceScore: Double
    public let interruptionHint: InterruptionHint
    public let messageIDs: [UUID]
    public let primaryMessageID: UUID?

    public static func make(
        threadIdentifier: String,
        folder: String,
        count: Int,
        messages: [NewMailNotificationMessageSnapshot]
    ) -> NewMailNotificationPresentation {
        let normalizedFolder = trimmedNonEmpty(folder) ?? "INBOX"
        let sortedMessages = messages.sorted { lhs, rhs in
            switch (lhs.receivedAt, rhs.receivedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        let totalCount = max(1, count, sortedMessages.count)

        if totalCount == 1, let message = sortedMessages.first {
            return singlePresentation(
                message: message,
                threadIdentifier: threadIdentifier
            )
        }

        return batchPresentation(
            count: totalCount,
            messages: sortedMessages,
            folder: normalizedFolder,
            threadIdentifier: threadIdentifier
        )
    }

    private static func singlePresentation(
        message: NewMailNotificationMessageSnapshot,
        threadIdentifier: String
    ) -> NewMailNotificationPresentation {
        let subject = trimmedNonEmpty(message.subject) ?? "No subject"
        return NewMailNotificationPresentation(
            kind: .singleMessage,
            title: displaySender(for: message),
            subtitle: subject,
            body: statusLabel(for: message),
            threadIdentifier: threadIdentifier,
            relevanceScore: relevanceScore(for: [message]),
            interruptionHint: interruptionHint(for: [message]),
            messageIDs: [message.id],
            primaryMessageID: message.id
        )
    }

    private static func batchPresentation(
        count: Int,
        messages: [NewMailNotificationMessageSnapshot],
        folder: String,
        threadIdentifier: String
    ) -> NewMailNotificationPresentation {
        let replyCount = messages.filter(\.isActionable).count
        let confirmationCount = messages.filter(\.requiresConfirmation).count
        var bodyParts: [String] = []
        if replyCount > 0 {
            bodyParts.append(needPhrase(count: replyCount, object: "reply"))
        }
        if confirmationCount > 0 {
            bodyParts.append(needPhrase(count: confirmationCount, object: "confirmation"))
        }
        let senders = topSenders(from: messages)
        if !senders.isEmpty {
            bodyParts.append(senders.joined(separator: ", "))
        }
        let purposes = topPurposes(from: messages)
        if !purposes.isEmpty {
            bodyParts.append(purposes.joined(separator: ", "))
        }
        return NewMailNotificationPresentation(
            kind: .messageBatch,
            title: count == 1 ? "1 new message" : "\(count) new messages",
            subtitle: folder,
            body: bodyParts.joined(separator: " · "),
            threadIdentifier: threadIdentifier,
            relevanceScore: relevanceScore(for: messages),
            interruptionHint: interruptionHint(for: messages),
            messageIDs: messages.map(\.id),
            primaryMessageID: messages.first?.id
        )
    }

    private static func displaySender(for message: NewMailNotificationMessageSnapshot) -> String {
        if let name = trimmedNonEmpty(message.senderName),
           name.caseInsensitiveCompare(message.senderAddress) != .orderedSame {
            return name
        }
        return trimmedNonEmpty(message.senderAddress) ?? "Unknown sender"
    }

    private static func statusLabel(for message: NewMailNotificationMessageSnapshot) -> String {
        var parts: [String] = []
        if let purpose = purposeLabel(for: message) {
            parts.append(purpose)
        }
        // Reply and confirmation are mutually exclusive (the binary obligation
        // invariant, enforced upstream on the verdict feeding this snapshot),
        // so a single message resolves to exactly one obligation status.
        if message.isActionable {
            parts.append("Reply needed")
        } else if message.requiresConfirmation {
            parts.append("Confirmation needed")
        } else if let deadlineText = trimmedNonEmpty(message.deadlineText) {
            parts.append("Deadline (\(deadlineText))")
        } else if message.hasDeadline {
            parts.append("Deadline")
        }
        return parts.joined(separator: " · ")
    }

    private static func purposeLabel(for message: NewMailNotificationMessageSnapshot) -> String? {
        guard let purpose = message.purpose else { return nil }
        return "\(purpose.notificationIcon) \(purpose.displayLabel)"
    }

    private static func topSenders(
        from messages: [NewMailNotificationMessageSnapshot]
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for message in messages {
            let sender = displaySender(for: message)
            let key = sender.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(sender)
            if result.count == 3 { break }
        }
        return result
    }

    private static func topPurposes(
        from messages: [NewMailNotificationMessageSnapshot]
    ) -> [String] {
        var counts: [MailPurpose: Int] = [:]
        for message in messages {
            guard let purpose = message.purpose else { continue }
            counts[purpose, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                let leftIndex = MailPurpose.allCases.firstIndex(of: lhs.key) ?? .max
                let rightIndex = MailPurpose.allCases.firstIndex(of: rhs.key) ?? .max
                return leftIndex < rightIndex
            }
            .prefix(2)
            .map { $0.key.displayLabel }
    }

    private static func needPhrase(count: Int, object: String) -> String {
        count == 1 ? "1 needs \(object)" : "\(count) need \(object)"
    }

    private static func relevanceScore(
        for messages: [NewMailNotificationMessageSnapshot]
    ) -> Double {
        var score = 0.45
        if messages.contains(where: \.requiresConfirmation) {
            score += 0.18
        }
        if messages.contains(where: \.isActionable) {
            score += 0.28
        }
        if messages.count > 1 {
            score += min(0.09, Double(messages.count - 1) * 0.03)
        }
        return min(1.0, score)
    }

    private static func interruptionHint(
        for messages: [NewMailNotificationMessageSnapshot]
    ) -> InterruptionHint {
        messages.contains { $0.isActionable || $0.requiresConfirmation || $0.hasDeadline }
            ? .timeSensitive
            : .normal
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
