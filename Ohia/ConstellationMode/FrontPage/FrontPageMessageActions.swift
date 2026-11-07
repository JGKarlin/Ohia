import AppKit
import OhiaCore

/// Closures the Front Page UI calls to act on individual messages. Implemented
/// by `ConstellationModeView`, which owns the model context, the mutation
/// dispatcher, and the shared `ProjectLensActionRepository`. Single-message
/// affordances (a card's hover icons, the reader context menu) pass `[id]`; the
/// right control column and the bulk right-click menu pass the whole selection.
///
/// Every closure has a no-op default so SwiftUI previews and tests can mount the
/// Front Page views without wiring the host. The closures are created in
/// `ConstellationModeView`'s main-actor context and inherit that isolation
/// (non-`Sendable`), so they may call main-actor mutation paths synchronously —
/// the same pattern `ConstellationNodeContextMenu.Context` uses.
struct FrontPageMessageActionHandlers {
    /// Present the single-message right-click `NSMenu` (full action parity with
    /// the Projects lens message menu) at `point` in `view`.
    var presentMenu: (UUID, NSPoint, NSView) -> Void = { _, _, _ in }
    /// Present the collapsed-package right-click `NSMenu`, where project
    /// membership applies to the represented thread rather than one member.
    var presentThreadMenu: (UUID, NSPoint, NSView) -> Void = { _, _, _ in }
    /// Present the bulk right-click `NSMenu` for a multi-selection.
    var presentBulkMenu: ([UUID], NSPoint, NSView) -> Void = { _, _, _ in }
    /// Mark messages read / unread. The focused reader uses this to flip an
    /// unread message to read on entry; context menus retain the manual toggle.
    var setRead: ([UUID], Bool) -> Void = { _, _ in }
    /// Flag / unflag every message — the caller resolves the target value.
    var setFlagged: ([UUID], Bool) -> Void = { _, _ in }
    /// Move messages to the account Junk / Spam mailbox.
    var markAsSpam: ([UUID]) -> Void = { _ in }
    /// Mark messages as needing a reply / clear that manual needed marker.
    var setReplyNeeded: ([UUID], Bool) -> Void = { _, _ in }
    /// Explicitly add needs-reply messages to the Composer queue.
    var sendToComposer: ([UUID]) -> Void = { _ in }
    /// Mark messages replied / unreplied (shared message attention state).
    var setReplied: ([UUID], Bool) -> Void = { _, _ in }
    /// Mark messages as needing confirmation / clear that manual needed marker.
    var setConfirmationNeeded: ([UUID], Bool) -> Void = { _, _ in }
    /// Mark messages confirmed / unconfirmed (shared message attention state).
    var setConfirmed: ([UUID], Bool) -> Void = { _, _ in }
    /// Mark messages resolved / reopen them from the Front Page message feed.
    var setResolved: ([UUID], Bool) -> Void = { _, _ in }
    /// Delete messages. The handler runs its own destructive confirmation
    /// alert and the post-delete refresh, so callers do not gate on it.
    var delete: ([UUID]) -> Void = { _ in }
    /// Review and create a list-scoped ignore rule for one eligible message.
    /// The review sheet owns confirmation, so callers should not animate or
    /// remove the message before invoking this closure.
    var ignore: (UUID) -> Void = { _ in }
    /// Replace a message's canonical classification plus its independent
    /// custom-key set from an axis-native manual editor.
    var setClassification: (UUID, MailClassification?, Set<String>) -> Void = { _, _, _ in }
    /// The same mutation with an explicit persistence result. Focused
    /// Projects waits for this result before reconciling structural
    /// membership or beginning a departure animation.
    var setClassificationAndReportSuccess: (UUID, MailClassification?, Set<String>) -> Bool = { _, _, _ in false }
    /// Whether the native Undo stack can restore the category edit that just
    /// ran. Focused Projects uses this to avoid offering a false Undo button.
    var canUndoClassification: (UUID) -> Bool = { _ in false }
    /// Performs the semantic category Undo registered by the shared host.
    var undoClassification: (UUID) -> Bool = { _ in false }
    /// Awaitable exact-message reconciliation used by focused Projects before
    /// deciding whether the edited message departed its project.
    var reconcileProjectMembership: (UUID) async -> Void = { _ in }
}

/// Builder for the bulk right-click `NSMenu` shown when the user right-clicks a
/// card that is part of a multi-card selection. Mirrors
/// `ProjectsContextMenu.presentBulk`: every item carries the exact count, and
/// mixed states (some flagged, some not) resolve to the action that flips the
/// majority so a single click always changes something. The target booleans and
/// applicability are resolved by `ConstellationModeView` (which holds the
/// messages) and baked into the context.
@MainActor
struct FrontPageBulkMessageMenu {
    struct Context {
        let count: Int
        /// `true` → menu offers "Mark N as Read" (sets read); `false` → "Mark
        /// N as Unread".
        let readTargetValue: Bool
        /// `true` → menu offers "Flag N" (flags); `false` → "Unflag N".
        let flagTargetValue: Bool
        let replyActionTitle: String
        let composerActionTitle: String?
        /// Title for the ⌥ alternate of the composer item ("Open N in Composer").
        /// `nil` keeps the alternate off (e.g. nothing to queue).
        let composerOpenActionTitle: String?
        let confirmationActionTitle: String
        let onSetRead: (Bool) -> Void
        let onSetFlagged: (Bool) -> Void
        let onMarkAsSpam: () -> Void
        let onReplyAction: () -> Void
        let onComposerAction: () -> Void
        /// ⌥ alternate: queue the selection AND bring the Composer to the front.
        let onComposerActionAndOpen: () -> Void
        let onConfirmationAction: () -> Void
        let onMarkResolved: () -> Void
        let onDelete: () -> Void
    }

    static func present(at point: NSPoint, in view: NSView, context ctx: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let noun = ctx.count == 1 ? "message" : "messages"
        let header = NSMenuItem(title: "\(ctx.count) \(noun) selected", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let readItem = FrontPageBulkMenuItem(
            title: ctx.readTargetValue ? "Mark \(ctx.count) as Read" : "Mark \(ctx.count) as Unread"
        ) { ctx.onSetRead(ctx.readTargetValue) }
        readItem.image = frontPageMenuImage(systemSymbolName: ctx.readTargetValue ? "envelope.open" : "envelope.badge")
        menu.addItem(readItem)

        let flagItem = FrontPageBulkMenuItem(
            title: ctx.flagTargetValue ? "Flag \(ctx.count)" : "Unflag \(ctx.count)"
        ) { ctx.onSetFlagged(ctx.flagTargetValue) }
        flagItem.image = frontPageMenuImage(systemSymbolName: ctx.flagTargetValue ? "flag" : "flag.slash")
        menu.addItem(flagItem)

        let spamItem = FrontPageBulkMenuItem(title: "Mark \(ctx.count) as spam") { ctx.onMarkAsSpam() }
        spamItem.image = frontPageMenuImage(systemSymbolName: "xmark.bin")
        menu.addItem(spamItem)

        let replyItem = FrontPageBulkMenuItem(title: ctx.replyActionTitle) { ctx.onReplyAction() }
        replyItem.image = frontPageMenuImage(
            systemSymbolName: ctx.replyActionTitle.contains("Replied")
                ? "arrowshape.turn.up.left.fill"
                : "arrowshape.turn.up.left"
        )
        menu.addItem(replyItem)
        if let composerActionTitle = ctx.composerActionTitle {
            // Default item queues only; the ⌥ alternate ("Open N in Composer")
            // queues AND fronts the Composer. Same empty key equivalent, differing
            // only by modifier mask — the AppKit Option-alternate idiom.
            let composerItem = FrontPageBulkMenuItem(title: composerActionTitle) { ctx.onComposerAction() }
            composerItem.image = frontPageMenuImage(systemSymbolName: "square.and.pencil")
            composerItem.keyEquivalentModifierMask = []
            menu.addItem(composerItem)
            if let composerOpenActionTitle = ctx.composerOpenActionTitle {
                let openItem = FrontPageBulkMenuItem(title: composerOpenActionTitle) { ctx.onComposerActionAndOpen() }
                openItem.image = frontPageMenuImage(systemSymbolName: "square.and.pencil")
                openItem.keyEquivalentModifierMask = [.option]
                openItem.isAlternate = true
                menu.addItem(openItem)
            }
        }
        let confirmationItem = FrontPageBulkMenuItem(title: ctx.confirmationActionTitle) { ctx.onConfirmationAction() }
        // "Confirmed" and "Unconfirmed" are both the confirmation axis (seal);
        // only "Confirmation Needed" reads as the unresolved question mark. The
        // dedicated "Mark N Resolved" item below owns the circle-check.
        confirmationItem.image = frontPageMenuImage(
            systemSymbolName: ctx.confirmationActionTitle.contains("onfirmed")
                ? "checkmark.seal"
                : "questionmark.circle"
        )
        menu.addItem(confirmationItem)

        let resolvedItem = FrontPageBulkMenuItem(title: "Mark \(ctx.count) Resolved") { ctx.onMarkResolved() }
        resolvedItem.image = frontPageMenuImage(systemSymbolName: "checkmark.circle")
        menu.addItem(resolvedItem)

        menu.addItem(.separator())
        let deleteItem = FrontPageBulkMenuItem(title: "Delete \(ctx.count)…") { ctx.onDelete() }
        deleteItem.keyEquivalent = "\u{8}"     // backspace
        deleteItem.keyEquivalentModifierMask = [.command]
        deleteItem.image = frontPageMenuImage(systemSymbolName: "trash")
        menu.addItem(deleteItem)

        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private func frontPageMenuImage(systemSymbolName: String) -> NSImage? {
    guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil) else {
        return nil
    }
    image.isTemplate = true
    return image
}

/// `NSMenuItem` subclass that retains a Swift closure target (default
/// `NSMenuItem` requires an Objective-C selector). Mirrors the private
/// `ActionMenuItem` in `ConstellationNodeContextMenu`.
private final class FrontPageBulkMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for FrontPageBulkMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}

extension FrontPageMessageActionHandlers {
    /// Returns handlers that begin the matching status gesture before performing
    /// the real mutation, so the Front Page shows an immediate, action-typed
    /// response (and a masking card exit) while the snapshot rebuilds. Wrapping
    /// here covers both the per-card hover cluster and the right control column,
    /// since both call these closures on the affected message ids.
    ///
    /// Every command dispatches the instant it is pressed — message ids are
    /// captured at press time and the coordinator plays concurrent per-message
    /// gestures, so an action on one card during another card's exit animation
    /// responds immediately instead of waiting for the page to settle.
    ///
    /// Delete and ignore are NOT begun here: delete runs a destructive
    /// confirmation alert (an optimistic gesture would leave a red-collapse
    /// overlay lingering on cancel) and ignore opens its review sheet. Their
    /// hosts begin the cue only after confirmation and successful dispatch, so
    /// they pass through unwrapped.
    @MainActor
    func beginningStatusGestures(
        with coordinator: MessageStatusGestureCoordinator
    ) -> FrontPageMessageActionHandlers {
        var handlers = self
        let base = self
        handlers.setResolved = { ids, value in
            if value { coordinator.begin(.resolve, for: ids) }
            base.setResolved(ids, value)
        }
        handlers.setReplied = { ids, value in
            if value { coordinator.begin(.markReplied, for: ids) }
            base.setReplied(ids, value)
        }
        handlers.setReplyNeeded = { ids, value in
            if value { coordinator.begin(.replyNeeded, for: ids) }
            base.setReplyNeeded(ids, value)
        }
        handlers.setConfirmed = { ids, value in
            if value { coordinator.begin(.markConfirmed, for: ids) }
            base.setConfirmed(ids, value)
        }
        handlers.setConfirmationNeeded = { ids, value in
            if value { coordinator.begin(.confirmationNeeded, for: ids) }
            base.setConfirmationNeeded(ids, value)
        }
        handlers.setFlagged = { ids, value in
            coordinator.begin(.flag(raising: value), for: ids)
            base.setFlagged(ids, value)
        }
        return handlers
    }
}
