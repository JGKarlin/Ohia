import Foundation
import OhiaCore

/// Immutable, `Sendable` per-message input to the Front Page composer. Carries
/// only the signals the ranking + budget + grouping engine needs; file paths,
/// rendered summaries, and view-layer derivations stay in the app layer
/// (`FrontPageArticle`). Built off-main by `FrontPageDataController` from the
/// same decoded `Message` / `MessageFilterRow` the Projects pipeline produces.
///
/// Tiering is deliberately driven by the shared message-attention state
/// (`isActionable` = open reply obligation, `requiresConfirmation` = open
/// confirmation obligation) plus the email date. No language-specific
/// heuristic participates in ranking.
public struct FrontPageArticleInput: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let subject: String
    public let fromName: String?
    public let fromAddress: String
    public let isSentByUser: Bool
    public let isRead: Bool
    /// Shared attention state: true only while this message still needs a reply.
    public let isActionable: Bool
    /// Shared attention state: true only while this message still needs confirmation.
    public let requiresConfirmation: Bool
    /// True after the user has manually acknowledged a confirmation-required
    /// message. Front Page keeps these promoted until the user resolves them.
    public let isConfirmed: Bool
    /// Legacy Row-G attention bucket retained for display/context, not tiering.
    public let messageType: MessageType
    public let hasDeadline: Bool
    /// Canonical classification snapshot. `nil` means classification is still
    /// pending; a valid document with no resolved Purpose is presented as
    /// uncertain.
    public let classification: MailClassification?
    /// Deterministic RFC 2919 list membership, derived from `Message.listId`.
    public let isMailingList: Bool
    /// Whether an address owned by the message's account appears explicitly
    /// in the RFC To field. This is the only list-delivery exception that may
    /// retain Correspondence presentation.
    public let isDirectToUser: Bool
    /// Whether a representative `image/*` attachment exists (the photo).
    /// Breaks a near-tie for the lead slot.
    public let hasImage: Bool
    /// Whether a generated `bodySummary` (row F) is available. Nil summaries
    /// are filled on demand (hover) by the app layer, so this only informs
    /// layout, never tiering.
    public let hasSummary: Bool
    /// Identity of the persistent `MessageThread` this message belongs to, when
    /// one exists. The composer groups messages sharing a `threadID` into a
    /// single package unit. `nil` for an unthreaded (singleton) message.
    public let threadID: UUID?

    public init(
        id: UUID,
        date: Date,
        subject: String,
        fromName: String?,
        fromAddress: String,
        isSentByUser: Bool,
        isRead: Bool,
        isActionable: Bool,
        requiresConfirmation: Bool,
        isConfirmed: Bool = false,
        messageType: MessageType,
        hasDeadline: Bool,
        classification: MailClassification?,
        isMailingList: Bool = false,
        isDirectToUser: Bool = false,
        hasImage: Bool,
        hasSummary: Bool,
        threadID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.subject = subject
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.isSentByUser = isSentByUser
        self.isRead = isRead
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.isConfirmed = isConfirmed
        self.messageType = messageType
        self.hasDeadline = hasDeadline
        self.classification = classification
        self.isMailingList = isMailingList
        self.isDirectToUser = isDirectToUser
        self.hasImage = hasImage
        self.hasSummary = hasSummary
        self.threadID = threadID
    }

    /// True while the shared attention resolver says this message needs a reply.
    public var requiresAction: Bool {
        isActionable
    }

    /// True while the shared attention resolver says this message needs confirmation.
    public var isConfirmation: Bool {
        requiresConfirmation
    }

    /// True while the article still belongs in the confirmation lane. An
    /// explicit confirmed mark removes the unread/needs-confirmation work, but
    /// stays prominent until the user resolves the message.
    public var isConfirmationActive: Bool {
        requiresConfirmation || isConfirmed
    }

    /// Front Page sections use resolved Purpose when available. Factual list
    /// membership supplies the Lists presentation while Purpose is unresolved.
    public var purposePresentation: FrontPagePurposePresentation {
        FrontPagePurposePresentation(
            classification: classification,
            isMailingList: isMailingList,
            isDirectToUser: isDirectToUser
        )
    }
}
