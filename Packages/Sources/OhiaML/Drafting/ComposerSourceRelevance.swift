import Foundation
import SwiftData
import OhiaCore

@MainActor
enum ComposerSourceRelevance {
    struct SemanticAffinityKeys {
        let tags: Set<String>

        static let empty = SemanticAffinityKeys(tags: [])
    }

    /// The account owner's own addresses and name/address tokens, collected
    /// across every configured account and identity. The user's name is in
    /// nearly every message they ever sent (signature, sign-off) and their
    /// own address rides along as a To/Cc participant on every inbound
    /// message, so neither is evidence that two messages are related —
    /// self tokens must never act as identity bridges.
    struct SelfIdentityProfile {
        let addresses: Set<String>
        let tokens: Set<String>

        static let empty = SelfIdentityProfile(addresses: [], tokens: [])
    }

    static func selfIdentityProfile(context: ModelContext) -> SelfIdentityProfile {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var addresses = Set<String>()
        var textParts: [String] = []

        func addAddress(_ raw: String?) {
            guard let address = raw?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !address.isEmpty else { return }
            addresses.insert(address)
            textParts.append(address)
        }

        for account in accounts {
            addAddress(account.emailAddress)
            textParts.append(account.displayName)
            for identity in account.identities {
                addAddress(identity.address)
                addAddress(identity.replyTo)
                if let displayName = identity.displayName {
                    textParts.append(displayName)
                }
            }
        }
        return SelfIdentityProfile(
            addresses: addresses,
            tokens: tokens(textParts.joined(separator: "\n"), maxTokens: 80)
        )
    }

    static func dimensions(of message: Message) -> MessageDimensions? {
        guard let json = message.analysis?.dimensionsJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MessageDimensions.self, from: data)
    }

    static func draftingAffinityKeys(of message: Message) -> Set<String> {
        Set(draftingMemoryFacets(for: message).draftingAffinityKeys)
    }

    static func draftingAffinityKeys(
        of message: Message,
        knownCustomCategoryKeys: Set<String>
    ) -> Set<String> {
        Set(draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        ).draftingAffinityKeys)
    }

    /// High-quality semantic keys for cross-thread source affinity. Broad,
    /// low-confidence, or incidental labels must not connect two emails in
    /// Composer merely because the extractor emitted the same phrase.
    static func semanticAffinityKeys(of message: Message) -> SemanticAffinityKeys {
        guard let dimensions = dimensions(of: message) else { return .empty }

        let tagKeys = Set(
            SemanticAffinityMembershipResolver
                .memberships(forSemanticTags: dimensions.semanticTags)
                .map(\.semanticKey)
        )
        return SemanticAffinityKeys(tags: tagKeys)
    }

    static func topicalTerms(
        for message: Message,
        excluding selfProfile: SelfIdentityProfile = .empty
    ) -> Set<String> {
        var textParts = [
            message.subject,
            message.analysis?.bodySummary ?? "",
            messageText(for: message, bodyLimit: 3_000, attachmentLimit: 1_200)
        ]
        if let dimensions = dimensions(of: message) {
            textParts.append(contentsOf: semanticAffinityTerms(of: message))
            textParts.append(contentsOf: dimensions.deadlines.compactMap(\.displayText))
            for task in legacyTaskRequirements(of: message, dimensions: dimensions) {
                textParts.append(task.taskType)
                textParts.append(task.actionObject ?? "")
                textParts.append(task.dueCandidate ?? "")
            }
        }
        textParts.append(contentsOf: triageResearchTerms(of: message))

        return tokens(textParts.joined(separator: "\n"), maxTokens: 200)
            .subtracting(selfProfile.tokens)
            .subtracting(identityTerms(for: message, excluding: selfProfile))
    }

    static func semanticAffinityTerms(of message: Message) -> [String] {
        guard let dimensions = dimensions(of: message) else { return [] }
        return SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .map(\.displayName)
    }

    static func subjectTerms(
        for message: Message,
        excluding selfProfile: SelfIdentityProfile = .empty
    ) -> Set<String> {
        tokens(ThreadAssigner.normalizedSubject(message.subject), maxTokens: 64)
            .subtracting(selfProfile.tokens)
            .subtracting(identityTerms(for: message, excluding: selfProfile))
    }

    static func primaryCorrespondentTerms(
        for message: Message,
        excluding selfProfile: SelfIdentityProfile = .empty
    ) -> Set<String> {
        var parts = [message.fromName ?? "", message.fromAddress]
        if let localPart = message.fromAddress.split(separator: "@").first {
            parts.append(String(localPart))
        }
        return tokens(parts.joined(separator: "\n"), maxTokens: 40)
            .subtracting(selfProfile.tokens)
    }

    static func distinctiveIdentifiers(in terms: Set<String>) -> Set<String> {
        Set(terms.filter { token in
            let scalars = token.unicodeScalars
            let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
            let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
            // Bare dates, phone numbers, years, and other numeric strings are
            // common across unrelated mail. A standalone bridge must look
            // like a named record/code (DN-14, RFC5322), not merely a long
            // number that happens to recur.
            return hasDigit && hasLetter && token.count >= 4
        })
    }

    static func relevanceTerms(for message: Message) -> Set<String> {
        relevanceTerms(
            for: message,
            knownCustomCategoryKeys: message.modelContext.map {
                CustomMailCategoryCatalog.allKeys(in: $0)
            } ?? []
        )
    }

    static func relevanceTerms(
        for message: Message,
        knownCustomCategoryKeys: Set<String>
    ) -> Set<String> {
        var textParts = [
            message.subject,
            message.fromName ?? "",
            message.fromAddress,
            message.analysis?.bodySummary ?? "",
            messageText(for: message, bodyLimit: 3_000, attachmentLimit: 1_200)
        ]

        textParts.append(contentsOf: draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        ).draftingAffinityKeys)

        if let dimensions = dimensions(of: message) {
            textParts.append(contentsOf: semanticTagDisplayNames(in: dimensions))
            textParts.append(contentsOf: dimensions.deadlines.compactMap(\.displayText))
            for task in legacyTaskRequirements(of: message, dimensions: dimensions) {
                textParts.append(task.taskType)
                textParts.append(task.actionObject ?? "")
                textParts.append(task.dueCandidate ?? "")
            }
        }
        textParts.append(contentsOf: triageResearchTerms(of: message))

        return tokens(textParts.joined(separator: "\n"), maxTokens: 160)
    }

    static func identityTerms(
        for message: Message,
        excluding selfProfile: SelfIdentityProfile = .empty
    ) -> Set<String> {
        var textParts: [String] = []
        let fromAddress = message.fromAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if selfProfile.addresses.contains(fromAddress) == false {
            textParts.append(message.fromName ?? "")
            textParts.append(message.fromAddress)
            if let localPart = message.fromAddress.split(separator: "@").first {
                textParts.append(String(localPart))
            }
        }
        for participant in message.participants {
            let email = participant.participant?.emailAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let email, selfProfile.addresses.contains(email) { continue }
            if let displayName = participant.participant?.displayName {
                textParts.append(displayName)
            }
            if let email {
                textParts.append(email)
                if let localPart = email.split(separator: "@").first {
                    textParts.append(String(localPart))
                }
            }
        }
        // Address matching skips the user's participant rows; the token
        // subtraction also catches self names that arrive through rows the
        // address check cannot attribute (display-name variants on other
        // addresses, nil-email participants).
        return tokens(textParts.joined(separator: "\n"), maxTokens: 80)
            .subtracting(selfProfile.tokens)
    }

    static func tokens(_ text: String, maxTokens: Int = 128) -> Set<String> {
        AskMemoryTokenizer.tokenize(text, maxTokens: maxTokens)
    }

    static func cleanedBodyText(for message: Message) -> String? {
        guard let path = message.bodyTextPath,
              let stored = try? String(contentsOfFile: path, encoding: .utf8),
              let cleaned = OriginalMessageText.cleaned(from: stored) else {
            return nil
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func messageText(
        for message: Message,
        bodyLimit: Int,
        attachmentLimit: Int
    ) -> String {
        var parts = [message.subject]
        if bodyLimit > 0,
           let cleanedBody = cleanedBodyText(for: message) {
            parts.append(String(cleanedBody.prefix(bodyLimit)))
        } else if let body = textFileSnippet(atPath: message.bodyTextPath, limit: bodyLimit) {
            parts.append(body)
        }
        for attachment in message.attachments.prefix(4) {
            guard let text = textFileSnippet(atPath: attachment.extractedTextPath, limit: attachmentLimit),
                  !text.isEmpty else { continue }
            parts.append("Attachment \(attachment.filename): \(text)")
        }
        return parts.joined(separator: "\n")
    }

    static func textFileSnippet(atPath path: String?, limit: Int) -> String? {
        guard limit > 0,
              let path,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let snippet = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    static func calendarFacts(for message: Message) -> [String] {
        var facts: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let cleaned = raw
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  seen.insert(cleaned.lowercased()).inserted else { return }
            facts.append(cleaned)
        }

        if let dimensions = dimensions(of: message) {
            for deadline in dimensions.deadlines {
                guard let text = deadline.displayText else { continue }
                append("Deadline (\(deadline.type)): \(text)")
            }
            for task in legacyTaskRequirements(of: message, dimensions: dimensions) {
                if let due = task.dueCandidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !due.isEmpty {
                    let object = task.actionObject?.trimmingCharacters(in: .whitespacesAndNewlines)
                    append("Task due \(due): \(object?.isEmpty == false ? object! : task.taskType)")
                }
            }
        }

        if let verdictJSON = message.analysis?.triageVerdictJSON,
           let data = verdictJSON.data(using: .utf8),
           let verdict = try? JSONDecoder().decode(TriageVerdict.self, from: data) {
            for deadline in verdict.deadlineCandidates {
                guard let text = deadline.displayText else { continue }
                append("Deadline (\(deadline.type)): \(text)")
            }
        }

        return facts
    }

    static func triageVerdict(of message: Message) -> TriageVerdict? {
        guard let verdictJSON = message.analysis?.triageVerdictJSON,
              let data = verdictJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TriageVerdict.self, from: data)
    }

    static func triageResearchTerms(of message: Message) -> [String] {
        guard let verdict = triageVerdict(of: message),
              verdict.isActionable,
              let action = verdict.action else { return [] }
        var terms = [action.summary]
        terms.append(contentsOf: action.decisionInputs)
        if let deadline = action.deadline?.displayText {
            terms.append(deadline)
        }
        return terms
    }

    /// Heuristic task requirements survive only on historical rows. A
    /// structured Qwen action is authoritative whenever one is present.
    static func legacyTaskRequirements(
        of message: Message,
        dimensions: MessageDimensions
    ) -> [TaskRequirement] {
        guard triageVerdict(of: message)?.action == nil else { return [] }
        return dimensions.tasks
    }

    static func semanticTagDisplayNames(in dimensions: MessageDimensions) -> [String] {
        SemanticTagProjectionPresentation.canonical(dimensions.semanticTags).map(\.displayName)
    }
}
