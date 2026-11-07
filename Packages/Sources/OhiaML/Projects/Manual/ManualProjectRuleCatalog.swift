import CryptoKit
import Foundation
import OhiaCore
import SwiftData

/// Reads a manual-project rule inventory synchronously from the caller's
/// SwiftData context. Returned snapshots contain values only.
public struct ManualProjectRuleCatalog {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func snapshot(
        selectedValuesByFacet: [MailProjectRuleFacet: Set<String>] = [:]
    ) throws -> MailProjectRuleCatalogSnapshot {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let correspondents = try modelContext.fetch(FetchDescriptor<Correspondent>())
        let participants = try modelContext.fetch(FetchDescriptor<Participant>())
        let mailingLists = try modelContext.fetch(FetchDescriptor<MailingList>())
        let categories = try modelContext.fetch(FetchDescriptor<CustomMailCategory>())
            .filter { $0.statusRaw == CustomMailCategoryStatus.collecting.rawValue || $0.statusRaw == CustomMailCategoryStatus.active.rawValue }
        let messages = try modelContext.fetch(FetchDescriptor<Message>())
        let messageParticipants = try modelContext.fetch(FetchDescriptor<MessageParticipant>())
        let semanticTags = try modelContext.fetch(FetchDescriptor<SemanticTag>())
        let semanticAliases = try modelContext.fetch(FetchDescriptor<SemanticTagAlias>())
        let semanticMemberships = try modelContext.fetch(FetchDescriptor<MessageSemanticTagMembership>())

        var accountCounts: [UUID: Int] = [:]
        var purposeCounts: [MailPurpose: Int] = [:]
        var customCategoryCounts: [String: Int] = [:]
        var valuesByFacetCounts: [MailProjectRuleFacet: [String: Int]] = [:]
        var displaysByFacet: [MailProjectRuleFacet: [String: Set<String>]] = [:]
        var semanticValuesByCorrespondent: [UUID: [MailProjectRuleFacet: Set<String>]] = [:]
        var semanticTagCooccurrenceCounts: [
            MailProjectSemanticTagIdentity: [MailProjectSemanticTagIdentity: Int]
        ] = [:]
        var correspondentIDsByMessage: [UUID: Set<UUID>] = [:]
        for link in messageParticipants {
            guard let messageID = link.message?.id,
                  let participant = link.participant else { continue }
            correspondentIDsByMessage[messageID, default: []].insert(participant.id)
            if let aggregateID = participant.correspondent?.id {
                correspondentIDsByMessage[messageID, default: []].insert(aggregateID)
            }
        }

        for message in messages {
            if let accountID = message.accountID ?? message.account?.id {
                accountCounts[accountID, default: 0] += 1
            }
            let analysis = message.analysis
            if let purpose = MailClassificationJSON.decode(analysis?.mailClassificationJSON)?.purpose {
                purposeCounts[purpose, default: 0] += 1
            }
            for key in Set(CustomCategoryKeysJSON.decode(analysis?.customCategoryKeysJSON)) {
                customCategoryCounts[key, default: 0] += 1
            }
            if let language = DraftLanguage.familyID(for: message.languageDetected) {
                record(
                    [language: [language]],
                    facet: .language,
                    counts: &valuesByFacetCounts,
                    displays: &displaysByFacet
                )
            }
        }

        let tagsByID = Dictionary(uniqueKeysWithValues: semanticTags.map { ($0.id, $0) })
        let promotedTagIDs = Set(semanticTags.compactMap { tag in
            tag.lifecycle == .promoted && tag.mergedIntoTagID == nil ? tag.id : nil
        })
        var aliasesByTagID: [UUID: Set<String>] = [:]
        for alias in semanticAliases {
            guard let rawTagID = alias.tag?.id,
                  let tagID = Self.resolvedTagID(rawTagID, tagsByID: tagsByID),
                  promotedTagIDs.contains(tagID) else { continue }
            let display = alias.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if display.isEmpty == false {
                aliasesByTagID[tagID, default: []].insert(display)
            }
        }

        var logicalMessagesByTagID: [UUID: Set<String>] = [:]
        var tagIDsByLogicalMessage: [String: Set<UUID>] = [:]
        for membership in semanticMemberships {
            guard let tagID = Self.resolvedTagID(membership.tagID, tagsByID: tagsByID),
                  promotedTagIDs.contains(tagID) else { continue }
            let logicalMessageKey = membership.logicalMessageKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard logicalMessageKey.isEmpty == false else { continue }
            logicalMessagesByTagID[tagID, default: []].insert(logicalMessageKey)
            tagIDsByLogicalMessage[logicalMessageKey, default: []].insert(tagID)
            let stableKey = tagID.uuidString.lowercased()
            for correspondentID in correspondentIDsByMessage[membership.messageID, default: []] {
                semanticValuesByCorrespondent[correspondentID, default: [:]][.semanticTag, default: []]
                    .insert(stableKey)
            }
        }
        for tagIDs in tagIDsByLogicalMessage.values {
            let identities = tagIDs.map(MailProjectSemanticTagIdentity.init(tagID:))
                .sorted { $0.stableKey < $1.stableKey }
            guard identities.count > 1 else { continue }
            for sourceIndex in identities.indices {
                for targetIndex in identities.index(after: sourceIndex)..<identities.endIndex {
                    let source = identities[sourceIndex]
                    let target = identities[targetIndex]
                    semanticTagCooccurrenceCounts[source, default: [:]][target, default: 0] += 1
                    semanticTagCooccurrenceCounts[target, default: [:]][source, default: 0] += 1
                }
            }
        }

        var accountValues = accounts.map { account in
            MailProjectCatalogValue(
                stableKey: account.id.uuidString,
                displayName: account.displayName,
                currentMatchCount: accountCounts[account.id, default: 0],
                isValid: true
            )
        }
        let accountIDs = Set(accounts.map { $0.id.uuidString })
        for selected in selectedValuesByFacet[.account, default: []] where accountIDs.contains(selected) == false {
            accountValues.append(MailProjectCatalogValue(
                stableKey: selected,
                displayName: selected,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        accountValues = Self.sortedCatalogValues(accountValues)

        var messageIDsByCorrespondent: [UUID: Set<UUID>] = [:]
        for link in messageParticipants {
            guard let messageID = link.message?.id,
                  let participant = link.participant else {
                continue
            }
            messageIDsByCorrespondent[participant.id, default: []].insert(messageID)
            if let aggregateID = participant.correspondent?.id {
                messageIDsByCorrespondent[aggregateID, default: []].insert(messageID)
            }
        }
        var correspondentValues = correspondents.map { correspondent in
            MailProjectCorrespondentCatalogValue(
                id: correspondent.id,
                canonicalID: correspondent.id,
                displayName: correspondent.primaryName,
                resolvedAddresses: Array(Set(correspondent.linkedParticipants.compactMap { participant in
                    let address = Self.normalizedAddress(participant.emailAddress)
                    return address.isEmpty ? nil : address
                })).sorted(),
                currentMatchCount: messageIDsByCorrespondent[correspondent.id, default: []].count
            )
        }
        correspondentValues.append(contentsOf: participants.compactMap { participant in
            guard participant.correspondent == nil else { return nil }
            let address = Self.normalizedAddress(participant.emailAddress)
            guard address.isEmpty == false else { return nil }
            let name = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = if let name, name.isEmpty == false {
                name
            } else {
                address
            }
            return MailProjectCorrespondentCatalogValue(
                id: participant.id,
                canonicalID: participant.id,
                displayName: displayName,
                resolvedAddresses: [address],
                currentMatchCount: messageIDsByCorrespondent[participant.id, default: []].count
            )
        })
        let selectedCorrespondentIDs = selectedValuesByFacet[.correspondent, default: []]
        correspondentValues.append(contentsOf: participants.compactMap { participant in
            guard let correspondentID = participant.correspondent?.id,
                  selectedCorrespondentIDs.contains(participant.id.uuidString) else {
                return nil
            }
            let address = Self.normalizedAddress(participant.emailAddress)
            let name = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = if let name, name.isEmpty == false {
                name
            } else if address.isEmpty == false {
                address
            } else {
                participant.id.uuidString
            }
            return MailProjectCorrespondentCatalogValue(
                id: participant.id,
                canonicalID: correspondentID,
                displayName: displayName,
                resolvedAddresses: address.isEmpty ? [] : [address],
                currentMatchCount: messageIDsByCorrespondent[participant.id, default: []].count
            )
        })
        correspondentValues.sort(by: Self.correspondentOrder)

        var facetValues: [MailProjectRuleFacet: [MailProjectCatalogValue]] = [:]
        facetValues[.fixedCategory] = Self.sortedCatalogValues(MailPurpose.allCases.map { purpose in
            MailProjectCatalogValue(
                stableKey: purpose.rawValue,
                displayName: purpose.displayLabel,
                currentMatchCount: purposeCounts[purpose, default: 0],
                isValid: true
            )
        })

        var customValues = categories.map { category in
            MailProjectCatalogValue(
                stableKey: category.key,
                displayName: category.displayName,
                currentMatchCount: customCategoryCounts[category.key, default: 0],
                isValid: true
            )
        }
        let categoryKeys = Set(categories.map(\.key))
        for selected in selectedValuesByFacet[.customCategory, default: []] where categoryKeys.contains(selected) == false {
            customValues.append(MailProjectCatalogValue(
                stableKey: selected,
                displayName: selected,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        facetValues[.customCategory] = Self.sortedCatalogValues(customValues)

        var mailingListValues = mailingLists.map { list in
            MailProjectCatalogValue(
                stableKey: MailProjectMailingListValue.stableKey(
                    accountID: list.accountID,
                    listID: list.listId
                ),
                displayName: list.displayName,
                detail: list.listAddress ?? list.listId,
                currentMatchCount: list.messageCount,
                isValid: true
            )
        }
        let mailingListKeys = Set(mailingListValues.map(\.stableKey))
        for selected in selectedValuesByFacet[.mailingList, default: []]
            where mailingListKeys.contains(selected) == false {
            mailingListValues.append(MailProjectCatalogValue(
                stableKey: selected,
                displayName: selected,
                detail: selected,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        facetValues[.mailingList] = Self.sortedCatalogValues(mailingListValues)

        var semanticTagValues = promotedTagIDs.compactMap { tagID -> MailProjectCatalogValue? in
            guard let tag = tagsByID[tagID] else { return nil }
            let aliases = aliasesByTagID[tagID, default: []]
                .filter { $0.localizedCaseInsensitiveCompare(tag.preferredDisplayName) != .orderedSame }
                .sorted()
            return MailProjectCatalogValue(
                stableKey: tagID.uuidString.lowercased(),
                displayName: tag.preferredDisplayName,
                detail: aliases.isEmpty ? nil : aliases.joined(separator: " · "),
                currentMatchCount: logicalMessagesByTagID[tagID, default: []].count,
                isValid: true
            )
        }
        let promotedSemanticTagValues = semanticTagValues
        let promotedStableKeys = Set(semanticTagValues.map { $0.stableKey.lowercased() })
        for selected in selectedValuesByFacet[.semanticTag, default: []]
            where promotedStableKeys.contains(selected.lowercased()) == false {
            semanticTagValues.append(MailProjectCatalogValue(
                stableKey: selected,
                displayName: selected,
                currentMatchCount: 0,
                isValid: false
            ))
        }
        facetValues[.semanticTag] = Self.sortedCatalogValues(semanticTagValues)

        for facet in Self.metadataFacets {
            var keys = Set(valuesByFacetCounts[facet]?.keys ?? Dictionary<String, Int>().keys)
            keys.formUnion(selectedValuesByFacet[facet, default: []])
            let values = keys.map { key in
                MailProjectCatalogValue(
                    stableKey: key,
                    displayName: displaysByFacet[facet]?[key]?.sorted().first ?? key,
                    currentMatchCount: valuesByFacetCounts[facet]?[key, default: 0] ?? 0,
                    isValid: true
                )
            }
            facetValues[facet] = Self.sortedCatalogValues(values)
        }

        return MailProjectRuleCatalogSnapshot(
            accounts: accountValues,
            correspondents: correspondentValues,
            valuesByFacet: facetValues,
            semanticValuesByCorrespondent: semanticValuesByCorrespondent,
            semanticTagCooccurrenceCounts: semanticTagCooccurrenceCounts,
            validityRevision: validityRevision(
                accountIDs: accounts.map(\.id),
                correspondentIDs: correspondents.map(\.id) + participants.map(\.id),
                customCategoryKeys: categories.map(\.key),
                mailingListKeys: Array(mailingListKeys),
                semanticTagValues: promotedSemanticTagValues,
                semanticTagCooccurrenceCounts: semanticTagCooccurrenceCounts
            )
        )
    }

    public static func search(
        _ query: String,
        in values: [MailProjectCatalogValue]
    ) -> [MailProjectCatalogValue] {
        let normalizedQuery = normalizedSearchText(query)
        let filtered = normalizedQuery.isEmpty ? values : values.filter { value in
            normalizedSearchText(value.stableKey).contains(normalizedQuery)
                || normalizedSearchText(value.displayName).contains(normalizedQuery)
                || normalizedSearchText(value.detail ?? "").contains(normalizedQuery)
        }
        return sortedCatalogValues(filtered)
    }

    private func record(
        _ valuesForMessage: [String: Set<String>],
        facet: MailProjectRuleFacet,
        counts: inout [MailProjectRuleFacet: [String: Int]],
        displays: inout [MailProjectRuleFacet: [String: Set<String>]]
    ) {
        for (key, valueDisplays) in valuesForMessage {
            counts[facet, default: [:]][key, default: 0] += 1
            displays[facet, default: [:]][key, default: []].formUnion(valueDisplays)
        }
    }

    private func validityRevision(
        accountIDs: [UUID],
        correspondentIDs: [UUID],
        customCategoryKeys: [String],
        mailingListKeys: [String],
        semanticTagValues: [MailProjectCatalogValue],
        semanticTagCooccurrenceCounts: [
            MailProjectSemanticTagIdentity: [MailProjectSemanticTagIdentity: Int]
        ]
    ) -> String {
        var encoder = InventoryEncoder()
        encoder.append("accounts", accountIDs.map(\.uuidString))
        encoder.append("correspondents", correspondentIDs.map(\.uuidString))
        encoder.append("fixedPurposes", MailPurpose.allCases.map(\.rawValue))
        encoder.append("customCategories", customCategoryKeys)
        encoder.append("mailingLists", mailingListKeys)
        encoder.append("semanticTags", semanticTagValues.flatMap { value in
            [
                value.stableKey,
                value.displayName,
                value.detail ?? "",
                String(value.currentMatchCount),
                String(value.isValid),
            ]
        })
        encoder.append("semanticTagCooccurrence", semanticTagCooccurrenceCounts.flatMap { source, targets in
            targets.map { target, count in
                "\(source.stableKey)|\(target.stableKey)|\(count)"
            }
        })
        return SHA256.hash(data: encoder.data).map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedTagID(
        _ tagID: UUID,
        tagsByID: [UUID: SemanticTag]
    ) -> UUID? {
        var currentID = tagID
        var visited: Set<UUID> = []
        while let tag = tagsByID[currentID] {
            guard visited.insert(currentID).inserted else { return nil }
            guard let mergedIntoTagID = tag.mergedIntoTagID else { return currentID }
            currentID = mergedIntoTagID
        }
        return nil
    }

    private static func normalizedAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func sortedCatalogValues(_ values: [MailProjectCatalogValue]) -> [MailProjectCatalogValue] {
        values.sorted { lhs, rhs in
            let lhsDisplay = normalizedSearchText(lhs.displayName)
            let rhsDisplay = normalizedSearchText(rhs.displayName)
            if lhsDisplay != rhsDisplay { return lhsDisplay < rhsDisplay }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.stableKey < rhs.stableKey
        }
    }

    private static func correspondentOrder(
        _ lhs: MailProjectCorrespondentCatalogValue,
        _ rhs: MailProjectCorrespondentCatalogValue
    ) -> Bool {
        let lhsDisplay = normalizedSearchText(lhs.displayName)
        let rhsDisplay = normalizedSearchText(rhs.displayName)
        if lhsDisplay != rhsDisplay { return lhsDisplay < rhsDisplay }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static let metadataFacets: [MailProjectRuleFacet] = [
        .language,
    ]
}

private struct InventoryEncoder {
    private(set) var data = Data()

    mutating func append(_ key: String, _ values: [String]) {
        appendLengthPrefixed(Data(key.utf8))
        let canonicalValues = Array(Set(values)).sorted()
        appendUInt64(UInt64(canonicalValues.count))
        for value in canonicalValues {
            appendLengthPrefixed(Data(value.utf8))
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
