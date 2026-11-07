// Ohia/ConstellationMode/QA/CitationHighlighter.swift
import Foundation
import OhiaCore

/// Membership tracker for nodes the user is actively working with —
/// Q&A citations and fly-to targets (new-star visits, notification
/// focus). Marked ids are force-included in the render packet past
/// aperture culling via `buildAlwaysInclude`; the visible pulse on
/// cited/searched nodes is rendered shader-side from the packet's
/// per-star signal channels, so membership carries no animation state.
///
/// Membership is NOT refcounted: a vectorId marked by two owners (e.g.
/// a live citation that is also a fly-to target) is dropped by the
/// first `remove`. Every consumer must therefore keep an independent
/// source of truth — citations do (`qaVM.citationVectorIds` is unioned
/// into the render request separately), and any future owner must too.
@MainActor
public final class CitationHighlighter {

    public private(set) var vectorIds: Set<Int64> = []

    public func mark(vectorIds ids: [Int64]) {
        vectorIds.formUnion(ids)
    }

    public func remove(vectorIds ids: [Int64]) {
        vectorIds.subtract(ids)
    }
}
