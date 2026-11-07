import Foundation

public extension Notification.Name {
    static let ohiaMessageAttentionChanged = Notification.Name("ohia.messageAttention.changed")
}

public enum MessageAttentionNotificationUserInfoKey {
    public static let messageIDs = "messageIDs"
}

public enum MessageAttentionNotificationCoding {
    public static func userInfo(messageIDs: Set<UUID>) -> [AnyHashable: Any] {
        [
            MessageAttentionNotificationUserInfoKey.messageIDs:
                messageIDs.map(\.uuidString).sorted(),
        ]
    }

    public static func messageIDs(from notification: Notification) -> Set<UUID> {
        guard let rawIDs = notification.userInfo?[
            MessageAttentionNotificationUserInfoKey.messageIDs
        ] else {
            return []
        }
        if let ids = rawIDs as? [UUID] {
            return Set(ids)
        }
        guard let strings = rawIDs as? [String] else {
            return []
        }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }
}
