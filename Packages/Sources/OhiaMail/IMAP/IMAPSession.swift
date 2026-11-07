import Foundation
import OhiaCore

public extension Notification.Name {
    /// Posted after an authoritative IMAP folder poll completes without error.
    /// Beacon failures listen for this signal so any later successful poll can
    /// clear their persistent error latch.
    static let ohiaIMAPPollSucceeded = Notification.Name("ohia.imap.pollSucceeded")
}

public actor IMAPSession {
    /// Operational mode for the session's main loop.
    ///
    /// - `.full`: connect → auth → SELECT INBOX → IDLE rotation. The standard
    ///   live-tail / poll / backfill driver.
    /// - `.deletionWatchOnly`: connect → auth → wait for cancellation. The
    ///   IDLE loop is suppressed while forward-fetch is gated. Deletion-watch ticks are driven externally
    ///   by `runDeletionWatchTick(folder:)`, which uses the auxiliary client
    ///   pool and emits `IMAPDeletionEvent` for the standard cascade. Promotion
    ///   to `.full` is via `IMAPSessionManager` tearing down the session and
    ///   starting a fresh one in the new mode.
    public enum SessionMode: Sendable, Equatable {
        case full
        case deletionWatchOnly
    }

    public enum Status: Sendable, Equatable {
        case disconnected
        case connecting
        case authing
        case selected(mailbox: String, exists: Int, uidNext: UInt32, uidValidity: UInt32)
        case idling
        case syncing(folder: String)
        case reconnecting(attempt: Int)
        case halted(reason: IMAPSessionHaltReason)

        var sendable: IMAPSessionStatus {
            switch self {
            case .disconnected: return .disconnected
            case .connecting:   return .connecting
            case .authing:      return .authing
            case .selected(let mb, let e, let n, let v):
                return .selected(mailbox: mb, exists: e, uidNext: n, uidValidity: v)
            case .idling:       return .idling
            case .syncing(let f): return .syncing(folder: f)
            case .reconnecting(let a): return .reconnecting(attempt: a)
            case .halted(let r): return .halted(reason: r)
            }
        }
    }

    public enum NetworkEvent: Sendable { case pathLost, pathRestored, willSleep, didWake }

    public struct BackfillResult: Sendable {
        public let fetched: Int
        public let newLowestFetchedUID: UInt32
        public let backfillComplete: Bool
    }

    public struct PollResult: Sendable {
        public let fetched: Int
        public let newInboundMessageIDs: [UUID]
        public let newHighestFetchedUID: UInt32
        public let hasMore: Bool
    }

    public struct WithheldAutoDeleteResult: Sendable, Equatable {
        public let role: WithheldFolderRole
        public let folderName: String?
        public let matchedCount: Int
        public let deletedCount: Int
        public let folderFound: Bool
    }

    public static let defaultPollBatchSize = 50
    public static let defaultFlagReconciliationBatchSize = 500
    private static let liveStartupCatchUpWindow: UInt32 = 50
    private static let manualLiveTailWindow: UInt32 = 50
    private static let fallbackInboxPollInterval: TimeInterval = 5 * 60
    private static let fallbackTrashMailboxName = "Trash"

    public let accountID: UUID
    private let accountEmailAddress: String
    private let imapHost: String
    private let imapPort: Int
    private let imapSecurity: IMAPSecurity
    private let imapAuthMethod: IMAPAuthMethod
    private let imapUsername: String
    private let pinnedCertSHA256: String?
    private let credentialsResolver: IMAPCredentialsResolving
    private let gmailDraftDeleter: any GmailDraftDeleting
    private let gmailMessageTrasher: any GmailMessageTrashing
    private weak var statusReporter: (any IMAPSessionStatusReporting)?
    private let ingestRaw: IMAPRawMessageIngesting
    private let folderStateStore: IMAPFolderStateReading
    internal let initialHistoryEstimate: IMAPHistoryEstimate?
    public let mode: SessionMode

    // Internal state
    private let clientFactory: @Sendable () -> any IMAPClienting
    private var client: (any IMAPClienting)?
    private var openingAuxiliaryClients: [UUID: any IMAPClienting] = [:]
    private var status: Status = .disconnected
    private var currentMailbox: String?
    private var currentSelectState: IMAPSelectState?
    private var lastKnownExists: Int = 0
    private var hasPendingPoke: Bool = false
    private var backfillYieldRequested: Bool = false
    private var useQresync: Bool = false
    private var lastCapability: IMAPCapability?
    private var mainTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    internal var idleRotationInterval: TimeInterval = 29 * 60   // internal for test override
    /// Coalesces a burst of IDLE flag pushes into one read-mark refresh.
    internal var recentArrivalFlagRefreshDelay: TimeInterval = 1.5   // internal for test override
    private var recentArrivalFlagRefreshTask: Task<Void, Never>?
    private var recentArrivalFlagRefreshToken = UUID()
    private var recentArrivalFlagRefreshRequested = false
    /// A folder whose refresh failed rests a minute rather than reconnecting
    /// the auxiliary client on every push.
    private var recentArrivalFlagRefreshFailures: [String: Date] = [:]
    private static let recentArrivalFlagRefreshFailureBackoff: TimeInterval = 60

    // Pooled auxiliary client: a second long-lived IMAP connection used by
    // pollFolder/backfillTick when the main session is in IDLE. Without this
    // pool, each non-INBOX poll would open a fresh TCP+TLS+AUTH cycle —
    // dozens of handshakes per day on a multi-folder mailbox, each one a
    // chance to hit a transient TLS or network failure.
    private enum AuxiliaryLane: CaseIterable {
        case background
        case mutation
    }
    private struct AuxiliaryPool {
        var client: (client: any IMAPClienting, qresyncEnabled: Bool)?
        var operationActive = false
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    }
    // User changes must never wait for the background connection's FETCH or
    // ingestion. Each lane remains serialized so SELECT/STORE/APPEND sequences
    // cannot change one another's selected mailbox across actor suspension.
    private var auxiliaryPools: [AuxiliaryLane: AuxiliaryPool] = [:]
    private var auxiliaryGeneration = 0
    private struct ManualLiveTailCursor: Sendable {
        let uidValidity: UInt32
        let highestCheckedUID: UInt32
    }
    private var manualLiveTailCursors: [String: ManualLiveTailCursor] = [:]

    public init(
        accountID: UUID,
        accountEmailAddress: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: IMAPSecurity,
        imapAuthMethod: IMAPAuthMethod,
        imapUsername: String,
        pinnedCertSHA256: String?,
        credentialsResolver: IMAPCredentialsResolving,
        statusReporter: IMAPSessionStatusReporting?,
        ingestRaw: IMAPRawMessageIngesting,
        folderStateStore: IMAPFolderStateReading,
        mode: SessionMode = .full,
        initialHistoryEstimate: IMAPHistoryEstimate? = nil
    ) {
        self.init(
            accountID: accountID,
            accountEmailAddress: accountEmailAddress,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            imapAuthMethod: imapAuthMethod,
            imapUsername: imapUsername,
            pinnedCertSHA256: pinnedCertSHA256,
            credentialsResolver: credentialsResolver,
            statusReporter: statusReporter,
            ingestRaw: ingestRaw,
            folderStateStore: folderStateStore,
            mode: mode,
            initialHistoryEstimate: initialHistoryEstimate,
            gmailDraftDeleter: GmailDraftAPIClient(),
            gmailMessageTrasher: GmailMessageAPIClient(),
            clientFactory: { IMAPClient() }
        )
    }

    init(
        accountID: UUID,
        accountEmailAddress: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: IMAPSecurity,
        imapAuthMethod: IMAPAuthMethod,
        imapUsername: String,
        pinnedCertSHA256: String?,
        credentialsResolver: IMAPCredentialsResolving,
        statusReporter: IMAPSessionStatusReporting?,
        ingestRaw: IMAPRawMessageIngesting,
        folderStateStore: IMAPFolderStateReading,
        mode: SessionMode = .full,
        initialHistoryEstimate: IMAPHistoryEstimate? = nil,
        gmailDraftDeleter: any GmailDraftDeleting = GmailDraftAPIClient(),
        gmailMessageTrasher: any GmailMessageTrashing = GmailMessageAPIClient(),
        clientFactory: @escaping @Sendable () -> any IMAPClienting
    ) {
        self.accountID = accountID
        self.accountEmailAddress = accountEmailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.imapAuthMethod = imapAuthMethod
        self.imapUsername = imapUsername
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.credentialsResolver = credentialsResolver
        self.gmailDraftDeleter = gmailDraftDeleter
        self.gmailMessageTrasher = gmailMessageTrasher
        self.statusReporter = statusReporter
        self.ingestRaw = ingestRaw
        self.folderStateStore = folderStateStore
        self.mode = mode
        self.initialHistoryEstimate = initialHistoryEstimate
        self.clientFactory = clientFactory
    }

    public func start() {
        if mainTask != nil { return }
        recentArrivalFlagRefreshFailures.removeAll()
        mainTask = Task { [weak self] in
            await self?.runMainLoop()
        }
    }

    public func stop() async {
        let stoppingTask = mainTask
        stoppingTask?.cancel()
        mainTask = nil
        recentArrivalFlagRefreshTask?.cancel()
        recentArrivalFlagRefreshTask = nil
        auxiliaryGeneration += 1
        for lane in AuxiliaryLane.allCases {
            let waiters = auxiliaryPools[lane, default: AuxiliaryPool()].waiters
            auxiliaryPools[lane, default: AuxiliaryPool()].waiters.removeAll()
            for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        }
        // Cancellation may leave IDLE/FETCH owning the response reader.
        // LOGOUT would compete with that read and delay shutdown until a
        // network timeout. Close every transport first, then drain the task.
        let primary = client
        let openingClients = Array(openingAuxiliaryClients.values)
        openingAuxiliaryClients.removeAll()
        client = nil
        currentMailbox = nil
        currentSelectState = nil
        await primary?.close()
        for openingClient in openingClients { await openingClient.close() }
        for lane in AuxiliaryLane.allCases {
            let auxiliary = auxiliaryPools[lane]?.client
            auxiliaryPools[lane, default: AuxiliaryPool()].client = nil
            await auxiliary?.client.close()
        }
        await transition(to: .disconnected)
        await stoppingTask?.value
    }

    public func poke() {
        hasPendingPoke = true
    }

    public func handleNetworkEvent(_ event: NetworkEvent) async {
        switch event {
        case .pathLost, .willSleep:
            await stop()
        case .pathRestored, .didWake:
            reconnectAttempt = 0
            start()
        }
    }

    // MARK: - Main loop

    private func runMainLoop() async {
        while !Task.isCancelled {
            do {
                try await connectAndAuth()
                switch mode {
                case .full:
                    try await watchInboxForever()
                case .deletionWatchOnly:
                    // Forward-fetch is gated off. We still want a live session for cheap SELECTs
                    // driven by `runDeletionWatchTick(folder:)` against the
                    // auxiliary client pool, but no IDLE rotation, no body
                    // fetch. Park here until cancellation or reconnect; the
                    // primary client stays connected so credentials work
                    // path stays warm. When the gate flips, the manager
                    // tears down this session and starts a fresh `.full` one.
                    try await waitForCancellation()
                }
            } catch let error as IMAPError {
                await handleError(error)
            } catch {
                await handleError(.transient(underlying: error))
            }
        }
    }

    /// Suspend the main task until cancellation. Used in `.deletionWatchOnly`
    /// mode where the primary client connection is kept warm but no IDLE loop
    /// runs. Throws `IMAPError.cancelled` on cancellation so `handleError`
    /// returns cleanly without a reconnect.
    private func waitForCancellation() async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        throw IMAPError.cancelled
    }

    /// Outer loop: begin IDLE, race events against the 29-minute rotation
    /// deadline, end IDLE, drain if anything changed (or if a `poke` came
    /// in), then re-enter IDLE. Terminates on task cancellation.
    private func idleLoopForever() async throws {
        guard let c = client else { throw IMAPError.notConnected }

        while !Task.isCancelled {
            try await c.beginIdle()
            await transition(to: .idling)

            let deadline = Date().addingTimeInterval(idleRotationInterval)
            var sawMailboxChange = false

            // Inner event loop. Cap each wait at 60s so cancellation
            // and the outer rotation are noticed promptly.
            while Date() < deadline && !Task.isCancelled {
                let remaining = max(1, deadline.timeIntervalSinceNow)
                let capped = min(remaining, 60)
                let event = try await c.readIdleEvent(timeout: capped)
                guard let event else { continue }

                switch event {
                case .exists(let count):
                    if count > lastKnownExists {
                        sawMailboxChange = true
                    }
                    lastKnownExists = count
                case .expunge:
                    // EXPUNGE delivers a sequence number, not a UID, so we
                    // can't decide a deletion from this event alone. Break
                    // out of IDLE so the drain path's deletion-aware SELECT
                    // (QRESYNC VANISHED) reports the vanished UIDs and the
                    // cascade applies the deletion. Keep `lastKnownExists`
                    // consistent so a subsequent EXISTS that matches the
                    // post-expunge count doesn't suppress a future drain.
                    if lastKnownExists > 0 { lastKnownExists -= 1 }
                    sawMailboxChange = true
                case .flagsChanged:
                    // Re-read recent arrivals' read marks on the auxiliary
                    // connection; this one stays in IDLE, so no EXISTS that
                    // follows is lost.
                    requestRecentArrivalFlagRefresh()
                case .alert(let text):
                    print("[Ohia] IMAP ALERT: \(text)")
                case .bye:
                    throw IMAPError.serverClosedConnection
                case .other:
                    ()
                }
                if sawMailboxChange { break }
            }

            try await c.endIdle()

            let wasPoked = hasPendingPoke
            hasPendingPoke = false
            if sawMailboxChange || wasPoked || Date() >= deadline {
                // Reconcile at every normal rotation as a backstop for a
                // mailbox-change response that was lost or never delivered.
                try await drainNewMailInINBOX()
            }
        }
    }

    /// Prefer server-driven IDLE when advertised. IMAP4rev2 includes IDLE in
    /// the base protocol, so it need not appear as a separate capability token.
    /// Older servers without IDLE, and servers that reject an advertised IDLE,
    /// fall back to periodic INBOX reconciliation instead of halting live mail.
    private func watchInboxForever() async throws {
        let supportsIdle = lastCapability?.idle == true
            || lastCapability?.raw.contains("IMAP4REV2") == true
        guard supportsIdle else {
            try await pollInboxForever()
            return
        }

        do {
            try await idleLoopForever()
        } catch {
            guard Self.isIdleRejection(error) else { throw error }
            print("[Ohia] IMAP IDLE unavailable; polling INBOX instead")
            try await pollInboxForever()
        }
    }

    private func pollInboxForever() async throws {
        let interval = max(0.01, min(idleRotationInterval, Self.fallbackInboxPollInterval))
        await reportSelectedInboxStatus()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch is CancellationError {
                throw IMAPError.cancelled
            }
            if Task.isCancelled { throw IMAPError.cancelled }
            try await drainNewMailInINBOX()
            await reportSelectedInboxStatus()
        }
        throw IMAPError.cancelled
    }

    private func reportSelectedInboxStatus() async {
        guard let state = currentSelectState else { return }
        await transition(to: .selected(
            mailbox: "INBOX",
            exists: state.exists,
            uidNext: state.uidNext,
            uidValidity: state.uidValidity
        ))
    }

    private static func isIdleRejection(_ error: Error) -> Bool {
        guard case .protocolViolation(let message) = error as? IMAPError else {
            return false
        }
        return message.hasPrefix("IDLE rejected:")
    }

    // MARK: - Status reporting

    private func transition(to new: Status) async {
        status = new
        await statusReporter?.reportStatus(new.sendable, for: accountID)
    }

    private func handleError(_ err: IMAPError) async {
        switch err {
        case .cancelled:
            return

        case .authFailed(let text):
            await tearDownPrimaryClient()
            await transition(to: .halted(reason: .authFailed(text)))
            mainTask?.cancel()

        case .reauthRequired(let text):
            await tearDownPrimaryClient()
            await transition(to: .halted(reason: .reauthRequired(text)))
            mainTask?.cancel()

        case .mailStream(.certPinMismatch(let presented)):
            await tearDownPrimaryClient()
            await transition(to: .halted(reason: .certMismatch(presented: presented)))
            mainTask?.cancel()

        case .mailStream(.tlsHandshakeFailed(let underlying)):
            await tearDownPrimaryClient()
            let msg = underlying.map { "\($0)" } ?? "TLS handshake failed"
            await transition(to: .halted(reason: .tlsError(msg)))
            mainTask?.cancel()

        case .notImapServer:
            await tearDownPrimaryClient()
            await transition(to: .halted(reason: .protocolViolation("not an IMAP server")))
            mainTask?.cancel()

        case .protocolViolation(let text):
            await tearDownPrimaryClient()
            await transition(to: .halted(reason: .protocolViolation(text)))
            mainTask?.cancel()

        case .transient, .mailStream, .serverTemporary, .serverClosedConnection, .notConnected:
            await tearDownPrimaryClient()
            reconnectAttempt += 1
            await transition(to: .reconnecting(attempt: reconnectAttempt))
            let seconds = Self.backoffSeconds(attempt: reconnectAttempt)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    internal static func backoffSeconds(attempt: Int) -> TimeInterval {
        switch attempt {
        case ..<1: return 1
        case 1: return 1
        case 2: return 2
        case 3: return 5
        case 4: return 15
        case 5: return 30
        default: return 60
        }
    }
}

// MARK: - connectAndAuth

extension IMAPSession {
    internal func connectAndAuth() async throws {
        let generation = auxiliaryGeneration
        await transition(to: .connecting)
        try Task.checkCancellation()
        guard generation == auxiliaryGeneration else { throw CancellationError() }
        let c = clientFactory()
        self.client = c
        do {
            try await c.connect(
                host: imapHost,
                port: imapPort,
                security: imapSecurity,
                pinnedCertSHA256: pinnedCertSHA256
            )
            try Task.checkCancellation()
            guard generation == auxiliaryGeneration else { throw CancellationError() }
            reconnectAttempt = 0

            await transition(to: .authing)
            switch imapAuthMethod {
            case .password:
                let password = try await credentialsResolver.passwordForAccount(accountID)
                try await c.authenticatePlain(username: imapUsername, password: password)

            case .oauth2:
                // Derive provider from imapHost — convention, not parse.
                let provider: MailProvider.OAuthProviderID = {
                    if imapHost.contains("gmail") || imapHost.contains("google") { return .gmail }
                    return .microsoft
                }()
                let token = try await credentialsResolver.oauthAccessTokenForAccount(accountID, provider: provider)
                try await c.authenticateXOAuth2(username: imapUsername, accessToken: token)
            }

            await transition(to: .syncing(folder: "mailbox setup"))

            // Post-auth caps may differ (e.g. X-GM-EXT-1 appears only after login).
            let caps = try await c.capability()
            lastCapability = caps
            if caps.qresync {
                do {
                    try await c.enableQresync()
                    useQresync = true
                } catch {
                    useQresync = false
                }
            } else {
                useQresync = false
            }

            _ = (try? await refreshTrackedFolders(capabilities: caps)) ?? []

            // In `.deletionWatchOnly` mode the session is a warm credentials
            // holder for the auxiliary-client deletion-watch path. Land on
            // `.selected("DELETION_WATCH")` so observers see a stable post-auth
            // status rather than `.authing` indefinitely.
            guard mode == .full else {
                await transition(to: .selected(
                    mailbox: "DELETION_WATCH",
                    exists: 0,
                    uidNext: 0,
                    uidValidity: 0
                ))
                return
            }

            let initialSelect = try await selectMailboxTrackingDeletions("INBOX")
            let selectState = initialSelect.select
            self.currentMailbox = "INBOX"
            self.currentSelectState = selectState
            self.lastKnownExists = selectState.exists
            await transition(to: .selected(
                mailbox: "INBOX",
                exists: selectState.exists,
                uidNext: selectState.uidNext,
                uidValidity: selectState.uidValidity
            ))
            await establishLiveBaselineIfNeeded(folder: "INBOX", selectState: selectState)
            try await drainNewMailInINBOX()
        } catch {
            if generation == auxiliaryGeneration {
                client = nil
                currentMailbox = nil
                currentSelectState = nil
                await c.close()
            }
            throw error
        }
    }
}

// MARK: - folder discovery

extension IMAPSession {
    private func refreshTrackedFolders(capabilities: IMAPCapability) async throws -> [IMAPFolder] {
        guard let c = client else { throw IMAPError.notConnected }
        let listed = try await c.list()
        let tracked = GmailFolderFilter.foldersToSync(listing: listed, capabilities: capabilities)
        // Every synced folder — not just the folder(s) that feed the
        // message corpus — must finish its own backfill before the
        // account's initial history acquisition counts as complete.
        // `foldersForCorpus` (used to decide what actually feeds the
        // corpus/embeddings, e.g. Gmail's All Mail-only dedup so INBOX
        // isn't double-ingested) is a narrower, separate concern. Gating
        // completion on it alone left INBOX/Drafts backfill invisible to
        // "importing": the Activity Strip dropped that label the moment
        // All Mail finished, even while another synced folder was still
        // catching up to the same history window — surfacing as a
        // confusing "backfilling" relabel instead of the initial import
        // simply continuing.
        await folderStateStore.registerInitialImportCorpusFolders(
            accountID: accountID,
            folderNames: tracked.map(\.name)
        )
        for folder in tracked {
            let existing = await folderStateStore.readFolderState(accountID: accountID, folderName: folder.name)
            var snapshot = existing ?? IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: folder.name,
                folderAttributes: [],
                uidValidity: 0,
                uidNextAtLastSelect: 0,
                highestFetchedUID: 0,
                lowestFetchedUID: 0,
                backfillComplete: false
            )
            snapshot.folderAttributes = folder.attributes.sorted()
            await folderStateStore.upsertFolderState(snapshot)
        }
        return tracked
    }
}

// MARK: - deletion-aware SELECT

extension IMAPSession {
    private enum DeletionReconciliationMode: Equatable {
        case standard
        case deletionWatch
        case liveTail
    }

    private func selectMailboxTrackingDeletions(_ mailbox: String) async throws -> IMAPSelectQRESYNCResult {
        guard let c = client else { throw IMAPError.notConnected }
        return try await selectMailboxTrackingDeletions(
            mailbox,
            using: c,
            qresyncEnabled: useQresync
        )
    }

    private func selectMailboxTrackingDeletions(
        _ mailbox: String,
        using c: any IMAPClienting,
        qresyncEnabled: Bool,
        reconciliationMode: DeletionReconciliationMode = .standard
    ) async throws -> IMAPSelectQRESYNCResult {
        let snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: mailbox)
        establishManualLiveTailCursorIfNeeded(folder: mailbox, snapshot: snapshot)
        let uidValidityBefore = snapshot?.uidValidity
        let highestModSeqBefore = snapshot?.highestModSeq
        let historicalFetchAllowed = await folderStateStore.historicalBodyFetchAllowed(accountID: accountID)

        let result: IMAPSelectQRESYNCResult
        if qresyncEnabled, let uidValidityBefore, let highestModSeqBefore {
            result = try await c.selectWithQresync(
                mailbox: mailbox,
                uidValidity: uidValidityBefore,
                highestModSeq: highestModSeqBefore
            )
        } else {
            result = try await c.selectWithMetadata(mailbox: mailbox)
        }

        // On first-sync (no stored modseq), attempt UID SEARCH ALL so the
        // coordinator can retroactively detect deletions that occurred before
        // our QRESYNC cursor was established. Best-effort: any error is
        // silently swallowed so the poll still completes.
        let isFirstSync = (highestModSeqBefore == nil)
        let vanishedUIDsPresent = !result.vanishedUIDs.isEmpty
        let existsDropped = snapshot?.existsAtLastSelect.map { result.select.exists < $0 } ?? false
        let needsMessageIDReconciliation: Bool
        if reconciliationMode == .standard {
            needsMessageIDReconciliation = await folderStateStore.needsMessageIDReconciliation(
                accountID: accountID,
                folderName: mailbox
            )
        } else {
            needsMessageIDReconciliation = false
        }
        var fullUids: [UInt32]? = nil
        var serverMessageIDs: [IMAPUIDMessageID]? = nil
        let lowerBound = await folderStateStore.ingestionLowerBound(accountID: accountID)
        if reconciliationMode == .standard {
            await recordInitialImportWorkProgress(
                folder: mailbox,
                selectState: result.select,
                lowerBound: lowerBound,
                searchedUIDCount: nil,
                processedUIDCount: 0
            )
        }
        var inScopeUids: [UInt32]? = nil
        let shouldSearchScopedUIDs = lowerBound != nil
            && result.select.uidNext > 1
            && (
                reconciliationMode == .standard
                    || (
                        reconciliationMode == .deletionWatch
                            && existsDropped
                            && !vanishedUIDsPresent
                    )
            )
        if let lowerBound, shouldSearchScopedUIDs {
            do {
                inScopeUids = try await c.uidSearch(
                    range: 1...(result.select.uidNext - 1),
                    since: lowerBound
                )
            } catch {
                inScopeUids = nil
            }
        }
        if reconciliationMode == .standard, let inScopeUids {
            await recordInitialImportWorkProgress(
                folder: mailbox,
                selectState: result.select,
                lowerBound: lowerBound,
                searchedUIDCount: inScopeUids.count,
                processedUIDCount: 0
            )
        }
        if lowerBound != nil {
            if let inScopeUids {
                await folderStateStore.recordSelectCounts(
                    accountID: accountID,
                    folderName: mailbox,
                    exists: result.select.exists,
                    inScope: inScopeUids.count
                )
            } else {
                await folderStateStore.recordSelectExists(
                    accountID: accountID,
                    folderName: mailbox,
                    exists: result.select.exists
                )
            }
        } else {
            await folderStateStore.recordSelectCounts(
                accountID: accountID,
                folderName: mailbox,
                exists: result.select.exists,
                inScope: nil
            )
        }
        if reconciliationMode == .standard, historicalFetchAllowed && isFirstSync {
            do {
                if let inScopeUids {
                    fullUids = inScopeUids
                } else if lowerBound == nil {
                    fullUids = try await c.uidSearchAll()
                }
            } catch {
                // Non-fatal: skip reconciliation on this pass.
            }
        }
        let shouldFetchServerMessageIDs: Bool
        switch reconciliationMode {
        case .standard:
            shouldFetchServerMessageIDs = historicalFetchAllowed
                && (needsMessageIDReconciliation || isFirstSync)
                && (lowerBound == nil || inScopeUids != nil)
        case .deletionWatch:
            shouldFetchServerMessageIDs = historicalFetchAllowed
                && existsDropped
                && !vanishedUIDsPresent
                && (lowerBound == nil || inScopeUids != nil)
        case .liveTail:
            shouldFetchServerMessageIDs = false
        }
        if shouldFetchServerMessageIDs {
            do {
                serverMessageIDs = try await fetchServerMessageIDsForReconciliation(
                    selectState: result.select,
                    using: c,
                    scopedUIDs: inScopeUids
                )
                if fullUids == nil {
                    fullUids = serverMessageIDs?.map(\.uid)
                }
            } catch {
                // Non-fatal: UID/QRESYNC-based deletion handling can still run.
            }
        }
        if reconciliationMode == .standard,
           lowerBound == nil,
           let fullUids {
            await recordInitialImportWorkProgress(
                folder: mailbox,
                selectState: result.select,
                lowerBound: nil,
                searchedUIDCount: fullUids.count,
                processedUIDCount: 0
            )
        }

        // Deletion-watch emits only when there is destructive work to prove:
        // a QRESYNC VANISHED set, or an All Mail EXISTS drop that needs the
        // slower Message-ID reconciliation fallback. Standard poll/backfill
        // still emits broader cursor events so migration and first-sync
        // reconciliation keep their existing behavior. `DeletionSyncCoordinator`
        // already handles nil UID / Message-ID reconciliation fields
        // defensively.
        let shouldEmitDeletionEvent: Bool
        switch reconciliationMode {
        case .standard:
            shouldEmitDeletionEvent = qresyncEnabled
                || result.highestModSeq != nil
                || vanishedUIDsPresent
                || isFirstSync
                || needsMessageIDReconciliation
        case .deletionWatch:
            shouldEmitDeletionEvent = vanishedUIDsPresent || existsDropped
        case .liveTail:
            shouldEmitDeletionEvent = vanishedUIDsPresent
        }
        if shouldEmitDeletionEvent {
            let event = IMAPDeletionEvent(
                folder: mailbox,
                folderAttributes: snapshot?.folderAttributes ?? [],
                uidValidityBefore: uidValidityBefore,
                uidValidityAfter: result.select.uidValidity,
                highestModSeqBefore: highestModSeqBefore,
                highestModSeqAfter: result.highestModSeq,
                vanishedUIDs: result.vanishedUIDs,
                observedAt: Date(),
                serverUidSetForReconciliation: fullUids,
                serverMessageIDsForReconciliation: serverMessageIDs
            )
            await statusReporter?.reportDeletionEvent(event, for: accountID)
        }
        await reportFlagSnapshotsIfNeeded(result.flagSnapshots, folder: mailbox)
        if !qresyncEnabled, reconciliationMode != .liveTail {
            await reconcileKnownFlagsBestEffort(folder: mailbox, using: c)
        }

        return result
    }

    private func reportFlagSnapshotsIfNeeded(
        _ snapshots: [IMAPFlagSnapshot],
        folder: String
    ) async {
        guard !snapshots.isEmpty else { return }
        await statusReporter?.reportFlagSnapshotEvent(
            IMAPFlagSnapshotEvent(folder: folder, snapshots: snapshots),
            for: accountID
        )
    }

    /// How long after arrival a message's read mark is re-read when the
    /// server reports a flag change: the arrival alert waits at most two
    /// minutes, and its reply preparation runs up to ten.
    static let recentArrivalFlagWindow: TimeInterval = 600

    private func recentArrivalFlagTargets() async -> [String: [UInt32]] {
        await folderStateStore.recentUnreadLiveArrivalUIDs(
            accountID: accountID,
            since: Date().addingTimeInterval(-Self.recentArrivalFlagWindow)
        )
    }

    /// One refresh at a time; pushes while one runs schedule exactly one
    /// more, and pushes during its coalescing pause join it.
    private func requestRecentArrivalFlagRefresh() {
        // A push read while the session stops starts nothing it can't cancel.
        guard mainTask != nil, !Task.isCancelled else { return }
        guard recentArrivalFlagRefreshTask == nil else {
            recentArrivalFlagRefreshRequested = true
            return
        }
        let token = UUID()
        recentArrivalFlagRefreshToken = token
        recentArrivalFlagRefreshTask = Task { [weak self] in
            await self?.runRecentArrivalFlagRefreshes(token: token)
        }
    }

    private func runRecentArrivalFlagRefreshes(token: UUID) async {
        repeat {
            try? await Task.sleep(nanoseconds: UInt64(max(0, recentArrivalFlagRefreshDelay) * 1_000_000_000))
            recentArrivalFlagRefreshRequested = false
            guard !Task.isCancelled else { break }
            await refreshRecentArrivalFlags()
        } while recentArrivalFlagRefreshRequested && !Task.isCancelled
        // A task cancelled by stop() never clears a newer one's handle.
        if recentArrivalFlagRefreshToken == token {
            recentArrivalFlagRefreshTask = nil
        }
    }

    /// Re-reads the read marks of mail that arrived in the last ten minutes,
    /// so mail the user read in another client appears without the arrival
    /// alert. Read-only (EXAMINE, FLAGS) on the auxiliary connection; the
    /// IDLE connection stays on INBOX.
    func refreshRecentArrivalFlags() async {
        let now = Date()
        recentArrivalFlagRefreshFailures = recentArrivalFlagRefreshFailures.filter {
            now.timeIntervalSince($0.value) < Self.recentArrivalFlagRefreshFailureBackoff
        }
        for (folder, uids) in await recentArrivalFlagTargets().sorted(by: { $0.key < $1.key })
        where !uids.isEmpty && recentArrivalFlagRefreshFailures[folder] == nil {
            let storedUIDValidity = await folderStateStore.readFolderState(
                accountID: accountID, folderName: folder
            )?.uidValidity
            do {
                // The short user-facing lane: the background lane can be
                // busy for minutes with backfill or reconciliation, past the
                // two minutes an arrival waits.
                let snapshots = try await withAuxiliaryClient(lane: .mutation) { client, _ -> [IMAPFlagSnapshot] in
                    let result = try await client.examineWithMetadata(mailbox: folder)
                    // A rebuilt folder reuses UIDs for other messages (0 is
                    // an unknown stored value, as elsewhere).
                    if let storedUIDValidity, storedUIDValidity != 0,
                       storedUIDValidity != result.select.uidValidity { return [] }
                    var snapshots: [IMAPFlagSnapshot] = []
                    for start in stride(from: 0, to: uids.count, by: Self.defaultFlagReconciliationBatchSize) {
                        let chunk = Array(uids[start..<min(start + Self.defaultFlagReconciliationBatchSize, uids.count)])
                        let stream = await client.uidFetchStream(uids: chunk, attrs: [.uid, .flags])
                        for try await message in stream {
                            snapshots.append(IMAPFlagSnapshot(uid: message.uid, flags: message.flags))
                        }
                    }
                    return snapshots
                }
                await reportFlagSnapshotsIfNeeded(snapshots, folder: folder)
            } catch is CancellationError {
                return
            } catch {
                recentArrivalFlagRefreshFailures[folder] = now
                print("[Ohia] IMAP recent-arrival flag refresh failed for \(folder): \(String(reflecting: type(of: error)))")
            }
        }
    }

    private func reconcileKnownFlagsBestEffort(
        folder: String,
        using client: any IMAPClienting
    ) async {
        do {
            let uids = await folderStateStore.flagReconciliationUIDs(
                accountID: accountID,
                folderName: folder,
                limit: Self.defaultFlagReconciliationBatchSize
            )
            guard !uids.isEmpty else { return }

            var snapshots: [IMAPFlagSnapshot] = []
            snapshots.reserveCapacity(uids.count)
            let stream = await client.uidFetchStream(uids: uids, attrs: [.uid, .flags])
            for try await message in stream {
                snapshots.append(IMAPFlagSnapshot(uid: message.uid, flags: message.flags))
            }
            await reportFlagSnapshotsIfNeeded(snapshots, folder: folder)
            if let lastUID = uids.last {
                await folderStateStore.recordFlagReconciliationCursor(
                    accountID: accountID,
                    folderName: folder,
                    lastUID: lastUID
                )
            }
        } catch {
            print("[Ohia] IMAP flag reconciliation failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func fetchServerMessageIDsForReconciliation(
        selectState: IMAPSelectState,
        using c: any IMAPClienting,
        scopedUIDs: [UInt32]? = nil
    ) async throws -> [IMAPUIDMessageID] {
        if let scopedUIDs {
            var rows: [IMAPUIDMessageID] = []
            for chunkStart in stride(from: 0, to: scopedUIDs.count, by: 500) {
                let chunk = Array(scopedUIDs[chunkStart..<min(chunkStart + 500, scopedUIDs.count)])
                let stream = await c.uidFetchStream(uids: chunk, attrs: [.uid, .envelope])
                for try await message in stream {
                    guard let messageID = message.envelope?.messageID else { continue }
                    rows.append(IMAPUIDMessageID(uid: message.uid, messageID: messageID))
                }
            }
            return rows
        }

        guard selectState.uidNext > 1 else { return [] }
        let maxUID = selectState.uidNext - 1
        let batchSize: UInt32 = 2_000
        var low: UInt32 = 1
        var rows: [IMAPUIDMessageID] = []
        while low <= maxUID {
            let remaining = maxUID - low
            let high = remaining >= batchSize ? low + batchSize - 1 : maxUID
            let stream = await c.uidFetchStream(range: low...high, attrs: [.uid, .envelope])
            for try await message in stream {
                guard let messageID = message.envelope?.messageID else { continue }
                rows.append(IMAPUIDMessageID(uid: message.uid, messageID: messageID))
            }
            if high == UInt32.max { break }
            low = high + 1
        }
        return rows
    }
}

// MARK: - Dependency protocols

public protocol IMAPCredentialsResolving: Sendable {
    func passwordForAccount(_ accountID: UUID) async throws -> String
    func oauthAccessTokenForAccount(_ accountID: UUID, provider: MailProvider.OAuthProviderID) async throws -> String
}

public protocol IMAPRawMessageIngesting: Sendable {
    func ingestRawRFC5322(
        data: Data,
        accountID: UUID,
        folderPath: String,
        serverUID: UInt32,
        receivedAt: Date?,
        seenAtSource: Bool?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> IMAPRawMessageIngestionResult

    func ingestRawRFC5322(
        data: Data,
        accountID: UUID,
        folderPath: String,
        folderAttributes: [String],
        serverUID: UInt32,
        folderUIDValidity: UInt32?,
        receivedAt: Date?,
        seenAtSource: Bool?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> IMAPRawMessageIngestionResult
}

public protocol IMAPFolderStateReading: Sendable {
    func readFolderState(accountID: UUID, folderName: String) async -> IMAPFolderStateSnapshot?
    func registerInitialImportCorpusFolders(accountID: UUID, folderNames: [String]) async
    func initialIMAPImportCompleted(accountID: UUID) async -> Bool
    func isInitialImportCorpusFolder(accountID: UUID, folderName: String) async -> Bool
    func recordSelectExists(accountID: UUID, folderName: String, exists: Int) async
    func recordSelectCounts(accountID: UUID, folderName: String, exists: Int, inScope: Int?) async
    func upsertFolderState(_ snapshot: IMAPFolderStateSnapshot) async
    func handleUIDValidityChange(accountID: UUID, folderName: String, newUIDValidity: UInt32) async
    func needsMessageIDReconciliation(accountID: UUID, folderName: String) async -> Bool
    func historicalBodyFetchAllowed(accountID: UUID) async -> Bool
    func ingestionLowerBound(accountID: UUID) async -> Date?
    func flagReconciliationUIDs(accountID: UUID, folderName: String, limit: Int) async -> [UInt32]
    func recordFlagReconciliationCursor(accountID: UUID, folderName: String, lastUID: UInt32) async
    /// UIDs, by folder, of this account's live-detected mail since `since`
    /// that is not yet known read and not trashed.
    func recentUnreadLiveArrivalUIDs(accountID: UUID, since: Date) async -> [String: [UInt32]]
}

public extension IMAPFolderStateReading {
    func registerInitialImportCorpusFolders(accountID: UUID, folderNames: [String]) async {}
    func initialIMAPImportCompleted(accountID: UUID) async -> Bool { false }
    func isInitialImportCorpusFolder(accountID: UUID, folderName: String) async -> Bool { true }
    func recordSelectExists(accountID: UUID, folderName: String, exists: Int) async {}
    func recordSelectCounts(accountID: UUID, folderName: String, exists: Int, inScope: Int?) async {
        await recordSelectExists(accountID: accountID, folderName: folderName, exists: exists)
    }
    func needsMessageIDReconciliation(accountID: UUID, folderName: String) async -> Bool { false }
    func historicalBodyFetchAllowed(accountID: UUID) async -> Bool { true }
    func ingestionLowerBound(accountID: UUID) async -> Date? { nil }
    func flagReconciliationUIDs(accountID: UUID, folderName: String, limit: Int) async -> [UInt32] { [] }
    func recordFlagReconciliationCursor(accountID: UUID, folderName: String, lastUID: UInt32) async {}
    func recentUnreadLiveArrivalUIDs(accountID: UUID, since: Date) async -> [String: [UInt32]] { [:] }
}

public extension IMAPRawMessageIngesting {
    func ingestRawRFC5322(
        data: Data,
        accountID: UUID,
        folderPath: String,
        folderAttributes: [String],
        serverUID: UInt32,
        folderUIDValidity: UInt32? = nil,
        receivedAt: Date?,
        seenAtSource: Bool?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> IMAPRawMessageIngestionResult {
        try await ingestRawRFC5322(
            data: data,
            accountID: accountID,
            folderPath: folderPath,
            serverUID: serverUID,
            receivedAt: receivedAt,
            seenAtSource: seenAtSource,
            automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
        )
    }
}

public struct IMAPFolderStateSnapshot: Sendable {
    public var accountID: UUID
    public var folderName: String
    public var folderAttributes: [String]
    public var uidValidity: UInt32
    public var uidNextAtLastSelect: UInt32
    public var existsAtLastSelect: Int?
    public var highestFetchedUID: UInt32
    public var lowestFetchedUID: UInt32
    public var backfillComplete: Bool
    public var highestModSeq: UInt64?
    public var lastDeletionSyncAt: Date?
    public var lastMessageIDReconciliationAt: Date?
    public var backfillLowerBoundAt: Date?
    public var inScopeMessageCountAtLastSelect: Int?
    public var initialImportUIDWorkTotal: Int?
    public var initialImportUIDWorkRemaining: Int?
    public var initialImportSnapshotUIDValidity: UInt32?
    public var initialImportTerminalExclusionReason: String?

    public init(
        accountID: UUID,
        folderName: String,
        folderAttributes: [String],
        uidValidity: UInt32,
        uidNextAtLastSelect: UInt32,
        existsAtLastSelect: Int? = nil,
        highestFetchedUID: UInt32,
        lowestFetchedUID: UInt32,
        backfillComplete: Bool,
        highestModSeq: UInt64? = nil,
        lastDeletionSyncAt: Date? = nil,
        lastMessageIDReconciliationAt: Date? = nil,
        backfillLowerBoundAt: Date? = nil,
        inScopeMessageCountAtLastSelect: Int? = nil,
        initialImportUIDWorkTotal: Int? = nil,
        initialImportUIDWorkRemaining: Int? = nil,
        initialImportSnapshotUIDValidity: UInt32? = nil,
        initialImportTerminalExclusionReason: String? = nil
    ) {
        self.accountID = accountID
        self.folderName = folderName
        self.folderAttributes = folderAttributes
        self.uidValidity = uidValidity
        self.uidNextAtLastSelect = uidNextAtLastSelect
        self.existsAtLastSelect = existsAtLastSelect
        self.highestFetchedUID = highestFetchedUID
        self.lowestFetchedUID = lowestFetchedUID
        self.backfillComplete = backfillComplete
        self.highestModSeq = highestModSeq
        self.lastDeletionSyncAt = lastDeletionSyncAt
        self.lastMessageIDReconciliationAt = lastMessageIDReconciliationAt
        self.backfillLowerBoundAt = backfillLowerBoundAt
        self.inScopeMessageCountAtLastSelect = inScopeMessageCountAtLastSelect
        self.initialImportUIDWorkTotal = initialImportUIDWorkTotal
        self.initialImportUIDWorkRemaining = initialImportUIDWorkRemaining
        self.initialImportSnapshotUIDValidity = initialImportSnapshotUIDValidity
        self.initialImportTerminalExclusionReason = initialImportTerminalExclusionReason
    }
}

// MARK: - Mailbox-change drain helpers

extension IMAPSession {
    /// For a fresh session, anchor INBOX at the server's current UID high-water
    /// mark before entering IDLE. That lets the live tail ingest only messages
    /// that arrive after Ohia starts listening, while historical backfill can
    /// later walk downward from the same boundary.
    private func establishLiveBaselineIfNeeded(folder: String, selectState: IMAPSelectState) async {
        guard folder.uppercased() == "INBOX" else { return }

        var snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: folder)
        if let existing = snapshot,
           existing.uidValidity != 0,
           existing.uidValidity != selectState.uidValidity {
            await folderStateStore.handleUIDValidityChange(
                accountID: accountID,
                folderName: folder,
                newUIDValidity: selectState.uidValidity
            )
            snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: folder)
        }

        let anchor = selectState.uidNext > 0 ? selectState.uidNext - 1 : 0
        let catchUpHighWater = anchor > Self.liveStartupCatchUpWindow
            ? anchor - Self.liveStartupCatchUpWindow
            : 0
        let catchUpLowestUID = catchUpHighWater + 1
        if var existing = snapshot {
            let isUninitialized = existing.lowestFetchedUID == 0
            guard isUninitialized else { return }
            existing.uidValidity = selectState.uidValidity
            existing.uidNextAtLastSelect = selectState.uidNext
            existing.existsAtLastSelect = selectState.exists
            existing.highestFetchedUID = catchUpHighWater
            existing.lowestFetchedUID = catchUpLowestUID
            existing.backfillComplete = anchor == 0
            await folderStateStore.upsertFolderState(existing)
        } else {
            await folderStateStore.upsertFolderState(IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: folder,
                folderAttributes: ["\\Inbox"],
                uidValidity: selectState.uidValidity,
                uidNextAtLastSelect: selectState.uidNext,
                existsAtLastSelect: selectState.exists,
                highestFetchedUID: catchUpHighWater,
                lowestFetchedUID: catchUpLowestUID,
                backfillComplete: anchor == 0
            ))
        }
    }

    /// End IDLE has already been sent — do the quick SELECT + UID FETCH
    /// of any new UIDs, ingest via the raw-message protocol, and upsert
    /// the folder state snapshot with the new highestFetchedUID.
    private func drainNewMailInINBOX() async throws {
        guard let c = client else { throw IMAPError.notConnected }
        await transition(to: .syncing(folder: "INBOX"))

        // Re-SELECT INBOX to pick up fresh UIDNEXT / EXISTS.
        let freshResult = try await selectMailboxTrackingDeletions("INBOX")
        let fresh = freshResult.select
        await handleUIDValidityChangeIfNeeded(folder: "INBOX", newState: fresh)
        currentSelectState = fresh
        currentMailbox = "INBOX"
        lastKnownExists = fresh.exists

        let snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: "INBOX")
        let currentHigh = snapshot?.highestFetchedUID ?? 0
        guard fresh.uidNext > currentHigh + 1 else {
            recordManualLiveTailProgress(
                folder: "INBOX",
                uidValidity: fresh.uidValidity,
                highestCheckedUID: fresh.uidNext > 0 ? fresh.uidNext - 1 : 0
            )
            await postSuccessfulPollNotification(folder: "INBOX")
            return
        }

        let range = (currentHigh + 1)...(fresh.uidNext - 1)
        let fetchResult = try await fetchAndIngestForwardMessages(
            using: c,
            range: range,
            folder: "INBOX",
            folderUIDValidity: fresh.uidValidity,
            automaticallySummarizeNewMessages: true
        )
        var newSnapshot = snapshot ?? IMAPFolderStateSnapshot(
            accountID: accountID,
            folderName: "INBOX",
            folderAttributes: ["\\Inbox"],
            uidValidity: fresh.uidValidity,
            uidNextAtLastSelect: fresh.uidNext,
            existsAtLastSelect: fresh.exists,
            highestFetchedUID: fresh.uidNext - 1,
            lowestFetchedUID: fresh.uidNext,
            backfillComplete: false
        )
        newSnapshot.highestFetchedUID = fresh.uidNext - 1
        newSnapshot.uidNextAtLastSelect = fresh.uidNext
        newSnapshot.existsAtLastSelect = fresh.exists
        newSnapshot = await mergeWithLatestFolderProgress(newSnapshot, folder: "INBOX")
        await folderStateStore.upsertFolderState(newSnapshot)
        await reportNewInboundMessagesIfNeeded(
            messageIDs: fetchResult.newInboundMessageIDs,
            folder: "INBOX"
        )
        recordManualLiveTailProgress(
            folder: "INBOX",
            uidValidity: fresh.uidValidity,
            highestCheckedUID: fresh.uidNext - 1
        )
        await postSuccessfulPollNotification(folder: "INBOX")

        print("[Ohia] IMAP drained \(fetchResult.fetchedCount) new INBOX messages")
    }

    private func shouldReportNewInboundMessage(
        _ result: IMAPRawMessageIngestionResult,
        automaticallySummarizeNewMessages: Bool
    ) -> Bool {
        automaticallySummarizeNewMessages
            && result.disposition == .insertedNew
            && result.messageId != nil
            && !result.isSentByUser
            && result.allowsLiveInboundNotification
    }

    /// Gmail exposes drafts through All Mail as well as its Drafts mailbox.
    /// The system `\Draft` flag is therefore the message-level authority:
    /// process it only when the selected mailbox itself is Drafts, where the
    /// ingestion bridge updates Composer draft state instead of the corpus.
    private static func shouldSkipDraftFromCorpus(
        _ message: IMAPFetch.Message,
        folder: String,
        folderAttributes: [String]
    ) -> Bool {
        let isDraft = message.flags.contains {
            $0.caseInsensitiveCompare("\\Draft") == .orderedSame
        }
        return isDraft
            && !IMAPFolderIngestionPolicy.isDraftsFolder(
                folderName: folder,
                attributes: folderAttributes
            )
    }

    private func fetchAndIngestForwardMessages(
        using c: any IMAPClienting,
        range: ClosedRange<UInt32>,
        folder: String,
        folderUIDValidity: UInt32?,
        automaticallySummarizeNewMessages: Bool
    ) async throws -> (fetchedCount: Int, newInboundMessageIDs: [UUID]) {
        var fetchedCount = 0
        var newInboundMessageIDs: [UUID] = []
        let folderAttributes = await folderStateStore
            .readFolderState(accountID: accountID, folderName: folder)?
            .folderAttributes ?? []
        do {
            let stream = await c.uidFetchStream(range: range, attrs: .all)
            for try await msg in stream {
                if !Self.shouldSkipDraftFromCorpus(
                    msg,
                    folder: folder,
                    folderAttributes: folderAttributes
                ) {
                    let result = try await ingestRaw.ingestRawRFC5322(
                        data: msg.rfc822Bytes,
                        accountID: accountID,
                        folderPath: folder,
                        folderAttributes: folderAttributes,
                        serverUID: msg.uid,
                        folderUIDValidity: folderUIDValidity,
                        receivedAt: msg.internalDate,
                        seenAtSource: msg.flags.contains("\\Seen"),
                        automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
                    )
                    if shouldReportNewInboundMessage(
                        result,
                        automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
                    ), let messageId = result.messageId {
                        newInboundMessageIDs.append(messageId)
                    }
                }
                fetchedCount += 1
            }
            return (fetchedCount, newInboundMessageIDs)
        } catch {
            await reportNewInboundMessagesIfNeeded(messageIDs: newInboundMessageIDs, folder: folder)
            throw error
        }
    }

    private func reportNewInboundMessagesIfNeeded(messageIDs: [UUID], folder: String) async {
        guard messageIDs.isEmpty == false else { return }
        backfillYieldRequested = true
        await statusReporter?.reportNewInboundMessages(
            IMAPNewInboundMessageEvent(
                folder: folder,
                count: messageIDs.count,
                messageIDs: messageIDs
            ),
            for: accountID
        )
    }

    /// If the folder's stored UIDVALIDITY (nonzero — 0 means "never selected
    /// before") differs from the server's, notify the store which treats
    /// this as "mailbox rebuilt" and resets highestFetchedUID / backfillComplete.
    private func handleUIDValidityChangeIfNeeded(folder: String, newState: IMAPSelectState) async {
        let snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: folder)
        if let s = snapshot, s.uidValidity != 0, s.uidValidity != newState.uidValidity {
            await folderStateStore.handleUIDValidityChange(
                accountID: accountID,
                folderName: folder,
                newUIDValidity: newState.uidValidity
            )
        }
    }
}

// MARK: - backfillTick + pollFolder

extension IMAPSession {
    private func connectAuxiliaryClient() async throws -> (client: any IMAPClienting, qresyncEnabled: Bool) {
        try Task.checkCancellation()
        let c = clientFactory()
        let openingID = UUID()
        let generation = auxiliaryGeneration
        openingAuxiliaryClients[openingID] = c
        defer { openingAuxiliaryClients[openingID] = nil }
        do {
            try await c.connect(
                host: imapHost,
                port: imapPort,
                security: imapSecurity,
                pinnedCertSHA256: pinnedCertSHA256
            )
            try Task.checkCancellation()
            guard generation == auxiliaryGeneration else { throw CancellationError() }

            switch imapAuthMethod {
            case .password:
                let password = try await credentialsResolver.passwordForAccount(accountID)
                try await c.authenticatePlain(username: imapUsername, password: password)

            case .oauth2:
                let provider: MailProvider.OAuthProviderID = {
                    if imapHost.contains("gmail") || imapHost.contains("google") { return .gmail }
                    return .microsoft
                }()
                let token = try await credentialsResolver.oauthAccessTokenForAccount(accountID, provider: provider)
                try await c.authenticateXOAuth2(username: imapUsername, accessToken: token)
            }

            let caps = try await c.capability()
            var qresyncEnabled = false
            if caps.qresync {
                do {
                    try await c.enableQresync()
                    qresyncEnabled = true
                } catch {
                    qresyncEnabled = false
                }
            }
            try Task.checkCancellation()
            guard generation == auxiliaryGeneration else { throw CancellationError() }
            return (c, qresyncEnabled)
        } catch {
            if generation == auxiliaryGeneration {
                await c.close()
            }
            throw error
        }
    }

    /// Run an operation against the pooled auxiliary IMAP client, lazily
    /// connecting on first use and reusing the same connection for
    /// subsequent calls. On a recoverable transport-level failure (e.g.
    /// the server idle-timed-out the socket between calls), tear down and
    /// retry exactly once with a fresh connection. Non-recoverable errors
    /// (TLS handshake, auth, protocol) propagate without retry — they would
    /// fail the same way on a second connect.
    private func withAuxiliaryClient<T: Sendable>(
        lane: AuxiliaryLane = .background,
        activityStatus: Status? = nil,
        postsCheckingMailEvent: Bool = false,
        prioritizesUserInitiatedWork: Bool = false,
        _ operation: (any IMAPClienting, Bool) async throws -> T
    ) async throws -> T {
        try await acquireAuxiliaryOperationSlot(
            lane: lane,
            prioritizesUserInitiatedWork: prioritizesUserInitiatedWork
        )
        defer { releaseAuxiliaryOperationSlot(lane: lane) }
        try Task.checkCancellation()

        if let activityStatus {
            if postsCheckingMailEvent {
                await postAuxiliaryActivityNotification(activityStatus)
            }
            await statusReporter?.reportStatus(activityStatus.sendable, for: accountID)
        }

        do {
            let result = try await runAuxiliaryClientOperation(lane: lane, operation)
            if activityStatus != nil {
                await statusReporter?.reportStatus(status.sendable, for: accountID)
            }
            return result
        } catch {
            if activityStatus != nil {
                await statusReporter?.reportStatus(status.sendable, for: accountID)
            }
            throw error
        }
    }

    private func runAuxiliaryClientOperation<T: Sendable>(
        lane: AuxiliaryLane,
        _ operation: (any IMAPClienting, Bool) async throws -> T
    ) async throws -> T {
        let generation = auxiliaryGeneration
        if let existing = auxiliaryPools[lane]?.client {
            do {
                return try await operation(existing.client, existing.qresyncEnabled)
            } catch {
                // Operation failed against an existing client. The connection
                // may now be in an inconsistent state (mid-fetch parser
                // position, server-closed socket, etc.) regardless of why,
                // so always tear it down. Retry only if the error class is
                // one a fresh connection can plausibly recover from.
                await tearDownAuxiliaryClient(lane: lane)
                try Task.checkCancellation()
                guard generation == auxiliaryGeneration else { throw CancellationError() }
                if !Self.isAuxiliaryRecoverable(error) {
                    throw error
                }
                // fall through to fresh connect + retry
            }
        }

        let fresh = try await connectAuxiliaryClient()
        do {
            try Task.checkCancellation()
            guard generation == auxiliaryGeneration else { throw CancellationError() }
            // Retain before awaiting so shutdown can close an in-flight command.
            auxiliaryPools[lane, default: AuxiliaryPool()].client = fresh
            let result = try await operation(fresh.client, fresh.qresyncEnabled)
            return result
        } catch {
            if generation == auxiliaryGeneration {
                auxiliaryPools[lane, default: AuxiliaryPool()].client = nil
            }
            await fresh.client.close()
            throw error
        }
    }

    @MainActor
    private func postAuxiliaryActivityNotification(_ activityStatus: Status) {
        guard case .syncing(let folder) = activityStatus else { return }
        NotificationCenter.default.post(
            name: .ohiaIMAPCheckingMail,
            object: nil,
            userInfo: [
                "accountID": accountID,
                "folder": folder
            ]
        )
    }

    @MainActor
    private func postSuccessfulPollNotification(folder: String) {
        NotificationCenter.default.post(
            name: .ohiaIMAPPollSucceeded,
            object: nil,
            userInfo: [
                "accountID": accountID,
                "folder": folder
            ]
        )
    }

    private func acquireAuxiliaryOperationSlot(
        lane: AuxiliaryLane,
        prioritizesUserInitiatedWork: Bool
    ) async throws {
        try Task.checkCancellation()
        guard auxiliaryPools[lane, default: AuxiliaryPool()].operationActive else {
            auxiliaryPools[lane, default: AuxiliaryPool()].operationActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if prioritizesUserInitiatedWork {
                    auxiliaryPools[lane, default: AuxiliaryPool()].waiters.insert((id, continuation), at: 0)
                } else {
                    auxiliaryPools[lane, default: AuxiliaryPool()].waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelAuxiliaryWaiter(id: id, lane: lane) }
        }
    }

    private func cancelAuxiliaryWaiter(id: UUID, lane: AuxiliaryLane) {
        guard let index = auxiliaryPools[lane]?.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = auxiliaryPools[lane]!.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseAuxiliaryOperationSlot(lane: AuxiliaryLane) {
        guard auxiliaryPools[lane]?.waiters.isEmpty == false else {
            auxiliaryPools[lane, default: AuxiliaryPool()].operationActive = false
            return
        }

        let next = auxiliaryPools[lane]!.waiters.removeFirst()
        next.continuation.resume()
    }

    private func tearDownAuxiliaryClient(lane: AuxiliaryLane) async {
        guard let aux = auxiliaryPools[lane]?.client else { return }
        auxiliaryPools[lane, default: AuxiliaryPool()].client = nil
        // An active operation may own the response reader; never issue LOGOUT
        // concurrently with it. Closing also releases pending network reads.
        if auxiliaryPools[lane]?.operationActive == true {
            await aux.client.close()
        } else {
            await Self.tearDown(client: aux.client)
        }
    }

    private func tearDownPrimaryClient() async {
        guard let c = client else { return }
        client = nil
        currentMailbox = nil
        currentSelectState = nil
        await Self.tearDown(client: c)
    }

    private static func tearDown(client: any IMAPClienting) async {
        await client.logout()
        await client.close()
    }

    /// True for errors that a brand-new aux-client connection can plausibly
    /// recover from on retry: transport-level disconnects (server idle
    /// timeout, mid-stream socket close, transient network blip). False for
    /// permanent classes — TLS handshake, cert pin, auth, protocol — which
    /// would fail identically against a fresh connection. Note: any error
    /// raised against a fresh-from-`connectAuxiliaryClient` client (TLS,
    /// auth, etc.) lands in the second `do/catch` of `withAuxiliaryClient`
    /// and propagates without consulting this classifier.
    private static func isAuxiliaryRecoverable(_ error: Error) -> Bool {
        guard let imap = error as? IMAPError else { return false }
        switch imap {
        case .transient, .serverTemporary, .serverClosedConnection, .notConnected:
            return true
        case .mailStream(let inner):
            switch inner {
            case .connectionClosed, .stream, .notConnected:
                return true
            case .tlsHandshakeFailed, .certPinMismatch, .invalidUTF8, .wrongState:
                return false
            }
        case .authFailed, .reauthRequired, .protocolViolation, .notImapServer, .cancelled:
            return false
        }
    }

    private var liveLoopOwnsPrimaryConnection: Bool {
        guard mainTask != nil else { return false }
        switch status {
        case .disconnected, .halted:
            return false
        case .connecting, .authing, .selected, .idling, .syncing, .reconnecting:
            return true
        }
    }

    /// Walk down one batch from (lowestFetchedUID - 1) toward UID 1. Suspends
    /// IDLE on entry, SELECTs the target folder (routing UIDVALIDITY changes),
    /// UID-FETCHes the next range, ingests each message, upserts the folder
    /// state snapshot, then drains any fresh INBOX arrivals before resuming IDLE.
    public func backfillTick(folder: String, batchSize: Int) async throws -> BackfillResult {
        if liveLoopOwnsPrimaryConnection || client == nil {
            return try await backfillTickOnAuxiliaryClient(folder: folder, batchSize: batchSize)
        }

        guard let c = client else { throw IMAPError.notConnected }

        let wasIdling = try await suspendIdleIfNeeded(using: c)

        await transition(to: .syncing(folder: folder))

        do {
            if currentMailbox != folder {
                let newResult = try await selectMailboxTrackingDeletions(folder)
                let newState = newResult.select
                await handleUIDValidityChangeIfNeeded(folder: folder, newState: newState)
                currentMailbox = folder
                currentSelectState = newState
            }

            guard let selectState = currentSelectState else {
                throw IMAPError.notConnected
            }

            let lowerBound = await folderStateStore.ingestionLowerBound(accountID: accountID)
            let snapshot = await effectiveBackfillSnapshot(
                folder: folder,
                selectState: selectState,
                lowerBound: lowerBound
            )
            let (low, high, skip) = Self.nextBackfillRange(
                snapshot: snapshot,
                selectState: selectState,
                batchSize: batchSize
            )
            if skip {
                if var s = snapshot {
                    s.backfillComplete = true
                    s.backfillLowerBoundAt = lowerBound
                    await folderStateStore.upsertFolderState(s)
                }
                await markInitialImportWorkExhausted(folder: folder)
                let result = BackfillResult(
                    fetched: 0,
                    newLowestFetchedUID: snapshot?.lowestFetchedUID ?? 1,
                    backfillComplete: true
                )
                try await drainLiveInboxAndResumeIdleIfNeeded(wasIdling: wasIdling)
                return result
            }

            let plan = try await makeBackfillFetchPlan(
                using: c,
                fallbackRange: low...high,
                cursorHigh: high,
                batchSize: batchSize,
                lowerBound: lowerBound
            )
            if plan.isExhausted {
                var updated = snapshot ?? IMAPFolderStateSnapshot(
                    accountID: accountID,
                    folderName: folder,
                    folderAttributes: [],
                    uidValidity: selectState.uidValidity,
                    uidNextAtLastSelect: selectState.uidNext,
                    existsAtLastSelect: selectState.exists,
                    highestFetchedUID: selectState.uidNext > 0 ? selectState.uidNext - 1 : 0,
                    lowestFetchedUID: 1,
                    backfillComplete: true
                )
                updated.lowestFetchedUID = plan.cursorAfterBatch
                updated.uidNextAtLastSelect = selectState.uidNext
                updated.existsAtLastSelect = selectState.exists
                updated.backfillComplete = true
                updated.backfillLowerBoundAt = lowerBound
                updated = await mergeWithLatestFolderProgress(updated, folder: folder)
                await folderStateStore.upsertFolderState(updated)
                await recordInitialImportWorkProgress(
                    folder: folder,
                    selectState: selectState,
                    lowerBound: lowerBound,
                    searchedUIDCount: plan.searchedUIDCount,
                    processedUIDCount: 0
                )
                let result = BackfillResult(
                    fetched: 0,
                    newLowestFetchedUID: plan.cursorAfterBatch,
                    backfillComplete: true
                )
                try await drainLiveInboxAndResumeIdleIfNeeded(wasIdling: wasIdling)
                return result
            }

            let progress = try await fetchAndIngestBackfillMessages(
                using: c,
                source: plan.source,
                folder: folder,
                folderUIDValidity: selectState.uidValidity
            )

            var updated = snapshot ?? IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: folder,
                folderAttributes: [],
                uidValidity: selectState.uidValidity,
                uidNextAtLastSelect: selectState.uidNext,
                existsAtLastSelect: selectState.exists,
                highestFetchedUID: selectState.uidNext > 0 ? selectState.uidNext - 1 : 0,
                lowestFetchedUID: selectState.uidNext,
                backfillComplete: false
            )
            let proposedCursor = progress.yieldedForLiveInbound
                ? (progress.lowestIngestedUID ?? plan.cursorAfterBatch)
                : plan.cursorAfterBatch
            let initialImportCompleted = await folderStateStore.initialIMAPImportCompleted(
                accountID: accountID
            )
            let isCorpusFolder = await folderStateStore.isInitialImportCorpusFolder(
                accountID: accountID,
                folderName: folder
            )
            let cursorResolution = Self.resolvedBackfillCursor(
                proposedCursor: proposedCursor,
                previousCursor: snapshot?.lowestFetchedUID ?? selectState.uidNext,
                searchSucceeded: plan.searchedUIDCount != nil,
                initialImportCompleted: initialImportCompleted || isCorpusFolder == false,
                hasInitialWorkSnapshot: snapshot?.initialImportUIDWorkTotal != nil
            )
            updated.lowestFetchedUID = cursorResolution.cursor
            updated.uidNextAtLastSelect = selectState.uidNext
            updated.existsAtLastSelect = selectState.exists
            updated.backfillLowerBoundAt = lowerBound
            // Backfill is only complete when we've walked all the way down to
            // UID 1. A zero-fetch batch is NOT a completion signal — Gmail
            // (and any mailbox with historical EXPUNGE activity) has sparse
            // UID space, and a 50-UID range can land entirely in a deletion
            // gap. Previously this branch marked complete on any empty batch,
            // which permanently halted ingestion at the first gap and left
            // the rest of the mailbox unreachable.
            let didComplete = !progress.yieldedForLiveInbound
                && plan.completesBackfill
                && cursorResolution.mayComplete
            updated.backfillComplete = didComplete
            updated = await mergeWithLatestFolderProgress(updated, folder: folder)
            await folderStateStore.upsertFolderState(updated)
            await recordInitialImportWorkProgress(
                folder: folder,
                selectState: selectState,
                lowerBound: lowerBound,
                searchedUIDCount: plan.searchedUIDCount,
                processedUIDCount: progress.ingestedCount
            )

            let result = BackfillResult(
                fetched: progress.ingestedCount,
                newLowestFetchedUID: updated.lowestFetchedUID,
                backfillComplete: updated.backfillComplete
            )
            try await drainLiveInboxAndResumeIdleIfNeeded(wasIdling: wasIdling)
            return result
        } catch {
            if wasIdling {
                try? await resumeIdleOnINBOX()
            }
            throw error
        }
    }

    /// Pure math. Returns (low, high, skipEntirely).
    /// - Anchor step: no snapshot yet — skip; caller records the initial snapshot.
    /// - Complete: skip.
    /// - At floor (lowestFetchedUID == 1): skip.
    /// - Otherwise: high = lowest-1, low = max(1, lowest - batchSize).
    private func effectiveBackfillSnapshot(
        folder: String,
        selectState: IMAPSelectState,
        lowerBound: Date?
    ) async -> IMAPFolderStateSnapshot? {
        let snapshot = await folderStateStore.readFolderState(
            accountID: accountID,
            folderName: folder
        )
        return Self.effectiveHistoricalBackfillSnapshot(
            snapshot: snapshot,
            selectState: selectState,
            lowerBound: lowerBound
        )
    }

    internal static func effectiveHistoricalBackfillSnapshot(
        snapshot: IMAPFolderStateSnapshot?,
        selectState: IMAPSelectState,
        lowerBound: Date?
    ) -> IMAPFolderStateSnapshot? {
        guard var snapshot else { return nil }
        guard snapshot.uidValidity == 0 || snapshot.uidValidity == selectState.uidValidity else {
            return nil
        }
        snapshot.uidValidity = selectState.uidValidity
        if snapshot.lowestFetchedUID == 0 {
            snapshot.lowestFetchedUID = selectState.uidNext
        }
        guard snapshot.backfillLowerBoundAt != lowerBound else { return snapshot }
        snapshot.backfillComplete = false
        snapshot.backfillLowerBoundAt = nil
        return snapshot
    }

    internal static func nextBackfillRange(
        snapshot: IMAPFolderStateSnapshot?,
        selectState: IMAPSelectState,
        batchSize: Int
    ) -> (low: UInt32, high: UInt32, skip: Bool) {
        guard let s = snapshot else {
            return (low: 0, high: 0, skip: true)
        }
        guard !s.backfillComplete else { return (0, 0, true) }
        guard s.lowestFetchedUID > 1 else { return (0, 0, true) }
        let high = s.lowestFetchedUID - 1
        let batchU = UInt32(max(1, batchSize))
        let low: UInt32 = s.lowestFetchedUID > batchU ? s.lowestFetchedUID - batchU : 1
        return (low: low, high: high, skip: false)
    }

    internal static func backfillIngestionOrder(_ messages: [IMAPFetch.Message]) -> [IMAPFetch.Message] {
        messages.sorted { lhs, rhs in
            if lhs.uid != rhs.uid {
                return lhs.uid > rhs.uid
            }
            return (lhs.internalDate ?? Date(timeIntervalSince1970: 0))
                > (rhs.internalDate ?? Date(timeIntervalSince1970: 0))
        }
    }

    private struct BackfillIngestionProgress {
        let ingestedCount: Int
        let lowestIngestedUID: UInt32?
        let yieldedForLiveInbound: Bool
    }

    private enum BackfillFetchSource {
        case uidSet([UInt32])
        case range(ClosedRange<UInt32>)
    }

    private struct BackfillFetchPlan {
        let source: BackfillFetchSource
        let cursorAfterBatch: UInt32
        let completesBackfill: Bool
        let searchedUIDCount: Int?

        var isExhausted: Bool {
            if case .uidSet(let uids) = source {
                return uids.isEmpty
            }
            return false
        }
    }

    private func makeBackfillFetchPlan(
        using client: any IMAPClienting,
        fallbackRange: ClosedRange<UInt32>,
        cursorHigh: UInt32,
        batchSize: Int,
        lowerBound: Date?
    ) async throws -> BackfillFetchPlan {
        do {
            let available: [UInt32]
            if let lowerBound {
                available = try await client.uidSearch(range: 1...cursorHigh, since: lowerBound)
            } else {
                available = try await client.uidSearch(range: 1...cursorHigh)
            }
            let selected = Self.backfillUIDBatch(
                availableUIDs: available,
                beforeOrAt: cursorHigh,
                batchSize: batchSize
            )
            let cursorBeforeSearch = cursorHigh == UInt32.max ? UInt32.max : cursorHigh + 1
            if selected.isEmpty {
                return BackfillFetchPlan(
                    source: .uidSet([]),
                    cursorAfterBatch: Self.cursorAfterHistoricalSearch(
                        selectedUIDs: [],
                        cursorBeforeSearch: cursorBeforeSearch,
                        hasLowerBound: lowerBound != nil
                    ),
                    completesBackfill: true,
                    searchedUIDCount: 0
                )
            }
            let exhaustsSearchResults = selected.count == available.filter { $0 <= cursorHigh }.count
            let cursorAfterBatch = exhaustsSearchResults
                ? Self.cursorAfterHistoricalSearch(
                    selectedUIDs: selected,
                    cursorBeforeSearch: cursorBeforeSearch,
                    hasLowerBound: lowerBound != nil
                )
                : (selected.min() ?? fallbackRange.lowerBound)
            return BackfillFetchPlan(
                source: .uidSet(selected),
                cursorAfterBatch: cursorAfterBatch,
                completesBackfill: exhaustsSearchResults,
                searchedUIDCount: available.filter { $0 <= cursorHigh }.count
            )
        } catch {
            return BackfillFetchPlan(
                source: .range(fallbackRange),
                cursorAfterBatch: fallbackRange.lowerBound,
                completesBackfill: fallbackRange.lowerBound == 1,
                searchedUIDCount: nil
            )
        }
    }

    internal static func backfillUIDBatch(
        availableUIDs: [UInt32],
        beforeOrAt cursorHigh: UInt32,
        batchSize: Int
    ) -> [UInt32] {
        let safeBatchSize = max(1, batchSize)
        return Array(
            availableUIDs
                .filter { $0 <= cursorHigh }
                .sorted(by: >)
                .prefix(safeBatchSize)
        )
    }

    internal static func cursorAfterHistoricalSearch(
        selectedUIDs: [UInt32],
        cursorBeforeSearch: UInt32,
        hasLowerBound: Bool
    ) -> UInt32 {
        guard hasLowerBound else { return 1 }
        return selectedUIDs.min() ?? cursorBeforeSearch
    }

    internal static func initialImportWorkSnapshot(
        snapshot: IMAPFolderStateSnapshot,
        selectState: IMAPSelectState,
        estimateFolder: IMAPFolderWorkEstimate?,
        searchedUIDCount: Int?,
        processedUIDCount: Int
    ) -> IMAPFolderStateSnapshot {
        var updated = snapshot
        guard updated.uidValidity == 0 || updated.uidValidity == selectState.uidValidity else {
            return updated
        }

        if updated.initialImportUIDWorkTotal == nil {
            let matchingEstimateCount: Int? = {
                guard let estimateFolder,
                      estimateFolder.folderName == snapshot.folderName,
                      estimateFolder.uidValidity == selectState.uidValidity else {
                    return nil
                }
                return estimateFolder.candidateUIDCount
            }()
            guard let initialTotal = matchingEstimateCount ?? searchedUIDCount else {
                return updated
            }
            let clampedTotal = max(0, initialTotal)
            updated.initialImportUIDWorkTotal = clampedTotal
            updated.initialImportUIDWorkRemaining = clampedTotal
            updated.initialImportSnapshotUIDValidity = selectState.uidValidity
        }

        guard let total = updated.initialImportUIDWorkTotal else { return updated }
        if let searchedUIDCount {
            let liveTotal = max(0, searchedUIDCount)
            if processedUIDCount == 0,
               (updated.initialImportUIDWorkRemaining ?? total) == total,
               liveTotal != total {
                updated.initialImportUIDWorkTotal = liveTotal
                updated.initialImportUIDWorkRemaining = liveTotal
                return updated
            }
            let proposedRemaining = min(
                total,
                max(0, liveTotal - max(0, processedUIDCount))
            )
            updated.initialImportUIDWorkRemaining = min(
                updated.initialImportUIDWorkRemaining ?? total,
                proposedRemaining
            )
        }
        return updated
    }

    internal static func resolvedBackfillCursor(
        proposedCursor: UInt32,
        previousCursor: UInt32,
        searchSucceeded: Bool,
        initialImportCompleted: Bool,
        hasInitialWorkSnapshot: Bool
    ) -> (cursor: UInt32, mayComplete: Bool) {
        let mustAwaitWorkSnapshot = initialImportCompleted == false
            && hasInitialWorkSnapshot == false
            && searchSucceeded == false
        return mustAwaitWorkSnapshot
            ? (cursor: previousCursor, mayComplete: false)
            : (cursor: proposedCursor, mayComplete: true)
    }

    private func recordInitialImportWorkProgress(
        folder: String,
        selectState: IMAPSelectState,
        lowerBound: Date?,
        searchedUIDCount: Int?,
        processedUIDCount: Int
    ) async {
        guard await folderStateStore.initialIMAPImportCompleted(accountID: accountID) == false,
              await folderStateStore.isInitialImportCorpusFolder(
                accountID: accountID,
                folderName: folder
              ),
              let snapshot = await folderStateStore.readFolderState(
                accountID: accountID,
                folderName: folder
              ) else {
            return
        }
        let estimateFolder: IMAPFolderWorkEstimate?
        if initialHistoryEstimate?.lowerBound == lowerBound {
            estimateFolder = initialHistoryEstimate?.folderWork.first { estimate in
                estimate.folderName == folder
            }
        } else {
            estimateFolder = nil
        }
        let updated = Self.initialImportWorkSnapshot(
            snapshot: snapshot,
            selectState: selectState,
            estimateFolder: estimateFolder,
            searchedUIDCount: searchedUIDCount,
            processedUIDCount: processedUIDCount
        )
        await folderStateStore.upsertFolderState(updated)
    }

    private func markInitialImportWorkExhausted(folder: String) async {
        guard await folderStateStore.initialIMAPImportCompleted(accountID: accountID) == false,
              await folderStateStore.isInitialImportCorpusFolder(
                accountID: accountID,
                folderName: folder
              ),
              var snapshot = await folderStateStore.readFolderState(
                accountID: accountID,
                folderName: folder
              ),
              snapshot.initialImportUIDWorkTotal != nil else {
            return
        }
        snapshot.initialImportUIDWorkRemaining = 0
        await folderStateStore.upsertFolderState(snapshot)
    }

    private func fetchAndIngestBackfillMessages(
        using client: any IMAPClienting,
        source: BackfillFetchSource,
        folder: String,
        folderUIDValidity: UInt32?
    ) async throws -> BackfillIngestionProgress {
        let stream: AsyncThrowingStream<IMAPFetch.Message, Error>
        switch source {
        case .uidSet(let uids):
            guard !uids.isEmpty else {
                return BackfillIngestionProgress(
                    ingestedCount: 0,
                    lowestIngestedUID: nil,
                    yieldedForLiveInbound: false
                )
            }
            stream = await client.uidFetchStream(uids: uids, attrs: .all)
        case .range(let range):
            stream = await client.uidFetchStream(range: range, attrs: .all)
        }

        var ingestedCount = 0
        var lowestIngestedUID: UInt32?
        var yieldedForLiveInbound = false
        var yieldBeforeNextMessage = false
        let folderAttributes = await folderStateStore
            .readFolderState(accountID: accountID, folderName: folder)?
            .folderAttributes ?? []

        for try await msg in stream {
            if yieldBeforeNextMessage {
                yieldedForLiveInbound = true
            }
            // Keep draining the active FETCH response after a live-preemption
            // request so the IMAP connection is not abandoned mid-command.
            // The cursor stays at the lowest ingested UID, so skipped
            // historical messages are retried later and dedup remains cheap.
            guard !yieldedForLiveInbound else { continue }

            if !Self.shouldSkipDraftFromCorpus(
                msg,
                folder: folder,
                folderAttributes: folderAttributes
            ) {
                _ = try await ingestRaw.ingestRawRFC5322(
                    data: msg.rfc822Bytes,
                    accountID: accountID,
                    folderPath: folder,
                    folderAttributes: folderAttributes,
                    serverUID: msg.uid,
                    folderUIDValidity: folderUIDValidity,
                    receivedAt: msg.internalDate,
                    seenAtSource: msg.flags.contains("\\Seen"),
                    automaticallySummarizeNewMessages: false
                )
            }
            ingestedCount += 1
            lowestIngestedUID = min(lowestIngestedUID ?? msg.uid, msg.uid)

            if consumeBackfillYieldRequest() {
                // Match the old buffered path: a yield request only shortens
                // the batch if there is another historical message left after
                // the one we just ingested. For a one-message batch, the fetch
                // is already drained and the caller may safely complete the
                // cursor normally.
                yieldBeforeNextMessage = true
            }
        }

        return BackfillIngestionProgress(
            ingestedCount: ingestedCount,
            lowestIngestedUID: lowestIngestedUID,
            yieldedForLiveInbound: yieldedForLiveInbound
        )
    }

    private func consumeBackfillYieldRequest() -> Bool {
        guard backfillYieldRequested else { return false }
        backfillYieldRequested = false
        return true
    }

    private func mergeWithLatestFolderProgress(
        _ candidate: IMAPFolderStateSnapshot,
        folder: String
    ) async -> IMAPFolderStateSnapshot {
        guard let latest = await folderStateStore.readFolderState(
            accountID: accountID,
            folderName: folder
        ) else {
            return candidate
        }
        return Self.mergeFolderProgress(candidate, with: latest)
    }

    internal static func mergeFolderProgress(
        _ candidate: IMAPFolderStateSnapshot,
        with latest: IMAPFolderStateSnapshot
    ) -> IMAPFolderStateSnapshot {
        guard candidate.accountID == latest.accountID,
              candidate.folderName == latest.folderName,
              candidate.uidValidity == latest.uidValidity else {
            return candidate
        }

        var merged = candidate
        merged.highestFetchedUID = max(candidate.highestFetchedUID, latest.highestFetchedUID)
        if candidate.lowestFetchedUID == 0 {
            merged.lowestFetchedUID = latest.lowestFetchedUID
        } else if latest.lowestFetchedUID > 0 {
            merged.lowestFetchedUID = min(candidate.lowestFetchedUID, latest.lowestFetchedUID)
        }
        if candidate.backfillLowerBoundAt == latest.backfillLowerBoundAt {
            merged.backfillComplete = candidate.backfillComplete || latest.backfillComplete
        } else {
            merged.backfillComplete = candidate.backfillComplete
        }

        if latest.uidNextAtLastSelect > candidate.uidNextAtLastSelect {
            merged.uidNextAtLastSelect = latest.uidNextAtLastSelect
            merged.existsAtLastSelect = latest.existsAtLastSelect
        } else if candidate.existsAtLastSelect == nil {
            merged.existsAtLastSelect = latest.existsAtLastSelect
        }

        if merged.folderAttributes.isEmpty {
            merged.folderAttributes = latest.folderAttributes
        }
        if let latestModSeq = latest.highestModSeq {
            merged.highestModSeq = max(merged.highestModSeq ?? 0, latestModSeq)
        }
        if let latestDeletionSync = latest.lastDeletionSyncAt,
           merged.lastDeletionSyncAt.map({ $0 < latestDeletionSync }) ?? true {
            merged.lastDeletionSyncAt = latestDeletionSync
        }
        if let latestReconciliation = latest.lastMessageIDReconciliationAt,
           merged.lastMessageIDReconciliationAt.map({ $0 < latestReconciliation }) ?? true {
            merged.lastMessageIDReconciliationAt = latestReconciliation
        }
        if merged.inScopeMessageCountAtLastSelect == nil {
            merged.inScopeMessageCountAtLastSelect = latest.inScopeMessageCountAtLastSelect
        }
        if merged.initialImportUIDWorkTotal == nil {
            merged.initialImportUIDWorkTotal = latest.initialImportUIDWorkTotal
            merged.initialImportUIDWorkRemaining = latest.initialImportUIDWorkRemaining
            merged.initialImportSnapshotUIDValidity = latest.initialImportSnapshotUIDValidity
        } else if merged.initialImportUIDWorkTotal == latest.initialImportUIDWorkTotal,
                  let latestRemaining = latest.initialImportUIDWorkRemaining {
            merged.initialImportUIDWorkRemaining = min(
                merged.initialImportUIDWorkRemaining ?? latestRemaining,
                latestRemaining
            )
        }
        if merged.initialImportTerminalExclusionReason == nil {
            merged.initialImportTerminalExclusionReason = latest.initialImportTerminalExclusionReason
        }
        return merged
    }

    private func ingestBackfillMessages(
        _ messages: [IMAPFetch.Message],
        folder: String,
        folderUIDValidity: UInt32?
    ) async throws -> BackfillIngestionProgress {
        let ordered = Self.backfillIngestionOrder(messages)
        var ingestedCount = 0
        var lowestIngestedUID: UInt32?
        let folderAttributes = await folderStateStore
            .readFolderState(accountID: accountID, folderName: folder)?
            .folderAttributes ?? []

        for index in ordered.indices {
            let msg = ordered[index]
            if !Self.shouldSkipDraftFromCorpus(
                msg,
                folder: folder,
                folderAttributes: folderAttributes
            ) {
                _ = try await ingestRaw.ingestRawRFC5322(
                    data: msg.rfc822Bytes,
                    accountID: accountID,
                    folderPath: folder,
                    folderAttributes: folderAttributes,
                    serverUID: msg.uid,
                    folderUIDValidity: folderUIDValidity,
                    receivedAt: msg.internalDate,
                    seenAtSource: msg.flags.contains("\\Seen"),
                    automaticallySummarizeNewMessages: false
                )
            }
            ingestedCount += 1
            lowestIngestedUID = min(lowestIngestedUID ?? msg.uid, msg.uid)

            if index < ordered.index(before: ordered.endIndex),
               consumeBackfillYieldRequest() {
                return BackfillIngestionProgress(
                    ingestedCount: ingestedCount,
                    lowestIngestedUID: lowestIngestedUID,
                    yieldedForLiveInbound: true
                )
            }
        }

        return BackfillIngestionProgress(
            ingestedCount: ingestedCount,
            lowestIngestedUID: lowestIngestedUID,
            yieldedForLiveInbound: false
        )
    }

    private func backfillTickOnAuxiliaryClient(folder: String, batchSize: Int) async throws -> BackfillResult {
        try await withAuxiliaryClient(activityStatus: .syncing(folder: folder)) { c, qresyncEnabled in
            let newResult = try await selectMailboxTrackingDeletions(
                folder,
                using: c,
                qresyncEnabled: qresyncEnabled
            )
            let selectState = newResult.select
            await handleUIDValidityChangeIfNeeded(folder: folder, newState: selectState)

            let lowerBound = await folderStateStore.ingestionLowerBound(accountID: accountID)
            let snapshot = await effectiveBackfillSnapshot(
                folder: folder,
                selectState: selectState,
                lowerBound: lowerBound
            )
            let (low, high, skip) = Self.nextBackfillRange(
                snapshot: snapshot,
                selectState: selectState,
                batchSize: batchSize
            )
            if skip {
                if var s = snapshot {
                    s.backfillComplete = true
                    s.backfillLowerBoundAt = lowerBound
                    await folderStateStore.upsertFolderState(s)
                }
                await markInitialImportWorkExhausted(folder: folder)
                return BackfillResult(
                    fetched: 0,
                    newLowestFetchedUID: snapshot?.lowestFetchedUID ?? 1,
                    backfillComplete: true
                )
            }

            let plan = try await makeBackfillFetchPlan(
                using: c,
                fallbackRange: low...high,
                cursorHigh: high,
                batchSize: batchSize,
                lowerBound: lowerBound
            )
            if plan.isExhausted {
                var updated = snapshot ?? IMAPFolderStateSnapshot(
                    accountID: accountID,
                    folderName: folder,
                    folderAttributes: [],
                    uidValidity: selectState.uidValidity,
                    uidNextAtLastSelect: selectState.uidNext,
                    existsAtLastSelect: selectState.exists,
                    highestFetchedUID: selectState.uidNext > 0 ? selectState.uidNext - 1 : 0,
                    lowestFetchedUID: 1,
                    backfillComplete: true
                )
                updated.lowestFetchedUID = plan.cursorAfterBatch
                updated.uidNextAtLastSelect = selectState.uidNext
                updated.existsAtLastSelect = selectState.exists
                updated.backfillComplete = true
                updated.backfillLowerBoundAt = lowerBound
                updated = await mergeWithLatestFolderProgress(updated, folder: folder)
                await folderStateStore.upsertFolderState(updated)
                await recordInitialImportWorkProgress(
                    folder: folder,
                    selectState: selectState,
                    lowerBound: lowerBound,
                    searchedUIDCount: plan.searchedUIDCount,
                    processedUIDCount: 0
                )
                return BackfillResult(
                    fetched: 0,
                    newLowestFetchedUID: plan.cursorAfterBatch,
                    backfillComplete: true
                )
            }

            let progress = try await fetchAndIngestBackfillMessages(
                using: c,
                source: plan.source,
                folder: folder,
                folderUIDValidity: selectState.uidValidity
            )

            var updated = snapshot ?? IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: folder,
                folderAttributes: [],
                uidValidity: selectState.uidValidity,
                uidNextAtLastSelect: selectState.uidNext,
                existsAtLastSelect: selectState.exists,
                highestFetchedUID: selectState.uidNext > 0 ? selectState.uidNext - 1 : 0,
                lowestFetchedUID: selectState.uidNext,
                backfillComplete: false
            )
            let proposedCursor = progress.yieldedForLiveInbound
                ? (progress.lowestIngestedUID ?? plan.cursorAfterBatch)
                : plan.cursorAfterBatch
            let initialImportCompleted = await folderStateStore.initialIMAPImportCompleted(
                accountID: accountID
            )
            let isCorpusFolder = await folderStateStore.isInitialImportCorpusFolder(
                accountID: accountID,
                folderName: folder
            )
            let cursorResolution = Self.resolvedBackfillCursor(
                proposedCursor: proposedCursor,
                previousCursor: snapshot?.lowestFetchedUID ?? selectState.uidNext,
                searchSucceeded: plan.searchedUIDCount != nil,
                initialImportCompleted: initialImportCompleted || isCorpusFolder == false,
                hasInitialWorkSnapshot: snapshot?.initialImportUIDWorkTotal != nil
            )
            updated.lowestFetchedUID = cursorResolution.cursor
            updated.uidNextAtLastSelect = selectState.uidNext
            updated.existsAtLastSelect = selectState.exists
            updated.backfillLowerBoundAt = lowerBound
            let didComplete = !progress.yieldedForLiveInbound
                && plan.completesBackfill
                && cursorResolution.mayComplete
            updated.backfillComplete = didComplete
            updated = await mergeWithLatestFolderProgress(updated, folder: folder)
            await folderStateStore.upsertFolderState(updated)
            await recordInitialImportWorkProgress(
                folder: folder,
                selectState: selectState,
                lowerBound: lowerBound,
                searchedUIDCount: plan.searchedUIDCount,
                processedUIDCount: progress.ingestedCount
            )

            return BackfillResult(
                fetched: progress.ingestedCount,
                newLowestFetchedUID: updated.lowestFetchedUID,
                backfillComplete: updated.backfillComplete
            )
        }
    }

    /// Forward-sync a non-INBOX folder without relying on IDLE (some providers
    /// don't offer IDLE on every folder). Same IDLE-suspend/resume discipline
    /// as `backfillTick`. Fetches (highestFetched+1 ... uidNext-1).
    /// Set `reportsNewInboundMessages` to false for reconciliation/gap-check
    /// passes that may import historical messages rather than live arrivals.
    public func pollFolderToCompletion(
        folder: String,
        batchSize: Int = IMAPSession.defaultPollBatchSize,
        reportsNewInboundMessages: Bool = true
    ) async throws -> PollResult {
        var fetched = 0
        var newInboundMessageIDs: [UUID] = []
        var seenMessageIDs: Set<UUID> = []
        var previousHighestUID: UInt32?

        while true {
            try Task.checkCancellation()
            let page = try await pollFolder(
                folder: folder,
                batchSize: batchSize,
                reportsNewInboundMessages: reportsNewInboundMessages
            )
            fetched += page.fetched
            for messageID in page.newInboundMessageIDs where seenMessageIDs.insert(messageID).inserted {
                newInboundMessageIDs.append(messageID)
            }
            guard page.hasMore else {
                return PollResult(
                    fetched: fetched,
                    newInboundMessageIDs: newInboundMessageIDs,
                    newHighestFetchedUID: page.newHighestFetchedUID,
                    hasMore: false
                )
            }
            guard page.newHighestFetchedUID != previousHighestUID else {
                throw IMAPError.protocolViolation(
                    "Forward poll made no progress while more messages remained."
                )
            }
            previousHighestUID = page.newHighestFetchedUID
        }
    }

    /// Checks only the newest bounded live UID tail. A dedicated in-session
    /// cursor is seeded before maintenance SELECTs and advances only after a
    /// successful live check, so deletion watches and historical backfill
    /// cannot make genuinely new mail look already checked. Unlike
    /// `pollFolderToCompletion`, this never walks an existing historical gap.
    public func pollLiveTail(folder: String) async throws -> PollResult {
        let result = try await withAuxiliaryClient(
            activityStatus: .syncing(folder: folder),
            postsCheckingMailEvent: true,
            prioritizesUserInitiatedWork: true
        ) { c, qresyncEnabled in
            let newResult = try await selectMailboxTrackingDeletions(
                folder,
                using: c,
                qresyncEnabled: qresyncEnabled,
                reconciliationMode: .liveTail
            )
            let selectState = newResult.select
            let liveTailCursor = manualLiveTailCursors[folder]
            let hasStableLiveTailCursor = liveTailCursor?.uidValidity == selectState.uidValidity

            await handleUIDValidityChangeIfNeeded(folder: folder, newState: selectState)
            let latestSnapshot = await folderStateStore.readFolderState(
                accountID: accountID,
                folderName: folder
            )

            var fetched = 0
            var newInboundMessageIDs: [UUID] = []
            if hasStableLiveTailCursor,
               let highestCheckedUID = liveTailCursor?.highestCheckedUID,
               selectState.uidNext > 1 {
                let latestUID = selectState.uidNext - 1
                if highestCheckedUID < latestUID {
                    let boundedLow = latestUID >= Self.manualLiveTailWindow
                        ? latestUID - Self.manualLiveTailWindow + 1
                        : 1
                    let firstUncheckedUID = highestCheckedUID + 1
                    let fetchResult = try await fetchAndIngestForwardMessages(
                        using: c,
                        range: max(firstUncheckedUID, boundedLow)...latestUID,
                        folder: folder,
                        folderUIDValidity: selectState.uidValidity,
                        automaticallySummarizeNewMessages: true
                    )
                    fetched = fetchResult.fetchedCount
                    newInboundMessageIDs = fetchResult.newInboundMessageIDs
                }
            }

            var updated = latestSnapshot ?? Self.makeInitialSnapshot(
                accountID: accountID,
                folderName: folder,
                selectState: selectState
            )
            updated.uidValidity = selectState.uidValidity
            updated.uidNextAtLastSelect = selectState.uidNext
            updated.existsAtLastSelect = selectState.exists
            updated = await mergeWithLatestFolderProgress(updated, folder: folder)
            await folderStateStore.upsertFolderState(updated)
            await reportNewInboundMessagesIfNeeded(
                messageIDs: newInboundMessageIDs,
                folder: folder
            )
            recordManualLiveTailProgress(
                folder: folder,
                uidValidity: selectState.uidValidity,
                highestCheckedUID: selectState.uidNext > 0 ? selectState.uidNext - 1 : 0
            )

            return PollResult(
                fetched: fetched,
                newInboundMessageIDs: newInboundMessageIDs,
                newHighestFetchedUID: updated.highestFetchedUID,
                hasMore: false
            )
        }
        await postSuccessfulPollNotification(folder: folder)
        return result
    }

    private func establishManualLiveTailCursorIfNeeded(
        folder: String,
        snapshot: IMAPFolderStateSnapshot?
    ) {
        guard manualLiveTailCursors[folder] == nil,
              let snapshot,
              snapshot.uidValidity != 0,
              snapshot.uidNextAtLastSelect > 0 else { return }
        manualLiveTailCursors[folder] = ManualLiveTailCursor(
            uidValidity: snapshot.uidValidity,
            highestCheckedUID: snapshot.uidNextAtLastSelect - 1
        )
    }

    private func recordManualLiveTailProgress(
        folder: String,
        uidValidity: UInt32,
        highestCheckedUID: UInt32
    ) {
        if let existing = manualLiveTailCursors[folder],
           existing.uidValidity == uidValidity,
           existing.highestCheckedUID >= highestCheckedUID {
            return
        }
        manualLiveTailCursors[folder] = ManualLiveTailCursor(
            uidValidity: uidValidity,
            highestCheckedUID: highestCheckedUID
        )
    }

    public func pollFolder(
        folder: String,
        batchSize: Int = IMAPSession.defaultPollBatchSize,
        reportsNewInboundMessages: Bool = true
    ) async throws -> PollResult {
        if liveLoopOwnsPrimaryConnection || client == nil {
            let result = try await pollFolderOnAuxiliaryClient(
                folder: folder,
                batchSize: batchSize,
                reportsNewInboundMessages: reportsNewInboundMessages
            )
            await postSuccessfulPollNotification(folder: folder)
            return result
        }

        guard let c = client else { throw IMAPError.notConnected }

        let wasIdling = try await suspendIdleIfNeeded(using: c)

        await transition(to: .syncing(folder: folder))
        do {
            if currentMailbox != folder {
                let newResult = try await selectMailboxTrackingDeletions(folder)
                let newState = newResult.select
                await handleUIDValidityChangeIfNeeded(folder: folder, newState: newState)
                currentMailbox = folder
                currentSelectState = newState
            }
            guard let selectState = currentSelectState else {
                throw IMAPError.notConnected
            }

            let snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: folder)
            let nextRange = Self.nextPollRange(
                snapshot: snapshot,
                selectState: selectState,
                batchSize: batchSize
            )
            if nextRange.skip {
                var updated = snapshot ?? Self.makeInitialSnapshot(
                    accountID: accountID,
                    folderName: folder,
                    selectState: selectState
                )
                updated.uidValidity = selectState.uidValidity
                updated.uidNextAtLastSelect = selectState.uidNext
                updated.existsAtLastSelect = selectState.exists
                await folderStateStore.upsertFolderState(updated)
                let result = PollResult(
                    fetched: 0,
                    newInboundMessageIDs: [],
                    newHighestFetchedUID: updated.highestFetchedUID,
                    hasMore: false
                )
                try await drainLiveInboxAndResumeIdleIfNeeded(wasIdling: wasIdling)
                await postSuccessfulPollNotification(folder: folder)
                return result
            }

            let automaticallySummarizeNewMessages = reportsNewInboundMessages && !nextRange.isInitialAnchor
            let fetchResult = try await fetchAndIngestForwardMessages(
                using: c,
                range: nextRange.low...nextRange.high,
                folder: folder,
                folderUIDValidity: selectState.uidValidity,
                automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
            )
            var updated = snapshot ?? Self.makeInitialSnapshot(
                accountID: accountID,
                folderName: folder,
                selectState: selectState
            )
            updated.uidValidity = selectState.uidValidity
            updated.highestFetchedUID = nextRange.high
            if (snapshot?.lowestFetchedUID ?? 0) == 0 {
                updated.lowestFetchedUID = nextRange.low
                updated.backfillComplete = nextRange.low == 1
            }
            updated.uidNextAtLastSelect = selectState.uidNext
            updated.existsAtLastSelect = selectState.exists
            await folderStateStore.upsertFolderState(updated)

            let maxUID = selectState.uidNext > 1 ? selectState.uidNext - 1 : 0
            let result = PollResult(
                fetched: fetchResult.fetchedCount,
                newInboundMessageIDs: fetchResult.newInboundMessageIDs,
                newHighestFetchedUID: updated.highestFetchedUID,
                hasMore: updated.highestFetchedUID < maxUID
            )
            if reportsNewInboundMessages {
                await reportNewInboundMessagesIfNeeded(
                    messageIDs: fetchResult.newInboundMessageIDs,
                    folder: folder
                )
            }
            try await drainLiveInboxAndResumeIdleIfNeeded(wasIdling: wasIdling)
            await postSuccessfulPollNotification(folder: folder)
            return result
        } catch {
            if wasIdling {
                try? await resumeIdleOnINBOX()
            }
            throw error
        }
    }

    private func pollFolderOnAuxiliaryClient(
        folder: String,
        batchSize: Int,
        reportsNewInboundMessages: Bool
    ) async throws -> PollResult {
        try await withAuxiliaryClient(
            activityStatus: .syncing(folder: folder),
            postsCheckingMailEvent: true
        ) { c, qresyncEnabled in
            let newResult = try await selectMailboxTrackingDeletions(
                folder,
                using: c,
                qresyncEnabled: qresyncEnabled
            )
            let selectState = newResult.select
            await handleUIDValidityChangeIfNeeded(folder: folder, newState: selectState)

            let snapshot = await folderStateStore.readFolderState(accountID: accountID, folderName: folder)
            let nextRange = Self.nextPollRange(
                snapshot: snapshot,
                selectState: selectState,
                batchSize: batchSize
            )
            if nextRange.skip {
                var updated = snapshot ?? Self.makeInitialSnapshot(
                    accountID: accountID,
                    folderName: folder,
                    selectState: selectState
                )
                updated.uidValidity = selectState.uidValidity
                updated.uidNextAtLastSelect = selectState.uidNext
                updated.existsAtLastSelect = selectState.exists
                await folderStateStore.upsertFolderState(updated)
                return PollResult(
                    fetched: 0,
                    newInboundMessageIDs: [],
                    newHighestFetchedUID: updated.highestFetchedUID,
                    hasMore: false
                )
            }

            let automaticallySummarizeNewMessages = reportsNewInboundMessages && !nextRange.isInitialAnchor
            let fetchResult = try await fetchAndIngestForwardMessages(
                using: c,
                range: nextRange.low...nextRange.high,
                folder: folder,
                folderUIDValidity: selectState.uidValidity,
                automaticallySummarizeNewMessages: automaticallySummarizeNewMessages
            )
            var updated = snapshot ?? Self.makeInitialSnapshot(
                accountID: accountID,
                folderName: folder,
                selectState: selectState
            )
            updated.uidValidity = selectState.uidValidity
            updated.highestFetchedUID = nextRange.high
            if (snapshot?.lowestFetchedUID ?? 0) == 0 {
                updated.lowestFetchedUID = nextRange.low
                updated.backfillComplete = nextRange.low == 1
            }
            updated.uidNextAtLastSelect = selectState.uidNext
            updated.existsAtLastSelect = selectState.exists
            await folderStateStore.upsertFolderState(updated)

            let maxUID = selectState.uidNext > 1 ? selectState.uidNext - 1 : 0
            if reportsNewInboundMessages {
                await reportNewInboundMessagesIfNeeded(
                    messageIDs: fetchResult.newInboundMessageIDs,
                    folder: folder
                )
            }
            return PollResult(
                fetched: fetchResult.fetchedCount,
                newInboundMessageIDs: fetchResult.newInboundMessageIDs,
                newHighestFetchedUID: updated.highestFetchedUID,
                hasMore: updated.highestFetchedUID < maxUID
            )
        }
    }

    /// Lightweight SELECT-only deletion-watch tick.
    ///
    /// Runs SELECT (or QRESYNC SELECT) against the named folder using the
    /// auxiliary client pool, picks up any QRESYNC `VANISHED` set / modseq
    /// movement, and emits an `IMAPDeletionEvent` via the standard status
    /// reporter chain. The existing `DeletionSyncCoordinator.handle` cascade
    /// fires for each event identically to the live-poll path — including
    /// posting `.ohiaDeletionApplied` for the constellation's black-hole
    /// animation.
    ///
    /// This path may run alongside the live body-fetching session. It
    /// intentionally:
    ///   - Does NOT body-fetch any messages.
    ///   - Does NOT advance `highestFetchedUID` / `lowestFetchedUID`.
    ///   - DOES record `existsAtLastSelect` via the standard SELECT path so
    ///     server-mailbox-size diagnostics stay current.
    ///   - Leaves `lastDeletionWatchAt` for `IMAPDeletionWatchWorker` to
    ///     stamp after the tick finishes, so the seeder can pace the cadence.
    ///
    public func runDeletionWatchTick(folder: String) async throws {
        let beforeSnapshot = await folderStateStore.readFolderState(
            accountID: accountID,
            folderName: folder
        )

        try await withAuxiliaryClient { c, qresyncEnabled in
            let result = try await selectMailboxTrackingDeletions(
                folder,
                using: c,
                qresyncEnabled: qresyncEnabled,
                reconciliationMode: .deletionWatch
            )
            await handleUIDValidityChangeIfNeeded(folder: folder, newState: result.select)

            // Persist `highestModSeq` / `uidValidity` / `existsAtLastSelect`
            // movement so the next deletion-watch tick can detect further
            // changes. Critically, do NOT touch `highestFetchedUID` or
            // `lowestFetchedUID` — those are owned by the historical-fetch
            // path and must not be advanced by deletion reconciliation.
            var updated = beforeSnapshot ?? IMAPFolderStateSnapshot(
                accountID: accountID,
                folderName: folder,
                folderAttributes: [],
                uidValidity: result.select.uidValidity,
                uidNextAtLastSelect: result.select.uidNext,
                existsAtLastSelect: result.select.exists,
                highestFetchedUID: 0,
                lowestFetchedUID: 0,
                backfillComplete: false
            )
            updated.uidValidity = result.select.uidValidity
            updated.uidNextAtLastSelect = result.select.uidNext
            updated.existsAtLastSelect = result.select.exists
            if let highestModSeqAfter = result.highestModSeq {
                updated.highestModSeq = highestModSeqAfter
            }
            await folderStateStore.upsertFolderState(updated)
        }
    }

    /// Set or clear `\Seen` on a single message. Borrows the auxiliary
    /// IMAP client so a live IDLE on the primary connection isn't
    /// disturbed. The aux client is kept warm between calls — repeated
    /// `markSeen` invocations across the same folder pay one SELECT each
    /// (the fastest the protocol allows) but reuse the TLS+AUTH state.
    public func markSeen(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        value: Bool
    ) async throws {
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            try Self.verifyUIDValidity(
                expectedUIDValidity,
                actual: result.select.uidValidity,
                folder: folder
            )
            try await c.uidStore(
                uid: uid,
                op: value ? .add : .remove,
                flags: ["\\Seen"]
            )
        }
    }

    /// Set or clear `\Flagged` on a single message. Same auxiliary-
    /// client borrow as `markSeen` so the primary IDLE connection stays
    /// undisturbed and the TLS+AUTH state is reused across repeated
    /// flag toggles in the same folder.
    public func markFlagged(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        value: Bool
    ) async throws {
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            try Self.verifyUIDValidity(
                expectedUIDValidity,
                actual: result.select.uidValidity,
                folder: folder
            )
            try await c.uidStore(
                uid: uid,
                op: value ? .add : .remove,
                flags: ["\\Flagged"]
            )
        }
    }

    /// Destructive delete of a single message. Sets `\Deleted` then
    /// EXPUNGEs — using `UID EXPUNGE` (RFC 4315) when the server
    /// advertises UIDPLUS so other `\Deleted` messages in the folder
    /// remain untouched, falling back to plain `EXPUNGE` otherwise.
    public func deleteMessage(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        messageIDHeader: String? = nil
    ) async throws {
        let normalizedMessageID = try Self.validatedMessageID(messageIDHeader)
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            if normalizedMessageID == nil {
                try Self.verifyUIDValidity(
                    expectedUIDValidity,
                    actual: result.select.uidValidity,
                    folder: folder
                )
                let existingUIDs = try await c.uidSearch(range: uid...uid)
                guard existingUIDs.contains(uid) else {
                    throw IMAPError.protocolViolation(
                        "UID \(uid) does not exist in \(folder); refusing unverified permanent delete"
                    )
                }
                try await c.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
                let caps = try await c.capability()
                if caps.uidPlus {
                    try await c.uidExpunge(uid: uid)
                } else {
                    try await c.expunge()
                }
                _ = try await c.selectWithMetadata(mailbox: folder)
                let remainingUIDs = try await c.uidSearch(range: uid...uid)
                guard remainingUIDs.contains(uid) == false else {
                    throw IMAPError.protocolViolation(
                        "permanent delete was acknowledged but UID \(uid) remains in \(folder)"
                    )
                }
                return
            }

            guard let normalizedMessageID else { return }
            let targetUIDs = try await c.uidSearchHeader("Message-ID", value: normalizedMessageID)
            // Absence is an idempotent success: the provider copy no longer
            // exists in the requested source mailbox.
            guard targetUIDs.isEmpty == false else { return }

            let caps = try await c.capability()
            for targetUID in Set(targetUIDs).sorted() {
                try await c.uidStore(uid: targetUID, op: .add, flags: ["\\Deleted"])
                if caps.uidPlus {
                    try await c.uidExpunge(uid: targetUID)
                }
            }
            if caps.uidPlus == false {
                try await c.expunge()
            }

            _ = try await c.selectWithMetadata(mailbox: folder)
            let remaining = try await c.uidSearchHeader("Message-ID", value: normalizedMessageID)
            guard remaining.isEmpty else {
                throw IMAPError.protocolViolation(
                    "permanent delete was acknowledged but Message-ID \(normalizedMessageID) remains in \(folder)"
                )
            }
        }
    }

    /// Permanently delete a bounded batch of messages in the account's Junk or
    /// Trash folder whose INTERNALDATE is older than `cutoff`.
    ///
    /// The folder is resolved from SPECIAL-USE first, then common leaf names.
    /// Missing folders are treated as an empty result so accounts with only one
    /// withheld folder do not fail the whole scheduled cleanup pass.
    public func deleteWithheldMessagesOlderThan(
        role: WithheldFolderRole,
        cutoff: Date,
        maxPerFolder: Int
    ) async throws -> WithheldAutoDeleteResult {
        guard maxPerFolder > 0 else {
            return WithheldAutoDeleteResult(
                role: role,
                folderName: nil,
                matchedCount: 0,
                deletedCount: 0,
                folderFound: false
            )
        }

        return try await withAuxiliaryClient { c, _ in
            let folders = try await c.list()
            guard let folder = WithheldFolderResolver.resolve(role: role, in: folders) else {
                return WithheldAutoDeleteResult(
                    role: role,
                    folderName: nil,
                    matchedCount: 0,
                    deletedCount: 0,
                    folderFound: false
                )
            }

            _ = try await c.selectWithMetadata(mailbox: folder.name)
            let searchedUIDs = try await c.uidSearch(before: cutoff)
            let matchedUIDs = searchedUIDs.sorted()
            let targetUIDs = Array(matchedUIDs.prefix(maxPerFolder))
            guard !targetUIDs.isEmpty else {
                return WithheldAutoDeleteResult(
                    role: role,
                    folderName: folder.name,
                    matchedCount: matchedUIDs.count,
                    deletedCount: 0,
                    folderFound: true
                )
            }

            let caps = try await c.capability()
            guard caps.uidPlus else {
                throw IMAPError.protocolViolation(
                    "Automatic Junk/Trash cleanup requires UIDPLUS so expunge can stay UID-scoped."
                )
            }
            for uid in targetUIDs {
                try await c.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
                try await c.uidExpunge(uid: uid)
            }

            return WithheldAutoDeleteResult(
                role: role,
                folderName: folder.name,
                matchedCount: matchedUIDs.count,
                deletedCount: targetUIDs.count,
                folderFound: true
            )
        }
    }

    /// Move a single message to an arbitrary destination folder. Uses RFC 6851
    /// `UID MOVE` when available; otherwise copies to the destination and removes
    /// only the copied source UID when UIDPLUS gives us `UID EXPUNGE`. Without
    /// UIDPLUS, a plain `EXPUNGE` would affect every `\Deleted` message in the
    /// selected folder, so the fallback leaves the source merely marked deleted.
    public func moveMessage(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        to destination: String
    ) async throws {
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            try Self.verifyUIDValidity(
                expectedUIDValidity,
                actual: result.select.uidValidity,
                folder: folder
            )
            try await Self.moveSelectedMessage(
                using: c,
                uid: uid,
                to: destination
            )
        }
    }

    /// Restore a retained message after its provider Trash move completed.
    /// Stable Message-ID is the only safe identity because the retained local
    /// row still carries its pre-Trash UID, not the provider's Trash UID.
    public func restoreMessageFromTrash(messageIDHeader: String) async throws {
        guard let providerMessageID = canonicalProviderMessageID(messageIDHeader) else {
            throw IMAPError.protocolViolation(
                "Trash restore requires a safe RFC Message-ID"
            )
        }

        if imapAuthMethod == .oauth2, Self.isGmailHost(imapHost) {
            let token = try await credentialsResolver.oauthAccessTokenForAccount(
                accountID,
                provider: .gmail
            )
            do {
                try await gmailMessageTrasher.restoreMessagesFromTrash(
                    matchingMessageID: providerMessageID,
                    accessToken: token
                )
            } catch GmailMessageAPIError.requestFailed(let statusCode)
                        where statusCode == 401 {
                throw IMAPError.reauthRequired(
                    serverText: "Gmail restore API authorization failed with HTTP \(statusCode)."
                )
            } catch GmailMessageAPIError.requestFailed(let statusCode)
                        where statusCode >= 500 || statusCode == 429 || statusCode == 403 {
                throw IMAPError.serverTemporary(
                    "Gmail restore API failed with HTTP \(statusCode)."
                )
            }
            return
        }

        try await withAuxiliaryClient(lane: .mutation) { client, _ in
            let folders = try await client.list()
            guard let trash = WithheldFolderResolver.resolve(role: .trash, in: folders) else {
                throw IMAPError.protocolViolation("No Trash mailbox advertised by server")
            }
            _ = try await client.selectWithMetadata(mailbox: trash.name)
            try await Self.moveSelectedMessagesAndVerify(
                using: client,
                source: trash.name,
                destination: "INBOX",
                messageIDHeader: providerMessageID
            )
        }
    }

    /// Move a single message into the account Trash folder.
    ///
    /// If no cached destination is provided, resolves the server Trash mailbox
    /// from a live LIST response. If the server truly advertises none, creates
    /// a conventional `Trash` mailbox and moves the message there.
    public func moveMessageToTrash(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        trashFolder: String? = nil,
        messageIDHeader: String? = nil
    ) async throws {
        let normalizedMessageID = try Self.validatedMessageID(messageIDHeader)
        if imapAuthMethod == .oauth2, Self.isGmailHost(imapHost) {
            guard let providerMessageID = canonicalProviderMessageID(normalizedMessageID) else {
                throw IMAPError.protocolViolation(
                    "OAuth Gmail Trash requires an RFC Message-ID; refusing an unverified IMAP label move"
                )
            }
            let token = try await credentialsResolver.oauthAccessTokenForAccount(
                accountID,
                provider: .gmail
            )
            do {
                try await gmailMessageTrasher.moveMessagesToTrash(
                    matchingMessageID: providerMessageID,
                    accessToken: token
                )
            } catch GmailMessageAPIError.requestFailed(let statusCode) where statusCode == 401 || statusCode == 403 {
                throw IMAPError.reauthRequired(
                    serverText: "Gmail Trash API authorization failed with HTTP \(statusCode)."
                )
            } catch GmailMessageAPIError.requestFailed(let statusCode) where statusCode >= 500 || statusCode == 429 {
                throw IMAPError.serverTemporary("Gmail Trash API failed with HTTP \(statusCode).")
            }
            return
        }

        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            if normalizedMessageID == nil {
                try Self.verifyUIDValidity(
                    expectedUIDValidity,
                    actual: result.select.uidValidity,
                    folder: folder
                )
            }
            let destination = try await Self.resolveTrashDestination(
                preferredTrashFolder: trashFolder,
                using: c
            )
            if let normalizedMessageID {
                try await Self.moveSelectedMessagesAndVerify(
                    using: c,
                    source: folder,
                    destination: destination,
                    messageIDHeader: normalizedMessageID
                )
            } else {
                try await Self.moveSelectedUIDAndVerify(
                    using: c,
                    source: folder,
                    destination: destination,
                    uid: uid,
                )
            }
        }
    }

    /// Move a single message into the account Junk / Spam folder.
    ///
    /// Resolves and validates the server Junk mailbox from a live LIST response.
    /// Unlike Trash, this neither trusts a conventional folder name nor
    /// fabricates a fallback mailbox: without a server-advertised `\Junk`
    /// destination the command would only move mail, not mark it as spam.
    public func moveMessageToJunk(
        folder: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        junkFolder: String? = nil,
        messageIDHeader: String? = nil,
        acceptAlreadyAbsentSourceUID: Bool = false
    ) async throws {
        let validatedMessageID = try Self.validatedMessageID(messageIDHeader)
        let normalizedMessageID = canonicalProviderMessageID(validatedMessageID)
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let result = try await c.selectWithMetadata(mailbox: folder)
            if normalizedMessageID == nil {
                try Self.verifyUIDValidity(
                    expectedUIDValidity,
                    actual: result.select.uidValidity,
                    folder: folder
                )
            }
            let destination = try await Self.resolveJunkDestination(
                preferredJunkFolder: junkFolder,
                using: c
            )
            guard destination.caseInsensitiveCompare(folder) != .orderedSame else {
                if let normalizedMessageID {
                    let existingUIDs = try await c.uidSearchHeader(
                        "Message-ID",
                        value: normalizedMessageID
                    )
                    guard existingUIDs.isEmpty == false else {
                        throw IMAPError.protocolViolation(
                            "Message-ID \(normalizedMessageID) is absent from Junk mailbox \(folder)"
                        )
                    }
                } else {
                    let existingUIDs = try await c.uidSearch(range: uid...uid)
                    guard existingUIDs.contains(uid) else {
                        throw IMAPError.protocolViolation(
                            "UID \(uid) is absent from Junk mailbox \(folder)"
                        )
                    }
                }
                return
            }
            if let normalizedMessageID {
                try await Self.moveSelectedMessagesAndVerify(
                    using: c,
                    source: folder,
                    destination: destination,
                    messageIDHeader: normalizedMessageID
                )
            } else {
                try await Self.moveSelectedUIDAndVerify(
                    using: c,
                    source: folder,
                    destination: destination,
                    uid: uid,
                    acceptAlreadyAbsentSourceUID: acceptAlreadyAbsentSourceUID
                )
            }
        }
    }

    private static func moveSelectedMessage(
        using c: any IMAPClienting,
        uid: UInt32,
        to destination: String
    ) async throws {
        let caps = try await c.capability()
        try await moveSelectedMessage(
            using: c,
            uid: uid,
            to: destination,
            capabilities: caps
        )
    }

    private static func moveSelectedMessage(
        using c: any IMAPClienting,
        uid: UInt32,
        to destination: String,
        capabilities caps: IMAPCapability
    ) async throws {
        if caps.move {
            try await c.uidMove(uid: uid, mailbox: destination)
            return
        }

        try await c.uidCopy(uid: uid, mailbox: destination)
        try await c.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
        if caps.uidPlus {
            try await c.uidExpunge(uid: uid)
        }
    }

    /// Move every source copy sharing the immutable RFC Message-ID and prove
    /// the postcondition. This closes the IMAP rule where a stale UID can yield
    /// `OK` while affecting zero messages.
    private static func moveSelectedMessagesAndVerify(
        using c: any IMAPClienting,
        source: String,
        destination: String,
        messageIDHeader: String
    ) async throws {
        let sourceUIDs = try await c.uidSearchHeader("Message-ID", value: messageIDHeader)
        if sourceUIDs.isEmpty {
            _ = try await c.selectWithMetadata(mailbox: destination)
            let existingDestinationUIDs = try await c.uidSearchHeader(
                "Message-ID",
                value: messageIDHeader
            )
            guard existingDestinationUIDs.isEmpty == false else {
                throw IMAPError.protocolViolation(
                    "Message-ID \(messageIDHeader) was found in neither \(source) nor \(destination)"
                )
            }
            return
        }

        let caps = try await c.capability()
        guard caps.move || caps.uidPlus else {
            throw IMAPError.protocolViolation(
                "verified mailbox moves require MOVE or UIDPLUS"
            )
        }
        for sourceUID in Set(sourceUIDs).sorted() {
            try await moveSelectedMessage(
                using: c,
                uid: sourceUID,
                to: destination,
                capabilities: caps
            )
        }

        _ = try await c.selectWithMetadata(mailbox: source)
        let remainingSourceUIDs = try await c.uidSearchHeader("Message-ID", value: messageIDHeader)
        guard remainingSourceUIDs.isEmpty else {
            throw IMAPError.protocolViolation(
                "move was acknowledged but Message-ID \(messageIDHeader) remains in \(source)"
            )
        }

        _ = try await c.selectWithMetadata(mailbox: destination)
        let destinationUIDs = try await c.uidSearchHeader("Message-ID", value: messageIDHeader)
        guard destinationUIDs.isEmpty == false else {
            throw IMAPError.protocolViolation(
                "move was acknowledged but Message-ID \(messageIDHeader) is absent from \(destination)"
            )
        }
    }

    /// Legacy and RFC-valid Message-ID-less mail still needs a provable
    /// operation. Establish that the UID exists before mutation and is absent
    /// from the same UIDVALIDITY generation afterward. A server `OK` without
    /// either observation is not success.
    private static func moveSelectedUIDAndVerify(
        using c: any IMAPClienting,
        source: String,
        destination: String,
        uid: UInt32,
        acceptAlreadyAbsentSourceUID: Bool = false
    ) async throws {
        let existingUIDs = try await c.uidSearch(range: uid...uid)
        if existingUIDs.contains(uid) == false,
           acceptAlreadyAbsentSourceUID {
            // A prior exact-UID MOVE may have committed before its response or
            // postcondition read reached Ohia. Source absence is the only
            // identity-safe retry postcondition available for Message-ID-less
            // mail because the destination assigns a new UID.
            return
        }
        guard existingUIDs.contains(uid) else {
            throw IMAPError.protocolViolation(
                "UID \(uid) does not exist in \(source); refusing unverified mailbox move"
            )
        }

        let caps = try await c.capability()
        guard caps.move || caps.uidPlus else {
            throw IMAPError.protocolViolation(
                "verified mailbox moves require MOVE or UIDPLUS"
            )
        }
        try await moveSelectedMessage(
            using: c,
            uid: uid,
            to: destination,
            capabilities: caps
        )

        _ = try await c.selectWithMetadata(mailbox: source)
        let remainingUIDs = try await c.uidSearch(range: uid...uid)
        guard remainingUIDs.contains(uid) == false else {
            throw IMAPError.protocolViolation(
                "move was acknowledged but UID \(uid) remains in \(source)"
            )
        }
    }

    private static func validatedMessageID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.unicodeScalars.contains(where: {
            $0.value == 0x00 || $0.value == 0x0D || $0.value == 0x0A
        }) else {
            throw IMAPError.protocolViolation("Message-ID contains an unsafe control character")
        }
        return trimmed
    }

    private static func resolveTrashDestination(
        preferredTrashFolder: String?,
        using c: any IMAPClienting
    ) async throws -> String {
        if let preferred = preferredTrashFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            return preferred
        }

        let folders = try await c.list()
        if let resolved = WithheldFolderResolver.resolve(role: .trash, in: folders) {
            return resolved.name
        }

        do {
            try await c.createMailbox(fallbackTrashMailboxName)
        } catch {
            let refreshedFolders = try await c.list()
            if let resolved = WithheldFolderResolver.resolve(role: .trash, in: refreshedFolders) {
                return resolved.name
            }
            throw error
        }
        return fallbackTrashMailboxName
    }

    private static func resolveJunkDestination(
        preferredJunkFolder: String?,
        using c: any IMAPClienting
    ) async throws -> String {
        let folders = try await c.list()
        let advertisedJunkFolders = folders.filter { !$0.isNoselect && $0.isJunk }
        if let preferred = preferredJunkFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           let validated = advertisedJunkFolders.first(where: {
               $0.name.caseInsensitiveCompare(preferred) == .orderedSame
           }) {
            return validated.name
        }
        if let advertised = advertisedJunkFolders.first {
            return advertised.name
        }

        throw IMAPError.protocolViolation("No \\Junk mailbox advertised by server")
    }

    private static func verifyUIDValidity(
        _ expected: UInt32?,
        actual: UInt32,
        folder: String
    ) throws {
        guard let expected, expected != 0, actual != expected else { return }
        throw IMAPError.protocolViolation(
            "UIDVALIDITY changed for \(folder): expected \(expected), got \(actual)"
        )
    }

    public func saveDraft(
        preferredFolder: String?,
        previousFolder: String?,
        previousUID: UInt32?,
        previousUIDValidity: UInt32?,
        messageIDHeader: String,
        payload: Data,
        date: Date?
    ) async throws -> IMAPDraftRemoteLocation {
        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            let folder = try await resolveDraftsFolder(using: c, preferredFolder: preferredFolder)

            let appendResult = try await c.append(
                mailbox: folder,
                flags: ["\\Draft"],
                date: date,
                payload: payload
            )

            var uid = appendResult.uids.first
            var uidValidity = appendResult.uidValidity
            if uid == nil {
                let selected = try await c.selectWithMetadata(mailbox: folder)
                uidValidity = selected.select.uidValidity
                uid = try await c.uidSearchHeader("Message-ID", value: messageIDHeader).max()
            }

            var cleanupErrorDescription: String?
            if let previousFolder,
               !previousFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    if let previousUID, previousUID > 0 {
                        try await deleteDraftCopies(
                            using: c,
                            folder: previousFolder,
                            uid: previousUID,
                            uidValidity: previousUIDValidity,
                            messageIDHeader: messageIDHeader,
                            excludingUIDs: previousFolder == folder ? Set([uid].compactMap { $0 }) : []
                        )
                    } else if previousFolder != folder || uid != nil {
                        try await deleteDraftCopies(
                            using: c,
                            folder: previousFolder,
                            messageIDHeader: messageIDHeader,
                            excludingUIDs: previousFolder == folder ? Set([uid].compactMap { $0 }) : []
                        )
                    }
                } catch {
                    cleanupErrorDescription = String(describing: error)
                }
            }

            return IMAPDraftRemoteLocation(
                folder: folder,
                uid: uid,
                uidValidity: uidValidity,
                messageIDHeader: messageIDHeader,
                cleanupErrorDescription: cleanupErrorDescription
            )
        }
    }

    public func deleteDraft(
        folder: String,
        uid: UInt32?,
        uidValidity: UInt32?,
        messageIDHeader: String?
    ) async throws {
        let normalizedMessageID = try Self.validatedMessageID(messageIDHeader)
        // Gmail's IMAP endpoint can reject moving messages out of Drafts, and
        // deleting them in place can merely remove the mailbox label while the
        // draft survives in All Mail. OAuth-backed Gmail accounts already carry
        // the broad mail scope, so use Gmail's definitive drafts.delete API for
        // terminal Composer cleanup. A thrown API error leaves the local cleanup
        // tombstone intact for retry instead of falsely reporting success.
        if imapAuthMethod == .oauth2,
           Self.isGmailHost(imapHost),
           let normalizedMessageID {
            let token = try await credentialsResolver.oauthAccessTokenForAccount(
                accountID,
                provider: .gmail
            )
            try await gmailDraftDeleter.deleteDrafts(
                matchingMessageID: normalizedMessageID,
                accessToken: token
            )
            return
        }

        try await withAuxiliaryClient(lane: .mutation) { c, _ in
            try await deleteDraftCopies(
                using: c,
                folder: folder,
                uid: uid,
                uidValidity: uidValidity,
                messageIDHeader: normalizedMessageID,
                requireIdentifiedTarget: true
            )
        }
    }

    private static func isGmailHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized.contains("gmail") || normalized.contains("google")
    }

    private func resolveDraftsFolder(
        using client: any IMAPClienting,
        preferredFolder: String?
    ) async throws -> String {
        if let preferredFolder,
           !preferredFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferredFolder
        }
        let folders = try await client.list()
        guard let folder = DraftsFolderResolver.resolve(folders: folders) else {
            throw IMAPError.protocolViolation("no IMAP Drafts folder detected")
        }
        return folder
    }

    private func deleteDraftCopies(
        using client: any IMAPClienting,
        folder: String,
        uid: UInt32?,
        uidValidity: UInt32?,
        messageIDHeader: String?,
        excludingUIDs: Set<UInt32> = [],
        requireIdentifiedTarget: Bool = false
    ) async throws {
        let selected = try await client.selectWithMetadata(mailbox: folder)
        // Gather every copy of this draft in the folder: the tracked UID (when
        // still valid) PLUS every message sharing its unique Message-ID, so
        // accumulated duplicates are all cleaned — not just the last UID we
        // uploaded. (Servers can leave prior draft versions behind.)
        var targetUIDs = Set<UInt32>()
        var verifiedUIDWithoutMessageID: UInt32?
        var trackedUIDConfirmedAbsent = false
        if let uid, uid > 0, let uidValidity, uidValidity > 0, uidValidity == selected.select.uidValidity {
            if requireIdentifiedTarget {
                let existingUIDs = try await client.uidSearch(range: uid...uid)
                if existingUIDs.contains(uid) {
                    targetUIDs.insert(uid)
                    verifiedUIDWithoutMessageID = uid
                } else {
                    trackedUIDConfirmedAbsent = true
                }
            } else {
                targetUIDs.insert(uid)
            }
        }
        let trimmedMessageID = try Self.validatedMessageID(messageIDHeader)
        if let trimmedMessageID, !trimmedMessageID.isEmpty {
            targetUIDs.formUnion(try await client.uidSearchHeader("Message-ID", value: trimmedMessageID))
        } else if requireIdentifiedTarget, verifiedUIDWithoutMessageID == nil {
            // Within the same UIDVALIDITY generation, a missing UID proves
            // this exact IMAP message is already gone. Gmail is different:
            // removing its Drafts label can leave the provider draft alive.
            // Without a Message-ID we cannot verify that provider identity.
            if trackedUIDConfirmedAbsent, !Self.isGmailHost(imapHost) { return }
            throw IMAPError.protocolViolation(
                "draft cleanup has neither a valid Message-ID nor an extant UID in the current UIDVALIDITY generation"
            )
        }
        try await deleteSelectedDraftCopies(
            using: client,
            uids: Array(targetUIDs),
            messageIDHeader: trimmedMessageID,
            excludingUIDs: excludingUIDs
        )

        guard requireIdentifiedTarget else { return }

        _ = try await client.selectWithMetadata(mailbox: folder)
        if let trimmedMessageID {
            let remainingUIDs = Set(
                try await client.uidSearchHeader("Message-ID", value: trimmedMessageID)
            ).subtracting(excludingUIDs)
            guard remainingUIDs.isEmpty else {
                throw IMAPError.protocolViolation(
                    "draft delete was acknowledged but Message-ID \(trimmedMessageID) remains in \(folder)"
                )
            }
        } else if let verifiedUIDWithoutMessageID {
            let remainingUIDs = try await client.uidSearch(
                range: verifiedUIDWithoutMessageID...verifiedUIDWithoutMessageID
            )
            guard remainingUIDs.contains(verifiedUIDWithoutMessageID) == false else {
                throw IMAPError.protocolViolation(
                    "draft delete was acknowledged but UID \(verifiedUIDWithoutMessageID) remains in \(folder)"
                )
            }
        }
    }

    private func deleteDraftCopies(
        using client: any IMAPClienting,
        folder: String,
        messageIDHeader: String,
        excludingUIDs: Set<UInt32> = []
    ) async throws {
        let trimmedMessageID = messageIDHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageID.isEmpty else { return }
        _ = try await client.selectWithMetadata(mailbox: folder)
        let uids = try await client.uidSearchHeader("Message-ID", value: trimmedMessageID)
        try await deleteSelectedDraftCopies(
            using: client,
            uids: uids,
            messageIDHeader: trimmedMessageID,
            excludingUIDs: excludingUIDs
        )
    }

    /// Removes the given draft copies from the currently-selected Drafts folder.
    ///
    /// Standard IMAP: mark `\Deleted` + EXPUNGE, which removes the messages
    /// outright. Gmail (`X-GM-EXT-1`) treats folders as labels, so `\Deleted` +
    /// EXPUNGE in the Drafts folder only *unlabels* the draft — it survives in
    /// "All Mail" and keeps showing in other clients. For Gmail we instead MOVE
    /// each copy to Trash (which strips every other label, including All Mail),
    /// then permanently EXPUNGE it from Trash so the draft is fully removed from
    /// the account (matching Gmail's own "Discard draft"). The moved copies are
    /// relocated in Trash by the draft's unique Message-ID, since `uidMove` does
    /// not hand back the new Trash UIDs.
    private func deleteSelectedDraftCopies(
        using client: any IMAPClienting,
        uids: [UInt32],
        messageIDHeader: String?,
        excludingUIDs: Set<UInt32> = []
    ) async throws {
        let targetUIDs = Set(uids).subtracting(excludingUIDs).filter { $0 > 0 }
        guard !targetUIDs.isEmpty else { return }
        let caps = try await client.capability()

        guard caps.xGmExt1 else {
            for uid in targetUIDs {
                try await client.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
                if caps.uidPlus {
                    try await client.uidExpunge(uid: uid)
                }
            }
            if !caps.uidPlus {
                try await client.expunge()
            }
            return
        }

        // Gmail: prefer moving each copy out of Drafts (and All Mail) into
        // Trash. Some Gmail accounts reject UID MOVE from Drafts even though
        // they advertise MOVE. Fall back to the equivalent COPY-to-Trash plus
        // source deletion sequence rather than deleting in place, which can
        // merely remove the Drafts label and leave the draft visible elsewhere.
        let trash = try await Self.resolveTrashDestination(preferredTrashFolder: nil, using: client)
        var movedToTrash = false
        for uid in targetUIDs.sorted() {
            do {
                try await Self.moveSelectedMessage(using: client, uid: uid, to: trash)
                movedToTrash = true
            } catch {
                guard Self.isGmailDraftMoveUnsupported(error) else { throw error }
                try await client.uidCopy(uid: uid, mailbox: trash)
                try await Self.deleteSelectedMessageInPlace(using: client, uid: uid, caps: caps)
                movedToTrash = true
            }
        }
        // Permanently purge the moved copies from Trash (Gmail otherwise keeps
        // trashed items ~30 days). Without a Message-ID we cannot relocate them,
        // but they have already left Drafts and All Mail and will auto-purge.
        guard movedToTrash else { return }
        guard let messageID = messageIDHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !messageID.isEmpty else { return }
        _ = try await client.selectWithMetadata(mailbox: trash)
        let trashUIDs = try await client.uidSearchHeader("Message-ID", value: messageID)
        for uid in trashUIDs.sorted() where uid > 0 {
            try await client.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
            try await client.uidExpunge(uid: uid)
        }
    }

    private static func deleteSelectedMessageInPlace(
        using client: any IMAPClienting,
        uid: UInt32,
        caps: IMAPCapability
    ) async throws {
        try await client.uidStore(uid: uid, op: .add, flags: ["\\Deleted"])
        if caps.uidPlus {
            try await client.uidExpunge(uid: uid)
        } else {
            try await client.expunge()
        }
    }

    private static func isGmailDraftMoveUnsupported(_ error: Error) -> Bool {
        guard case IMAPError.protocolViolation(let message) = error else {
            return false
        }
        let lowercased = message.lowercased()
        return lowercased.contains("cannot move messages out of the drafts folder")
            || lowercased.contains("cannot move messages out of drafts")
    }

    internal static func nextPollRange(
        snapshot: IMAPFolderStateSnapshot?,
        selectState: IMAPSelectState,
        batchSize: Int
    ) -> (low: UInt32, high: UInt32, skip: Bool, isInitialAnchor: Bool) {
        guard selectState.uidNext > 1 else {
            return (0, 0, true, false)
        }

        let maxUID = selectState.uidNext - 1
        let batchU = UInt32(max(1, batchSize))
        let hasDisconnectedCursor = snapshot.map {
            $0.lowestFetchedUID > $0.highestFetchedUID
                && $0.lowestFetchedUID - $0.highestFetchedUID > 1
        } ?? false
        let isInitialAnchor = snapshot == nil
            || snapshot?.lowestFetchedUID == 0
            || snapshot?.highestFetchedUID == 0
            || hasDisconnectedCursor

        if isInitialAnchor {
            let low = maxUID >= batchU ? maxUID - batchU + 1 : 1
            return (low, maxUID, false, true)
        }

        let currentHigh = snapshot?.highestFetchedUID ?? 0
        guard maxUID > currentHigh else {
            return (0, 0, true, false)
        }

        let remaining = maxUID - currentHigh
        let high = remaining > batchU ? currentHigh + batchU : maxUID
        return (currentHigh + 1, high, false, false)
    }

    /// Re-SELECT INBOX if we drifted, then beginIdle. Called from the defer
    /// block in backfillTick / pollFolder when we were idling on entry.
    private func resumeIdleOnINBOX() async throws {
        guard let c = client else { return }
        if currentMailbox != "INBOX" {
            let result = try await selectMailboxTrackingDeletions("INBOX")
            let s = result.select
            await handleUIDValidityChangeIfNeeded(folder: "INBOX", newState: s)
            currentMailbox = "INBOX"
            currentSelectState = s
            lastKnownExists = s.exists
        }
        try await c.beginIdle()
        await transition(to: .idling)
    }

    private func suspendIdleIfNeeded(using client: any IMAPClienting) async throws -> Bool {
        guard case .idling = status else { return false }
        try await client.endIdle()
        return true
    }

    private func drainLiveInboxAndResumeIdleIfNeeded(wasIdling: Bool) async throws {
        guard wasIdling else { return }
        do {
            try await drainNewMailInINBOX()
            try await resumeIdleOnINBOX()
        } catch {
            try? await resumeIdleOnINBOX()
            throw error
        }
    }

    private static func makeInitialSnapshot(
        accountID: UUID,
        folderName: String,
        selectState: IMAPSelectState
    ) -> IMAPFolderStateSnapshot {
        let anchor = selectState.uidNext > 0 ? selectState.uidNext - 1 : 0
        return IMAPFolderStateSnapshot(
            accountID: accountID,
            folderName: folderName,
            folderAttributes: [],
            uidValidity: selectState.uidValidity,
            uidNextAtLastSelect: selectState.uidNext,
            existsAtLastSelect: selectState.exists,
            highestFetchedUID: anchor,
            lowestFetchedUID: selectState.uidNext,
            backfillComplete: false
        )
    }
}
