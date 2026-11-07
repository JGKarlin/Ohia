import CryptoKit
import Foundation
import OhiaCore

public enum ManualProjectFingerprint {
    public static func configurationFingerprint(_ configuration: MailProjectConfigurationSnapshot) -> String {
        var encoder = CanonicalEncoder()
        encoder.append("projectID", configuration.projectID.uuidString)
        encoder.appendArray("accountIDs", configuration.accountIDs.map { Data($0.uuidString.utf8) })
        encoder.appendDate("automaticIntakeStartAt", configuration.automaticIntakeStartAt)
        encoder.appendArray("groups", configuration.groups.map(groupComponent))
        encoder.appendArray("manualDecisions", configuration.manualDecisions.map(decisionComponent))
        return digest(encoder.data)
    }

    public static func messageSourceFingerprint(
        _ message: MailProjectMessageSnapshot,
        dependencySet: MailProjectDependencySet
    ) -> String {
        var encoder = CanonicalEncoder()
        let facets = dependencySet.facets.sorted { $0.rawValue < $1.rawValue }
        encoder.appendArray("facets", facets.map { Data($0.rawValue.utf8) })
        encoder.appendBool("dependsOnThreadIdentity", dependencySet.dependsOnThreadIdentity)
        if dependencySet.dependsOnThreadIdentity {
            encoder.append("threadID", message.threadID?.uuidString)
        }

        for facet in facets {
            let prefix = "facet.\(facet.rawValue)"
            encoder.append("\(prefix).readiness", message.readinessByFacet[facet]?.rawValue)
            switch facet {
            case .account:
                encoder.append("\(prefix).accountID", message.accountID?.uuidString)
                encoder.appendDate("\(prefix).messageDate", message.messageDate)
            case .correspondent:
                appendCorrespondents(message, prefix: prefix, to: &encoder)
            case .fixedCategory:
                encoder.append("\(prefix).purpose", message.purpose?.rawValue)
            case .customCategory:
                encoder.appendArray("\(prefix).values", message.customCategoryKeys.map { Data($0.utf8) })
            case .subject:
                encoder.append("\(prefix).value", message.subject)
            case .body:
                encoder.append("\(prefix).value", message.body)
            case .attachmentFilename:
                encoder.appendArray("\(prefix).values", message.attachmentFilenames.map { Data($0.utf8) })
            case .attachmentText:
                encoder.appendArray("\(prefix).values", message.attachmentTexts.map { Data($0.utf8) })
            default:
                encoder.appendArray("\(prefix).values", (message.valuesByFacet[facet] ?? []).map { Data($0.utf8) })
            }
        }
        return digest(encoder.data)
    }

    /// A content-free generation stamp for the persisted inputs used to build a
    /// message snapshot. It is safe to recompute at the final write boundary:
    /// body and attachment bytes are represented by file generation metadata,
    /// while every SwiftData scalar/relationship consumed by the builder is
    /// encoded directly.
    public static func messageSourceStateFingerprint(_ message: Message?) -> String {
        var encoder = CanonicalEncoder()
        guard let message else {
            encoder.append("message", nil)
            return digest(encoder.data)
        }

        encoder.append("message", message.id.uuidString)
        encoder.append("account", (message.accountID ?? message.account?.id)?.uuidString)
        encoder.append("thread", message.thread?.id.uuidString)
        encoder.append("subject", message.subject)
        encoder.append("from", message.fromAddress)
        encoder.appendDate("sentAt", message.sentAt)
        encoder.appendDate("receivedAt", message.receivedAt)
        encoder.appendDate("ingestedAt", message.ingestedAt)
        encoder.append("listID", message.listId)
        encoder.append("bodyPath", message.bodyTextPath)
        appendFileGeneration(message.bodyTextPath, key: "bodyFile", to: &encoder)

        if let analysis = message.analysis {
            encoder.append("classification", analysis.mailClassificationJSON)
            encoder.append("customCategories", analysis.customCategoryKeysJSON)
            encoder.append("dimensions", analysis.dimensionsJSON)
            encoder.appendDate("interpretedAt", analysis.interpretedAt)
        } else {
            encoder.append("analysis", nil)
        }

        let participants = message.participants.map { link in
            var item = CanonicalEncoder()
            item.append("id", link.id.uuidString)
            item.append("role", link.role.rawValue)
            item.append("participantID", link.participant?.id.uuidString)
            item.append("address", link.participant?.emailAddress)
            item.append("correspondentID", link.participant?.correspondent?.id.uuidString)
            return item.data
        }
        encoder.appendArray("participants", participants)

        let attachments = message.attachments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .prefix(ManualProjectMessageSnapshotBuilder.maximumAttachmentCount)
            .map { attachment in
                var item = CanonicalEncoder()
                item.append("id", attachment.id.uuidString)
                item.append("filename", attachment.filename)
                item.append("textPath", attachment.extractedTextPath)
                item.append("extractionStatus", attachment.extractionStatus)
                appendFileGeneration(
                    attachment.extractedTextPath,
                    key: "textFile",
                    to: &item
                )
                return item.data
            }
        encoder.appendArray("attachments", attachments)
        return digest(encoder.data)
    }

    public static func previewFingerprint(
        configuration: MailProjectConfigurationSnapshot,
        catalog: MailProjectRuleCatalogSnapshot,
        messages: [MailProjectMessageSnapshot]
    ) -> String {
        var encoder = CanonicalEncoder()
        encoder.append("configuration", configurationFingerprint(configuration))
        encoder.append("catalogValidityRevision", catalog.validityRevision)
        encoder.appendArray("messages", messages.map { message in
            var pair = CanonicalEncoder()
            pair.append("id", message.id.uuidString)
            pair.append("sourceFingerprint", message.sourceFingerprint)
            return pair.data
        })
        return digest(encoder.data)
    }

    private static func groupComponent(_ group: MailProjectRuleGroupSnapshot) -> Data {
        var encoder = CanonicalEncoder()
        // Group intent is semantic: a shared AND gate is distinct from an OR match path.
        encoder.append("kind", group.kind.rawValue)
        encoder.appendArray("conditions", group.conditions.map(conditionComponent))
        return encoder.data
    }

    private static func conditionComponent(_ condition: MailProjectRuleConditionSnapshot) -> Data {
        var encoder = CanonicalEncoder()
        encoder.append("facet", condition.facet.rawValue)
        encoder.append("polarity", condition.polarity.rawValue)
        encoder.append("quantifier", condition.quantifier.rawValue)
        encoder.appendArray("values", condition.values.map { Data($0.utf8) })
        encoder.append("correspondentRole", condition.correspondentRole?.rawValue)
        encoder.appendArray("keywordScopes", condition.keywordScopes.map { Data($0.rawValue.utf8) })
        encoder.append("keywordOperator", condition.keywordOperator?.rawValue)
        return encoder.data
    }

    private static func decisionComponent(_ decision: MailProjectDecisionSnapshot) -> Data {
        var encoder = CanonicalEncoder()
        encoder.append("targetKind", decision.targetKind.rawValue)
        encoder.append("targetID", decision.targetID.uuidString)
        encoder.append("decision", decision.decision.rawValue)
        return encoder.data
    }

    private static func appendCorrespondents(
        _ message: MailProjectMessageSnapshot,
        prefix: String,
        to encoder: inout CanonicalEncoder
    ) {
        let roles = Set(message.correspondentIDsByRole.keys).union(message.addressesByRole.keys)
            .sorted { $0.rawValue < $1.rawValue }
        var roleComponents: [Data] = []
        for role in roles {
            var roleEncoder = CanonicalEncoder()
            roleEncoder.append("role", role.rawValue)
            roleEncoder.appendArray("ids", (message.correspondentIDsByRole[role] ?? []).map { Data($0.uuidString.utf8) })
            roleEncoder.appendArray("addresses", (message.addressesByRole[role] ?? []).map { Data($0.utf8) })
            roleComponents.append(roleEncoder.data)
        }
        encoder.appendArray("\(prefix).roles", roleComponents)
    }

    private static func appendFileGeneration(
        _ path: String?,
        key: String,
        to encoder: inout CanonicalEncoder
    ) {
        guard let path else {
            encoder.append(key, nil)
            return
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value
            let modified = attributes[.modificationDate] as? Date
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            encoder.append(
                key,
                [
                    path,
                    size.map(String.init) ?? "<unknown-size>",
                    modified.map { String($0.timeIntervalSinceReferenceDate.bitPattern) }
                        ?? "<unknown-date>",
                    fileNumber.map(String.init) ?? "<unknown-file>",
                ].joined(separator: "|")
            )
        } catch {
            encoder.append(key, "\(path)|<missing>")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CanonicalEncoder {
    private(set) var data = Data()

    mutating func append(_ key: String, _ value: String?) {
        appendLengthPrefixed(Data(key.utf8))
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendLengthPrefixed(Data(value.utf8))
    }

    mutating func appendBool(_ key: String, _ value: Bool) {
        appendLengthPrefixed(Data(key.utf8))
        data.append(value ? 1 : 0)
    }

    mutating func appendDate(_ key: String, _ value: Date?) {
        appendLengthPrefixed(Data(key.utf8))
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendUInt64(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    mutating func appendArray(_ key: String, _ values: [Data]) {
        appendLengthPrefixed(Data(key.utf8))
        let canonicalValues = Array(Set(values)).sorted { $0.lexicographicallyPrecedes($1) }
        appendUInt64(UInt64(canonicalValues.count))
        for value in canonicalValues {
            appendLengthPrefixed(value)
        }
    }

    private mutating func appendLengthPrefixed(_ value: Data) {
        appendUInt64(UInt64(value.count))
        data.append(value)
    }

    private mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
