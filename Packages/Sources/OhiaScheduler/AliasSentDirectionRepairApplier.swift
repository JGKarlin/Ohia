import Foundation
import SwiftData
import OhiaCore

/// Repairs messages imported before alias-aware sent detection. When a message's
/// From address belongs to the account, it must behave as outgoing everywhere:
/// summaries, context prompts, style training, and constellation filtering.
@MainActor
public final class AliasSentDirectionRepairApplier {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func run() throws -> Int {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        var repaired = 0

        for account in accounts {
            let accountID = account.id
            let ownedAddresses = account.ownedEmailAddresses
            guard !ownedAddresses.isEmpty else { continue }

            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.isSentByUser == false
                        && (message.accountID == accountID || message.account?.id == accountID)
                }
            )
            let messages = try modelContext.fetch(descriptor)
            for message in messages {
                let fromAddress = message.fromAddress
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard ownedAddresses.contains(fromAddress) else { continue }
                repair(message)
                repaired += 1
            }
        }

        if repaired > 0 {
            try enqueueGenericSummarizeJobIfNeeded()
            try modelContext.save()
        }
        return repaired
    }

    private func repair(_ message: Message) {
        message.isSentByUser = true
        message.applyReadState(true)
        message.trainingStatus = .pending
        message.embeddingStatus = .pending
        message.classifiedAt = nil
        message.messageType = .unclassified

        if let analysis = message.analysis {
            analysis.bodySummary = nil
            analysis.bodySummaryInputFingerprint = nil
            analysis.mailClassificationJSON = nil
            analysis.triageVerdictJSON = nil
            analysis.interpretedAt = nil
            analysis.summarizedAt = nil
        }
    }

    private func enqueueGenericSummarizeJobIfNeeded() throws {
        let jobs = try modelContext.fetch(FetchDescriptor<Job>())
        let hasActiveSummarize = jobs.contains { job in
            job.type == .summarize
                && job.messageId == nil
                && (job.status == .pending || job.status == .running || job.status == .failed)
        }
        guard !hasActiveSummarize else { return }
        modelContext.insert(Job(type: .summarize, priority: 6))
    }
}
