import AppKit
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ProjectDeletionConfirmation: Equatable, Sendable {
    let title: String
    let message: String
    let confirmationTitle: String

    init(displayName: String, memberCount: Int) {
        title = "Delete “\(displayName)”?"
        let noun = memberCount == 1 ? "message" : "messages"
        message = "\(memberCount) \(noun) will be removed from this project. Source email and shared metadata will not be deleted."
        confirmationTitle = "Delete Project"
    }
}

@MainActor
struct ProjectsContextMenu {
    enum RowCommandKind: Equatable, Sendable {
        case configure
        case rename
        case setPinned(Bool)
        case setResolved(Bool)
        case delete
    }

    struct RowCommand: Equatable, Sendable {
        let kind: RowCommandKind
        let title: String
        let symbolName: String
    }

    struct RowContext {
        let row: ProjectRow
        let onConfigure: () -> Void
        let onRename: () -> Void
        let onSetPinned: (Bool) -> Void
        let onSetResolved: (Bool) -> Void
        let onDelete: () -> Void
    }

    nonisolated static func rowCommands(for row: ProjectRow) -> [RowCommand] {
        [
            RowCommand(kind: .configure, title: "Configure…", symbolName: "slider.horizontal.3"),
            RowCommand(kind: .rename, title: "Rename Project", symbolName: "pencil"),
            RowCommand(
                kind: .setPinned(!row.isPinned),
                title: row.isPinned ? "Unpin" : "Pin",
                symbolName: row.isPinned ? "pin.slash" : "pin"
            ),
            RowCommand(
                kind: .setResolved(!row.isResolvedEffective),
                title: row.isResolvedEffective ? "Reopen" : "Resolve",
                symbolName: row.isResolvedEffective ? "arrow.uturn.backward" : "checkmark.circle"
            ),
            RowCommand(kind: .delete, title: "Delete Project…", symbolName: "trash"),
        ]
    }

    static func presentRow(at point: NSPoint, in view: NSView, context: RowContext) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for command in rowCommands(for: context.row) {
            if command.kind == .delete {
                menu.addItem(.separator())
            }
            menu.addItem(ProjectsActionMenuItem(
                title: command.title,
                symbolName: command.symbolName
            ) {
                switch command.kind {
                case .configure:
                    context.onConfigure()
                case .rename:
                    context.onRename()
                case .setPinned(let pinned):
                    context.onSetPinned(pinned)
                case .setResolved(let resolved):
                    context.onSetResolved(resolved)
                case .delete:
                    context.onDelete()
                }
            })
        }

        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private final class ProjectsActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbolName: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        self.image?.isTemplate = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ProjectsActionMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}
