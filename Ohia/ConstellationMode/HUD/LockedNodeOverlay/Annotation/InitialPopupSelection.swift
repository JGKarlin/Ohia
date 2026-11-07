import Foundation

struct InitialPopupSelection {
    func select(items: [AnnotationItem], autoOpenThreadSiblings: Bool) -> Set<String> {
        Set(selectOrdered(items: items, autoOpenThreadSiblings: autoOpenThreadSiblings))
    }

    func selectOrdered(
        items: [AnnotationItem],
        autoOpenThreadSiblings: Bool,
        limit: Int = 2
    ) -> [String] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }

        let candidates = items
            .filter { autoOpenThreadSiblings || !Self.isThreadSiblingKind($0.kind) }
            .sorted(by: importanceSort)

        var ids: [String] = []
        for item in candidates {
            if !ids.contains(item.id) {
                ids.append(item.id)
            }
            if ids.count == limit { break }
        }
        return ids
    }

    private func importanceSort(_ lhs: AnnotationItem, _ rhs: AnnotationItem) -> Bool {
        if lhs.importance != rhs.importance {
            return lhs.importance > rhs.importance
        }
        if lhs.kind.priority != rhs.kind.priority {
            return lhs.kind.priority < rhs.kind.priority
        }
        return lhs.id < rhs.id
    }

    private static func isThreadSiblingKind(_ kind: AnnotationKind) -> Bool {
        kind == .thread || kind == .reply
    }
}
