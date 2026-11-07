// Ohia/Commands/AppCommandCenter.swift
// Shared dispatcher for menu bar and context menu commands.
// Views register handlers; menus post commands.

import Foundation
import SwiftUI
import OhiaCore

enum OhiaWindowID {
    static let constellation = "constellation"
    static let composer = "composer"
    static let compose = "Compose"
}

/// Builds and parses `ohia://message/<uuid>` deep links — a URL a user can
/// click from *outside* the app (e.g. the "Open in Ohia" line Ohia writes
/// into a synced calendar event's notes) to land on one specific email.
/// Registered as `CFBundleURLSchemes` in Info.plist; routed to
/// `AppCommand.requestDeepLinkTimelineFocus` from
/// `OhiaAppDelegate.application(_:open:)`.
enum OhiaDeepLink {
    static let scheme = "ohia"
    private static let messageHost = "message"

    static func messageURL(_ messageID: UUID) -> URL {
        // A UUID's string form is only hex digits and hyphens, both valid
        // unescaped in a URL host/path — this can never fail to parse.
        URL(string: "\(scheme)://\(messageHost)/\(messageID.uuidString)")!
    }

    static func messageID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == messageHost else {
            return nil
        }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: raw)
    }
}

/// Notification names for app-level commands invoked via the menu bar
/// or context menus. Views observe the ones relevant to them.
extension Notification.Name {
    // App lifecycle
    static let ohiaWillPrepareForTermination = Notification.Name("ohia.app.willPrepareForTermination")

    // Mode navigation
    static let ohiaShowConstellation = Notification.Name("ohia.showConstellation")
    static let ohiaShowFocus = Notification.Name("ohia.showFocus")
    static let ohiaShowComposer = Notification.Name("ohia.showComposer")
    static let ohiaCreateNewProject = Notification.Name("ohia.projects.createNew")
    static let ohiaConstellationShortcut = Notification.Name("ohia.constellationShortcut")
    static let ohiaComposerDismissNoReply = Notification.Name("ohia.composerDismissNoReply")
    /// Select a message inside the already-mounted Composer
    /// (userInfo["messageID"] = UUID) — avoids a session-destroying remount.
    static let ohiaComposerSelectMessage = Notification.Name("ohia.composerSelectMessage")
    /// Posted by ComposerView on appear/disappear (userInfo["active"] = Bool).
    /// RootView mirrors it into the shared app-activity snapshot so the
    /// generative worker grants the Composer foreground model priority.
    static let ohiaComposerSurfaceActive = Notification.Name("ohia.composerSurfaceActive")
    /// Posted by ComposerView whenever the open reply changes
    /// (userInfo["messageID"] = UUID; absent when no reply is open). RootView
    /// mirrors it into the shared app-activity snapshot so background passes
    /// never replace the body of a draft the editor may hold unsaved text for.
    static let ohiaComposerOpenReplyChanged = Notification.Name("ohia.composerOpenReplyChanged")
    /// Open the Subscriptions ledger (Settings → Lists).
    static let ohiaShowSubscriptions = Notification.Name("ohia.showSubscriptions")
    /// Scope the Constellation to one mailing list (userInfo["listId"] =
    /// canonical RFC 2919 list identity string, optional userInfo["accountID"]
    /// = account UUID).
    static let ohiaScopeConstellationToList = Notification.Name("ohia.scopeConstellationToList")
    static let ohiaNotificationMarkRead = Notification.Name("ohia.notification.markRead")

    // Outbox
    static let ohiaShowOutbox = Notification.Name("ohia.showOutbox")
    static let ohiaSendAllOutboxNow = Notification.Name("ohia.sendAllOutboxNow")

    // Withheld (Junk & Trash) drawer
    static let ohiaToggleWithheld = Notification.Name("ohia.toggleWithheld")

    // Account
    static let ohiaReauthenticateAccount = Notification.Name("ohia.reauthenticateAccount")

    // Training
    static let ohiaTrainingTrainNow = Notification.Name("ohia.training.trainNow")
    static let ohiaTrainingTogglePause = Notification.Name("ohia.training.togglePause")
    static let ohiaTrainingStop = Notification.Name("ohia.training.stop")
    static let ohiaOpenTrainingSettings = Notification.Name("ohia.training.openSettings")
    static let ohiaEnsureGenerativeWorker = Notification.Name("ohia.generative.ensureWorker")
    static let ohiaSelectGenerationModel = Notification.Name("ohia.generative.selectModel")
    static let ohiaCancelGenerationModelPreparation = Notification.Name("ohia.generative.cancelModelPreparation")
    static let ohiaPrepareOnboardingModels = Notification.Name("ohia.onboarding.prepareModels")

    // Compose
    static let ohiaComposeNew = Notification.Name("ohia.composeNew")
    /// Show the unpersisted new-message header in an already-mounted Composer.
    static let ohiaComposerBeginNewMessage = Notification.Name("ohia.composerBeginNewMessage")
    /// Select a compose draft inside the already-mounted Composer
    /// (userInfo["draftID"] = UUID) — the compose analogue of
    /// `ohiaComposerSelectMessage`.
    static let ohiaComposerSelectCompose = Notification.Name("ohia.composerSelectCompose")

    // Identities
    static let ohiaAddIdentityFromMenu = Notification.Name("ohia.addIdentityFromMenu")

    // Pipeline control (developer + future user-facing pause)
    static let ohiaPausePipeline = Notification.Name("ohia.pausePipeline")
    static let ohiaResumePipeline = Notification.Name("ohia.resumePipeline")

    // User-triggered retry for the visible generated artifact. Observed by a
    // single arbiter (`ConstellationModeView.regenerateVisibleGeneratedText`)
    // which picks exactly one focused surface by priority — never broadcast to
    // every summary view at once.
    static let ohiaRegenerateGeneratedText = Notification.Name("ohia.regenerateGeneratedText")
    static let ohiaRegenerateTranslation = Notification.Name("ohia.regenerateTranslation")
    static let ohiaRegenerateFrontPageTranslation = Notification.Name("ohia.regenerateFrontPageTranslation")
    static let ohiaRegenerateTimelineTranslation = Notification.Name("ohia.regenerateTimelineTranslation")
    static let ohiaRegenerateLockedEmailTranslation = Notification.Name("ohia.regenerateLockedEmailTranslation")
    static let ohiaRegenerateAnnotationTranslation = Notification.Name("ohia.regenerateAnnotationTranslation")

    // Internal re-dispatch from the regenerate arbiter to a single child
    // surface that owns its own generated state: the locked-overlay context
    // orientation and the Projects gutter project-summary. Posted only by the
    // arbiter (never bound directly to a menu item), so one user command
    // regenerates one surface.
    static let ohiaRegenerateLockedContext = Notification.Name("ohia.regenerateLockedContext")
    static let ohiaRegenerateProjectsGutter = Notification.Name("ohia.regenerateProjectsGutter")

    // Sidebar visibility
    static let ohiaToggleSidebar = Notification.Name("ohia.toggleSidebar")

    // Constellation locked-node actions (Edit-menu parity for the right-
    // click context menu). Each posts when the user picks the matching
    // menu item; ConstellationModeView listens and routes to the same
    // dispatcher the right-click menu uses.
    static let ohiaLockedNodeToggleRead = Notification.Name("ohia.lockedNode.toggleRead")
    static let ohiaLockedNodeMarkAsSpam = Notification.Name("ohia.lockedNode.markAsSpam")
    static let ohiaLockedNodeDelete = Notification.Name("ohia.lockedNode.delete")
    /// userInfo["facet"] is a namespaced flat-category token such as
    /// `purpose.receipt` or `custom.family`.
    static let ohiaLockedNodeEditClassificationFacet = Notification.Name("ohia.lockedNode.editClassificationFacet")

    // Developer cache invalidation
    static let ohiaEmailSummariesInvalidated = Notification.Name("ohia.emailSummariesInvalidated")
}

enum ConstellationShortcutCommand: Hashable, Identifiable, Sendable {
    case scope(FrameKey)
    case moment(TimeRangePreset)
    case action(HeadlineToggle)
    case status(TraceToggle)

    static let scopeCommands: [Self] = [
        .scope(.frontPage),
        .scope(.meaning),
        .scope(.people),
        .scope(.projects),
        .scope(.timeline),
    ]

    static let momentCommands: [Self] = [
        .moment(.now),
        .moment(.hour),
        .moment(.today),
        .moment(.yesterday),
        .moment(.week),
        .moment(.month),
        .moment(.quarter),
        .moment(.yearToDate),
        .moment(.year),
        .moment(.all),
    ]

    static let actionCommands: [Self] = [
        .action(.actionable),
        .action(.confirm),
        .action(.resolved),
    ]

    static let statusCommands: [Self] = [
        .status(.received),
        .status(.sent),
        .status(.read),
        .status(.unread),
        .status(.replied),
        .status(.unreplied),
        .status(.flagged),
        .status(.hasAttachments),
    ]

    var id: String {
        switch self {
        case .scope(let frame):
            return "scope.\(frame.rawValue)"
        case .moment(let preset):
            return "moment.\(preset.rawValue)"
        case .action(let action):
            return "action.\(action.rawValue)"
        case .status(let status):
            return "status.\(status.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .scope(let frame):
            return FrameSelectorBar.title(for: frame)
        case .moment(let preset):
            return preset.title
        case .action(let action):
            return action.actionDisplayLabel
        case .status(let status):
            switch status {
            case .received:       return "Received"
            case .sent:           return "Sent"
            case .read:           return "Read"
            case .unread:         return "Unread"
            case .replied:        return "Replied"
            case .unreplied:      return "Unreplied"
            case .flagged:        return "Flagged"
            case .hasAttachments: return "Attachments"
            }
        }
    }

    var keyCharacter: Character {
        let commands: [Self]
        switch self {
        case .scope:
            commands = Self.scopeCommands
        case .moment:
            commands = Self.momentCommands
        case .action:
            commands = Self.actionCommands
        case .status:
            commands = Self.statusCommands
        }
        guard let index = commands.firstIndex(of: self) else {
            preconditionFailure("Shortcut command is absent from its canonical group")
        }
        if case .moment(.all) = self {
            return "0"
        }
        if case .scope = self {
            return Character(String(index + 3))
        }
        return Character(String(index + 1))
    }

    var modifiers: EventModifiers {
        switch self {
        case .scope:
            return [.command]
        case .moment:
            return [.option, .command]
        case .action:
            return [.control, .command]
        case .status:
            return [.control, .option, .command]
        }
    }
}

struct ConstellationShortcutLegendEntry: Hashable, Sendable {
    let keys: String
    let detail: String
}

enum ConstellationShortcutLegendModel {
    static let entries: [ConstellationShortcutLegendEntry] = [
        .init(keys: "⌘1", detail: "Constellation window"),
        .init(keys: "⌘2", detail: "Composer window"),
        .init(
            keys: "⌘3–7",
            detail: "Digest · Meanings · Correspondents · Projects · Timeline"
        ),
        .init(
            keys: "⌥⌘1–0",
            detail: "Now · Hour · Today · Yesterday · Week · Month · Quarter · YTD · Year · All Time"
        ),
        .init(keys: "⌃⌘1–3", detail: "Reply · Confirm · Resolve"),
        .init(
            keys: "⌃⌥⌘1–8",
            detail: "Received · Sent · Read · Unread · Replied · Unreplied · Flagged · Attachments"
        ),
    ]
}

enum ConstellationShortcutAvailability {
    static func isEnabled(
        _ command: ConstellationShortcutCommand,
        displayedFrames: Set<FrameKey>,
        displayedActions: Set<HeadlineToggle>,
        displayedStatuses: Set<TraceToggle>,
        activeFrame: FrameKey,
        hasCompletedFirstIngestion: Bool = true
    ) -> Bool {
        guard hasCompletedFirstIngestion else { return false }

        switch command {
        case .scope(let frame):
            return displayedFrames.contains(frame.spatialLens)
        case .moment:
            return true
        case .action(let action):
            return displayedActions.contains(action)
        case .status(let status):
            guard displayedStatuses.contains(status) else { return false }
            if activeFrame.spatialLens == .frontPage {
                return status != .received && status != .sent
            }
            return true
        }
    }
}

enum ConstellationShortcutDisplayState {
    static func displayedActions(
        rawValue: String,
        resolvedPreferenceInitialized: Bool
    ) -> Set<HeadlineToggle> {
        var displayed = Set(rawValue.split(separator: ",").compactMap {
            HeadlineToggle(rawValue: String($0))
        })
        if !resolvedPreferenceInitialized {
            displayed.insert(.resolved)
        }
        return displayed
    }

    static func displayedStatuses(rawValue: String) -> Set<TraceToggle> {
        var displayed = Set(rawValue.split(separator: ",").compactMap {
            TraceToggle(rawValue: String($0))
        })
        normalizePair(.received, .sent, in: &displayed)
        normalizePair(.read, .unread, in: &displayed)
        normalizePair(.replied, .unreplied, in: &displayed)
        return displayed
    }

    private static func normalizePair(
        _ first: TraceToggle,
        _ second: TraceToggle,
        in displayed: inout Set<TraceToggle>
    ) {
        guard displayed.contains(first) || displayed.contains(second) else {
            return
        }
        displayed.insert(first)
        displayed.insert(second)
    }
}

enum ConstellationShortcutFilterMutation {
    static func applying(
        action: HeadlineToggle,
        to filter: VectorFilter,
        activeFrame: FrameKey
    ) -> VectorFilter {
        var result = filter
        switch action {
        case .actionable:
            result.replyNeededCriterion = next(result.replyNeededCriterion)
        case .confirm:
            result.confirmationNeededCriterion = next(result.confirmationNeededCriterion)
        case .resolved:
            let effective = ResolvedActionFilterPolicy.criterion(
                stored: result.resolvedCriterion,
                lens: activeFrame
            )
            result.resolvedCriterion = next(effective)
        }
        return result
    }

    static func applying(
        status: TraceToggle,
        to filter: VectorFilter
    ) -> VectorFilter {
        var result = filter
        switch status {
        case .received:
            result.sentStates = toggling(false, in: result.sentStates)
        case .sent:
            result.sentStates = toggling(true, in: result.sentStates)
        case .read:
            result.readStates = toggling(true, in: result.readStates)
        case .unread:
            result.readStates = toggling(false, in: result.readStates)
        case .replied:
            result.repliedStates = toggling(true, in: result.repliedStates)
        case .unreplied:
            result.repliedStates = toggling(false, in: result.repliedStates)
        case .flagged:
            result.flaggedOnly.toggle()
        case .hasAttachments:
            result.hasAttachmentsOnly.toggle()
        }
        return result
    }

    private static func next(
        _ criterion: AttentionFilterCriterion
    ) -> AttentionFilterCriterion {
        switch criterion {
        case .any:
            return .required
        case .required:
            return .excluded
        case .excluded:
            return .any
        }
    }

    private static func toggling(
        _ value: Bool,
        in states: Set<Bool>?
    ) -> Set<Bool>? {
        var active = states ?? [true, false]
        if active.contains(value) {
            active.remove(value)
        } else {
            active.insert(value)
        }
        if active == [true, false] || active.isEmpty {
            return nil
        }
        return active
    }
}

/// Helper for posting commands with a consistent API.
enum AppCommand {
    private static let pendingComposerFocusMessageIDKey = "ohia.pendingComposerFocusMessageID"
    private static let pendingNotificationFocusMessageIDKey = "ohia.pendingNotificationFocusMessageID"
    private static let pendingNotificationMarkReadMessageIDsKey = "ohia.pendingNotificationMarkReadMessageIDs"
    private static let pendingNewProjectConfigurationKey = "ohia.pendingNewProjectConfiguration"

    static func showConstellation() {
        NotificationCenter.default.post(name: .ohiaShowConstellation, object: nil)
    }

    /// Opens the manual-project configuration flow. The pending bit lets a
    /// menu command survive while the unique Constellation window is closed;
    /// its workspace consumes the request when it next mounts.
    static func createNewProject(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingNewProjectConfigurationKey)
        NotificationCenter.default.post(name: .ohiaCreateNewProject, object: nil)
        showConstellation()
    }

    static func pendingNewProjectConfiguration(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingNewProjectConfigurationKey)
    }

    static func clearPendingNewProjectConfiguration(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingNewProjectConfigurationKey)
    }

    static func constellationShortcut(_ command: ConstellationShortcutCommand) {
        NotificationCenter.default.post(
            name: .ohiaConstellationShortcut,
            object: command
        )
        showConstellation()
    }

    static func showFocus(messageID: UUID) {
        requestComposerFocus(messageID: messageID)
        NotificationCenter.default.post(
            name: .ohiaShowFocus,
            object: nil,
            userInfo: ["messageID": messageID]
        )
    }

    /// Opens the Composer at its queue (no specific message).
    static func showComposer() {
        clearPendingComposerFocusMessageID()
        NotificationCenter.default.post(name: .ohiaShowComposer, object: nil)
    }

    static func requestComposerFocus(messageID: UUID) {
        UserDefaults.standard.set(
            messageID.uuidString,
            forKey: pendingComposerFocusMessageIDKey
        )
        NotificationCenter.default.post(
            name: .ohiaComposerSelectMessage,
            object: nil,
            userInfo: ["messageID": messageID]
        )
    }

    static func pendingComposerFocusMessageID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: pendingComposerFocusMessageIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func clearPendingComposerFocusMessageID() {
        UserDefaults.standard.removeObject(forKey: pendingComposerFocusMessageIDKey)
    }

    /// Dismisses the Composer's selected reply as not needing a reply.
    static func composerDismissNoReply() {
        NotificationCenter.default.post(name: .ohiaComposerDismissNoReply, object: nil)
    }

    /// Opens the Subscriptions ledger (Settings → Lists).
    static func showSubscriptions() {
        NotificationCenter.default.post(name: .ohiaShowSubscriptions, object: nil)
    }

    private static let pendingConstellationListScopeKey = "ohia.pendingConstellationListScope"
    private static let pendingConstellationListScopeAccountKey = "ohia.pendingConstellationListScopeAccount"

    /// Scopes the Constellation to one mailing list. Latched through
    /// UserDefaults because the Constellation may not be mounted when the
    /// ledger fires this (the shell shows one mode at a time): the live
    /// view applies the notification immediately; a freshly-mounted view
    /// picks the latch up in `onAppear`.
    static func scopeConstellationToList(listId: String, accountID: UUID? = nil) {
        UserDefaults.standard.set(listId, forKey: pendingConstellationListScopeKey)
        if let accountID {
            UserDefaults.standard.set(accountID.uuidString, forKey: pendingConstellationListScopeAccountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingConstellationListScopeAccountKey)
        }
        var userInfo: [String: Any] = ["listId": listId]
        if let accountID {
            userInfo["accountID"] = accountID
        }
        NotificationCenter.default.post(
            name: .ohiaScopeConstellationToList,
            object: nil,
            userInfo: userInfo
        )
    }

    static func pendingConstellationListScope() -> String? {
        UserDefaults.standard.string(forKey: pendingConstellationListScopeKey)
    }

    static func pendingConstellationListScopeAccountID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: pendingConstellationListScopeAccountKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func clearPendingConstellationListScope() {
        UserDefaults.standard.removeObject(forKey: pendingConstellationListScopeKey)
        UserDefaults.standard.removeObject(forKey: pendingConstellationListScopeAccountKey)
    }

    // MARK: - Live Constellation filter mirror

    /// The Composer runs in its own window and can't see ConstellationModeView's
    /// `@State`, so the live in-session `VectorFilter` is mirrored to defaults
    /// here whenever it changes. The Composer's "Search Past Emails" sheet reads
    /// it to scope results to the user's current view. Distinct from
    /// `ConstellationViewStatePersistence`, which intentionally strips the
    /// session-scoped narrowing (account / type / attachment toggles) for
    /// cross-launch restore and so does not reflect the live filter.
    /// In-memory rather than UserDefaults-backed: the Constellation and Composer
    /// windows share one process, so an in-memory mirror crosses the window
    /// boundary just fine AND is naturally empty on launch — a filter from a
    /// previous session can never silently scope a fresh search before the live
    /// Constellation has published its current filter.
    @MainActor private static var liveConstellationFilter: VectorFilter?

    @MainActor
    static func publishConstellationFilter(_ filter: VectorFilter) {
        liveConstellationFilter = filter
    }

    @MainActor
    static func currentConstellationFilter() -> VectorFilter? {
        liveConstellationFilter
    }

    static func requestNotificationFocus(messageID: UUID) {
        UserDefaults.standard.set(
            messageID.uuidString,
            forKey: pendingNotificationFocusMessageIDKey
        )
        // An ordinary notification click must not inherit a forced-lens
        // request left behind by an earlier, still-unconsumed deep link
        // (`requestDeepLinkTimelineFocus`) — this message belongs to
        // whichever lens is currently active, not necessarily Timeline.
        UserDefaults.standard.removeObject(forKey: pendingNotificationFocusForcesTimelineKey)
        // A macOS new-mail notification belongs to the currently selected
        // Constellation lens. Keep the persisted UUID for cold launch, then
        // wake the Constellation window; ConstellationModeView consumes the
        // exact message once its restored lens is ready.
        showConstellation()
    }

    private static let pendingNotificationFocusForcesTimelineKey =
        "ohia.pendingNotificationFocusForcesTimeline"

    /// Like `requestNotificationFocus`, but always resolves in the Timeline
    /// lens rather than whichever lens is currently active — used by the
    /// `ohia://message/<uuid>` deep link, which always wants to land on the
    /// exact dated email a synced calendar event came from, regardless of
    /// what the user was last looking at.
    static func requestDeepLinkTimelineFocus(messageID: UUID) {
        UserDefaults.standard.set(
            messageID.uuidString,
            forKey: pendingNotificationFocusMessageIDKey
        )
        UserDefaults.standard.set(true, forKey: pendingNotificationFocusForcesTimelineKey)
        showConstellation()
    }

    static func pendingNotificationFocusMessageID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: pendingNotificationFocusMessageIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func clearPendingNotificationFocusMessageID() {
        UserDefaults.standard.removeObject(forKey: pendingNotificationFocusMessageIDKey)
        UserDefaults.standard.removeObject(forKey: pendingNotificationFocusForcesTimelineKey)
    }

    /// Consumes (reads and clears) the pending forced-lens flag. One-shot:
    /// the flag only needs to fire the single `selectFrame(.timeline)` that
    /// starts the navigation — the notification-focus retry machinery that
    /// follows keys off `state.activeFrame`, not this flag.
    static func consumePendingNotificationFocusForcesTimeline() -> Bool {
        let forces = UserDefaults.standard.bool(forKey: pendingNotificationFocusForcesTimelineKey)
        if forces {
            UserDefaults.standard.removeObject(forKey: pendingNotificationFocusForcesTimelineKey)
        }
        return forces
    }

    static func requestNotificationMarkRead(messageIDs: [UUID]) {
        let merged = mergeUUIDStrings(
            existing: UserDefaults.standard.stringArray(
                forKey: pendingNotificationMarkReadMessageIDsKey
            ) ?? [],
            incoming: messageIDs.map(\.uuidString)
        )
        UserDefaults.standard.set(merged, forKey: pendingNotificationMarkReadMessageIDsKey)
        NotificationCenter.default.post(
            name: .ohiaNotificationMarkRead,
            object: nil,
            userInfo: ["messageIDs": merged]
        )
    }

    static func pendingNotificationMarkReadMessageIDs() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: pendingNotificationMarkReadMessageIDsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
    }

    static func clearPendingNotificationMarkReadMessageIDs() {
        UserDefaults.standard.removeObject(forKey: pendingNotificationMarkReadMessageIDsKey)
    }

    private static func mergeUUIDStrings(existing: [String], incoming: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in existing + incoming {
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func showOutbox() {
        NotificationCenter.default.post(name: .ohiaShowOutbox, object: nil)
    }

    static func sendAllOutboxNow() {
        NotificationCenter.default.post(name: .ohiaSendAllOutboxNow, object: nil)
    }

    static func reauthenticateAccount() {
        NotificationCenter.default.post(name: .ohiaReauthenticateAccount, object: nil)
    }

    static func trainingTrainNow() {
        NotificationCenter.default.post(name: .ohiaTrainingTrainNow, object: nil)
    }

    static func trainingTogglePause() {
        NotificationCenter.default.post(name: .ohiaTrainingTogglePause, object: nil)
    }

    static func openTrainingSettings() {
        NotificationCenter.default.post(name: .ohiaOpenTrainingSettings, object: nil)
    }

    static func ensureGenerativeWorker() {
        NotificationCenter.default.post(name: .ohiaEnsureGenerativeWorker, object: nil)
    }

    static func selectGenerationModel(_ modelID: String) {
        NotificationCenter.default.post(
            name: .ohiaSelectGenerationModel,
            object: nil,
            userInfo: ["modelID": modelID]
        )
    }

    static func cancelGenerationModelPreparation(_ modelID: String) {
        NotificationCenter.default.post(
            name: .ohiaCancelGenerationModelPreparation,
            object: nil,
            userInfo: ["modelID": modelID]
        )
    }

    static func composeNew() {
        NotificationCenter.default.post(name: .ohiaComposeNew, object: nil)
    }

    private static let pendingComposerNewMessageKey = "ohia.pendingComposerNewMessage"
    private static let pendingComposerComposeDraftIDKey = "ohia.pendingComposerComposeDraftID"

    /// Latches the provisional new-message surface so a Composer opened by
    /// this command can consume it on appear, while an existing one responds
    /// to the notification immediately.
    static func requestComposerNewMessage(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingComposerComposeDraftIDKey)
        defaults.set(true, forKey: pendingComposerNewMessageKey)
        NotificationCenter.default.post(name: .ohiaComposerBeginNewMessage, object: nil)
    }

    static func pendingComposerNewMessage(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingComposerNewMessageKey)
    }

    static func clearPendingComposerNewMessage(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingComposerNewMessageKey)
    }

    /// Latches the compose draft to select and notifies the Composer. A
    /// freshly-mounted Composer reads the latch in `onAppear`; an already-open
    /// one selects immediately via the notification. Mirrors the message-focus
    /// latch used by `requestComposerFocus`.
    static func requestComposerCompose(draftID: UUID) {
        clearPendingComposerNewMessage()
        UserDefaults.standard.set(draftID.uuidString, forKey: pendingComposerComposeDraftIDKey)
        NotificationCenter.default.post(
            name: .ohiaComposerSelectCompose, object: nil,
            userInfo: ["draftID": draftID]
        )
    }

    static func pendingComposerComposeDraftID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: pendingComposerComposeDraftIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func clearPendingComposerComposeDraftID() {
        UserDefaults.standard.removeObject(forKey: pendingComposerComposeDraftIDKey)
    }

    static func addIdentityFromMenu() {
        NotificationCenter.default.post(name: .ohiaAddIdentityFromMenu, object: nil)
    }

    static func regenerateGeneratedText() {
        NotificationCenter.default.post(name: .ohiaRegenerateGeneratedText, object: nil)
    }

    static func regenerateTranslation() {
        NotificationCenter.default.post(name: .ohiaRegenerateTranslation, object: nil)
    }

    static func toggleSidebar() {
        NotificationCenter.default.post(name: .ohiaToggleSidebar, object: nil)
    }

    static func toggleWithheld() {
        NotificationCenter.default.post(name: .ohiaToggleWithheld, object: nil)
    }

    static func lockedNodeToggleRead() {
        NotificationCenter.default.post(name: .ohiaLockedNodeToggleRead, object: nil)
    }

    static func lockedNodeMarkAsSpam() {
        NotificationCenter.default.post(name: .ohiaLockedNodeMarkAsSpam, object: nil)
    }

    static func lockedNodeDelete(confirm: Bool = true) {
        NotificationCenter.default.post(
            name: .ohiaLockedNodeDelete,
            object: nil,
            userInfo: ["confirm": confirm]
        )
    }

    static func lockedNodeEditClassificationFacet(_ facet: String) {
        NotificationCenter.default.post(
            name: .ohiaLockedNodeEditClassificationFacet,
            object: nil,
            userInfo: ["facet": facet]
        )
    }
}
