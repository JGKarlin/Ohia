import Foundation
import OhiaCore

public protocol ProjectTextFileReading: Sendable {
    func readUTF8(atPath path: String, maximumByteCount: Int) throws -> String
}

public struct ProjectTextFileReader: ProjectTextFileReading, Sendable {
    public init() {}

    public func readUTF8(atPath path: String, maximumByteCount: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: max(0, maximumByteCount)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds a value-only rule snapshot while the caller owns the message's
/// SwiftData context and executor. The builder never retains a model object.
public struct ManualProjectMessageSnapshotBuilder {
    public static let subjectByteLimit = 32 * 1024
    public static let bodyByteLimit = 1024 * 1024
    public static let attachmentFilenameByteLimit = 8 * 1024
    public static let attachmentTextByteLimit = 1024 * 1024
    public static let maximumAttachmentCount = 256

    private let textReader: any ProjectTextFileReading

    public init(textReader: any ProjectTextFileReading) {
        self.textReader = textReader
    }

    public func snapshot(for message: Message) throws -> MailProjectMessageSnapshot {
        var correspondentIDsByRole: [MailProjectCorrespondentRole: Set<UUID>] = [:]
        var addressesByRole: [MailProjectCorrespondentRole: Set<String>] = [:]
        for link in message.participants {
            guard let role = projectRole(link.role),
                  let participant = link.participant else {
                continue
            }
            let address = normalizedAddress(participant.emailAddress)
            if address.isEmpty == false {
                addressesByRole[role, default: []].insert(address)
            }
            correspondentIDsByRole[role, default: []].insert(participant.id)
            if let aggregateID = participant.correspondent?.id {
                correspondentIDsByRole[role, default: []].insert(aggregateID)
            }
        }
        let fallbackFrom = normalizedAddress(message.fromAddress)
        if fallbackFrom.isEmpty == false {
            addressesByRole[.from, default: []].insert(fallbackFrom)
        }

        let analysis = message.analysis
        let classification = MailClassificationJSON.decode(analysis?.mailClassificationJSON)
        let customCategoryKeys = Set(CustomCategoryKeysJSON.decode(analysis?.customCategoryKeysJSON))
        let dimensions = decodeDimensions(analysis?.dimensionsJSON)
        var valuesByFacet = values(from: dimensions)
        if let language = DraftLanguage.familyID(for: message.languageDetected) {
            valuesByFacet[.language] = [language]
        }
        let accountID = message.accountID ?? message.account?.id
        if let accountID,
           let listID = message.listId?.trimmingCharacters(in: .whitespacesAndNewlines),
           listID.isEmpty == false {
            valuesByFacet[.mailingList] = [MailProjectMailingListValue.stableKey(
                accountID: accountID,
                listID: listID
            )]
        }

        let attachments = Array(message.attachments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .prefix(Self.maximumAttachmentCount))
        let attachmentFilenames = attachments.map {
            utf8SafePrefix($0.filename, maximumByteCount: Self.attachmentFilenameByteLimit)
        }
        var attachmentTexts: [String] = []
        for attachment in attachments {
            if let path = attachment.extractedTextPath {
                attachmentTexts.append(try textReader.readUTF8(
                    atPath: path,
                    maximumByteCount: Self.attachmentTextByteLimit
                ))
            }
        }

        let body: String
        if let path = message.bodyTextPath {
            body = try textReader.readUTF8(atPath: path, maximumByteCount: Self.bodyByteLimit)
        } else {
            body = ""
        }

        let readiness = readinessByFacet(
            analysis: analysis,
            classification: classification,
            dimensions: dimensions,
            attachments: attachments
        )
        let draft = MailProjectMessageSnapshot(
            id: message.id,
            accountID: accountID,
            threadID: message.thread?.id,
            messageDate: message.receivedAt ?? message.sentAt ?? message.ingestedAt,
            correspondentIDsByRole: correspondentIDsByRole,
            addressesByRole: addressesByRole,
            purpose: classification?.purpose,
            customCategoryKeys: customCategoryKeys,
            valuesByFacet: valuesByFacet,
            subject: utf8SafePrefix(message.subject, maximumByteCount: Self.subjectByteLimit),
            body: body,
            attachmentFilenames: attachmentFilenames,
            attachmentTexts: attachmentTexts,
            readinessByFacet: readiness,
            sourceFingerprint: ""
        )
        let fingerprint = ManualProjectFingerprint.messageSourceFingerprint(
            draft,
            dependencySet: MailProjectDependencySet(
                facets: Set(MailProjectRuleFacet.allCases),
                dependsOnThreadIdentity: true
            )
        )
        return MailProjectMessageSnapshot(
            id: draft.id,
            accountID: draft.accountID,
            threadID: draft.threadID,
            messageDate: draft.messageDate,
            correspondentIDsByRole: draft.correspondentIDsByRole,
            addressesByRole: draft.addressesByRole,
            purpose: draft.purpose,
            customCategoryKeys: draft.customCategoryKeys,
            valuesByFacet: draft.valuesByFacet,
            subject: draft.subject,
            body: draft.body,
            attachmentFilenames: draft.attachmentFilenames,
            attachmentTexts: draft.attachmentTexts,
            readinessByFacet: draft.readinessByFacet,
            sourceFingerprint: fingerprint
        )
    }

    private func projectRole(_ role: ParticipantRole) -> MailProjectCorrespondentRole? {
        switch role {
        case .from: .from
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        }
    }

    private func normalizedAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func decodeDimensions(_ value: String?) -> MessageDimensions? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MessageDimensions.self, from: data)
    }

    private func values(from dimensions: MessageDimensions?) -> [MailProjectRuleFacet: Set<String>] {
        guard let dimensions else { return [:] }
        return [
            .semanticTag: Set(dimensions.semanticTags.map { $0.tagID.uuidString.lowercased() }),
        ]
    }

    private func readinessByFacet(
        analysis: MessageAnalysis?,
        classification: MailClassification?,
        dimensions: MessageDimensions?,
        attachments: [Attachment]
    ) -> [MailProjectRuleFacet: MailProjectMetadataReadiness] {
        var result = Dictionary(
            uniqueKeysWithValues: MailProjectRuleFacet.allCases.map { ($0, MailProjectMetadataReadiness.committed) }
        )
        result[.fixedCategory] = metadataReadiness(
            hasCommittedValue: classification != nil,
            interpretedAt: analysis?.interpretedAt
        )
        result[.customCategory] = metadataReadiness(
            hasCommittedValue: analysis?.customCategoryKeysJSON != nil,
            interpretedAt: analysis?.interpretedAt
        )
        let dimensionsReadiness = metadataReadiness(
            hasCommittedValue: dimensions != nil,
            interpretedAt: analysis?.interpretedAt
        )
        for facet in Self.dimensionsFacets {
            result[facet] = dimensionsReadiness
        }
        result[.attachmentText] = attachmentTextReadiness(attachments)
        return result
    }

    private func metadataReadiness(
        hasCommittedValue: Bool,
        interpretedAt: Date?
    ) -> MailProjectMetadataReadiness {
        guard hasCommittedValue else { return .pendingForNewMessage }
        return interpretedAt == nil ? .regeneratingWithCommittedValue : .committed
    }

    private func attachmentTextReadiness(_ attachments: [Attachment]) -> MailProjectMetadataReadiness {
        if attachments.isEmpty || attachments.allSatisfy({ $0.extractionStatus != nil }) {
            return .committed
        }
        if attachments.contains(where: { $0.extractionStatus == nil && $0.extractedTextPath == nil }) {
            return .pendingForNewMessage
        }
        return .regeneratingWithCommittedValue
    }

    private func utf8SafePrefix(_ value: String, maximumByteCount: Int) -> String {
        guard maximumByteCount > 0 else { return "" }
        var output = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount + scalarByteCount <= maximumByteCount else { break }
            output.append(scalar)
            byteCount += scalarByteCount
        }
        return String(output)
    }

    private static let dimensionsFacets: [MailProjectRuleFacet] = [
        .semanticTag,
    ]
}
