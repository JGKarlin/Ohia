import Foundation
import OhiaCore
import OSLog
import SwiftData

@MainActor
public enum MessageSummaryWriter {
    private static let summaryOnlyAnalysisVersion = "summary-only"
    private static let classificationLogger = Logger(
        subsystem: "com.ohia.app",
        category: "MailClassification"
    )
    private static let verdictEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private static let dimensionsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private static let dimensionsDecoder = JSONDecoder()

    @discardableResult
    public static func persist(
        messageID: UUID,
        summaryInputFingerprint: String,
        result: SummarizationResult,
        summarizedAt: Date,
        context: ModelContext,
        updateInterpretationFromResult: Bool = true,
        updateMessageTypeFromVerdict: Bool = true
    ) throws -> Bool {
        guard let storedSummary = SummaryTextSanitizer.cleaned(result.summary) else {
            return false
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            return false
        }

        let analysis: MessageAnalysis
        if let existing = message.analysis {
            analysis = existing
        } else {
            let created = MessageAnalysis(
                message: message,
                analysisVersion: summaryOnlyAnalysisVersion,
                dimensionsJSON: "{}"
            )
            context.insert(created)
            message.analysis = created
            analysis = created
        }

        analysis.bodySummary = storedSummary
        analysis.bodySummaryInputFingerprint = summaryInputFingerprint
        analysis.summarizedAt = summarizedAt
        guard updateInterpretationFromResult else {
            try context.save()
            return true
        }

        let classification = resolvedClassification(
            message: message,
            candidates: result.classificationCandidates,
            existing: result.classification,
            context: context
        )
        try persistClassification(
            classification,
            customCategoryKeys: result.customCategoryKeys,
            candidates: result.classificationCandidates,
            analysis: analysis
        )
        let deliveryFacts = deliveryFacts(for: message, context: context)
        let normalizedVerdict = result.triageVerdict.map {
            TriageVerdictPolicy.normalizedForAttention(
                $0.normalizingActionability(isSentByUser: message.isSentByUser),
                purpose: classification.purpose,
                senderAddress: message.fromAddress,
                senderName: message.fromName,
                subject: message.subject,
                bodyText: bodyTextPrefix(for: message),
                deliveryFacts: deliveryFacts
            )
        }
        analysis.triageVerdictJSON = try normalizedVerdict.map(encodeVerdict)
        try mergeTriageDeadlines(normalizedVerdict?.deadlineCandidates ?? [], into: analysis)
        try SemanticTagIntake.persist(
            candidates: result.semanticTagCandidates,
            for: message,
            extractionVersion: normalizedVerdict?.extractionVersion
                ?? MLXSummarizer.extractionVersion,
            context: context,
            at: summarizedAt
        )
        // When the summarization engine produced a structured verdict, it is
        // the authoritative source of `MessageType`. When no verdict is
        // present (summary-only conservative fallbacks) we leave `messageType` alone.
        if updateMessageTypeFromVerdict, let verdict = normalizedVerdict {
            message.messageType = verdict.derivedMessageType(
                purpose: classification.purpose,
                isMailingList: isMailingList(message)
            )
            message.classifiedAt = summarizedAt
            analysis.interpretedAt = summarizedAt
        }
        updateReplyPreparationRequirement(
            on: message,
            context: context,
            interpretedAt: summarizedAt
        )
        try context.save()
        return true
    }

    @discardableResult
    public static func persistInterpretation(
        messageID: UUID,
        result: InterpretationResult,
        interpretedAt: Date,
        context: ModelContext,
        updateMessageTypeFromVerdict: Bool = true
    ) throws -> Bool {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            return false
        }

        let analysis = analysis(for: message, context: context)

        let classification = resolvedClassification(
            message: message,
            candidates: result.classificationCandidates,
            existing: nil,
            context: context
        )
        try persistClassification(
            classification,
            customCategoryKeys: result.customCategoryKeys,
            candidates: result.classificationCandidates,
            analysis: analysis
        )
        let deliveryFacts = deliveryFacts(for: message, context: context)
        let normalizedVerdict = TriageVerdictPolicy.normalizedForAttention(
            result.triageVerdict.normalizingActionability(isSentByUser: message.isSentByUser),
            purpose: classification.purpose,
            senderAddress: message.fromAddress,
            senderName: message.fromName,
            subject: message.subject,
            bodyText: bodyTextPrefix(for: message),
            deliveryFacts: deliveryFacts
        )
        analysis.triageVerdictJSON = try encodeVerdict(normalizedVerdict)
        try mergeTriageDeadlines(normalizedVerdict.deadlineCandidates, into: analysis)
        try replaceMeetingCandidate(result.meeting, in: analysis)
        try SemanticTagIntake.persist(
            candidates: result.semanticTagCandidates,
            for: message,
            extractionVersion: normalizedVerdict.extractionVersion,
            context: context,
            at: interpretedAt
        )
        analysis.interpretedAt = interpretedAt

        if updateMessageTypeFromVerdict {
            message.messageType = normalizedVerdict.derivedMessageType(
                purpose: classification.purpose,
                isMailingList: isMailingList(message)
            )
            message.classifiedAt = interpretedAt
        }

        updateReplyPreparationRequirement(
            on: message,
            context: context,
            interpretedAt: interpretedAt
        )
        try context.save()
        return true
    }

    @discardableResult
    public static func persistInterpretationMetadata(
        messageID: UUID,
        result: InterpretationMetadataResult,
        interpretedAt: Date,
        context: ModelContext,
        updateMessageType: Bool = true
    ) throws -> Bool {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            return false
        }

        let analysis = analysis(for: message, context: context)
        try applyInterpretationMetadata(
            result,
            to: message,
            analysis: analysis,
            context: context,
            interpretedAt: interpretedAt,
            clearTriageVerdict: true,
            updateMessageType: updateMessageType
        )
        try context.save()
        return true
    }

    private static func analysis(for message: Message, context: ModelContext) -> MessageAnalysis {
        if let existing = message.analysis {
            return existing
        }
        let created = MessageAnalysis(
            message: message,
            analysisVersion: summaryOnlyAnalysisVersion,
            dimensionsJSON: "{}"
        )
        context.insert(created)
        message.analysis = created
        return created
    }

    private static func applyInterpretationMetadata(
        _ result: InterpretationMetadataResult,
        to message: Message,
        analysis: MessageAnalysis,
        context: ModelContext,
        interpretedAt: Date,
        clearTriageVerdict: Bool,
        updateMessageType: Bool
    ) throws {
        let classification = resolvedClassification(
            message: message,
            candidates: result.classificationCandidates,
            existing: nil,
            context: context
        )
        try persistClassification(
            classification,
            customCategoryKeys: result.customCategoryKeys,
            candidates: result.classificationCandidates,
            analysis: analysis
        )
        if clearTriageVerdict {
            analysis.triageVerdictJSON = nil
            if message.placedAt == nil {
                message.replyPreparationRequiredAt = nil
                message.replyPreparationReadyAt = nil
            }
        }
        try SemanticTagIntake.persist(
            candidates: result.semanticTagCandidates,
            for: message,
            extractionVersion: MLXSummarizer.extractionVersion,
            context: context,
            at: interpretedAt
        )
        if clearTriageVerdict {
            try scrubTriageActionDimensions(in: analysis)
        }
        analysis.interpretedAt = interpretedAt
        if updateMessageType {
            message.messageType = nonAttentionMessageType(
                classification: classification,
                isMailingList: isMailingList(message)
            )
            message.classifiedAt = interpretedAt
        }
    }

    private static func updateReplyPreparationRequirement(
        on message: Message,
        context: ModelContext,
        interpretedAt: Date
    ) {
        guard message.liveDetectedAt != nil, message.isSentByUser == false else {
            return
        }
        if ReplySourcePreparationEligibility.isEligible(message, context: context) {
            message.replyPreparationRequiredAt = message.replyPreparationRequiredAt ?? interpretedAt
            message.replyPreparationReadyAt = nil
        } else if message.placedAt == nil {
            message.replyPreparationRequiredAt = nil
            message.replyPreparationReadyAt = nil
        }
        releaseSupersededPresentationHolds(around: message, context: context)
    }

    /// Once this email's interpretation makes a newer email the
    /// conversation's reply target, an earlier email still held for its own
    /// preparation will never get one. Release its hold in the same save, so
    /// it appears now instead of waiting out the hold for a preparation that
    /// is no longer made.
    private static func releaseSupersededPresentationHolds(
        around message: Message,
        context: ModelContext
    ) {
        guard message.thread != nil else { return }
        for member in message.composerConversationMembers
        where member.id != message.id
            && member.placedAt == nil
            && member.replyPreparationRequiredAt != nil {
            guard ReplySourcePreparationEligibility
                .conversationState(for: member, context: context)
                .isSuperseded else { continue }
            member.replyPreparationRequiredAt = nil
            member.replyPreparationReadyAt = nil
        }
    }

    private static func resolvedClassification(
        message: Message,
        candidates: ModelClassificationCandidates,
        existing: MailClassification?,
        context: ModelContext
    ) -> MailClassification {
        let deterministic = deterministicEvidence(for: message)
        let resolved = existing ?? MailClassificationResolver.resolve(
            model: candidates,
            deterministic: deterministic
        )
        guard resolved.purposeCandidates.contains(where: { $0.purpose == .correspondence }),
              listDeliveryExcludesCorrespondence(message, context: context) else {
            return resolved
        }

        // Correspondence is impossible for this post, so it must neither win
        // nor block another purpose on the margin rule. Remove it and resolve
        // the remainder. An empty or unresolved remainder stays uncertain and
        // the Front Page presents the factual Lists category.
        return MailClassificationResolver.resolve(
            model: ModelClassificationCandidates(
                purposes: resolved.purposeCandidates.filter { $0.purpose != .correspondence },
                classifierVersion: resolved.classifierVersion
            ),
            deterministic: deterministic
        )
    }

    /// List-ID is factual delivery metadata. A list message can only be
    /// Correspondence when an owned account address is explicitly present in
    /// To. The single definition shared by the classification writer and the
    /// interpretation context.
    public static func listDeliveryExcludesCorrespondence(
        _ message: Message,
        context: ModelContext
    ) -> Bool {
        guard isMailingList(message) else { return false }
        let ownedAddresses = ownedEmailAddresses(for: message, context: context)
        return hasOwnedRecipient(message, roles: [.to], ownedAddresses: ownedAddresses) == false
    }

    /// The List-ID handed to `MLXInterpreter` so it can re-classify a list post
    /// whose answer this writer would discard. Nil when structural evidence
    /// already qualifies a purpose: the writer resolves that purpose whatever
    /// the model says, so a review could only spend a generation and, through
    /// supersession, override it.
    public static func interpretationListExclusionID(
        for message: Message,
        context: ModelContext
    ) -> String? {
        guard listDeliveryExcludesCorrespondence(message, context: context),
              deterministicEvidence(for: message).ruleIDs.isEmpty else {
            return nil
        }
        return message.listId
    }

    private static func deterministicEvidence(
        for message: Message
    ) -> DeterministicMailEvidence {
        var ruleIDs: [String] = []
        let headers = structuredHeaders(for: message)
        let hasCalendarMIME = message.attachments.contains { attachment in
            attachment.mimeType.lowercased() == "text/calendar"
                || URL(fileURLWithPath: attachment.filename).pathExtension.lowercased() == "ics"
        } || headers["content-type"]?.lowercased().contains("text/calendar") == true
        if hasCalendarMIME {
            ruleIDs.append("purpose.calendar.scheduledEventAction")
        }

        return DeterministicMailEvidence(ruleIDs: ruleIDs)
    }

    private static func structuredHeaders(for message: Message) -> [String: String] {
        guard let rawPath = message.rawPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rawPath)) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), data.isEmpty == false,
              let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else {
            return [:]
        }

        var headers: [String: String] = [:]
        var currentName: String?
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for rawLine in lines {
            if rawLine.isEmpty { break }
            if rawLine.first?.isWhitespace == true, let currentName {
                headers[currentName, default: ""] += " "
                    + rawLine.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":") else {
                currentName = nil
                continue
            }
            let name = rawLine[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard name.isEmpty == false else { continue }
            headers[name] = rawLine[rawLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentName = name
        }
        return headers
    }

    private static func persistClassification(
        _ classification: MailClassification,
        customCategoryKeys: Set<String>,
        candidates: ModelClassificationCandidates,
        analysis: MessageAnalysis
    ) throws {
        analysis.mailClassificationJSON = try MailClassificationJSON.encode(classification)
        let preserved = Set(CustomCategoryKeysJSON.decode(analysis.customCategoryKeysJSON))
        analysis.customCategoryKeysJSON = try CustomCategoryKeysJSON.encode(
            preserved.union(customCategoryKeys)
        )
        logClassification(classification, candidates: candidates)
    }

    static func invalidateModelDerivedClassification(_ analysis: MessageAnalysis) {
        analysis.mailClassificationJSON = nil
    }

    private static func logClassification(
        _ classification: MailClassification,
        candidates: ModelClassificationCandidates
    ) {
        let sorted = candidates.purposes.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.purpose.rawValue < rhs.purpose.rawValue
        }
        let margin = sorted.count >= 2
            ? String(format: "%.4f", sorted[0].confidence - sorted[1].confidence)
            : "none"
        let deterministicPurpose = classification.evidence.first { evidence in
            evidence.isDeterministic
        }?.purpose.rawValue
        let leadingModelPurpose = sorted.first?.purpose.rawValue
        let disagreement = deterministicPurpose != nil
            && leadingModelPurpose != nil
            && deterministicPurpose != leadingModelPurpose
        classificationLogger.info(
            "classification status=\(classification.status.rawValue, privacy: .public) purpose=\(classification.purpose?.rawValue ?? "none", privacy: .public) topTwoMargin=\(margin, privacy: .public) classifierVersion=\(classification.classifierVersion, privacy: .public) resolverVersion=\(classification.resolverVersion, privacy: .public) deterministicModelDisagreement=\(disagreement, privacy: .public)"
        )
    }

    private static func deliveryFacts(
        for message: Message,
        context: ModelContext
    ) -> TriageVerdictPolicy.DeliveryFacts {
        let ownedAddresses = ownedEmailAddresses(for: message, context: context)
        let priority: TriageVerdictPolicy.DeliveryPriority
        if ownedAddresses.isEmpty == false {
            if hasOwnedRecipient(message, roles: [.to], ownedAddresses: ownedAddresses) {
                priority = .direct
            } else if hasOwnedRecipient(message, roles: [.cc], ownedAddresses: ownedAddresses) {
                priority = .copied
            } else if hasOwnedRecipient(message, roles: [.bcc], ownedAddresses: ownedAddresses) {
                priority = .low
            } else {
                priority = .unknown
            }
        } else {
            priority = .unknown
        }

        let trafficFacts = DeterministicMessageTrafficFacts(message: message)
        return TriageVerdictPolicy.DeliveryFacts(
            priority: trafficFacts.isMailingListOrBulk && priority == .unknown ? .low : priority,
            isMailingListOrBulk: trafficFacts.isMailingListOrBulk,
            isAutomated: trafficFacts.isAutomated
        )
    }

    private static func isMailingList(_ message: Message) -> Bool {
        if let listID = message.listId?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return listID.isEmpty == false
        }
        return false
    }

    private static func ownedEmailAddresses(
        for message: Message,
        context: ModelContext
    ) -> Set<String> {
        if let account = message.account {
            return account.ownedEmailAddresses
        }
        guard let accountID = message.accountID else {
            return []
        }
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first?.ownedEmailAddresses) ?? []
    }

    private static func hasOwnedRecipient(
        _ message: Message,
        roles: Set<ParticipantRole>,
        ownedAddresses: Set<String>
    ) -> Bool {
        message.participants.contains { link in
            guard roles.contains(link.role),
                  let address = link.participant?.emailAddress
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  !address.isEmpty else {
                return false
            }
            return ownedAddresses.contains(address)
        }
    }

    private static func nonAttentionMessageType(
        classification: MailClassification,
        isMailingList: Bool
    ) -> MessageType {
        if isMailingList {
            return .subscription
        }
        switch classification.purpose {
        case .receipt:
            return .receipt
        case .newsletter, .promotion:
            return .subscription
        default:
            return .report
        }
    }

    private static func encodeVerdict(_ verdict: TriageVerdict) throws -> String {
        let data = try verdictEncoder.encode(verdict)
        return String(decoding: data, as: UTF8.self)
    }

    private static func bodyTextPrefix(for message: Message, byteLimit: Int = 4_096) -> String? {
        guard let path = message.bodyTextPath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit), !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func scrubTriageActionDimensions(in analysis: MessageAnalysis) throws {
        guard let dimensions = decodeDimensions(analysis.dimensionsJSON),
              dimensions.deadlines.isEmpty == false
                || (dimensions.meetings ?? []).isEmpty == false else {
            return
        }
        let scrubbed = dimensions.scrubbingTriageActionState()
        let data = try dimensionsEncoder.encode(scrubbed)
        analysis.dimensionsJSON = String(decoding: data, as: UTF8.self)
    }

    private static func mergeTriageDeadlines(
        _ candidates: [DeadlineCandidate],
        into analysis: MessageAnalysis
    ) throws {
        guard candidates.isEmpty == false else { return }

        var dimensions = decodeDimensions(analysis.dimensionsJSON)
            ?? MessageDimensions(extractionVersion: "datafied-triage-deadlines-v1")
        var seen = Set(dimensions.deadlines.map(deadlineIdentity))
        for candidate in candidates {
            guard seen.insert(deadlineIdentity(candidate)).inserted else { continue }
            dimensions.deadlines.append(candidate)
        }
        let data = try dimensionsEncoder.encode(dimensions)
        analysis.dimensionsJSON = String(decoding: data, as: UTF8.self)
    }

    private static func replaceMeetingCandidate(
        _ candidate: MeetingCandidate?,
        in analysis: MessageAnalysis
    ) throws {
        guard candidate != nil || decodeDimensions(analysis.dimensionsJSON) != nil else {
            return
        }
        var dimensions = decodeDimensions(analysis.dimensionsJSON)
            ?? MessageDimensions(extractionVersion: "datafied-meetings-v1")
        dimensions.meetings = candidate.map { [$0] } ?? []
        let data = try dimensionsEncoder.encode(dimensions)
        analysis.dimensionsJSON = String(decoding: data, as: UTF8.self)
    }

    private static func deadlineIdentity(_ deadline: DeadlineCandidate) -> String {
        "\(deadline.dateString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(deadline.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func decodeDimensions(_ dimensionsJSON: String) -> MessageDimensions? {
        guard let data = dimensionsJSON.data(using: .utf8) else { return nil }
        return try? dimensionsDecoder.decode(MessageDimensions.self, from: data)
    }
}
