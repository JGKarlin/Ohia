import Foundation
import OhiaCore

nonisolated enum PeopleFrameFilterPolicy {
    static func visualFilter(frame: FrameKey, filter: VectorFilter) -> VectorFilter {
        guard frame.spatialLens == .people else { return filter }
        var visualFilter = filter
        visualFilter.correspondentQuery = ""
        return visualFilter
    }

    static func focus(
        frame: FrameKey,
        filter: VectorFilter,
        expandsToOneHop: Bool = false
    ) -> PeopleFrameFocus? {
        guard frame.spatialLens == .people else { return nil }
        let query = filter.correspondentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return PeopleFrameFocus(
            query: query,
            scopes: filter.correspondentScopes,
            expandsToOneHop: expandsToOneHop
        )
    }
}
