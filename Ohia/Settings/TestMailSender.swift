// Ohia/Settings/TestMailSender.swift
// Developer-mode helper for enqueuing a synthetic SMTP smoke-test message.
// Builds an OutboxItem directly (no Draft/Message linkage) and queues a
// .sendOutbox job so the scheduler's next tick drains it through the real
// SMTP pipeline.

import Foundation
import SwiftData
import OhiaCore
import OhiaMail
import OhiaScheduler

enum TestMailSender {
    enum Error: Swift.Error, LocalizedError {
        case noAccount
        case noSMTPConfig
        case emptyRecipient

        var errorDescription: String? {
            switch self {
            case .noAccount: return "No account is configured. Add one via Accounts settings."
            case .noSMTPConfig: return "Account is missing SMTP configuration (host/port/security)."
            case .emptyRecipient: return "Recipient email is empty."
            }
        }
    }

    @MainActor
    static func enqueueSmokeTest(recipient: String, context: ModelContext) throws {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else { throw Error.emptyRecipient }

        let accounts = try context.fetch(FetchDescriptor<Account>())
        guard let account = accounts.first else { throw Error.noAccount }
        guard account.smtpHost != nil else { throw Error.noSMTPConfig }

        let escaped = escapeJSON(trimmedRecipient)
        let toJSON = "[\"\(escaped)\"]"

        let outgoingID = MessageBuilder.generateMessageID(fromAddress: account.emailAddress)

        let item = OutboxItem(
            fromAddress: account.emailAddress,
            toAddressesJSON: toJSON,
            subject: "Ohia SMTP smoke test",
            plainBody: "This is a test message sent from Ohia's developer console.\n\nIf you are reading this, the outbound SMTP pipeline works.",
            messageIDHeader: outgoingID
        )
        item.account = account
        context.insert(item)

        try JobQueue().enqueue(type: .sendOutbox, priority: 1, context: context)
        try context.save()
    }

    private static func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
