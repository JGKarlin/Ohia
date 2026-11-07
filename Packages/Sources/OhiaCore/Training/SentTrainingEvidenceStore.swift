import Foundation
import SwiftData

public enum SentTrainingEvidenceStoreError: Error, LocalizedError {
    case missingAccount

    public var errorDescription: String? {
        switch self {
        case .missingAccount:
            "A sent message cannot become training evidence without an account."
        }
    }
}

/// Idempotent discovery and reconciliation at the sent-mail boundary. This
/// store records only durable source facts; OhiaML owns later preparation.
public struct SentTrainingEvidenceStore: Sendable {
    public init() {}

    public func discover(
        message: Message,
        account: Account,
        context: ModelContext,
        now: Date = .now
    ) throws -> SentTrainingEvidence {
        if let existing = message.sentTrainingEvidence {
            update(existing, from: message, account: account, now: now)
            return existing
        }

        let identity = sourceIdentity(for: message, accountID: account.id)
        var key = identity.key
        if let existing = try evidence(sourceIdentityKey: key, context: context) {
            if existing.sourceMessage == nil || existing.sourceMessage?.id == message.id {
                update(existing, from: message, account: account, now: now)
                existing.sourceMessage = message
                message.sentTrainingEvidence = existing
                return existing
            }
            key = "\(key):collision:\(message.id.uuidString.lowercased())"
        }

        if let existing = try evidence(sourceIdentityKey: key, context: context) {
            update(existing, from: message, account: account, now: now)
            existing.sourceMessage = message
            message.sentTrainingEvidence = existing
            return existing
        }

        let created = SentTrainingEvidence(
            sourceIdentityKey: key,
            accountID: account.id,
            kind: message.inReplyTo == nil ? .historicalStandalone : .historicalReply,
            createdAt: now
        )
        created.sourceMailboxLocator = identity.mailboxLocator
        created.sourceMessage = message
        message.sentTrainingEvidence = created
        update(created, from: message, account: account, now: now)
        context.insert(created)
        return created
    }

    public func recordSuccessfulSend(
        _ item: OutboxItem,
        context: ModelContext,
        now: Date = .now
    ) throws -> SentTrainingEvidence? {
        guard item.status == .sent else { return nil }
        guard let accountID = item.account?.id
                ?? item.draft?.composeFromAccountID
                ?? item.draft?.message?.accountID
                ?? item.draft?.message?.account?.id else {
            throw SentTrainingEvidenceStoreError.missingAccount
        }
        guard let normalizedMessageID = normalizeMessageIDHeader(item.messageIDHeader) else {
            return nil
        }
        if let existing = item.sentTrainingEvidence {
            update(existing, from: item, accountID: accountID, normalizedMessageID: normalizedMessageID, now: now)
            return existing
        }

        let key = Self.messageIDKey(accountID: accountID, normalizedMessageID: normalizedMessageID)
        let evidence = try evidence(sourceIdentityKey: key, context: context) ?? SentTrainingEvidence(
            sourceIdentityKey: key,
            accountID: accountID,
            kind: item.draft?.kind == .userCompose ? .composerStandalone : .composerReply,
            learningPreference: item.learnFromSend ? .automaticEnabled : .automaticDisabled,
            createdAt: now
        )
        if evidence.modelContext == nil {
            context.insert(evidence)
        }
        evidence.sourceOutbox = item
        item.sentTrainingEvidence = evidence
        update(
            evidence,
            from: item,
            accountID: accountID,
            normalizedMessageID: normalizedMessageID,
            now: now
        )
        return evidence
    }

    private func evidence(
        sourceIdentityKey: String,
        context: ModelContext
    ) throws -> SentTrainingEvidence? {
        var descriptor = FetchDescriptor<SentTrainingEvidence>(
            predicate: #Predicate<SentTrainingEvidence> {
                $0.sourceIdentityKey == sourceIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func sourceIdentity(
        for message: Message,
        accountID: UUID
    ) -> (key: String, mailboxLocator: String?) {
        if let normalized = normalizeMessageIDHeader(message.messageIdHeader) {
            return (Self.messageIDKey(accountID: accountID, normalizedMessageID: normalized), nil)
        }
        if message.imapUID > 0, let folder = message.imapFolderPath, !folder.isEmpty {
            let locator = "imap:\(folder):\(message.imapUID)"
            return ("mailbox:\(accountID.uuidString.lowercased()):\(locator)", locator)
        }

        let sentSecond = Int64((message.sentAt ?? message.ingestedAt).timeIntervalSince1970)
        let subject = message.subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fingerprint = message.contentHash ?? "missing-content-fingerprint"
        let base = "composite:\(accountID.uuidString.lowercased()):\(sentSecond):\(subject):\(fingerprint)"
        return (base, nil)
    }

    private static func messageIDKey(accountID: UUID, normalizedMessageID: String) -> String {
        "message-id:\(accountID.uuidString.lowercased()):\(normalizedMessageID)"
    }

    private func update(
        _ evidence: SentTrainingEvidence,
        from message: Message,
        account: Account,
        now: Date
    ) {
        let previousBodyPath = evidence.authoredBodyPath
        let previousFingerprint = evidence.authoredTextFingerprint
        let sourceRelationshipWasMissing = evidence.sourceMessage == nil
        evidence.accountID = account.id
        evidence.sourceMessageID = message.id
        evidence.normalizedMessageID = normalizeMessageIDHeader(message.messageIdHeader)
        evidence.authoredTextFingerprint = message.contentHash
        evidence.authoredBodyPath = message.bodyTextPath
        evidence.languageID = message.languageDetected
        evidence.identityID = account.identities.first {
            $0.address.caseInsensitiveCompare(message.fromAddress) == .orderedSame
        }?.id
        let ownedAddresses = Set(
            ([account.emailAddress] + account.identities.map(\.address))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        evidence.correspondentAddress = message.participants
            .filter { $0.role == .to || $0.role == .cc || $0.role == .bcc }
            .compactMap { $0.participant?.emailAddress.lowercased() }
            .first { !ownedAddresses.contains($0) }
        evidence.threadID = message.thread?.id
        evidence.subjectRoot = message.thread?.subjectRoot ?? message.subject
        evidence.sentAt = message.sentAt
        evidence.updatedAt = now
        let bodyIsNowAvailable = message.bodyTextPath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        let retryInputChanged = previousBodyPath != message.bodyTextPath
            || previousFingerprint != message.contentHash
            || sourceRelationshipWasMissing
            || (evidence.reason == .missingBody && bodyIsNowAvailable)
        // Prompt-relevant content change under an already-prepared historical
        // row: the ledger would otherwise show the new fingerprint while the
        // prepared pair kept training on the old text. Bump the revision and
        // re-queue so preparation rebuilds at the new content. User opt-out
        // and trashed-source exclusions stay locked; Composer evidence is
        // fixed at SMTP acceptance and never re-keyed by ingest artifacts.
        let contentChanged = previousFingerprint != nil
            && message.contentHash != nil
            && message.contentHash != previousFingerprint
        let historicalKind = evidence.kind == .historicalReply
            || evidence.kind == .historicalStandalone
        let requeueLocked = evidence.disposition == .excluded
            && (evidence.reason == .userOptOut || evidence.reason == .trashedSource)
        if contentChanged,
           historicalKind,
           !requeueLocked,
           evidence.disposition != .pendingPreparation {
            requeueForPreparation(evidence, message: message)
        } else if evidence.disposition == .preparationFailed,
                  evidence.isRetryable,
                  retryInputChanged {
            requeueForPreparation(evidence, message: message)
        }
    }

    private func requeueForPreparation(_ evidence: SentTrainingEvidence, message: Message) {
        evidence.revision += 1
        evidence.disposition = .pendingPreparation
        evidence.reason = nil
        evidence.dispositionedAt = nil
        evidence.preparationAttemptedAt = nil
        evidence.isRetryable = false
        evidence.styleScoringFailureCount = nil
        evidence.styleScoringRetryAfter = nil
        message.trainingStatus = .pending
    }

    private func update(
        _ evidence: SentTrainingEvidence,
        from item: OutboxItem,
        accountID: UUID,
        normalizedMessageID: String,
        now: Date
    ) {
        evidence.accountID = accountID
        evidence.kind = item.draft?.kind == .userCompose ? .composerStandalone : .composerReply
        evidence.sourceOutboxID = item.id
        evidence.normalizedMessageID = normalizedMessageID
        evidence.identityID = item.draft?.fromIdentityID
        evidence.subjectRoot = item.subject
        let authored = AuthoredReplyText.extract(from: item.plainBody)
        evidence.languageID = DraftLanguage.detectedFamilyID(ofText: authored)
        evidence.correspondentAddress = firstNonOwnedRecipient(from: item)
        evidence.sentAt = evidence.sentAt ?? now
        // `learnFromSend` is the automatic default until Stage 3's explicit
        // Composer control ships; the ledger must not record a user decision
        // (explicit preference + decided-at) that never happened.
        evidence.learningPreference = item.learnFromSend ? .automaticEnabled : .automaticDisabled
        evidence.updatedAt = now
        if item.learnFromSend {
            if evidence.disposition == .excluded, evidence.reason == .userOptOut {
                evidence.disposition = .pendingPreparation
                evidence.reason = nil
                evidence.dispositionedAt = nil
            }
        } else {
            evidence.disposition = .excluded
            evidence.reason = .userOptOut
            evidence.dispositionedAt = now
            evidence.isRetryable = false
        }
    }

    private func firstNonOwnedRecipient(from item: OutboxItem) -> String? {
        var ownedAddresses = item.account?.ownedEmailAddresses ?? []
        if let fromAddress = normalizedMailboxAddress(item.fromAddress) {
            ownedAddresses.insert(fromAddress)
        }
        let recipients = ComposeAddressEncoding.decode(item.toAddressesJSON)
            + ComposeAddressEncoding.decode(item.ccAddressesJSON)
            + ComposeAddressEncoding.decode(item.bccAddressesJSON)
        return recipients
            .compactMap(normalizedMailboxAddress)
            .first { ownedAddresses.contains($0) == false }
    }

    private func normalizedMailboxAddress(_ raw: String) -> String? {
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
        guard normalized.isEmpty == false,
              normalized.contains("@") else {
            return nil
        }
        return normalized
    }
}
