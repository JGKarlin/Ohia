import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class WithheldAutoDeleteWorker {
    public struct Payload: Codable, Sendable, Equatable {
        public let accountID: UUID

        public init(accountID: UUID) {
            self.accountID = accountID
        }
    }

    public static let priority = 9
    public static let maxPerFolder = 100

    private let sessionManager: IMAPSessionManager
    private let maxPerFolder: Int
    private let now: () -> Date

    public init(
        sessionManager: IMAPSessionManager,
        maxPerFolder: Int = WithheldAutoDeleteWorker.maxPerFolder,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionManager = sessionManager
        self.maxPerFolder = maxPerFolder
        self.now = now
    }

    @discardableResult
    public func run(job: Job, context: ModelContext) async throws -> Int {
        let payload = try Self.decodePayload(from: job)
        guard let account = try Self.fetchAccount(id: payload.accountID, context: context) else {
            return 0
        }

        let schedule = account.withheldAutoDeleteSchedule
        let runDate = now()
        guard schedule != .off,
              account.isWithheldAutoDeleteDue(now: runDate),
              let cutoff = schedule.cutoffDate(anchoredAt: runDate) else {
            return 0
        }

        guard let session = sessionManager.sessionForWork(accountID: payload.accountID) else {
            throw IMAPError.transient(underlying: IMAPError.notConnected)
        }

        do {
            let junk = try await session.deleteWithheldMessagesOlderThan(
                role: .junk,
                cutoff: cutoff,
                maxPerFolder: maxPerFolder
            )
            let trash = try await session.deleteWithheldMessagesOlderThan(
                role: .trash,
                cutoff: cutoff,
                maxPerFolder: maxPerFolder
            )
            let deleted = junk.deletedCount + trash.deletedCount
            let hasMoreToDelete = [junk, trash].contains { result in
                result.matchedCount > result.deletedCount
            }
            account.withheldAutoDeleteLastRunAt = hasMoreToDelete ? nil : runDate
            account.withheldAutoDeleteLastDeletedCount = deleted
            account.withheldAutoDeleteLastError = nil
            try context.save()
            return deleted
        } catch {
            markAccountForIMAPReauthIfNeeded(error, account: account)
            account.withheldAutoDeleteLastError = error.localizedDescription
            try context.save()
            throw error
        }
    }

    public static func payloadString(accountID: UUID) throws -> String {
        let payload = Payload(accountID: accountID)
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decodePayload(from job: Job) throws -> Payload {
        guard let data = job.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw PipelineError.invalidPayload("withheldAutoDelete job missing payload")
        }
        return payload
    }

    @MainActor
    public static func fetchAccount(id accountID: UUID, context: ModelContext) throws -> Account? {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func markAccountForIMAPReauthIfNeeded(_ error: Error, account: Account) {
        guard let imap = error as? IMAPError else { return }
        switch imap {
        case .authFailed, .reauthRequired:
            account.needsImapReauth = true
        default:
            break
        }
    }
}
