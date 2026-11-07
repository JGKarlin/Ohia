// Ohia/Settings/MCPServerEditorSheet.swift
// Create/edit modal for one configured MCP server (Settings → Sources).
//
// Catalog services pin a verified hosted HTTPS endpoint and expose one
// Keychain-backed credential. Slack, Notion, and Firecrawl offer browser
// OAuth; Firecrawl also retains an API-key option.
// Custom servers expose an HTTPS endpoint plus explicit request headers.
// Ohia never downloads or launches an MCP executable.

import SwiftUI
import OhiaML

/// What the sheet edits: the record, its stored environment values, and
/// whether this is a first save.
struct MCPServerEditorContext: Identifiable {
    let server: MCPConfiguredServer
    let environment: [String: String]
    let isNew: Bool
    var id: UUID { server.id }
}

struct MCPServerEditorSheet: View {
    let context: MCPServerEditorContext
    let store: MCPServerStore

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var remoteEndpointURL: String
    @State private var credentialValue: String
    @State private var headerRows: [HeaderRow]
    @State private var automaticQueries: Bool
    @State private var validationMessage: String?
    @State private var firecrawlAuthMethod: MCPConfiguredServer.FirecrawlAuthMethod
    @State private var oauthConnectionState: HostedMCPAuth.ConnectionState
    @State private var oauthConnecting = false
    /// Whether this sheet performed the connect — a cancelled new record
    /// must not leave freshly minted tokens behind in the Keychain.
    @State private var oauthConnectedThisSheet = false
    /// Set by save and explicit cancel; `onDisappear` cleans up abandoned
    /// auth state only when neither ran (window closed over the sheet).
    @State private var sheetResolved = false

    private struct HeaderRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(context: MCPServerEditorContext, store: MCPServerStore) {
        self.context = context
        self.store = store
        let server = context.server
        _displayName = State(initialValue: server.displayName)
        _remoteEndpointURL = State(initialValue: server.remoteEndpointURL ?? "")
        _automaticQueries = State(initialValue: server.automaticQueries)
        _firecrawlAuthMethod = State(initialValue: server.firecrawlAuthMethod ?? .apiKey)
        _oauthConnectionState = State(initialValue: server.usesHostedOAuth
            ? HostedMCPAuth.connectionState(serverID: server.id, service: server.service)
            : .disconnected)
        if server.service.supportsHostedOAuth {
            _credentialValue = State(initialValue: Self.initialCredentialValue(
                for: server,
                environment: context.environment
            ))
            _headerRows = State(initialValue: [])
        } else if let credential = server.service.credential {
            _credentialValue = State(initialValue: context.environment[credential.envKey] ?? "")
            _headerRows = State(initialValue: [])
        } else {
            _credentialValue = State(initialValue: "")
            _headerRows = State(initialValue: context.environment
                .sorted { $0.key < $1.key }
                .map { HeaderRow(key: $0.key, value: $0.value) })
        }
    }

    private var isCustom: Bool { context.server.service == .custom }

    static func initialCredentialValue(
        for server: MCPConfiguredServer,
        environment: [String: String]
    ) -> String {
        guard !server.usesHostedOAuth,
              let credential = server.service.credential else { return "" }
        return environment[credential.envKey] ?? ""
    }

    static func hostedOAuthSetupMessage(
        for service: MCPConfiguredServer.Service,
        isAvailable: Bool
    ) -> String? {
        guard !isAvailable else { return nil }
        return "\(service.displayName) sign-in requires release setup before this connector is available."
    }

    static func shouldRefreshOAuthConnectionState(
        notificationServerID: UUID?,
        editedServerID: UUID
    ) -> Bool {
        notificationServerID == nil || notificationServerID == editedServerID
    }

    private static func hostedOAuthSetupMessage(
        for service: MCPConfiguredServer.Service
    ) -> String? {
        hostedOAuthSetupMessage(
            for: service,
            isAvailable: HostedMCPAuth.isServiceAvailable(service)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(context.isNew ? "Add \(context.server.service == .custom ? "Custom Server" : context.server.service.displayName)" : "Edit \(context.server.displayName)")
                    .font(.headline)
                Text("An MCP server that will supply draft sources. Credentials are stored in your Keychain, never in the configuration file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Name") {
                        TextField("Server name", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if isCustom {
                        customEndpointField
                        customHeaderFields
                    } else {
                        preconfiguredFields
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            context.server.service.isWebResearchService
                                ? "Research the web for new drafts"
                                : "Research this source for new drafts",
                            isOn: $automaticQueries
                        )
                        Text("When enabled, Ohia derives privacy-filtered research questions from the message or compose brief and sends those questions to this third-party server. Only read/search tools run automatically; tools that create, change, or delete anything remain manual.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if context.server.service == .firecrawl {
                            Text("Searching uses your Firecrawl credits. Automatic mode uses search snippets and may fetch result pages locally.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(OhiaColors.ohiaRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            HStack {
                Spacer()
                Button("Cancel") { cancelAndDismiss() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                    .keyboardShortcut(.cancelAction)
                Button(context.isNew ? "Add Server" : "Save") { save() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 460)
        .frame(maxHeight: 560)
        .tint(OhiaColors.chipActiveForeground)
        .onChange(of: firecrawlAuthMethod) {
            validationMessage = nil
            if firecrawlAuthMethod == .apiKey {
                // Leaving OAuth abandons a sign-in still waiting on the
                // browser; already-staged tokens are dealt with at save.
                HostedMCPAuth.cancelConnect()
            } else {
                oauthConnectionState = HostedMCPAuth.connectionState(
                    serverID: context.server.id,
                    service: context.server.service
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .ohiaMCPServerInjectableEnvironmentDidChange
            )
        ) { notification in
            guard Self.shouldRefreshOAuthConnectionState(
                notificationServerID: notification.object as? UUID,
                editedServerID: context.server.id
            ) else { return }
            oauthConnectionState = HostedMCPAuth.connectionState(
                serverID: context.server.id,
                service: context.server.service
            )
        }
        .onDisappear {
            // Teardown that bypasses the buttons (the Settings window
            // closing over the sheet) must clean up like Cancel does.
            if !sheetResolved { abandonHostedAuth() }
        }
    }

    // MARK: - Preconfigured

    @ViewBuilder
    private var preconfiguredFields: some View {
        let service = context.server.service
        labeledField("HTTPS endpoint") {
            Text(context.server.remoteEndpointURL ?? "Unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if service == .firecrawl {
            firecrawlAuthSection
        } else if service.supportsHostedOAuth {
            hostedOAuthFields
        } else if let credential = service.credential {
            credentialEntryFields(credential, service: service)
        }
    }

    @ViewBuilder
    private func credentialEntryFields(
        _ credential: (envKey: String, label: String, isSecret: Bool),
        service: MCPConfiguredServer.Service
    ) -> some View {
        labeledField(credential.label) {
            if credential.isSecret {
                SecureField(credential.label, text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("/path/to/credentials.json", text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
            }
        }
        Text("Stored in your Keychain as \(credential.envKey).")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let signupHint = service.credentialSignupHint {
            Text(signupHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Firecrawl dual auth

    @ViewBuilder
    private var firecrawlAuthSection: some View {
        labeledField("Sign-in method") {
            Picker("Sign-in method", selection: $firecrawlAuthMethod) {
                Text("Sign in with Firecrawl")
                    .tag(MCPConfiguredServer.FirecrawlAuthMethod.oauth)
                Text("API key")
                    .tag(MCPConfiguredServer.FirecrawlAuthMethod.apiKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if firecrawlAuthMethod == .oauth {
            hostedOAuthFields
        } else if let credential = context.server.service.credential {
            credentialEntryFields(credential, service: context.server.service)
        }
    }

    @ViewBuilder
    private var hostedOAuthFields: some View {
        let service = context.server.service
        if let setupMessage = Self.hostedOAuthSetupMessage(for: service) {
            Text(setupMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(hostedOAuthDescription(for: service))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                oauthStepRow(1, "Click Connect below")
                oauthStepRow(2, "Sign in to \(service.displayName) in the browser if asked")
                oauthStepRow(3, "Review access and click Allow")
                oauthStepRow(4, "Return to Ohia — connection completes automatically")
            }

            switch oauthConnectionState {
            case .connected:
                HStack(spacing: 10) {
                    Text("Connected to \(service.displayName)")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                    Button("Disconnect") { disconnectHostedOAuth() }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                }
            case .publicationPending:
                Text("Finishing the \(service.displayName) credential update")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .reconnectRequired:
                HStack(spacing: 10) {
                    Text("Connection expired — reconnect required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    connectHostedOAuthButton(label: "Reconnect to \(service.displayName)")
                }
            case .disconnected:
                connectHostedOAuthButton(label: "Connect to \(service.displayName)")
            case .unavailable:
                EmptyView()
            }

            if oauthConnecting {
                Text("Waiting for browser sign-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectHostedOAuthButton(label: String) -> some View {
        Button(label) { connectHostedOAuth() }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
            .disabled(oauthConnecting)
    }

    private func hostedOAuthDescription(
        for service: MCPConfiguredServer.Service
    ) -> String {
        switch service {
        case .firecrawl:
            return "Ohia opens firecrawl.dev in your browser. Usage counts against your Firecrawl account."
        case .notion:
            return "Ohia opens Notion in your browser so you can choose and authorize a workspace."
        case .slack:
            return "Ohia opens Slack in your browser and requests read-only access for finding source material."
        case .github, .custom:
            return "Ohia opens the service in your browser to authorize this connection."
        }
    }

    private func oauthStepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectHostedOAuth() {
        let service = context.server.service
        guard HostedMCPAuth.isServiceAvailable(service) else {
            oauthConnectionState = .unavailable
            validationMessage = Self.hostedOAuthSetupMessage(for: service)
            return
        }
        validationMessage = nil
        oauthConnecting = true
        let serverID = context.server.id
        Task {
            do {
                try await HostedMCPAuth.connect(serverID: serverID, service: service)
                oauthConnectionState = .connected
                oauthConnectedThisSheet = true
            } catch is CancellationError {
                // The sheet abandoned the flow (cancel, mode switch) — no
                // message; the staged state was never written.
            } catch {
                oauthConnectionState = HostedMCPAuth.connectionState(
                    serverID: serverID,
                    service: service
                )
                validationMessage = (error as? HostedMCPAuthError)?.errorDescription
                    ?? error.localizedDescription
            }
            oauthConnecting = false
        }
    }

    private func disconnectHostedOAuth() {
        HostedMCPAuth.cancelConnect()
        let serverID = context.server.id
        do {
            try HostedMCPAuth.disconnect(
                serverID: serverID,
                service: context.server.service
            )
            oauthConnectionState = .disconnected
            oauthConnectedThisSheet = false
            Task { await MCPSessionManager.shared.invalidate(id: serverID) }
        } catch {
            validationMessage = "Could not disconnect: \(error.localizedDescription)"
        }
    }

    /// Abandons any in-flight browser sign-in and disposes tokens the sheet
    /// staged for a record that is not (or not yet) an OAuth record — an
    /// abandoned sheet must leave no orphaned Keychain state behind. A
    /// re-auth staged for an existing OAuth record is kept: its rotation
    /// already superseded the old grant.
    private func abandonHostedAuth() {
        guard context.server.service.supportsHostedOAuth else { return }
        HostedMCPAuth.cancelConnect()
        if oauthConnectedThisSheet,
           context.isNew || !context.server.usesHostedOAuth {
            try? HostedMCPAuth.disconnect(
                serverID: context.server.id,
                service: context.server.service
            )
        }
    }

    private func cancelAndDismiss() {
        abandonHostedAuth()
        sheetResolved = true
        dismiss()
    }

    // MARK: - Custom

    @ViewBuilder
    private var customEndpointField: some View {
        labeledField("HTTPS endpoint") {
            TextField("https://mcp.example.com/mcp", text: $remoteEndpointURL)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var customHeaderFields: some View {
        labeledField("Request headers") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($headerRows) { $row in
                    HStack(spacing: 6) {
                        TextField("Authorization", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        SecureField("value", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            headerRows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 6, verticalPadding: 3))
                        .help("Remove this header")
                    }
                }
                Button {
                    headerRows.append(HeaderRow(key: "", value: ""))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Add Header")
                            .font(.caption)
                    }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
            }
        }
        Text("Header values are stored in your Keychain; the configuration file keeps header names only.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func labeledField(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Save

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationMessage = "Give the server a name."
            return
        }

        var server = context.server
        server.displayName = name
        server.automaticQueries = automaticQueries

        var environment: [String: String] = [:]

        if context.server.service == .firecrawl {
            server.firecrawlAuthMethod = firecrawlAuthMethod
            switch firecrawlAuthMethod {
            case .apiKey:
                // Any browser flow still waiting must not stage tokens after
                // this save; staged material is cleared only once the save
                // has actually persisted (below), so a failed write never
                // destroys tokens the on-disk record still references.
                HostedMCPAuth.cancelConnect()
                let value = credentialValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    environment[MCPConfiguredServer.FirecrawlAuthMethod.apiKey.environmentKey] = value
                }
            case .oauth:
                // Publishing the staged access token into the injectable
                // credential snapshot happens here and only here — a connect
                // that was never saved never reaches a remote request.
                do {
                    environment = try HostedMCPAuth.injectableOAuthEnvironment(
                        serverID: server.id,
                        service: server.service
                    )
                } catch {
                    validationMessage = "Connect to Firecrawl before saving."
                    return
                }
            }
        } else if context.server.service.supportsHostedOAuth {
            if let setupMessage = Self.hostedOAuthSetupMessage(
                for: context.server.service
            ) {
                validationMessage = setupMessage
                return
            }
            do {
                environment = try HostedMCPAuth.injectableOAuthEnvironment(
                    serverID: server.id,
                    service: server.service
                )
            } catch {
                validationMessage = "Connect to \(server.service.displayName) before saving."
                return
            }
        } else if isCustom {
            let endpoint = remoteEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else {
                validationMessage = "A custom server needs an HTTPS endpoint."
                return
            }
            server.remoteEndpointURL = endpoint

            var seenKeys = Set<String>()
            for row in headerRows {
                let key = row.key.trimmingCharacters(in: .whitespaces)
                let value = row.value.trimmingCharacters(in: .whitespaces)
                if key.isEmpty && value.isEmpty { continue } // leftover blank row
                guard !key.isEmpty else {
                    validationMessage = "A request header value is missing its name."
                    return
                }
                guard !value.isEmpty else {
                    validationMessage = "Request header \(key) has no value."
                    return
                }
                let normalizedKey = key.lowercased()
                guard seenKeys.insert(normalizedKey).inserted else {
                    validationMessage = "Request header \(key) is listed twice."
                    return
                }
                environment[key] = value
            }
            do {
                _ = try server.validatedRemoteEndpoint()
                _ = try MCPClientSession.validatedRequestHeaders(
                    config: server,
                    environment: environment
                )
            } catch {
                validationMessage = error.localizedDescription
                return
            }
        } else if let credential = context.server.service.credential {
            let value = credentialValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                environment[credential.envKey] = value
            }
        }

        // Saving a new server is the user's explicit enablement decision.
        // Automatic drafting queries remain a separate, opt-in setting.
        if context.isNew {
            server.isEnabled = true
        }

        do {
            try store.upsert(server, environment: environment)
            if server.service == .firecrawl {
                switch firecrawlAuthMethod {
                case .apiKey:
                    // The save is durable — now the OAuth material (refresh
                    // token, keep-fresh loop) can be safely discarded.
                    HostedMCPAuth.clearAppOnlyMaterial(serverID: server.id)
                case .oauth:
                    // Editing an existing record must (re)arm rotation even
                    // when this sheet performed no fresh connect.
                    HostedMCPAuth.ensureKeepFreshForConfiguredServers()
                }
            } else if server.usesHostedOAuth {
                HostedMCPAuth.ensureKeepFreshForConfiguredServers()
            }
            // Retire any live session so the edited endpoint or rotated
            // credential applies to the next connection.
            let id = server.id
            Task { await MCPSessionManager.shared.invalidate(id: id) }
            sheetResolved = true
            dismiss()
        } catch {
            validationMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
