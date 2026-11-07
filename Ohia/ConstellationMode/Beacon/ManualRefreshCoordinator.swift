// ManualRefreshCoordinator.swift
// Drives the Constellation starburst button as a quick new-node check:
// click -> poll the new-mail folder for each displayed IMAP account -> show
// a short result. Background IMAP work such as deletion reconciliation,
// historical sync, and full mailbox maintenance stays outside this UI loop.

import Foundation
import Observation
import os
import OhiaCore
import OhiaMail
import OhiaScheduler

private enum ManualRefreshLog {
    static let logger = Logger(subsystem: "com.ohia.app", category: "ManualRefresh")
}

enum ManualRefreshTransientFailureReason: Equatable, Sendable {
    case connection
    case syncing
}

enum ManualRefreshUIState: Equatable, Sendable {
    case idle
    case searching
    case newMail(count: Int)
    case empty
    case transientFailure(ManualRefreshTransientFailureReason)
    case authFailure(accountID: UUID, accountEmail: String)

    var capsuleText: String? {
        switch self {
        case .idle, .searching, .empty:
            // The empty (no-new-mail) outcome is expressed entirely by the
            // collapsing-star motion inside the starburst — no text capsule.
            return nil
        case .newMail(let count):
            return count == 1 ? "A new node is forming" : "\(count) new nodes are forming"
        case .transientFailure(.connection):
            return "Couldn't reach mail server."
        case .transientFailure(.syncing):
            return "Mail is still syncing."
        case .authFailure(_, let email):
            return "Sign in again to check \(email)."
        }
    }

    var isFailure: Bool {
        switch self {
        case .transientFailure, .authFailure:
            return true
        case .idle, .searching, .newMail, .empty:
            return false
        }
    }
}

/// Exact message IDs discovered by user-initiated beacon checks. The shared
/// request survives lens remounts, while the arrival ledger remains the
/// authority for whether each requested message is still awaiting its unified
/// placement, badge, sound, and notification.
@Observable
@MainActor
final class ManualRefreshArrivalAnimationRequest {
    static let shared = ManualRefreshArrivalAnimationRequest()

    private(set) var messageIDs: Set<UUID> = []

    func recordDetected(
        _ detectedMessageIDs: [UUID],
        pendingArrivalMessageIDs: Set<UUID>
    ) {
        messageIDs.formIntersection(pendingArrivalMessageIDs)
        messageIDs.formUnion(
            Set(detectedMessageIDs).intersection(pendingArrivalMessageIDs)
        )
    }

    func pendingMessageIDs(
        in pendingArrivalMessageIDs: Set<UUID>
    ) -> Set<UUID> {
        messageIDs.intersection(pendingArrivalMessageIDs)
    }
}

@Observable
@MainActor
final class ManualRefreshCoordinator {
    /// Minimum visible search time so the click feels acknowledged.
    static let minSearchingDuration: TimeInterval = 2.0
    /// Maximum visible search time. The starburst must never stay spinning
    /// while unrelated IMAP maintenance continues in the background.
    static let maxSearchingDuration: TimeInterval = 30.0
    static let resultVisibleDuration: TimeInterval = 3.0

    private(set) var state: ManualRefreshUIState = .idle

    /// Increments every time the parent reports a click landing while
    /// already searching. The view binds an animation to this value and
    /// flickers the icon a single 0.95x pulse on each change.
    private(set) var ackFlickerSeq: Int = 0

    /// Increments each time a manual check lands on the no-new-mail outcome.
    /// The starburst binds its collapsing-star motion to this value so the
    /// empty result reads entirely inside the icon — no text capsule.
    private(set) var emptySignalSeq: Int = 0

    private var inFlight: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var idleTransitionTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var successfulPollObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        successfulPollObserver = notificationCenter.addObserver(
            forName: .ohiaIMAPPollSucceeded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordSuccessfulIMAPPoll()
            }
        }
    }

    isolated deinit {
        if let successfulPollObserver {
            notificationCenter.removeObserver(successfulPollObserver)
        }
    }

    struct FolderCandidate: Equatable, Sendable {
        let folderName: String
        let attributes: [String]

        init(folderName: String, attributes: [String]) {
            self.folderName = folderName
            self.attributes = attributes
        }
    }

    enum RefreshEligibility: Equatable, Sendable {
        case eligible
        case authRequired
        case unavailable
    }

    struct RefreshTarget: Sendable {
        let accountID: UUID
        let email: String
        let folderNames: [String]
        let eligibility: RefreshEligibility
    }

    struct AccountResult: Sendable {
        let newInboundMessageIDs: [UUID]
        let completedAuthoritativePoll: Bool
        let transientFailureReason: ManualRefreshTransientFailureReason?
        let authFailure: (accountID: UUID, email: String)?

        static func completed(newInboundMessageIDs: [UUID]) -> Self {
            Self(
                newInboundMessageIDs: newInboundMessageIDs,
                completedAuthoritativePoll: true,
                transientFailureReason: nil,
                authFailure: nil
            )
        }

        static func incomplete(
            newInboundMessageIDs: [UUID],
            reason: ManualRefreshTransientFailureReason = .connection
        ) -> Self {
            Self(
                newInboundMessageIDs: newInboundMessageIDs,
                completedAuthoritativePoll: false,
                transientFailureReason: reason,
                authFailure: nil
            )
        }

        static func ineligible(target: RefreshTarget) -> Self {
            switch target.eligibility {
            case .authRequired:
                return Self(
                    newInboundMessageIDs: [],
                    completedAuthoritativePoll: false,
                    transientFailureReason: nil,
                    authFailure: (target.accountID, target.email)
                )
            case .eligible, .unavailable:
                return .incomplete(newInboundMessageIDs: [], reason: .syncing)
            }
        }
    }

    struct Resolution: Sendable {
        let state: ManualRefreshUIState
        let newInboundMessageIDs: [UUID]
    }

    func request(
        accounts: [Account],
        sessionManager: IMAPSessionManager?,
        allowsIMAPWork: Bool = true
    ) {
        guard state != .searching else { return }

        let targets = accounts.map {
            Self.makeRefreshTarget(
                for: $0,
                allowsIMAPWork: allowsIMAPWork
            )
        }

        let sessionStatuses: [(String, String)] = accounts.map { account in
            let raw = sessionManager?.statusByAccount[account.id]
            return (account.emailAddress, Self.describe(raw))
        }
        ManualRefreshLog.logger.debug("click: accounts=\(accounts.count) targets=\(targets.count) sessionManager=\(sessionManager != nil ? "present" : "nil")")
        for (email, status) in sessionStatuses {
            let folders = targets.first(where: { $0.email == email })?.folderNames ?? []
            ManualRefreshLog.logger.debug("  account=\(email, privacy: .private) status=\(status) newMailFolders=\(folders)")
        }

        idleTransitionTask?.cancel()
        idleTransitionTask = nil
        inFlight?.cancel()
        inFlight = nil
        pollTask?.cancel()
        pollTask = nil

        let requestID = UUID()
        activeRequestID = requestID
        state = .searching

        let startedAt = Date.now
        pollTask = Task { [weak self] in
            let aggregate = await Self.pollAll(targets: targets, sessionManager: sessionManager)
            let elapsed = Date.now.timeIntervalSince(startedAt)
            if elapsed < Self.minSearchingDuration {
                try? await Task.sleep(for: .seconds(Self.minSearchingDuration - elapsed))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.apply(aggregate, requestID: requestID)
            }
        }

        inFlight = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxSearchingDuration))
            guard !Task.isCancelled, let self else { return }
            guard self.activeRequestID == requestID, self.state == .searching else { return }
            self.pollTask?.cancel()
            self.pollTask = nil
            self.state = Self.interruptedPollState
            self.activeRequestID = nil
        }
    }

    func acknowledgeClick() {
        ackFlickerSeq &+= 1
    }

    static func makeRefreshTarget(
        for account: Account,
        allowsIMAPWork: Bool
    ) -> RefreshTarget {
        let eligibility: RefreshEligibility
        if account.needsImapReauth {
            eligibility = .authRequired
        } else if allowsIMAPWork,
                  account.status != .paused,
                  account.imapHost != nil,
                  account.imapKeychainRef != nil {
            eligibility = .eligible
        } else {
            eligibility = .unavailable
        }
        return RefreshTarget(
            accountID: account.id,
            email: account.emailAddress,
            folderNames: manualNewMailFolderNames(
                imapHost: account.imapHost,
                from: account.imapFolderStates.map {
                    FolderCandidate(
                        folderName: $0.folderName,
                        attributes: $0.folderAttributes
                    )
                }
            ),
            eligibility: eligibility
        )
    }

    static func manualNewMailFolderNames(
        imapHost: String?,
        from folders: [FolderCandidate]
    ) -> [String] {
        let selectable = folders.filter { folder in
            !folder.attributes.contains {
                $0.caseInsensitiveCompare("\\Noselect") == .orderedSame
            }
        }
        let normalizedHost = imapHost?.lowercased() ?? ""
        let isGmail = normalizedHost.contains("gmail") || normalizedHost.contains("google")
        if isGmail {
            let gmailAllFolders = selectable.filter {
                classifyIMAPFolderRole(
                    folder: $0.folderName,
                    attributes: $0.attributes
                ) == .gmailAll
            }
            if !gmailAllFolders.isEmpty {
                return uniqueFolderNames(gmailAllFolders.map(\.folderName))
            }
        }

        let inboxes = selectable.filter {
            classifyIMAPFolderRole(folder: $0.folderName, attributes: $0.attributes) == .inbox
        }
        if !inboxes.isEmpty {
            return uniqueFolderNames(inboxes.map(\.folderName))
        }

        // RFC 3501 requires the canonical INBOX name even before folder
        // discovery has persisted its row.
        return ["INBOX"]
    }

    static let interruptedPollState = ManualRefreshUIState.transientFailure(.syncing)

    static func stateAfterSuccessfulPoll(
        _ state: ManualRefreshUIState
    ) -> ManualRefreshUIState {
        state.isFailure ? .idle : state
    }

    static func resolveAccountResults(_ results: [AccountResult]) -> Resolution {
        var seenMessageIDs: Set<UUID> = []
        var newInboundMessageIDs: [UUID] = []
        for result in results {
            for messageID in result.newInboundMessageIDs where seenMessageIDs.insert(messageID).inserted {
                newInboundMessageIDs.append(messageID)
            }
        }

        let firstAuthFailure = results
            .compactMap(\.authFailure)
            .sorted {
                if $0.email != $1.email { return $0.email < $1.email }
                return $0.accountID.uuidString < $1.accountID.uuidString
            }
            .first
        let transientFailureReasons = results.compactMap(\.transientFailureReason)
        let hasIncompleteTarget = results.contains { !$0.completedAuthoritativePoll }
        let state: ManualRefreshUIState
        if let firstAuthFailure {
            state = .authFailure(
                accountID: firstAuthFailure.accountID,
                accountEmail: firstAuthFailure.email
            )
        } else if transientFailureReasons.contains(.connection) {
            state = .transientFailure(.connection)
        } else if hasIncompleteTarget || results.isEmpty {
            state = .transientFailure(.syncing)
        } else if newInboundMessageIDs.isEmpty == false {
            state = .newMail(count: newInboundMessageIDs.count)
        } else {
            state = .empty
        }
        return Resolution(
            state: state,
            newInboundMessageIDs: newInboundMessageIDs
        )
    }

    private func apply(_ resolution: Resolution, requestID: UUID) {
        guard activeRequestID == requestID, state == .searching else { return }
        pollTask = nil
        inFlight?.cancel()
        inFlight = nil

        let arrivalLedger = NewMailArrivalLedger.shared
        arrivalLedger.registerDetected(resolution.newInboundMessageIDs)
        ManualRefreshArrivalAnimationRequest.shared.recordDetected(
            resolution.newInboundMessageIDs,
            pendingArrivalMessageIDs: arrivalLedger.pendingArrivalMessageIDs
        )
        state = resolution.state
        if state == .empty {
            emptySignalSeq &+= 1
        }
        if state.isFailure {
            activeRequestID = nil
        } else {
            scheduleReturnToIdle(after: Self.resultVisibleDuration)
        }
    }

    private func recordSuccessfulIMAPPoll() {
        let nextState = Self.stateAfterSuccessfulPoll(state)
        guard nextState != state else { return }
        idleTransitionTask?.cancel()
        idleTransitionTask = nil
        activeRequestID = nil
        state = nextState
    }

    private func scheduleReturnToIdle(after seconds: TimeInterval) {
        idleTransitionTask?.cancel()
        idleTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.state = .idle
            self.activeRequestID = nil
        }
    }

    private static func uniqueFolderNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for name in names {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            unique.append(name)
        }
        return unique
    }

    private static func pollAll(
        targets: [RefreshTarget],
        sessionManager: IMAPSessionManager?
    ) async -> Resolution {
        var results: [AccountResult] = []
        await withTaskGroup(of: AccountResult.self) { group in
            for target in targets {
                group.addTask {
                    await pollAccount(target: target, sessionManager: sessionManager)
                }
            }
            for await result in group {
                results.append(result)
            }
        }
        return resolveAccountResults(results)
    }

    private static func pollAccount(
        target: RefreshTarget,
        sessionManager: IMAPSessionManager?
    ) async -> AccountResult {
        guard target.eligibility == .eligible else {
            return .ineligible(target: target)
        }
        guard let sessionManager else {
            return .incomplete(newInboundMessageIDs: [], reason: .syncing)
        }

        let session = await MainActor.run {
            sessionManager.sessionForManualWork(
                accountID: target.accountID,
                livePollAllowed: true
            )
        }

        guard let session else {
            return .incomplete(newInboundMessageIDs: [], reason: .syncing)
        }

        guard !target.folderNames.isEmpty else {
            return .incomplete(newInboundMessageIDs: [], reason: .syncing)
        }

        var newInboundMessageIDs: [UUID] = []

        for folderName in target.folderNames {
            do {
                try Task.checkCancellation()
                let result = try await session.pollLiveTail(folder: folderName)
                newInboundMessageIDs.append(contentsOf: result.newInboundMessageIDs)
                ManualRefreshLog.logger.debug("  poll \(target.email, privacy: .private)/\(folderName) -> fetched=\(result.fetched) inbound=\(result.newInboundMessageIDs.count) hasMore=\(result.hasMore)")
            } catch let error as IMAPError {
                switch error {
                case .authFailed, .reauthRequired:
                    ManualRefreshLog.logger.error("  poll \(target.email, privacy: .private)/\(folderName) -> AUTH FAILED \(String(reflecting: type(of: error)), privacy: .public)")
                    return AccountResult(
                        newInboundMessageIDs: newInboundMessageIDs,
                        completedAuthoritativePoll: false,
                        transientFailureReason: nil,
                        authFailure: (target.accountID, target.email)
                    )
                case .cancelled:
                    ManualRefreshLog.logger.debug("  poll \(target.email, privacy: .private)/\(folderName) -> cancelled")
                    return .incomplete(
                        newInboundMessageIDs: newInboundMessageIDs,
                        reason: .syncing
                    )
                case .transient,
                     .protocolViolation,
                     .mailStream,
                     .serverTemporary,
                     .serverClosedConnection,
                     .notConnected,
                     .notImapServer:
                    ManualRefreshLog.logger.notice("  poll \(target.email, privacy: .private)/\(folderName) -> transient \(String(reflecting: type(of: error)), privacy: .public)")
                    return .incomplete(newInboundMessageIDs: newInboundMessageIDs)
                }
            } catch is CancellationError {
                ManualRefreshLog.logger.debug("  poll \(target.email, privacy: .private)/\(folderName) -> cancelled")
                return .incomplete(
                    newInboundMessageIDs: newInboundMessageIDs,
                    reason: .syncing
                )
            } catch {
                ManualRefreshLog.logger.error("  poll \(target.email, privacy: .private)/\(folderName) -> error \(String(reflecting: type(of: error)), privacy: .public)")
                return .incomplete(newInboundMessageIDs: newInboundMessageIDs)
            }
        }

        return .completed(newInboundMessageIDs: newInboundMessageIDs)
    }

    private static func describe(_ status: IMAPSessionStatus?) -> String {
        guard let status else { return "(no session)" }
        switch status {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .authing: return "authing"
        case .selected: return "selected"
        case .idling: return "idling"
        case .syncing(let folder): return "syncing(\(folder))"
        case .reconnecting(let attempt): return "reconnecting(\(attempt))"
        case .halted(let reason): return "halted(\(reason))"
        }
    }
}
