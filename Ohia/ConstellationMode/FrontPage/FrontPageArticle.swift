import Foundation
import OhiaCore
import OhiaML

/// Per-article view model for the Front Page lens. Built off-main by
/// `FrontPageDataController` from the decoded `Message` + the composer's
/// `FrontPageComposedArticle`. Display-ready: subjects are MIME-decoded,
/// senders resolved, and datelines render through a cached
/// `RelativeDateTimeFormatter` (never a chained `Date.FormatStyle`, which has
/// tripped the type-checker in this codebase).
///
/// `summary` is the sanitized `bodySummary` prepared at snapshot-build time and
/// may be `nil` (row F is generated on demand). The view overlays the prepared live
/// `summaryByMessageId` map on top, and missing summaries are resolved
/// through the app's on-demand channel.
struct FrontPageArticle: Identifiable, Sendable, Equatable {
    let id: UUID
    let messageIdString: String
    let headline: String
    let byline: String
    /// Normalized-ready sender address (the message's `fromAddress`), used to
    /// key the per-sender remote-image allowlist. Empty for sent mail / unknown.
    let senderAddress: String
    /// Display name of the account that owns this message. Used as help text
    /// for the visual account-color mark.
    let accountDisplayName: String
    /// Email address of the owning account. Used only to choose the same
    /// provider/generic glyph family as the account chips.
    let accountEmailAddress: String
    /// Stored `Account.colorIndex` resolved while building the snapshot.
    let accountColorIndex: Int
    let date: Date
    /// Best-known read timestamp from the corpus row. `nil` for unread rows
    /// and for older stores that have not re-ingested or changed read state.
    var readAt: Date?
    /// Prepared by the data controller before publication. Invalid summaries
    /// are nil; rendering never repeats tokenization or quoted-text parsing.
    let summary: String?
    let bodyPreview: String?
    /// Canonical classification snapshot. `nil` means pending; a valid
    /// classification with no resolved Purpose remains explicitly uncertain.
    /// Mutable only for the reader's optimistic manual-edit reflection.
    var classification: MailClassification?
    /// Independent user-defined keys, restricted to the live catalog at
    /// snapshot-build time.
    var customCategoryKeys: Set<String> = []
    /// True only when this message carries both List-Id metadata and canonical
    /// Group Delivery. Drives conditional Ignore controls.
    let isListIgnoreEligible: Bool
    /// Factual List-ID presence. Drives the Lists presentation; unlike
    /// `isListIgnoreEligible` it does not require a resolved Purpose, which is
    /// exactly the case the Lists presentation exists for.
    let isMailingList: Bool
    /// Whether an address owned by the message's account appears explicitly
    /// in To. Allows a list-delivered message to retain Correspondence.
    var isDirectToUser: Bool = false
    let isSentByUser: Bool
    var isUnread: Bool
    /// Shared attention state: true only while this message still needs a reply.
    /// `var` so the focused reader can optimistically reflect a reply/
    /// confirmation action ahead of the authoritative snapshot rebuild
    /// (`withAttentionState`), the same way `isFlagged` carries flag optimism.
    var isActionable: Bool
    /// True when this needs-reply message is already in the Composer queue.
    let isInComposerQueue: Bool
    /// Shared attention state: true only while this message still needs confirmation.
    var requiresConfirmation: Bool
    /// True once a reply was sent, detected as reply evidence, or manually
    /// marked replied through the shared message-attention actions.
    var isReplied: Bool
    /// True once the user manually marked the message confirmed through the
    /// shared message-attention actions.
    var isConfirmed: Bool
    /// Present only after an explicit user action. There is deliberately no
    /// inverse "not resolved" tag.
    var isResolved: Bool = false
    /// True when structured interpretation extracted deadline evidence.
    let hasDeadline: Bool
    /// Surface text for the first extracted deadline, when available.
    var deadlineText: String? = nil
    /// Mirror of the message's IMAP `\Flagged` state, so the card's hover
    /// action and the right-column flag toggle can render and flip it without
    /// a SwiftData re-fetch. `var` so a flag toggle can optimistically update
    /// the rendered article ahead of the authoritative snapshot rebuild
    /// (`withFlagState`), the same way `isUnread` carries read-state optimism.
    var isFlagged: Bool
    let isRevivedAfterInactiveGap: Bool
    let sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
    let hasAttachments: Bool
    /// On-disk path to the representative `image/*` attachment, or `nil` for a
    /// text-only card.
    let imagePath: String?
    let bodyHtmlPath: String?
    let bodyTextPath: String?
    /// Raw RFC 5322 artifact saved by ingestion. Used as a reader fallback
    /// when a message has no standalone body artifact, including blank mail.
    let rawPath: String?

    /// Relative dateline, e.g. "2 hours ago". Cached formatter — no chained
    /// `Date.FormatStyle`.
    func dateline(relativeTo reference: Date = .now) -> String {
        FrontPageRelativeDate.string(for: date, relativeTo: reference)
    }

    var purposePresentation: FrontPagePurposePresentation {
        FrontPagePurposePresentation(
            classification: classification,
            isMailingList: isMailingList,
            isDirectToUser: isDirectToUser
        )
    }

    /// Purpose label for the card badge. Pending and uncertain are explicit
    /// non-Purpose states and never masquerade as Other.
    var purposeLabel: String {
        purposePresentation.displayLabel
    }

    var accountColor: AccountColor {
        AccountColorPalette.color(forIndex: accountColorIndex)
    }

    var statusDescriptor: MessageStatusDescriptor {
        MessageStatusDescriptor(
            isSentByUser: isSentByUser,
            isRead: !isUnread,
            isReplied: isReplied,
            isConfirmed: isConfirmed,
            isResolved: isResolved,
            needsReply: isActionable,
            needsConfirmation: requiresConfirmation,
            hasDeadline: hasDeadline,
            deadlineText: deadlineText,
            isFlagged: isFlagged,
            isRevivedAfterInactiveGap: isRevivedAfterInactiveGap,
            sharedEvidenceKinds: sharedEvidenceKinds
        )
    }

    func withReadState(isRead: Bool, readAt overrideReadAt: Date? = nil) -> FrontPageArticle {
        var copy = self
        copy.isUnread = !isRead
        copy.readAt = isRead ? (overrideReadAt ?? readAt ?? Date()) : nil
        return copy
    }

    /// Returns a copy with the flag state flipped, for optimistic UI ahead of
    /// the authoritative snapshot rebuild. Mirrors `withReadState`.
    func withFlagState(_ isFlagged: Bool) -> FrontPageArticle {
        var copy = self
        copy.isFlagged = isFlagged
        return copy
    }

    /// Returns a copy with canonical classification and independent custom
    /// assignments replaced for optimistic reader UI.
    func withClassificationState(
        classification: MailClassification?,
        customCategoryKeys: Set<String>
    ) -> FrontPageArticle {
        var copy = self
        copy.classification = classification
        copy.customCategoryKeys = customCategoryKeys
        return copy
    }

    /// Returns a copy with the shared attention state replaced, for optimistic
    /// reader UI after a reply / confirmation action. Replied and confirmed
    /// messages leave the Front Page feed, so the rebuilt snapshot drops the
    /// article and the open reader falls back to its stale focus-time copy;
    /// this transform lets the workspace correct that fallback. Mirrors
    /// `withFlagState` / `withReadState`.
    func withAttentionState(
        isActionable: Bool,
        requiresConfirmation: Bool,
        isReplied: Bool,
        isConfirmed: Bool
    ) -> FrontPageArticle {
        var copy = self
        copy.isActionable = isActionable
        copy.requiresConfirmation = requiresConfirmation
        copy.isReplied = isReplied
        copy.isConfirmed = isConfirmed
        return copy
    }

    /// Both inputs are sanitized at their publication boundaries: the data
    /// controller prepares the capture, and completion/on-demand processing
    /// prepares the live map. The latest live value wins without rescanning
    /// unchanged prose during layout, selection, or pointer movement.
    func resolvedSummary(liveSummaries: [String: String]) -> String? {
        liveSummaries[messageIdString] ?? summary
    }

    /// Text for the Front Page lede slot. The slot stays empty until a
    /// generated or live summary is available.
    func resolvedLede(liveSummaries: [String: String]) -> String? {
        resolvedSummary(liveSummaries: liveSummaries)
    }

    /// True when this article can still benefit from the shared on-demand
    /// summary channel. Used by hover, selection, and reader focus so Front
    /// Page does not rely on one fragile interaction to fill a missing lede.
    func needsOnDemandSummary(
        liveSummaries: [String: String],
        unavailableMessageIds: Set<String>
    ) -> Bool {
        resolvedSummary(liveSummaries: liveSummaries) == nil
            && !unavailableMessageIds.contains(messageIdString)
    }
}

/// Cached relative-date formatting for datelines. A single shared
/// `RelativeDateTimeFormatter` is reused (allocating one per cell is
/// expensive and the chained `.formatted(...)` style has hit type-checker
/// limits here). Mirrors the file-level cached-`DateFormatter` idiom in
/// `ProjectsWorkspaceView`.
enum FrontPageRelativeDate {
    static func string(for date: Date, relativeTo reference: Date) -> String {
        frontPageRelativeFormatter.localizedString(for: date, relativeTo: reference)
    }
}

private let frontPageRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .named
    return f
}()
