import Foundation
import SwiftData

/// Subscription lifecycle states for a `MailingList`. Raw strings (not a
/// Codable enum) so SwiftData lightweight migration and `#Predicate`
/// translation never see a custom enum type.
public enum MailingListStatus {
    /// Mail is arriving and no unsubscribe has been requested.
    public static let subscribed = "subscribed"
    /// The user triggered an unsubscribe; the list hasn't been quiet long
    /// enough to call it done. `MailingList.resolvedStatus` flips this to
    /// `unsubscribed` once the cadence-derived quiet window passes.
    public static let unsubscribePending = "unsubscribePending"
    /// No mail since the unsubscribe request for longer than the list's
    /// quiet window — the unsubscribe took.
    public static let unsubscribed = "unsubscribed"
}

/// One mailing list / listserv / group an account receives, aggregated at
/// ingestion from RFC 2919 `List-Id` headers. The ledger row the
/// Subscriptions surface renders: identity, volume, cadence, and the
/// unsubscribe mechanics captured from the most recent message.
@Model
public final class MailingList {
    public var id: UUID

    /// Owning account — list identities never cross accounts.
    public var accountID: UUID

    /// Canonical RFC 2919 identity (angle-bracket token, lowercased).
    /// Unique per account; the aggregation upserts on (accountID, listId).
    public var listId: String

    /// Best-known human name: the `List-Id` display phrase when one was
    /// ever seen, else the most recent sender display name, else the
    /// list-id token itself.
    public var displayName: String

    /// The most recent sender address mail arrived from (the list's
    /// envelope identity for display).
    public var lastFromAddress: String

    /// The list's verbatim email address when the identity was resolved
    /// from a delivery recipient (Bcc / group mail) — the exact
    /// `local@domain` captured before the canonical `listId` collapses
    /// `@`→`.`. nil for RFC 2919 `List-Id` lists, whose token is not an
    /// address. The Subscriptions ledger labels each row by this address;
    /// rows without it fall back to reconstructing one from the `listId`.
    /// Optional so existing rows migrate without a crash and a re-ingest
    /// backfills it.
    public var listAddress: String?

    public var messageCount: Int
    public var firstReceivedAt: Date
    public var lastReceivedAt: Date

    // Unsubscribe mechanics from the most recent message that carried them.
    public var unsubscribeMailto: String?
    public var unsubscribeURL: String?
    /// RFC 8058 one-click eligible (HTTPS POST, no browser round-trip).
    public var supportsOneClickUnsubscribe: Bool

    /// `MailingListStatus` raw string.
    public var statusRaw: String
    public var unsubscribeRequestedAt: Date?
    /// How the unsubscribe was performed ("oneClick", "mailto", "url");
    /// informational for the ledger.
    public var unsubscribeMethodRaw: String?

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        listId: String,
        displayName: String,
        lastFromAddress: String,
        listAddress: String? = nil,
        messageCount: Int = 0,
        firstReceivedAt: Date,
        lastReceivedAt: Date,
        unsubscribeMailto: String? = nil,
        unsubscribeURL: String? = nil,
        supportsOneClickUnsubscribe: Bool = false,
        statusRaw: String = MailingListStatus.subscribed,
        unsubscribeRequestedAt: Date? = nil,
        unsubscribeMethodRaw: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.listId = listId
        self.displayName = displayName
        self.lastFromAddress = lastFromAddress
        self.listAddress = listAddress
        self.messageCount = messageCount
        self.firstReceivedAt = firstReceivedAt
        self.lastReceivedAt = lastReceivedAt
        self.unsubscribeMailto = unsubscribeMailto
        self.unsubscribeURL = unsubscribeURL
        self.supportsOneClickUnsubscribe = supportsOneClickUnsubscribe
        self.statusRaw = statusRaw
        self.unsubscribeRequestedAt = unsubscribeRequestedAt
        self.unsubscribeMethodRaw = unsubscribeMethodRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension MailingList {
    /// Average messages per week over the observed span. Lists seen once
    /// report a span of one day so the rate stays finite.
    var messagesPerWeek: Double {
        let span = max(lastReceivedAt.timeIntervalSince(firstReceivedAt), 86_400)
        return Double(messageCount) / (span / 604_800)
    }

    /// How long the list must stay quiet after an unsubscribe request
    /// before the pending state resolves: twice the average inter-message
    /// gap, clamped to [3 days, 30 days]. High-volume lists confirm fast;
    /// monthly digests get a real chance to miss a cycle.
    var quietConfirmationWindow: TimeInterval {
        let averageGap = max(
            lastReceivedAt.timeIntervalSince(firstReceivedAt) / Double(max(messageCount, 1)),
            86_400
        )
        return min(max(averageGap * 2, 3 * 86_400), 30 * 86_400)
    }

    /// Status with the quiet window applied at read time: a pending
    /// unsubscribe whose list has stayed silent past the window reads as
    /// unsubscribed. New arrivals re-open the pending state through the
    /// aggregation path (which bumps `lastReceivedAt`).
    func resolvedStatus(now: Date = .now) -> String {
        guard statusRaw == MailingListStatus.unsubscribePending,
              let requestedAt = unsubscribeRequestedAt else {
            return statusRaw
        }
        let lastSignal = max(lastReceivedAt, requestedAt)
        if now.timeIntervalSince(lastSignal) > quietConfirmationWindow {
            return MailingListStatus.unsubscribed
        }
        return statusRaw
    }
}
