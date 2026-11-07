import Foundation
import SwiftData
import OhiaCore

/// Builds source-aware translation context from one user-wide canonical
/// glossary. `accountID` scopes style rules only; it never scopes dyads.
public struct TranslationGlossaryProvider: TranslationContextProviding {
    private let container: ModelContainer
    private let maxRules: Int

    public init(container: ModelContainer, maxRules: Int = 8) {
        self.container = container
        self.maxRules = max(0, maxRules)
    }

    public func translationContext(
        forAccount accountID: UUID?,
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguage: SummarizationTargetLanguage
    ) -> TranslationContext? {
        translationContext(
            accountID: accountID,
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguage: targetLanguage,
            in: ModelContext(container)
        )
    }

    public func translationContext(
        forMessage messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        sourceLanguageCode: String?
    ) async -> TranslationContext? {
        let context = ModelContext(container)
        let message = Self.message(for: messageID, in: context)
        return translationContext(
            accountID: message?.accountID ?? message?.account?.id,
            sourceText: bodyText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguage: targetLanguage,
            messageIdentityRules: Self.messageIdentityRules(for: message),
            in: context
        )
    }

    private func translationContext(
        accountID: UUID?,
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguage: SummarizationTargetLanguage,
        messageIdentityRules: [String] = [],
        in context: ModelContext
    ) -> TranslationContext? {
        guard let target = LocalModelLanguageSupport.canonicalLanguageID(
            for: targetLanguage.identifier
        ) else { return nil }
        let source: String
        if let sourceLanguageCode {
            guard let resolved = LocalModelLanguageSupport.canonicalLanguageID(
                for: sourceLanguageCode
            ), resolved != target else { return nil }
            source = resolved
        } else {
            guard let inferred = inferredSourceLanguage(
                sourceText: sourceText,
                targetLanguageCode: target,
                in: context
            ) else { return nil }
            source = inferred
        }
        let selected = selectedEntries(
            sourceText: sourceText,
            sourceLanguageCode: source,
            targetLanguageCode: target,
            in: context
        )
        let accountRules = accountID.map { styleRules(accountID: $0, target: target, in: context) } ?? []
        let result = TranslationContext(
            exactGlossary: selected.filter { $0.authority == .exact },
            provisionalGlossary: selected.filter { $0.authority == .provisional },
            rules: messageIdentityRules + accountRules
        )
        return result.isEmpty ? nil : result
    }

    /// Short names and CJK contact facts often cannot satisfy statistical
    /// language detection. A canonical dyad can still identify the source side
    /// from the known target, but only when every applicable pair agrees on one
    /// source language. Conflicting language candidates fail closed.
    private func inferredSourceLanguage(
        sourceText: String,
        targetLanguageCode: String,
        in context: ModelContext
    ) -> String? {
        guard sourceText.isEmpty == false else { return nil }
        let candidates = ((try? context.fetch(FetchDescriptor<TranslationGlossaryPair>())) ?? [])
            .compactMap { pair -> String? in
                guard let status = TranslationGlossaryPairStatus(rawValue: pair.statusRaw),
                      TranslationGlossaryPolicy.authority(
                        status: status,
                        confidence: pair.confidence
                      ) != .excluded else { return nil }
                let sourceLanguage: String
                let sourceTerm: String
                if pair.canonicalLanguageA == targetLanguageCode {
                    sourceLanguage = pair.canonicalLanguageB
                    sourceTerm = pair.termB
                } else if pair.canonicalLanguageB == targetLanguageCode {
                    sourceLanguage = pair.canonicalLanguageA
                    sourceTerm = pair.termA
                } else {
                    return nil
                }
                guard TranslationGlossaryTextMatcher.eligibleRanges(
                    of: sourceTerm,
                    in: sourceText
                ).isEmpty == false else { return nil }
                return sourceLanguage
            }
        let unique = Set(candidates)
        return unique.count == 1 ? unique.first : nil
    }

    private func selectedEntries(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        in context: ModelContext
    ) -> [TranslationGlossaryEntry] {
        guard sourceText.isEmpty == false,
              let sourceLanguageCode,
              let targetLanguageCode,
              sourceLanguageCode != targetLanguageCode else { return [] }

        let candidates = ((try? context.fetch(FetchDescriptor<TranslationGlossaryPair>())) ?? [])
            .compactMap { pair -> TranslationGlossaryEntry? in
                guard let status = TranslationGlossaryPairStatus(rawValue: pair.statusRaw) else { return nil }
                let authority = TranslationGlossaryPolicy.authority(
                    status: status,
                    confidence: pair.confidence
                )
                guard authority != .excluded else { return nil }

                let sourceTerm: String
                let targetRendering: String
                if pair.canonicalLanguageA == sourceLanguageCode,
                   pair.canonicalLanguageB == targetLanguageCode {
                    sourceTerm = pair.termA
                    targetRendering = pair.termB
                } else if pair.canonicalLanguageB == sourceLanguageCode,
                          pair.canonicalLanguageA == targetLanguageCode {
                    sourceTerm = pair.termB
                    targetRendering = pair.termA
                } else {
                    return nil
                }
                guard sourceTerm.isEmpty == false,
                      targetRendering.isEmpty == false,
                      TranslationGlossaryTextMatcher.eligibleRanges(
                        of: sourceTerm,
                        in: sourceText
                      ).isEmpty == false else { return nil }
                return TranslationGlossaryEntry(
                    pairID: pair.id,
                    sourceTerm: sourceTerm,
                    targetRendering: targetRendering,
                    authority: authority
                )
            }
        // Exact authority is allocated before provisional authority. Otherwise
        // a longer provisional phrase can occupy a confirmed term's occurrence
        // and leave the confirmed source spelling exposed to generation.
        let orderedCandidates = candidates
            .filter { $0.authority == .exact }
            .sorted(by: Self.entryPrecedes)
            + candidates
                .filter { $0.authority == .provisional }
                .sorted(by: Self.entryPrecedes)

        var occupied: [Range<String.Index>] = []
        var selected: [TranslationGlossaryEntry] = []
        for candidate in orderedCandidates {
            let nonoverlapping = TranslationGlossaryTextMatcher.eligibleRanges(
                of: candidate.sourceTerm,
                in: sourceText
            ).filter { range in
                occupied.allSatisfy { !$0.overlaps(range) }
            }
            guard nonoverlapping.isEmpty == false else { continue }
            selected.append(candidate)
            occupied.append(contentsOf: nonoverlapping)
        }
        return selected
    }

    private static func entryPrecedes(
        _ lhs: TranslationGlossaryEntry,
        _ rhs: TranslationGlossaryEntry
    ) -> Bool {
        if lhs.sourceTerm.count != rhs.sourceTerm.count {
            return lhs.sourceTerm.count > rhs.sourceTerm.count
        }
        if lhs.sourceTerm != rhs.sourceTerm { return lhs.sourceTerm < rhs.sourceTerm }
        return lhs.pairID.uuidString < rhs.pairID.uuidString
    }

    private func styleRules(
        accountID: UUID,
        target: String?,
        in context: ModelContext
    ) -> [String] {
        guard let target, maxRules > 0 else { return [] }
        var descriptor = FetchDescriptor<AccountMemory>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
        let rows = ((try? context.fetch(descriptor)) ?? []).filter { memory in
            memory.dimensionKind == AccountMemoryDimension.translation
                && EmailLanguageDetector.canonicalBaseCode(memory.resolvedDimensionValue) == target
                && memory.isHiddenByDefault == false
                && memory.isSensitiveAndUnaffirmed == false
                && memory.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && TranslationStyleRuleWriter.isGlossaryShaped(memory.displayText) == false
                && TranslationStyleRuleWriter.isStyleRule(memory)
        }
        return rows.sorted { lhs, rhs in
            let lhsAffirmed = lhs.statusRaw == AccountMemoryProjectedStatus.affirmed
            let rhsAffirmed = rhs.statusRaw == AccountMemoryProjectedStatus.affirmed
            if lhsAffirmed != rhsAffirmed { return lhsAffirmed }
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }.prefix(maxRules).map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func message(for messageID: UUID, in context: ModelContext) -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Header recipients supply the spelling the model cannot recover from a
    /// phonetic source form such as Japanese katakana. Account identities mark
    /// which recipient is the user and provide a fallback for sent messages.
    private static func messageIdentityRules(for message: Message?) -> [String] {
        guard let message else { return [] }
        let account = message.account
        let accountIdentities = account?.identities ?? []
        let ownerAddresses = Set(
            accountIdentities.map { normalizedAddress($0.address) }
                + [normalizedAddress(account?.emailAddress ?? "")]
        ).subtracting([""])

        let recipients = message.participants
            .filter { $0.role == .to || $0.role == .cc }
            .sorted { lhs, rhs in
                let lhsRole = lhs.role == .to ? 0 : 1
                let rhsRole = rhs.role == .to ? 0 : 1
                if lhsRole != rhsRole { return lhsRole < rhsRole }
                if lhs.headerPosition != rhs.headerPosition {
                    return (lhs.headerPosition ?? Int.max) < (rhs.headerPosition ?? Int.max)
                }
                return normalizedAddress(lhs.participant?.emailAddress ?? "")
                    < normalizedAddress(rhs.participant?.emailAddress ?? "")
            }

        var rules: [String] = []
        var includedAddresses: Set<String> = []
        var includesAccountOwner = false
        for relationship in recipients {
            if rules.count == 8 { break }
            guard let participant = relationship.participant else { continue }
            let address = normalizedAddress(participant.emailAddress)
            guard address.isEmpty == false, includedAddresses.contains(address) == false else { continue }
            let storedName = accountIdentities.sorted(by: identityPrecedes).first {
                normalizedAddress($0.address) == address
            }?.displayName
            guard let displayName = normalizedName(participant.displayName) ?? normalizedName(storedName) else {
                continue
            }
            includedAddresses.insert(address)
            let isAccountOwner = ownerAddresses.contains(address)
            includesAccountOwner = includesAccountOwner || isAccountOwner
            let role = relationship.role == .to ? "To" : "Cc"
            let owner = isAccountOwner ? "; account owner" : ""
            rules.append(
                "Message recipient (\(role)\(owner)): \(displayName) <\(address)>. "
                    + "Use this spelling exactly when the source refers to or addresses this person."
            )
        }

        if includesAccountOwner == false,
           rules.count < 8,
           let identity = accountIdentities.sorted(by: identityPrecedes).first(where: {
               normalizedName($0.displayName) != nil
           }),
           let displayName = normalizedName(identity.displayName) {
            let address = normalizedAddress(identity.address)
            if address.isEmpty == false {
                rules.append(
                    "Account owner: \(displayName) <\(address)>. "
                        + "Use this spelling exactly when the source refers to this person."
                )
            }
        }
        return rules
    }

    private static func identityPrecedes(_ lhs: Identity, _ rhs: Identity) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
        return normalizedAddress(lhs.address) < normalizedAddress(rhs.address)
    }

    private static func normalizedAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \Character.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        return String(normalized.prefix(160))
    }
}

/// Shared literal matcher for provider selection and exact protection.
enum TranslationGlossaryTextMatcher {
    static func eligibleRanges(of term: String, in text: String) -> [Range<String.Index>] {
        guard term.isEmpty == false, text.isEmpty == false else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: [.literal], range: searchStart..<text.endIndex) {
            if hasValidBoundaries(range, term: term, in: text) {
                ranges.append(range)
            }
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func hasValidBoundaries(
        _ range: Range<String.Index>,
        term: String,
        in text: String
    ) -> Bool {
        guard requiresTokenBoundaries(term) else { return true }
        if range.lowerBound > text.startIndex {
            let prior = text[text.index(before: range.lowerBound)]
            if isTokenCharacter(prior) { return false }
        }
        if range.upperBound < text.endIndex,
           isTokenCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func requiresTokenBoundaries(_ term: String) -> Bool {
        term.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF, 0x0400...0x052F,
                 0x2DE0...0x2DFF, 0xA640...0xA69F, 0xAB30...0xAB6F:
                true
            default:
                false
            }
        }
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "_"
        }
    }
}
