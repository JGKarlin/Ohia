// NewStarDockBadge.swift
// Renders the unvisited-arrival count onto the macOS Dock tile.
//
// `NewMailArrivalLedger` is the ONLY writer (via its dock-badge mirror).
// There are deliberately no increment/ensure helpers: ad-hoc writers are
// how the dock tile and the starburst badge drifted apart.

import AppKit

@MainActor
enum NewStarDockBadge {
    static func update(count: Int) {
        NSApplication.shared.dockTile.badgeLabel = label(for: count)
    }

    static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
}
