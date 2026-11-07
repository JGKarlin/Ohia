import Foundation

/// User-visible scope for a reply draft's recipient list.
public enum ReplyRecipientMode: String, Codable, Sendable, Equatable {
    case reply
    case replyAll
    case custom
}

/// Address-only recipient projection shared by Composer, remote Drafts sync,
/// and final send. Display names remain a UI concern; delivery uses the exact
/// normalized addresses represented here.
public struct ReplyRecipientSet: Sendable, Equatable {
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]

    public init(to: [String], cc: [String] = [], bcc: [String] = []) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }

    public var recipientCount: Int {
        to.count + cc.count + bcc.count
    }
}

/// RFC-aware default recipient construction for reply drafts.
///
/// Reply targets prefer the inbound `Reply-To` header and fall back to
/// `From`. Reply All then retains the original To/Cc split, excluding every
/// address owned by the receiving account, suppressing Bcc, and deduplicating
/// case-insensitively with To taking precedence over Cc.
public enum ReplyRecipientPolicy {
    public static func defaultRecipients(
        for message: Message,
        mode: ReplyRecipientMode
    ) -> ReplyRecipientSet {
        let ownedAddresses = message.account?.ownedEmailAddresses ?? []
        let storedReplyTargets = ComposeAddressEncoding.decode(message.replyToAddressesJSON)
        let replyTargets = uniqueExternalAddresses(
            from: storedReplyTargets.isEmpty
                ? [message.fromAddress]
                : storedReplyTargets,
            excluding: ownedAddresses
        )

        guard mode == .replyAll else {
            return ReplyRecipientSet(to: replyTargets)
        }

        let originalTo = orderedAddresses(for: .to, in: message)
        let originalCc = orderedAddresses(for: .cc, in: message)
        let to = uniqueExternalAddresses(
            from: replyTargets + originalTo,
            excluding: ownedAddresses
        )
        let toSet = Set(to.map(normalizedAddress))
        let cc = uniqueExternalAddresses(
            from: originalCc,
            excluding: ownedAddresses.union(toSet)
        )
        return ReplyRecipientSet(to: to, cc: cc)
    }

    /// Recipient values that delivery should use. Explicit draft overrides
    /// win; absent fields fall back to the selected mode's policy defaults.
    public static func effectiveRecipients(for draft: Draft) -> ReplyRecipientSet {
        guard let message = draft.message else {
            return ReplyRecipientSet(to: [])
        }
        let defaults = defaultRecipients(
            for: message,
            mode: draft.resolvedReplyRecipientMode
        )
        let to = draft.replyToAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.to
        let cc = draft.replyCcAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.cc
        let bcc = draft.replyBccAddressesJSON.map(ComposeAddressEncoding.decode) ?? defaults.bcc
        return ReplyRecipientSet(to: to, cc: cc, bcc: bcc)
    }

    private static func orderedAddresses(
        for role: ParticipantRole,
        in message: Message
    ) -> [String] {
        message.participants
            .enumerated()
            .filter { $0.element.role == role }
            .sorted { lhs, rhs in
                let leftPosition = lhs.element.headerPosition ?? lhs.offset
                let rightPosition = rhs.element.headerPosition ?? rhs.offset
                if leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                return lhs.offset < rhs.offset
            }
            .compactMap { $0.element.participant?.emailAddress }
    }

    private static func uniqueExternalAddresses(
        from addresses: [String],
        excluding excludedAddresses: Set<String>
    ) -> [String] {
        let excluded = Set(excludedAddresses.map(normalizedAddress))
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(addresses.count)

        for rawAddress in addresses {
            let normalized = normalizedAddress(rawAddress)
            guard !normalized.isEmpty,
                  !excluded.contains(normalized),
                  seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public extension Draft {
    var resolvedReplyRecipientMode: ReplyRecipientMode {
        if let raw = replyRecipientModeRaw,
           let mode = ReplyRecipientMode(rawValue: raw) {
            return mode
        }
        if replyToAddressesJSON != nil
            || replyCcAddressesJSON != nil
            || replyBccAddressesJSON != nil {
            return .custom
        }
        return .reply
    }
}
