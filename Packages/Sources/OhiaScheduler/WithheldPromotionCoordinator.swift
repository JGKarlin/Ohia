import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaMail

// MARK: - Request & Outcome types

/// Everything the coordinator needs to know about a single withheld message
/// that the user has chosen to promote to their inbox.
public struct WithheldPromotionRequest: Sendable, Equatable {
    public let accountID: UUID
    public let role: WithheldFolderRole
    /// The source Junk/Trash IMAP folder path (e.g. `"[Gmail]/Spam"`).
    public let folderPath: String
    public let uid: UInt32
    public let uidValidity: UInt32
    /// RFC Message-ID header value, used to re-resolve a stale UID after
    /// UIDVALIDITY change or when the cached UID is no longer found.
    /// `nil` when the header was absent in the envelope.
    public let messageID: String?
    /// User restore evidence attached to the existing move-to-Inbox mutation.
    /// Present for Junk restores so future Withheld scoring can learn that
    /// similar mail should be weighted away from spam.
    public let feedbackEvidence: MailboxSpamFeedbackEvidence?
    public let feedbackProviderSpamScore: Double?

    public init(
        accountID: UUID,
        role: WithheldFolderRole,
        folderPath: String,
        uid: UInt32,
        uidValidity: UInt32,
        messageID: String?,
        feedbackEvidence: MailboxSpamFeedbackEvidence? = nil,
        feedbackProviderSpamScore: Double? = nil
    ) {
        self.accountID = accountID
        self.role = role
        self.folderPath = folderPath
        self.uid = uid
        self.uidValidity = uidValidity
        self.messageID = messageID
        self.feedbackEvidence = feedbackEvidence
        self.feedbackProviderSpamScore = feedbackProviderSpamScore
    }
}

/// The result of a successful promotion.
public enum PromotionOutcome: Sendable, Equatable {
    /// The message was not previously in the corpus — ingested fresh and
    /// a server-side move was enqueued.
    case promoted(messageID: UUID)
    /// The message was already present in the corpus (dedup hit) — move
    /// still enqueued so the server copy lands in Inbox.
    case alreadyPresent(messageID: UUID)
}

/// Errors that abort the promotion without enqueueing a server move.
public enum WithheldPromotionError: Error, Equatable {
    /// The UID was stale (UIDVALIDITY changed or message not found) and
    /// there was no Message-ID to re-resolve it — it is unsafe to move
    /// an unknown UID.
    case staleUIDUnresolved
    /// The ingestion pipeline returned a nil messageId alongside a
    /// non-skipped disposition.
    case ingestReturnedNoMessage
    /// The ingestion pipeline returned `.skipped`, which should never
    /// happen for a promotion call (the caller passes `isPromotion: true`).
    case ingestUnexpectedlySkipped
}

// MARK: - Protocol seams

/// Retrieves raw RFC 5322 bytes for a withheld message and can re-resolve
/// a stale UID by Message-ID. Sendable; implementations typically wrap an
/// actor (e.g. `WithheldFolderService`).
public protocol WithheldPromotionBodySource: Sendable {
    func fetchBody(
        uid: UInt32,
        expectedUIDValidity: UInt32?,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> Data

    func resolveUID(
        messageID: String,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> WithheldResolvedUID?
}

/// Ingests a raw RFC 5322 message into the Ohia corpus.
/// All implementations run on the main actor because they access
/// `ModelContext` and `Account` SwiftData rows.
@MainActor
public protocol WithheldPromotionIngesting {
    func ingestPromotedMessage(
        rawData: Data,
        accountID: UUID
    ) throws -> IMAPRawMessageIngestionResult
}

/// Enqueues a server-side move of the promoted message to Inbox.
/// All implementations run on the main actor because they access
/// `ModelContext`.
@MainActor
public protocol WithheldPromotionMoveQueueing {
    /// Returns `true` when the move was propagated to the server queue
    /// (i.e. `MailboxMutationDispatcher.Outcome.propagatedToServer`).
    func enqueueMoveToInbox(
        accountID: UUID,
        messageID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32,
        feedbackEvidence: MailboxSpamFeedbackEvidence?,
        feedbackSourceRoleRaw: String?,
        feedbackProviderSpamScore: Double?
    ) throws -> Bool
}

// MARK: - Coordinator

/// Orchestrates a single withheld-message promotion:
///
/// 1. Fetch raw bytes from the Junk/Trash folder, re-resolving a stale UID
///    via Message-ID when necessary.
/// 2. **Ingest first** — hand the bytes to the ingestion pipeline so the
///    message lands in the corpus regardless of IMAP move outcome.
/// 3. Enqueue the server-side IMAP MOVE to Inbox.
///
/// Ingest-before-move is load-bearing: if the move succeeds but ingest
/// crashes the app, the message is already in Inbox but the user would
/// never see it in Ohia. Ingest-first means the corpus is always ahead.
@MainActor
public final class WithheldPromotionCoordinator {
    private let bodySource: any WithheldPromotionBodySource
    private let ingester: any WithheldPromotionIngesting
    private let moveQueue: any WithheldPromotionMoveQueueing

    public init(
        bodySource: any WithheldPromotionBodySource,
        ingester: any WithheldPromotionIngesting,
        moveQueue: any WithheldPromotionMoveQueueing
    ) {
        self.bodySource = bodySource
        self.ingester = ingester
        self.moveQueue = moveQueue
    }

    /// Promote a withheld message to Inbox.
    ///
    /// - Throws: `WithheldPromotionError` on stale UID, missing message id,
    ///   or unexpected skip. Re-throws any other error from the body source
    ///   or ingestion layer.
    public func promote(
        _ request: WithheldPromotionRequest,
        config: WithheldFetchConfig
    ) async throws -> PromotionOutcome {

        // Step 1: Fetch raw bytes. Rows without provider coordinates must be
        // resolved by Message-ID before fetching; otherwise UID 0 can wait for
        // the transport timeout instead of reaching the stale-UID fallback.
        // Valid cached coordinates still fetch first and re-resolve only when
        // the server reports UIDVALIDITY change or messageNotFound.
        var effectiveUID = request.uid
        var effectiveUIDValidity = request.uidValidity
        var effectiveFolderPath = request.folderPath
        let data: Data
        let hasProviderCoordinates = !request.folderPath.isEmpty
            && request.uid > 0
            && request.uidValidity > 0

        if !hasProviderCoordinates {
            let resolvedFetch = try await resolveAndFetch(request, config: config)
            effectiveUID = resolvedFetch.resolved.uid
            effectiveUIDValidity = resolvedFetch.resolved.uidValidity
            effectiveFolderPath = resolvedFetch.resolved.folderPath ?? request.folderPath
            data = resolvedFetch.data
        } else {
            do {
                data = try await bodySource.fetchBody(
                    uid: request.uid,
                    expectedUIDValidity: request.uidValidity,
                    role: request.role,
                    config: config
                )
            } catch WithheldFolderService.ServiceError.uidValidityChanged,
                    WithheldFolderService.ServiceError.messageNotFound {
                let resolvedFetch = try await resolveAndFetch(request, config: config)
                let resolved = resolvedFetch.resolved
                effectiveUID = resolved.uid
                effectiveUIDValidity = resolved.uidValidity
                effectiveFolderPath = resolved.folderPath ?? request.folderPath
                data = resolvedFetch.data
            }
        }

        // Step 2: Ingest first — corpus update is committed before the IMAP move.
        // The ingested INBOX row carries no server UID (the source UID belongs to
        // the Junk/Trash folder, not INBOX); the move below + the next INBOX poll
        // reconcile its true UID by Message-ID.
        let result = try ingester.ingestPromotedMessage(
            rawData: data,
            accountID: request.accountID
        )

        guard result.disposition != .skipped else {
            throw WithheldPromotionError.ingestUnexpectedlySkipped
        }
        guard let messageID = result.messageId else {
            throw WithheldPromotionError.ingestReturnedNoMessage
        }

        // Step 3: Enqueue the server-side move to Inbox.
        _ = try moveQueue.enqueueMoveToInbox(
            accountID: request.accountID,
            messageID: messageID,
            sourceFolder: effectiveFolderPath,
            uid: effectiveUID,
            uidValidity: effectiveUIDValidity,
            feedbackEvidence: request.feedbackEvidence,
            feedbackSourceRoleRaw: request.role == .junk ? "junk" : nil,
            feedbackProviderSpamScore: request.feedbackProviderSpamScore
        )

        return result.disposition == .insertedNew
            ? .promoted(messageID: messageID)
            : .alreadyPresent(messageID: messageID)
    }

    private func resolveAndFetch(
        _ request: WithheldPromotionRequest,
        config: WithheldFetchConfig
    ) async throws -> (resolved: WithheldResolvedUID, data: Data) {
        guard let messageID = request.messageID,
              let resolved = try await bodySource.resolveUID(
                  messageID: messageID,
                  role: request.role,
                  config: config
              )
        else {
            throw WithheldPromotionError.staleUIDUnresolved
        }

        let data = try await bodySource.fetchBody(
            uid: resolved.uid,
            expectedUIDValidity: resolved.uidValidity,
            role: request.role,
            config: config
        )
        return (resolved, data)
    }
}

// MARK: - Production adapters

/// Bridges `WithheldFolderService` (an actor) to `WithheldPromotionBodySource`.
public struct WithheldFolderServiceBodySource: WithheldPromotionBodySource {
    private let service: WithheldFolderService

    public init(service: WithheldFolderService) {
        self.service = service
    }

    public func fetchBody(
        uid: UInt32,
        expectedUIDValidity: UInt32?,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> Data {
        try await service.fetchBody(
            uid: uid,
            expectedUIDValidity: expectedUIDValidity,
            role: role,
            config: config
        )
    }

    public func resolveUID(
        messageID: String,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> WithheldResolvedUID? {
        try await service.resolveUID(
            messageID: messageID,
            role: role,
            config: config
        )
    }
}

/// Bridges `IngestionOrchestrator` to `WithheldPromotionIngesting`.
///
/// Resolves the `Account` row from `accountID` at call time so the
/// coordinator never holds a cross-context reference.
///
/// After a non-skipped ingest, this adapter calls `context.save()` so the
/// corpus update is durable independent of the subsequent IMAP move. This is
/// the "ingest-first" durability guarantee: even if `enqueueMoveToInbox`
/// throws or returns early, the ingested `Message` is already committed.
@MainActor
public final class OrchestratorPromotionIngester: WithheldPromotionIngesting {
    private let orchestrator: IngestionOrchestrator
    private let context: ModelContext

    /// - Parameters:
    ///   - orchestrator: The ingestion orchestrator that inserts `Message` rows.
    ///   - context: **MUST** be the same `ModelContext` the `orchestrator` was
    ///     constructed with (and the same one the move-queue dispatcher uses),
    ///     so that this adapter's `save()` commits the orchestrator's insert.
    ///     Task 6 wiring passes the shared `mainContext` to all three.
    public init(orchestrator: IngestionOrchestrator, context: ModelContext) {
        self.orchestrator = orchestrator
        self.context = context
    }

    public func ingestPromotedMessage(
        rawData: Data,
        accountID: UUID
    ) throws -> IMAPRawMessageIngestionResult {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == accountID }
        )
        descriptor.fetchLimit = 1
        let accounts = try context.fetch(descriptor)
        guard let account = accounts.first else {
            throw IngesterError.accountNotFound(accountID)
        }
        // serverUID: 0 — the promoted row lands under INBOX, but its true INBOX
        // UID isn't known until the server MOVE completes and INBOX is next
        // polled. A 0 UID marks the row for prompt Message-ID re-resolution by
        // the reconciler, rather than seeding a stale Junk/Trash UID into INBOX.
        let result = try orchestrator.ingestRawRFC5322(
            data: rawData,
            account: account,
            folderPath: "INBOX",
            serverUID: 0,
            isPromotion: true
        )
        // Save immediately so the corpus update is durable independent of
        // the subsequent move. On `.skipped` there is nothing to commit.
        if result.disposition != .skipped {
            try context.save()
        }
        return result
    }

    public enum IngesterError: Error, Equatable {
        case accountNotFound(UUID)
    }
}

/// Bridges `MailboxMutationDispatcher` to `WithheldPromotionMoveQueueing`.
@MainActor
public final class DispatcherPromotionMoveQueue: WithheldPromotionMoveQueueing {
    private let dispatcher: MailboxMutationDispatcher

    public init(dispatcher: MailboxMutationDispatcher) {
        self.dispatcher = dispatcher
    }

    public func enqueueMoveToInbox(
        accountID: UUID,
        messageID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32,
        feedbackEvidence: MailboxSpamFeedbackEvidence?,
        feedbackSourceRoleRaw: String?,
        feedbackProviderSpamScore: Double?
    ) throws -> Bool {
        try dispatcher.reactivatePromotedMessage(messageID: messageID)
        let outcome = try dispatcher.moveToInbox(
            accountID: accountID,
            messageID: messageID,
            sourceFolder: sourceFolder,
            uid: uid,
            uidValidity: uidValidity,
            feedbackEvidence: feedbackEvidence,
            feedbackSourceRoleRaw: feedbackSourceRoleRaw,
            feedbackProviderSpamScore: feedbackProviderSpamScore
        )
        return outcome.propagatedToServer
    }
}
