// MailingListAggregator.swift
// Ingestion-seam aggregation: every newly persisted message carrying a
// List-Id stamps its list fields and upserts the per-account `MailingList`
// ledger row. Runs inline during raw IMAP ingestion,
// so a reset → re-ingest rebuilds the entire subscriptions ledger from
// the mailbox.

import Foundation
import SwiftData
import OhiaCore

public enum MailingListAggregator {

    /// Stamps the parsed list headers onto the message and folds the
    /// message into the account's `MailingList` row for that list identity.
    /// Call after the message row has been inserted (never for dedup-skipped
    /// duplicates — they were already counted). Isolation follows the
    /// caller's: both ingestion paths invoke it with their own
    /// `ModelContext`, exactly like the rest of the persist phase.
    public static func record(
        _ listHeaders: ParsedListHeaders,
        message: Message,
        account: Account,
        context: ModelContext
    ) {
        message.listId = listHeaders.listId
        message.listDisplayName = listHeaders.displayName
        message.listUnsubscribeMailto = listHeaders.unsubscribeMailto
        message.listUnsubscribeURL = listHeaders.unsubscribeURL
        message.listSupportsOneClickUnsubscribe = listHeaders.supportsOneClick

        let accountID = account.id
        let listId = listHeaders.listId
        let messageDate = message.receivedAt ?? message.sentAt ?? message.ingestedAt
        let now = Date()

        let existing: MailingList? = (try? context.fetch(FetchDescriptor<MailingList>(
            predicate: #Predicate<MailingList> { list in
                list.accountID == accountID && list.listId == listId
            }
        )))?.first

        if let list = existing {
            list.messageCount += 1
            list.firstReceivedAt = min(list.firstReceivedAt, messageDate)
            if messageDate >= list.lastReceivedAt {
                list.lastReceivedAt = messageDate
                list.lastFromAddress = message.fromAddress
            }
            // The List-Id display phrase is the authoritative name; keep
            // the latest non-nil one. Fallback names never overwrite a
            // phrase the list itself declared.
            if let phrase = listHeaders.displayName, !phrase.isEmpty {
                list.displayName = phrase
            } else if list.displayName == list.listId, let senderName = message.fromName {
                list.displayName = senderName
            }
            // The verbatim list address is stable per identity; keep the
            // latest non-empty one so a row first seen via a path that
            // couldn't supply it (RFC List-Id) gains it once a delivery
            // copy arrives.
            if let address = listHeaders.listAddress,
               !address.isEmpty {
                list.listAddress = address
            }
            if let mailto = listHeaders.unsubscribeMailto { list.unsubscribeMailto = mailto }
            if let url = listHeaders.unsubscribeURL { list.unsubscribeURL = url }
            if listHeaders.supportsOneClick { list.supportsOneClickUnsubscribe = true }

            // Honest lifecycle. `resolvedStatus` computes "unsubscribed"
            // lazily once the quiet window passes; persist that resolution
            // here (the ingestion of list mail is the only writer that
            // observes time passing for a list) so the reopen rule below
            // operates on the real state.
            if list.statusRaw == MailingListStatus.unsubscribePending,
               list.resolvedStatus(now: messageDate) == MailingListStatus.unsubscribed {
                list.statusRaw = MailingListStatus.unsubscribed
            }
            // Mail arriving after a resolved unsubscribe means the
            // unsubscribe did not take — reopen the pending state so the
            // ledger shows the truth and the quiet window restarts.
            // (Historical backfill older than the request leaves the state
            // alone.)
            if list.statusRaw == MailingListStatus.unsubscribed,
               let requestedAt = list.unsubscribeRequestedAt,
               messageDate > requestedAt {
                list.statusRaw = MailingListStatus.unsubscribePending
            }
            list.updatedAt = now
        } else {
            let fallbackName = listHeaders.displayName
                ?? message.fromName
                ?? listHeaders.listId
            let list = MailingList(
                accountID: accountID,
                listId: listId,
                displayName: fallbackName,
                lastFromAddress: message.fromAddress,
                listAddress: listHeaders.listAddress,
                messageCount: 1,
                firstReceivedAt: messageDate,
                lastReceivedAt: messageDate,
                unsubscribeMailto: listHeaders.unsubscribeMailto,
                unsubscribeURL: listHeaders.unsubscribeURL,
                supportsOneClickUnsubscribe: listHeaders.supportsOneClick,
                createdAt: now,
                updatedAt: now
            )
            context.insert(list)
        }
    }
}
