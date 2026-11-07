import AppKit

/// Right-click menu for a Meaning-lens cluster orb. Mirrors the lightweight
/// closure-driven `NSMenu` pattern used by `ProjectsContextMenu`: a disabled
/// title header followed by a single filter / remove action keyed off whether
/// the cluster is already in scope. Engaging respects every other active
/// ConstellationTopBar filter because it only sets `VectorFilter.clusterIds`,
/// which is AND-ed with the rest of the filter at render time.
enum MeaningClusterContextMenu {
    @MainActor
    static func present(
        at point: NSPoint,
        in view: NSView,
        title: String,
        isActive: Bool,
        onFilter: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if isActive {
            let removeItem = MeaningClusterActionMenuItem(
                title: "Remove Cluster Filter",
                action: onRemove
            )
            removeItem.state = .on
            menu.addItem(removeItem)
        } else {
            menu.addItem(
                MeaningClusterActionMenuItem(
                    title: "Filter to This Cluster",
                    action: onFilter
                )
            )
        }

        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private final class MeaningClusterActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for MeaningClusterActionMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}
