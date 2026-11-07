import Foundation
import OhiaCore

/// Stateless helpers that compute the frame-aware text the
/// `SurveyTelemetryStrip` renders. Extracted from the SwiftUI view so the
/// section heading and People identity line can be exercised in pure unit
/// tests rather than through view-host scaffolding.
enum SurveyTelemetryFraming {

    /// The section heading the strip renders at the top of the pane. Each
    /// spatial lens picks its own caps-word so the active frame is legible
    /// at a glance without changing pane structure or placement.
    static func sectionHeading(for frame: FrameKey) -> String {
        switch frame.spatialLens {
        case .people:        return "CORRESPONDENT"
        case .projects:      return "PROJECT"
        case .meaning, .defaultFrame: return "CONTEXT"
        default: return "CONTEXT"
        }
    }

    /// Person identity shown directly beneath the `.people` heading. Prefer a
    /// locked person focus when the overlay was opened from a People hub; fall
    /// back to the locked message's non-user correspondent otherwise.
    nonisolated static func correspondentIdentityLine(
        for frame: FrameKey,
        row: MessageFilterRow,
        userAddresses: Set<String>,
        personFocus: LockedPersonFocus? = nil
    ) -> String? {
        guard frame.spatialLens == .people else { return nil }
        if let personFocus {
            return formattedCorrespondentIdentity(
                displayName: personFocus.displayName,
                email: personFocus.email
            )
        }
        guard let identity = primaryCorrespondentIdentity(
            row: row,
            userAddresses: userAddresses
        ) else {
            return nil
        }
        return formattedCorrespondentIdentity(
            displayName: identity.displayName,
            email: identity.email
        )
    }

    private struct CorrespondentIdentity: Equatable {
        let displayName: String?
        let email: String
    }

    private nonisolated static func primaryCorrespondentIdentity(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> CorrespondentIdentity? {
        let normalizedUsers = Set(userAddresses.compactMap(normalizedEmail))
        if row.isSentByUser {
            return firstRecipientIdentity(row: row, userAddresses: normalizedUsers)
                ?? senderIdentity(row: row, userAddresses: normalizedUsers)
        }
        return senderIdentity(row: row, userAddresses: normalizedUsers)
            ?? firstRecipientIdentity(row: row, userAddresses: normalizedUsers)
    }

    private nonisolated static func senderIdentity(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> CorrespondentIdentity? {
        guard let email = normalizedEmail(row.fromAddress),
              !userAddresses.contains(email) else {
            return nil
        }
        return CorrespondentIdentity(displayName: row.fromName, email: email)
    }

    private nonisolated static func firstRecipientIdentity(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> CorrespondentIdentity? {
        for rawAddress in row.recipientAddresses {
            guard let email = normalizedEmail(rawAddress),
                  !userAddresses.contains(email) else {
                continue
            }
            return CorrespondentIdentity(
                displayName: displayName(forRecipient: email, row: row),
                email: email
            )
        }
        return nil
    }

    private nonisolated static func displayName(forRecipient email: String, row: MessageFilterRow) -> String? {
        guard let index = row.toAddresses.firstIndex(where: { normalizedEmail($0) == email }),
              row.toDisplayNames.indices.contains(index) else {
            return nil
        }
        return row.toDisplayNames[index]
    }

    private nonisolated static func formattedCorrespondentIdentity(displayName: String?, email rawEmail: String) -> String? {
        guard let email = normalizedEmail(rawEmail) else { return nil }
        let name = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || normalizedEmail(name) == email {
            return email
        }
        return "\(name) · \(email)"
    }

    private nonisolated static func normalizedEmail(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        guard !trimmed.isEmpty, trimmed.contains("@") else { return nil }
        return trimmed
    }
}
