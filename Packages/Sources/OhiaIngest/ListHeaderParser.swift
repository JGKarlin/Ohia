// ListHeaderParser.swift
// Mailing-list header extraction at the ingestion seam:
//   - List-Id (RFC 2919) → canonical list identity + display phrase
//   - List-Unsubscribe (RFC 2369) → mailto / https targets
//   - List-Unsubscribe-Post (RFC 8058) → one-click eligibility
// Header-driven and language-agnostic — no body heuristics.

import Foundation
import OhiaCore

public struct ParsedListHeaders: Sendable, Equatable {
    /// Canonical identity: the `List-Id` angle-bracket token, lowercased.
    public let listId: String
    /// Display phrase preceding the angle brackets, RFC 2047-decoded and
    /// unquoted; nil when the header carried only the token.
    public let displayName: String?
    /// The list's verbatim email address when the identity came from a
    /// delivery recipient (Bcc / group mail). nil for RFC 2919 `List-Id`
    /// identities, whose token is not necessarily an address. Carried so the
    /// ledger can label the list by its exact address even when the
    /// `listId` token's `@` position is unrecoverable (cross-domain lists).
    public let listAddress: String?
    /// First `mailto:` target from `List-Unsubscribe` (address only,
    /// query parameters preserved after `?` are stripped into the address
    /// + subject pieces by the unsubscribe dispatcher).
    public let unsubscribeMailto: String?
    /// First `http(s):` target from `List-Unsubscribe`.
    public let unsubscribeURL: String?
    /// RFC 8058: `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
    /// together with an HTTPS target.
    public let supportsOneClick: Bool

    public init(
        listId: String,
        displayName: String?,
        listAddress: String? = nil,
        unsubscribeMailto: String?,
        unsubscribeURL: String?,
        supportsOneClick: Bool
    ) {
        self.listId = listId
        self.displayName = displayName
        self.listAddress = listAddress
        self.unsubscribeMailto = unsubscribeMailto
        self.unsubscribeURL = unsubscribeURL
        self.supportsOneClick = supportsOneClick
    }
}

public enum ListHeaderParser {

    /// Deterministic safety/routing fact. This never participates in the
    /// model-generated category vocabulary.
    public static func isAutomatedOrBulk(_ email: ParsedEmail) -> Bool {
        if email.headerValue(for: "List-Id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            return true
        }
        if email.headerValue(for: "List-Unsubscribe")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            return true
        }
        if let precedence = email.headerValue(for: "Precedence")?
            .lowercased()
            .split(whereSeparator: { character in
                character == "," || character.isWhitespace
            }), precedence.contains(where: { $0 == "bulk" || $0 == "list" }) {
            return true
        }
        let autoSubmitted = email.headerValue(for: "Auto-Submitted")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return autoSubmitted?.isEmpty == false && autoSubmitted != "no"
    }

    /// Parses the list-related headers from a parsed message. Returns nil
    /// when the message carries no usable `List-Id` — a `List-Unsubscribe`
    /// without a list identity (some one-off marketing blasts) is not a
    /// subscription the ledger can track.
    public static func parse(_ email: ParsedEmail) -> ParsedListHeaders? {
        guard let rawListId = email.headerValue(for: "List-Id"),
              let identity = parseListId(rawListId) else {
            return nil
        }

        var mailto: String? = nil
        var url: String? = nil
        if let rawUnsubscribe = email.headerValue(for: "List-Unsubscribe") {
            let targets = parseUnsubscribeTargets(rawUnsubscribe)
            mailto = targets.mailto
            url = targets.url
        }

        let oneClick = isOneClick(
            postHeader: email.headerValue(for: "List-Unsubscribe-Post"),
            httpsTarget: url
        )

        return ParsedListHeaders(
            listId: identity.token,
            displayName: identity.display,
            unsubscribeMailto: mailto,
            unsubscribeURL: url,
            supportsOneClick: oneClick
        )
    }

    /// Parses list identity with account-aware delivery semantics.
    ///
    /// RFC `List-Id` remains authoritative unless the visible recipient
    /// headers show that this copy was delivered through a distinct
    /// non-account list address, such as `Bcc: teach@example.edu` while
    /// `List-Id` names a different upstream group. In that case the
    /// delivery list is the user's actual list membership, so it wins. Any
    /// unsubscribe targets from the conflicting `List-Id` are deliberately
    /// dropped rather than attached to the wrong list.
    public static func parse(
        _ email: ParsedEmail,
        accountOwnedAddresses: Set<String>,
        isSentByUser: Bool
    ) -> ParsedListHeaders? {
        let headerIdentity = parse(email)
        guard !isSentByUser,
              headerIdentity != nil || hasListDeliverySignal(email),
              let deliveryIdentity = deliveryListIdentity(
                in: email,
                accountOwnedAddresses: accountOwnedAddresses
              ) else {
            return headerIdentity
        }

        if let headerIdentity,
           headerIdentity.listId == deliveryIdentity.listId {
            return ParsedListHeaders(
                listId: headerIdentity.listId,
                displayName: headerIdentity.displayName ?? deliveryIdentity.displayName,
                listAddress: deliveryIdentity.address,
                unsubscribeMailto: headerIdentity.unsubscribeMailto,
                unsubscribeURL: headerIdentity.unsubscribeURL,
                supportsOneClick: headerIdentity.supportsOneClick
            )
        }

        return ParsedListHeaders(
            listId: deliveryIdentity.listId,
            displayName: deliveryIdentity.displayName,
            listAddress: deliveryIdentity.address,
            unsubscribeMailto: nil,
            unsubscribeURL: nil,
            supportsOneClick: false
        )
    }

    private struct DeliveryListIdentity {
        let listId: String
        let displayName: String?
        /// The recipient's verbatim `local@domain`, before `listId` collapses it.
        let address: String
    }

    private static func deliveryListIdentity(
        in email: ParsedEmail,
        accountOwnedAddresses: Set<String>
    ) -> DeliveryListIdentity? {
        let owned = Set(accountOwnedAddresses.map(normalizedAddress).filter { !$0.isEmpty })
        guard !owned.isEmpty else { return nil }

        let bcc = email.bcc.map(ParticipantNormalizer.parse) ?? []
        let cc = email.cc.map(ParticipantNormalizer.parse) ?? []
        let to = email.to.map(ParticipantNormalizer.parse) ?? []
        let allVisibleRecipients = bcc + cc + to
        guard !allVisibleRecipients.isEmpty else { return nil }

        if allVisibleRecipients.contains(where: { owned.contains(normalizedAddress($0.email)) }) {
            return nil
        }

        // Delivery aliases identify where this copy entered the user's account.
        // Bcc is strongest because it is hidden delivery. Cc comes before To:
        // group offices often To themselves and Cc the actual listservs, so
        // using To first mints bogus "lists" named after the sender/team alias.
        // Google Groups' `X-Spam-Checked-In-Group` / `X-BeenThere` headers
        // strengthen a visible Cc choice when several list aliases are present.
        let fromAddress = (email.from.map(ParticipantNormalizer.parse) ?? [])
            .first.map { normalizedAddress($0.email) }
        let routeAddresses = routedListAddresses(in: email)
        let candidate = firstUsableRecipient(in: bcc, fromAddress: fromAddress)
            ?? firstRecipient(in: cc, matching: routeAddresses, fromAddress: fromAddress)
            ?? firstUsableRecipient(in: cc, fromAddress: fromAddress)
            ?? firstRecipient(in: to, matching: routeAddresses, fromAddress: fromAddress)
            ?? firstUsableRecipient(in: to, fromAddress: fromAddress)
        guard let candidate,
              let listId = canonicalListID(forRecipientAddress: candidate.email) else {
            return nil
        }

        return DeliveryListIdentity(
            listId: listId,
            displayName: candidate.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? candidate.name
                : candidate.email,
            address: normalizedAddress(candidate.email)
        )
    }

    private static func firstUsableRecipient(
        in recipients: [NormalizedParticipant],
        fromAddress: String?
    ) -> NormalizedParticipant? {
        recipients.first {
            let address = normalizedAddress($0.email)
            return !address.isEmpty && address != fromAddress
        }
    }

    private static func firstRecipient(
        in recipients: [NormalizedParticipant],
        matching routeAddresses: [String],
        fromAddress: String?
    ) -> NormalizedParticipant? {
        guard !routeAddresses.isEmpty else { return nil }
        for routeAddress in routeAddresses {
            let normalizedRoute = normalizedAddress(routeAddress)
            guard !normalizedRoute.isEmpty else { continue }
            if let match = recipients.first(where: {
                let address = normalizedAddress($0.email)
                return !address.isEmpty && address != fromAddress && address == normalizedRoute
            }) {
                return match
            }
        }
        return nil
    }

    private static func routedListAddresses(in email: ParsedEmail) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        func appendAddresses(from headerName: String) {
            for value in headerValues(named: headerName, in: email) {
                for participant in ParticipantNormalizer.parse(value) {
                    let address = normalizedAddress(participant.email)
                    if !address.isEmpty, seen.insert(address).inserted {
                        result.append(address)
                    }
                }
            }
        }

        appendAddresses(from: "X-Spam-Checked-In-Group")
        appendAddresses(from: "X-BeenThere")
        return result
    }

    private static func hasListDeliverySignal(_ email: ParsedEmail) -> Bool {
        let listHeaderNames: Set<String> = [
            "list-unsubscribe",
            "list-unsubscribe-post",
            "list-post",
            "list-help",
            "list-subscribe",
            "list-archive",
            "mailing-list",
            "x-mailing-list",
            "x-beenthere",
            "x-list-id",
        ]
        if email.headers.contains(where: { listHeaderNames.contains($0.name.lowercased()) }) {
            return true
        }
        if let precedence = email.headerValue(for: "Precedence")?.lowercased() {
            return precedence.contains("list") || precedence.contains("bulk")
        }
        return false
    }

    private static func headerValues(named name: String, in email: ParsedEmail) -> [String] {
        let lowered = name.lowercased()
        return email.headers.compactMap { header in
            header.name.lowercased() == lowered ? header.value : nil
        }
    }

    private static func normalizedAddress(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func canonicalListID(forRecipientAddress address: String) -> String? {
        let normalized = normalizedAddress(address)
        let parts = normalized.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return nil
        }
        return "\(parts[0]).\(parts[1])"
    }

    // MARK: - List-Id (RFC 2919)

    /// `List-Id: Campus Announcements <announce.lists.example.edu>` →
    /// (token: "announce.lists.example.edu", display: "Campus Announcements").
    /// Tolerates bare tokens without angle brackets (seen in the wild).
    static func parseListId(_ raw: String) -> (token: String, display: String?)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let open = value.lastIndex(of: "<"),
           let close = value[open...].firstIndex(of: ">") {
            let token = value[value.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !token.isEmpty else { return nil }
            var phrase = value[..<open]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            phrase = MIMEHeaderDecoder.decodeEncodedWords(phrase)
            if phrase.hasPrefix("\""), phrase.hasSuffix("\""), phrase.count >= 2 {
                phrase = String(phrase.dropFirst().dropLast())
            }
            return (token, phrase.isEmpty ? nil : phrase)
        }

        // Bare token form. Reject values with spaces — those are malformed
        // phrases, not identities.
        let bare = value.lowercased()
        guard !bare.contains(" ") else { return nil }
        return (bare, nil)
    }

    // MARK: - List-Unsubscribe (RFC 2369)

    /// Comma-separated `<uri>` entries, possibly wrapped in comments.
    /// Returns the first mailto address and the first http(s) URL.
    static func parseUnsubscribeTargets(_ raw: String) -> (mailto: String?, url: String?) {
        var mailto: String? = nil
        var url: String? = nil

        var search = raw[raw.startIndex...]
        while let open = search.firstIndex(of: "<") {
            guard let close = search[open...].firstIndex(of: ">") else { break }
            let uri = search[search.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = uri.lowercased()
            if mailto == nil, lowered.hasPrefix("mailto:") {
                // Strip the scheme and any ?subject=… query — the dispatcher
                // builds its own subject ("unsubscribe") per RFC 2369 §3.2.
                // `prefix(while:)` (not `split`) so empty addresses
                // (`<mailto:>`, `<mailto:?q>`) yield nothing instead of
                // trapping or capturing the query string as the address.
                let address = uri.dropFirst("mailto:".count)
                let bare = address.prefix(while: { $0 != "?" })
                if !bare.isEmpty { mailto = String(bare) }
            } else if url == nil, lowered.hasPrefix("https:") || lowered.hasPrefix("http:") {
                url = uri
            }
            if mailto != nil && url != nil { break }
            search = search[search.index(after: close)...]
        }
        return (mailto, url)
    }

    // MARK: - One-click (RFC 8058)

    static func isOneClick(postHeader: String?, httpsTarget: String?) -> Bool {
        guard let postHeader,
              postHeader.lowercased().contains("list-unsubscribe=one-click"),
              let httpsTarget,
              httpsTarget.lowercased().hasPrefix("https:") else {
            return false
        }
        return true
    }
}
