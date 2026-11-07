// UnsubscribeDispatcher.swift
// Executes a mailing-list unsubscribe with the right escalation:
//   1. RFC 8058 one-click — HTTPS POST "List-Unsubscribe=One-Click",
//      no browser, no confirmation page.
//   2. RFC 2369 mailto — a real tracked send through the outbox.
//   3. URL fallback — handed back to the caller to open in the browser
//      (AppKit stays out of this package).
// On success the list flips to `unsubscribePending`; the quiet-window
// resolution in `MailingList.resolvedStatus` decides when it reads as done.

import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class UnsubscribeDispatcher {

    /// How the unsubscribe was (or should be) performed.
    public enum Outcome: Equatable, Sendable {
        /// RFC 8058 POST succeeded — nothing else to do.
        case oneClick
        /// An unsubscribe mail was queued through the outbox.
        case mailtoQueued
        /// No automatic mechanism worked; the caller should open this URL
        /// in the browser. The pending state is already recorded.
        case openURL(URL)
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        /// The list carries no unsubscribe mechanism at all.
        case noMechanism
        /// A mailto unsubscribe needs a send identity and none resolved.
        case noIdentity
        /// The advertised mailto target does not parse as an address.
        case invalidUnsubscribeAddress(String)

        public var errorDescription: String? {
            switch self {
            case .noMechanism:
                return "The list does not advertise an unsubscribe mechanism."
            case .noIdentity:
                return "No send identity is configured for this account."
            case .invalidUnsubscribeAddress(let address):
                return "The list's unsubscribe address is not valid: \(address)"
            }
        }
    }

    private let context: ModelContext
    private let jobQueue: JobQueue
    private let urlSession: URLSession

    public init(
        context: ModelContext,
        jobQueue: JobQueue,
        urlSession: URLSession = .shared
    ) {
        self.context = context
        self.jobQueue = jobQueue
        self.urlSession = urlSession
    }

    /// Runs the escalation for one list. Marks the list
    /// `unsubscribePending` with the method used before returning.
    public func unsubscribe(from list: MailingList, account: Account) async throws -> Outcome {
        // 1. One-click (RFC 8058).
        if list.supportsOneClickUnsubscribe,
           let urlString = list.unsubscribeURL,
           let url = URL(string: urlString),
           url.scheme?.lowercased() == "https" {
            if await postOneClick(to: url) {
                markPending(list, method: "oneClick")
                try context.save()
                return .oneClick
            }
            // Fall through — a failed POST escalates to mailto / URL.
        }

        // 2. mailto through the outbox (RFC 2369).
        if let mailto = list.unsubscribeMailto, !mailto.isEmpty {
            try queueUnsubscribeMail(to: mailto, account: account)
            markPending(list, method: "mailto")
            try context.save()
            return .mailtoQueued
        }

        // 3. Browser fallback.
        if let urlString = list.unsubscribeURL, let url = URL(string: urlString) {
            markPending(list, method: "url")
            try context.save()
            return .openURL(url)
        }

        throw Error.noMechanism
    }

    // MARK: - One-click POST

    private func postOneClick(to url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.timeoutInterval = 20
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - mailto via outbox

    private func queueUnsubscribeMail(to address: String, account: Account) throws {
        // A target that doesn't parse must never reach the outbox — it
        // would become a permanently retrying send.
        guard (try? MailAddressParser.parseOne(address)) != nil else {
            throw Error.invalidUnsubscribeAddress(address)
        }
        guard let identity = account.resolveIdentity(for: nil) else {
            throw Error.noIdentity
        }
        guard !identity.address.isEmpty else { throw Error.noIdentity }

        let outgoingID = "<\(UUID().uuidString)@ohia.\(ProcessInfo.processInfo.hostName)>"
        let toJSON = "[\"\(address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"]"

        let item = OutboxItem(
            fromAddress: identity.address,
            toAddressesJSON: toJSON,
            ccAddressesJSON: nil,
            bccAddressesJSON: nil,
            subject: "unsubscribe",
            plainBody: "unsubscribe",
            htmlBody: nil,
            inReplyTo: nil,
            referencesChain: nil,
            attachmentPathsJSON: nil,
            messageIDHeader: outgoingID
        )
        item.fromDisplayName = identity.displayName
        item.account = account
        context.insert(item)
        try jobQueue.enqueue(type: .sendOutbox, priority: 1, context: context)
    }

    private func markPending(_ list: MailingList, method: String) {
        list.statusRaw = MailingListStatus.unsubscribePending
        list.unsubscribeRequestedAt = Date()
        list.unsubscribeMethodRaw = method
        list.updatedAt = Date()
    }
}
