import AppKit
import OhiaMail

struct WithheldMessageActionHandlers {
    var restore: ([WithheldRow]) -> Void = { _ in }
    var selectAll: () -> Void = {}
    var setRead: ([WithheldRow], Bool) -> Void = { _, _ in }
    var deletePermanently: ([WithheldRow]) -> Void = { _ in }
}

@MainActor
struct WithheldMessageContextMenu {
    struct Context {
        let rows: [WithheldRow]
        let onRestore: () -> Void
        let onSelectAll: () -> Void
        let onSetRead: (Bool) -> Void
        let onDeletePermanently: () -> Void
    }

    static func present(at point: NSPoint, in view: NSView, context ctx: Context) {
        guard !ctx.rows.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if ctx.rows.count > 1 {
            let header = NSMenuItem(
                title: "\(ctx.rows.count) withheld emails selected",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        let restoreItem = WithheldMenuItem(title: restoreTitle(for: ctx.rows), action: ctx.onRestore)
        restoreItem.image = menuImage(systemSymbolName: restoreIcon(for: ctx.rows))
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let selectAllItem = WithheldMenuItem(title: "Select All", action: ctx.onSelectAll)
        selectAllItem.keyEquivalent = "a"
        selectAllItem.keyEquivalentModifierMask = [.command]
        selectAllItem.image = menuImage(systemSymbolName: "checklist")
        menu.addItem(selectAllItem)

        let targetReadValue = ctx.rows.contains { !$0.isRead }
        let readItem = WithheldMenuItem(title: readTitle(count: ctx.rows.count, targetReadValue: targetReadValue)) {
            ctx.onSetRead(targetReadValue)
        }
        readItem.keyEquivalent = "u"
        readItem.keyEquivalentModifierMask = [.command, .shift]
        readItem.image = menuImage(systemSymbolName: targetReadValue ? "envelope.open" : "envelope.badge")
        menu.addItem(readItem)

        menu.addItem(.separator())

        let deleteItem = WithheldMenuItem(
            title: deleteTitle(count: ctx.rows.count),
            action: ctx.onDeletePermanently
        )
        deleteItem.keyEquivalent = "\u{8}"
        deleteItem.keyEquivalentModifierMask = [.command, .option]
        deleteItem.image = menuImage(systemSymbolName: "trash.slash")
        menu.addItem(deleteItem)

        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func restoreTitle(for rows: [WithheldRow]) -> String {
        guard rows.count == 1, let row = rows.first else {
            return "Restore \(rows.count) to Inbox"
        }
        return row.folder == .junk ? "Not Junk" : "Restore"
    }

    private static func restoreIcon(for rows: [WithheldRow]) -> String {
        guard rows.count == 1, rows.first?.folder == .junk else {
            return "arrow.uturn.backward"
        }
        return "tray.and.arrow.down"
    }

    private static func readTitle(count: Int, targetReadValue: Bool) -> String {
        if count == 1 {
            return targetReadValue ? "Mark as Read" : "Mark as Unread"
        }
        return targetReadValue ? "Mark \(count) as Read" : "Mark \(count) as Unread"
    }

    private static func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete Permanently…" : "Delete \(count) Permanently…"
    }
}

private func menuImage(systemSymbolName: String) -> NSImage? {
    guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil) else {
        return nil
    }
    image.isTemplate = true
    return image
}

private final class WithheldMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for WithheldMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}
