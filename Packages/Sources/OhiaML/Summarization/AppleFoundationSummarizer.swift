import Foundation
import FoundationModels
import OhiaCore

public final class AppleFoundationSummarizer: Summarizing, @unchecked Sendable {
    private static let generationOptions = GenerationOptions(temperature: 0.1, maximumResponseTokens: ApplePromptBudget.analysisResponseTokens)
    static let extractionVersion = "apple-foundation-v1"

    private struct PromptAttempt {
        let bodyCharacterLimit: Int
        let context: SummarizationContext?
        let name: String
    }

    @Generable
    struct GeneratedEmailAnalysis {
        @Guide(description: "Zero to three Purpose candidates. Each candidate uses a canonical Purpose raw value, finite 0.0-1.0 confidence, and stable rule IDs. Do not select a winner.")
        let purposeCandidates: [GeneratedPurposeCandidate]

        @Guide(description: "Zero to twelve stable Purpose rule identifiers repeated from the Purpose candidates. Never include body quotations.")
        let classificationEvidence: [String]

        @Guide(description: "Keys of the user-defined categories listed under 'User-defined categories' in the prompt whose definition clearly matches the anchor evidence; only emit candidates with confidence >= 0.75. Empty when none apply or none are listed.")
        let customCategories: [GeneratedCategoryCandidate]

        @Guide(description: SummarizationPromptBuilder.guide)
        let summary: String

        @Guide(description: "True iff the sender is asking the account owner (or the team the owner belongs to) for a direct reply or draftable response. False for short conversational acknowledgements such as sounds good / got it / thanks, self-service or portal tasks, optional CTAs, informational, mass-marketing, no-reply institutional, automated transactional, or third-party-directed content where the owner has no reply obligation.")
        let isActionable: Bool

        @Guide(description: "True iff the anchor carries time-sensitive or material information the recipient must absorb without replying — verification codes, security alerts, calendar changes, financial alerts on the owner's account, legal deadlines binding the owner, shipping milestones for the owner's order, booking confirmations the owner holds. False for marketing content and information that has already passed.")
        let requiresConfirmation: Bool

        @Guide(description: "0.0–1.0 estimate of how certain the triage classification is given the available evidence.")
        let confidence: Double

        @Guide(description: SummarizationPromptBuilder.actionSpecGuide)
        let action: GeneratedActionSpec?

        @Guide(description: SummarizationPromptBuilder.acknowledgementSpecGuide)
        let acknowledgement: GeneratedAcknowledgementSpec?
    }

    @Generable
    struct GeneratedPurposeCandidate {
        @Guide(description: "Canonical Purpose raw value.")
        let purpose: String

        @Guide(description: "Finite 0.0-1.0 candidate confidence.")
        let confidence: Double

        @Guide(description: "Stable Purpose rule identifiers supporting this candidate.")
        let ruleIDs: [String]
    }

    @Generable
    struct GeneratedCategoryCandidate {
        @Guide(description: "Canonical key from the active custom-category catalog.")
        let category: String

        @Guide(description: "0.0-1.0 confidence that this user-defined category independently applies; only emit candidates with confidence >= 0.75.")
        let confidence: Double
    }

    @Generable
    struct GeneratedActionSpec {
        @Guide(description: "One sentence stating the sender's requested direct response in concrete terms.")
        let summary: String

        @Guide(description: "Action kind. One of: reply, provideInformation, makeDecision, scheduleMeeting, review, signOff, other.")
        let kind: String

        @Guide(description: "Who the request is directed at. One of: user, userTeam, thirdParty, ambiguous.")
        let directedAt: String

        @Guide(description: "Surface text of the deadline if the anchor states one (e.g. 'by Friday', 'before the exec meeting'). Empty string when no deadline is stated.")
        let deadlineText: String

        @Guide(description: "Deadline kind when a deadline is present. One of: hard, soft, conditional. Empty string when no deadline is stated.")
        let deadlineKind: String

        @Guide(description: "Zero to five short questions the account owner must answer before a reply can be drafted. Each must be answerable by the owner alone.")
        let decisionInputs: [String]
    }

    @Generable
    struct GeneratedAcknowledgementSpec {
        @Guide(description: "One sentence stating the material signal.")
        let summary: String

        @Guide(description: "Signal kind. One of: verificationCode, securityAlert, calendarChange, financialAlert, legalDeadline, shippingMilestone, bookingConfirmation, accountChange, deliveryConfirmation, other.")
        let signalKind: String

        @Guide(description: "Surface text of the deadline if one is stated (e.g. 'expires in 10 minutes', 'by Friday'). Empty string when no deadline is stated.")
        let deadlineText: String

        @Guide(description: "Deadline kind when a deadline is present. One of: hard, soft, conditional. Empty string when no deadline is stated.")
        let deadlineKind: String

        @Guide(description: "Zero to five short bullets the recipient needs to internalize. Each must stand alone as a fact, not an instruction or a question.")
        let materialFacts: [String]
    }

    public init() {}

    public func summarize(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async throws -> SummarizationResult? {
        guard AppleIntelligenceAvailability.current().isAvailable else {
            throw SummarizationError.modelUnavailable
        }

        var lastContextWindowError: Error?
        let model = SystemLanguageModel.default
        let budget = try await ApplePromptBudget.current(
            instructions: SummarizationPromptBuilder.appleInstructions,
            schema: GeneratedEmailAnalysis.generationSchema,
            responseTokens: ApplePromptBudget.analysisResponseTokens,
            model: model
        )
        let attempts = Self.promptAttempts(context: context, maximumBodyCharacters: model.contextSize * 4)
        let normalizedBody = Self.normalizedBody(bodyText, contextSize: model.contextSize)
        for (index, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            let session = LanguageModelSession(instructions: SummarizationPromptBuilder.appleInstructions)
            func makePrompt(_ body: String) -> String {
                SummarizationPromptBuilder.applePrompt(
                    bodyText: body, senderName: senderName, subject: subject,
                    context: attempt.context, bodyCharacterLimit: attempt.bodyCharacterLimit
                )
            }
            guard let fittedBody = try await ApplePromptBudget.fitBody(
                normalizedBody, maximumCharacters: attempt.bodyCharacterLimit,
                fits: { try await budget.fits(prompt: makePrompt($0), model: model) }
            ) else { continue }
            let prompt = makePrompt(fittedBody)

            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedEmailAnalysis.self,
                    options: Self.generationOptions
                )
                let result = try Self.makeResult(
                    response.content,
                    customCategories: attempt.context?.customCategories ?? []
                )
                return SummaryIdentityValidator.validatedSummary(
                    result,
                    bodyText: bodyText,
                    senderName: senderName,
                    subject: subject,
                    context: attempt.context
                )
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal:
                    throw SummarizationError.guardrailViolation
                case .exceededContextWindowSize(_):
                    lastContextWindowError = error
                    if index < attempts.count - 1 {
                        print("[Ohia] Apple summary prompt exceeded context window; retrying with \(attempts[index + 1].name) prompt")
                        continue
                    }
                    throw SummarizationError.underlying(error)
                default:
                    throw SummarizationError.underlying(error)
                }
            } catch let error as SummarizationError {
                throw error
            } catch {
#if compiler(>=6.4)
                if #available(macOS 27.0, *), let modelError = error as? LanguageModelError {
                    switch modelError {
                    case .contextSizeExceeded:
                        lastContextWindowError = error
                        if index < attempts.count - 1 { continue }
                    case .guardrailViolation, .refusal:
                        throw SummarizationError.guardrailViolation
                    default:
                        break
                    }
                }
#endif
                try Task.checkCancellation()
                throw SummarizationError.underlying(error)
            }
        }

        if let lastContextWindowError {
            throw SummarizationError.underlying(lastContextWindowError)
        }
        return nil
    }

    static func makeResult(
        _ output: GeneratedEmailAnalysis,
        customCategories: [CustomMailCategoryDescriptor] = []
    ) throws -> SummarizationResult {
        guard let summary = MLXSummarizer.postProcess(output.summary) else {
            throw SummarizationError.empty
        }
        let customCategoryKeys = Set(
            output.customCategories.compactMap { candidate -> String? in
                guard clamp(candidate.confidence, lower: 0.0, upper: 1.0)
                        >= CustomCategoryAssignmentPolicy.confidenceThreshold else { return nil }
                return CustomMailCategoryNormalization.normalizedKey(
                    candidate.category,
                    catalog: customCategories
                )
            }
        )
        let fields = [
            "purposeCandidates": output.purposeCandidates.map {
                [$0.purpose, String($0.confidence), $0.ruleIDs.joined(separator: ",")]
                    .joined(separator: " | ")
            }.joined(separator: TriageVerdictParsing.arraySeparator),
            "classificationEvidence": output.classificationEvidence.joined(separator: ","),
        ]
        guard let candidates = MLXSummarizer.parseModelClassificationCandidates(fields: fields) else {
            throw SummarizationError.invalidCategory("purpose classification output")
        }
        return SummarizationResult(
            summary: summary,
            classificationCandidates: candidates,
            triageVerdict: Self.makeTriageVerdict(output),
            customCategoryKeys: customCategoryKeys
        )
    }

    static func normalizedBody(_ body: String, contextSize: Int) -> String {
        SummarizationPromptBuilder.appleBodyExcerpt(body, limit: max(0, contextSize) * 4)
    }

    private static func promptAttempts(context: SummarizationContext?, maximumBodyCharacters: Int) -> [PromptAttempt] {
        [
            PromptAttempt(
                bodyCharacterLimit: maximumBodyCharacters,
                context: context,
                name: "primary"
            ),
            PromptAttempt(
                bodyCharacterLimit: maximumBodyCharacters / 2,
                context: context?.compactedForAppleContextWindowRetry(),
                name: "compact"
            ),
            PromptAttempt(
                bodyCharacterLimit: maximumBodyCharacters / 4,
                context: context?.metadataOnlyForAppleContextWindowRetry(),
                name: "minimal"
            )
        ]
    }

    static func makeTriageVerdict(_ output: GeneratedEmailAnalysis) -> TriageVerdict {
        TriageVerdict(
            isActionable: output.isActionable,
            requiresConfirmation: output.requiresConfirmation,
            confidence: clamp(output.confidence, lower: 0.0, upper: 1.0),
            action: output.isActionable ? output.action.flatMap(makeActionSpec) : nil,
            acknowledgement: output.requiresConfirmation ? output.acknowledgement.flatMap(makeAcknowledgementSpec) : nil,
            extractionVersion: extractionVersion
        )
    }

    static func makeActionSpec(_ generated: GeneratedActionSpec) -> ActionSpec? {
        ActionSpec.make(
            summary: generated.summary,
            kind: generated.kind,
            directedAt: generated.directedAt,
            deadlineText: generated.deadlineText,
            deadlineKind: generated.deadlineKind,
            decisionInputs: generated.decisionInputs
        )
    }

    static func makeAcknowledgementSpec(_ generated: GeneratedAcknowledgementSpec) -> AcknowledgementSpec? {
        AcknowledgementSpec.make(
            summary: generated.summary,
            signalKind: generated.signalKind,
            deadlineText: generated.deadlineText,
            deadlineKind: generated.deadlineKind,
            materialFacts: generated.materialFacts
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
