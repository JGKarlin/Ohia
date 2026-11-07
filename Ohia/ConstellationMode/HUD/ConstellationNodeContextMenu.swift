import AppKit
import SwiftData
import OhiaCore
import OhiaScheduler

/// Builder for the right-click NSMenu that appears when the user
/// right-clicks a node in the Constellation scene. Sections:
///
/// 1. Send to Composer, when applicable
/// 2. Lens-specific message actions, when supplied
/// 3. Add message / thread to an active project
/// 4. Mark as Read / Unread (mirrors IMAP `\Seen` via MailboxMutation)
/// 5. Flag / Unflag (mirrors IMAP `\Flagged` via MailboxMutation)
/// 6. Mark as spam — moves the message to the account Junk / Spam mailbox
/// 7. Category — one flat list of shared and user-created categories.
/// 8. Delete… — moves the message to the account Trash mailbox.
@MainActor
struct ConstellationNodeContextMenu {

    struct ProjectDestination {
        let id: UUID
        let title: String
        let isPinned: Bool
        let pinSortIndex: Int?
        let resolvedAt: Date?
        let isIncluded: Bool
        let action: () -> Void
    }

    /// Inputs the menu needs: the resolved Message + the closures that
    /// drive each action. The view doesn't need to know the dispatcher
    /// API — it hands in the closures it already has.
    ///
    /// `includeCopyAction` appends a "Copy" item for the complete email.
    /// Text selections are handled earlier by `TimelineEventCatcher`, which
    /// substitutes a selection-only menu before this card-wide menu is built.
    struct Context {
        struct ExtraItem {
            let title: String
            let state: NSControl.StateValue
            let systemSymbolName: String?
            let action: () -> Void

            init(
                title: String,
                state: NSControl.StateValue = .off,
                systemSymbolName: String? = nil,
                action: @escaping () -> Void
            ) {
                self.title = title
                self.state = state
                self.systemSymbolName = systemSymbolName
                self.action = action
            }
        }

        /// One user-defined category row in the Categories submenu. The
        /// title carries collecting progress ("Surf Trips (3 of 6
        /// examples)") so tagging examples reads as measurable progress
        /// toward activation.
        struct CustomCategoryEntry {
            let key: String
            let title: String
            let isChecked: Bool
        }

        let message: Message
        let currentClassification: MailClassification?
        let onSetRead: (Bool) -> Void
        let onSetFlagged: (Bool) -> Void
        /// Composer queue action for this message. Visible whenever the message
        /// is composer-relevant — it still needs a reply, or it is already in the
        /// queue. When not yet queued the item adds it ("Send to Composer"); when
        /// already queued it navigates instead ("Open in Composer"), since the
        /// draft is already being prepared.
        var composerQueueActionVisible: Bool = false
        var composerQueueActionEnabled: Bool = true
        /// True when the message is already in the Composer queue, which flips the
        /// item from the add action to the open-in-Composer navigation.
        var composerQueueActionIsQueued: Bool = false
        var onSendToComposer: () -> Void = {}
        /// The ⌥-modified "Open in Composer" variant: queue the message AND bring
        /// the Composer window to the front. Shown as an Option alternate beneath
        /// the plain "Send to Composer" item when the message is not yet queued.
        var onSendToComposerAndOpen: () -> Void = {}
        var onOpenInComposer: () -> Void = {}
        var messageProjectDestinations: [ProjectDestination]? = []
        var threadProjectDestinations: [ProjectDestination]? = nil
        let onSetPurpose: (MailPurpose) -> Void
        var customCategories: [CustomCategoryEntry] = []
        var onToggleCustomCategory: (String) -> Void = { _ in }
        let onMarkAsSpam: () -> Void
        let onDelete: () -> Void
        var includeCopyAction: Bool = false
        var extraItems: [ExtraItem] = []
    }

    /// Build the NSMenu and pop it up at `point` (in `view`'s NSView
    /// coordinate space). The closures are retained on the menu items
    /// so they survive past the call.
    static func present(at point: NSPoint, in view: NSView, context ctx: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let composerItems = makeComposerQueueItems(context: ctx)
        if !composerItems.isEmpty {
            composerItems.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

        if !ctx.extraItems.isEmpty {
            for extra in ctx.extraItems {
                let item = ActionMenuItem(title: extra.title, action: extra.action)
                item.state = extra.state
                item.image = menuImage(systemSymbolName: extra.systemSymbolName)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        for item in projectItems(
            messageDestinations: ctx.messageProjectDestinations,
            threadDestinations: ctx.threadProjectDestinations
        ) {
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 4. Mark Read / Unread. The title snapshot is fine — the menu
        // is only on screen for milliseconds — but the action re-reads
        // the message to avoid a stale flip if a background IMAP poll
        // changed `\Seen` while the menu was open.
        let isReadAtBuild = ctx.message.isReadOrFalse
        let toggleReadTitle = isReadAtBuild ? "Mark as Unread" : "Mark as Read"
        let toggleReadItem = ActionMenuItem(title: toggleReadTitle) {
            [message = ctx.message, onSetRead = ctx.onSetRead] in
            onSetRead(!message.isReadOrFalse)
        }
        toggleReadItem.keyEquivalent = "u"
        toggleReadItem.keyEquivalentModifierMask = [.command, .shift]
        toggleReadItem.image = menuImage(systemSymbolName: isReadAtBuild ? "envelope.badge" : "envelope.open")
        menu.addItem(toggleReadItem)

        // 5. Flag / Unflag. Same stale-snapshot guard as Mark Read.
        let isFlaggedAtBuild = ctx.message.flaggedOrFalse
        let toggleFlagTitle = isFlaggedAtBuild ? "Unflag" : "Flag"
        let toggleFlagItem = ActionMenuItem(title: toggleFlagTitle) {
            [message = ctx.message, onSetFlagged = ctx.onSetFlagged] in
            onSetFlagged(!message.flaggedOrFalse)
        }
        toggleFlagItem.keyEquivalent = "l"
        toggleFlagItem.keyEquivalentModifierMask = [.command, .shift]
        toggleFlagItem.image = menuImage(systemSymbolName: isFlaggedAtBuild ? "flag.slash" : "flag")
        menu.addItem(toggleFlagItem)

        let spamItem = ActionMenuItem(title: "Mark as spam", action: ctx.onMarkAsSpam)
        spamItem.image = menuImage(systemSymbolName: "xmark.bin")
        menu.addItem(spamItem)

        menu.addItem(.separator())

        // 7. Flat shared and user-created category submenu.
        let catParent = NSMenuItem(title: "Category", action: nil, keyEquivalent: "")
        catParent.image = menuImage(systemSymbolName: "tag")
        let catSubmenu = NSMenu()
        catSubmenu.autoenablesItems = false

        for purpose in MailPurpose.allCases {
            let item = ActionMenuItem(title: purpose.displayLabel) { ctx.onSetPurpose(purpose) }
            item.state = ctx.currentClassification?.purpose == purpose ? .on : .off
            item.image = menuImage(systemSymbolName: purpose.systemImageName)
            catSubmenu.addItem(item)
        }
        // User-defined categories follow the fixed taxonomy after a
        // separator. Toggling a collecting category tags / untags this
        // message as a training example; toggling an active one is plain
        // assignment. Categories are created and removed from the
        // toolbar's Category pulldown.
        if !ctx.customCategories.isEmpty {
            catSubmenu.addItem(.separator())
            for entry in ctx.customCategories {
                let item = ActionMenuItem(title: entry.title) {
                    [key = entry.key, onToggle = ctx.onToggleCustomCategory] in
                    onToggle(key)
                }
                item.state = entry.isChecked ? .on : .off
                item.image = NSImage(
                    systemSymbolName: ToggleIconography.customCategorySymbolName,
                    accessibilityDescription: nil
                )
                catSubmenu.addItem(item)
            }
        }
        catParent.submenu = catSubmenu
        menu.addItem(catParent)

        menu.addItem(.separator())

        // 8. Delete (destructive)
        let deleteItem = ActionMenuItem(title: "Delete…", action: ctx.onDelete)
        deleteItem.keyEquivalent = "\u{8}"     // backspace
        deleteItem.keyEquivalentModifierMask = [.command]
        deleteItem.image = menuImage(systemSymbolName: "trash")
        menu.addItem(deleteItem)

        // 9. Copy — card-wide menus always copy the complete formatted email.
        // The selection-only path is intercepted before this presenter runs,
        // so this action must not depend on whichever view happens to be the
        // current responder.
        if ctx.includeCopyAction {
            menu.addItem(.separator())
            menu.addItem(copyItem(for: ctx.message))
        }

        menu.popUp(positioning: nil, at: point, in: view)
    }

    static func projectItems(
        messageDestinations: [ProjectDestination]?,
        threadDestinations: [ProjectDestination]?
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let messageDestinations {
            items.append(projectParentItem(
                title: "Add Message to Project",
                systemSymbolName: "folder.badge.plus",
                destinations: messageDestinations
            ))
        }
        if let threadDestinations {
            items.append(
                projectParentItem(
                    title: "Add Thread to Project",
                    systemSymbolName: "text.bubble.badge.plus",
                    destinations: threadDestinations
                )
            )
        }
        return items
    }

    static func copyItem(
        for message: Message,
        pasteboard: NSPasteboard = .general
    ) -> NSMenuItem {
        let item = ActionMenuItem(title: "Copy") {
            pasteboard.clearContents()
            pasteboard.setString(formatMessageForCopy(message), forType: .string)
        }
        item.keyEquivalent = "c"
        item.keyEquivalentModifierMask = [.command]
        item.image = menuImage(systemSymbolName: "doc.on.doc")
        return item
    }

    private static func projectParentItem(
        title: String,
        systemSymbolName: String,
        destinations: [ProjectDestination]
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = menuImage(systemSymbolName: systemSymbolName)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let activeDestinations = destinations
            .filter { $0.resolvedAt == nil }
            .sorted(by: projectDestinationOrder)
        if activeDestinations.isEmpty {
            let emptyItem = NSMenuItem(title: "No active projects", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for destination in activeDestinations {
                let item = ActionMenuItem(title: destination.title, action: destination.action)
                item.state = destination.isIncluded ? .on : .off
                item.isEnabled = !destination.isIncluded
                item.image = menuImage(systemSymbolName: "folder")
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        return parent
    }

    private static func projectDestinationOrder(
        _ lhs: ProjectDestination,
        _ rhs: ProjectDestination
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.isPinned {
            let leftPin = lhs.pinSortIndex ?? .max
            let rightPin = rhs.pinSortIndex ?? .max
            if leftPin != rightPin { return leftPin < rightPin }
        }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func makeComposerQueueItems(context ctx: Context) -> [NSMenuItem] {
        guard ctx.composerQueueActionVisible else { return [] }

        // Already queued → jump to the Composer focused on this message rather
        // than re-adding it; the draft is already in flight.
        if ctx.composerQueueActionIsQueued {
            let openItem = ActionMenuItem(title: "Open in Composer") {
                [onOpenInComposer = ctx.onOpenInComposer] in
                onOpenInComposer()
            }
            openItem.image = menuImage(systemSymbolName: "square.and.pencil")
            return [openItem]
        }

        // Not queued → two items differing only by the ⌥ modifier mask (the AppKit
        // idiom for an Option alternate). Each title tracks whether it fronts the
        // Composer, per `ComposerOpenOnQueuePreference` (default on) inverted by ⌥:
        // by default the plain item opens ("Open in Composer") and the ⌥ alternate
        // queues quietly ("Send to Composer"); the setting flips both.
        let primaryTitle = ComposerOpenOnQueuePreference.opensComposer(optionHeld: false)
            ? "Open in Composer" : "Send to Composer"
        let alternateTitle = ComposerOpenOnQueuePreference.opensComposer(optionHeld: true)
            ? "Open in Composer" : "Send to Composer"

        let sendItem = ActionMenuItem(title: primaryTitle) {
            [onSendToComposer = ctx.onSendToComposer] in
            onSendToComposer()
        }
        sendItem.isEnabled = ctx.composerQueueActionEnabled
        sendItem.image = menuImage(systemSymbolName: "square.and.pencil")
        sendItem.keyEquivalentModifierMask = []

        let openItem = ActionMenuItem(title: alternateTitle) {
            [onSendToComposerAndOpen = ctx.onSendToComposerAndOpen] in
            onSendToComposerAndOpen()
        }
        openItem.isEnabled = ctx.composerQueueActionEnabled
        openItem.image = menuImage(systemSymbolName: "square.and.pencil")
        openItem.keyEquivalentModifierMask = [.option]
        openItem.isAlternate = true

        return [sendItem, openItem]
    }
}

private func menuImage(systemSymbolName: String?) -> NSImage? {
    guard let systemSymbolName,
          let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    else { return nil }
    image.isTemplate = true
    return image
}

/// NSMenuItem subclass that retains its closure target. Default
/// NSMenuItem requires an Objective-C selector; this wraps a Swift
/// closure on the same object so the menu items stay self-contained.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ActionMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}

/// Render a `Message` as plain text suitable for the system pasteboard
/// when the user picks "Copy" with no text selection. Mirrors a
/// minimal RFC-5322 layout (header block → blank line → body) so a
/// paste into another mail client lands cleanly. Body source is the
/// canonical plain-text artifact at `bodyTextPath`; if that file is
/// missing or unreadable we fall back to just the headers so the
/// command never silently produces an empty pasteboard.
private func formatMessageForCopy(_ message: Message) -> String {
    var lines: [String] = []
    lines.append("Subject: \(message.subject.isEmpty ? "(no subject)" : message.subject)")

    let fromLine: String = {
        if let name = message.fromName, !name.isEmpty, !message.fromAddress.isEmpty {
            return "\(name) <\(message.fromAddress)>"
        }
        return message.fromAddress.isEmpty ? "(unknown)" : message.fromAddress
    }()
    lines.append("From: \(fromLine)")

    let recipients = message.participants
        .filter { $0.role == .to || $0.role == .cc || $0.role == .bcc }
        .compactMap { link -> (ParticipantRole, String)? in
            guard let participant = link.participant else { return nil }
            let label: String
            if let name = participant.displayName, !name.isEmpty, !participant.emailAddress.isEmpty {
                label = "\(name) <\(participant.emailAddress)>"
            } else if !participant.emailAddress.isEmpty {
                label = participant.emailAddress
            } else if let name = participant.displayName, !name.isEmpty {
                label = name
            } else {
                return nil
            }
            return (link.role, label)
        }
    let toList = recipients.filter { $0.0 == .to }.map(\.1)
    let ccList = recipients.filter { $0.0 == .cc }.map(\.1)
    let bccList = recipients.filter { $0.0 == .bcc }.map(\.1)
    if !toList.isEmpty { lines.append("To: \(toList.joined(separator: ", "))") }
    if !ccList.isEmpty { lines.append("Cc: \(ccList.joined(separator: ", "))") }
    if !bccList.isEmpty { lines.append("Bcc: \(bccList.joined(separator: ", "))") }

    if let date = message.vectorTimeFilterDate {
        lines.append("Date: \(dateFormatterForCopy.string(from: date))")
    }

    lines.append("")

    if let path = message.bodyTextPath,
       let body = try? String(contentsOfFile: path, encoding: .utf8),
       !body.isEmpty {
        lines.append(body)
    }

    return lines.joined(separator: "\n")
}

private let dateFormatterForCopy: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()
