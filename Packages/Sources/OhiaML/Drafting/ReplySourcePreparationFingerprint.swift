import CryptoKit
import Foundation
import OhiaCore
import OhiaIngest

/// Revision key for exactly the target and conversation values consumed by
/// initial reply-source compilation and interview planning. Broader retrieval
/// results are frozen into the prepared source snapshot instead of making
/// unrelated corpus churn invalidate every ready preparation.
/// Model traversal and file reads run synchronously on the caller's executor;
/// the caller must keep its model graph confined to that executor.
public enum ReplySourcePreparationFingerprint {
    public static let contractVersion = 32

    private struct CanonicalInput: Encodable {
        let contractVersion: Int
        let target: TargetInput
        let account: AccountInput?
        let threadMessages: [MessageInput]
    }

    private struct TargetInput: Encodable {
        let id: UUID
        let accountID: UUID?
        let replyToAddresses: [String]?
        let draftingLanguage: String?
        /// Prepared questions are written in the author's reading language.
        let questionLanguage: String
    }

    private struct AccountInput: Encodable {
        let id: UUID
        let displayName: String
        let emailAddress: String
        let draftLanguages: [String]
        let identities: [IdentityInput]
    }

    private struct IdentityInput: Encodable {
        let address: String
        let displayName: String?
        let replyTo: String?
        let isPrimary: Bool

        var sortKey: String {
            [
                isPrimary ? "0" : "1",
                address,
                displayName ?? "",
                replyTo ?? "",
            ].joined(separator: "\u{1F}")
        }
    }

    private struct MessageInput: Encodable {
        let id: UUID
        let contentHash: String?
        let messageIDHeader: String?
        let inReplyTo: String?
        let referencesChain: String?
        let sourceDate: Date
        let subject: String
        let fromAddress: String
        let fromName: String?
        let isSentByUser: Bool
        let isAutomatedOrBulk: Bool?
        let bodyContent: FileContentIdentity
        let participants: [ParticipantInput]
        let attachments: [AttachmentInput]
        let analysis: AnalysisInput?
    }

    private struct ParticipantInput: Encodable {
        let role: String
        let headerPosition: Int?
        let emailAddress: String?
        let displayName: String?

        var sortKey: String {
            [
                role,
                headerPosition.map(String.init) ?? "",
                emailAddress ?? "",
                displayName ?? "",
            ].joined(separator: "\u{1F}")
        }
    }

    private struct AttachmentInput: Encodable {
        let filename: String
        let mimeType: String
        let sizeBytes: Int
        let sourceContent: FileContentIdentity
        let extractedTextContent: FileContentIdentity
        let terminalExtractionMarker: String

        var sortKey: String {
            [
                filename,
                mimeType,
                String(sizeBytes),
                sourceContent.sortKey,
                extractedTextContent.sortKey,
                terminalExtractionMarker,
            ].joined(separator: "\u{1F}")
        }
    }

    private struct AnalysisInput: Encodable {
        let classification: MailClassification?
        let customCategoryKeys: [String]
        let triageVerdict: TriageVerdict?
        let dimensions: MessageDimensions?
        let discourseMemory: DiscourseMemory?
        let bodySummary: String?
    }

    private struct FileContentIdentity: Encodable {
        enum State: String, Encodable {
            case absent
            case unreadable
            case available
        }

        let state: State
        let sha256: String?

        var sortKey: String {
            "\(state.rawValue)\u{1F}\(sha256 ?? "")"
        }
    }

    public static func value(
        for message: Message,
        questionLanguage: SummarizationTargetLanguage = ComposerQuestionLanguage.current()
    ) -> String {
        encodedFingerprint(for: message, readsFileContents: true, questionLanguage: questionLanguage)
    }

    /// Validates the model inputs of an asynchronously computed fingerprint
    /// without reading body or attachment files on the presentation executor.
    /// File paths are part of this stamp; file bytes remain covered by `value`.
    /// Callers must also fence input invalidations while that read is in flight.
    public static func metadataStamp(
        for message: Message,
        questionLanguage: SummarizationTargetLanguage = ComposerQuestionLanguage.current()
    ) -> String {
        encodedFingerprint(for: message, readsFileContents: false, questionLanguage: questionLanguage)
    }

    private static func encodedFingerprint(
        for message: Message,
        readsFileContents: Bool,
        questionLanguage: SummarizationTargetLanguage
    ) -> String {
        let projection = canonicalInput(
            for: message,
            readsFileContents: readsFileContents,
            questionLanguage: questionLanguage
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = (try? encoder.encode(projection)) ?? Data(
            "contract=\(contractVersion);target=\(message.id.uuidString);encoding=failed".utf8
        )
        return sha256(payload)
    }

    private static func canonicalInput(
        for message: Message,
        readsFileContents: Bool,
        questionLanguage: SummarizationTargetLanguage
    ) -> CanonicalInput {
        var messagesByID: [UUID: Message] = [message.id: message]
        for related in message.thread?.messages ?? [] {
            messagesByID[related.id] = related
        }
        let orderedMessages = messagesByID.values.sorted(by: messageSort)
        let account = message.account
        return CanonicalInput(
            contractVersion: contractVersion,
            target: TargetInput(
                id: message.id,
                accountID: message.accountID ?? account?.id,
                replyToAddresses: decodedStringArray(message.replyToAddressesJSON),
                draftingLanguage: DraftLanguage.familyID(for: message.languageDetected),
                questionLanguage: questionLanguage.identifier
            ),
            account: account.map(accountInput),
            threadMessages: orderedMessages.map { messageInput($0, readsFileContents: readsFileContents) }
        )
    }

    private static func accountInput(_ account: Account) -> AccountInput {
        let identities = account.identities.map { identity in
            IdentityInput(
                address: identity.address,
                displayName: identity.displayName,
                replyTo: identity.replyTo,
                isPrimary: identity.isPrimary
            )
        }.sorted { $0.sortKey < $1.sortKey }
        let draftLanguages = decodedStringArray(account.draftLanguagesJSON)?
            .compactMap(DraftLanguage.familyID(for:)) ?? []
        return AccountInput(
            id: account.id,
            displayName: account.displayName,
            emailAddress: account.emailAddress,
            draftLanguages: draftLanguages,
            identities: identities
        )
    }

    private static func messageInput(_ message: Message, readsFileContents: Bool) -> MessageInput {
        let participants = message.participants.map { link in
            ParticipantInput(
                role: link.role.rawValue,
                headerPosition: link.headerPosition,
                emailAddress: link.participant?.emailAddress,
                displayName: link.participant?.displayName
            )
        }.sorted { $0.sortKey < $1.sortKey }
        let attachments = message.attachments.map {
            attachmentInput($0, readsFileContents: readsFileContents)
        }.sorted {
            $0.sortKey < $1.sortKey
        }
        return MessageInput(
            id: message.id,
            contentHash: message.contentHash,
            messageIDHeader: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            referencesChain: message.referencesChain,
            sourceDate: message.receivedAt ?? message.sentAt ?? message.ingestedAt,
            subject: message.subject,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            isSentByUser: message.isSentByUser,
            isAutomatedOrBulk: message.isAutomatedOrBulk,
            bodyContent: fileContentIdentity(at: message.bodyTextPath, readsFileContents: readsFileContents),
            participants: participants,
            attachments: attachments,
            analysis: message.analysis.map(analysisInput)
        )
    }

    private static func attachmentInput(_ attachment: Attachment, readsFileContents: Bool) -> AttachmentInput {
        let kind = DocumentKind.detect(
            mimeType: attachment.mimeType,
            filename: attachment.filename
        )
        return AttachmentInput(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            sourceContent: fileContentIdentity(at: attachment.filePath, readsFileContents: readsFileContents),
            extractedTextContent: fileContentIdentity(at: attachment.extractedTextPath, readsFileContents: readsFileContents),
            terminalExtractionMarker: terminalExtractionMarker(
                for: attachment,
                kind: kind
            )
        )
    }

    private static func analysisInput(_ analysis: MessageAnalysis) -> AnalysisInput {
        AnalysisInput(
            classification: MailClassificationJSON.decode(analysis.mailClassificationJSON),
            customCategoryKeys: CustomCategoryKeysJSON
                .decode(analysis.customCategoryKeysJSON)
                .sorted(),
            triageVerdict: decoded(TriageVerdict.self, from: analysis.triageVerdictJSON),
            dimensions: decoded(MessageDimensions.self, from: analysis.dimensionsJSON),
            discourseMemory: decoded(DiscourseMemory.self, from: analysis.discourseMemoryJSON),
            bodySummary: analysis.bodySummary
        )
    }

    private static func terminalExtractionMarker(
        for attachment: Attachment,
        kind: DocumentKind
    ) -> String {
        switch kind {
        case .image:
            return "visual:\(attachment.visualExtractionStatus ?? "pending")"
        case .unsupported:
            return "unsupported"
        default:
            if attachment.extractedTextPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false {
                return "document:extracted"
            }
            let retryState = attachment.extractionNextRetryAt == nil
                ? "settled"
                : "retryable"
            return "document:\(attachment.extractionStatus ?? "pending"):\(retryState)"
        }
    }

    private static func decodedStringArray(_ json: String?) -> [String]? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private static func decoded<Value: Decodable>(
        _ type: Value.Type,
        from json: String?
    ) -> Value? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func fileContentIdentity(at path: String?, readsFileContents: Bool) -> FileContentIdentity {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false else {
            return FileContentIdentity(state: .absent, sha256: nil)
        }
        guard readsFileContents else {
            return FileContentIdentity(state: .available, sha256: "path:\(path)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return FileContentIdentity(state: .unreadable, sha256: nil)
        }
        return FileContentIdentity(state: .available, sha256: sha256(data))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func messageSort(_ lhs: Message, _ rhs: Message) -> Bool {
        let lhsDate = lhs.receivedAt ?? lhs.sentAt ?? lhs.ingestedAt
        let rhsDate = rhs.receivedAt ?? rhs.sentAt ?? rhs.ingestedAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
