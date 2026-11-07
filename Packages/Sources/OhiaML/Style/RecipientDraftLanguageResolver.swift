import Foundation
import SwiftData
import OhiaCore

/// Resolves a new compose draft's language from durable sent-mail evidence.
/// The result is account- and recipient-scoped; opted-out evidence never
/// contributes to the user's observed language preference.
public enum RecipientDraftLanguageResolver {
    @MainActor
    public static func preferredLanguage(
        accountID: UUID?,
        correspondentAddress: String?,
        context: ModelContext
    ) -> String? {
        guard let accountID,
              let correspondentAddress = normalizedAddress(correspondentAddress) else {
            return nil
        }

        let descriptor = evidenceDescriptor(
            accountID: accountID,
            normalizedRecipient: correspondentAddress
        )
        let evidence = (try? context.fetch(descriptor)) ?? []

        var summaries: [String: (count: Int, latest: Date)] = [:]
        for row in evidence {
            guard normalizedAddress(row.correspondentAddress) == correspondentAddress,
                  row.learningPreference == .automaticEnabled
                    || row.learningPreference == .explicitEnabled,
                  let languageID = DraftLanguage.familyID(for: row.languageID),
                  languageID != "unknown",
                  languageID != "und" else {
                continue
            }
            let timestamp = row.sentAt ?? row.createdAt
            let current = summaries[languageID] ?? (0, .distantPast)
            summaries[languageID] = (
                current.count + 1,
                max(current.latest, timestamp)
            )
        }

        return summaries.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            if lhs.value.latest != rhs.value.latest {
                return lhs.value.latest > rhs.value.latest
            }
            return lhs.key < rhs.key
        }.first?.key
    }

    static func evidenceDescriptor(
        accountID: UUID,
        normalizedRecipient: String
    ) -> FetchDescriptor<SentTrainingEvidence> {
        // Reject unrelated recipients in the store before SwiftData creates
        // evidence models. This deliberately broad, case-insensitive search
        // also admits decorated addresses and substring/diacritic matches;
        // the exact normalized-address check above remains authoritative.
        FetchDescriptor(
            predicate: #Predicate<SentTrainingEvidence> { evidence in
                evidence.accountID == accountID
                    && (evidence.correspondentAddress?.localizedStandardContains(normalizedRecipient) ?? false)
            }
        )
    }

    private static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let mailbox: Substring
        if let opening = trimmed.lastIndex(of: "<"),
           let closing = trimmed[opening...].firstIndex(of: ">"),
           opening < closing {
            mailbox = trimmed[trimmed.index(after: opening)..<closing]
        } else {
            mailbox = trimmed[...]
        }
        let normalized = mailbox
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
