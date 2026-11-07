import Foundation

struct LongThreadClassifier {
    func visibleFullPopupIDs<T: Collection>(
        siblings: T,
        id: (T.Element) -> String,
        position: (T.Element) -> Int
    ) -> Set<String> {
        let sorted = siblings.sorted {
            abs(position($0)) == abs(position($1))
                ? position($0) < position($1)
                : abs(position($0)) < abs(position($1))
        }
        return Set(sorted.filter { abs(position($0)) <= 2 }.prefix(4).map(id))
    }
}
