import Foundation

public extension Notification.Name {
    static let ohiaManualProjectMembershipDidChange = Notification.Name(
        "ohia.manualProject.membership.didChange"
    )
    static let ohiaManualProjectSourceDidChange = Notification.Name(
        "ohia.manualProject.source.didChange"
    )
}

public enum ManualProjectMembershipNotificationUserInfoKey {
    public static let projectIDs = "projectIDs"
    public static let messageIDs = "messageIDs"
    public static let configurationRevision = "configurationRevision"
}

public enum ManualProjectMembershipNotificationCoding {
    public static func userInfo(
        projectIDs: Set<UUID>,
        messageIDs: Set<UUID>,
        configurationRevision: Int
    ) -> [AnyHashable: Any] {
        [
            ManualProjectMembershipNotificationUserInfoKey.projectIDs:
                projectIDs.map(\.uuidString).sorted(),
            ManualProjectMembershipNotificationUserInfoKey.messageIDs:
                messageIDs.map(\.uuidString).sorted(),
            ManualProjectMembershipNotificationUserInfoKey.configurationRevision:
                configurationRevision,
        ]
    }

    public static func projectIDs(from notification: Notification) -> Set<UUID> {
        uuidSet(
            from: notification.userInfo?[ManualProjectMembershipNotificationUserInfoKey.projectIDs]
        )
    }

    public static func messageIDs(from notification: Notification) -> Set<UUID> {
        uuidSet(
            from: notification.userInfo?[ManualProjectMembershipNotificationUserInfoKey.messageIDs]
        )
    }

    public static func configurationRevision(from notification: Notification) -> Int? {
        notification.userInfo?[ManualProjectMembershipNotificationUserInfoKey.configurationRevision] as? Int
    }

    private static func uuidSet(from value: Any?) -> Set<UUID> {
        if let ids = value as? [UUID] {
            return Set(ids)
        }
        if let strings = value as? [String] {
            return Set(strings.compactMap(UUID.init(uuidString:)))
        }
        guard let values = value as? [Any] else { return [] }
        return Set(values.compactMap { item in
            if let id = item as? UUID { return id }
            if let string = item as? String { return UUID(uuidString: string) }
            return nil
        })
    }
}

public enum ManualProjectSourceNotificationUserInfoKey {
    public static let messageIDs = "messageIDs"
    public static let facets = "facets"
}

public enum ManualProjectSourceNotificationCoding {
    public static func userInfo(
        messageIDs: Set<UUID>,
        facets: Set<MailProjectRuleFacet>
    ) -> [AnyHashable: Any] {
        [
            ManualProjectSourceNotificationUserInfoKey.messageIDs:
                messageIDs.map(\.uuidString).sorted(),
            ManualProjectSourceNotificationUserInfoKey.facets:
                facets.map(\.rawValue).sorted(),
        ]
    }

    public static func messageIDs(from notification: Notification) -> Set<UUID> {
        let value = notification.userInfo?[ManualProjectSourceNotificationUserInfoKey.messageIDs]
        if let ids = value as? [UUID] {
            return Set(ids)
        }
        if let strings = value as? [String] {
            return Set(strings.compactMap(UUID.init(uuidString:)))
        }
        guard let values = value as? [Any] else { return [] }
        return Set(values.compactMap { item in
            if let id = item as? UUID { return id }
            if let string = item as? String { return UUID(uuidString: string) }
            return nil
        })
    }

    public static func facets(from notification: Notification) -> Set<MailProjectRuleFacet> {
        let value = notification.userInfo?[ManualProjectSourceNotificationUserInfoKey.facets]
        let strings: [String]
        if let typed = value as? [String] {
            strings = typed
        } else if let values = value as? [Any] {
            strings = values.compactMap { $0 as? String }
        } else {
            return []
        }
        return Set(strings.compactMap(MailProjectRuleFacet.init(rawValue:)))
    }
}
