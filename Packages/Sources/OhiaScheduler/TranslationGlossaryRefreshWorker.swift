import Foundation
import SwiftData
import OhiaCore
import OhiaML

/// Bounded retrieval-worker pass. It reads only stale messages plus capped
/// mechanically linked rows, and stamps a source only inside the same
/// transaction that commits its evidence.
@MainActor
public final class TranslationGlossaryRefreshWorker {
    public static let evidenceVersion = "translation-glossary-evidence-v1"
    public static let batchLimit = 64
    public static let staleProbeLimit = batchLimit + 1
    public static let pendingProbeLimit = 1
    public static let relatedPerKeyLimit = 8
    public static let relatedTotalLimit = 256

    private let declaredLanguagesForAccount: (Account?) -> [String]
    private let repositoryFactory: (ModelContext) -> TranslationGlossaryRepository

    public struct Outcome: Sendable, Equatable {
        public let processed: Int
        public let hasPendingWork: Bool
        public let relatedRowsFetched: Int
    }

    public init(
        declaredLanguagesForAccount: ((Account?) -> [String])? = nil,
        repositoryFactory: ((ModelContext) -> TranslationGlossaryRepository)? = nil
    ) {
        self.declaredLanguagesForAccount = declaredLanguagesForAccount ?? { account in
            Self.defaultDeclaredLanguages(account)
        }
        self.repositoryFactory = repositoryFactory ?? { TranslationGlossaryRepository(modelContext: $0) }
    }

    public func run(context: ModelContext, now: Date = .now) async throws -> Outcome {
        _ = try TranslationGlossaryCutoverApplier(modelContext: context).run()
        let version = Self.evidenceVersion
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate {
                $0.translationGlossaryEvidenceVersion == nil
                    || $0.translationGlossaryEvidenceVersion != version
            },
            sortBy: [SortDescriptor(\Message.ingestedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.staleProbeLimit
        let stale = try context.fetch(descriptor).sorted(by: Message.newestPipelineFirst)
        let selectedMessages = Array(stale.prefix(Self.batchLimit))

        var selectedSources: [UUID: TranslationGlossaryEvidenceSource] = [:]
        for message in selectedMessages {
            let snapshot = await authoredBodySnapshot(
                for: message.bodyTextPath,
                senderAddress: message.fromAddress
            )
            selectedSources[message.id] = source(for: message, snapshot: snapshot)
        }

        let relatedResult = try await relatedSources(
            for: Array(selectedSources.values),
            selectedSources: selectedSources,
            context: context
        )
        let allSources = Self.deduplicatedSources(Array(selectedSources.values) + relatedResult.sources)
        let allIdentityRecords = allSources.flatMap { Self.identityRecords(from: $0) }
        let repository = repositoryFactory(context)

        for message in selectedMessages {
            guard let source = selectedSources[message.id] else { continue }
            let identity = Self.identityRecords(from: source).flatMap { current in
                TranslationGlossaryEvidenceProducers.identityObservations(
                    current: current,
                    related: allIdentityRecords
                )
            }
            let observations = identity
                + TranslationGlossaryEvidenceProducers.explicitNotationObservations(from: source)
                + TranslationGlossaryEvidenceProducers.linkedCorrespondenceObservations(
                    source: source,
                    related: allSources
                )
            let priorEvidenceVersion = message.translationGlossaryEvidenceVersion
            do {
                try repository.applyBatch(observations, reconciledAt: now) {
                    message.translationGlossaryEvidenceVersion = Self.evidenceVersion
                }
            } catch {
                // SwiftData rollback discards the transaction, but an already
                // referenced model object can retain its assigned scalar in
                // memory. Restore the source stamp explicitly so callers and
                // the next scheduler probe both observe the failed row stale.
                message.translationGlossaryEvidenceVersion = priorEvidenceVersion
                throw error
            }
        }

        return Outcome(
            processed: selectedMessages.count,
            hasPendingWork: stale.count > selectedMessages.count,
            relatedRowsFetched: relatedResult.rowsFetched
        )
    }

    public static func hasPendingWork(context: ModelContext) throws -> Bool {
        let version = Self.evidenceVersion
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate {
            $0.translationGlossaryEvidenceVersion == nil
                || $0.translationGlossaryEvidenceVersion != version
        })
        descriptor.fetchLimit = Self.pendingProbeLimit
        return try context.fetch(descriptor).isEmpty == false
    }

    private struct RelatedResult {
        let sources: [TranslationGlossaryEvidenceSource]
        let rowsFetched: Int
    }

    private func relatedSources(
        for selected: [TranslationGlossaryEvidenceSource],
        selectedSources: [UUID: TranslationGlossaryEvidenceSource],
        context: ModelContext
    ) async throws -> RelatedResult {
        let addresses = Set(selected.flatMap { source in
            source.identitySurfaces.compactMap(Self.addressLookupKey)
        }).sorted()
        let threadIDs = Set(selected.compactMap(\.threadID)).sorted { $0.uuidString < $1.uuidString }
        var remaining = Self.relatedTotalLimit
        var rowsFetched = 0
        var messages: [UUID: Message] = [:]

        for address in addresses where remaining > 0 {
            let limit = min(Self.relatedPerKeyLimit, remaining)
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.fromAddress == address },
                sortBy: [SortDescriptor(\Message.ingestedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let rows = try context.fetch(descriptor)
            rowsFetched += rows.count
            remaining -= rows.count
            for row in rows { messages[row.id] = row }
        }

        for threadID in threadIDs where remaining > 0 {
            let limit = min(Self.relatedPerKeyLimit, remaining)
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.thread?.id == threadID },
                sortBy: [SortDescriptor(\Message.ingestedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let rows = try context.fetch(descriptor)
            rowsFetched += rows.count
            remaining -= rows.count
            for row in rows { messages[row.id] = row }
        }

        var sources: [TranslationGlossaryEvidenceSource] = []
        for message in messages.values.sorted(by: Message.newestPipelineFirst) {
            if let selected = selectedSources[message.id] {
                sources.append(selected)
            } else {
                let snapshot = await authoredBodySnapshot(
                    for: message.bodyTextPath,
                    senderAddress: message.fromAddress
                )
                sources.append(source(for: message, snapshot: snapshot))
            }
        }
        return RelatedResult(sources: sources, rowsFetched: rowsFetched)
    }

    private struct AuthoredBodySnapshot: Sendable {
        struct SignatureIdentity: Sendable {
            let term: String
            let address: String
        }

        let latestAuthoredText: String
        let quotedIdentities: [(term: String, address: String)]
        let signatureIdentity: SignatureIdentity?

        static let empty = AuthoredBodySnapshot(
            latestAuthoredText: "",
            quotedIdentities: [],
            signatureIdentity: nil
        )
    }

    private func authoredBodySnapshot(
        for path: String?,
        senderAddress: String
    ) async -> AuthoredBodySnapshot {
        guard let path else { return .empty }
        return await Task.detached(priority: .utility) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .empty }
            return Self.bodySnapshot(from: text, senderAddress: senderAddress)
        }.value
    }

    nonisolated private static func bodySnapshot(
        from raw: String,
        senderAddress: String
    ) -> AuthoredBodySnapshot {
        let authored = latestAuthoredBody(from: raw)
        return AuthoredBodySnapshot(
            latestAuthoredText: authored,
            quotedIdentities: quotedAttributionIdentities(in: raw),
            signatureIdentity: signatureIdentity(
                in: authored,
                senderAddress: senderAddress
            )
        )
    }

    nonisolated static func latestAuthoredBody(from text: String) -> String {
        QuotedHistoryTail.conservativeAuthoredText(from: text)
    }

    nonisolated static func strippingQuotedHistory(_ text: String) -> String {
        latestAuthoredBody(from: text)
    }

    private func source(
        for message: Message,
        snapshot: AuthoredBodySnapshot
    ) -> TranslationGlossaryEvidenceSource {
        let normalizedAuthor = Self.normalized(message.fromAddress)
        let senderParticipant = message.participants.compactMap { link -> Participant? in
            guard link.role == .from,
                  let participant = link.participant,
                  Self.normalized(participant.emailAddress) == normalizedAuthor else { return nil }
            return participant
        }.first
        let stableContactID = senderParticipant.map { "contact:\($0.id.uuidString.lowercased())" }
        var identities: [TranslationGlossaryIdentitySurface] = []

        if let name = trimmed(message.fromName) {
            let language = sourceSpecificLanguage(for: name, message: message)
            identities.append(.init(term: name, language: language, provenance: .participantAddress(normalizedAuthor)))
            if let stableContactID {
                identities.append(.init(term: name, language: language, provenance: .stableContact(stableContactID)))
            }
        }
        if let participantName = trimmed(senderParticipant?.displayName) {
            let language = sourceSpecificLanguage(for: participantName, message: message)
            identities.append(.init(term: participantName, language: language, provenance: .participantAddress(normalizedAuthor)))
            if let stableContactID {
                identities.append(.init(term: participantName, language: language, provenance: .stableContact(stableContactID)))
            }
        }
        for quoted in snapshot.quotedIdentities {
            identities.append(.init(term: quoted.term, provenance: .quotedAttribution(quoted.address)))
        }
        if let signature = snapshot.signatureIdentity {
            let stableID = stableContactID ?? "address:\(Self.normalized(signature.address))"
            identities.append(.init(
                term: signature.term,
                language: sourceSpecificLanguage(for: signature.term, message: message),
                provenance: .stableSignature(stableID)
            ))
        }

        return TranslationGlossaryEvidenceSource(
            messageID: message.id,
            accountID: message.accountID,
            authorAddress: message.fromAddress,
            declaredLanguages: declaredLanguagesForAccount(message.account),
            body: snapshot.latestAuthoredText,
            identitySurfaces: identities,
            notationHeaderSurfaces: [message.subject],
            threadID: message.thread?.id,
            observedAt: message.pipelineOrderingDate
        )
    }

    nonisolated static func identityRecords(
        from source: TranslationGlossaryEvidenceSource
    ) -> [TranslationGlossaryEvidenceProducers.IdentityRecord] {
        var seen = Set<String>()
        return source.identitySurfaces.compactMap { surface in
            guard case let .participantAddress(address) = surface.provenance,
                  Self.normalized(address) == Self.normalized(source.authorAddress),
                  let language = validatedLanguage(for: surface, declared: source.declaredLanguages),
                  seen.insert("\(language)|\(surface.term)").inserted else { return nil }
            return .init(
                address: address,
                displayName: surface.term,
                language: language,
                accountID: source.accountID,
                sourceMessageID: source.messageID,
                observedAt: source.observedAt
            )
        }
    }

    nonisolated private static func validatedLanguage(
        for surface: TranslationGlossaryIdentitySurface,
        declared: [String]
    ) -> String? {
        if let language = surface.language {
            let declaredLanguages = Set(declared.compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:)))
            guard declaredLanguages.contains(language),
                  TranslationGlossaryCandidateValidator.scriptCompatibleDeclaredLanguages(
                    for: surface.term,
                    declaredLanguages: [language]
                  ) == [language] else { return nil }
            return language
        }
        return uniqueLanguage(for: surface.term, declared: declared)
    }

    nonisolated private static func uniqueLanguage(for term: String, declared: [String]) -> String? {
        let matches = TranslationGlossaryCandidateValidator.scriptCompatibleDeclaredLanguages(
            for: term,
            declaredLanguages: declared
        )
        return matches.count == 1 ? matches[0] : nil
    }

    private func sourceSpecificLanguage(for term: String, message: Message) -> String? {
        guard let detected = message.languageDetected.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:)) else {
            return nil
        }
        let declared = declaredLanguagesForAccount(message.account)
            .compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:))
        guard declared.contains(detected),
              TranslationGlossaryCandidateValidator.scriptCompatibleDeclaredLanguages(
                for: term,
                declaredLanguages: [detected]
              ) == [detected] else { return nil }
        return detected
    }

    private static func addressLookupKey(
        _ surface: TranslationGlossaryIdentitySurface
    ) -> String? {
        switch surface.provenance {
        case let .participantAddress(address), let .quotedAttribution(address):
            return normalized(address)
        case let .stableSignature(identity), let .stableContact(identity):
            guard identity.hasPrefix("address:") else { return nil }
            return normalized(String(identity.dropFirst("address:".count)))
        }
    }

    private static func defaultDeclaredLanguages(_ account: Account?) -> [String] {
        let accountLanguages = account?.draftLanguagesJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return TranslationLanguages.declaredCodes(accountDraftLanguages: accountLanguages)
    }

    private static func deduplicatedSources(
        _ sources: [TranslationGlossaryEvidenceSource]
    ) -> [TranslationGlossaryEvidenceSource] {
        var seen = Set<UUID>()
        return sources.filter { seen.insert($0.messageID).inserted }
    }

    nonisolated private static func quotedAttributionIdentities(
        in raw: String
    ) -> [(term: String, address: String)] {
        var result: [(String, String)] = []
        for line in normalizedLines(raw) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ReplyAttribution.isAttributionLine(trimmed),
                  let address = firstEmailAddress(in: trimmed),
                  let term = ReplyAttribution.parse(trimmed).author,
                  term.isEmpty == false else { continue }
            result.append((term, address))
        }
        return result
    }

    nonisolated private static func signatureIdentity(
        in currentAuthoredText: String,
        senderAddress: String
    ) -> AuthoredBodySnapshot.SignatureIdentity? {
        let lines = normalizedLines(currentAuthoredText)
        guard let separator = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "--"
        }) else { return nil }
        let block = lines.dropFirst(separator + 1).prefix(12).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedSender = normalized(senderAddress)
        guard block.compactMap(firstEmailAddress).contains(normalizedSender),
              let term = block.compactMap({
                  TranslationGlossaryCandidateValidator.personalNameValue(inLabeledField: $0)
              }).first else { return nil }
        return .init(term: term, address: normalizedSender)
    }

    nonisolated private static func firstEmailAddress(in value: String) -> String? {
        guard value.utf16.count <= 1_000,
              let regex = try? NSRegularExpression(
                pattern: #"[A-Z0-9._%+\-]{1,64}@[A-Z0-9.\-]{1,255}\.[A-Z]{2,63}"#,
                options: [.caseInsensitive]
              ),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range, in: value) else { return nil }
        return normalized(String(value[range]))
    }

    nonisolated private static func normalizedLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
