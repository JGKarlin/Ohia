import Foundation
import SwiftData
import OhiaCore

/// Plans and grounds the complete reply interview before a Composer-owned
/// Draft exists. Invalid model output is a terminal preparation failure,
/// distinct from a valid reply with no unresolved questions.
public final class ReplyPreparationInterviewPlanner: ReplyInterviewPlanning, Sendable {
    private let planner: ComposerInterviewPlanner
    private let groundingResolver: (any ReplyQuestionGrounding)?
    private let contextPacker: ComposerContextPacker

    public init(
        planner: ComposerInterviewPlanner,
        groundingResolver: (any ReplyQuestionGrounding)? = nil,
        contextPacker: ComposerContextPacker = ComposerContextPacker(tokenCounter: nil)
    ) {
        self.planner = planner
        self.groundingResolver = groundingResolver
        self.contextPacker = contextPacker
    }

    @MainActor
    public func plan(
        for message: Message,
        sourcesJSON: String,
        inputFingerprint: String,
        context: ModelContext
    ) async throws -> ComposerInterviewState {
        let sources = ComposerSourceCoding.decode(sourcesJSON)
        let bodyText = loadBody(message)
        let contextPack = try QuestionGroundingContextPacking.reply(
            message: message,
            bodyText: bodyText,
            sources: sources,
            packer: contextPacker
        )
        let account = message.account ?? fetchAccount(id: message.accountID, context: context)
        let accountID = message.accountID ?? account?.id
        let identity = IdentityResolver.resolveReplyIdentity(message: message)
        let languageIdentifier = DraftLanguage.familyID(for: message.languageDetected) ?? "und"
        let userName = DraftGenerationOrchestrator.interviewUserName(
            account: account,
            draftIdentityID: identity?.id
        )
        let counterpartName = message.fromName ?? message.fromAddress
        let evidenceFingerprint = QuestionGroundingResolver.evidenceFingerprint(
            contextPack: contextPack,
            framing: .reply,
            subject: message.subject,
            accountID: accountID,
            languageIdentifier: languageIdentifier
        )
        let recipients = ReplyRecipientPolicy.defaultRecipients(for: message, mode: .reply)
        let plannerResult = try planner.planReading(
            ComposerInterviewPlannerInput(
                contextPack: contextPack,
                subject: message.subject,
                userName: userName,
                counterpartName: counterpartName,
                framing: .reply,
                questionLanguage: ComposerQuestionLanguage.current(),
                recipients: recipients.to + recipients.cc + recipients.bcc,
                sendingIdentity: identity?.address,
                inputFingerprint: inputFingerprint,
                evidenceFingerprint: evidenceFingerprint,
                generationEpoch: 0
            )
        )

        guard plannerResult.plan.planningOutcome != .invalid else {
            throw ComposerContentError.invalidBrief(
                "Reply interview could not be validated: \(plannerResult.metrics.validationFailureReason ?? "invalid protocol")")
        }
        let state = ComposerInterviewState(plan: plannerResult.plan)

        // Source resolution is part of the initial preparation. Remaining facts
        // need user input; re-running a grounding model would repeat that work.
        if state.replyContext != nil {
            return ComposerInterviewGroundingNormalizer.normalize(state: state, resolved: [])
        }

        let evidenceNodes = state.baseProtocol.questionNodes.filter {
            QuestionGroundingResolver.effectiveAuthority(for: $0) == .evidenceFact
        }
        guard !evidenceNodes.isEmpty, let groundingResolver else {
            return ComposerInterviewGroundingNormalizer.normalize(state: state, resolved: [])
        }

        let groundings = try await groundingResolver.ground(
            questions: evidenceNodes,
            contextPack: contextPack,
            framing: .reply,
            subject: message.subject,
            accountID: accountID,
            languageIdentifier: languageIdentifier,
            cachedGroundings: []
        )
        return ComposerInterviewGroundingNormalizer.normalize(
            state: state,
            resolved: groundings
        )
    }

    @MainActor
    private func fetchAccount(id: UUID?, context: ModelContext) -> Account? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func loadBody(_ message: Message) -> String {
        guard let path = message.bodyTextPath else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
