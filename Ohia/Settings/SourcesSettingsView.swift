// Ohia/Settings/SourcesSettingsView.swift
// Settings → Sources: the single place the Composer's external evidence
// providers are configured. Two groups —
//
//  • Apps on This Mac: the four outside-the-mailbox readers offered in the
//    Composer's "Add" popover (Calendar, Contacts, Apple Notes, Screenshot).
//    Each row is an enable switch plus the live macOS
//    permission state with grant / System Settings actions. A switched-off
//    provider disappears from the Composer's Add popover, and Calendar's
//    automatic availability source stops compiling.
//
//  • MCP Servers: hosted Model Context Protocol services that feed drafting
//    as sources. `MCPServerStore` persists endpoint configuration and places
//    credentials in the Keychain; runtime sessions discover and call the
//    selected service's tools over HTTPS.

import SwiftUI
import Contacts
import EventKit
import OhiaCore
import OhiaML

struct SourcesSettingsView: View {

    @Environment(\.messagesTranscriptBroker) private var messagesTranscriptBroker

    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .calendar),
        store: OhiaSharedDefaults.store
    )
    private var calendarEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .contacts),
        store: OhiaSharedDefaults.store
    )
    private var contactsEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .appleNotes),
        store: OhiaSharedDefaults.store
    )
    private var appleNotesEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .screenshot),
        store: OhiaSharedDefaults.store
    )
    private var screenshotEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .messages),
        store: OhiaSharedDefaults.store
    )
    private var messagesEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled

    @State private var store = MCPServerStore()
    @State private var permissions = AppSourcePermissions()
    /// Provider whose grant request is in flight — disables its button.
    @State private var requestingProvider: ComposerSourceProvider?
    /// Set once a Screen Recording request comes back false, so the row can
    /// offer System Settings (CGPreflight can't distinguish denied from
    /// not-yet-asked, and re-requests after a denial are silent no-ops).
    @State private var screenshotRequestRefused = false
    @State private var editorContext: MCPServerEditorContext?
    @State private var pendingRemoval: MCPConfiguredServer?
    @State private var storeErrorMessage: String?
    /// Live connection state per server, driven by the Test Connection
    /// action. Sessions stay lazy — nothing connects until tested or used.
    @State private var mcpStatuses: [UUID: MCPConnectionStatus] = [:]
    /// Invalidates Keychain-derived row summaries after background OAuth
    /// rotation, recovery, or terminal revocation.
    @State private var mcpCredentialRevision = 0

    private enum MCPConnectionStatus: Equatable {
        case testing
        case connected(toolCount: Int)
        case failed(String)
    }

    var body: some View {
        // Hand-built cards rather than `Form(.grouped)` — see OhiaSettingsCard
        // for why the system section box cannot be black over the night sky.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appsSection
                mcpSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .task { permissions = await AppSourcePermissions.current(messagesBroker: messagesTranscriptBroker) }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Returning from System Settings re-reads every grant. Wrapped
            // in a Task because the Messages reader status crosses XPC.
            Task { permissions = await AppSourcePermissions.current(messagesBroker: messagesTranscriptBroker) }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .ohiaMCPServerInjectableEnvironmentDidChange
            )
        ) { notification in
            if let serverID = notification.object as? UUID {
                mcpStatuses[serverID] = nil
            } else {
                mcpStatuses.removeAll()
            }
            mcpCredentialRevision &+= 1
        }
        .sheet(item: $editorContext) { context in
            MCPServerEditorSheet(context: context, store: store)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this server")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) {
                guard let server = pendingRemoval else { return }
                pendingRemoval = nil
                do {
                    // OAuth material (refresh token, keep-fresh loop) lives
                    // outside the record's environment item — clear it too.
                    if server.service.supportsHostedOAuth {
                        // Removal is ID-scoped and intentionally clears any
                        // orphaned app-only state even if the record's service
                        // was corrupted or changed outside Ohia.
                        HostedMCPAuth.clearAppOnlyMaterial(serverID: server.id)
                    }
                    try store.remove(id: server.id)
                    mcpStatuses[server.id] = nil
                    // Removal must also disconnect any live remote session.
                    Task { await MCPSessionManager.shared.invalidate(id: server.id) }
                } catch {
                    storeErrorMessage = "Could not remove the server: \(error.localizedDescription)"
                }
            }
        } message: {
            Text("Its configuration and Keychain credential are deleted.")
        }
        .alert(
            "MCP Servers",
            isPresented: Binding(
                get: { storeErrorMessage != nil },
                set: { if !$0 { storeErrorMessage = nil } }
            )
        ) {
            Button("OK") { storeErrorMessage = nil }
        } message: {
            Text(storeErrorMessage ?? "")
        }
    }

    // MARK: - Apps on This Mac

    private var appsSection: some View {
        OhiaSettingsCard("Apps on This Mac") {
            SettingsCaption("Evidence readers offered in the Composer's Add menu. A switched-off app disappears from the menu, and Calendar's automatic availability check and Messages' automatic transcript both stop for newly prepared drafts — sources already added to a draft stay until removed there.")
            SettingsRowDivider()
            SettingsBlock {
                appRow(
                    provider: .calendar,
                    symbol: "calendar",
                    isEnabled: $calendarEnabled,
                    status: permissions.calendar.statusText,
                    statusColor: permissions.calendar.statusColor
                ) {
                    switch permissions.calendar {
                    case .notDetermined:
                        grantButton(for: .calendar) {
                            _ = await CalendarSourceReader.requestAccess()
                        }
                    case .denied, .writeOnly:
                        // A write-only grant can't be upgraded by re-prompting;
                        // both paths go through System Settings.
                        systemSettingsButton(pane: "Privacy_Calendars")
                    default:
                        EmptyView()
                    }
                }

                appRow(
                    provider: .contacts,
                    symbol: "person.crop.rectangle",
                    isEnabled: $contactsEnabled,
                    status: permissions.contacts.statusText,
                    statusColor: permissions.contacts.statusColor
                ) {
                    switch permissions.contacts {
                    case .notDetermined:
                        grantButton(for: .contacts) {
                            _ = await ContactSourceReader.requestAccess()
                        }
                    case .denied:
                        systemSettingsButton(pane: "Privacy_Contacts")
                    default:
                        EmptyView()
                    }
                }

                appRow(
                    provider: .appleNotes,
                    symbol: "note.text",
                    isEnabled: $appleNotesEnabled,
                    status: notesStatusText,
                    statusColor: notesStatusColor
                ) {
                    switch permissions.notes {
                    case .notDetermined:
                        grantButton(for: .appleNotes) {
                            _ = await NotesAutomationPermission.requestAccess()
                        }
                    case .notesNotRunning:
                        Button("Open Notes") {
                            openNotes()
                        }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                    case .denied:
                        Button("Open System Settings…") {
                            NotesAutomationPermission.openAutomationSettings()
                        }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                    case .granted:
                        EmptyView()
                    }
                }

                appRow(
                    provider: .screenshot,
                    symbol: "camera.viewfinder",
                    isEnabled: $screenshotEnabled,
                    status: screenshotStatusText,
                    // Never red: a refused CGRequest can simply mean the system
                    // prompt is still on screen, and after a grant the preflight
                    // stays false until relaunch.
                    statusColor: permissions.screenshot == .granted
                        ? OhiaColors.chipActiveForeground
                        : .secondary
                ) {
                    if permissions.screenshot != .granted {
                        if screenshotRequestRefused {
                            systemSettingsButton(pane: "Privacy_ScreenCapture")
                        } else {
                            grantButton(for: .screenshot) {
                                let granted = ScreenCaptureService.requestAccess()
                                if !granted { screenshotRequestRefused = true }
                            }
                        }
                    }
                }

                appRow(
                    provider: .messages,
                    symbol: "message",
                    isEnabled: $messagesEnabled,
                    status: messagesStatusText,
                    // Full Disk Access has no request API at all — never red;
                    // "not yet granted" is the default state for a permission
                    // this sensitive, not a sign anything is broken.
                    statusColor: permissions.messagesAvailable
                        ? OhiaColors.chipActiveForeground
                        : .secondary
                ) {
                    if !permissions.messagesAvailable {
                        systemSettingsButton(pane: "Privacy_AllFiles")
                    }
                }
            }
        }
    }

    private func appRow(
        provider: ComposerSourceProvider,
        symbol: String,
        isEnabled: Binding<Bool>,
        status: String,
        statusColor: Color,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled.wrappedValue ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .foregroundStyle(isEnabled.wrappedValue ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            action()
            Toggle(provider.displayName, isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func grantButton(
        for provider: ComposerSourceProvider,
        request: @escaping () async -> Void
    ) -> some View {
        Button("Grant Access") {
            requestingProvider = provider
            Task {
                await request()
                permissions = await AppSourcePermissions.current(
                    messagesBroker: messagesTranscriptBroker
                )
                requestingProvider = nil
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
        .disabled(requestingProvider != nil)
    }

    private func systemSettingsButton(pane: String) -> some View {
        Button("Open System Settings…") {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
    }

    private func openNotes() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: NotesAutomationPermission.notesBundleID
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var notesStatusText: String {
        switch permissions.notes {
        case .granted:         return "Automation access granted"
        case .denied:          return "Automation access denied"
        case .notDetermined:   return "Not yet requested"
        case .notesNotRunning: return "Notes must be open to use this source"
        }
    }

    private var notesStatusColor: Color {
        switch permissions.notes {
        case .granted: return OhiaColors.chipActiveForeground
        case .denied:  return OhiaColors.ohiaRed
        case .notDetermined, .notesNotRunning: return .secondary
        }
    }

    private var screenshotStatusText: String {
        switch permissions.screenshot {
        case .granted:
            return "Screen Recording granted"
        default:
            return screenshotRequestRefused
                ? "Not granted — enable Screen Recording in System Settings, then relaunch Ohia"
                : "Not yet granted"
        }
    }

    private var messagesStatusText: String {
        permissions.messagesAvailable
            ? "Full Disk Access granted"
            : "Needs Full Disk Access — enable Ohia in System Settings ▸ Privacy & Security ▸ Full Disk Access"
    }

    // MARK: - MCP Servers

    private var mcpSection: some View {
        OhiaSettingsCard("MCP Servers") {
            SettingsCaption("Model Context Protocol servers feed drafting as sources alongside the apps above. Ohia connects only to HTTPS endpoints you configure and save. Credentials live in your Keychain. Automatic queries are off until you opt in from the server editor.")
            SettingsRowDivider()
            SettingsBlock {
                if store.servers.isEmpty {
                    Text("No servers configured")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                } else {
                    ForEach(store.servers) { server in
                        mcpRow(server, credentialRevision: mcpCredentialRevision)
                    }
                }
            }
            SettingsRowDivider()
            SettingsBlock {
                addServerMenu
            }
        }
    }

    private func mcpRow(
        _ server: MCPConfiguredServer,
        credentialRevision: Int
    ) -> some View {
        _ = credentialRevision
        return HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(server.isEnabled ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .foregroundStyle(server.isEnabled ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                    if server.service != .custom {
                        Text(server.service.displayName)
                            .font(.caption2)
                            .foregroundStyle(OhiaColors.textTertiary)
                    }
                }
                Text(endpointLine(for: server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(credentialSummary(for: server))
                    .font(.caption)
                    .foregroundStyle(credentialMissing(for: server) ? OhiaColors.ohiaRed : .secondary)
                if let status = mcpStatuses[server.id] {
                    Text(statusLine(for: status))
                        .font(.caption)
                        .foregroundStyle(statusColor(for: status))
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                testConnection(for: server)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 6, verticalPadding: 3))
            .disabled(!server.isEnabled || mcpStatuses[server.id] == .testing)
            .help("Test the connection and list the server's tools")
            Button {
                editorContext = MCPServerEditorContext(
                    server: server,
                    environment: store.environment(for: server.id),
                    isNew: false
                )
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 6, verticalPadding: 3))
            .help("Edit this server")
            Button {
                pendingRemoval = server
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaRed, horizontalPadding: 6, verticalPadding: 3))
            .help("Remove this server")
            Toggle(server.displayName, isOn: Binding(
                get: { server.isEnabled },
                set: { enabled in
                    do {
                        try store.setEnabled(enabled, id: server.id)
                        if server.usesHostedOAuth {
                            // Token rotation should track the enable switch:
                            // no background refreshes for a server that can't
                            // be queried, resume when it can again.
                            if enabled {
                                HostedMCPAuth.ensureKeepFreshForConfiguredServers()
                            } else {
                                HostedMCPAuth.suspendKeepFresh(serverID: server.id)
                            }
                        }
                        if !enabled {
                            // Disabling disconnects the live remote session.
                            mcpStatuses[server.id] = nil
                            Task { await MCPSessionManager.shared.invalidate(id: server.id) }
                        }
                    } catch {
                        storeErrorMessage = "Could not save the change: \(error.localizedDescription)"
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func endpointLine(for server: MCPConfiguredServer) -> String {
        server.remoteEndpointURL ?? "Missing HTTPS endpoint — edit or remove"
    }

    private func statusLine(for status: MCPConnectionStatus) -> String {
        switch status {
        case .testing:
            return "Connecting…"
        case .connected(let toolCount):
            switch toolCount {
            case 0:  return "Connected · no tools offered"
            case 1:  return "Connected · 1 tool"
            default: return "Connected · \(toolCount) tools"
            }
        case .failed(let message):
            return message
        }
    }

    private func statusColor(for status: MCPConnectionStatus) -> Color {
        switch status {
        case .testing:   return .secondary
        case .connected: return OhiaColors.chipActiveForeground
        case .failed:    return OhiaColors.ohiaRed
        }
    }

    /// Retires any live session first so a re-test picks up the edited
    /// endpoint and rotated credentials.
    private func testConnection(for server: MCPConfiguredServer) {
        mcpStatuses[server.id] = .testing
        Task {
            let environment: [String: String]
            if server.usesHostedOAuth {
                // Renews an expiring OAuth token before the HTTPS request;
                // never opens a browser.
                do {
                    environment = try await HostedMCPAuth.resolvedMCPEnvironment(
                        serverID: server.id,
                        service: server.service
                    )
                } catch {
                    let message = (error as? HostedMCPAuthError)?.errorDescription
                        ?? error.localizedDescription
                    mcpStatuses[server.id] = .failed(message)
                    return
                }
            } else {
                environment = store.environment(for: server.id)
            }
            await MCPSessionManager.shared.invalidate(id: server.id)
            let session = await MCPSessionManager.shared.session(for: server, environment: environment)
            do {
                let tools = try await session.availableTools()
                mcpStatuses[server.id] = .connected(toolCount: tools.count)
            } catch {
                mcpStatuses[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func credentialSummary(for server: MCPConfiguredServer) -> String {
        if server.usesHostedOAuth {
            // Live Keychain truth, not the record: an in-editor disconnect
            // that was never saved must not leave this row claiming a
            // connection that no longer exists.
            return HostedMCPAuth.isConnected(serverID: server.id, service: server.service)
                ? "Connected via \(server.service.displayName) sign-in"
                : "Not connected — open editor to sign in"
        }
        if let credential = server.service.credential {
            return server.environmentKeys.contains(credential.envKey)
                ? "\(credential.label) stored in Keychain"
                : "\(credential.label) not set"
        }
        switch server.environmentKeys.count {
        case 0:  return "No request headers"
        case 1:  return "1 request header in Keychain"
        default: return "\(server.environmentKeys.count) request headers in Keychain"
        }
    }

    private func credentialMissing(for server: MCPConfiguredServer) -> Bool {
        if server.usesHostedOAuth {
            return !HostedMCPAuth.isConnected(serverID: server.id, service: server.service)
        }
        return server.environmentKeys.isEmpty
    }

    private var addServerMenu: some View {
        Menu {
            ForEach(MCPConfiguredServer.Service.remoteCatalog, id: \.self) { service in
                preconfiguredServerButton(service)
            }
            Divider()
            Button("Custom Server…") {
                let draft = MCPConfiguredServer(
                    displayName: "",
                    service: .custom,
                    isEnabled: false,
                    automaticQueries: false
                )
                editorContext = MCPServerEditorContext(server: draft, environment: [:], isNew: true)
            }
        } label: {
            // Menus can't take a ButtonStyle; the label re-states the §3.7
            // emblem framing EmblemButtonStyle codifies.
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add Server")
                    .font(.caption)
            }
            .foregroundStyle(OhiaColors.ohiaGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(OhiaColors.buttonBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func preconfiguredServerButton(_ service: MCPConfiguredServer.Service) -> some View {
        Button("\(service.displayName)…") {
            guard let draft = MCPConfiguredServer.preconfigured(service) else { return }
            editorContext = MCPServerEditorContext(server: draft, environment: [:], isNew: true)
        }
    }
}

// MARK: - Permission snapshot

/// One read of every app-source permission, taken on appear, on
/// app-foreground, and after each grant request.
private struct AppSourcePermissions: Equatable {
    enum GrantState: Equatable {
        case granted
        case limited
        case denied
        /// Calendar-only: events can be written but not read — full access
        /// is required for availability, and only System Settings can
        /// upgrade the grant.
        case writeOnly
        case notDetermined

        var statusText: String {
            switch self {
            case .granted:       return "Access granted"
            case .limited:       return "Limited access granted"
            case .denied:        return "Access denied"
            case .writeOnly:     return "Write-only access — full access needed to read events"
            case .notDetermined: return "Not yet requested"
            }
        }

        var statusColor: Color {
            switch self {
            case .granted, .limited: return OhiaColors.chipActiveForeground
            case .denied, .writeOnly: return OhiaColors.ohiaRed
            case .notDetermined:     return .secondary
            }
        }
    }

    var calendar: GrantState = .notDetermined
    var contacts: GrantState = .notDetermined
    var notes: NotesAutomationPermission.Status = .notDetermined
    var screenshot: GrantState = .notDetermined
    /// Full Disk Access has no authorization API. The sandboxed reader
    /// service reports whether its Messages database is readable.
    var messagesAvailable = false

    @MainActor
    static func current(messagesBroker: MessagesTranscriptBroker?) async -> AppSourcePermissions {
        var snapshot = AppSourcePermissions()

        if CalendarSourceReader.isAuthorized {
            snapshot.calendar = .granted
        } else if CalendarSourceReader.isDenied {
            snapshot.calendar = .denied
        } else if EKEventStore.authorizationStatus(for: .event) == .writeOnly {
            snapshot.calendar = .writeOnly
        }

        switch ContactSourceReader.authorizationStatus {
        case .authorized:          snapshot.contacts = .granted
        case .limited:             snapshot.contacts = .limited
        case .denied, .restricted: snapshot.contacts = .denied
        default:                   snapshot.contacts = .notDetermined
        }

        snapshot.notes = NotesAutomationPermission.status()

        // CGPreflight can't distinguish denied from not-yet-asked; the view
        // refines "notDetermined" after a refused request.
        snapshot.screenshot = ScreenCaptureService.isAuthorized ? .granted : .notDetermined

        snapshot.messagesAvailable = await messagesBroker?.accessStatus() ?? false

        return snapshot
    }
}
