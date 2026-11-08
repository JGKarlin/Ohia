import SwiftUI
import SwiftData
import AppKit
import CryptoKit
import Observation
import UserNotifications
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML
import OhiaScheduler
import os

/// The unified arrival gate: ordinary pipeline interpretation, layout, and any
/// required exact reply-preparation snapshot must all be complete. There is
/// deliberately no alert-only fallback for vectorless mail: a new-mail
/// notification cannot precede placement in the active lens.
func isRowReadyForUnifiedArrival(
    _ row: MessageStoreLiveInboundRow,
    replyPreparationReady: Bool
) -> Bool {
    row.isPipelineReadyForUserAlert
        && row.placedAt != nil
        && replyPreparationReady
}

/// Arrivals the user already read in another mail client; they appear
/// without the arrival alert.
@MainActor
func alreadyReadArrivalIDs(_ messageIDs: [UUID], context: ModelContext) -> Set<UUID> {
    guard messageIDs.isEmpty == false else { return [] }
    let ids = Array(Set(messageIDs))
    let descriptor = FetchDescriptor<Message>(
        predicate: #Predicate<Message> { ids.contains($0.id) && $0.isRead == true }
    )
    do {
        return Set(try context.fetch(descriptor).map(\.id))
    } catch {
        // Unknown read state alerts, as for any unread arrival.
        Logger(subsystem: "com.ohia.app", category: "LiveInboundArrival")
            .error("read-state lookup for arrivals failed: \(String(describing: error), privacy: .public)")
        return []
    }
}

nonisolated func replyPreparationPresentationReadiness(
    messageIDs: [UUID],
    container: ModelContainer
) -> [UUID: Bool] {
    replyPreparationPresentationReadiness(messageIDs: messageIDs, container: container, now: Date())
}

nonisolated func replyPreparationPresentationReadiness(
    messageIDs: [UUID],
    container: ModelContainer,
    now: Date
) -> [UUID: Bool] {
    guard messageIDs.isEmpty == false else { return [:] }
    let ids = Array(Set(messageIDs))
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<Message>(
        predicate: #Predicate<Message> { ids.contains($0.id) }
    )
    guard let messages = try? context.fetch(descriptor) else {
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })
    }
    var readiness = Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })
    for message in messages {
        guard !Task.isCancelled else { return readiness }
        readiness[message.id] = ReplyPreparationInputReadiness
            .isReadyForFirstPresentation(message: message, context: context, now: now)
    }
    return readiness
}

nonisolated struct LiveInboundReconciliationSnapshot: Sendable {
    let rows: [MessageStoreLiveInboundRow]
    let replyPreparationReadiness: [UUID: Bool]
    let completedSweep: Bool
}

/// One process-owned lane: the polling task awaits the whole sweep, and a
/// cancelled/restarted poll cannot overlap SwiftData materialization. Each
/// page owns a fresh context and only Sendable values return to the UI.
actor LiveInboundReconciliationWorker {
    typealias PageLoader = @Sendable (
        Date, MessageStoreLiveInboundCursor?, Int
    ) throws -> MessageStoreLiveInboundPage?
    typealias ReadinessLoader = @Sendable ([UUID], ModelContainer) -> [UUID: Bool]

    private let loadPage: PageLoader
    private let loadReadiness: ReadinessLoader

    init(
        loadPage: @escaping PageLoader = { since, cursor, limit in
            try MessageStoreHotPath.recentLiveInboundPage(
                since: since, after: cursor, limit: limit
            )
        },
        loadReadiness: @escaping ReadinessLoader = replyPreparationPresentationReadiness
    ) {
        self.loadPage = loadPage
        self.loadReadiness = loadReadiness
    }

    func gather(
        since: Date,
        announcedMessageIDs: Set<String>,
        container: ModelContainer,
        pageSize: Int
    ) throws -> LiveInboundReconciliationSnapshot {
        try Task.checkCancellation()
        var rows: [MessageStoreLiveInboundRow] = []
        var readiness: [UUID: Bool] = [:]
        var cursor: MessageStoreLiveInboundCursor?
        var completedSweep = true
        while true {
            try Task.checkCancellation()
            guard let page = try loadPage(since, cursor, pageSize) else {
                completedSweep = false
                break
            }
            try Task.checkCancellation()
            rows.append(contentsOf: page.rows)
            let candidateIDs = page.rows.compactMap { row -> UUID? in
                guard !announcedMessageIDs.contains(row.messageId.uuidString),
                      row.isPipelineReadyForUserAlert, row.placedAt != nil else {
                    return nil
                }
                return row.messageId
            }
            if !candidateIDs.isEmpty {
                readiness.merge(loadReadiness(candidateIDs, container)) { _, latest in latest }
            }
            try Task.checkCancellation()
            guard let nextCursor = page.nextCursor, nextCursor != cursor else { break }
            cursor = nextCursor
        }
        return LiveInboundReconciliationSnapshot(
            rows: rows,
            replyPreparationReadiness: readiness,
            completedSweep: completedSweep
        )
    }
}

/// The main actor can process a deletion or input edit while a sweep is in
/// flight. Such a sweep must not release an old ready result. Observers run
/// synchronously on the posting thread, closing the hop-to-MainActor window.
nonisolated final class LiveInboundReconciliationValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        for name in [
            Notification.Name.ohiaDeletionApplied,
            .ohiaMessageAttentionChanged,
            .ohiaEmailSummariesInvalidated,
            .ohiaMailSendConfirmed,
        ] {
            observers.append(notificationCenter.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                self?.invalidate()
            })
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    var isCurrent: Bool {
        lock.withLock { valid }
    }

    private func invalidate() {
        lock.withLock { valid = false }
    }
}

enum WorkerFleetResourceState: Sendable, Equatable {
    case full
    case throttled
    case paused
    case waiting
    case loading
    case unavailable
    case failed

    var displayLabel: String {
        switch self {
        case .full: return "full speed"
        case .throttled: return "throttled"
        case .paused: return "paused"
        case .waiting: return "waiting"
        case .loading: return "loading"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }
}

enum WorkerFleetProcessState: Sendable, Equatable {
    case running
    case stopped

    var displayLabel: String {
        switch self {
        case .running: return "worker running"
        case .stopped: return "worker stopped"
        }
    }
}

struct WorkerStatusPresentationSnapshot: Sendable, Equatable {
    let worker: WorkerStatusSnapshot
    let resourceState: WorkerFleetResourceState
    let processState: WorkerFleetProcessState
    let detail: String?
    let throttleReasons: [String]
    let updatedAt: Date

    static func unavailable(_ role: WorkerRole) -> WorkerStatusPresentationSnapshot {
        let now = Date()
        return WorkerStatusPresentationSnapshot(
            worker: WorkerStatusSnapshot(role: role, state: .unknown, updatedAt: now),
            resourceState: .unavailable,
            processState: .stopped,
            detail: "status snapshot unavailable",
            throttleReasons: [],
            updatedAt: now
        )
    }

    var help: String {
        var parts = [
            "\(worker.role.resourceTitle): \(resourceState.displayLabel)",
            "\(worker.processName): \(processState.displayLabel)",
            "state: \(worker.state.displayLabel)",
        ]
        if let currentJob = worker.currentJobDescription ?? worker.currentJobType {
            parts.append("job: \(currentJob)")
        }
        if let message = worker.statusMessage, !message.isEmpty {
            parts.append(message)
        }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if !throttleReasons.isEmpty {
            parts.append("reason: \(throttleReasons.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}

@Observable
final class WorkerFleetStatusPublisher {
    @ObservationIgnored
    private(set) var fleet = OhiaCore.WorkerFleetStatusSnapshot(workers: [])
    private(set) var bge: WorkerStatusPresentationSnapshot = .unavailable(.bge)
    private(set) var qwen: WorkerStatusPresentationSnapshot = .unavailable(.qwen)
    private(set) var semanticGeneration = 0

    @ObservationIgnored
    private var bgeSemanticValue: PresentationSemanticValue?
    @ObservationIgnored
    private var qwenSemanticValue: PresentationSemanticValue?

    func snapshot(for role: WorkerRole) -> WorkerStatusPresentationSnapshot {
        let cached: WorkerStatusPresentationSnapshot
        switch role {
        case .bge: cached = bge
        case .qwen: cached = qwen
        }
        guard let rawWorker = fleet.status(for: role) else {
            return cached
        }
        return WorkerStatusPresentationSnapshot(
            worker: rawWorker,
            resourceState: cached.resourceState,
            processState: cached.processState,
            detail: cached.detail,
            throttleReasons: cached.throttleReasons,
            updatedAt: cached.updatedAt
        )
    }

    @MainActor
    func update(
        fleet: OhiaCore.WorkerFleetStatusSnapshot,
        bge: WorkerStatusPresentationSnapshot,
        qwen: WorkerStatusPresentationSnapshot
    ) {
        for (previous, current) in [(self.bge, bge), (self.qwen, qwen)] {
            if let pid = previous.worker.pid, previous.processState == .running,
               current.processState == .stopped || current.worker.pid != pid {
                SessionActivityLog.shared.record(SessionActivityEvent(
                    operation: "Worker stopped", phase: .state,
                    detail: previous.worker.role.displayName, processID: pid
                ))
            }
        }
        self.fleet = fleet

        var semanticChange = false
        let newBGESemanticValue = PresentationSemanticValue(bge)
        if bgeSemanticValue != newBGESemanticValue {
            bgeSemanticValue = newBGESemanticValue
            self.bge = bge
            semanticChange = true
        }

        let newQwenSemanticValue = PresentationSemanticValue(qwen)
        if qwenSemanticValue != newQwenSemanticValue {
            qwenSemanticValue = newQwenSemanticValue
            self.qwen = qwen
            semanticChange = true
        }

        if semanticChange {
            semanticGeneration &+= 1
        }
    }

    private struct PresentationSemanticValue: Equatable {
        let worker: WorkerStatusSnapshot.SemanticValue
        let imapActivityStreamID: UUID?
        let imapActivitySequence: UInt64?
        let resourceState: WorkerFleetResourceState
        let processState: WorkerFleetProcessState
        let detail: String?
        let throttleReasons: [String]

        init(_ snapshot: WorkerStatusPresentationSnapshot) {
            self.worker = snapshot.worker.semanticValue
            self.imapActivityStreamID = snapshot.worker.imapActivityStreamID
            self.imapActivitySequence = snapshot.worker.imapActivitySequence
            self.resourceState = snapshot.resourceState
            self.processState = snapshot.processState
            self.detail = snapshot.detail
            self.throttleReasons = snapshot.throttleReasons
        }
    }
}

@MainActor
private final class WorkerStatusRefreshCoordinator {
    var gate = WorkerStatusRefreshGate(
        minimumInterval: .seconds(1)
    )
    var observationTask: Task<Void, Never>?
    var delayedReadTask: Task<Void, Never>?
    var readTask: Task<Void, Never>?
    var completionBridge = WorkerCompletionBridgeTracker(
        historyCapacity: 500
    )
    var lastErrorSignature: String?

    func cancel() {
        gate.cancel()
        observationTask?.cancel()
        delayedReadTask?.cancel()
        readTask?.cancel()
        observationTask = nil
        delayedReadTask = nil
        readTask = nil
    }
}

@Observable
final class StartupSplashVisibility {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

private extension WorkerRole {
    var resourceTitle: String {
        switch self {
        case .bge: return "Retrieval Worker"
        case .qwen: return "Generative Worker"
        @unknown default: return "Worker"
        }
    }
}

private extension WorkerState {
    var displayLabel: String {
        rawValue
    }
}

private extension ResourceThrottleReason {
    /// `PipelineActivityPresentation.throttleReasonLabel` is the single
    /// source of truth for throttle-reason copy across the worker-status
    /// surfaces, so adjacent tooltips can never disagree. Exhaustiveness is
    /// test-enforced in
    /// `ResourcePolicyTests.everyThrottleReasonHasACuratedLabel`.
    var displayLabel: String {
        PipelineActivityPresentation.throttleReasonLabel(rawValue)
    }
}

private struct RawEmailDateRepairCandidate: Sendable {
    let messageId: UUID
    let rawPath: String
}

private enum RawEmailDateRepairer {
    nonisolated static func sentDates(for candidates: [RawEmailDateRepairCandidate]) -> [UUID: Date] {
        var dates: [UUID: Date] = [:]
        dates.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.rawPath)),
                  let parsed = try? MIMEParser.parse(data: data),
                  let sentAt = IngestionOrchestrator.parseEmailDateHeader(parsed.date) else {
                continue
            }
            dates[candidate.messageId] = sentAt
        }
        return dates
    }
}

enum NewMailUserNotifier {
    struct DeliveryPayload: Sendable, Equatable {
        let accountID: UUID
        let folder: String
        let count: Int
        let messageIDs: [UUID]
    }

    enum ActionIdentifier {
        static let open = "ohia.notification.openMessage"
        static let markRead = "ohia.notification.markRead"
    }

    enum CategoryIdentifier {
        static let single = "ohia.notification.newMail.single"
        static let batch = "ohia.notification.newMail.batch"
    }

    enum ResponseRoute: Sendable, Equatable {
        case openMessage(UUID)
        case markRead([UUID])
        case none
    }

    static let messageIDsUserInfoKey = "messageIDs"

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(notificationCategories())
        center.requestAuthorization(options: [.alert, .badge]) { _, error in
            if let error {
                print("[Ohia] New mail notification authorization failed: \(String(reflecting: type(of: error)))")
            }
        }
    }

    @MainActor
    static func deliver(payload: DeliveryPayload, context: ModelContext) {
        let snapshots = snapshots(for: payload.messageIDs, context: context)
        let group = LiveInboundNotificationGroup(
            accountID: payload.accountID,
            folder: payload.folder
        )
        let presentation = NewMailNotificationPresentation.make(
            threadIdentifier: NewMailNotificationRoutingTokens.shared
                .threadIdentifier(for: group),
            folder: payload.folder,
            count: payload.count,
            messages: snapshots
        )

        let request = notificationRequest(for: presentation)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Ohia] New mail notification delivery failed: \(String(reflecting: type(of: error)))")
            }
        }
    }

    static func notificationRequest(
        for presentation: NewMailNotificationPresentation
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        content.threadIdentifier = presentation.threadIdentifier
        content.categoryIdentifier = switch presentation.kind {
        case .singleMessage: CategoryIdentifier.single
        case .messageBatch: CategoryIdentifier.batch
        }
        content.relevanceScore = presentation.relevanceScore
        if presentation.interruptionHint == .timeSensitive {
            content.interruptionLevel = .timeSensitive
        } else {
            content.interruptionLevel = .active
        }
        content.userInfo = notificationUserInfo(for: presentation)

        return UNNotificationRequest(
            identifier: requestIdentifier(),
            content: content,
            trigger: nil
        )
    }

    static func messageIDs(from userInfo: [AnyHashable: Any]) -> [UUID] {
        if let ids = userInfo[messageIDsUserInfoKey] as? [UUID] {
            return ids
        }
        if let strings = userInfo[messageIDsUserInfoKey] as? [String] {
            return strings.compactMap(UUID.init(uuidString:))
        }
        return []
    }

    static func primaryMessageID(from userInfo: [AnyHashable: Any]) -> UUID? {
        messageIDs(from: userInfo).first
    }

    static func responseRoute(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> ResponseRoute {
        switch actionIdentifier {
        case ActionIdentifier.markRead:
            let ids = messageIDs(from: userInfo)
            return ids.isEmpty ? .none : .markRead(ids)
        case ActionIdentifier.open, UNNotificationDefaultActionIdentifier:
            guard let messageID = primaryMessageID(from: userInfo) else {
                return .none
            }
            return .openMessage(messageID)
        default:
            return .none
        }
    }

    private static func notificationCategories() -> Set<UNNotificationCategory> {
        let open = UNNotificationAction(
            identifier: ActionIdentifier.open,
            title: "Open",
            options: [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: ActionIdentifier.markRead,
            title: "Mark Read",
            options: []
        )
        let single = UNNotificationCategory(
            identifier: CategoryIdentifier.single,
            actions: [open, markRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let batch = UNNotificationCategory(
            identifier: CategoryIdentifier.batch,
            actions: [open, markRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        return [single, batch]
    }

    @MainActor
    private static func snapshots(
        for messageIDs: [UUID],
        context: ModelContext
    ) -> [NewMailNotificationMessageSnapshot] {
        let decoder = JSONDecoder()
        return messageIDs.compactMap { id in
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard let message = try? context.fetch(descriptor).first else {
                return nil
            }
            let decodedVerdict = decodeTriageVerdict(
                message.analysis?.triageVerdictJSON,
                decoder: decoder,
                isSentByUser: message.isSentByUser
            )
            let verdict = message.isLiveInboundTriageEligible ? decodedVerdict : nil
            let dimensions = decodeMessageDimensions(
                message.analysis?.dimensionsJSON,
                decoder: decoder
            )
            let deadlineText = dimensions?.primaryDeadlineDisplayText
                ?? verdict?.deadlineCandidates.compactMap(\.displayText).first
            let hasDeadline = dimensions?.deadlines.isEmpty == false
                || verdict?.deadlineCandidates.isEmpty == false
            let classification = MailClassificationJSON.decode(
                message.analysis?.mailClassificationJSON
            )
            return NewMailNotificationMessageSnapshot(
                id: message.id,
                senderName: message.fromName,
                senderAddress: message.fromAddress,
                subject: message.subject,
                purpose: classification?.purpose,
                isActionable: verdict?.isActionable ?? false,
                requiresConfirmation: verdict?.requiresConfirmation ?? false,
                hasDeadline: hasDeadline,
                deadlineText: deadlineText,
                isRead: message.isReadOrFalse,
                receivedAt: message.receivedAt ?? message.sentAt
            )
        }
    }

    private static func decodeTriageVerdict(
        _ json: String?,
        decoder: JSONDecoder,
        isSentByUser: Bool
    ) -> TriageVerdict? {
        guard let json,
              let data = json.data(using: .utf8),
              let verdict = try? decoder.decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.normalizingActionability(isSentByUser: isSentByUser)
    }

    private static func decodeMessageDimensions(
        _ json: String?,
        decoder: JSONDecoder
    ) -> MessageDimensions? {
        guard let json,
              let data = json.data(using: .utf8),
              let dimensions = try? decoder.decode(MessageDimensions.self, from: data) else {
            return nil
        }
        return dimensions
    }

    private static func notificationUserInfo(
        for presentation: NewMailNotificationPresentation
    ) -> [AnyHashable: Any] {
        [messageIDsUserInfoKey: presentation.messageIDs.map(\.uuidString)]
    }

    private static func requestIdentifier() -> String {
        "ohia-new-mail-\(UUID().uuidString)"
    }
}

struct LiveInboundNotificationGroup: Hashable {
    let accountID: UUID
    let folder: String
}

struct OhiaRunningApplicationSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleLastPathComponent: String?
    let executableLastPathComponent: String?
    let launchDate: Date?
}

private extension OhiaRunningApplicationSnapshot {
    init(_ application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier
        bundleLastPathComponent = application.bundleURL?.lastPathComponent
        executableLastPathComponent = application.executableURL?.lastPathComponent
        launchDate = application.launchDate
    }
}

enum OhiaSingleInstanceCoordinator {
    nonisolated static let canonicalBundleIdentifier = "org.jgkarlin.Ohia"
    nonisolated static let settingsWindowID = "settings"
    private static let oauthRedirectHandoffNotification =
        Notification.Name("org.jgkarlin.Ohia.oauthRedirectHandoff")
    /// OAuth redirect schemes this build answers: Microsoft's fixed scheme, and
    /// Google's reversed client ID when Configuration.plist carries one.
    nonisolated private static let oauthURLSchemes: [String] = {
        var schemes = ["com.ohia.app"]
        if let clientID = OAuthProvider.gmail.clientID,
           let scheme = URLComponents(string: OAuthProvider.gmail.redirectURI(for: clientID))?.scheme {
            schemes.append(scheme.lowercased())
        }
        return schemes
    }()

    nonisolated static func isOhiaApplication(_ snapshot: OhiaRunningApplicationSnapshot) -> Bool {
        guard let bundleIdentifier = snapshot.bundleIdentifier,
              bundleIdentifier == canonicalBundleIdentifier
                || bundleIdentifier.hasPrefix("\(canonicalBundleIdentifier).")
        else {
            return false
        }
        return true
    }

    nonisolated static func isOAuthRedirectURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return oauthURLSchemes.contains(scheme)
    }

    nonisolated static func oauthRedirectHandoffObjects(for urls: [URL]) -> [String] {
        urls.filter(isOAuthRedirectURL).map(\.absoluteString)
    }

    @MainActor
    static func presentOAuthReturn() {
        presentOAuthReturn(
            activateApplication: { NSApp.activate() },
            constellationWindow: {
                SceneWindowRegistry.shared.window(for: OhiaWindowID.constellation)
            },
            settingsWindow: {
                SceneWindowRegistry.shared.window(for: settingsWindowID)
            }
        )
    }

    @MainActor
    static func presentOAuthReturn(
        activateApplication: @MainActor () -> Void,
        constellationWindow: @MainActor () -> NSWindow?,
        settingsWindow: @MainActor () -> NSWindow? = { nil }
    ) {
        activateApplication()
        let visibleSettingsWindow = settingsWindow().flatMap { window in
            window.isVisible ? window : nil
        }
        (visibleSettingsWindow ?? constellationWindow())?.makeKeyAndOrderFront(nil)
    }

    nonisolated static func preferredPrimarySnapshot(
        from snapshots: [OhiaRunningApplicationSnapshot]
    ) -> OhiaRunningApplicationSnapshot? {
        let candidates = snapshots.filter(isOhiaApplication)
        let canonicalCandidates = candidates.filter {
            $0.bundleIdentifier == canonicalBundleIdentifier
        }
        let preferredPool = canonicalCandidates.isEmpty ? candidates : canonicalCandidates
        return preferredPool.sorted(by: shouldPrefer).first
    }

    nonisolated static func currentIsSecondary(
        snapshots: [OhiaRunningApplicationSnapshot],
        currentProcessID: pid_t
    ) -> Bool {
        guard let preferred = preferredPrimarySnapshot(from: snapshots) else { return false }
        return preferred.processIdentifier != currentProcessID
    }

    @MainActor
    static func primaryApplicationIfCurrentIsSecondary() -> NSRunningApplication? {
        let current = NSRunningApplication.current
        let applications = runningOhiaApplicationsIncludingCurrent()
        let snapshotsByPID = Dictionary(
            uniqueKeysWithValues: applications.map {
                ($0.processIdentifier, OhiaRunningApplicationSnapshot($0))
            }
        )
        guard currentIsSecondary(
            snapshots: Array(snapshotsByPID.values),
            currentProcessID: current.processIdentifier
        ),
              let primarySnapshot = preferredPrimarySnapshot(from: Array(snapshotsByPID.values))
        else {
            return nil
        }
        return applications.first {
            $0.processIdentifier == primarySnapshot.processIdentifier
        }
    }

    @MainActor
    static func duplicateApplicationsForCurrentPrimary() -> [NSRunningApplication] {
        let current = NSRunningApplication.current
        let applications = runningOhiaApplicationsIncludingCurrent()
        let snapshots = applications.map(OhiaRunningApplicationSnapshot.init)
        guard let primarySnapshot = preferredPrimarySnapshot(from: snapshots),
              primarySnapshot.processIdentifier == current.processIdentifier
        else {
            return []
        }
        return applications.filter {
            $0.processIdentifier != current.processIdentifier
                && isOhiaApplication(OhiaRunningApplicationSnapshot($0))
        }
    }

    @MainActor
    static func installOAuthRedirectHandoffObserver() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: oauthRedirectHandoffNotification,
            object: nil,
            queue: .main
        ) { notification in
            let rawURL = notification.object as? String
            Task { @MainActor in
                if handleOAuthRedirectHandoffObject(rawURL) {
                    // The redirect was forwarded by a secondary instance that
                    // is terminating; cross-process activation from it is
                    // unreliable, so the primary presents its window the
                    // moment it actually consumes the redirect.
                    presentOAuthReturn()
                }
            }
        }
    }

    @MainActor
    @discardableResult
    static func handleOAuthRedirectHandoffObject(
        _ object: Any?,
        handleURL: @escaping @MainActor (URL) -> Void = OAuthCoordinator.handleIncomingURL
    ) -> Bool {
        guard let rawURL = object as? String,
              let url = URL(string: rawURL),
              isOAuthRedirectURL(url)
        else {
            return false
        }
        handleURL(url)
        return true
    }

    @MainActor
    static func forwardOAuthRedirectsToPrimaryIfNeeded(
        _ urls: [URL]
    ) -> NSRunningApplication? {
        let handoffObjects = oauthRedirectHandoffObjects(for: urls)
        guard !handoffObjects.isEmpty else {
            return nil
        }
        guard let primary = primaryApplicationIfCurrentIsSecondary() else {
            return nil
        }
        for rawURL in handoffObjects {
            DistributedNotificationCenter.default().postNotificationName(
                oauthRedirectHandoffNotification,
                object: rawURL,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return primary
    }

    // Deep links (`ohia://message/<uuid>`) get the identical forwarding
    // treatment as OAuth redirects, kept as a fully separate notification
    // name and function pair rather than folded into the OAuth ones above:
    // those are named, tested, and reasoned about as OAuth-specific, and a
    // deep link is not an OAuth redirect. The underlying race this guards
    // against is the same one the doc comment on `OhiaAppDelegate` already
    // describes — a stale DerivedData build can still be the registered
    // handler for the "ohia" scheme and catch a click meant for the running
    // instance.
    nonisolated private static let deepLinkHandoffNotification =
        Notification.Name("org.jgkarlin.Ohia.deepLinkHandoff")

    nonisolated static func isOhiaDeepLinkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == OhiaDeepLink.scheme
    }

    nonisolated static func deepLinkHandoffObjects(for urls: [URL]) -> [String] {
        urls.filter(isOhiaDeepLinkURL).map(\.absoluteString)
    }

    @MainActor
    static func forwardDeepLinksToPrimaryIfNeeded(
        _ urls: [URL]
    ) -> NSRunningApplication? {
        let handoffObjects = deepLinkHandoffObjects(for: urls)
        guard !handoffObjects.isEmpty else {
            return nil
        }
        guard let primary = primaryApplicationIfCurrentIsSecondary() else {
            return nil
        }
        for rawURL in handoffObjects {
            DistributedNotificationCenter.default().postNotificationName(
                deepLinkHandoffNotification,
                object: rawURL,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return primary
    }

    @MainActor
    static func installDeepLinkHandoffObserver() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: deepLinkHandoffNotification,
            object: nil,
            queue: .main
        ) { notification in
            let rawURL = notification.object as? String
            Task { @MainActor in
                if handleDeepLinkHandoffObject(rawURL) {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
            }
        }
    }

    @MainActor
    @discardableResult
    static func handleDeepLinkHandoffObject(
        _ object: Any?,
        handleMessageID: @escaping @MainActor (UUID) -> Void = AppCommand.requestDeepLinkTimelineFocus
    ) -> Bool {
        guard let rawURL = object as? String,
              let url = URL(string: rawURL),
              let messageID = OhiaDeepLink.messageID(from: url)
        else {
            return false
        }
        handleMessageID(messageID)
        return true
    }

    @MainActor
    static func registerCanonicalBundleAsOAuthURLHandler() {
        guard Bundle.main.bundleIdentifier == canonicalBundleIdentifier else {
            return
        }
        let bundleURL = Bundle.main.bundleURL
        for scheme in oauthURLSchemes {
            NSWorkspace.shared.setDefaultApplication(
                at: bundleURL,
                toOpenURLsWithScheme: scheme
            ) { error in
                if let error {
                    print("[Ohia] failed to claim OAuth URL scheme \(scheme): \(String(reflecting: type(of: error)))")
                }
            }
        }
    }

    @MainActor
    private static func runningOhiaApplicationsIncludingCurrent() -> [NSRunningApplication] {
        let current = NSRunningApplication.current
        var applications = NSWorkspace.shared.runningApplications.filter {
            isOhiaApplication(OhiaRunningApplicationSnapshot($0))
        }
        if !applications.contains(where: { $0.processIdentifier == current.processIdentifier }) {
            applications.append(current)
        }
        return applications
    }

    nonisolated private static func shouldPrefer(
        _ lhs: OhiaRunningApplicationSnapshot,
        _ rhs: OhiaRunningApplicationSnapshot
    ) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }
}

struct OhiaStoreCompatibilityMarker: Codable, Equatable, Sendable {
    let generation: Int
    let schemaFingerprint: String
}

enum OhiaStoreCompatibilityError: Error, Equatable, LocalizedError {
    case storeCreatedByNewerGeneration(stored: Int, current: Int)
    case schemaChangedWithoutGenerationBump(generation: Int)

    var errorDescription: String? {
        switch self {
        case let .storeCreatedByNewerGeneration(stored, current):
            return "The Ohia store belongs to compatibility generation \(stored), but this build only supports generation \(current)."
        case let .schemaChangedWithoutGenerationBump(generation):
            return "The SwiftData schema changed without advancing compatibility generation \(generation)."
        }
    }
}

enum OhiaStoreCompatibilityGate {
    // Advance this value whenever OhiaSchema changes. A schema-changing build
    // with the same generation is rejected before SwiftData can open the store.
    static let currentGeneration = 2026100701

    static func marker(for schema: Schema) -> OhiaStoreCompatibilityMarker {
        OhiaStoreCompatibilityMarker(
            generation: currentGeneration,
            schemaFingerprint: schemaFingerprint(schema)
        )
    }

    static func markerURL(for storeURL: URL) -> URL {
        storeURL.appendingPathExtension("compatibility.json")
    }

    static func claim(
        current: OhiaStoreCompatibilityMarker,
        storeExists: Bool,
        markerURL: URL
    ) throws {
        if storeExists, let stored = try loadMarker(at: markerURL) {
            if stored.generation > current.generation {
                throw OhiaStoreCompatibilityError.storeCreatedByNewerGeneration(
                    stored: stored.generation,
                    current: current.generation
                )
            }
            if stored.generation == current.generation,
               stored.schemaFingerprint != current.schemaFingerprint {
                throw OhiaStoreCompatibilityError.schemaChangedWithoutGenerationBump(
                    generation: current.generation
                )
            }
        }

        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(current).write(to: markerURL, options: .atomic)
    }

    static func loadMarker(at markerURL: URL) throws -> OhiaStoreCompatibilityMarker? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            OhiaStoreCompatibilityMarker.self,
            from: Data(contentsOf: markerURL)
        )
    }

    private static func schemaFingerprint(_ schema: Schema) -> String {
        var lines: [String] = []
        for entity in schema.entities.sorted(by: { $0.name < $1.name }) {
            lines.append("entity|\(entity.name)|super|\(entity.superentityName ?? "")")
            lines.append(contentsOf: entity.uniquenessConstraints
                .map { $0.sorted().joined(separator: ",") }
                .sorted()
                .map { "unique|\($0)" })
            lines.append(contentsOf: entity.indices
                .map { $0.sorted().joined(separator: ",") }
                .sorted()
                .map { "index|\($0)" })

            for property in entity.properties.sorted(by: { $0.name < $1.name }) {
                var parts = [
                    "property",
                    property.name,
                    property.originalName,
                    String(reflecting: property.valueType),
                    "optional=\(property.isOptional)",
                    "transient=\(property.isTransient)",
                    "unique=\(property.isUnique)",
                ]
                if let attribute = property as? Schema.Attribute {
                    parts.append("attribute")
                    parts.append("transformable=\(attribute.isTransformable)")
                    parts.append("hash=\(attribute.hashModifier ?? "")")
                } else if let relationship = property as? Schema.Relationship {
                    parts.append("relationship")
                    parts.append("destination=\(relationship.destination)")
                    parts.append("delete=\(relationship.deleteRule.rawValue)")
                    parts.append("inverse=\(relationship.inverseName ?? "")")
                    parts.append("minimum=\(relationship.minimumModelCount.map(String.init) ?? "")")
                    parts.append("maximum=\(relationship.maximumModelCount.map(String.init) ?? "")")
                    parts.append("hash=\(relationship.hashModifier ?? "")")
                }
                lines.append(parts.joined(separator: "|"))
            }
        }

        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum OhiaLaunchEnvironment {
    static var isRunningHostedTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

nonisolated enum OhiaLaunchMode: Equatable {
    case normal
    case hostedTests
    case secondaryInstance

    static func resolve(
        isRunningHostedTests: Bool,
        isSecondaryInstance: Bool,
        arguments _: [String]
    ) -> OhiaLaunchMode {
        if isRunningHostedTests {
            return .hostedTests
        }
        if isSecondaryInstance {
            return .secondaryInstance
        }
        return .normal
    }

    var initializesRuntime: Bool {
        self == .normal
    }

    var suppressesPrimaryWindow: Bool {
        self == .hostedTests || self == .secondaryInstance
    }

    var suppressesAuxiliaryWindows: Bool {
        self != .normal
    }
}

@MainActor
enum SentMailSoundNotificationBridge {
    static func install() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: .ohiaMailSendConfirmed,
            object: nil,
            queue: .main
        ) { notification in
            let payload = notification.object as? String
            Task { @MainActor in
                relay(payload: payload, to: .default)
            }
        }
    }

    /// The worker's hint carries only the opaque outbox row id. Validate it's a
    /// UUID and relay it; the app does the authoritative row lookup and playback
    /// gating, so a malformed or spoofed payload is dropped here or there.
    static func relay(
        payload: String?,
        to localCenter: NotificationCenter
    ) {
        guard let payload,
              let outboxItemID = UUID(uuidString: payload) else {
            return
        }
        localCenter.post(
            name: .ohiaMailSendConfirmed,
            object: nil,
            userInfo: [
                MailSendNotificationUserInfoKey.outboxItemID: outboxItemID.uuidString
            ]
        )
    }
}

/// Handles URL opens and single-instance activation.
///
/// Primary job: route any URL macOS delivers to us (including OAuth redirect
/// URLs registered in Info.plist's `CFBundleURLTypes`) to the
/// `OAuthCoordinator` for matching against a pending sign-in continuation.
///
/// Secondary job: if macOS launches a *second* instance of Ohia while
/// another is already running, the second instance activates the first
/// (forwarding any URLs it was launched with) and quits itself. This
/// fixes a common dev-mode headache where LaunchServices picks a stale
/// DerivedData path as the URL handler and spawns a new process instead
/// of delivering to the running Xcode-debug instance.
final class OhiaAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var oauthRedirectHandoffObserver: NSObjectProtocol?
    private var deepLinkHandoffObserver: NSObjectProtocol?
    private var sentMailSoundConfirmationObserver: NSObjectProtocol?
    private var secondaryTerminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OhiaLaunchEnvironment.isRunningHostedTests else {
            return
        }

        if let primary = OhiaSingleInstanceCoordinator.primaryApplicationIfCurrentIsSecondary() {
            print("[Ohia] another Ohia instance already running (pid=\(primary.processIdentifier), bundle=\(primary.bundleIdentifier ?? "unknown")) — activating it and waiting briefly for URL handoff")
            primary.activate(options: [.activateAllWindows])
            scheduleSecondaryTermination(after: 5)
            return
        }

        oauthRedirectHandoffObserver = OhiaSingleInstanceCoordinator
            .installOAuthRedirectHandoffObserver()
        deepLinkHandoffObserver = OhiaSingleInstanceCoordinator
            .installDeepLinkHandoffObserver()
        sentMailSoundConfirmationObserver = SentMailSoundNotificationBridge.install()
        OhiaSingleInstanceCoordinator.registerCanonicalBundleAsOAuthURLHandler()
        terminateDuplicateOhiaInstances()

        NewMailUserNotifier.requestAuthorization()
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            WindowMenuIconDecorator.install()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let primary = OhiaSingleInstanceCoordinator.forwardOAuthRedirectsToPrimaryIfNeeded(urls) {
            print("[Ohia] forwarding OAuth redirect to primary Ohia instance (pid=\(primary.processIdentifier))")
            primary.activate(options: [.activateAllWindows])
            scheduleSecondaryTermination(after: 0.25)
            return
        }
        if let primary = OhiaSingleInstanceCoordinator.forwardDeepLinksToPrimaryIfNeeded(urls) {
            print("[Ohia] forwarding deep link to primary Ohia instance (pid=\(primary.processIdentifier))")
            primary.activate(options: [.activateAllWindows])
            scheduleSecondaryTermination(after: 0.25)
            return
        }

        var handledOAuthRedirect = false
        var handledDeepLink = false
        for url in urls {
            if OhiaSingleInstanceCoordinator.isOAuthRedirectURL(url) {
                OAuthCoordinator.handleIncomingURL(url)
                handledOAuthRedirect = true
            } else if let messageID = OhiaDeepLink.messageID(from: url) {
                AppCommand.requestDeepLinkTimelineFocus(messageID: messageID)
                handledDeepLink = true
            }
        }

        // Activating the process alone can leave the onboarding window behind
        // the browser. Explicitly make the registered Constellation window key
        // when OAuth returns so the completed wizard is actually visible.
        if handledOAuthRedirect {
            OhiaSingleInstanceCoordinator.presentOAuthReturn()
        } else if handledDeepLink {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppQuitCoordinator.shared.applicationShouldTerminate()
    }

    private func scheduleSecondaryTermination(after seconds: TimeInterval) {
        secondaryTerminationTask?.cancel()
        secondaryTerminationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            NSApp.terminate(nil)
        }
    }

    private func terminateDuplicateOhiaInstances() {
        for duplicate in OhiaSingleInstanceCoordinator.duplicateApplicationsForCurrentPrimary() {
            print("[Ohia] terminating duplicate Ohia instance (pid=\(duplicate.processIdentifier), bundle=\(duplicate.bundleIdentifier ?? "unknown"))")
            _ = duplicate.terminate()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        switch NewMailUserNotifier.responseRoute(
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        ) {
        case .markRead(let ids):
            AppCommand.requestNotificationMarkRead(messageIDs: ids)
        case .openMessage(let messageID):
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            AppCommand.requestNotificationFocus(messageID: messageID)
        case .none:
            break
        }
        completionHandler()
    }
}

@MainActor
private struct OhiaRuntime {
    let modelContainer: ModelContainer
    let scheduler: BackgroundScheduler?
    let workerSupervisor: WorkerFleetSupervisor
    let messagesTranscriptBroker: MessagesTranscriptBroker
    let automaticMessagesAccessCoordinator: AutomaticMessagesAccessCoordinator
}

@MainActor
enum TrainingMenuCommandPolicy {
    static func requestImmediateRun(on state: TrainingRunState, at now: Date = .now) {
        state.isPaused = false
        state.forceRunRequested = true
        state.forceRunRequestedAt = now
    }

    @discardableResult
    static func applyPauseRequest(
        _ requestedPause: Bool?,
        to state: TrainingRunState
    ) -> Bool {
        state.isPaused = requestedPause ?? !state.isPaused
        return state.isPaused
    }
}

@main
struct OhiaApp: App {
    @NSApplicationDelegateAdaptor(OhiaAppDelegate.self) var appDelegate

    private let launchMode: OhiaLaunchMode
    private let runtime: OhiaRuntime?
    @State var workerStatuses = WorkerFleetStatusPublisher()
    @State private var startupSplashVisibility: StartupSplashVisibility
    @State var appServices: AppServices?
    @State var modelLoader: ModelLoadingService?
    @State var trainingStatusPublisher: TrainingStatusPublisher?
    @State var imapSessionManager: IMAPSessionManager?
    @State var constellationActiveMonitor: ConstellationActiveMonitor?
    @State var appActivityMonitor: SharedAppActivityMonitor?
    @State private var pipelinePauseState = PipelinePauseState()

    init() {
        let hostedTests = OhiaLaunchEnvironment.isRunningHostedTests
        let secondaryInstance = !hostedTests
            && OhiaSingleInstanceCoordinator.primaryApplicationIfCurrentIsSecondary() != nil
        let launchMode = OhiaLaunchMode.resolve(
            isRunningHostedTests: hostedTests,
            isSecondaryInstance: secondaryInstance,
            arguments: CommandLine.arguments
        )
        self.launchMode = launchMode
        let shouldGateSecondaryWindows = launchMode == .normal
            && OhiaSharedDefaults.store.bool(forKey: "hasCompletedOnboarding")
        self._startupSplashVisibility = State(initialValue: StartupSplashVisibility(
            isActive: shouldGateSecondaryWindows
        ))
        guard launchMode.initializesRuntime else {
            runtime = nil
            return
        }
        ComposerWordClasses.requestMissingData()

        let storageLayout = OhiaStorageRoot.required()
        let appPrivateRoot = OhiaStorageRoot.requiredAppPrivateRoot()
        do {
            var keychainLeftovers: [DeveloperCredentialResetter.Leftover] = []
            _ = try SandboxResetCoordinator.completePendingReset(
                sharedLayout: storageLayout,
                appPrivateRoots: [appPrivateRoot],
                prepareExternalStateForDeletion: {
                    keychainLeftovers = DeveloperCredentialResetter.resetAll()
                    DeveloperDefaultsResetter.resetAll()
                }
            )
            ResetCredentialCleanupNotice.schedule(leftovers: keychainLeftovers)
        } catch {
            fatalError("Failed to complete the pending Ohia reset: \(String(reflecting: type(of: error)))")
        }

        do {
            try SessionActivityLog.shared.startSession(directoryURL: storageLayout.workerState)
            SessionActivityLog.shared.record(SessionActivityEvent(operation: "Ohia launched", phase: .state))
        } catch {
            Logger(subsystem: "org.jgkarlin.Ohia", category: "activity-log")
                .error("Cannot start activity log: \(String(reflecting: type(of: error)), privacy: .public)")
        }

        let schema = Schema(OhiaSchema.models)
        let storeURL = storageLayout.swiftDataStore
        do {
            try OhiaStoreCompatibilityGate.claim(
                current: OhiaStoreCompatibilityGate.marker(for: schema),
                storeExists: FileManager.default.fileExists(atPath: storeURL.path),
                markerURL: OhiaStoreCompatibilityGate.markerURL(for: storeURL)
            )
        } catch {
            fatalError("Refusing to open an incompatible Ohia store: \(String(reflecting: type(of: error)))")
        }

        let modelContainer: ModelContainer
        do {
            try FileManager.default.createDirectory(
                at: storageLayout.privateRoot,
                withIntermediateDirectories: true
            )
            let config = ModelConfiguration("Ohia", schema: schema, url: storeURL)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(String(reflecting: type(of: error)))")
        }
        let messagesTranscriptBroker = MessagesTranscriptBroker(modelContainer: modelContainer)
        let mailCredentialBroker = MailCredentialBroker(modelContainer: modelContainer)
        let automaticMessagesAccessCoordinator = AutomaticMessagesAccessCoordinator { request in
            await AutomaticMessagesAccessCoordinator.retryAndMerge(
                request: request,
                broker: messagesTranscriptBroker,
                container: modelContainer
            )
        }
        messagesTranscriptBroker.setResultObserver { result, request in
            Task { @MainActor in
                automaticMessagesAccessCoordinator.record(result, for: request)
            }
        }
        let workerSupervisor = WorkerFleetSupervisor(
            mailCredentialBroker: mailCredentialBroker,
            messagesTranscriptBroker: messagesTranscriptBroker
        )
        runtime = OhiaRuntime(
            modelContainer: modelContainer,
            scheduler: nil,
            workerSupervisor: workerSupervisor,
            messagesTranscriptBroker: messagesTranscriptBroker,
            automaticMessagesAccessCoordinator: automaticMessagesAccessCoordinator
        )

        do {
            let migrated = try TranslationGlossaryCutoverApplier(
                modelContext: modelContainer.mainContext
            ).run()
            if migrated > 0 {
                print("[Ohia] Translation glossary cutover: migrated \(migrated) canonical dyad(s)")
            }
        } catch {
            print("[Ohia] Translation glossary cutover failed: \(String(reflecting: type(of: error)))")
        }

        // Initialize pipeline services
        do {
            ComposeAddressParsingInstall.install()

            let services = try AppServices(
                storageLayout: storageLayout,
                modelContext: modelContainer.mainContext,
                askMemoryProvider: StoredAccountMemoryProvider(container: modelContainer)
            )
            self._appServices = State(initialValue: services)
            self._trainingStatusPublisher = State(initialValue: services.trainingStatusPublisher)
            let isAppActive = NSApplication.shared.isActive
            let activityMonitor = SharedAppActivityMonitor(
                snapshotURL: SharedAppActivityMonitor.snapshotURL(
                    appSupportDirectory: storageLayout.workerCoordination
                ),
                initialSnapshot: AppActivitySnapshot(isAppFrontmost: isAppActive)
            )
            activityMonitor.recordAppFrontmost(isAppActive)
            // No reply is open at launch; clear one left by a previous run.
            activityMonitor.recordComposerOpenReply(nil)
            self._appActivityMonitor = State(initialValue: activityMonitor)

            // IMAP session manager — app-side fallback/on-demand IMAP.
            // Startup background IMAP is owned by the retrieval worker so the
            // app process does not duplicate OAuth + provider sign-in work.
            // Constructed here (not in AppServices, which lives in OhiaML and
            // can't depend on OhiaScheduler). OAuthTokenStore is stateless
            // w.r.t. construction — Keychain persistence handles cross-instance
            // consistency.
            let imapManager = IMAPSessionManager(
                modelContext: modelContainer.mainContext,
                oauthStore: OAuthTokenStore(allowKeychainInteraction: false),
                passwordResolver: mailCredentialBroker,
                canonicalStore: services.canonicalStore,
                vectorStore: services.vectorStore,
                neighborsStore: services.vectorNeighborsStore,
                frameLayoutStore: services.vectorFrameLayoutStore,
                clusterStore: services.vectorClusterStore,
                liveInboundBroadcaster: services.jobCompletionBroadcaster,
                deletionSyncStatusPublisher: services.deletionSyncStatusPublisher,
                onDetectedInbound: { messageIDs in
                    NewMailArrivalLedger.shared.registerDetected(messageIDs)
                },
                onManualProjectSourceChange: { messageIDs, facets in
                    guard let coordinator = services.manualProjectMembershipCoordinator else {
                        return
                    }
                    Task {
                        await coordinator.reconcile(
                            messageIDs: messageIDs,
                            changedFacets: facets
                        )
                    }
                }
            )
            self._imapSessionManager = State(initialValue: imapManager)

            // ConstellationActiveMonitor — lives in OhiaScheduler; constructed here
            // (not in AppServices which lives in OhiaML and cannot depend on OhiaScheduler).
            // A single local is wired to both the scheduler (adaptive cadence) and the
            // view environment (enter/leave lifecycle), so both see the same instance.
            let activeMonitor = ConstellationActiveMonitor(activityMonitor: activityMonitor)
            self._constellationActiveMonitor = State(initialValue: activeMonitor)

            // Idempotent Plan-2 migration: silently wire IMAP for OAuth
            // accounts whenever an SMTP OAuth token exists but IMAP fields
            // were not persisted yet. This must run on every launch because
            // a user can complete OAuth after an older one-shot migration flag
            // has already been set.
            do {
                let applier = AccountMigrationApplier(modelContext: modelContainer.mainContext)
                let migrated = try applier.run()
                if migrated > 0 {
                    print("[Ohia] Plan-2 IMAP migration: wired \(migrated) account(s)")
                }
            } catch {
                print("[Ohia] Plan-2 IMAP migration failed: \(String(reflecting: type(of: error)))")
            }

            if !UserDefaults.standard.bool(forKey: "ohia.identity-migration-v1.completed") {
                do {
                    let applier = IdentityMigrationApplier(modelContext: modelContainer.mainContext)
                    try applier.run()
                    print("[Ohia] Identity migration v1: seeded primary identities")
                    UserDefaults.standard.set(true, forKey: "ohia.identity-migration-v1.completed")
                } catch {
                    print("[Ohia] Identity migration failed: \(String(reflecting: type(of: error)))")
                }
            }

            do {
                let inferred = try AuthenticatedSendAliasIdentityApplier(modelContext: modelContainer.mainContext).run()
                if inferred > 0 {
                    print("[Ohia] Authenticated send-alias inference: seeded \(inferred) identity row(s)")
                }
            } catch {
                print("[Ohia] Authenticated send-alias inference failed: \(String(reflecting: type(of: error)))")
            }

            // Signature-slot migration must follow the identity appliers —
            // it reads Identity.legacySignature off rows they seed.
            do {
                let seeded = try SignatureSlotMigrationApplier(modelContext: modelContainer.mainContext).run()
                if seeded > 0 {
                    print("[Ohia] Signature-slot migration v1: seeded \(seeded) slot(s)")
                }
            } catch {
                print("[Ohia] Signature-slot migration failed: \(String(reflecting: type(of: error)))")
            }

            do {
                let repaired = try AliasSentDirectionRepairApplier(modelContext: modelContainer.mainContext).run()
                if repaired > 0 {
                    print("[Ohia] Alias sent-direction repair: updated \(repaired) message row(s)")
                }
            } catch {
                print("[Ohia] Alias sent-direction repair failed: \(String(reflecting: type(of: error)))")
            }

            do {
                let assigned = try AccountColorMigrationApplier(modelContext: modelContainer.mainContext).run()
                if assigned > 0 {
                    print("[Ohia] AccountColor migration v1: assigned \(assigned) account color(s)")
                }
            } catch {
                print("[Ohia] AccountColor migration failed: \(String(reflecting: type(of: error)))")
            }

            // Heavy pipeline/model work is owned by the worker fleet. The UI
            // process keeps shared stores and lightweight publishers only; it
            // does not construct an in-process scheduler or model loader.
            self._modelLoader = State(initialValue: nil)
        } catch {
            print("[Ohia] Failed to initialize AppServices: \(String(reflecting: type(of: error)))")
            self._appServices = State(initialValue: nil)
            self._modelLoader = State(initialValue: nil)
            self._imapSessionManager = State(initialValue: nil)
            self._constellationActiveMonitor = State(initialValue: nil)
            self._appActivityMonitor = State(initialValue: nil)
        }
    }

    var body: some Scene {
        // `Window` (vs. `WindowGroup`) gives each app surface exactly one
        // reopenable window. The Constellation window remains the lifecycle
        // host for onboarding, splash, worker status, and app-wide command
        // observers.
        Window("Constellation", id: OhiaWindowID.constellation) {
            rootSceneContent
                .registerSceneWindow(id: OhiaWindowID.constellation)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(launchMode.suppressesPrimaryWindow ? .suppressed : .automatic)
        .keyboardShortcut("1", modifiers: [.command])
        .commands { OhiaMenuCommands() }

        Window("Composer", id: OhiaWindowID.composer) {
            composerSceneContent
                .registerSceneWindow(id: OhiaWindowID.composer)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .keyboardShortcut("2", modifiers: [.command])

        // macOS Settings scene — bound to ⌘, automatically.
        Settings {
            settingsSceneContent
                .registerSceneWindow(id: OhiaSingleInstanceCoordinator.settingsWindowID)
        }
    }

    @ViewBuilder
    private var rootSceneContent: some View {
        if let runtime {
            RootView(
                scheduler: runtime.scheduler,
                modelLoader: modelLoader,
                workerSupervisor: runtime.workerSupervisor,
                workerStatuses: workerStatuses,
                startupSplashVisibility: startupSplashVisibility,
                appActivityMonitor: appActivityMonitor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .environment(modelLoader)
            .environment(appServices)
            .environment(workerStatuses)
            .environment(trainingStatusPublisher)
            .environment(appServices?.deletionSyncStatusPublisher)
            .environment(imapSessionManager)
            .environment(constellationActiveMonitor)
            .environment(pipelinePauseState)
            .environment(\.messagesTranscriptBroker, runtime.messagesTranscriptBroker)
            .environment(runtime.automaticMessagesAccessCoordinator)
            .environment(\.workerFleetSupervisor, runtime.workerSupervisor)
            .modelContainer(runtime.modelContainer)
            .applyAppearancePreference()
            .applyReadingTextSizePreference()
            .modifier(AppWindowCommandBridge())
            .hidesWindowInsteadOfClosing()
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var composerSceneContent: some View {
        if let runtime {
            StartupSplashDeferredWindow(visibility: startupSplashVisibility) {
                ComposerWindowShellView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(appServices)
                    .environment(workerStatuses)
                    .environment(modelLoader)
                    .environment(trainingStatusPublisher)
                    .environment(\.messagesTranscriptBroker, runtime.messagesTranscriptBroker)
                    .environment(runtime.automaticMessagesAccessCoordinator)
                    .modelContainer(runtime.modelContainer)
                    .applyAppearancePreference()
                    .applyReadingTextSizePreference()
                    .modifier(AppWindowCommandBridge())
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var settingsSceneContent: some View {
        if let runtime {
            StartupSplashDeferredWindow(visibility: startupSplashVisibility) {
                SettingsView()
                    .environment(modelLoader)
                    .environment(appServices)
                    .environment(workerStatuses)
                    .environment(trainingStatusPublisher)
                    .environment(imapSessionManager)
                    .environment(pipelinePauseState)
                    .environment(\.messagesTranscriptBroker, runtime.messagesTranscriptBroker)
                    .environment(\.workerFleetSupervisor, runtime.workerSupervisor)
                    .modelContainer(runtime.modelContainer)
                    .applyAppearancePreference()
                    .applyReadingTextSizePreference()
                    .modifier(AppWindowCommandBridge())
            }
        } else {
            EmptyView()
        }
    }

}

private struct StartupSplashDeferredWindow<Content: View>: View {
    let visibility: StartupSplashVisibility
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if visibility.isActive {
                Color.clear
                    .frame(minWidth: 1, minHeight: 1)
                    .accessibilityHidden(true)
            } else {
                content()
            }
        }
        .suppressesWindowVisibility(while: visibility.isActive)
    }
}

enum MeetingCalendarLifecyclePolicy {
    static func shouldReconcile(
        isEnabled: Bool,
        hasWriteAccess: Bool,
        reconciliationInFlight: Bool,
        hasAttemptedInitialReconcile: Bool,
        readyMessageIDs: Set<UUID>,
        lastAttemptedReadyMessageIDs: Set<UUID>
    ) -> Bool {
        isEnabled
            && hasWriteAccess
            && reconciliationInFlight == false
            && (hasAttemptedInitialReconcile == false
                || readyMessageIDs.subtracting(lastAttemptedReadyMessageIDs).isEmpty == false)
    }

    static func shouldResetAttemptState(
        previousHasWriteAccess: Bool?,
        hasWriteAccess: Bool
    ) -> Bool {
        previousHasWriteAccess == false && hasWriteAccess
    }
}

private struct MeetingCalendarLifecycleFingerprint: Hashable {
    let isEnabled: Bool
    let defaultLeadTimeRaw: String
    let reminderHour: Int
}

struct RootView: View {
    let scheduler: BackgroundScheduler?
    let modelLoader: ModelLoadingService?
    let workerSupervisor: WorkerFleetSupervisor
    let workerStatuses: WorkerFleetStatusPublisher
    let startupSplashVisibility: StartupSplashVisibility
    let appActivityMonitor: SharedAppActivityMonitor?

    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage(
        OnboardingPipelineGate.hasReachedWitnessPanelKey,
        store: OhiaSharedDefaults.store
    )
    private var hasReachedOnboardingWitnessPanel = false
    @AppStorage(
        OnboardingPipelineGate.hasRequestedModelPreparationKey,
        store: OhiaSharedDefaults.store
    )
    private var hasRequestedOnboardingModelPreparation = false
    @AppStorage("constellationShortcutActiveFrame")
    private var constellationActiveFrameRaw = FrameKey.frontPage.rawValue
    @AppStorage("constellationFrameDisplayed")
    private var constellationFrameDisplayedRaw = FrameKey.visibleSpatialFrames
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
    @AppStorage(DeadlineReminderSettings.syncEnabledKey)
    private var deadlineCalendarSyncEnabled = DeadlineReminderSettings.defaultSyncEnabled
    @AppStorage(DeadlineReminderSettings.meetingSyncEnabledKey)
    private var meetingCalendarSyncEnabled = DeadlineReminderSettings.defaultMeetingSyncEnabled
    @AppStorage(DeadlineReminderSettings.defaultLeadTimeKey)
    private var calendarDefaultLeadTimeRaw = DeadlineReminderSettings.defaultLeadTime.rawValue
    @AppStorage(DeadlineReminderSettings.reminderHourKey)
    private var calendarReminderHour = DeadlineReminderSettings.defaultReminderHour
    @State private var showSplash = true
    /// Process-lived, non-observable orchestration state. Worker heartbeats
    /// mutate this reference without invalidating RootView; only semantic
    /// presentation changes are published through `workerStatuses`.
    @State private var workerStatusRefresh = WorkerStatusRefreshCoordinator()
    @State private var appActivityHeartbeatTask: Task<Void, Never>?
    /// Process-scoped (static), NOT view-scoped: the loop deliberately
    /// survives main-window close so arrival alerts keep firing while only
    /// the Composer is open. If this were `@State`, a window reopen whose
    /// view state was regenerated would see `nil`, start a second loop, and
    /// — worse — re-`beginSession` the arrival ledger while the first loop
    /// is still alive, wiping the announced set and replaying sounds,
    /// notifications, and dock-badge increments for every recent arrival.
    @MainActor private static var liveInboundReconcileTask: Task<Void, Never>?
    @MainActor private static var liveInboundReconcileSessionID: UUID?
    private static let liveInboundReconciliationWorker = LiveInboundReconciliationWorker()
    @MainActor private static var meetingCalendarReconcileTask: Task<Void, Never>?
    @MainActor private static var meetingCalendarLastObservedFingerprint: MeetingCalendarLifecycleFingerprint?
    @MainActor private static var meetingCalendarLastObservedWriteAccess: Bool?
    @MainActor private static var meetingCalendarHasAttemptedInitialReconcile = false
    @MainActor private static var meetingCalendarLastAttemptedReadyMessageIDs: Set<UUID> = []
    @State private var activityEventMonitor: Any?
    /// Mirrors whether the Composer is the mounted shell surface. Carried
    /// into every app-activity snapshot write so the generative worker can
    /// grant Composer drafting foreground access to the model.
    @State private var composerSurfaceActive = false

    private struct MeaningLensActivityFingerprint: Equatable {
        let enabled: Bool
        let active: Bool
    }

    private var meaningLensActivityFingerprint: MeaningLensActivityFingerprint {
        let enabled = MeaningLensDemandPolicy.isEnabled(
            displayedFrameRawValues: constellationFrameDisplayedRaw
        )
        return MeaningLensActivityFingerprint(
            enabled: enabled,
            active: enabled && MeaningLensDemandPolicy.isActive(
                activeFrame: FrameKey(rawValue: constellationActiveFrameRaw),
                displayedFrameRawValues: constellationFrameDisplayedRaw
            )
        )
    }

    private var meetingCalendarLifecycleFingerprint: MeetingCalendarLifecycleFingerprint {
        MeetingCalendarLifecycleFingerprint(
            isEnabled: meetingCalendarSyncEnabled,
            defaultLeadTimeRaw: calendarDefaultLeadTimeRaw,
            reminderHour: calendarReminderHour
        )
    }
    @State private var loggedWorkerResourceSignatures: [WorkerRole: String] = [:]
    @State private var pipelineDesired = false
    @State private var appIMAPFallbackActive = false
    @State private var newMailAlertSoundPlayer = NewStarAlertSoundPlayer()
    @State private var sentMailSoundPlayer = NewStarAlertSoundPlayer()
    @State private var notificationMarkReadObserver: NSObjectProtocol?
    @State private var messageAttentionChangedObserver: NSObjectProtocol?
    @State private var splashCanDismiss = false
    @State private var splashTimeoutTask: Task<Void, Never>?
    /// Maximum time the splash will wait for both workers to reach a stable
    /// model-load state. After this elapses the splash dismisses regardless
    /// — the user-facing app should never block longer than this on first
    /// paint, even if the Qwen model is mid-download or a worker is stuck.
    private static let splashMaxWait: TimeInterval = 12
    private static let workerHeartbeatMaxAge: TimeInterval = 15
    private static let liveInboundReconcileInterval: TimeInterval = 2
    /// Recent pre-session rows polled for silent acknowledgement. Current
    /// session live rows are polled from session start so slow pipeline
    /// completions can still trigger their unified announcement.
    private static let liveInboundReconcileLookback: TimeInterval = 15 * 60
    /// Row cap passed to `recentLiveInboundRows`.
    private static let liveInboundReconcileRowLimit = 200
    /// First-observed staged-but-unannounced time per message. The normal
    /// path waits for the active lens to render the message before alerting
    /// (`acknowledgeRenderedLiveInboundMessages`), so the alert and the
    /// navigable node land in the same moment. But a lens render witness can
    /// fail to arrive — the message doesn't survive the active lens's own
    /// candidate/selection filtering, an upstream data gap leaves it
    /// unrenderable, the window isn't frontmost, etc. Ohia is a mail client
    /// first: a missed render witness must never mean a missed notification.
    /// Process-scoped for the same reason as `liveInboundReconcileTask`.
    @MainActor private static var stagedSinceByMessageID: [UUID: Date] = [:]
    /// How long the reconciler waits for the render witness before firing
    /// the alert on pipeline-readiness alone. Generous enough that the
    /// common case (render witness lands within ~1s, per instrumented
    /// testing) never engages the fallback, short enough that no arrival
    /// ever waits longer than this for its sound/badge/notification.
    private static let liveInboundFallbackAlertTimeout: TimeInterval = 30

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(TrainingStatusPublisher.self) private var trainingStatusPublisher: TrainingStatusPublisher?
    @Environment(IMAPSessionManager.self) private var imapSessionManager: IMAPSessionManager?
    @Environment(ConstellationActiveMonitor.self) private var constellationActiveMonitor: ConstellationActiveMonitor?
    private static let modelLogger = Logger(subsystem: "org.jgkarlin.Ohia", category: "models")
    private static let arrivalLogger = Logger(subsystem: "com.ohia.app", category: "LiveInboundArrival")
    private static let calendarLogger = Logger(
        subsystem: "org.jgkarlin.Ohia",
        category: "DeadlineCalendarLifecycle"
    )

    var body: some View {
        lifecycleContent
        .modifier(LiveInboundRenderedObserver(onRender: handleLiveInboundRendered))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncAppActivitySnapshot(recordInteraction: true)
            reflectManagedCalendarDeletionIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: DeadlineCalendarSync.calendarStoreDidChangeNotification
            )
        ) { _ in
            reflectManagedCalendarDeletionIfNeeded()
        }
        .task { reflectManagedCalendarDeletionIfNeeded() }
        .task {
            // Consume any sent confirmations whose wake-up hint was dropped while
            // the app wasn't listening (suspended, not yet launched, or a lost
            // distributed notification), so a missed chime self-heals at launch.
            guard hasCompletedOnboarding else { return }
            sweepPendingSentConfirmations()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            syncAppActivitySnapshot(forceFrontmost: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
            syncAppActivitySnapshot(forceFrontmost: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)) { _ in
            syncAppActivitySnapshot(recordInteraction: true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            syncAppActivitySnapshot(forceFrontmost: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            syncAppActivitySnapshot()
        }
        .modifier(ComposerSurfaceActivityObserver(
            onChange: { active in
                composerSurfaceActive = active
                syncAppActivitySnapshot()
            },
            onOpenReplyChange: { messageID in
                appActivityMonitor?.recordComposerOpenReply(messageID)
            }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .ohiaShowOutbox)) { _ in
            guard hasCompletedOnboarding else { return }
            // The Composer queue is the outbox — open it instead of a Settings tab.
            AppCommand.showComposer()
            openWindow(id: OhiaWindowID.composer)
        }
        .modifier(SettingsTabOpeningObserver(
            notification: .ohiaShowSubscriptions,
            tabRawValue: "subscriptions",
            isEnabled: hasCompletedOnboarding,
            openSettings: { openSettings() }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .ohiaSendAllOutboxNow)) { _ in
            guard hasCompletedOnboarding else { return }
            _ = workerSupervisor.start(roles: [.bge])
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaMailSendConfirmed)) { notification in
            guard hasCompletedOnboarding else { return }
            let outboxItemID = notification.userInfo?[MailSendNotificationUserInfoKey.outboxItemID] as? String
            consumeSentConfirmation(outboxItemIDString: outboxItemID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaReauthenticateAccount)) { _ in
            guard hasCompletedOnboarding else { return }
            UserDefaults.standard.set("accounts", forKey: "selectedSettingsTab")
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaTrainingTrainNow)) { _ in
            guard let services = appServices else { return }
            let state = TrainingRunState.current(context: modelContext)
            let previousPaused = state.isPaused
            let previousForceRunRequested = state.forceRunRequested
            let previousForceRunRequestedAt = state.forceRunRequestedAt
            TrainingMenuCommandPolicy.requestImmediateRun(on: state)
            do {
                try modelContext.save()
            } catch {
                state.isPaused = previousPaused
                state.forceRunRequested = previousForceRunRequested
                state.forceRunRequestedAt = previousForceRunRequestedAt
                services.trainingStatusPublisher.recordError(
                    "Could not request training: \(error.localizedDescription)"
                )
                return
            }
            services.trainingStatusPublisher.reflectPauseToggle(false)
            _ = workerSupervisor.start(roles: [.bge, .qwen])
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaTrainingResetToBase)) { _ in
            workerSupervisor.requestGenerativeWorkerCommand(
                .resetTrainingToBase,
                message: "reset training to base requested"
            )
            _ = workerSupervisor.start(roles: [.qwen])
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaTrainingStop)) { _ in
            workerSupervisor.requestGenerativeWorkerCommand(
                .cancelTraining,
                message: "training stop requested"
            )
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaTrainingTogglePause)) { note in
            Task { @MainActor in
                guard let services = appServices else { return }
                let state = TrainingRunState.current(context: modelContext)
                let previousPaused = state.isPaused
                let isPaused = TrainingMenuCommandPolicy.applyPauseRequest(
                    TrainingMenuCommandRequest.requestedPause(from: note),
                    to: state
                )
                do {
                    try modelContext.save()
                } catch {
                    state.isPaused = previousPaused
                    services.trainingStatusPublisher.recordError(
                        "Could not update training pause: \(error.localizedDescription)"
                    )
                    return
                }
                services.trainingStatusPublisher.reflectPauseToggle(isPaused)
                // Pausing mid-run should stop the current training, not just
                // prevent the next one. The Generative Worker owns Qwen, so the
                // UI sends a worker command instead of touching a local engine.
                if isPaused {
                    workerSupervisor.requestGenerativeWorkerCommand(
                        .cancelTraining,
                        message: "training paused"
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaOpenTrainingSettings)) { _ in
            UserDefaults.standard.set("training", forKey: "selectedSettingsTab")
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaEnsureGenerativeWorker)) { _ in
            startGenerativeWorkerForModelPreparation()
        }
        .modifier(MCPEnvironmentRefreshObserver(
            onRefresh: { workerSupervisor.refreshGenerativeWorkerMCPEnvironment() }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .ohiaPrepareOnboardingModels)) { note in
            startOnboardingReadyModelPreparation(
                modelID: note.userInfo?["modelID"] as? String
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaSelectGenerationModel)) { note in
            guard let modelID = note.userInfo?["modelID"] as? String,
                  ModelManager.allModels.contains(where: { $0.modelId == modelID })
            else { return }
            let mode = ModelManager.recommendedPairForCurrentHardware().mode(for: modelID) ?? .quality
            let activeModelID = ModelManager.selectedGenerationModelID()
                ?? ModelManager.selectedGenerationModelForCurrentHardware().modelId
            if activeModelID == modelID {
                ModelManager.clearPendingGenerationModel()
            } else {
                ModelManager.setPendingGenerationModelID(modelID, mode: mode)
            }
            workerSupervisor.requestGenerativeModelSelection(modelID)
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaCancelGenerationModelPreparation)) { note in
            let modelID = note.userInfo?["modelID"] as? String
            workerSupervisor.requestGenerativeModelPreparationCancellation(modelID)
            requestWorkerStatusRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaComposeNew)) { _ in
            guard hasCompletedOnboarding else { return }
            AppCommand.showComposer()
            openWindow(id: OhiaWindowID.composer)
            AppCommand.requestComposerNewMessage()
        }
    }

    /// The Constellation root is Ohia's application-lifecycle host, so managed
    /// calendar deletion is observed even when neither Deadlines nor Settings
    /// is visible. The deletion remains unacknowledged until durable event
    /// links clear, allowing a later lifecycle notification to retry safely.
    private func reflectManagedCalendarDeletionIfNeeded() {
        guard (deadlineCalendarSyncEnabled || meetingCalendarSyncEnabled),
              DeadlineCalendarSync.managedCalendarWasDeleted() else {
            return
        }

        let sync = DeadlineCalendarSync(modelContext: modelContext)
        do {
            try ManagedCalendarDeletionCoordinator.clearLinksAndAcknowledge(
                clearLinks: {
                    try sync.clearEventLinksAfterManagedCalendarDeletion()
                },
                acknowledge: {
                    DeadlineCalendarSync.acknowledgeManagedCalendarDeletion()
                }
            )
        } catch {
            Self.calendarLogger.error(
                "Could not clear deleted-calendar event links: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            return
        }
        deadlineCalendarSyncEnabled = false
        meetingCalendarSyncEnabled = false
    }

    private var lifecycleContent: some View {
        ZStack {
            if !hasCompletedOnboarding {
                OnboardingView()
            } else if !showSplash {
                // The lens appears *instantly* beneath the fading splash
                // (`.transition(.identity)`) so its content — e.g. the Front Page
                // cards — renders at its own pace and is not gated by the long
                // splash dissolve. The gradual fade is the splash leaving on top,
                // not the lens arriving.
                MainShellView()
                    .transition(.identity)
            }

            // The splash sits on top and cross-dissolves into the lens over a
            // long, gradual fade. Its starfield is the same deterministic field
            // the lens draws, so the night sky reads as continuous through the
            // hand-off (identical-over-identical composites to itself); only the
            // ʻōhiʻa mark + text visibly fade, while the lens's content shows
            // through underneath as it settles.
            if hasCompletedOnboarding && showSplash {
                SplashView(
                    onFinished: { showSplash = false },
                    canDismiss: splashCanDismiss,
                    maximumVisibleDuration: Self.splashMaxWait
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: hasCompletedOnboarding)
        .animation(.easeInOut(duration: 1.8), value: showSplash)
        .onChange(of: hasCompletedOnboarding) { _, newValue in
            updateStartupSplashVisibility()
            if newValue {
                startPipelinePreparation()
                requestWorkerStatusRefresh()
                // The splash appears next render. Use the same model
                // warm-up gate as normal startup. During onboarding, the
                // workers may now prepare messages before the witness panel,
                // but visible constellation placement remains gated until the
                // witness view appears.
                if showSplash {
                    resetSplashGate()
                }
            } else {
                // Onboarding flipped back to false — almost always the
                // developer reset. Tear the pipeline down so in-flight
                // work doesn't keep writing into a database that's about
                // to be wiped (or has just been wiped). The matching
                // restart happens when the user finishes the next
                // onboarding pass and `hasCompletedOnboarding` flips true
                // again.
                stopPipeline()
                cancelSplashTimeout()
                showSplash = true
                splashCanDismiss = false
                updateStartupSplashVisibility()
                hasReachedOnboardingWitnessPanel = false
                hasRequestedOnboardingModelPreparation = false
            }
        }
        .onChange(of: showSplash) { _, newValue in
            updateStartupSplashVisibility()
            if !newValue {
                cancelSplashTimeout()
            }
        }
        .onChange(of: hasReachedOnboardingWitnessPanel) { _, newValue in
            syncAppActivitySnapshot()
            guard newValue, hasCompletedOnboarding else { return }
            startPipeline()
        }
        .onChange(of: hasCompletedFirstIngestion) { _, newValue in
            syncAppActivitySnapshot()
            if workerSupervisor.processState(for: .bge) == .running {
                stopAppIMAPFallback(clearStatuses: true)
            } else if appIMAPFallbackActive || !workerSupervisor.isEnabled {
                startAppIMAPFallback()
            }
            if newValue {
                requestWorkerStatusRefresh()
            }
        }
        .onChange(of: meaningLensActivityFingerprint, initial: true) {
            syncAppActivitySnapshot()
        }
        .modifier(PipelinePauseObserver(
            scheduler: scheduler,
            workerSupervisor: workerSupervisor,
            onPause: { pipelineDesired = false },
            onResume: { pipelineDesired = true }
        ))
        .task(id: meetingCalendarLifecycleFingerprint) {
            await handleMeetingCalendarLifecycleChange()
        }
        .onAppear {
            updateStartupSplashVisibility()
            installActivityMonitoring()
            startAppActivityHeartbeat()
            startWorkerStatusRefresh()
            installNotificationMarkReadObserver()
            installMessageAttentionChangedObserver()
            handlePendingNotificationMarkReadIfNeeded()
            startLiveInboundReconciler()
            AppQuitCoordinator.shared.registerCleanup(
                { await prepareForTermination() },
                timeoutDiagnostics: { workerSupervisor.pendingQuitStopRoles }
            )
            if hasCompletedOnboarding {
                if hasCompletedFirstIngestion || hasReachedOnboardingWitnessPanel {
                    startPipeline()
                } else {
                    startPipelinePreparation()
                }
                if showSplash {
                    resetSplashGate()
                }
            } else {
                hasRequestedOnboardingModelPreparation = false
            }
        }
        .onDisappear {
            // The main window closing is NOT app termination: the Composer
            // (its own Window scene) and Settings stay open and depend on
            // the worker fleet, the shared activity heartbeat, and live
            // reconciliation. Killing the backend here orphaned Composer
            // jobs the moment the main window went away. Process-level
            // teardown lives in `prepareForTermination` (registered with
            // AppQuitCoordinator in onAppear); only main-window-scoped UI
            // observers unwind here. Every start call in onAppear is
            // idempotent, so a reopened main window reattaches cleanly.
            // New-mail arrival alerts (sound, dock badge, system
            // notification) live in the reconciler, not here — they keep
            // firing while only the Composer window is open.
            removeNotificationMarkReadObserver()
            removeMessageAttentionChangedObserver()
            cancelSplashTimeout()
        }
    }

    private func updateStartupSplashVisibility() {
        startupSplashVisibility.isActive = hasCompletedOnboarding && showSplash
    }

    private func installNotificationMarkReadObserver() {
        guard notificationMarkReadObserver == nil else { return }
        notificationMarkReadObserver = NotificationCenter.default.addObserver(
            forName: .ohiaNotificationMarkRead,
            object: nil,
            queue: .main
        ) { notification in
            let ids = NewMailUserNotifier.messageIDs(from: notification.userInfo ?? [:])
            Task { @MainActor in
                guard hasCompletedOnboarding else { return }
                handleNotificationMarkRead(ids)
            }
        }
    }

    private func removeNotificationMarkReadObserver() {
        guard let observer = notificationMarkReadObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        notificationMarkReadObserver = nil
    }

    private func installMessageAttentionChangedObserver() {
        guard messageAttentionChangedObserver == nil else { return }
        messageAttentionChangedObserver = NotificationCenter.default.addObserver(
            forName: .ohiaMessageAttentionChanged,
            object: nil,
            queue: .main
        ) { notification in
            let messageIDs = MessageAttentionNotificationCoding.messageIDs(
                from: notification
            )
            guard messageIDs.isEmpty == false else { return }
            Task { @MainActor in
                reconcileReplySourcePreparation(
                    messageIDs: messageIDs,
                    origin: .alreadyVisibleManualAction
                )
            }
        }
    }

    private func removeMessageAttentionChangedObserver() {
        guard let observer = messageAttentionChangedObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        messageAttentionChangedObserver = nil
    }

    private func startLiveInboundReconciler() {
        // Server reconciliation outlives the main window, so the deletion
        // observer that retires Beacon/Dock arrivals must have the same
        // process-scoped lifetime.
        _ = ConstellationDeletionEventBridge.shared
        guard Self.liveInboundReconcileTask == nil else { return }
        NewMailArrivalLedger.shared.beginSession(at: Date.now)
        let sessionID = UUID()
        Self.liveInboundReconcileSessionID = sessionID
        Self.liveInboundReconcileTask = Task(priority: .utility) { @MainActor in
            while !Task.isCancelled {
                await reconcileLiveInboundNotificationsFromStore(sessionID: sessionID)
                do {
                    try await Task.sleep(for: .seconds(Self.liveInboundReconcileInterval))
                } catch {
                    break
                }
            }
        }
    }

    private func stopLiveInboundReconciler() {
        Self.liveInboundReconcileTask?.cancel()
        Self.liveInboundReconcileTask = nil
        Self.liveInboundReconcileSessionID = nil
        Self.meetingCalendarReconcileTask?.cancel()
        NewMailArrivalLedger.shared.endSession()
        // Mirrors the ledger's own session-scoped state clearing above.
        // Inert today (this only runs immediately before process
        // termination), but a future mid-process reconciler restart must
        // not inherit stale staged-since timestamps from the prior session.
        Self.stagedSinceByMessageID.removeAll()
    }

    private func handleNotificationMarkRead(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let dispatcher = MailboxMutationDispatcher(context: modelContext, jobQueue: JobQueue())
        var failedCount = 0
        var localOnlyCount = 0
        for id in ids {
            do {
                let outcome = try dispatcher.setRead(messageID: id, value: true)
                if !outcome.propagatedToServer {
                    localOnlyCount += 1
                }
            } catch {
                failedCount += 1
                print("[Ohia] notification mark read failed for \(id): \(String(reflecting: type(of: error)))")
            }
        }
        if localOnlyCount > 0 {
            print("[Ohia] notification mark read updated \(localOnlyCount) local-only message(s)")
        }
        AppCommand.clearPendingNotificationMarkReadMessageIDs()
        if failedCount < ids.count {
            NotificationCenter.default.post(name: .ohiaEmailSummariesInvalidated, object: nil)
        }
    }

    private func handlePendingNotificationMarkReadIfNeeded() {
        guard hasCompletedOnboarding else { return }
        let ids = AppCommand.pendingNotificationMarkReadMessageIDs()
        guard !ids.isEmpty else { return }
        handleNotificationMarkRead(ids)
    }

    private func handleLiveInboundRendered(_ notification: Notification) {
        guard let event = ConstellationModeView.liveInboundPayload(from: notification) else {
            Self.arrivalLogger.notice("didRenderInActiveLens received with unparseable payload")
            return
        }
        Self.arrivalLogger.notice(
            "didRenderInActiveLens messageIDs=\(event.messageIDs.map(\.uuidString).joined(separator: ","), privacy: .public)"
        )
        publishLiveInboundNotification(event)
    }

    private func reconcileLiveInboundNotificationsFromStore(sessionID: UUID) async {
        guard liveInboundUpdatesAllowed else { return }
        let ledger = NewMailArrivalLedger.shared
        let recentCutoff = Date.now.addingTimeInterval(-Self.liveInboundReconcileLookback)
        guard let since = ledger.reconciliationStartDate(recentCutoff: recentCutoff) else {
            return
        }
        let validity = LiveInboundReconciliationValidity()
        let announcedMessageIDs = ledger.visibilityGate().announcedMessageIds
        let snapshot: LiveInboundReconciliationSnapshot
        do {
            snapshot = try await Self.liveInboundReconciliationWorker.gather(
                since: since,
                announcedMessageIDs: announcedMessageIDs,
                container: modelContext.container,
                pageSize: Self.liveInboundReconcileRowLimit
            )
        } catch is CancellationError {
            return
        } catch {
            print("[Ohia] Live inbound notification reconcile failed: \(String(reflecting: type(of: error)))")
            return
        }
        guard !Task.isCancelled,
              Self.liveInboundReconcileSessionID == sessionID,
              liveInboundUpdatesAllowed,
              validity.isCurrent else { return }
        let rows = snapshot.rows
        let completedSweep = snapshot.completedSweep
        let replyPreparationReadiness = snapshot.replyPreparationReadiness

        requestMeetingCalendarReconciliationIfNeeded(
            readyMessageIDs: Set(
                rows.lazy
                    .filter(\.isPipelineReadyForUserAlert)
                    .map(\.messageId)
            )
        )

        // Prune tracking for messages that dropped out of the store entirely
        // (deleted, moved to Trash/Junk) while staged — otherwise their
        // UUID→Date entry never gets revisited and leaks for the rest of the
        // process's lifetime. Only safe on a completed sweep: a partial page
        // fetch doesn't reflect the full current row set.
        if completedSweep {
            let currentRowIDs = Set(rows.map(\.messageId))
            Self.stagedSinceByMessageID = Self.stagedSinceByMessageID.filter { currentRowIDs.contains($0.key) }
        }

        var rowsToPresent: [MessageStoreLiveInboundRow] = []
        var embargoIds: Set<UUID> = []
        var unresolvedDetectionDates: [Date] = []
        for row in rows {
            guard ledger.isAnnounced(messageID: row.messageId) == false else {
                Self.stagedSinceByMessageID.removeValue(forKey: row.messageId)
                continue
            }
            unresolvedDetectionDates.append(row.liveDetectedAt)
            if isRowReadyForUnifiedArrival(
                row,
                replyPreparationReady: replyPreparationReadiness[row.messageId] ?? false
            ) {
                let newlyStaged = ledger.stageForLensPresentation([row.messageId])
                Self.arrivalLogger.notice(
                    "reconcile staged messageID=\(row.messageId.uuidString, privacy: .public) newlyStaged=\(newlyStaged.isEmpty == false)"
                )
                rowsToPresent.append(row)
                if Self.stagedSinceByMessageID[row.messageId] == nil {
                    Self.stagedSinceByMessageID[row.messageId] = Date.now
                }
            } else {
                embargoIds.insert(row.messageId)
                Self.stagedSinceByMessageID.removeValue(forKey: row.messageId)
            }
        }
        // Rebuilt from the reconciler's current session truth every tick.
        // Rows stay visually embargoed until this loop observes readiness.
        // Staging then releases them to the lens without alerting.
        ledger.updateEmbargo(holding: embargoIds)
        if completedSweep {
            ledger.finishReconciliation(
                unresolvedDetectionDates: unresolvedDetectionDates
            )
        }

        // A render witness that never arrives (the message can't survive the
        // active lens's own candidate filtering, an upstream data gap, the
        // window isn't frontmost) must not silence the alert forever. Fire
        // on pipeline-readiness alone once a staged row has waited past the
        // timeout; `publishLiveInboundNotification` → `announce` is
        // idempotent, so a render witness that lands moments later is a
        // harmless no-op, not a double alert.
        let overdueRows = rowsToPresent.filter { row in
            guard let stagedSince = Self.stagedSinceByMessageID[row.messageId] else { return false }
            return Date.now.timeIntervalSince(stagedSince) >= Self.liveInboundFallbackAlertTimeout
        }
        if overdueRows.isEmpty == false {
            Self.arrivalLogger.notice(
                "fallback alert: render witness overdue for messageIDs=\(overdueRows.map { $0.messageId.uuidString }.joined(separator: ","), privacy: .public)"
            )
            for (group, groupRows) in Dictionary(grouping: overdueRows, by: { row in
                LiveInboundNotificationGroup(accountID: row.accountId, folder: liveInboundFolderName(row.folder))
            }) {
                publishLiveInboundNotification(IMAPLiveInboundPayload(
                    accountID: group.accountID,
                    folder: group.folder,
                    count: groupRows.count,
                    messageIDs: groupRows.map(\.messageId),
                    observedAt: groupRows.map(\.liveDetectedAt).max() ?? Date.now
                ))
            }
            for row in overdueRows {
                Self.stagedSinceByMessageID.removeValue(forKey: row.messageId)
            }
        }

        guard rowsToPresent.isEmpty == false else { return }

        let grouped = Dictionary(grouping: rowsToPresent) { row in
            LiveInboundNotificationGroup(
                accountID: row.accountId,
                folder: liveInboundFolderName(row.folder)
            )
        }
        for (group, groupRows) in grouped {
            let observedAt = groupRows.map(\.liveDetectedAt).max() ?? Date.now
            let event = IMAPLiveInboundPayload(
                accountID: group.accountID,
                folder: group.folder,
                count: groupRows.count,
                messageIDs: groupRows.map(\.messageId),
                observedAt: observedAt
            )
            Self.arrivalLogger.notice(
                "posting readyForLensPresentation messageIDs=\(event.messageIDs.map(\.uuidString).joined(separator: ","), privacy: .public)"
            )
            NotificationCenter.default.post(
                name: .ohiaLiveInboundReadyForLensPresentation,
                object: nil,
                userInfo: liveInboundNotificationUserInfo(for: event)
            )
        }
    }

    private func handleMeetingCalendarLifecycleChange() async {
        let fingerprint = meetingCalendarLifecycleFingerprint
        guard meetingCalendarSyncEnabled else {
            Self.meetingCalendarLastObservedFingerprint = fingerprint
            Self.meetingCalendarLastObservedWriteAccess = nil
            Self.meetingCalendarHasAttemptedInitialReconcile = false
            Self.meetingCalendarLastAttemptedReadyMessageIDs = []
            Self.meetingCalendarReconcileTask?.cancel()
            return
        }
        guard Self.meetingCalendarLastObservedFingerprint != fingerprint else { return }
        Self.meetingCalendarLastObservedFingerprint = fingerprint
        let previousTask = Self.meetingCalendarReconcileTask
        previousTask?.cancel()
        if let previousTask {
            await previousTask.value
        }
        Self.meetingCalendarHasAttemptedInitialReconcile = false
        Self.meetingCalendarLastAttemptedReadyMessageIDs = []
        requestMeetingCalendarReconciliationIfNeeded(readyMessageIDs: [])
    }

    private func requestMeetingCalendarReconciliationIfNeeded(
        readyMessageIDs: Set<UUID>
    ) {
        let hasWriteAccess = DeadlineCalendarSync.hasWriteAccess
        if MeetingCalendarLifecyclePolicy.shouldResetAttemptState(
            previousHasWriteAccess: Self.meetingCalendarLastObservedWriteAccess,
            hasWriteAccess: hasWriteAccess
        ) {
            Self.meetingCalendarHasAttemptedInitialReconcile = false
            Self.meetingCalendarLastAttemptedReadyMessageIDs = []
        }
        Self.meetingCalendarLastObservedWriteAccess = hasWriteAccess

        guard MeetingCalendarLifecyclePolicy.shouldReconcile(
            isEnabled: meetingCalendarSyncEnabled,
            hasWriteAccess: hasWriteAccess,
            reconciliationInFlight: Self.meetingCalendarReconcileTask != nil,
            hasAttemptedInitialReconcile: Self.meetingCalendarHasAttemptedInitialReconcile,
            readyMessageIDs: readyMessageIDs,
            lastAttemptedReadyMessageIDs: Self.meetingCalendarLastAttemptedReadyMessageIDs
        ) else { return }

        Self.meetingCalendarHasAttemptedInitialReconcile = true
        Self.meetingCalendarLastAttemptedReadyMessageIDs = readyMessageIDs
        let context = modelContext
        let leadTime = DeadlineReminderLeadTime(rawValue: calendarDefaultLeadTimeRaw)
            ?? DeadlineReminderSettings.defaultLeadTime
        let reminderHour = calendarReminderHour

        Self.meetingCalendarReconcileTask = Task { @MainActor in
            defer { Self.meetingCalendarReconcileTask = nil }
            do {
                let entries = try await MeetingCalendarEntryLoader.load(
                    modelContext: context
                )
                try Task.checkCancellation()
                guard UserDefaults.standard.bool(
                    forKey: DeadlineReminderSettings.meetingSyncEnabledKey
                ) else { return }

                let sync = DeadlineCalendarSync(modelContext: context)
                try sync.reconcileMeetings(
                    entries: entries,
                    defaultLeadTime: leadTime,
                    reminderHour: reminderHour
                )
                Self.calendarLogger.notice(
                    "Meeting Calendar reconciliation completed with \(entries.count, privacy: .public) eligible entries"
                )
            } catch is CancellationError {
                return
            } catch {
                Self.calendarLogger.error(
                    "Meeting Calendar reconciliation failed: \(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    private func liveInboundFolderName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "INBOX" : trimmed
    }

    private func startWorkerStatusRefresh() {
        let coordinator = workerStatusRefresh
        guard coordinator.observationTask == nil else { return }

        let invalidations = workerSupervisor.statusInvalidations
        coordinator.observationTask = Task { @MainActor in
            for await _ in invalidations {
                guard !Task.isCancelled else { return }
                // This is intentionally cheap enough to run for either a file
                // invalidation or the observer's 15-second recovery yield.
                ensureRetrievalWorkerRunningIfNeeded()
                ensureGenerativeWorkerRunningIfNeeded()
                requestWorkerStatusRefresh()
            }
        }
        requestWorkerStatusRefresh(force: true)
    }

    private func requestWorkerStatusRefresh(force: Bool = false) {
        let action = workerStatusRefresh.gate.invalidate(
            at: ContinuousClock.now,
            force: force
        )
        performWorkerStatusRefreshAction(action)
    }

    private func performWorkerStatusRefreshAction(
        _ action: WorkerStatusRefreshAction
    ) {
        switch action {
        case .none:
            return
        case .startRead:
            startWorkerStatusRead()
        case .schedule(let delay):
            scheduleWorkerStatusRead(after: delay)
        }
    }

    private func scheduleWorkerStatusRead(after delay: Duration) {
        let coordinator = workerStatusRefresh
        guard coordinator.delayedReadTask == nil else { return }
        coordinator.delayedReadTask = Task { @MainActor in
            do {
                try await Task.sleep(for: max(.zero, delay))
            } catch {
                return
            }
            coordinator.delayedReadTask = nil
            let action = coordinator.gate.scheduledReadFired(
                at: ContinuousClock.now
            )
            performWorkerStatusRefreshAction(action)
        }
    }

    private func startWorkerStatusRead() {
        let coordinator = workerStatusRefresh
        coordinator.delayedReadTask?.cancel()
        coordinator.delayedReadTask = nil
        let generation = coordinator.gate.generation

        coordinator.readTask = Task { @MainActor in
            do {
                let fleet = try await workerSupervisor.loadFleetStatus()
                guard coordinator.gate.shouldInstall(
                    generation: generation
                ) else {
                    return
                }

                coordinator.lastErrorSignature = nil
                installWorkerFleetStatus(fleet, at: Date())
                let action = coordinator.gate.readFinished(
                    at: ContinuousClock.now
                )
                coordinator.readTask = nil
                performWorkerStatusRefreshAction(action)
            } catch is CancellationError {
                guard coordinator.gate.shouldInstall(
                    generation: generation
                ) else {
                    return
                }
                _ = coordinator.gate.readFailed()
                coordinator.readTask = nil
            } catch {
                guard coordinator.gate.shouldInstall(
                    generation: generation
                ) else {
                    return
                }
                logWorkerStatusReadFailureIfNeeded(error)
                _ = coordinator.gate.readFailed()
                coordinator.readTask = nil
            }
        }
    }

    private func installWorkerFleetStatus(
        _ fleet: OhiaCore.WorkerFleetStatusSnapshot,
        at now: Date
    ) {
        bridgeWorkerCompletions(from: fleet)
        let bgeWorker = workerStatus(for: .bge, in: fleet, at: now)
        let qwenWorker = workerStatus(for: .qwen, in: fleet, at: now)
        let bgePresentation = bgeSnapshot(
            worker: bgeWorker,
            processState: workerSupervisor.processState(for: .bge),
            now: now
        )
        let qwenPresentation = qwenSnapshot(
            worker: qwenWorker,
            processState: workerSupervisor.processState(for: .qwen),
            now: now
        )
        logWorkerResourceStateIfNeeded(bgePresentation)
        logWorkerResourceStateIfNeeded(qwenPresentation)
        workerStatuses.update(
            fleet: fleet,
            bge: bgePresentation,
            qwen: qwenPresentation
        )
        updateSplashReadinessIfNeeded()
        if let training = fleet.status(for: .qwen)?.training {
            trainingStatusPublisher?.applyWorkerSnapshot(training)
        }
    }

    private func logWorkerStatusReadFailureIfNeeded(_ error: any Error) {
        let signature = "\(String(reflecting: type(of: error)))|\(error.localizedDescription)"
        guard workerStatusRefresh.lastErrorSignature != signature else {
            return
        }
        workerStatusRefresh.lastErrorSignature = signature
        Self.modelLogger.error(
            "Worker status read failed: \(String(reflecting: type(of: error)), privacy: .public)"
        )
    }

    private func bridgeWorkerCompletions(from fleet: OhiaCore.WorkerFleetStatusSnapshot) {
        guard let services = appServices else { return }
        for worker in fleet.workers {
            let result = workerStatusRefresh.completionBridge.consume(worker)
            if result.requiresFullReconciliation {
                // A completion interval fell out of the worker's bounded
                // status history before this app process observed it. One
                // broad data-change event reconciles every lens from the
                // authoritative store; advancing the watermark prevents the
                // same interval from triggering again on the next heartbeat.
                services.jobCompletionBroadcaster.yield(JobCompletionEvent(
                    type: .imapPollFolder,
                    payload: nil,
                    completedAt: fleet.updatedAt,
                    messageMutations: [PipelineMessageMutation(
                        messageIDs: [],
                        facets: [.visibility]
                    )]
                ))
            }
            for completion in result.completions {
                guard let event = completion.jobCompletionEvent else {
                    continue
                }
                NewMailArrivalLedger.shared.removeArrivals(
                    messageIds: CompletionRemoteDeletionRetirement.messageIDs(in: event)
                )
                services.jobCompletionBroadcaster.yield(event)
            }
        }
        reconcileArrivalLedgerWithActiveMessageStore(services: services)
    }

    private func reconcileArrivalLedgerWithActiveMessageStore(
        services: AppServices
    ) {
        let ledger = NewMailArrivalLedger.shared
        let trackedMessageIDs = ledger.deletionReconciliationMessageIDs
        guard trackedMessageIDs.isEmpty == false else { return }
        let activeMessageIDs: Set<UUID>
        do {
            guard let active = try MessageStoreHotPath.activeMessageIDs(
                matching: Array(trackedMessageIDs),
                storeURL: services.messageStoreURL
            ) else {
                return
            }
            activeMessageIDs = active
        } catch {
            return
        }
        let removedMessageIDs = ledger.removeArrivalsMissingFromActiveStore(
            activeMessageIDs: activeMessageIDs
        )
        guard removedMessageIDs.isEmpty == false else { return }
        // Exact completion metadata may have been evicted while the app was
        // asleep. Rebuild every lens from the authoritative active-row store
        // whenever this fallback discovers a retired arrival.
        services.jobCompletionBroadcaster.yield(JobCompletionEvent(
            type: .imapDeletionWatch,
            payload: nil,
            completedAt: .now,
            messageMutations: [PipelineMessageMutation(
                messageIDs: removedMessageIDs.compactMap(UUID.init(uuidString:)),
                facets: [.visibility]
            )]
        ))
    }

    /// The unified arrival moment. Everything the user perceives as "new
    /// mail arrived" fires from this one main-actor turn: the embargo lifts
    /// (so the very next scene refresh renders the node), the dock badge
    /// increments, the system notification posts, the new-mail sound plays,
    /// and `.ohiaIMAPNewInboundMessages` notifies the Constellation window —
    /// whose handler synchronously promotes the message into the starburst
    /// badge and kicks the revealing scene refresh.
    private func publishLiveInboundNotification(_ event: IMAPLiveInboundPayload) {
        guard liveInboundUpdatesAllowed else {
            Self.arrivalLogger.notice("publishLiveInboundNotification blocked: liveInboundUpdatesAllowed=false")
            return
        }
        // Mail the user already read in another client (Gmail on the web, a
        // phone) appears without the arrival alert. Trashed and Junk-filtered
        // mail never reaches here: it leaves the live inbound rows.
        let alreadyRead = alreadyReadArrivalIDs(event.messageIDs, context: modelContext)
        if alreadyRead.isEmpty == false {
            let released = NewMailArrivalLedger.shared.releaseWithoutAlert(
                event.messageIDs.filter(alreadyRead.contains)
            )
            Self.arrivalLogger.notice(
                "publishLiveInboundNotification released already-read arrivals without alert \(released.map(\.uuidString).joined(separator: ","), privacy: .public)"
            )
        }
        // `announce` adds the fresh IDs to the ledger's unvisited account,
        // which mirrors the dock badge — the same count every starburst
        // renders. No direct dock-tile writes here.
        let messageIDs = NewMailArrivalLedger.shared.announce(
            event.messageIDs.filter { alreadyRead.contains($0) == false }
        )
        guard messageIDs.isEmpty == false else {
            Self.arrivalLogger.notice(
                "publishLiveInboundNotification no alert: every arrival was already announced or read \(event.messageIDs.map(\.uuidString).joined(separator: ","), privacy: .public)"
            )
            return
        }
        Self.arrivalLogger.notice(
            "publishLiveInboundNotification FIRING sound+badge+notification for \(messageIDs.map(\.uuidString).joined(separator: ","), privacy: .public)"
        )

        let count = messageIDs.count
        NewMailUserNotifier.deliver(
            payload: NewMailUserNotifier.DeliveryPayload(
                accountID: event.accountID,
                folder: event.folder,
                count: count,
                messageIDs: messageIDs
            ),
            context: modelContext
        )
        let soundFilename = NewStarAlertSoundPreference.resolvedFilename(
            from: UserDefaults.standard.string(forKey: NewStarAlertSoundPreference.storageKey)
        )
        newMailAlertSoundPlayer.play(filename: soundFilename)
        NotificationCenter.default.post(
            name: .ohiaIMAPNewInboundMessages,
            object: nil,
            userInfo: liveInboundNotificationUserInfo(
                for: IMAPLiveInboundPayload(
                    accountID: event.accountID,
                    folder: event.folder,
                    count: count,
                    messageIDs: messageIDs,
                    observedAt: event.observedAt
                )
            )
        )
        // Commit only after every user-facing part of the unified arrival was
        // dispatched. If the process exits earlier, restart recovery retries
        // the still-uncommitted message instead of silently revealing it.
        NewMailArrivalLedger.shared.commitAnnouncementDelivery(messageIDs)
    }

    private func reconcileReplySourcePreparation(
        messageIDs: Set<UUID>,
        origin: ReplySourcePreparationAdmissionOrigin
    ) {
        guard messageIDs.isEmpty == false else { return }
        do {
            try ReplySourcePreparationCoordinator().reconcile(
                messageIDs: messageIDs,
                origin: origin,
                durablyAnnouncedMessageIDs:
                    NewMailArrivalLedger.shared.durablyAnnouncedMessageIDs(),
                context: modelContext
            )
        } catch {
            print(
                "[Ohia] Reply source preparation reconcile failed: "
                    + String(reflecting: type(of: error))
            )
        }
    }

    private func liveInboundNotificationUserInfo(
        for event: IMAPLiveInboundPayload
    ) -> [AnyHashable: Any] {
        [
            "accountID": event.accountID,
            "folder": event.folder,
            "count": event.count,
            "messageIDs": event.messageIDs,
            "observedAt": event.observedAt
        ]
    }

    /// Play the sent-mail confirmation sound, honoring the user's selection in
    /// Settings → General → Notifications. "No Sound" (empty filename) is silent.
    /// Separate player from `newMailAlertSoundPlayer` so a sent chime and a
    /// new-mail chime never cut each other off.
    ///
    /// Rows whose chime the Coqui Chorus send takeover claims stay silent
    /// here: the overlay fires the call itself on the frame whose rendered
    /// flash reaches the white-out beat (the claim arms it if the confirm
    /// resolution hasn't yet), and this consumer's job for those rows is
    /// only to retire the durable playback flag — however late the worker's
    /// hint arrives relative to the flourish. Every other path — no
    /// takeover, Warp Bolide, the launch sweep — plays immediately, exactly
    /// as before.
    private func playSentMailSound(for outboxItemID: UUID) {
        let filename = SentMailSoundPreference.resolvedFilename(
            from: UserDefaults.standard.string(forKey: SentMailSoundPreference.storageKey)
        )
        guard filename != SentMailSoundPreference.noSoundFilename else { return }
        guard !ComposerSendTakeoverCoordinator.claimChime(forOutboxItemID: outboxItemID) else {
            return
        }
        sentMailSoundPlayer.play(filename: filename)
    }

    /// Consume one durable sent confirmation: look the outbox row up, and only if
    /// it is genuinely `.sent` with `sentConfirmationPendingPlayback` still set,
    /// play the chime and clear the flag in the same save. The flag is the single
    /// source of truth, so this fires exactly once per send — a duplicate wake-up
    /// hint finds the flag already cleared, a spoofed one names no real row, and
    /// a dropped one is caught by `sweepPendingSentConfirmations` at launch.
    private func consumeSentConfirmation(outboxItemIDString: String?) {
        guard let outboxItemIDString,
              let outboxItemID = UUID(uuidString: outboxItemIDString) else { return }
        let consumed = SentConfirmationConsumer.consumePending(in: modelContext) {
            $0.id == outboxItemID
        }
        for item in consumed { playSentMailSound(for: item.id) }
    }

    /// Launch sweep: consume any sent confirmations whose wake-up hint was dropped
    /// while the app wasn't listening (suspended, not yet launched, or a lost
    /// distributed notification).
    private func sweepPendingSentConfirmations() {
        let consumed = SentConfirmationConsumer.consumePending(in: modelContext) { _ in true }
        for item in consumed { playSentMailSound(for: item.id) }
    }

    private func workerStatus(
        for role: WorkerRole,
        in fleet: OhiaCore.WorkerFleetStatusSnapshot,
        at date: Date
    ) -> WorkerStatusSnapshot {
        fleet.status(for: role) ?? WorkerStatusSnapshot(
            role: role,
            state: .unknown,
            updatedAt: date
        )
    }

    private func bgeSnapshot(
        worker: WorkerStatusSnapshot,
        processState: WorkerFleetProcessState,
        now: Date
    ) -> WorkerStatusPresentationSnapshot {
        let workerModel = worker.model
        let resourceState: WorkerFleetResourceState
        var details: [String] = []
        var hidesThrottleReasons = false

        if worker.state == .failed {
            resourceState = .failed
            details.append(worker.statusMessage ?? "worker failed")
        } else if case .failed(let message) = workerModel?.state {
            resourceState = .failed
            details.append(message)
        } else if processState == .stopped || worker.state == .stopped {
            resourceState = .unavailable
            details.append(worker.statusMessage ?? "worker stopped")
        } else if worker.isHeartbeatStale(
            maxAge: Self.workerHeartbeatMaxAge,
            now: now
        ) {
            resourceState = .unavailable
            details.append("worker heartbeat stale")
        } else if worker.state == .starting
            || workerModel?.state == .loading
            || isDownloading(workerModel?.state) {
            resourceState = .loading
            details.append(workerModel?.message ?? "loading bge-m3 model")
        } else if case .paused(let reason) = workerModel?.state {
            resourceState = .paused
            details.append(reason ?? workerModel?.message ?? "model loading paused")
        } else if workerModel?.state == .downloaded
            || workerModel?.state == .unavailable {
            resourceState = .waiting
            details.append(workerModel?.message ?? "waiting for bge-m3 model")
        } else if let resource = worker.resource {
            let availableLanes = max(
                1,
                resource.embeddingLaneCapacity
                    ?? workerModel?.laneCount
                    ?? 1
            )
            let laneLimit = max(
                1,
                min(resource.embeddingLaneLimit ?? 1, availableLanes)
            )
            let modelWorkIdle = resource.pipelineReadiness.isComplete
            if modelWorkIdle {
                resourceState = .waiting
                hidesThrottleReasons = true
                details.append("pipeline idle; waiting for new mail or queued BGE work")
            } else if worker.throttle.isThrottled {
                resourceState = .throttled
                details.append("lanes \(laneLimit)/\(availableLanes)")
            } else {
                resourceState = fleetResourceState(for: resource.mode)
                details.append("lanes \(laneLimit)/\(availableLanes)")
            }
            if let reason = resource.pipelineReadiness.blockingReason {
                details.append("pipeline: \(pipelineStatusLabel(reason))")
            }
        } else {
            resourceState = .waiting
            details.append("waiting for worker resource status")
        }

        return WorkerStatusPresentationSnapshot(
            worker: worker,
            resourceState: resourceState,
            processState: processState,
            detail: details.joined(separator: " · "),
            throttleReasons: hidesThrottleReasons
                ? []
                : displayThrottleReasons(worker: worker),
            updatedAt: now
        )
    }

    private func qwenSnapshot(
        worker: WorkerStatusSnapshot,
        processState: WorkerFleetProcessState,
        now: Date
    ) -> WorkerStatusPresentationSnapshot {
        let resourceState: WorkerFleetResourceState
        let detail: String?

        if worker.state == .failed {
            resourceState = .failed
            detail = worker.statusMessage
        } else if processState == .stopped || worker.state == .stopped {
            resourceState = .unavailable
            detail = worker.statusMessage ?? "worker stopped"
        } else if worker.isHeartbeatStale(
            maxAge: Self.workerHeartbeatMaxAge,
            now: now
        ) {
            resourceState = .unavailable
            detail = "worker heartbeat stale"
        } else if worker.state == .stopping {
            resourceState = .waiting
            detail = worker.statusMessage ?? "worker stopping"
        } else if let model = worker.model, !model.state.isReady {
            switch model.state {
            case .downloading, .loading:
                resourceState = .loading
            case .downloaded:
                resourceState = .waiting
            case .paused:
                resourceState = .paused
            case .failed:
                resourceState = .failed
            case .unavailable:
                resourceState = .waiting
            case .ready:
                resourceState = .full
            }
            detail = model.message ?? model.name
        } else if worker.state == .starting {
            resourceState = .loading
            detail = worker.statusMessage
        } else if let resource = worker.resource,
                  let reason = resource.pipelineReadiness.blockingReason {
            (resourceState, detail) = qwenBGEWaitStateAndDetail(
                worker: worker,
                resource: resource,
                reason: reason
            )
        } else if let resource = worker.resource {
            (resourceState, detail) = qwenResourceStateAndDetail(
                resource: resource
            )
        } else if worker.throttle.isThrottled {
            resourceState = .throttled
            detail = "waiting for worker resource status"
        } else {
            resourceState = .waiting
            detail = "waiting for worker resource status"
        }

        return WorkerStatusPresentationSnapshot(
            worker: worker,
            resourceState: resourceState,
            processState: processState,
            detail: detail,
            throttleReasons: displayThrottleReasons(worker: worker),
            updatedAt: now
        )
    }

    private func displayThrottleReasons(
        worker: WorkerStatusSnapshot
    ) -> [String] {
        worker.throttle.reasons.map(displayThrottleReason)
    }

    private func displayThrottleReason(_ rawValue: String) -> String {
        ResourceThrottleReason(rawValue: rawValue)?.displayLabel
            ?? rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func logWorkerResourceStateIfNeeded(_ snapshot: WorkerStatusPresentationSnapshot) {
        let signature = [
            snapshot.resourceState.displayLabel,
            snapshot.processState.displayLabel,
            snapshot.worker.state.rawValue,
            snapshot.worker.model?.message ?? "",
            snapshot.detail ?? "",
            snapshot.throttleReasons.joined(separator: ","),
        ].joined(separator: "|")
        guard loggedWorkerResourceSignatures[snapshot.worker.role] != signature else { return }
        loggedWorkerResourceSignatures[snapshot.worker.role] = signature

        Self.modelLogger.info(
            "\(snapshot.worker.role.resourceTitle, privacy: .public) status: resource=\(snapshot.resourceState.displayLabel, privacy: .public) process=\(snapshot.processState.displayLabel, privacy: .public) worker=\(snapshot.worker.state.rawValue, privacy: .public) throttled=\(snapshot.throttleReasons.isEmpty == false, privacy: .public)"
        )
    }

    private func qwenResourceStateAndDetail(
        resource: WorkerResourceStatusSnapshot
    ) -> (WorkerFleetResourceState, String?) {
        if resource.mode == .paused {
            return (.paused, nil)
        }
        if resource.mode == .full
            && resource.allowsBackgroundTraining == true {
            return (.full, nil)
        }
        return (.throttled, nil)
    }

    private func qwenBGEWaitStateAndDetail(
        worker: WorkerStatusSnapshot,
        resource: WorkerResourceStatusSnapshot,
        reason: WorkerPipelineBlockReason
    ) -> (WorkerFleetResourceState, String?) {
        let reasonText = pipelineStatusLabel(reason)
        if worker.currentJobType == JobType.summarize.rawValue
            || resource.allowsInterpretation == true {
            return (
                worker.throttle.isThrottled ? .throttled : .waiting,
                "datafied interpretation has priority; \(reasonText) still catching up"
            )
        }
        if resource.allowsUserInitiatedWork == true {
            return (
                worker.throttle.isThrottled ? .throttled : .waiting,
                "interactive Qwen ready; training and draft work waiting for \(reasonText)"
            )
        }
        return (.waiting, "training and draft work waiting for \(reasonText)")
    }

    private func fleetResourceState(
        for mode: WorkerResourceMode
    ) -> WorkerFleetResourceState {
        switch mode {
        case .full:
            return .full
        case .throttled:
            return .throttled
        case .paused:
            return .paused
        }
    }

    private func pipelineStatusLabel(
        _ reason: WorkerPipelineBlockReason
    ) -> String {
        switch reason {
        case .embedding:
            return "BGE embedding"
        case .placement:
            return "BGE indexing"
        case .reindexing:
            return "BGE reindexing"
        case .queuedBGEWork:
            return "BGE work"
        }
    }

    private func isDownloading(
        _ state: WorkerModelLoadState?
    ) -> Bool {
        if case .downloading = state {
            return true
        }
        return false
    }

    private func installActivityMonitoring() {
        guard let appActivityMonitor else { return }
        syncAppActivitySnapshot()
        guard activityEventMonitor == nil else { return }
        activityEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            appActivityMonitor.recordInteraction()
            return event
        }
    }

    private func removeActivityMonitoring() {
        if let activityEventMonitor {
            NSEvent.removeMonitor(activityEventMonitor)
            self.activityEventMonitor = nil
        }
        appActivityMonitor?.recordAppFrontmost(false)
    }

    private func startAppActivityHeartbeat() {
        guard appActivityHeartbeatTask == nil else { return }
        syncAppActivitySnapshot()
        appActivityHeartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    break
                }
                syncAppActivitySnapshot()
            }
        }
    }

    private func stopAppActivityHeartbeat() {
        appActivityHeartbeatTask?.cancel()
        appActivityHeartbeatTask = nil
    }

    private func syncAppActivitySnapshot(
        forceFrontmost: Bool? = nil,
        recordInteraction: Bool = false
    ) {
        guard let appActivityMonitor else { return }
        appActivityMonitor.recordHeartbeat(
            isAppFrontmost: forceFrontmost ?? NSApplication.shared.isActive,
            isConstellationActive: constellationActiveMonitor?.isActive ?? false,
            isMeaningLensEnabled: meaningLensActivityFingerprint.enabled,
            isMeaningLensActive: meaningLensActivityFingerprint.active,
            isComposerActive: composerSurfaceActive,
            isOnboardingWitnessActive: onboardingWitnessActivityActive
        )
        if recordInteraction {
            appActivityMonitor.recordInteraction()
        }
    }

    /// Tear down the pipeline. Used when onboarding flips back to false
    /// (developer reset) so in-flight ticks don't keep writing into a
    /// database that's about to be wiped. The matching `startPipeline`
    /// runs again when the user completes the next onboarding pass.
    /// Cancelling the structured pipeline task propagates cancellation
    /// through the runner into the orchestrator's per-file cancellation
    /// check, so a 94K-file ingest doesn't keep grinding past the reset.
    private func stopPipeline() {
        pipelineDesired = false
        appIMAPFallbackActive = false
        workerSupervisor.stop()
        Task { @MainActor in
            await imapSessionManager?.stopAllSessions()
        }
        requestWorkerStatusRefresh()
        print("[Ohia] Pipeline stopped")
    }

    private func prepareForTermination() async {
        let sequence = AppTerminationSequence(
            quiesce: {
                pipelineDesired = false
                appServices?.trainingEngine?.cancel()
                workerStatusRefresh.cancel()
                workerSupervisor.cancelStatusObservation()
                stopLiveInboundReconciler()
            },
            initialSave: { try modelContext.save() },
            stopWorkers: { await workerSupervisor.stopForQuit() },
            shutdownIMAP: { await imapSessionManager?.shutdown() },
            hasChanges: { modelContext.hasChanges },
            finalSave: { try modelContext.save() },
            log: { print($0) }
        )
        let pendingRoles = await sequence.run()
        if pendingRoles.isEmpty {
            print("[Ohia] Quit workers acknowledged terminal state")
        } else {
            let processNames = pendingRoles.map(\.processName).sorted().joined(separator: ", ")
            print("[Ohia] Quit workers still pending: \(processNames)")
        }
        print("[Ohia] Quit cleanup complete")
    }

    private func startPipeline() {
        pipelineDesired = true
        if workerSupervisor.start(roles: [.bge, .qwen]) {
            stopAppIMAPFallback(clearStatuses: true)
            requestWorkerStatusRefresh()
            return
        }
        print("[Ohia] ⚠ worker fleet unavailable — heavy pipeline work is degraded")
        startAppIMAPFallback()
        requestWorkerStatusRefresh()
    }

    private func startPipelinePreparation() {
        pipelineDesired = true
        guard workerSupervisor.start(roles: [.bge, .qwen]) else {
            print("[Ohia] ⚠ worker fleet unavailable — onboarding pipeline preparation is degraded")
            requestWorkerStatusRefresh()
            return
        }
        stopAppIMAPFallback(clearStatuses: true)
        requestWorkerStatusRefresh()
    }

    private func startOnboardingReadyModelPreparation(modelID: String?) {
        pipelineDesired = false
        hasRequestedOnboardingModelPreparation = true
        guard workerSupervisor.start(roles: [.bge, .qwen]) else {
            print("[Ohia] ⚠ worker fleet unavailable — onboarding model preparation is degraded")
            requestWorkerStatusRefresh()
            return
        }
        if let modelID, ModelManager.allModels.contains(where: { $0.modelId == modelID }) {
            ModelManager.clearPendingGenerationModel()
            ModelManager.setSelectedGenerationModelID(modelID)
            workerSupervisor.requestGenerativeModelSelection(modelID)
        }
        requestWorkerStatusRefresh()
    }

    private func startAppIMAPFallback() {
        appIMAPFallbackActive = true
        imapSessionManager?.syncSessions(allowsIMAPWork: liveInboundUpdatesAllowed)
        imapSessionManager?.start(allowsIMAPWork: liveInboundUpdatesAllowed)
    }

    private func stopAppIMAPFallback(clearStatuses: Bool) {
        guard appIMAPFallbackActive else { return }
        appIMAPFallbackActive = false
        Task { @MainActor in
            await imapSessionManager?.stopAllSessions(clearStatuses: clearStatuses)
        }
    }

    private func startGenerativeWorkerForModelPreparation() {
        guard workerSupervisor.start(roles: [.qwen]) else {
            print("[Ohia] ⚠ generative worker unavailable — Qwen preparation cannot start")
            requestWorkerStatusRefresh()
            return
        }
        requestWorkerStatusRefresh()
    }

    private var liveInboundUpdatesAllowed: Bool {
        hasCompletedOnboarding && (hasCompletedFirstIngestion || hasReachedOnboardingWitnessPanel)
    }

    private var onboardingWitnessActivityActive: Bool {
        OnboardingPipelineGate.isWitnessActivityActive(
            hasCompletedOnboarding: hasCompletedOnboarding,
            hasReachedWitnessPanel: hasReachedOnboardingWitnessPanel,
            hasCompletedFirstIngestion: hasCompletedFirstIngestion
        )
    }

    private func ensureRetrievalWorkerRunningIfNeeded() {
        guard pipelineDesired, hasCompletedOnboarding else { return }
        guard workerSupervisor.processState(for: .bge) == .stopped else { return }
        guard workerSupervisor.start(roles: [.bge]) else {
            startAppIMAPFallback()
            return
        }
        stopAppIMAPFallback(clearStatuses: true)
        print("[Ohia] retrieval worker relaunched for background IMAP sync")
    }

    private func ensureGenerativeWorkerRunningIfNeeded() {
        guard pipelineDesired, hasCompletedOnboarding else { return }
        guard workerSupervisor.processState(for: .qwen) == .stopped else { return }
        guard workerSupervisor.start(roles: [.qwen]) else { return }
        print("[Ohia] generative worker relaunched for model download/background generation")
    }

    /// Begin gating the splash dismissal on worker readiness. Resets any
    /// previous gate state and arms the safety timeout. Called when the
    /// splash is about to appear — at app launch (if onboarded) and right
    /// after the onboarding wizard completes.
    private func resetSplashGate() {
        splashCanDismiss = false
        cancelSplashTimeout()
        updateSplashReadinessIfNeeded()
        splashTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.splashMaxWait))
            guard !Task.isCancelled else { return }
            if !splashCanDismiss {
                print("[Ohia] splash gate timeout fired — dismissing without full model readiness")
                splashCanDismiss = true
            }
        }
    }

    private func cancelSplashTimeout() {
        splashTimeoutTask?.cancel()
        splashTimeoutTask = nil
    }

    private func updateSplashReadinessIfNeeded() {
        guard showSplash, hasCompletedOnboarding, !splashCanDismiss else { return }
        guard isWorkerReadyForSplashEarlyDismiss(workerStatuses.bge) else { return }
        guard isWorkerReadyForSplashEarlyDismiss(workerStatuses.qwen) else { return }
        splashCanDismiss = true
        cancelSplashTimeout()
    }

    /// Early splash dismissal is reserved for the happy path: the live worker
    /// process must be running and must report its model as loaded. Failures,
    /// unavailable models, and stopped workers fall through to the 12-second
    /// safety cap instead of ending the splash animation early.
    private func isWorkerReadyForSplashEarlyDismiss(
        _ snapshot: WorkerStatusPresentationSnapshot
    ) -> Bool {
        snapshot.worker.hasLoadedModelInRunningProcess(
            processIsRunning: snapshot.processState == .running
        )
    }

}

private struct PipelinePauseObserver: ViewModifier {
    @Environment(PipelinePauseState.self) private var pipelinePauseState

    let scheduler: BackgroundScheduler?
    let workerSupervisor: WorkerFleetSupervisor
    let onPause: @MainActor () -> Void
    let onResume: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ohiaPausePipeline)) { note in
                onPause()
                scheduler?.isPaused = true
                let skipWorkerStop = note.userInfo?["skipWorkerStop"] as? Bool ?? false
                if !skipWorkerStop {
                    workerSupervisor.stop()
                }
                pipelinePauseState.setPaused(true)
                print("[Ohia] pipeline paused")
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaResumePipeline)) { _ in
                onResume()
                scheduler?.isPaused = false
                _ = workerSupervisor.start(roles: [.bge])
                pipelinePauseState.setPaused(false)
                print("[Ohia] pipeline resumed")
            }
    }
}

private struct AppWindowCommandBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ohiaShowConstellation)) { _ in
                openWindow(id: OhiaWindowID.constellation)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaShowComposer)) { _ in
                guard hasCompletedFirstIngestion else { return }
                openWindow(id: OhiaWindowID.composer)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaShowFocus)) { notification in
                guard hasCompletedFirstIngestion,
                      let messageID = focusMessageID(from: notification) else { return }
                AppCommand.requestComposerFocus(messageID: messageID)
                openWindow(id: OhiaWindowID.composer)
            }
    }

    private func focusMessageID(from notification: Notification) -> UUID? {
        if let id = notification.userInfo?["messageID"] as? UUID {
            return id
        }
        if let raw = notification.userInfo?["messageID"] as? String {
            return UUID(uuidString: raw)
        }
        return nil
    }
}

/// Mirrors the Composer surface's appear/disappear notifications into a
/// callback. Extracted from `RootView`'s lifecycle modifier chain for the
/// same type-checker-budget reason as `SettingsTabOpeningObserver` below.
private struct ComposerSurfaceActivityObserver: ViewModifier {
    let onChange: (Bool) -> Void
    let onOpenReplyChange: (UUID?) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerSurfaceActive)) { notification in
                onChange(notification.userInfo?["active"] as? Bool ?? false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerOpenReplyChanged)) { notification in
                onOpenReplyChange(notification.userInfo?["messageID"] as? UUID)
            }
    }
}

/// Bridges active-lens presentation acknowledgement back to the process-level
/// arrival publisher without adding another inline observer to RootView's
/// already type-check-heavy lifecycle chain.
private struct LiveInboundRenderedObserver: ViewModifier {
    let onRender: (Notification) -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(
                for: .ohiaLiveInboundDidRenderInActiveLens
            )
        ) { notification in
            onRender(notification)
        }
    }
}

/// Refreshes the Generative Worker's in-memory MCP credential snapshot when
/// credentials change. Kept out of `RootView`'s lifecycle chain to preserve
/// its type-checker budget.
private struct MCPEnvironmentRefreshObserver: ViewModifier {
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(
                for: .ohiaMCPServerInjectableEnvironmentDidChange
            )
        ) { _ in
            onRefresh()
        }
    }
}

/// Opens a Settings tab when its menu-bar notification fires. Extracted
/// from `RootView`'s lifecycle modifier chain — inline `.onReceive`
/// closures there push the expression past the type-checker's limit.
private struct SettingsTabOpeningObserver: ViewModifier {
    let notification: Notification.Name
    let tabRawValue: String
    let isEnabled: Bool
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: notification)) { _ in
            guard isEnabled else { return }
            UserDefaults.standard.set(tabRawValue, forKey: "selectedSettingsTab")
            openSettings()
        }
    }
}
