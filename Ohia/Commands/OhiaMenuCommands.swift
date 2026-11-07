// Ohia/Commands/OhiaMenuCommands.swift
// Menu bar structure — File, View, Mail, and Tools menus.
// Each item shows its keyboard shortcut in the menu.

import AppKit
import SwiftUI
import OhiaCore

/// The active Constellation selection's Send Again action. A focused scene
/// value keeps menu enablement scoped to the key Ohia window and avoids a
/// stale process-wide selected-message latch when focus moves elsewhere.
struct SendAgainCommandTarget {
    let perform: @MainActor (_ immediately: Bool) -> Void
}

extension FocusedValues {
    @Entry var sendAgainCommandTarget: SendAgainCommandTarget?
}

enum TrainingMenuCommandRequest {
    private static let requestedPauseKey = "requestedPause"

    static func pause() {
        NotificationCenter.default.post(
            name: .ohiaTrainingTogglePause,
            object: nil,
            userInfo: [requestedPauseKey: true]
        )
    }

    static func requestedPause(from notification: Notification) -> Bool? {
        notification.userInfo?[requestedPauseKey] as? Bool
    }
}

struct OhiaMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.sendAgainCommandTarget) private var sendAgainCommandTarget
    @FocusedValue(\.focusedEmailPrintCommandTarget) private var focusedEmailPrintCommandTarget
    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false

    var body: some Commands {
        // File → New contains only user-facing creation actions. Replacing the
        // system group also suppresses SwiftUI's automatic entries for the
        // DEBUG-only design WindowGroups, which remain available under Tools.
        CommandGroup(replacing: .newItem) {
            Menu("New", systemImage: "plus") {
                Button("New Mail", systemImage: "square.and.pencil") {
                    AppCommand.composeNew()
                }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(!hasCompletedOnboarding)
                Button("New Project…", systemImage: "folder.badge.plus") {
                    AppCommand.createNewProject()
                }
                    .keyboardShortcut("n", modifiers: [.shift, .command])
                    .disabled(!hasCompletedOnboarding)
            }
        }

        // File menu — lens-aware printing is available only when the active
        // Ohia scene has a focused email surface.
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…", systemImage: "doc") {
                FocusedEmailPrintCoordinator.runPageLayout()
            }
            .keyboardShortcut("p", modifiers: [.shift, .command])

            Button("Print…", systemImage: "printer") {
                focusedEmailPrintCommandTarget?.perform()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(focusedEmailPrintCommandTarget == nil)
        }

        // View menu — chrome toggles for Constellation surfaces.
        CommandGroup(after: .toolbar) {
            ConstellationShortcutMenus()

            Divider()

            SidebarToggleMenuItem()

            WithheldToggleMenuItem()

            ActivityStripToggleItem()

            ComposerColumnsMenu()

            Divider()
        }

        // Edit menu — gated on a Constellation node being focused (the
        // locked-node overlay). The right-click context menu in
        // Constellation has the same five actions; this mirror keeps
        // them keyboard-discoverable per the project's "menu + context
        // menus" rule.
        CommandGroup(after: .pasteboard) {
            Divider()
            ConstellationLockedNodeMenuItems()
        }

        // Mail menu — compose + outbox affordances
        CommandMenu("Mail") {
            Button("Send Again", systemImage: "paperplane") {
                sendAgainCommandTarget?.perform(false)
            }
            .disabled(!hasCompletedOnboarding || sendAgainCommandTarget == nil)
            .modifierKeyAlternate(.option) {
                Button("Send Again Immediately", systemImage: "paperplane.fill") {
                    sendAgainCommandTarget?.perform(true)
                }
                .disabled(!hasCompletedOnboarding || sendAgainCommandTarget == nil)
            }
            Divider()
            Button("Send All Outbox Now", systemImage: "tray.and.arrow.up.fill") {
                AppCommand.sendAllOutboxNow()
            }
                .keyboardShortcut(.return, modifiers: [.shift, .command])
                .disabled(!hasCompletedOnboarding)
            Button("Email Lists…", systemImage: "list.bullet.rectangle") {
                AppCommand.showSubscriptions()
            }
                .keyboardShortcut("l", modifiers: [.option, .command])
                .disabled(!hasCompletedOnboarding)
        }

        CommandMenu("Tools") {
            Button("Regenerate Summary", systemImage: "arrow.clockwise") {
                AppCommand.regenerateGeneratedText()
            }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Regenerate Translation", systemImage: "translate") {
                AppCommand.regenerateTranslation()
            }
                .keyboardShortcut("r", modifiers: [.option, .command])
            Divider()
            Menu("Training", systemImage: "brain") {
                Button("Train Now", systemImage: "play.fill") {
                    AppCommand.trainingTrainNow()
                }
                    .keyboardShortcut("t", modifiers: [.shift, .command])
                Button("Pause Training", systemImage: "pause.fill") {
                    TrainingMenuCommandRequest.pause()
                }
                Divider()
                Button("Open Training Settings", systemImage: "gearshape") {
                    AppCommand.openTrainingSettings()
                }
            }
            Menu("Ingestion", systemImage: "arrow.triangle.2.circlepath") {
                Button("Start Pipeline", systemImage: "play.fill") {
                    NotificationCenter.default.post(name: .ohiaResumePipeline, object: nil)
                }
                Button("Pause Pipeline", systemImage: "pause.fill") {
                    NotificationCenter.default.post(name: .ohiaPausePipeline, object: nil)
                }
            }
        }
    }
}

private struct ConstellationShortcutMenus: View {
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage("constellationShortcutActiveFrame")
    private var activeFrameRaw = FrameKey.frontPage.rawValue
    @AppStorage("constellationFrameDisplayed")
    private var frameDisplayedRaw = FrameKey.visibleSpatialFrames
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
    @AppStorage("constellationHeadlineDisplayed")
    private var actionDisplayedRaw = HeadlineToggle.allCases
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
    @AppStorage("constellationResolvedHeadlineChipPreferenceInitialized")
    private var resolvedActionPreferenceInitialized = false
    @AppStorage("constellationTracesDisplayedV2")
    private var statusDisplayedRaw = TraceToggle.allCases
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")

    var body: some View {
        Menu("Moments", systemImage: "clock") {
            ForEach(ConstellationShortcutCommand.momentCommands) { command in
                shortcutButton(command)
            }
        }
        .disabled(!hasCompletedFirstIngestion)

        Menu(
            "Action",
            systemImage: "envelope.and.arrow.trianglehead.branch"
        ) {
            ForEach(ConstellationShortcutCommand.actionCommands) { command in
                shortcutButton(command)
            }
        }
        .disabled(!hasCompletedFirstIngestion)

        Menu("Status", systemImage: "tray.and.arrow.down") {
            ForEach(ConstellationShortcutCommand.statusCommands) { command in
                shortcutButton(command)
            }
        }
        .disabled(!hasCompletedFirstIngestion)

        Menu(
            "Scope",
            systemImage: "point.3.connected.trianglepath.dotted"
        ) {
            ForEach(ConstellationShortcutCommand.scopeCommands) { command in
                shortcutButton(command)
            }
        }
        .disabled(!hasCompletedFirstIngestion)
    }

    private func shortcutButton(
        _ command: ConstellationShortcutCommand
    ) -> some View {
        Button(command.title) {
            AppCommand.constellationShortcut(command)
        }
        .keyboardShortcut(
            KeyEquivalent(command.keyCharacter),
            modifiers: command.modifiers
        )
        .disabled(
            !ConstellationShortcutAvailability.isEnabled(
                command,
                displayedFrames: displayedFrames,
                displayedActions: displayedActions,
                displayedStatuses: displayedStatuses,
                activeFrame: activeFrame,
                hasCompletedFirstIngestion: hasCompletedFirstIngestion
            )
        )
    }

    private var activeFrame: FrameKey {
        FrameKey(rawValue: activeFrameRaw).spatialLens
    }

    private var displayedFrames: Set<FrameKey> {
        let known = Set(FrameKey.visibleSpatialFrames)
        return Set(frameDisplayedRaw.split(separator: ",").map {
            FrameKey(rawValue: String($0))
        })
        .intersection(known)
    }

    private var displayedActions: Set<HeadlineToggle> {
        ConstellationShortcutDisplayState.displayedActions(
            rawValue: actionDisplayedRaw,
            resolvedPreferenceInitialized: resolvedActionPreferenceInitialized
        )
    }

    private var displayedStatuses: Set<TraceToggle> {
        ConstellationShortcutDisplayState.displayedStatuses(
            rawValue: statusDisplayedRaw
        )
    }
}

private struct SidebarToggleMenuItem: View {
    // Mirrors ConstellationModeView's sidebar-visibility AppStorage so the label
    // tracks state: "Hide Search/Ask" when shown, "Show Search/Ask" when hidden.
    @AppStorage("constellationSidebarVisible") private var sidebarVisible = true

    var body: some View {
        Button(action: { AppCommand.toggleSidebar() }) {
            Label(sidebarVisible ? "Hide Search/Ask" : "Show Search/Ask", systemImage: "sidebar.left")
        }
        .keyboardShortcut("f", modifiers: [.command])
    }
}

private struct WithheldToggleMenuItem: View {
    // Peer to the sidebar toggle: same dynamic Show/Hide label, driven by the
    // same @AppStorage key ConstellationModeView writes when the drawer opens.
    @AppStorage("constellationWithheldVisible") private var withheldVisible = false
    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false

    var body: some View {
        Button(action: { AppCommand.toggleWithheld() }) {
            Label(withheldVisible ? "Hide Junk/Trash" : "Show Junk/Trash", systemImage: "tray.2")
        }
        .keyboardShortcut("j", modifiers: [.command])
        .disabled(!hasCompletedOnboarding)
    }
}

private struct ActivityStripToggleItem: View {
    @AppStorage("showConstellationActivityStrip")
    private var showConstellationActivityStrip = true
    @AppStorage("showComposerActivityStrip")
    private var showComposerActivityStrip = true

    var body: some View {
        Toggle(isOn: $showConstellationActivityStrip) {
            Label(
                "Show Activity Strip in Constellation",
                systemImage: "rectangle.bottomthird.inset.filled"
            )
        }

        Toggle(isOn: $showComposerActivityStrip) {
            Label(
                "Show Activity Strip in Composer",
                systemImage: "rectangle.bottomthird.inset.filled"
            )
        }
    }
}

/// View › Composer Columns: one checkmark toggle per Composer column, bound
/// to the same defaults keys `ComposerView` reads, so a column closed here
/// stays closed for every later message; then the moves for the column the
/// pointer is over or was last over (named in the item) and a reset of the
/// column order. Enabled only while a Composer window is key.
private struct ComposerColumnsMenu: View {
    @FocusedValue(\.composerColumnsCommandTarget) private var composerColumnsCommandTarget

    private static let moveModifiers: EventModifiers = [.control, .option, .command]

    var body: some View {
        Menu("Composer Columns", systemImage: "rectangle.split.3x1") {
            ForEach(ComposerColumn.allCases) { column in
                ComposerColumnToggleItem(column: column)
            }

            Divider()

            Button(
                composerColumnsCommandTarget?.moveTitle(.left) ?? "Move Column Left",
                systemImage: "arrow.left"
            ) {
                composerColumnsCommandTarget?.movePointerColumn(.left)
            }
            .keyboardShortcut(.leftArrow, modifiers: Self.moveModifiers)
            .disabled(composerColumnsCommandTarget?.canMovePointerColumn(.left) != true)

            Button(
                composerColumnsCommandTarget?.moveTitle(.right) ?? "Move Column Right",
                systemImage: "arrow.right"
            ) {
                composerColumnsCommandTarget?.movePointerColumn(.right)
            }
            .keyboardShortcut(.rightArrow, modifiers: Self.moveModifiers)
            .disabled(composerColumnsCommandTarget?.canMovePointerColumn(.right) != true)

            Button("Reset Column Order", systemImage: "arrow.uturn.backward") {
                composerColumnsCommandTarget?.resetOrder()
            }
            .disabled(composerColumnsCommandTarget?.isDefaultOrder != false)
        }
        .disabled(composerColumnsCommandTarget == nil)
    }
}

private struct ComposerColumnToggleItem: View {
    let column: ComposerColumn
    @AppStorage private var isOpen: Bool

    init(column: ComposerColumn) {
        self.column = column
        _isOpen = AppStorage(wrappedValue: true, column.openStorageKey)
    }

    var body: some View {
        Toggle(column.menuTitle, isOn: Binding(
            get: { isOpen },
            set: { newValue in
                guard !ComposerColumn.isWindowModalPresentationActive else { return }
                isOpen = newValue
            }
        ))
        .keyboardShortcut(column.shortcutKey, modifiers: ComposerColumn.shortcutModifiers)
    }
}

/// Edit-menu mirror of the Constellation right-click context menu. Items
/// are enabled only when a node is locked in the Constellation overlay.
/// Classification facets render as Toggles backed by AppStorage-mirrored JSON,
/// so the submenu shows ✓ marks for currently-applied facets — same
/// information the right-click submenu surfaces — and toggling a Toggle
/// fires the existing classification-facet notification.
private struct ConstellationLockedNodeMenuItems: View {
    @AppStorage(ConstellationDefaultsKey.lockedNodeID) private var lockedNodeIDRaw: String = ""
    @AppStorage(ConstellationDefaultsKey.lockedNodeClassificationJSON) private var lockedNodeClassificationJSON: String = ""
    @AppStorage(ConstellationDefaultsKey.lockedNodeCustomCategoryKeysJSON) private var lockedNodeCustomCategoryKeysJSON: String = ""
    @AppStorage(ConstellationDefaultsKey.customCategoryCatalogJSON) private var customCategoryCatalogJSON: String = ""

    private var hasLockedNode: Bool {
        !lockedNodeIDRaw.isEmpty
    }

    private var lockedClassification: MailClassification? {
        MailClassificationJSON.decode(
            lockedNodeClassificationJSON.isEmpty ? nil : lockedNodeClassificationJSON
        )
    }

    /// Custom-category catalog mirrored into defaults by
    /// `CustomCategoryStore` — the Commands scene has no SwiftData
    /// environment, so the JSON mirror is its source of truth.
    private var customCatalog: [CustomMailCategoryDescriptor] {
        CustomCategoryStore.decodeMirroredCatalog(customCategoryCatalogJSON)
    }

    private var lockedCustomKeys: Set<String> {
        Set(CustomCategoryKeysJSON.decode(
            lockedNodeCustomCategoryKeysJSON.isEmpty ? nil : lockedNodeCustomCategoryKeysJSON
        ))
        .intersection(Set(customCatalog.map(\.key)))
    }

    var body: some View {
        Button("Mark Selected Message as Read / Unread") {
            AppCommand.lockedNodeToggleRead()
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(!hasLockedNode)

        Menu("Selected Message Categories") {
            ForEach(MailPurpose.allCases, id: \.self) { purpose in
                Toggle(
                    purpose.displayLabel,
                    isOn: Binding(
                        get: { lockedClassification?.purpose == purpose },
                        set: { _ in AppCommand.lockedNodeEditClassificationFacet("purpose.\(purpose.rawValue)") }
                    )
                )
            }
            if !customCatalog.isEmpty {
                Divider()
                // User-defined categories ride the same facet notification;
                // `custom.*` tokens flip the independent custom-key set.
                ForEach(customCatalog) { descriptor in
                    Toggle(
                        CustomCategoryStore.menuLabel(for: descriptor),
                        isOn: Binding(
                            get: { lockedCustomKeys.contains(descriptor.key) },
                            set: { _ in AppCommand.lockedNodeEditClassificationFacet(descriptor.key) }
                        )
                    )
                }
            }
        }
        .disabled(!hasLockedNode)

        Button("Mark Selected Message as Spam") {
            AppCommand.lockedNodeMarkAsSpam()
        }
        .disabled(!hasLockedNode)

        // Clicking deletes immediately (no confirmation), matching ⌘-Delete.
        // The ⌫ / ⌘⌫ shortcuts are NOT bound here: the scene's focus-aware
        // keyboard catcher owns them so it can let the field editor keep ⌘⌫
        // ("delete to start of line") while a text field is focused. A menu
        // key-equivalent would fire before that guard and silently delete the
        // locked node mid-edit. No ellipsis because no dialog follows.
        Button("Delete Selected Message") {
            AppCommand.lockedNodeDelete(confirm: false)
        }
        .disabled(!hasLockedNode)
    }
}
