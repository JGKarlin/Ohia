import Foundation
import SwiftData
import OhiaCore

/// Queue reads and reply assessment share one lane. A cancelled synchronous
/// database operation may finish, but superseded queued work never starts and
/// cannot accumulate a parallel set of store scans under load.
actor ComposerBackgroundReadWorker {
    func run<Value: Sendable>(
        _ operation: @Sendable () throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
}

@MainActor
final class ComposerReadCoordinator {
    typealias QueueLoader = @Sendable (ModelContainer) throws -> [ComposerQueueItem]
    typealias AssessmentLoader = @Sendable (
        UUID, ModelContainer, @Sendable () -> Bool
    ) throws -> ReplySourcePreparationAssessment?
    let worker = ComposerBackgroundReadWorker()
    private let loadQueue: QueueLoader
    private let loadAssessment: AssessmentLoader
    private let notificationCenter: NotificationCenter
    private var queueTask: Task<Void, Never>?
    private var queuePending = false
    private var queueRevision: UInt64 = 0
    private var queueCompletion: (() -> Void)?
    private var lifetime: UInt64 = 0
    private var replyTask: Task<Void, Never>?
    private(set) var selectionRevision: UInt64 = 0

    init(
        notificationCenter: NotificationCenter = .default,
        loadQueue: @escaping QueueLoader = { container in
            try ComposerQueueModel.load(context: ModelContext(container))
        },
        loadAssessment: @escaping AssessmentLoader = { messageID, container, isCurrent in
            try ReplySourcePreparationAdopter.assess(
                messageID: messageID, container: container, isCurrent: isCurrent
            )
        }
    ) {
        self.notificationCenter = notificationCenter
        self.loadQueue = loadQueue
        self.loadAssessment = loadAssessment
    }

    func requestQueue(
        container: ModelContainer,
        invalidatingInFlight: Bool,
        onInstall: @escaping ([ComposerQueueItem]) -> Void,
        afterInstall: (() -> Void)? = nil
    ) {
        if invalidatingInFlight { queueRevision &+= 1 }
        queuePending = true
        if let afterInstall { queueCompletion = afterInstall }
        guard queueTask == nil else { return }
        let requestLifetime = lifetime
        queueTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if lifetime == requestLifetime { queueTask = nil }
            }
            while queuePending, !Task.isCancelled, lifetime == requestLifetime {
                queuePending = false
                let revision = queueRevision
                let validity = LiveInboundReconciliationValidity(notificationCenter: notificationCenter)
                do {
                    let loadQueue = self.loadQueue
                    let rows = try await worker.run {
                        try loadQueue(container)
                    }
                    guard !Task.isCancelled, lifetime == requestLifetime else { return }
                    guard revision == queueRevision, validity.isCurrent else {
                        queuePending = true
                        continue
                    }
                    let completion = queueCompletion
                    queueCompletion = nil
                    // Installing the queue may retire the formerly open
                    // reply and clear its selection. Preserve the newer
                    // opening intent across that synchronous reconciliation.
                    // Navigation during the await already cleared it above.
                    onInstall(rows)
                    completion?()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    /// User navigation always wins over an older opening or polling result.
    @discardableResult
    func changeSelection() -> UInt64 {
        selectionRevision &+= 1
        replyTask?.cancel()
        replyTask = nil
        queueCompletion = nil
        return selectionRevision
    }

    func requestReply(
        messageID: UUID,
        container: ModelContainer,
        isOpening: Bool,
        onResult: @escaping (ReplySourcePreparationAssessment?) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        if isOpening { changeSelection() }
        // Repeated polling coalesces with its active read instead of cancelling
        // a preparation that can legitimately take longer than the poll period.
        guard replyTask == nil else { return }
        let revision = selectionRevision
        let requestLifetime = lifetime
        replyTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                if revision == selectionRevision, requestLifetime == lifetime { replyTask = nil }
            }
            while !Task.isCancelled, revision == selectionRevision, requestLifetime == lifetime {
                let validity = LiveInboundReconciliationValidity(notificationCenter: notificationCenter)
                do {
                    let loadAssessment = self.loadAssessment
                    let assessment = try await worker.run {
                        try loadAssessment(messageID, container, { validity.isCurrent })
                    }
                    guard !Task.isCancelled,
                          revision == selectionRevision, requestLifetime == lifetime else { return }
                    guard validity.isCurrent else {
                        if isOpening { continue }
                        return
                    }
                    onResult(assessment)
                    return
                } catch is CancellationError {
                    // Data churn may invalidate an assessment without cancelling
                    // the user's opening intent. Retry that latest click; actual
                    // navigation/lifetime cancellation always stops the lane.
                    guard isOpening, !Task.isCancelled, !validity.isCurrent,
                          revision == selectionRevision, requestLifetime == lifetime else { return }
                } catch {
                    guard revision == selectionRevision, requestLifetime == lifetime else { return }
                    onError(error)
                    return
                }
            }
        }
    }

    func cancel() {
        lifetime &+= 1
        queueTask?.cancel()
        queueTask = nil
        queuePending = false
        queueCompletion = nil
        changeSelection()
    }
}
