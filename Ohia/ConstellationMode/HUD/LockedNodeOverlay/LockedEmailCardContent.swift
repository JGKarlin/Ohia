import SwiftUI
import OhiaCore

struct LockedEmailCardContent {
    enum RecipientRole: String, CaseIterable {
        case to
        case cc
        case bcc

        var label: String {
            switch self {
            case .to: return "To"
            case .cc: return "Cc"
            case .bcc: return "Bcc"
            }
        }
    }

    struct RecipientHeaderEntry: Identifiable, Equatable {
        let address: String
        let displayText: String
        let isListOrigin: Bool

        var id: String {
            "\(address)|\(displayText)|\(isListOrigin)"
        }
    }

    struct RecipientHeaderLine: Identifiable, Equatable {
        let role: RecipientRole
        var entries: [RecipientHeaderEntry]
        var trailingDetail: String?

        var id: String { role.rawValue }

        var plainText: String {
            var text = "\(role.label): " + entries.map(\.displayText).joined(separator: ", ")
            if let trailingDetail {
                text += " · \(trailingDetail)"
            }
            return text
        }

        var attributedText: AttributedString {
            var output = AttributedString()
            output += Self.attributed("\(role.label): ", color: OhiaColors.textSecondary)
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    output += Self.attributed(", ", color: OhiaColors.textSecondary)
                }
                output += Self.attributed(
                    entry.displayText,
                    color: entry.isListOrigin ? OhiaColors.ohiaYellow : OhiaColors.textSecondary
                )
            }
            if let trailingDetail {
                output += Self.attributed(" · \(trailingDetail)", color: OhiaColors.textSecondary)
            }
            return output
        }

        private static func attributed(_ text: String, color: Color) -> AttributedString {
            var attributed = AttributedString(text)
            attributed.foregroundColor = color
            return attributed
        }
    }

    enum BodyState {
        case loading
        case loaded(LockReadoutBodyContent)
        case failed
    }

    let messageId: String
    let vectorId: Int64
    let row: MessageFilterRow
    let summary: String?
    /// Canonical override supplied after an edit while the snapshot cache
    /// catches up. `nil` falls through to the row projection.
    let classificationOverride: MailClassification?
    /// Override for the row's user-defined-category key set; same
    /// nil-falls-through-to-row semantics as `classificationOverride`.
    var summaryCustomCategoryKeys: Set<String>? = nil
    /// Unified read/action/deadline/flag status for the locked message. Built
    /// by the overlay host from the same `MessageFilterRow` that drives the
    /// card, so the header and action rail read from one source.
    let statusDescriptor: MessageStatusDescriptor
    /// Forces generated-summary slots to show their loading affordance while
    /// a replacement generation is in flight, instead of displaying stale text.
    let summaryIsRegenerating: Bool
    let bodyState: BodyState
    /// Lowercased addresses that belong to the local user (every Account / Identity
    /// address). Used by `recipientHeaderLines` to drop the user themselves
    /// from To/Cc/Bcc on received mail — the lock card only surfaces "who
    /// else got this" since the user already knows they were a recipient.
    let userAddresses: Set<String>

    var displaySubject: String {
        row.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no subject)" : row.subject
    }

    var displayFromName: String? {
        if let name = row.fromName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return row.fromAddress.isEmpty ? nil : row.fromAddress
    }

    var displaySummary: String? {
        guard !summaryIsRegenerating else { return nil }
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    var classification: MailClassification? {
        classificationOverride ?? row.mailClassification
    }

    var purpose: MailPurpose? { classification?.purpose }

    /// User-defined category keys assigned to this message; override wins,
    /// matching `categories`.
    var customCategoryKeys: Set<String> {
        summaryCustomCategoryKeys ?? row.customCategoryKeys
    }

    /// Address used to key the per-sender remote-image allowlist. Sent mail
    /// (and unknown senders) get no unblock chip and never auto-load remote
    /// images — `nil` here means "keep images blocked, show no chip". The
    /// header chip and the body's image-loading both read this one value so
    /// the gating can't drift between them.
    var remoteImageSenderAddress: String? {
        row.isSentByUser ? nil : row.fromAddress
    }

    var directionLabel: String {
        row.isSentByUser ? "sent" : "received"
    }

    var directionSymbolName: String {
        row.isSentByUser ? "paperplane.fill" : "tray.and.arrow.down"
    }

    /// "From" line for the locked overlay header. Sent messages omit this entirely
    /// (the directional badge already reads "sent" and the new To line
    /// carries the date) so the header stays tight and doesn't echo the user's own
    /// name as the sender.
    var fromLine: String {
        guard !row.isSentByUser else { return "" }
        var parts: [String] = []
        if let displayFromName { parts.append(displayFromName) }
        if !row.fromAddress.isEmpty, row.fromAddress != displayFromName {
            parts.append(row.fromAddress)
        }
        if let date = row.receivedAt {
            parts.append(Self.dateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    /// Full recipient header for the locked overlay. For received messages,
    /// drops local user addresses from To/Cc/Bcc (the user already knows they
    /// received the copy) and returns only recipient sections that still have
    /// visible entries. For sent messages, the first visible recipient line
    /// carries the date; if there are no recipients at all, the header keeps
    /// the old explicit fallback.
    var recipientHeaderLines: [RecipientHeaderLine] {
        var lines = [
            recipientLine(role: .to, addresses: row.toAddresses, displayNames: row.toDisplayNames),
            recipientLine(role: .cc, addresses: row.ccAddresses, displayNames: row.ccDisplayNames),
            recipientLine(role: .bcc, addresses: row.bccAddresses, displayNames: row.bccDisplayNames)
        ].compactMap { $0 }

        guard row.isSentByUser else { return lines }

        let dateText = row.receivedAt.map(Self.dateFormatter.string(from:))
        if lines.isEmpty {
            lines = [RecipientHeaderLine(
                role: .to,
                entries: [RecipientHeaderEntry(
                    address: "",
                    displayText: "(recipients unavailable)",
                    isListOrigin: false
                )],
                trailingDetail: dateText
            )]
        } else if let dateText {
            lines[0].trailingDetail = dateText
        }
        return lines
    }

    /// Compatibility surface for older call sites that only expected the
    /// primary recipient line.
    var recipientsLine: String? {
        recipientHeaderLines.first?.plainText
    }

    private func recipientLine(
        role: RecipientRole,
        addresses: [String],
        displayNames: [String]
    ) -> RecipientHeaderLine? {
        let entries = addresses.enumerated().compactMap { index, address -> RecipientHeaderEntry? in
            let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedAddress = Self.normalizedAddress(trimmedAddress)
            guard !lowercasedAddress.isEmpty else { return nil }
            if !row.isSentByUser, userAddresses.contains(lowercasedAddress) {
                return nil
            }
            let displayName = displayNames.indices.contains(index)
                ? displayNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let isListOrigin = Self.isListOriginAddress(lowercasedAddress, listId: row.listId)
            return RecipientHeaderEntry(
                address: lowercasedAddress,
                displayText: Self.recipientDisplayText(
                    address: lowercasedAddress,
                    displayName: displayName,
                    isListOrigin: isListOrigin
                ),
                isListOrigin: isListOrigin
            )
        }
        guard !entries.isEmpty else { return nil }
        return RecipientHeaderLine(role: role, entries: entries, trailingDetail: nil)
    }

    private static func recipientDisplayText(
        address: String,
        displayName: String,
        isListOrigin: Bool
    ) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return address }
        guard isListOrigin, normalizedAddress(name) != address else { return name }
        return "\(name) <\(address)>"
    }

    private static func isListOriginAddress(_ address: String, listId: String?) -> Bool {
        guard let listId = listId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !listId.isEmpty else {
            return false
        }
        return address == listId || canonicalListId(forRecipientAddress: address) == listId
    }

    private static func canonicalListId(forRecipientAddress address: String) -> String? {
        let normalized = normalizedAddress(address)
        guard let atIndex = normalized.firstIndex(of: "@") else { return nil }
        let local = normalized[..<atIndex]
        let domainStart = normalized.index(after: atIndex)
        guard !local.isEmpty, domainStart < normalized.endIndex else { return nil }
        return "\(local).\(normalized[domainStart...])"
    }

    private static func normalizedAddress(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
