import Foundation
import OhiaCore

enum LockedOverlayBadgePolicy {
    static func visibleBadgeItems(
        from items: [ScreenAnnotationItem],
        activeFrame: FrameKey,
        limit: Int,
        rankedItems: [AnnotationItem]? = nil,
        shouldShowBadge: (String) -> Bool
    ) -> [ScreenAnnotationItem] {
        switch activeFrame.spatialLens {
        case .meaning, .defaultFrame:
            return meaningBadgeItems(
                from: items,
                rankedItems: rankedItems,
                shouldShowBadge: shouldShowBadge
            )
        case .people:
            return peopleBadgeItems(
                from: items,
                rankedItems: rankedItems,
                shouldShowBadge: shouldShowBadge
            )
        default:
            return defaultBadgeItems(
                from: items,
                limit: limit,
                shouldShowBadge: shouldShowBadge
            )
        }
    }

    private static func defaultBadgeItems(
        from items: [ScreenAnnotationItem],
        limit: Int,
        shouldShowBadge: (String) -> Bool
    ) -> [ScreenAnnotationItem] {
        items
            .filter { shouldShowBadge($0.id) }
            .sorted {
                if $0.item.importance != $1.item.importance {
                    return $0.item.importance > $1.item.importance
                }
                if $0.item.kind.priority != $1.item.kind.priority {
                    return $0.item.kind.priority < $1.item.kind.priority
                }
                return $0.id < $1.id
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func meaningBadgeItems(
        from items: [ScreenAnnotationItem],
        rankedItems: [AnnotationItem]?,
        shouldShowBadge: (String) -> Bool
    ) -> [ScreenAnnotationItem] {
        let screenItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let semanticallyRanked = rankedItems ?? LockedPaneRanking.sortedItems(items.map(\.item))
        var seenKinds = Set<AnnotationKind>()
        var result: [ScreenAnnotationItem] = []

        for item in semanticallyRanked where seenKinds.insert(item.kind).inserted {
            guard shouldShowBadge(item.id),
                  let screenItem = screenItemByID[item.id] else {
                continue
            }
            result.append(screenItem)
        }

        return result
    }

    private static func peopleBadgeItems(
        from items: [ScreenAnnotationItem],
        rankedItems: [AnnotationItem]?,
        shouldShowBadge: (String) -> Bool
    ) -> [ScreenAnnotationItem] {
        let screenItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let tabbedItems = rankedItems ?? LockedPaneRanking.sortedPeopleItems(items.map(\.item))
        var seenKinds = Set<AnnotationKind>()
        var result: [ScreenAnnotationItem] = []

        for item in tabbedItems where seenKinds.insert(item.kind).inserted {
            guard shouldShowBadge(item.id),
                  let screenItem = screenItemByID[item.id] else {
                continue
            }
            result.append(screenItem)
        }

        return result
    }
}
