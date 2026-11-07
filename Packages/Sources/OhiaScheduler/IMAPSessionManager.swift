import Foundation
import SwiftData
import Network
import Observation
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public protocol IMAPActivityReporting: AnyObject {
    func reportIMAPActivity(
        _ kind: WorkerIMAPActivityKind,
        accountID: UUID,
        folder: String?
    )

    func completeIMAPActivity(accountID: UUID, folder: String?, operationID: UUID?)

    /// Ends the active operation in a persistent failure state. Retrying
    /// failures use the reconnecting motif; terminal/auth failures require
    /// explicit attention until a later same-account transition arrives.
    func failIMAPActivity(
        accountID: UUID,
        folder: String?,
        requiresAttention: Bool,
        cause: WorkerIMAPAttentionCause,
        operationID: UUID?
    )
}

public extension IMAPActivityReporting {
    func failIMAPActivity(
        accountID: UUID,
        folder: String?,
        requiresAttention: Bool,
        cause: WorkerIMAPAttentionCause,
        operationID: UUID?
    ) {}
}

@MainActor
@Observable
public final class IMAPSessionManager: IMAPSessionStatusReporting, IMAPActivityReporting {
    public private(set) var statusByAccount: [UUID: IMAPSessionStatus] = [:]

    /// True when any session is mid-handshake or mid-sync. `.idling` and
    /// `.selected` are steady states and do not count as active work.
    public var hasActiveIMAPWork: Bool {
        statusByAccount.values.contains { status in
            switch status {
            case .connecting, .authing, .syncing, .reconnecting:
                return true
            case .disconnected, .selected, .idling, .halted:
                return false
            }
        }
    }

    private var sessions: [UUID: IMAPSession] = [:]
    /// Sessions created for an explicit UI/manual refresh. They keep an
    /// auxiliary IMAP client warm for one-shot work, but do not start the
    /// primary IDLE/live loop until the app actually falls back to owning
    /// background IMAP.
    private var manualWorkSessionIDs: Set<UUID> = []
    /// Tracks the operating mode the session was started in so a manual
    /// deletion-watch session can be promoted to the normal full session.
    private var sessionModes: [UUID: IMAPSession.SessionMode] = [:]
    private let modelContext: ModelContext
    private let canonicalStore: CanonicalStore
    private let credentialsResolver: ManagerCredentialsResolver
    private let ingestBridge: ManagerIngestBridge
    private let folderStateBridge: ManagerFolderStateBridge
    private let deletionSyncCoordinator: DeletionSyncCoordinator?
    private let pendingDeletionReaperWorker: PendingDeletionReaperWorker?
    private let flagSyncCoordinator: IMAPFlagSyncCoordinator
    private let deletionSyncStatusPublisher: DeletionSyncStatusPublisher?
    private let liveInboundBroadcaster: JobCompletionBroadcaster?
    private let onDetectedInbound: @MainActor ([UUID]) -> Void
    private let pathMonitor: NWPathMonitor
    private let pathMonitorQueue: DispatchQueue
    private var imapActivityReporter: (@MainActor @Sendable (WorkerIMAPActivitySnapshot) -> Void)?
    private var isStarted = false
    #if canImport(AppKit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    #endif

    private enum DetachedStopStatusDisposition {
        case markDisconnected
        case remove
    }

    public init(
        modelContext: ModelContext,
        oauthStore: OAuthTokenStore,
        passwordResolver: any MailPasswordResolving = UnavailableMailCredentialResolver(),
        canonicalStore: CanonicalStore,
        vectorStore: VectorStore? = nil,
        neighborsStore: VectorNeighborsStore? = nil,
        frameLayoutStore: VectorFrameLayoutStore? = nil,
        clusterStore: VectorClusterStore? = nil,
        liveInboundBroadcaster: JobCompletionBroadcaster? = nil,
        deletionSyncStatusPublisher: DeletionSyncStatusPublisher? = nil,
        onDetectedInbound: @escaping @MainActor ([UUID]) -> Void = { _ in },
        onManualProjectSourceChange: @escaping @MainActor @Sendable (
            Set<UUID>,
            Set<MailProjectRuleFacet>
        ) -> Void = { _, _ in }
    ) {
        self.modelContext = modelContext
        self.canonicalStore = canonicalStore
        self.credentialsResolver = ManagerCredentialsResolver(
            modelContext: modelContext,
            oauthStore: oauthStore,
            passwordResolver: passwordResolver
        )
        self.ingestBridge = ManagerIngestBridge(
            modelContext: modelContext,
            canonicalStore: canonicalStore,
            onManualProjectSourceChange: onManualProjectSourceChange
        )
        self.folderStateBridge = ManagerFolderStateBridge(modelContext: modelContext)
        self.flagSyncCoordinator = IMAPFlagSyncCoordinator(modelContext: modelContext)
        self.liveInboundBroadcaster = liveInboundBroadcaster
        self.onDetectedInbound = onDetectedInbound
        if let vectorStore,
           let neighborsStore,
           let frameLayoutStore,
           let clusterStore,
           let deletionSyncStatusPublisher {
            let applier = MessageDeletionApplier(
                modelContext: modelContext,
                vectorStore: vectorStore,
                neighborsStore: neighborsStore,
                frameLayoutStore: frameLayoutStore,
                clusterStore: clusterStore,
                canonicalStore: canonicalStore,
                status: deletionSyncStatusPublisher
            )
            self.deletionSyncCoordinator = DeletionSyncCoordinator(
                modelContext: modelContext,
                applier: applier,
                status: deletionSyncStatusPublisher
            )
            self.pendingDeletionReaperWorker = PendingDeletionReaperWorker(
                modelContext: modelContext,
                applier: applier,
                status: deletionSyncStatusPublisher,
                onDeletionApplied: { messageIDs, completedAt in
                    guard messageIDs.isEmpty == false else { return }
                    liveInboundBroadcaster?.yield(JobCompletionEvent(
                        type: .pendingDeletionReaper,
                        payload: nil,
                        completedAt: completedAt,
                        messageMutations: [PipelineMessageMutation(
                            messageIDs: messageIDs,
                            facets: [.visibility]
                        )]
                    ))
                }
            )
            self.deletionSyncStatusPublisher = deletionSyncStatusPublisher
        } else {
            self.deletionSyncCoordinator = nil
            self.pendingDeletionReaperWorker = nil
            self.deletionSyncStatusPublisher = nil
        }
        self.pathMonitorQueue = DispatchQueue(label: "org.jgkarlin.Ohia.imap.pathmon")
        self.pathMonitor = NWPathMonitor()
    }

    public func start(
        allowsIMAPWork: Bool = true
    ) {
        // Bring up sessions for every IMAP account.
        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? modelContext.fetch(descriptor) else { return }
        for account in accounts
            where shouldMaintainSession(
                for: account,
                allowsIMAPWork: allowsIMAPWork
            ) {
            startSession(
                for: account,
                allowsIMAPWork: allowsIMAPWork
            )
        }

        guard !isStarted else { return }
        isStarted = true

        // Wire NWPathMonitor.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    await self.broadcastNetworkEvent(.pathRestored)
                } else {
                    await self.broadcastNetworkEvent(.pathLost)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)

        #if canImport(AppKit)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.broadcastNetworkEvent(.willSleep) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.broadcastNetworkEvent(.didWake) }
        }
        #endif
    }

    public func shutdown() async {
        pathMonitor.cancel()
        #if canImport(AppKit)
        if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = wakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        #endif
        await stopAllSessions(clearStatuses: true)
    }

    /// Stop live account sessions without tearing down the manager itself.
    ///
    /// `shutdown()` is terminal because it cancels the underlying
    /// `NWPathMonitor`; this helper is for app-level pipeline pauses/resets
    /// where the same manager may be started again later.
    public func stopAllSessions(clearStatuses: Bool = false) async {
        let activeSessions = sessions
        sessions.removeAll()
        sessionModes.removeAll()
        manualWorkSessionIDs.removeAll()
        for (_, session) in activeSessions {
            await session.stop()
        }
        if clearStatuses {
            statusByAccount.removeAll()
        } else {
            for accountID in activeSessions.keys {
                statusByAccount[accountID] = .disconnected
            }
        }
    }

    public func session(for accountID: UUID) -> IMAPSession? {
        sessions[accountID]
    }

    public func sessionForWork(
        accountID: UUID,
        allowsIMAPWork: Bool = true
    ) -> IMAPSession? {
        guard allowsIMAPWork else { return nil }
        if let session = sessions[accountID] {
            return session
        }
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard let account = try? modelContext.fetch(descriptor).first else {
            return nil
        }
        startSession(
            for: account,
            allowsIMAPWork: allowsIMAPWork
        )
        return sessions[accountID]
    }

    public func sessionForManualWork(accountID: UUID, livePollAllowed: Bool = true) -> IMAPSession? {
        if let session = sessions[accountID] {
            return session
        }
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard let account = try? modelContext.fetch(descriptor).first else {
            return nil
        }
        let mode: IMAPSession.SessionMode = livePollAllowed ? .full : .deletionWatchOnly
        guard let session = makeSession(for: account, mode: mode) else { return nil }
        sessions[accountID] = session
        sessionModes[accountID] = mode
        manualWorkSessionIDs.insert(accountID)
        statusByAccount[accountID] = .disconnected
        return session
    }

    public func setIMAPActivityReporter(
        _ reporter: @escaping @MainActor @Sendable (WorkerIMAPActivitySnapshot) -> Void
    ) {
        imapActivityReporter = reporter
    }

    public func reportIMAPActivity(
        _ kind: WorkerIMAPActivityKind,
        accountID: UUID,
        folder: String? = nil
    ) {
        publishActivity(WorkerIMAPActivitySnapshot(
            kind: kind,
            accountID: accountID,
            folder: folder,
            attentionCause: kind == .needsAttention
                ? Self.attentionCause(for: statusByAccount[accountID]) : nil
        ))
    }

    public static func attentionCause(for status: IMAPSessionStatus?) -> WorkerIMAPAttentionCause {
        guard case let .halted(reason) = status else { return .mailboxOperation }
        switch reason {
        case .authFailed, .reauthRequired: return .authentication
        case .certMismatch: return .certificate
        case .tlsError: return .secureConnection
        case .protocolViolation: return .protocolFailure
        }
    }

    public func completeIMAPActivity(accountID: UUID, folder: String? = nil, operationID: UUID? = nil) {
        let kind = statusByAccount[accountID].map(Self.activityKind(for:)) ?? .ready
        publishActivity(WorkerIMAPActivitySnapshot(
            kind: kind, accountID: accountID, folder: folder,
            attentionCause: kind == .needsAttention ? Self.attentionCause(for: statusByAccount[accountID]) : nil,
            operationID: operationID
        ))
    }

    public func failIMAPActivity(
        accountID: UUID,
        folder: String? = nil,
        requiresAttention: Bool,
        cause: WorkerIMAPAttentionCause,
        operationID: UUID? = nil
    ) {
        publishActivity(WorkerIMAPActivitySnapshot(
            kind: requiresAttention ? .needsAttention : .reconnecting,
            accountID: accountID,
            folder: folder,
            attentionCause: requiresAttention ? cause : nil,
            operationID: operationID
        ))
    }

    public static func attentionCause(for error: Error) -> WorkerIMAPAttentionCause {
        guard let error = error as? IMAPError else { return .mailboxOperation }
        switch error {
        case .authFailed, .reauthRequired: return .authentication
        case .mailStream(.certPinMismatch): return .certificate
        case .mailStream(.tlsHandshakeFailed): return .secureConnection
        case .protocolViolation, .notImapServer: return .protocolFailure
        default: return .mailboxOperation
        }
    }

    private func publishActivity(_ activity: WorkerIMAPActivitySnapshot) {
        SessionActivityLog.shared.record(SessionActivityEvent(
            operation: SessionActivityLog.operationTitle(activity.kind.rawValue),
            phase: activity.kind == .needsAttention ? .failed : .state,
            accountID: activity.accountID,
            detail: [activity.folder, activity.attentionCause?.explanation].compactMap { $0 }.joined(separator: " · "),
            timestamp: activity.occurredAt
        ))
        imapActivityReporter?(activity)
    }

    public func startSession(
        for account: Account,
        allowsIMAPWork: Bool = true,
        initialHistoryEstimate: IMAPHistoryEstimate? = nil
    ) {
        guard !AccountDisconnectionRequest.isPending else { return }
        guard account.imapHost != nil, account.imapKeychainRef != nil else { return }
        guard shouldMaintainSession(
            for: account,
            allowsIMAPWork: allowsIMAPWork
        ) else { return }
        let mode: IMAPSession.SessionMode = .full
        if let existing = sessions[account.id] {
            if manualWorkSessionIDs.remove(account.id) != nil {
                if sessionModes[account.id] == mode {
                    Task { await existing.start() }
                } else {
                    sessions.removeValue(forKey: account.id)
                    sessionModes.removeValue(forKey: account.id)
                    Task { await existing.stop() }
                }
            } else {
                return
            }
        }
        guard sessions[account.id] == nil else { return }
        guard let session = makeSession(
            for: account,
            mode: mode,
            initialHistoryEstimate: initialHistoryEstimate
        ) else { return }
        sessions[account.id] = session
        sessionModes[account.id] = mode
        Task { await session.start() }
    }

    private func makeSession(
        for account: Account,
        mode: IMAPSession.SessionMode,
        initialHistoryEstimate: IMAPHistoryEstimate? = nil
    ) -> IMAPSession? {
        guard let host = account.imapHost,
              let port = account.imapPort,
              let security = account.imapSecurity,
              let authMethod = account.imapAuthMethod else { return nil }
        let username = account.imapUsername ?? account.emailAddress
        return IMAPSession(
            accountID: account.id,
            accountEmailAddress: account.emailAddress,
            imapHost: host,
            imapPort: port,
            imapSecurity: security,
            imapAuthMethod: authMethod,
            imapUsername: username,
            pinnedCertSHA256: account.pinnedCertSHA256,
            credentialsResolver: credentialsResolver,
            statusReporter: self,
            ingestRaw: ingestBridge,
            folderStateStore: folderStateBridge,
            mode: mode,
            initialHistoryEstimate: initialHistoryEstimate
        )
    }

    public func syncSessions(
        allowsIMAPWork: Bool = true
    ) {
        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? modelContext.fetch(descriptor) else { return }

        let currentAccountIDs = Set(accounts.map(\.id))
        for accountID in Array(sessions.keys) where !currentAccountIDs.contains(accountID) {
            detachAndStopSession(for: accountID, statusDisposition: .remove)
        }
        for accountID in Array(statusByAccount.keys) where !currentAccountIDs.contains(accountID) {
            statusByAccount.removeValue(forKey: accountID)
        }

        for account in accounts {
            guard shouldMaintainSession(
                for: account,
                allowsIMAPWork: allowsIMAPWork
            ) else {
                detachAndStopSession(for: account.id, statusDisposition: .markDisconnected)
                continue
            }
            let desiredMode: IMAPSession.SessionMode = .full
            if let currentMode = sessionModes[account.id],
               currentMode != desiredMode {
                detachAndStopSession(for: account.id, statusDisposition: .markDisconnected)
            }
            if isStarted {
                startSession(
                    for: account,
                    allowsIMAPWork: allowsIMAPWork
                )
            }
        }
    }

    public func stopSession(for accountID: UUID) async {
        guard let s = sessions.removeValue(forKey: accountID) else {
            sessionModes.removeValue(forKey: accountID)
            manualWorkSessionIDs.remove(accountID)
            return
        }
        sessionModes.removeValue(forKey: accountID)
        manualWorkSessionIDs.remove(accountID)
        await s.stop()
        guard sessions[accountID] == nil else { return }
        statusByAccount[accountID] = .disconnected
    }

    /// Reauth entry point: tear down halted session, clear needsImapReauth,
    /// start a fresh session.
    public func reset(account: Account) async {
        await stopSession(for: account.id)
        account.needsImapReauth = false
        Self.clearIMAPFailureCooldowns(accountID: account.id, context: modelContext)
        try? modelContext.save()
        startSession(for: account)
    }

    @MainActor
    public static func clearIMAPFailureCooldowns(accountID: UUID, context: ModelContext) {
        guard let folderStates = try? context.fetch(FetchDescriptor<IMAPFolderState>()) else { return }
        let now = Date()
        for folderState in folderStates where folderState.account?.id == accountID {
            if folderState.lastPollFailureAt != nil || folderState.lastDeletionWatchFailureAt != nil {
                folderState.lastPollFailureAt = nil
                folderState.lastDeletionWatchFailureAt = nil
                folderState.updatedAt = now
            }
        }
    }

    public func markBackfillComplete(account: UUID, folder: String) {
        // Seeder reads IMAPFolderState.backfillComplete directly; no-op here
        // unless future logic needs to react to completion.
    }

    /// Thread reconciliation after an IMAP folder finishes historical backfill.
    /// The pass retries header matching for orphan rows, then applies the
    /// subject + participant-overlap fallback for mangled headers, on the same
    /// `modelContext` that ingested them.
    public func reconcileOrphanThreadsBySubject() async throws {
        do {
            let outcome = try await ThreadAssigner.reconcileOrphansBySubject(context: modelContext)
            if outcome.threadsCreated > 0 || outcome.messagesAttached > 0 {
                try modelContext.save()
                print("[IMAP] thread reconciliation: created \(outcome.threadsCreated) thread(s), attached \(outcome.messagesAttached) message(s)")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[IMAP] thread reconciliation failed: \(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - IMAPSessionStatusReporting

    public func reportStatus(_ status: IMAPSessionStatus, for accountID: UUID) {
        guard sessions[accountID] != nil else { return }
        let statusChanged = statusByAccount[accountID] != status
        statusByAccount[accountID] = status
        if statusChanged {
            reportIMAPActivity(Self.activityKind(for: status), accountID: accountID)
        }
        if case .halted(let reason) = status {
            markAccountForAttentionIfNeeded(accountID: accountID, reason: reason)
        }
    }

    public func reportDeletionEvent(_ event: IMAPDeletionEvent, for accountID: UUID) {
        guard sessions[accountID] != nil else { return }
        guard let deletionSyncCoordinator else { return }
        guard accountAllowsLiveIMAPEvents(for: accountID) else { return }
        Task { @MainActor in
            reportIMAPActivity(.reconciling, accountID: accountID, folder: event.folder)
            do {
                try await deletionSyncCoordinator.handle(
                    event: event,
                    accountID: accountID,
                    onDeletionApplied: { [weak self] messageIDs in
                        guard let self, messageIDs.isEmpty == false else { return }
                        self.liveInboundBroadcaster?.yield(JobCompletionEvent(
                            type: .imapDeletionWatch,
                            payload: nil,
                            completedAt: event.observedAt,
                            messageMutations: [PipelineMessageMutation(
                                messageIDs: messageIDs,
                                facets: [.visibility]
                            )]
                        ))
                    }
                )
                reportIMAPActivity(.deletionsUpdated, accountID: accountID, folder: event.folder)
            } catch {
                failIMAPActivity(
                    accountID: accountID,
                    folder: event.folder,
                    requiresAttention: true,
                    cause: .localReconciliation
                )
                deletionSyncStatusPublisher?.recordAbort(
                    folder: event.folder,
                    reason: .applierFailed(message: "\(error)")
                )
                print("[Ohia] Deletion sync failed: \(String(reflecting: type(of: error)))")
            }
        }
    }

    @discardableResult
    func runPendingDeletionReaper() async throws -> [UUID] {
        guard let pendingDeletionReaperWorker else { return [] }
        return try await pendingDeletionReaperWorker.runOnce()
    }

    public func reportFlagSnapshotEvent(_ event: IMAPFlagSnapshotEvent, for accountID: UUID) {
        guard sessions[accountID] != nil else { return }
        guard accountAllowsLiveIMAPEvents(for: accountID) else { return }
        do {
            _ = try flagSyncCoordinator.apply(event: event, accountID: accountID)
        } catch {
            print("[Ohia] IMAP flag sync failed: \(String(reflecting: type(of: error)))")
        }
    }

    public func reportNewInboundMessages(_ event: IMAPNewInboundMessageEvent, for accountID: UUID) {
        guard sessions[accountID] != nil else { return }
        var seenMessageIDs: Set<UUID> = []
        let messageIDs = event.messageIDs.filter { seenMessageIDs.insert($0).inserted }
        guard messageIDs.isEmpty == false else { return }
        reportIMAPActivity(.forming, accountID: accountID, folder: event.folder)
        defer { completeIMAPActivity(accountID: accountID, folder: event.folder) }
        onDetectedInbound(messageIDs)
        if messageIDs.isEmpty == false {
            do {
                try LiveInboundPipelinePrioritizer.seed(
                    messageIDs: messageIDs,
                    observedAt: event.observedAt,
                    context: modelContext
                )
            } catch {
                print("[Ohia] live inbound pipeline prioritization failed: \(String(reflecting: type(of: error)))")
            }
        }
        let payload = IMAPLiveInboundPayload(
            accountID: accountID,
            folder: event.folder,
            count: messageIDs.count,
            messageIDs: messageIDs,
            observedAt: event.observedAt
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        liveInboundBroadcaster?.yield(JobCompletionEvent(
            type: .imapLiveInbound,
            payload: json,
            completedAt: event.observedAt
        ))
    }

    private func accountAllowsLiveIMAPEvents(for accountID: UUID) -> Bool {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard let account = try? modelContext.fetch(descriptor).first else { return false }
        return account.imapHost != nil && account.imapKeychainRef != nil
    }

    private static func activityKind(for status: IMAPSessionStatus) -> WorkerIMAPActivityKind {
        switch status {
        case .disconnected:
            .ready
        case .connecting:
            .connecting
        case .authing:
            .authenticating
        case .syncing:
            .syncing
        case .selected, .idling:
            .watching
        case .reconnecting:
            .reconnecting
        case .halted:
            .needsAttention
        }
    }

    private func markAccountForAttentionIfNeeded(
        accountID: UUID,
        reason: IMAPSessionHaltReason
    ) {
        switch reason {
        case .authFailed, .reauthRequired:
            let descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { $0.id == accountID }
            )
            guard let account = try? modelContext.fetch(descriptor).first else { return }
            guard IMAPReauthGate.shouldMarkNeedsImapReauth(
                account: account,
                reason: reason
            ) else {
                return
            }
            account.needsImapReauth = true
            try? modelContext.save()
        case .certMismatch, .tlsError, .protocolViolation:
            break
        }
    }

    private func shouldMaintainSession(
        for account: Account,
        allowsIMAPWork: Bool
    ) -> Bool {
        guard allowsIMAPWork, !AccountDisconnectionRequest.isPending else { return false }
        return account.status != .paused
            && account.imapHost != nil
            && account.imapKeychainRef != nil
            && !account.needsImapReauth
    }

    // MARK: - Network event broadcast

    private func broadcastNetworkEvent(_ event: IMAPSession.NetworkEvent) async {
        for (_, session) in sessions {
            await session.handleNetworkEvent(event)
        }
    }

    private func detachAndStopSession(
        for accountID: UUID,
        statusDisposition: DetachedStopStatusDisposition
    ) {
        let hadStatus = statusByAccount[accountID] != nil
        sessionModes.removeValue(forKey: accountID)
        manualWorkSessionIDs.remove(accountID)
        guard let session = sessions.removeValue(forKey: accountID) else {
            applyStatusDisposition(
                statusDisposition,
                for: accountID,
                hadDetachedSessionOrStatus: hadStatus
            )
            return
        }

        applyStatusDisposition(
            statusDisposition,
            for: accountID,
            hadDetachedSessionOrStatus: true
        )

        Task { @MainActor [weak self] in
            await session.stop()
            guard let self, self.sessions[accountID] == nil else { return }
            self.applyStatusDisposition(
                statusDisposition,
                for: accountID,
                hadDetachedSessionOrStatus: true
            )
        }
    }

    private func applyStatusDisposition(
        _ disposition: DetachedStopStatusDisposition,
        for accountID: UUID,
        hadDetachedSessionOrStatus: Bool
    ) {
        switch disposition {
        case .markDisconnected:
            if hadDetachedSessionOrStatus {
                statusByAccount[accountID] = .disconnected
            }
        case .remove:
            statusByAccount.removeValue(forKey: accountID)
        }
    }
}

// MARK: - Bridge types (main-actor-bound SwiftData adapters)

@MainActor
final class ManagerCredentialsResolver: IMAPCredentialsResolving {
    // `nonisolated(unsafe)` is safe: the ModelContext is only touched from
    // inside `MainActor.run { ... }` blocks below, serializing all access
    // onto the main actor.
    nonisolated(unsafe) let modelContext: ModelContext
    let oauthStore: OAuthTokenStore
    let passwordResolver: any MailPasswordResolving
    init(
        modelContext: ModelContext,
        oauthStore: OAuthTokenStore,
        passwordResolver: any MailPasswordResolving
    ) {
        self.modelContext = modelContext
        self.oauthStore = oauthStore
        self.passwordResolver = passwordResolver
    }

    nonisolated func passwordForAccount(_ accountID: UUID) async throws -> String {
        do {
            let keychainReference = try await MainActor.run {
                let d = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
                guard let account = try modelContext.fetch(d).first else {
                    throw IMAPError.notConnected
                }
                return try IMAPCredentials().keychainReference(for: account)
            }
            return try await passwordResolver.password(
                kind: .imapPassword,
                keychainReference: keychainReference
            )
        } catch {
            if KeychainHelpers.isUserDeniedAccess(error)
                || error as? MailCredentialBrokerError == .accessDenied {
                throw IMAPError.reauthRequired(serverText: "Keychain access was denied")
            }
            throw error
        }
    }

    nonisolated func oauthAccessTokenForAccount(_ accountID: UUID, provider: MailProvider.OAuthProviderID) async throws -> String {
        // Don't ferry Account across the MainActor boundary (PersistentModel
        // is not Sendable). Extract the sendable keychain ref on MainActor
        // and operate on that.
        let ref: String = try await MainActor.run {
            let d = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try modelContext.fetch(d).first else {
                throw IMAPError.notConnected
            }
            // Fall back to the SMTP keychain ref if IMAP-specific ref isn't
            // set yet (first-time IMAP on an existing SMTP-OAuth account
            // shares the token — they're consented as a union scope).
            guard let r = account.imapKeychainRef ?? account.smtpKeychainRef else {
                throw IMAPError.reauthRequired(serverText: "no OAuth token stored")
            }
            return r
        }

        do {
            // In worker processes this single call goes through the main-app
            // token broker, so helpers never read the stored OAuth refresh
            // token directly and IMAP auth only pays for one broker round-trip.
            return try await oauthStore.imapAccessTokenByKeychainRef(
                ref,
                provider: provider,
                forceRefresh: false
            )
        } catch OAuthTokenStoreError.noStoredTokens {
            throw IMAPError.reauthRequired(serverText: "no OAuth token stored")
        } catch OAuthTokenStoreError.missingKeychainRef {
            throw IMAPError.reauthRequired(serverText: "no OAuth keychain reference")
        } catch OAuthTokenStoreError.insufficientIMAPScope {
            throw IMAPError.reauthRequired(serverText: "stored OAuth scope missing IMAP permission")
        } catch OAuthTokenStoreError.refreshRejected(let message) {
            throw IMAPError.reauthRequired(serverText: message)
        } catch let error as OAuthTokenHTTPError where error.isAuthorizationFailure {
            throw IMAPError.reauthRequired(
                serverText: error.errorDescription ?? "OAuth token request was rejected"
            )
        } catch let error as MailCredentialBrokerError {
            switch error {
            case .missingCredential:
                throw IMAPError.reauthRequired(serverText: "no OAuth token stored")
            case .accessDenied:
                throw IMAPError.reauthRequired(serverText: "OAuth token access was denied by Keychain")
            case .insufficientIMAPScope:
                throw IMAPError.reauthRequired(serverText: "stored OAuth scope missing IMAP permission")
            case .refreshRejected:
                throw IMAPError.reauthRequired(serverText: "OAuth token refresh was rejected")
            case .unavailable, .invalidRequest, .incompatibleResponse:
                throw error
            }
        } catch {
            if KeychainHelpers.isUserDeniedAccess(error) {
                throw IMAPError.reauthRequired(serverText: "OAuth token access was denied by Keychain")
            }
            throw error
        }
    }
}

@MainActor
final class ManagerIngestBridge: IMAPRawMessageIngesting {
    static let manualProjectIngestionFacets: Set<MailProjectRuleFacet> = [
        .account,
        .correspondent,
        .mailingList,
        .language,
        .subject,
        .body,
        .attachmentFilename,
        .attachmentText,
    ]

    // `nonisolated(unsafe)` is safe: touched only inside `MainActor.run`.
    nonisolated(unsafe) let modelContext: ModelContext
    nonisolated let canonicalStore: CanonicalStore
    private let onManualProjectSourceChange: @MainActor @Sendable (
        Set<UUID>,
        Set<MailProjectRuleFacet>
    ) -> Void

    init(
        modelContext: ModelContext,
        canonicalStore: CanonicalStore,
        onManualProjectSourceChange: @escaping @MainActor @Sendable (
            Set<UUID>,
            Set<MailProjectRuleFacet>
        ) -> Void = { _, _ in }
    ) {
        self.modelContext = modelContext
        self.canonicalStore = canonicalStore
        self.onManualProjectSourceChange = onManualProjectSourceChange
    }

    nonisolated func ingestRawRFC5322(
        data: Data,
        accountID: UUID,
        folderPath: String,
        serverUID: UInt32,
        receivedAt: Date?,
        seenAtSource: Bool?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> IMAPRawMessageIngestionResult {
        try await ingestRawRFC5322(
            data: data,
            accountID: accountID,
            folderPath: folderPath,
            folderAttributes: [],
            serverUID: serverUID,
            folderUIDValidity: nil,
            receivedAt: receivedAt,
            seenAtSource: seenAtSource,
            automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
        )
    }

    nonisolated func ingestRawRFC5322(
        data: Data,
        accountID: UUID,
        folderPath: String,
        folderAttributes: [String],
        serverUID: UInt32,
        folderUIDValidity: UInt32?,
        receivedAt: Date?,
        seenAtSource: Bool?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> IMAPRawMessageIngestionResult {
        try await MainActor.run {
            let d = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try modelContext.fetch(d).first else { return .skipped }
            let o = IngestionOrchestrator(context: modelContext, canonicalStore: canonicalStore)
            let liveDetectedAt = automaticallySummarizeNewMessages ? Date() : nil
            let result = try o.ingestRawRFC5322(
                data: data,
                account: account,
                folderPath: folderPath,
                folderAttributes: folderAttributes,
                serverUID: serverUID,
                folderUIDValidity: folderUIDValidity,
                receivedAt: receivedAt,
                seenAtSource: seenAtSource,
                liveDetectedAt: liveDetectedAt
            )
            try modelContext.save()
            if automaticallySummarizeNewMessages, result.shouldAutomaticallySummarize {
                try Self.enqueueAutomaticSummaryIfNeeded(
                    messageID: result.messageId,
                    context: modelContext
                )
            }
            if let messageID = result.messageId,
               result.disposition != .skipped {
                onManualProjectSourceChange(
                    [messageID],
                    Self.manualProjectIngestionFacets
                )
            }
            return result
        }
    }

    @MainActor
    private static func enqueueAutomaticSummaryIfNeeded(
        messageID: UUID?,
        context: ModelContext
    ) throws {
        guard let messageID else { return }
        let descriptor = FetchDescriptor<Job>(
            predicate: #Predicate { job in
                job.messageId == messageID
            }
        )
        let jobs = try context.fetch(descriptor)
        if let existing = jobs.first(where: { job in
            job.type == .summarize
                && job.messageId == messageID
                && (job.status == .pending || job.status == .running || job.status == .failed)
        }) {
            guard existing.status != .running else { return }
            existing.status = .pending
            existing.priority = min(existing.priority, 4)
            existing.startedAt = nil
            existing.completedAt = nil
            existing.error = nil
            existing.nextAttemptAt = nil
            existing.retryCount = 0
            try context.save()
            return
        }
        try JobQueue().enqueue(
            type: .summarize,
            priority: 4,
            messageId: messageID,
            context: context
        )
    }
}

@MainActor
final class ManagerFolderStateBridge: IMAPFolderStateReading {
    // `nonisolated(unsafe)` is safe: touched only inside `MainActor.run`.
    nonisolated(unsafe) let modelContext: ModelContext
    private var requiredInitialImportCorpusFolders: [UUID: Set<String>] = [:]
    private let now: @MainActor () -> Date

    init(
        modelContext: ModelContext,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.modelContext = modelContext
        self.now = now
    }

    nonisolated func readFolderState(accountID: UUID, folderName: String) async -> IMAPFolderStateSnapshot? {
        await MainActor.run {
            let d = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            guard let row = try? modelContext.fetch(d).first else { return nil }
            return IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: row.folderName,
                folderAttributes: row.folderAttributes,
                uidValidity: row.uidValidity,
                uidNextAtLastSelect: row.uidNextAtLastSelect,
                existsAtLastSelect: row.existsAtLastSelect,
                highestFetchedUID: row.highestFetchedUID,
                lowestFetchedUID: row.lowestFetchedUID,
                backfillComplete: row.backfillComplete,
                highestModSeq: row.highestModSeq,
                lastDeletionSyncAt: row.lastDeletionSyncAt,
                lastMessageIDReconciliationAt: row.lastMessageIDReconciliationAt,
                backfillLowerBoundAt: row.backfillLowerBoundAt,
                inScopeMessageCountAtLastSelect: row.inScopeMessageCountAtLastSelect,
                initialImportUIDWorkTotal: row.initialImportUIDWorkTotal,
                initialImportUIDWorkRemaining: row.initialImportUIDWorkRemaining,
                initialImportSnapshotUIDValidity: row.initialImportSnapshotUIDValidity,
                initialImportTerminalExclusionReason: row.initialImportTerminalExclusionReason
            )
        }
    }

    nonisolated func registerInitialImportCorpusFolders(
        accountID: UUID,
        folderNames: [String]
    ) async {
        await MainActor.run {
            requiredInitialImportCorpusFolders[accountID] = Set(folderNames)
            evaluateInitialImportCompletion(accountID: accountID)
            try? modelContext.save()
        }
    }

    nonisolated func initialIMAPImportCompleted(accountID: UUID) async -> Bool {
        await MainActor.run {
            let descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            return (try? modelContext.fetch(descriptor).first)?.initialIMAPImportCompletedAt != nil
        }
    }

    nonisolated func isInitialImportCorpusFolder(
        accountID: UUID,
        folderName: String
    ) async -> Bool {
        await MainActor.run {
            if requiredInitialImportCorpusFolders[accountID] == nil {
                rebuildInitialImportCorpusFolders(accountID: accountID)
            }
            return requiredInitialImportCorpusFolders[accountID]?.contains(folderName) == true
        }
    }

    nonisolated func recordSelectExists(accountID: UUID, folderName: String, exists: Int) async {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return }
            let descriptor = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            let row: IMAPFolderState
            if let existing = try? modelContext.fetch(descriptor).first {
                row = existing
            } else {
                row = IMAPFolderState(
                    account: account,
                    folderName: folderName,
                    attributes: [],
                    uidValidity: 0
                )
                modelContext.insert(row)
            }
            row.existsAtLastSelect = max(0, exists)
            row.updatedAt = Date()
            try? modelContext.save()
        }
    }

    nonisolated func recordSelectCounts(
        accountID: UUID,
        folderName: String,
        exists: Int,
        inScope: Int?
    ) async {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return }
            let descriptor = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            let row: IMAPFolderState
            if let existing = try? modelContext.fetch(descriptor).first {
                row = existing
            } else {
                row = IMAPFolderState(
                    account: account,
                    folderName: folderName,
                    attributes: [],
                    uidValidity: 0
                )
                modelContext.insert(row)
            }
            row.existsAtLastSelect = max(0, exists)
            row.inScopeMessageCountAtLastSelect = inScope
            row.updatedAt = Date()
            try? modelContext.save()
        }
    }

    nonisolated func upsertFolderState(_ snapshot: IMAPFolderStateSnapshot) async {
        await MainActor.run {
            let accountID = snapshot.accountID
            let folderName = snapshot.folderName
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return }
            let d = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            let row: IMAPFolderState
            if let existing = try? modelContext.fetch(d).first {
                row = existing
            } else {
                row = IMAPFolderState(
                    account: account,
                    folderName: folderName,
                    attributes: snapshot.folderAttributes,
                    uidValidity: snapshot.uidValidity
                )
                modelContext.insert(row)
            }
            row.setFolderAttributes(snapshot.folderAttributes)
            row.uidValidity = snapshot.uidValidity
            row.uidNextAtLastSelect = snapshot.uidNextAtLastSelect
            if let existsAtLastSelect = snapshot.existsAtLastSelect {
                row.existsAtLastSelect = existsAtLastSelect
            }
            row.highestFetchedUID = snapshot.highestFetchedUID
            row.lowestFetchedUID = snapshot.lowestFetchedUID
            row.backfillComplete = snapshot.backfillComplete
            row.highestModSeq = snapshot.highestModSeq
            row.lastDeletionSyncAt = snapshot.lastDeletionSyncAt
            row.lastMessageIDReconciliationAt = snapshot.lastMessageIDReconciliationAt
            row.backfillLowerBoundAt = snapshot.backfillLowerBoundAt
            row.inScopeMessageCountAtLastSelect = snapshot.inScopeMessageCountAtLastSelect
            row.initialImportUIDWorkTotal = snapshot.initialImportUIDWorkTotal
            row.initialImportUIDWorkRemaining = snapshot.initialImportUIDWorkRemaining
            row.initialImportSnapshotUIDValidity = snapshot.initialImportSnapshotUIDValidity
            row.initialImportTerminalExclusionReason = snapshot.initialImportTerminalExclusionReason
            row.updatedAt = Date()
            evaluateInitialImportCompletion(accountID: accountID)
            try? modelContext.save()
        }
    }

    nonisolated func handleUIDValidityChange(accountID: UUID, folderName: String, newUIDValidity: UInt32) async {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return }
            let d = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            guard let row = try? modelContext.fetch(d).first else { return }
            row.uidValidity = newUIDValidity
            row.highestFetchedUID = 0
            row.lowestFetchedUID = 0
            row.highestModSeq = nil
            row.backfillComplete = false
            row.backfillLowerBoundAt = nil
            row.inScopeMessageCountAtLastSelect = nil
            row.lastFlagReconciliationUID = nil
            if account.initialIMAPImportCompletedAt == nil {
                row.initialImportUIDWorkTotal = nil
                row.initialImportUIDWorkRemaining = nil
                row.initialImportSnapshotUIDValidity = nil
                row.initialImportTerminalExclusionReason = nil
            }
            row.updatedAt = Date()
            try? modelContext.save()
        }
    }

    nonisolated func recentUnreadLiveArrivalUIDs(
        accountID: UUID,
        since: Date
    ) async -> [String: [UInt32]] {
        await MainActor.run {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.liveDetectedAt != nil && message.liveDetectedAt! > since
                        && message.accountID == accountID
                }
            )
            let recent = ((try? modelContext.fetch(descriptor)) ?? []).filter { message in
                message.isRead != true && message.trashedAt == nil && message.imapUID > 0
            }
            return Dictionary(grouping: recent.compactMap { message in
                message.imapFolderPath.map { (folder: $0, uid: message.imapUID) }
            }, by: \.folder).mapValues { $0.map(\.uid).sorted() }
        }
    }

    nonisolated func flagReconciliationUIDs(
        accountID: UUID,
        folderName: String,
        limit: Int
    ) async -> [UInt32] {
        await MainActor.run {
            guard limit > 0 else { return [] }
            let stateDescriptor = FetchDescriptor<IMAPFolderState>(
                predicate: #Predicate<IMAPFolderState> { state in
                    state.account?.id == accountID && state.folderName == folderName
                }
            )
            let cursor = (try? modelContext.fetch(stateDescriptor).first)?.lastFlagReconciliationUID ?? 0

            var afterCursorDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.accountID == accountID
                        && message.imapFolderPath == folderName
                        && message.imapUID > cursor
                },
                sortBy: [SortDescriptor(\.imapUID)]
            )
            afterCursorDescriptor.fetchLimit = limit

            var selected = ((try? modelContext.fetch(afterCursorDescriptor)) ?? [])
                .map(\.imapUID)
            if selected.count < limit {
                var wrapDescriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { message in
                        message.accountID == accountID
                            && message.imapFolderPath == folderName
                            && message.imapUID > 0
                            && message.imapUID <= cursor
                    },
                    sortBy: [SortDescriptor(\.imapUID)]
                )
                wrapDescriptor.fetchLimit = limit - selected.count
                selected.append(contentsOf: ((try? modelContext.fetch(wrapDescriptor)) ?? []).map(\.imapUID))
            }
            let deduplicated = Self.deduplicatePreservingOrder(selected, limit: limit)
            if !deduplicated.isEmpty {
                return deduplicated
            }

            // Legacy repair fallback: very old rows can predate scalar
            // `accountID`. Keep the hot path above scalar-only, then fall back
            // to relationship filtering only if there was nothing to reconcile.
            let legacyDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.imapFolderPath == folderName
                }
            )
            let legacy = ((try? modelContext.fetch(legacyDescriptor)) ?? []).filter { message in
                message.account?.id == accountID && message.imapUID > 0
            }
            let legacyUIDs = Array(Set(legacy.map(\.imapUID))).sorted()
            return Array(legacyUIDs.prefix(limit))
        }
    }

    nonisolated func recordFlagReconciliationCursor(
        accountID: UUID,
        folderName: String,
        lastUID: UInt32
    ) async {
        await MainActor.run {
            let descriptor = FetchDescriptor<IMAPFolderState>(
                predicate: #Predicate<IMAPFolderState> { state in
                    state.account?.id == accountID && state.folderName == folderName
                }
            )
            guard let row = try? modelContext.fetch(descriptor).first else { return }
            row.lastFlagReconciliationUID = lastUID
            row.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private func evaluateInitialImportCompletion(accountID: UUID) {
        guard let required = requiredInitialImportCorpusFolders[accountID],
              required.isEmpty == false else { return }
        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard let account = try? modelContext.fetch(accountDescriptor).first,
              account.initialIMAPImportCompletedAt == nil else { return }
        let stateDescriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID
            }
        )
        let folders = ((try? modelContext.fetch(stateDescriptor)) ?? []).map { state in
            InitialIMAPImportCompletionEvaluator.Folder(
                name: state.folderName,
                total: state.initialImportUIDWorkTotal,
                remaining: state.initialImportUIDWorkRemaining,
                snapshotUIDValidity: state.initialImportSnapshotUIDValidity,
                terminalExclusionReason: state.initialImportTerminalExclusionReason
            )
        }
        guard InitialIMAPImportCompletionEvaluator.isComplete(
            requiredFolderNames: required,
            folders: folders
        ) else { return }
        account.initialIMAPImportCompletedAt = now()
    }

    private func rebuildInitialImportCorpusFolders(accountID: UUID) {
        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard (try? modelContext.fetch(accountDescriptor).first) != nil else { return }
        let stateDescriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID
            }
        )
        let listing = ((try? modelContext.fetch(stateDescriptor)) ?? []).map { state in
            IMAPFolder(
                name: state.folderName,
                delimiter: nil,
                attributes: Set(state.folderAttributes)
            )
        }
        // Mirrors `IMAPSession.refreshTrackedFolders`: every synced folder is
        // required for initial-import completion, not just the folder(s)
        // that feed the message corpus (see that call site for why).
        let folders = GmailFolderFilter.foldersToSync(
            listing: listing,
            capabilities: IMAPCapability(raw: [])
        )
        requiredInitialImportCorpusFolders[accountID] = Set(folders.map(\.name))
    }

    private static func deduplicatePreservingOrder(_ uids: [UInt32], limit: Int) -> [UInt32] {
        guard limit > 0 else { return [] }
        var seen = Set<UInt32>()
        var selected: [UInt32] = []
        selected.reserveCapacity(min(uids.count, limit))
        for uid in uids where seen.insert(uid).inserted {
            selected.append(uid)
            if selected.count == limit { break }
        }
        return selected
    }

    nonisolated func needsMessageIDReconciliation(accountID: UUID, folderName: String) async -> Bool {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return false }
            let folderDescriptor = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            })
            let folderState = (try? modelContext.fetch(folderDescriptor).first)
            let folderAttributes = folderState?.folderAttributes ?? []
            let folderRole = classifyIMAPFolderRole(folder: folderName, attributes: folderAttributes)
            let host = account.imapHost?.lowercased() ?? ""
            let isGmailAll = (host.contains("gmail") || host.contains("google")) && folderRole == .gmailAll
            if isGmailAll {
                let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { message in
                    (message.accountID == accountID || message.account?.id == accountID)
                        && message.messageIdHeader != nil
                })
                let rows = (try? modelContext.fetch(descriptor)) ?? []
                let inScopeRows = rows.filter { message in
                    account.acceptsExistingMessageIngestionWindow(
                        receivedAt: message.receivedAt,
                        sentAt: message.sentAt
                    )
                }
                if inScopeRows.contains(where: { message in
                    message.imapUID == 0 || message.imapFolderPath != folderName
                }) {
                    return true
                }
                guard !inScopeRows.isEmpty else { return false }
                guard let last = folderState?.lastMessageIDReconciliationAt else {
                    return true
                }
                return Date().timeIntervalSince(last) >= Self.gmailAllMailReconciliationInterval
            }

            let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { message in
                (message.accountID == accountID || message.account?.id == accountID)
                    && message.imapFolderPath == folderName
                    && message.imapUID == 0
                    && message.messageIdHeader != nil
            })
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            return rows.contains { message in
                account.acceptsExistingMessageIngestionWindow(
                    receivedAt: message.receivedAt,
                    sentAt: message.sentAt
                )
            }
        }
    }

    nonisolated func historicalBodyFetchAllowed(accountID: UUID) async -> Bool {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            guard let account = try? modelContext.fetch(accountFetch).first else { return false }
            return account.status != .paused
                && account.imapHost != nil
                && account.imapKeychainRef != nil
                && !account.needsImapReauth
        }
    }

    nonisolated func ingestionLowerBound(accountID: UUID) async -> Date? {
        await MainActor.run {
            let accountFetch = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
            return (try? modelContext.fetch(accountFetch).first)?.ingestionLowerBoundAt
        }
    }

    private static let gmailAllMailReconciliationInterval: TimeInterval = 5 * 60
}
