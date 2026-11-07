import Foundation
import OhiaCore
import OhiaMail

enum DeveloperFirstIngestionStatus: String, Equatable, Sendable {
    case complete = "Complete"
    case inProgress = "In progress"
    case waiting = "Waiting"
    case paused = "Paused"
    case needsAttention = "Needs attention"
}

struct DeveloperFirstIngestionPresentation: Equatable, Sendable {
    struct AccountInput: Equatable, Sendable {
        let id: UUID
        let displayName: String
        let emailAddress: String
        let accountStatus: AccountStatus
        let imapHost: String?
        let imapKeychainRef: String?
        let needsReauth: Bool
        let needsImapReauth: Bool
        let initialIMAPImportCompletedAt: Date?
    }

    struct FolderInput: Equatable, Sendable {
        let accountID: UUID
        let folderName: String
        let folderAttributes: [String]
        let initialImportUIDWorkTotal: Int?
        let initialImportUIDWorkRemaining: Int?

        init(
            accountID: UUID,
            folderName: String = "INBOX",
            folderAttributes: [String] = [],
            initialImportUIDWorkTotal: Int?,
            initialImportUIDWorkRemaining: Int?
        ) {
            self.accountID = accountID
            self.folderName = folderName
            self.folderAttributes = folderAttributes
            self.initialImportUIDWorkTotal = initialImportUIDWorkTotal
            self.initialImportUIDWorkRemaining = initialImportUIDWorkRemaining
        }
    }

    struct AccountRow: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
        let status: DeveloperFirstIngestionStatus
        let summary: String
    }

    let status: DeveloperFirstIngestionStatus
    let rows: [AccountRow]

    static func make(
        accounts: [AccountInput],
        folders: [FolderInput],
        hasCompletedFirstIngestion: Bool
    ) -> DeveloperFirstIngestionPresentation {
        let sortedAccounts = accounts.sorted {
            let lhsName = normalizedSortKey($0.displayName)
            let rhsName = normalizedSortKey($1.displayName)
            if lhsName != rhsName { return lhsName < rhsName }
            return normalizedSortKey($0.emailAddress) < normalizedSortKey($1.emailAddress)
        }
        let duplicateNames = duplicateDisplayNames(in: sortedAccounts)
        let foldersByAccount = Dictionary(grouping: folders, by: \.accountID)
        let rows = sortedAccounts.map { account in
            accountRow(
                for: account,
                folders: foldersByAccount[account.id] ?? [],
                includeEmailInLabel: duplicateNames.contains(normalizedDisplayName(account.displayName))
            )
        }

        return DeveloperFirstIngestionPresentation(
            status: overallStatus(rows: rows, hasCompletedFirstIngestion: hasCompletedFirstIngestion),
            rows: rows
        )
    }

    private static func accountRow(
        for account: AccountInput,
        folders: [FolderInput],
        includeEmailInLabel: Bool
    ) -> AccountRow {
        let label = accountLabel(for: account, includeEmail: includeEmailInLabel)
        let phase = initialImportPhase(for: account, folders: folders)
        return AccountRow(
            id: account.id,
            label: label,
            status: phase.status,
            summary: "\(label) · \(phase.label)"
        )
    }

    private static func initialImportPhase(
        for account: AccountInput,
        folders: [FolderInput]
    ) -> (label: String, status: DeveloperFirstIngestionStatus) {
        if account.accountStatus == .paused {
            return ("IMAP import paused", .needsAttention)
        }
        if account.needsReauth || account.needsImapReauth {
            return ("IMAP import needs reauth", .needsAttention)
        }
        guard nonblank(account.imapHost) != nil, nonblank(account.imapKeychainRef) != nil else {
            return ("IMAP credentials missing", .needsAttention)
        }
        if account.initialIMAPImportCompletedAt != nil {
            return ("Initial IMAP import complete", .complete)
        }

        let requiredFolders = requiredCorpusFolders(from: folders)
        guard !requiredFolders.isEmpty else {
            return ("Initial IMAP import waiting for UID snapshot", .waiting)
        }
        let work = requiredFolders.compactMap { folder -> (total: Int, remaining: Int)? in
            guard let total = folder.initialImportUIDWorkTotal,
                  let remaining = folder.initialImportUIDWorkRemaining else { return nil }
            return (max(0, total), max(0, min(total, remaining)))
        }
        guard work.count == requiredFolders.count else {
            return ("Initial IMAP import waiting for UID snapshot", .waiting)
        }

        let total = work.reduce(0) { $0 + $1.total }
        let remaining = work.reduce(0) { $0 + $1.remaining }
        let completed = max(0, total - remaining)
        if total == 0 || remaining == 0 {
            return ("Initial IMAP import awaiting completion marker", .waiting)
        }
        return (
            "Initial IMAP import \(decimal(completed))/\(decimal(total)) UID work",
            .inProgress
        )
    }

    private static func requiredCorpusFolders(from folders: [FolderInput]) -> [FolderInput] {
        let listing = folders.map { folder in
            IMAPFolder(
                name: folder.folderName,
                delimiter: nil,
                attributes: Set(folder.folderAttributes)
            )
        }
        let requiredNames = Set(GmailFolderFilter.foldersForCorpus(
            listing: listing,
            capabilities: IMAPCapability(raw: [])
        ).map(\.name))
        return folders.filter { requiredNames.contains($0.folderName) }
    }

    private static func overallStatus(
        rows: [AccountRow],
        hasCompletedFirstIngestion: Bool
    ) -> DeveloperFirstIngestionStatus {
        guard !rows.isEmpty else {
            return hasCompletedFirstIngestion ? .complete : .waiting
        }
        if rows.contains(where: { $0.status == .needsAttention }) { return .needsAttention }
        if rows.contains(where: { $0.status == .paused }) { return .paused }
        if rows.contains(where: { $0.status == .inProgress }) { return .inProgress }
        if rows.contains(where: { $0.status == .waiting }) { return .waiting }
        return .complete
    }

    private static func accountLabel(for account: AccountInput, includeEmail: Bool) -> String {
        let displayName = normalizedDisplayName(account.displayName)
        let email = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return email }
        guard !email.isEmpty else { return displayName }
        guard includeEmail || displayName.caseInsensitiveCompare(email) == .orderedSame else {
            return displayName
        }
        return "\(displayName) (\(email))"
    }

    private static func duplicateDisplayNames(in accounts: [AccountInput]) -> Set<String> {
        var counts: [String: Int] = [:]
        for account in accounts {
            let name = normalizedDisplayName(account.displayName)
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedSortKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
