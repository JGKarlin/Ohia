import Foundation

enum LockedPaneRanking {
    nonisolated static func sortedItems(_ items: [AnnotationItem]) -> [AnnotationItem] {
        items.sorted(by: itemPrecedes)
    }

    nonisolated static func sortedPeopleItems(_ items: [AnnotationItem]) -> [AnnotationItem] {
        let baseRanked = sortedItems(items)
        let kindOrder = sortedKinds(
            AnnotationKind.allCases,
            rankedItems: baseRanked
        )
        let buckets = Dictionary(grouping: items, by: \.kind)
        return kindOrder.flatMap { kind in
            (buckets[kind] ?? []).sorted(by: peopleItemPrecedes)
        }
    }

    /// People-focus overlay default Tab walk: bucketed by kind in the
    /// chip-strip/ring order (Received → Included → Sent → Sent·Included),
    /// with each bucket itself sorted by date descending (newest →
    /// oldest) so within-kind Tab tracks the visible clockwise arc.
    /// Focal-pane kinds (`.correspondent` / `.mainEmail`) stay pinned
    /// ahead of the ring body — defensive in case a future factory
    /// introduces such an item. Items whose kind isn't one of the four
    /// ring-bucket kinds (very rare in practice) append after the
    /// buckets in their natural sort order so they remain reachable via
    /// Tab.
    nonisolated static func sortedPeopleFocusItems(_ items: [AnnotationItem]) -> [AnnotationItem] {
        let bucketOrder = AnnotationKind.peopleRingTraversalOrder
        let bucketIndex = Dictionary(
            uniqueKeysWithValues: bucketOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return items.sorted { lhs, rhs in
            if lhs.kind.isFocalPaneKind != rhs.kind.isFocalPaneKind {
                return lhs.kind.isFocalPaneKind
            }
            let lhsBucket = bucketIndex[lhs.kind] ?? bucketOrder.count
            let rhsBucket = bucketIndex[rhs.kind] ?? bucketOrder.count
            if lhsBucket != rhsBucket {
                return lhsBucket < rhsBucket
            }
            switch (lhs.badgeSortDate, rhs.badgeSortDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    /// People-focus pure-chronological walk: oldest → newest across every
    /// ring item, ignoring kind buckets. Used by the Option+Tab traversal
    /// so the user can step strictly along the time axis (oldest first)
    /// or strictly backward in time (Option+Shift+Tab). Focal-pane kinds
    /// stay pinned ahead of the chronological body for the same defensive
    /// reason as `sortedPeopleFocusItems`.
    nonisolated static func chronologicalPeopleFocusItems(_ items: [AnnotationItem]) -> [AnnotationItem] {
        items.sorted { lhs, rhs in
            if lhs.kind.isFocalPaneKind != rhs.kind.isFocalPaneKind {
                return lhs.kind.isFocalPaneKind
            }
            switch (lhs.badgeSortDate, rhs.badgeSortDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    nonisolated static func sortedKinds(
        _ kinds: [AnnotationKind],
        rankedItems: [AnnotationItem]
    ) -> [AnnotationKind] {
        var firstRankByKind: [AnnotationKind: Int] = [:]
        for (offset, item) in rankedItems.enumerated() where firstRankByKind[item.kind] == nil {
            firstRankByKind[item.kind] = offset
        }

        return kinds.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs.isFocalPaneKind { return true }
            if rhs.isFocalPaneKind { return false }

            let lhsRank = firstRankByKind[lhs]
            let rhsRank = firstRankByKind[rhs]
            switch (lhsRank, rhsRank) {
            case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.rawValue < rhs.rawValue
        }
    }

    private nonisolated static func itemPrecedes(_ lhs: AnnotationItem, _ rhs: AnnotationItem) -> Bool {
        if lhs.kind == .attachment, rhs.kind != .attachment {
            return true
        }
        if rhs.kind == .attachment, lhs.kind != .attachment {
            return false
        }

        let lhsKey = relevanceKey(for: lhs)
        let rhsKey = relevanceKey(for: rhs)
        if lhsKey.primary != rhsKey.primary {
            return lhsKey.primary > rhsKey.primary
        }
        if lhsKey.secondary != rhsKey.secondary {
            return lhsKey.secondary > rhsKey.secondary
        }
        if lhs.kind.priority != rhs.kind.priority {
            return lhs.kind.priority < rhs.kind.priority
        }
        return lhs.id < rhs.id
    }

    nonisolated static func peopleItemPrecedes(_ lhs: AnnotationItem, _ rhs: AnnotationItem) -> Bool {
        switch (lhs.badgeSortDate, rhs.badgeSortDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return itemPrecedes(lhs, rhs)
        }
    }

    private nonisolated static func relevanceKey(for item: AnnotationItem) -> (primary: Double, secondary: Double) {
        if let affinity = item.radialAffinity, affinity.isFinite {
            return (affinity, finite(item.importance))
        }
        return (finite(item.importance), 0)
    }

    private nonisolated static func finite(_ value: Double) -> Double {
        value.isFinite ? value : -.infinity
    }
}

private extension AnnotationKind {
    nonisolated var isFocalPaneKind: Bool {
        self == .mainEmail || self == .correspondent
    }
}
