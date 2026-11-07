import Foundation
import SwiftData

@Model
public final class OutboxItem {
    public var id: UUID
    public var account: Account?
    public var draft: Draft?
    public var message: Message?

    public var fromAddress: String
    public var fromDisplayName: String?
    public var replyToAddress: String?
    public var toAddressesJSON: String
    public var ccAddressesJSON: String?
    public var bccAddressesJSON: String?
    public var subject: String
    public var plainBody: String
    public var htmlBody: String?
    public var inReplyTo: String?
    public var referencesChain: String?
    public var attachmentPathsJSON: String?

    /// JSON `[OutboxInlineImage]` — images referenced by `cid:` URLs inside
    /// `htmlBody`, emitted as `multipart/related` inline parts at send.
    /// Nil for mail without embedded images. Optional for lightweight
    /// migration.
    public var inlineImagesJSON: String?

    public var messageIDHeader: String

    public var status: OutboxStatus
    public var createdAt: Date
    public var lastAttemptAt: Date?
    /// Submission timing, separate from retry counts and post-send learning.
    public var submissionAttemptCount: Int = 0
    public var lastAttemptFinishedAt: Date?
    public var providerAcceptedAt: Date?
    /// Safe diagnostic category; contains no provider text or message content.
    public var deliveryErrorCategory: String?
    public var nextAttemptAfter: Date?
    public var attempts: Int
    public var lastError: String?
    public var cancellationRequested: Bool

    /// Durable "play the sent-mail sound" marker, set when the SMTP server
    /// accepts the message and cleared by the app after it plays the chime.
    /// Lives on the row (not a notification payload) so a dropped distributed
    /// notification still self-heals via the launch sweep, and a spoofed one
    /// fails the lookup. The app consumes it atomically (read → play → clear
    /// in one save), so the sound fires exactly once per send.
    public var sentConfirmationPendingPlayback: Bool = false
    /// Frozen copy of the generation basis of the revision the sent body was
    /// built on, captured when the user sends. A later change to the live
    /// Draft cannot rewrite the training input for this email.
    public var generationBasisJSON: String?

    /// The generated revision the sent body derives from, frozen with the
    /// basis, so training measures the author's edits against the body the
    /// author actually edited whatever the live draft does afterwards.
    /// Optional for lightweight migration.
    public var baseRevisionID: UUID?

    /// Durable, idempotent post-SMTP learning state. Optional primitives keep
    /// existing stores lightweight-migratable. A nil processed timestamp means
    /// the sent row is eligible for retry; queued/failed rows are never read.
    public var trainingFeedbackProcessedAt: Date?
    public var trainingFeedbackDispositionRaw: String?
    public var trainingFeedbackError: String?

    /// Send-time learning choice. Currently always the learning-enabled
    /// default — no producer writes it, and the ledger records it as an
    /// automatic (not user-decided) preference. Stage 3 ships the explicit
    /// Composer control that writes real decisions here; untouched-generation
    /// protection meanwhile rests on the recorder's generated-revision match.
    public var learnFromSend: Bool = true

    @Relationship(deleteRule: .nullify, inverse: \SentTrainingEvidence.sourceOutbox)
    public var sentTrainingEvidence: SentTrainingEvidence?

    /// Durable, idempotent post-SMTP translation-glossary correction state.
    /// Nil means an already-sent row remains eligible for local reconciliation.
    /// These are optional so existing stores remain lightweight-migratable.
    public var translationGlossaryFeedbackProcessedAt: Date?
    public var translationGlossaryFeedbackError: String?

    /// JSON-encoded approved `TrainingSignal` values from the edit review.
    /// Nil means no review decision was captured; `[]` means the user
    /// explicitly dismissed every signal and elevated edit learning is off.
    public var approvedTrainingSignalsJSON: String?

    /// Immutable style decision frozen with the queued body.
    public var styleControlSnapshotJSON: String?

    public init(
        fromAddress: String,
        toAddressesJSON: String,
        ccAddressesJSON: String? = nil,
        bccAddressesJSON: String? = nil,
        subject: String,
        plainBody: String,
        htmlBody: String? = nil,
        inReplyTo: String? = nil,
        referencesChain: String? = nil,
        attachmentPathsJSON: String? = nil,
        messageIDHeader: String
    ) {
        self.id = UUID()
        self.fromAddress = fromAddress
        self.toAddressesJSON = toAddressesJSON
        self.ccAddressesJSON = ccAddressesJSON
        self.bccAddressesJSON = bccAddressesJSON
        self.subject = subject
        self.plainBody = plainBody
        self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo
        self.referencesChain = referencesChain
        self.attachmentPathsJSON = attachmentPathsJSON
        self.messageIDHeader = messageIDHeader
        self.status = .queued
        self.createdAt = Date()
        self.attempts = 0
        self.cancellationRequested = false
        self.sentConfirmationPendingPlayback = false
    }

    public var styleControlSnapshot: StyleControlSnapshot? {
        get { StyleControlSnapshot.decodeJSON(styleControlSnapshotJSON) }
        set { styleControlSnapshotJSON = newValue?.jsonString }
    }
}

public enum SentTrainingFeedbackDisposition: String, Codable, Sendable {
    case recorded
    case noUserAuthoredDelta
    case dismissed
    case notEligible
}

/// One inline image queued for send: a local file emitted as a
/// `multipart/related` part whose `Content-ID` the `htmlBody` references
/// via `cid:`. Persisted as JSON in `OutboxItem.inlineImagesJSON`.
public struct OutboxInlineImage: Codable, Sendable, Equatable {
    public var path: String
    /// Content-ID without angle brackets (e.g. `sig-<uuid>@ohia`).
    public var contentID: String
    public var mimeType: String

    public init(path: String, contentID: String, mimeType: String) {
        self.path = path
        self.contentID = contentID
        self.mimeType = mimeType
    }

    public static func encode(_ images: [OutboxInlineImage]) -> String? {
        guard !images.isEmpty,
              let data = try? JSONEncoder().encode(images) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String?) -> [OutboxInlineImage] {
        guard let json, let data = json.data(using: .utf8),
              let images = try? JSONDecoder().decode([OutboxInlineImage].self, from: data) else {
            return []
        }
        return images
    }
}
