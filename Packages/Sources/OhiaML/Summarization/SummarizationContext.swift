import Foundation
import OhiaCore
import OSLog

private let summarizationGroundingLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "summarization-grounding"
)

public struct SummarizationUserIdentity: Sendable, Equatable {
    public let displayName: String
    public let primaryEmailAddress: String
    public let aliasEmailAddresses: [String]

    public init(
        displayName: String,
        primaryEmailAddress: String,
        aliasEmailAddresses: [String] = []
    ) {
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = primaryEmailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.primaryEmailAddress = primary

        var seen = Set<String>()
        self.aliasEmailAddresses = aliasEmailAddresses.compactMap { address in
            let normalized = address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty,
                  normalized != primary,
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    public var isUseful: Bool {
        !displayName.isEmpty || !primaryEmailAddress.isEmpty || !aliasEmailAddresses.isEmpty
    }
}

public struct SummarizationContext: Sendable, Equatable {
    public enum AnchorDirection: String, Sendable, Equatable {
        case incoming
        case outgoing

        var evidenceCode: String {
            switch self {
            case .incoming: return "received_by_account_owner"
            case .outgoing: return "sent_by_account_owner"
            }
        }

        var promptDescription: String {
            switch self {
            case .incoming:
                return "received by the account owner; the account owner did not write it, and the From field names who wrote it."
            case .outgoing:
                return "sent by the account owner; the account owner wrote it, and the From field is the account owner or one of their aliases."
            }
        }

        var evidenceDescription: String {
            switch self {
            case .incoming:
                return "received by the account owner"
            case .outgoing:
                return "sent by the account owner"
            }
        }
    }

    public struct Recipient: Sendable, Equatable {
        public let displayName: String?
        public let address: String

        public init(displayName: String? = nil, address: String) {
            let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayName = name?.isEmpty == false ? name : nil
            self.address = address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        var isUseful: Bool {
            displayName?.isEmpty == false || !address.isEmpty
        }
    }

    public struct AnchorRecipients: Sendable, Equatable {
        public let to: [Recipient]
        public let cc: [Recipient]

        public init(to: [Recipient] = [], cc: [Recipient] = []) {
            self.to = Self.deduplicated(to)
            self.cc = Self.deduplicated(cc)
        }

        public var isUseful: Bool {
            !to.isEmpty || !cc.isEmpty
        }

        private static func deduplicated(_ recipients: [Recipient]) -> [Recipient] {
            var seen = Set<String>()
            return recipients.compactMap { recipient in
                guard recipient.isUseful else { return nil }
                let key = recipient.address.isEmpty
                    ? (recipient.displayName ?? "").lowercased()
                    : recipient.address
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return recipient
            }
        }
    }

    public struct VectorShape: Sendable, Equatable {
        public let contextCount: Int
        public let attachmentCount: Int
        public let entityCount: Int
        public let neighborCount: Int

        public init(
            contextCount: Int,
            attachmentCount: Int,
            entityCount: Int,
            neighborCount: Int
        ) {
            self.contextCount = max(0, contextCount)
            self.attachmentCount = max(0, attachmentCount)
            self.entityCount = max(0, entityCount)
            self.neighborCount = max(0, neighborCount)
        }

        public var totalCount: Int {
            contextCount + attachmentCount + entityCount
        }
    }

    public struct ConnectedItem: Sendable, Equatable {
        public let senderName: String
        public let subject: String
        public let excerpt: String
        public let similarity: Float
        public let direction: AnchorDirection?
        public let recipients: AnchorRecipients?

        public init(
            senderName: String,
            subject: String,
            excerpt: String,
            similarity: Float,
            direction: AnchorDirection? = nil,
            recipients: AnchorRecipients? = nil
        ) {
            self.senderName = senderName
            self.subject = subject
            self.excerpt = excerpt
            self.similarity = similarity
            self.direction = direction
            self.recipients = recipients?.isUseful == true ? recipients : nil
        }
    }

    public struct SatelliteEvidence: Sendable, Equatable {
        public let kind: String
        public let text: String

        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct VisualAttachmentSummary: Sendable, Equatable {
        public let filename: String
        public let summary: String

        public init(filename: String, summary: String) {
            self.filename = filename
            self.summary = summary
        }
    }

    public struct TextAttachmentEvidence: Sendable, Equatable {
        public let filename: String
        public let text: String

        public init(filename: String, text: String) {
            self.filename = filename
            self.text = text
        }
    }

    public let vectorShape: VectorShape?
    public let analysisSignals: [String]
    public let connectedItems: [ConnectedItem]
    public let satelliteEvidence: [SatelliteEvidence]
    public let messageEvidenceDigest: String?
    public let visualAttachmentSummaries: [VisualAttachmentSummary]
    public let textAttachmentEvidence: [TextAttachmentEvidence]
    public let userIdentity: SummarizationUserIdentity?
    public let anchorDirection: AnchorDirection?
    public let anchorRecipients: AnchorRecipients?
    /// List-ID of a mailing-list post whose To line names no address the
    /// account owns. Ingestion never resolves such a post to `correspondence`
    /// (`MessageSummaryWriter.listDeliveryExcludesCorrespondence`). The first
    /// interpretation pass ignores this field on purpose; when its answer would
    /// be discarded, `MLXInterpreter` re-classifies once with correspondence
    /// withdrawn (`InterpretationSecondPassReason.listCorrespondenceExcluded`).
    public let correspondenceExcludingListID: String?
    /// Applicable user-wide dyads plus account-scoped preferences for the
    /// target summary language. Present only when source anchor evidence is
    /// confidently in a different language from the configured output.
    public let translationContext: TranslationContext?
    /// One occurrence map prepared across the subject, authored body, message
    /// evidence digest, and extracted text attachments. Summaries may omit a
    /// mapped fact, but every marker they retain is restored before persistence.
    public let translationProtection: PreparedTranslationGlossaryProtection?
    /// The target language resolved for the same request as
    /// `translationContext`, keeping glossary selection and prompt generation
    /// on one stable language even if settings change while work is in flight.
    public let summaryTargetLanguage: SummarizationTargetLanguage?
    /// Active user-defined categories (key, display name, LLM-written
    /// definition). When non-empty, the MLX prompt builders append the
    /// definitions alongside the built-in classification guide and request a
    /// `CustomCategories:` output line; the parsers map the returned keys
    /// back through this catalog. Only descriptors with a definition steer
    /// the model — assemblers pass `CustomMailCategoryCatalog.activeDescriptors`.
    public let customCategories: [CustomMailCategoryDescriptor]

    public init(
        vectorShape: VectorShape? = nil,
        analysisSignals: [String] = [],
        connectedItems: [ConnectedItem] = [],
        satelliteEvidence: [SatelliteEvidence] = [],
        messageEvidenceDigest: String? = nil,
        visualAttachmentSummaries: [VisualAttachmentSummary] = [],
        textAttachmentEvidence: [TextAttachmentEvidence] = [],
        userIdentity: SummarizationUserIdentity? = nil,
        anchorDirection: AnchorDirection? = nil,
        anchorRecipients: AnchorRecipients? = nil,
        correspondenceExcludingListID: String? = nil,
        translationContext: TranslationContext? = nil,
        translationProtection: PreparedTranslationGlossaryProtection? = nil,
        summaryTargetLanguage: SummarizationTargetLanguage? = nil,
        customCategories: [CustomMailCategoryDescriptor] = []
    ) {
        self.vectorShape = vectorShape
        self.analysisSignals = analysisSignals
        self.connectedItems = connectedItems
        self.satelliteEvidence = satelliteEvidence
        self.messageEvidenceDigest = Self.clean(messageEvidenceDigest, limit: 2_400)
        self.visualAttachmentSummaries = visualAttachmentSummaries
        self.textAttachmentEvidence = textAttachmentEvidence.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.userIdentity = userIdentity?.isUseful == true ? userIdentity : nil
        self.anchorDirection = anchorDirection
        self.anchorRecipients = anchorRecipients?.isUseful == true ? anchorRecipients : nil
        self.correspondenceExcludingListID = Self.clean(correspondenceExcludingListID, limit: 160)
        self.translationContext = translationContext?.isEmpty == false ? translationContext : nil
        self.translationProtection = translationProtection?.mappings.isEmpty == false
            ? translationProtection
            : nil
        self.summaryTargetLanguage = summaryTargetLanguage
        self.customCategories = customCategories.filter { descriptor in
            descriptor.isActive
                && descriptor.definition?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
        }
    }

    public var isEmpty: Bool {
        !hasLocalSemanticEvidence
            && userIdentity == nil
            && anchorDirection == nil
            && anchorRecipients == nil
            && correspondenceExcludingListID == nil
            && translationContext == nil
            && translationProtection == nil
            && summaryTargetLanguage == nil
            && customCategories.isEmpty
    }

    public var hasLocalSemanticEvidence: Bool {
        vectorShape != nil
            || !analysisSignals.isEmpty
            || !connectedItems.isEmpty
            || !satelliteEvidence.isEmpty
            || messageEvidenceDigest != nil
            || !visualAttachmentSummaries.isEmpty
            || !textAttachmentEvidence.isEmpty
    }

    public var hasSummarizableAnchorEvidence: Bool {
        messageEvidenceDigest != nil
            || visualAttachmentSummaries.contains { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || textAttachmentEvidence.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var hasTextAttachmentEvidence: Bool {
        textAttachmentEvidence.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func removingVisualAttachmentSummaries() -> SummarizationContext? {
        let context = SummarizationContext(
            vectorShape: vectorShape,
            analysisSignals: analysisSignals,
            connectedItems: connectedItems,
            satelliteEvidence: satelliteEvidence,
            messageEvidenceDigest: messageEvidenceDigest,
            textAttachmentEvidence: textAttachmentEvidence,
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: anchorRecipients,
            correspondenceExcludingListID: correspondenceExcludingListID,
            translationContext: translationContext,
            translationProtection: translationProtection,
            summaryTargetLanguage: summaryTargetLanguage,
            customCategories: customCategories
        )
        return context.isEmpty ? nil : context
    }

    public func bindingSummaryTargetLanguage(
        _ targetLanguage: SummarizationTargetLanguage
    ) -> SummarizationContext {
        SummarizationContext(
            vectorShape: vectorShape,
            analysisSignals: analysisSignals,
            connectedItems: connectedItems,
            satelliteEvidence: satelliteEvidence,
            messageEvidenceDigest: messageEvidenceDigest,
            visualAttachmentSummaries: visualAttachmentSummaries,
            textAttachmentEvidence: textAttachmentEvidence,
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: anchorRecipients,
            correspondenceExcludingListID: correspondenceExcludingListID,
            translationContext: translationContext,
            translationProtection: translationProtection,
            summaryTargetLanguage: targetLanguage,
            customCategories: customCategories
        )
    }

    public func compactedForAppleContextWindowRetry() -> SummarizationContext? {
        let context = SummarizationContext(
            messageEvidenceDigest: messageEvidenceDigest,
            visualAttachmentSummaries: Array(visualAttachmentSummaries.prefix(1)),
            textAttachmentEvidence: textAttachmentEvidence.prefix(1).map {
                TextAttachmentEvidence(
                    filename: $0.filename,
                    text: TranslationGlossaryProtection.markerSafePrefix($0.text, limit: 600)
                )
            },
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: anchorRecipients,
            correspondenceExcludingListID: correspondenceExcludingListID,
            translationContext: translationContext,
            translationProtection: translationProtection,
            summaryTargetLanguage: summaryTargetLanguage,
            customCategories: customCategories
        )
        return context.isEmpty ? nil : context
    }

    public func metadataOnlyForAppleContextWindowRetry() -> SummarizationContext? {
        let context = SummarizationContext(
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: anchorRecipients,
            correspondenceExcludingListID: correspondenceExcludingListID,
            translationContext: translationContext,
            translationProtection: translationProtection,
            summaryTargetLanguage: summaryTargetLanguage,
            customCategories: customCategories
        )
        return context.isEmpty ? nil : context
    }

    public func withTranslationGrounding(
        _ translationContext: TranslationContext?,
        protection: PreparedTranslationGlossaryProtection,
        messageEvidenceDigest: String?,
        textAttachmentEvidence: [TextAttachmentEvidence],
        summaryTargetLanguage: SummarizationTargetLanguage
    ) -> SummarizationContext? {
        let context = SummarizationContext(
            vectorShape: vectorShape,
            analysisSignals: analysisSignals,
            connectedItems: connectedItems,
            satelliteEvidence: satelliteEvidence,
            messageEvidenceDigest: messageEvidenceDigest,
            visualAttachmentSummaries: visualAttachmentSummaries,
            textAttachmentEvidence: textAttachmentEvidence,
            userIdentity: userIdentity,
            anchorDirection: anchorDirection,
            anchorRecipients: anchorRecipients,
            correspondenceExcludingListID: correspondenceExcludingListID,
            translationContext: translationContext,
            translationProtection: protection,
            summaryTargetLanguage: summaryTargetLanguage,
            customCategories: customCategories
        )
        return context.isEmpty ? nil : context
    }

    private static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > limit else { return cleaned }
        return TranslationGlossaryProtection.markerSafePrefix(cleaned, limit: limit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SummarizationTranslationGrounding {
    public struct PreparedInputs: Sendable, Equatable {
        public let bodyText: String
        public let senderName: String
        public let subject: String
        public let knownInterpretation: SummaryKnownInterpretation?
        public let context: SummarizationContext?
        public let summaryInputFingerprint: String

        fileprivate init(
            bodyText: String,
            senderName: String,
            subject: String,
            knownInterpretation: SummaryKnownInterpretation?,
            context: SummarizationContext?,
            summaryInputFingerprint: String
        ) {
            self.bodyText = bodyText
            self.senderName = senderName
            self.subject = subject
            self.knownInterpretation = knownInterpretation
            self.context = context
            self.summaryInputFingerprint = summaryInputFingerprint
        }

        /// Whether a stored summary can still be shown to a reader of the
        /// bound target language. Source-language residue left by an earlier
        /// generation makes it stale.
        public func isDisplayable(storedSummary: String?) -> Bool {
            guard let storedSummary, let target = context?.summaryTargetLanguage else { return true }
            return DisplayLanguageGuard.needsResolution([storedSummary], targetLanguage: target) == false
        }

        /// A summary after the display-language pass.
        public enum FinalizedSummary: Sendable, Equatable {
            /// Fit to show and persist in the bound target language.
            case displayable(SummarizationResult)
            /// Withheld: a source-language passage could not be translated,
            /// or nothing readable remained. `transient` when the translation
            /// pass never reached an answer (no loaded model, a cancelled
            /// generation), so an attempt soon may succeed.
            case withheld(transient: Bool)

            public var result: SummarizationResult? {
                guard case .displayable(let result) = self else { return nil }
                return result
            }
        }

        /// Renders any source-language residue in the visible summary into the
        /// bound target language. A summary that cannot be shown in that
        /// language is withheld: neither shown nor persisted, and generated
        /// again by a later request. Call after `restoringSummaryResult`.
        public func finalizingDisplayLanguage(
            of result: SummarizationResult,
            using guardrail: DisplayLanguageGuard?,
            messageID: UUID?,
            accountID: UUID?,
            sourceLanguageHint: String? = nil
        ) async -> FinalizedSummary {
            guard let guardrail,
                  let target = context?.summaryTargetLanguage,
                  DisplayLanguageGuard.needsResolution([result.summary], targetLanguage: target) else {
                return .displayable(result)
            }
            let resolution = await guardrail.resolve(
                [result.summary],
                targetLanguage: target,
                source: DisplayLanguageGuard.Source(
                    languageHint: sourceLanguageHint,
                    context: displaySourceContext,
                    messageID: messageID,
                    accountID: accountID
                )
            )
            guard resolution.isComplete else { return .withheld(transient: resolution.isTransient) }
            guard let summary = resolution.fields.first.flatMap(SummaryTextSanitizer.cleaned) else {
                return .withheld(transient: false)
            }
            return .displayable(result.replacingSummary(summary))
        }

        /// The unavailable reason for a summary `finalizingDisplayLanguage`
        /// withheld, naming the reading language.
        public var untranslatedSummaryReason: String {
            let language = context?.summaryTargetLanguage?.displayName
                ?? SummarizationTargetLanguage.ohiaPreferred().displayName
            return "Summary unavailable: it could not be written in \(language)."
        }

        /// Subject and leading body with glossary markers restored to their
        /// renderings, so the residue pass reads the source's meaning.
        var displaySourceContext: String {
            let raw = "\(subject)\n\(TranslationGlossaryProtection.markerSafePrefix(bodyText, limit: 1_200))"
            guard let protection = context?.translationProtection else { return raw }
            return (try? protection.restore(in: raw, requireAll: false))
                ?? raw.replacingOccurrences(of: #"\[\[OHIA_GLOSSARY_[A-Za-z0-9_]+\]\]"#, with: "", options: .regularExpression)
        }

        /// Summary omission is legitimate, but any exact marker that survives
        /// generation is restored before the result can be cached or persisted.
        public func restoringSummaryResult(
            _ result: SummarizationResult
        ) throws -> SummarizationResult {
            guard let protection = context?.translationProtection else { return result }
            return result.replacingGeneratedText(
                summary: try protection.restore(in: result.summary, requireAll: false),
                triageVerdict: try restore(result.triageVerdict, using: protection),
                semanticTagCandidates: try restore(
                    result.semanticTagCandidates,
                    using: protection
                )
            )
        }

        private func restore(
            _ candidates: [SemanticTagCandidate],
            using protection: PreparedTranslationGlossaryProtection
        ) throws -> [SemanticTagCandidate] {
            try candidates.map { candidate in
                SemanticTagCandidate(
                    preferredLabel: try protection.restore(
                        in: candidate.preferredLabel,
                        requireAll: false
                    ),
                    sourceForms: try candidate.sourceForms.map {
                        try protection.restore(in: $0, requireAll: false)
                    },
                    qualifiers: try candidate.qualifiers.map {
                        SemanticTagQualifier(
                            kind: $0.kind,
                            value: try protection.restore(in: $0.value, requireAll: false)
                        )
                    },
                    centrality: candidate.centrality,
                    roles: candidate.roles,
                    confidence: candidate.confidence
                )
            }
        }

        private func restore(
            _ verdict: TriageVerdict?,
            using protection: PreparedTranslationGlossaryProtection
        ) throws -> TriageVerdict? {
            guard let verdict else { return nil }
            let action = try verdict.action.map { action in
                ActionSpec(
                    summary: try protection.restore(in: action.summary, requireAll: false),
                    kind: action.kind,
                    directedAt: action.directedAt,
                    deadline: try restore(action.deadline, using: protection),
                    decisionInputs: try action.decisionInputs.map {
                        try protection.restore(in: $0, requireAll: false)
                    },
                    evidenceSpans: try action.evidenceSpans.map {
                        try restore($0, using: protection)
                    }
                )
            }
            let acknowledgement = try verdict.acknowledgement.map { acknowledgement in
                AcknowledgementSpec(
                    summary: try protection.restore(in: acknowledgement.summary, requireAll: false),
                    signalKind: acknowledgement.signalKind,
                    deadline: try restore(acknowledgement.deadline, using: protection),
                    materialFacts: try acknowledgement.materialFacts.map {
                        try protection.restore(in: $0, requireAll: false)
                    },
                    evidenceSpans: try acknowledgement.evidenceSpans.map {
                        try restore($0, using: protection)
                    }
                )
            }
            return TriageVerdict(
                isActionable: verdict.isActionable,
                requiresConfirmation: verdict.requiresConfirmation,
                confidence: verdict.confidence,
                action: action,
                acknowledgement: acknowledgement,
                extractionVersion: verdict.extractionVersion
            )
        }

        private func restore(
            _ deadline: DeadlineCandidate?,
            using protection: PreparedTranslationGlossaryProtection
        ) throws -> DeadlineCandidate? {
            guard let deadline else { return nil }
            return DeadlineCandidate(
                dateString: try protection.restore(in: deadline.dateString, requireAll: false),
                type: deadline.type,
                confidence: deadline.confidence,
                evidenceSpan: try restoreOptionalSpan(deadline.evidenceSpan, using: protection)
            )
        }

        private func restoreOptionalSpan(
            _ span: EvidenceSpan?,
            using protection: PreparedTranslationGlossaryProtection
        ) throws -> EvidenceSpan? {
            guard let span else { return nil }
            return try restore(span, using: protection)
        }

        private func restore(
            _ span: EvidenceSpan,
            using protection: PreparedTranslationGlossaryProtection
        ) throws -> EvidenceSpan {
            EvidenceSpan(
                start: span.start,
                end: span.end,
                text: try protection.restore(in: span.text, requireAll: false)
            )
        }


    }

    public static func applying(
        to context: SummarizationContext?,
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation?,
        sourceLanguageCode: String? = nil,
        accountID: UUID?,
        targetLanguage: SummarizationTargetLanguage,
        provider: (any TranslationContextProviding)?
    ) -> PreparedInputs {
        let fingerprint = summaryInputFingerprint(
            targetLanguage: targetLanguage,
            translationContext: context?.translationContext
        )
        let targetBoundContext = context?.bindingSummaryTargetLanguage(targetLanguage)
            ?? SummarizationContext(summaryTargetLanguage: targetLanguage)
        let ungrounded = PreparedInputs(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            context: targetBoundContext,
            summaryInputFingerprint: fingerprint
        )
        guard let provider else {
            diagnostic(outcome: "no-provider", occurrenceCount: 0)
            return ungrounded
        }

        let fields = sourceFields(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            context: context
        )
        let sourceText = fields.map(\.text).joined(separator: "\n")
        let detected = EmailLanguageDetector.evaluate(
            bodyText: sourceText,
            targetLanguageIdentifier: targetLanguage.identifier
        )
        guard let targetFamily = LocalModelLanguageSupport.canonicalLanguageID(
            for: targetLanguage.identifier
        ) else {
            diagnostic(outcome: "unsupported-target", occurrenceCount: 0)
            return ungrounded
        }
        let sourceLanguage: String?
        if let sourceLanguageCode {
            guard let sourceFamily = LocalModelLanguageSupport.canonicalLanguageID(
                for: sourceLanguageCode
            ), sourceFamily != targetFamily else {
                diagnostic(outcome: "same-language", occurrenceCount: 0)
                return ungrounded
            }
            sourceLanguage = sourceLanguageCode
        } else if let detectedLanguage = detected.detectedLanguageCode {
            guard let sourceFamily = LocalModelLanguageSupport.canonicalLanguageID(
                for: detectedLanguage
            ), sourceFamily != targetFamily else { return ungrounded }
            sourceLanguage = detectedLanguage
        } else {
            // The provider may conservatively infer one source language from
            // applicable canonical dyads and the known target. Ambiguity stays
            // ungrounded inside the provider.
            sourceLanguage = nil
        }
        guard let translationContext = provider.translationContext(
            forAccount: accountID,
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguage,
            targetLanguage: targetLanguage
        ), translationContext.isEmpty == false else {
            diagnostic(outcome: "no-context", occurrenceCount: 0)
            return ungrounded
        }

        let prepared = protecting(
            fields.map(\.text),
            exactGlossary: translationContext.exactGlossary
        )
        guard prepared.segments.count == fields.count,
              Set(fields.map(\.slot)).count == fields.count else {
            diagnostic(outcome: "cardinality-mismatch", occurrenceCount: 0)
            return ungrounded
        }
        let values = Dictionary(uniqueKeysWithValues: zip(fields.map(\.slot), prepared.segments))
        guard values.count == fields.count else {
            diagnostic(outcome: "duplicate-slot", occurrenceCount: 0)
            return ungrounded
        }
        let groundedContext = rebuiltContext(
            context,
            values: values,
            translationContext: translationContext,
            protection: prepared.protection,
            targetLanguage: targetLanguage
        )
        let groundedKnownInterpretation = rebuiltKnownInterpretation(knownInterpretation, values: values)
        let occurrenceCount = exactOccurrenceCount(in: fields.map(\.text), glossary: translationContext.exactGlossary)
        diagnostic(outcome: occurrenceCount == 0 ? "no-exact-occurrence" : "grounded", occurrenceCount: occurrenceCount)
        return PreparedInputs(
            bodyText: values[.body] ?? bodyText,
            senderName: values[.senderName] ?? senderName,
            subject: values[.subject] ?? subject,
            knownInterpretation: groundedKnownInterpretation,
            context: groundedContext,
            summaryInputFingerprint: summaryInputFingerprint(
                targetLanguage: targetLanguage,
                translationContext: translationContext
            )
        )
    }

    private enum RecipientRole: Hashable { case to, cc }
    private enum SourceSlot: Hashable {
        case senderName, subject, body, userDisplayName
        case anchorRecipient(role: RecipientRole, index: Int)
        case analysisSignal(Int)
        case connectedSender(Int), connectedSubject(Int), connectedExcerpt(Int)
        case connectedRecipient(item: Int, role: RecipientRole, index: Int)
        case satelliteText(Int), evidenceDigest
        case visualSummary(Int), textAttachment(Int)
        case actionSummary, actionDeadline, decisionInput(Int)
        case acknowledgementSummary, acknowledgementDeadline, materialFact(Int)
    }
    private struct SourceField { let slot: SourceSlot; let text: String }

    private static func sourceFields(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation?,
        context: SummarizationContext?
    ) -> [SourceField] {
        var fields = [
            SourceField(slot: .senderName, text: senderName),
            SourceField(slot: .subject, text: subject),
            SourceField(slot: .body, text: bodyText),
        ]
        if let name = context?.userIdentity?.displayName { fields.append(.init(slot: .userDisplayName, text: name)) }
        func recipients(_ recipients: [SummarizationContext.Recipient], role: RecipientRole, item: Int? = nil) {
            for (index, recipient) in recipients.enumerated() where recipient.displayName != nil {
                let slot: SourceSlot = item.map { .connectedRecipient(item: $0, role: role, index: index) } ?? .anchorRecipient(role: role, index: index)
                fields.append(.init(slot: slot, text: recipient.displayName!))
            }
        }
        if let anchor = context?.anchorRecipients { recipients(anchor.to, role: .to); recipients(anchor.cc, role: .cc) }
        for (index, signal) in (context?.analysisSignals ?? []).enumerated() { fields.append(.init(slot: .analysisSignal(index), text: signal)) }
        for (index, item) in (context?.connectedItems ?? []).enumerated() {
            fields.append(.init(slot: .connectedSender(index), text: item.senderName))
            fields.append(.init(slot: .connectedSubject(index), text: item.subject))
            fields.append(.init(slot: .connectedExcerpt(index), text: item.excerpt))
            if let recipientsValue = item.recipients { recipients(recipientsValue.to, role: .to, item: index); recipients(recipientsValue.cc, role: .cc, item: index) }
        }
        for (index, item) in (context?.satelliteEvidence ?? []).enumerated() { fields.append(.init(slot: .satelliteText(index), text: item.text)) }
        if let digest = context?.messageEvidenceDigest { fields.append(.init(slot: .evidenceDigest, text: digest)) }
        for (index, item) in (context?.visualAttachmentSummaries ?? []).enumerated() { fields.append(.init(slot: .visualSummary(index), text: item.summary)) }
        for (index, item) in (context?.textAttachmentEvidence ?? []).enumerated() { fields.append(.init(slot: .textAttachment(index), text: item.text)) }
        if let action = knownInterpretation?.triageVerdict.action {
            fields.append(.init(slot: .actionSummary, text: action.summary))
            if let deadline = action.deadline { fields.append(.init(slot: .actionDeadline, text: deadline.dateString)) }
            for (index, value) in action.decisionInputs.enumerated() { fields.append(.init(slot: .decisionInput(index), text: value)) }
        }
        if let acknowledgement = knownInterpretation?.triageVerdict.acknowledgement {
            fields.append(.init(slot: .acknowledgementSummary, text: acknowledgement.summary))
            if let deadline = acknowledgement.deadline { fields.append(.init(slot: .acknowledgementDeadline, text: deadline.dateString)) }
            for (index, value) in acknowledgement.materialFacts.enumerated() { fields.append(.init(slot: .materialFact(index), text: value)) }
        }
        return fields
    }

    private static func rebuiltContext(
        _ context: SummarizationContext?, values: [SourceSlot: String], translationContext: TranslationContext,
        protection: PreparedTranslationGlossaryProtection, targetLanguage: SummarizationTargetLanguage
    ) -> SummarizationContext? {
        guard let context else {
            return SummarizationContext(translationContext: translationContext, translationProtection: protection, summaryTargetLanguage: targetLanguage)
        }
        func recipients(_ input: SummarizationContext.AnchorRecipients?, item: Int? = nil) -> SummarizationContext.AnchorRecipients? {
            guard let input else { return nil }
            func mapped(_ input: [SummarizationContext.Recipient], role: RecipientRole) -> [SummarizationContext.Recipient] {
                input.enumerated().map { index, recipient in
                    let slot = item.map { SourceSlot.connectedRecipient(item: $0, role: role, index: index) } ?? .anchorRecipient(role: role, index: index)
                    return .init(displayName: values[slot] ?? recipient.displayName, address: recipient.address)
                }
            }
            return .init(to: mapped(input.to, role: .to), cc: mapped(input.cc, role: .cc))
        }
        return SummarizationContext(
            vectorShape: context.vectorShape,
            analysisSignals: context.analysisSignals.enumerated().map { values[.analysisSignal($0.offset)] ?? $0.element },
            connectedItems: context.connectedItems.enumerated().map { index, item in
                .init(senderName: values[.connectedSender(index)] ?? item.senderName, subject: values[.connectedSubject(index)] ?? item.subject, excerpt: values[.connectedExcerpt(index)] ?? item.excerpt, similarity: item.similarity, direction: item.direction, recipients: recipients(item.recipients, item: index))
            },
            satelliteEvidence: context.satelliteEvidence.enumerated().map { .init(kind: $0.element.kind, text: values[.satelliteText($0.offset)] ?? $0.element.text) },
            messageEvidenceDigest: values[.evidenceDigest] ?? context.messageEvidenceDigest,
            visualAttachmentSummaries: context.visualAttachmentSummaries.enumerated().map { .init(filename: $0.element.filename, summary: values[.visualSummary($0.offset)] ?? $0.element.summary) },
            textAttachmentEvidence: context.textAttachmentEvidence.enumerated().map { .init(filename: $0.element.filename, text: values[.textAttachment($0.offset)] ?? $0.element.text) },
            userIdentity: context.userIdentity.map { .init(displayName: values[.userDisplayName] ?? $0.displayName, primaryEmailAddress: $0.primaryEmailAddress, aliasEmailAddresses: $0.aliasEmailAddresses) },
            anchorDirection: context.anchorDirection, anchorRecipients: recipients(context.anchorRecipients),
            correspondenceExcludingListID: context.correspondenceExcludingListID, translationContext: translationContext,
            translationProtection: protection, summaryTargetLanguage: targetLanguage, customCategories: context.customCategories
        )
    }

    private static func rebuiltKnownInterpretation(_ known: SummaryKnownInterpretation?, values: [SourceSlot: String]) -> SummaryKnownInterpretation? {
        guard let known else { return nil }
        let verdict = known.triageVerdict
        let action = verdict.action.map { action in
            ActionSpec(summary: values[.actionSummary] ?? action.summary, kind: action.kind, directedAt: action.directedAt,
                deadline: action.deadline.map { .init(dateString: values[.actionDeadline] ?? $0.dateString, type: $0.type, confidence: $0.confidence, evidenceSpan: $0.evidenceSpan) },
                decisionInputs: action.decisionInputs.enumerated().map { values[.decisionInput($0.offset)] ?? $0.element }, evidenceSpans: action.evidenceSpans)
        }
        let acknowledgement = verdict.acknowledgement.map { item in
            AcknowledgementSpec(summary: values[.acknowledgementSummary] ?? item.summary, signalKind: item.signalKind,
                deadline: item.deadline.map { .init(dateString: values[.acknowledgementDeadline] ?? $0.dateString, type: $0.type, confidence: $0.confidence, evidenceSpan: $0.evidenceSpan) },
                materialFacts: item.materialFacts.enumerated().map { values[.materialFact($0.offset)] ?? $0.element }, evidenceSpans: item.evidenceSpans)
        }
        return .init(classification: known.classification, triageVerdict: .init(isActionable: verdict.isActionable, requiresConfirmation: verdict.requiresConfirmation, confidence: verdict.confidence, action: action, acknowledgement: acknowledgement, extractionVersion: verdict.extractionVersion), customCategoryKeys: known.customCategoryKeys, semanticTagCandidates: known.semanticTagCandidates)
    }

    /// Exact pairs and style rules bind the stored summary; provisional pairs
    /// are only advisory, and the display-language pass already keeps the
    /// visible text residue-free, so a newly founded provisional pair does
    /// not make every stored summary that mentions its term stale.
    private static func summaryInputFingerprint(targetLanguage: SummarizationTargetLanguage, translationContext: TranslationContext?) -> String {
        let binding = translationContext.map {
            TranslationContext(exactGlossary: $0.exactGlossary, provisionalGlossary: [], rules: $0.rules)
        }
        let contextFingerprint = binding.flatMap { $0.isEmpty ? nil : $0.fingerprint } ?? "no-translation-context"
        let fields = ["summary-input-v1", targetLanguage.identifier, contextFingerprint]
        let serialized = fields.map { "\($0.utf8.count):\($0)" }.joined()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in serialized.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }

    private static func diagnostic(outcome: String, occurrenceCount: Int) {
        summarizationGroundingLogger.debug(
            "summary grounding outcome=\(outcome, privacy: .public) occurrences=\(occurrenceCount, privacy: .public)"
        )
    }

    private static func exactOccurrenceCount(
        in fields: [String],
        glossary: [TranslationGlossaryEntry]
    ) -> Int {
        fields.reduce(into: 0) { total, field in
            for entry in glossary where entry.sourceTerm.isEmpty == false {
                total += field.components(separatedBy: entry.sourceTerm).count - 1
            }
        }
    }

    private static func protecting(
        _ segments: [String],
        exactGlossary: [TranslationGlossaryEntry]
    ) -> (segments: [String], protection: PreparedTranslationGlossaryProtection) {
        var delimiter: String
        repeat {
            delimiter = "\n[[OHIA_SUMMARY_SEGMENT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))]]\n"
        } while segments.contains { $0.contains(delimiter) }

        let prepared = TranslationGlossaryProtection().prepare(
            bodyText: segments.joined(separator: delimiter),
            exactGlossary: exactGlossary
        )
        return (
            prepared.protectedText.components(separatedBy: delimiter),
            prepared
        )
    }
}

public struct SummarizationTargetLanguage: Sendable, Equatable {
    public static let summaryOutputLanguageDefaultsKey = "summaryOutputLanguage"

    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = Self.normalizedIdentifier(identifier)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? self.identifier
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var promptDescription: String {
        displayName == identifier ? identifier : "\(displayName) (\(identifier))"
    }

    public static func current(
        preferredLanguages: [String] = Locale.preferredLanguages,
        displayLocale: Locale = .autoupdatingCurrent
    ) -> SummarizationTargetLanguage {
        let raw = preferredLanguages.first ?? displayLocale.identifier
        let identifier = normalizedIdentifier(raw)
        let localeIdentifier = identifier.replacingOccurrences(of: "-", with: "_")
        let displayName = displayLocale.localizedString(forIdentifier: localeIdentifier)
            ?? displayLocale.localizedString(forLanguageCode: identifier.components(separatedBy: "-").first ?? identifier)
            ?? identifier
        return SummarizationTargetLanguage(identifier: identifier, displayName: displayName)
    }

    public static func ohiaPreferred(
        summaryOutputLanguage: String? = OhiaSharedDefaults.store.string(forKey: summaryOutputLanguageDefaultsKey),
        activeLanguagesData: Data? = OhiaSharedDefaults.store.data(
            forKey: ContentLanguagesStore.defaultsKey
        ),
        preferredLanguages: [String] = Locale.preferredLanguages,
        displayLocale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> SummarizationTargetLanguage {
        if let summaryOutputLanguage,
           let supportedSummaryLanguage = supportedLanguageIdentifier(summaryOutputLanguage) {
            return current(preferredLanguages: [supportedSummaryLanguage], displayLocale: displayLocale)
        }
        let activeLanguages = activeLanguageIdentifiers(from: activeLanguagesData)
        let fallbackLanguages = supportedLanguageIdentifiers(from: preferredLanguages)
        return current(
            preferredLanguages: activeLanguages.isEmpty ? (fallbackLanguages.isEmpty ? ["en"] : fallbackLanguages) : activeLanguages,
            displayLocale: displayLocale
        )
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "en" : trimmed.replacingOccurrences(of: "_", with: "-")
    }

    private static func activeLanguageIdentifiers(from data: Data?) -> [String] {
        ContentLanguagesStore.decode(data)
            .compactMap(supportedLanguageIdentifier)
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                let lhsRank = commonLanguageRank(lhs)
                let rhsRank = commonLanguageRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private static func supportedLanguageIdentifiers(from identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard let supported = supportedLanguageIdentifier(identifier),
                  seen.insert(supported).inserted else {
                return nil
            }
            return supported
        }
    }

    private static func supportedLanguageIdentifier(_ identifier: String) -> String? {
        LocalModelLanguageSupport.canonicalLanguageID(for: normalizedIdentifier(identifier))
    }

    private static func commonLanguageRank(_ identifier: String) -> Int {
        let languageCode = identifier.components(separatedBy: "-").first ?? identifier
        return commonLanguagePreferenceOrder.firstIndex(of: languageCode) ?? Int.max
    }

    private static let commonLanguagePreferenceOrder = LocalModelLanguageSupport.supportedLanguageIDs
}

/// Why the interpreter spends its single bounded second generation.
enum InterpretationSecondPassReason: Equatable {
    /// The first answer failed the output contract.
    case formatRepair
    /// Two or more qualified purposes cleared the threshold without a winner.
    case competingPurposes
    /// The first answer resolved to correspondence on a list post whose To line
    /// names no owned address, and nothing else would resolve once the writer
    /// discards it.
    case listCorrespondenceExcluded
}

enum SummarizationPromptBuilder {
    static let bodyCharacterLimit = 5000
    static let interpretationBodyCharacterLimit = 3000
    private static let appleVisualAttachmentLimit = 2
    private static let appleVisualAttachmentSummaryCharacterLimit = 260
    private static let appleTextAttachmentLimit = 1
    private static let appleTextAttachmentCharacterLimit = 600
    static let purposeValues = MailPurpose.allCases.map(\.rawValue).joined(separator: ", ")

    /// Heuristic-only taxonomy. It deliberately contains definitions and
    /// boundary rules, never representative messages or user-specific
    /// exemplars.
    static let classificationGuide = """
    Classify Purpose from the cleaned anchor text and structured metadata. The model proposes candidates; a deterministic resolver makes the selection. Every Purpose candidate must cite its canonical necessary-condition rule ID.

    Purpose asks what job the anchor primarily performs. Return one primary candidate when that job is clear. Additional candidates (at most three total) are only for genuinely unresolved alternatives about the central job, not secondary topics or incidental features. A mention of money, a date, a human sender, or a transaction does not by itself make finance, calendar, correspondence, or receipt a competing purpose. Apply exclusions before emitting candidates; omit categories whose necessary central condition is absent. Do not add other alongside a qualifying defined purpose. Keep confidence low when the evidence is genuinely insufficient; do not invent certainty to satisfy the resolver. Candidate confidence ordering must respect exclusions and supersession. A generic state-change framing never outranks a qualifying specific Purpose. necessary central condition; Exclusions and supersession:
    - correspondence — central interpersonal exchange, request, response, discussion, or relationship maintenance; rule purpose.correspondence.exchange. A human sender is insufficient; a specialized transaction, event, alert, logistics, support, or legal job supersedes it.
    - announcement — central non-periodic informational notice for multiple recipients or a community; rule purpose.announcement.notice. Recurring editorial material is newsletter; operational state change is notification; commercial persuasion is promotion.
    - receipt — central acknowledgement that a purchase, payment, donation, booking charge, or transaction itself completed; rule purpose.receipt.completed. Bills, amounts due, declined or pending payments, and statements are finance. Completion of an administrative reimbursement or payment-processing step is not a receipt while funds are still scheduled or pending. Receipt supersedes finance only when the underlying transaction itself is complete.
    - promotion — central commercial persuasion to purchase, subscribe, upgrade, visit, or engage; rule purpose.promotion.persuasion. Requested transaction status, receipts, shipping state, and account notices are excluded.
    - newsletter — central recurring editorial or curated multi-item publication; rule purpose.newsletter.recurringEditorial. One-off notices are announcement and machine state-change digests are notification.
    - verificationCode — central time-limited credential, passcode, magic link, or confirmation action for immediate access or identity proof; rule purpose.verificationCode.timeBoundCredential. It supersedes security.
    - notification — central system, account, content, or workflow state change with no more specific purpose; rule purpose.notification.stateChange. Receipt, verification codes, security, shipping, travel, calendar, finance, support, legal, and social activity supersede it.
    - security — central authentication, access, credentials, privacy, fraud, or account risk; rule purpose.security.accountRisk. A usable time-bound credential is verificationCode; generic legal/privacy policy is excluded.
    - shipping — central physical shipment, carrier handling, tracking, delivery state, or pickup; rule purpose.shipping.logisticsState. Purchase completion alone is receipt and movement of people is travel.
    - travel — central itinerary, transport, lodging, check-in, or travel reservation state; rule purpose.travel.itineraryState. It supersedes calendar when the substantive event is travel.
    - finance — central financial obligation, balance, statement, tax, payroll, invoice, transfer, reimbursement, or payment state that is not a completed transaction acknowledgement; rule purpose.finance.financialObligation. Reimbursement processing and scheduled or pending transfers are finance even when an administrative processing step is complete. Acknowledgement that the underlying transaction itself completed is receipt.
    - calendar — central creation, change, cancellation, acceptance, decline, or coordination of a scheduled event; rule purpose.calendar.scheduledEventAction. A date mention alone is insufficient and travel itinerary state is travel.
    - support — central opening, update, resolution, or discussion of a customer-service or technical-support incident; rule purpose.support.caseInteraction. General interpersonal requests are correspondence.
    - legal — central establishment, change, request, or explanation of legal rights, obligations, contracts, claims, regulatory duties, or formal compliance action; rule purpose.legal.rightsObligations. Boilerplate terms, disclaimers, and footer links are insufficient.
    - socialActivity — central platform-mediated social interaction such as follows, reactions, comments, community activity, or connection requests; rule purpose.socialActivity.platformInteraction. Direct discussion is correspondence and generic platform state is notification.
    - other — successful classification where no defined purpose describes the central job; rule purpose.other.noDefinedPurpose. Never use it for parser errors or low confidence.

    Resolution thresholds: Purpose requires confidence >= 0.65 and a top-two margin >= 0.12 unless qualifying structured evidence reaches 0.90.

    Purpose raw values: \(purposeValues).
    Evidence contains only stable Purpose rule identifiers made of letters, digits, period, underscore, or hyphen. Never return body quotations as evidence. Return at most twelve distinct rule identifiers.
    Copy the exact canonical necessary-condition rule ID printed beside the selected purpose above. Do not invent, paraphrase, shorten, or replace its suffix. The purpose and its rule ID must be the pair defined in the guide.
    """

    // MARK: - User-defined (custom) categories
    //
    // Active `CustomMailCategory` definitions are appended to the prompt
    // and returned through a dedicated `CustomCategories:` output line.
    // Custom categories are additive labels independent of built-in Purpose.

    static func customCategorySection(_ context: SummarizationContext?) -> String {
        customCategoryGuide(context?.customCategories ?? [])
    }

    static func customCategoryGuide(_ customCategories: [CustomMailCategoryDescriptor]) -> String {
        guard customCategories.isEmpty == false else { return "" }
        var lines = [
            "User-defined categories:",
            "The account owner defined these additional categories. They are additive labels and never replace built-in Purpose. When a definition clearly matches the anchor evidence, return that category's key in the CustomCategories output field; otherwise leave CustomCategories empty. Evaluate each definition independently from the anchor evidence."
        ]
        for descriptor in customCategories {
            let definition = (descriptor.definition ?? "")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            lines.append("- \(descriptor.key) (\(descriptor.displayName)): \(definition)")
        }
        return lines.joined(separator: "\n")
    }

    /// Independent custom-category field. The field is present even when the
    /// live catalog is empty so the parser contract has one stable schema.
    static func customCategoriesContractLine(_ context: SummarizationContext?) -> String {
        let customCategories = context?.customCategories ?? []
        guard customCategories.isEmpty == false else {
            return "\nCustomCategories: <empty; no active custom-category catalog>"
        }
        let keys = customCategories.map(\.key).joined(separator: ", ")
        return "\nCustomCategories: <zero to two of \(keys) as key=confidence entries with confidence >= 0.75, separated by  ||  | empty>"
    }

    /// Stable cache-key suffix for prompts whose *prefix* embeds the custom
    /// definitions (the interpretation prompts split after the taxonomy).
    /// Engines key reusable KV state on `PrefixCachedPrompt.cacheKey`, so a
    /// changed catalog must produce a different key or generation would run
    /// against a stale cached prefix. FNV-1a over key + definition.
    static func customCategoryCacheKeySuffix(_ context: SummarizationContext?) -> String {
        let customCategories = context?.customCategories ?? []
        guard customCategories.isEmpty == false else { return "" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for descriptor in customCategories.sorted(by: { $0.key < $1.key }) {
            for byte in "\(descriptor.key)|\(descriptor.definition ?? "")\u{1}".utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        return "+cc-" + String(hash, radix: 16)
    }

    static let semanticTagGuide = """
    Canonical semantic tags:
    - Emit zero to three reusable concepts from the anchor across the full spectrum of named efforts, organizations, groups, concrete subjects, documents, products, places, logistics, issues, and decisions. This is one flat set: never emit duplicates merely because one concept could be viewed as a project, team, or topic.
    - Treat translations, transliterations, case, spacing, and word-order variants as one candidate. Put every evidenced surface form in aliases, separated by `/`; for example, Admissions 2027 and 入試2027 belong in one candidate.
    - Preserve qualifiers that change identity. Admissions 2026 and Admissions 2027 are different; record `year:2026` or `year:2027`. Institution, program, property, trip, order, case, campaign, and other meaningful qualifiers also distinguish tags. Separate qualifiers with commas.
    - Never emit both a broad parent and its qualified specific child for the same anchor. Prefer the most specific reusable concept supported by evidence.
    - Do not emit people, Purpose values, custom categories, or generic mail-type words as tags. Local context may clarify a concept already present in the anchor but may not invent one.
    Format each candidate exactly as `preferred label | aliases=surface form/surface form | qualifiers=kind:value,kind:value | centrality=value | roles=value+value | confidence=number`. centrality is one of \(semanticCentralityValues). roles is a `+`-separated subset of \(semanticRoleValues). Use an empty value after `qualifiers=` or `roles=` when none apply. Separate candidates with ` || `.
    """

    static let purposeSummaryGuide = """
    Purpose-specific summary shape:
    - correspondence: capture the exchange's current request, response, decision, or next step without inferring Context.
    - announcement: capture the source, subject, audience, timing, and practical significance.
    - receipt: capture merchant, purchase or payment, amount/date/order status, and any follow-up only if present.
    - promotion: capture brand, offer, discount, expiry, and material terms without sounding like advertising.
    - newsletter: capture source and the main topics or takeaways, not every headline.
    - verificationCode: capture the issuing service, the kind of authentication step, the code value when present, and any stated expiry; do not editorialize.
    - security: capture service/account, event, risk, and required action.
    - shipping: capture carrier/store, shipment state, delivery window, and tracking issue.
    - travel: capture booking, itinerary, timing, location, and action needed.
    - finance: capture institution/vendor, amount, due date, statement/bill status, and action needed.
    - calendar: capture event, time, participants, RSVP or prep needed.
    - support: capture case/ticket, problem state, next step, and response needed.
    - legal: capture document/policy/contract, effective date, obligation, and action needed.
    - notification: capture the state change, affected system or account, timing, and practical consequence.
    - socialActivity: capture the platform-mediated interaction and any evidenced response path.
    - other: summarize according to the central practical signal without inventing a specialized Purpose.
    """

    // MARK: - Triage prompt material
    //
    // These guides describe the two-axis triage classification the LLM is
    // asked to produce alongside the body summary: `isActionable` (sender
    // expects a reply / draftable response) and `requiresConfirmation` (recipient must
    // absorb / acknowledge information). The two flags are independent —
    // they can both fire, neither, or just one. The structured payloads
    // (action / acknowledgement) seed the Almanac question generator and
    // the acknowledge surface respectively, so the field-level wording
    // matters: each `decisionInputs` string becomes an Almanac question,
    // each `materialFacts` string becomes a "got it" bullet.

    static let actionKindValues = ActionKind.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    static let assigneeValues = Assignee.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    static let signalKindValues = SignalKind.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    static let semanticCentralityValues = SemanticTagCentrality.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    static let semanticRoleValues = SemanticTagRole.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    static let triageGuide = """
    Two independent attention flags must be set for every message:

    - isActionable: true iff the anchor is a received message and the sender is asking the account owner (or the team the owner belongs to) for a direct reply or draftable response — reply, supply information, choose an option and tell the sender, schedule by responding, review and report back, sign and return. Sent/outgoing messages written by the account owner are NOT actionable for the account owner. Short conversational acknowledgements or acceptances ("sounds good", "got it", "thanks", "will do", "looks good") that merely close the loop are NOT actionable, even when nearby thread context contains prior tasks or decisions. Self-service or portal tasks ("pay this invoice", "resolve this App Store submission issue", "review your itinerary", "manage your booking"), mass-marketing CTAs ("Shop now", "Read more", "book a consultation", "attend an open house"), automated transactional notices, no-reply institutional notifications, and informational digests are NOT actionable unless they explicitly ask the owner to reply/respond/email/send information back to the sender. A message addressed only to a third party with the owner on cc, with no ask of the owner, is NOT actionable.
    - requiresConfirmation: true iff the message contains time-sensitive or material information the recipient must absorb without replying — verification codes, security alerts, calendar changes the owner attends, shipping milestones the owner ordered, financial alerts on the owner's account, legal deadlines binding the owner, booking confirmations the owner holds. Newsletters and marketing do NOT require confirmation. A message that already passed (e.g. a flight reminder for a flight last week) does NOT require confirmation.

    Read the entire current anchor for requests before deciding that a message merely closes the loop. Greetings, thanks, an arrival update, or a friendly sign-off do not cancel a later request. A personal request to tell the sender whether the owner plans to visit or is available needs a reply, even without a question mark, deadline, or firm meeting proposal. For example, "I arrived safely, thanks for your help. Let me know whether you will be on campus next week" is actionable: the requested response is the owner's campus plans. "I arrived safely, thanks for your help. See you soon" alone has no such request. A generic "let me know if you need anything" is an optional offer, not a demand for a reply. Interpret who is requesting what from whom; do not classify by a phrase alone or import a request from quoted history.

    Both can be true simultaneously (e.g. "Please review the attached contract and confirm receipt by Friday" — actionable AND requires confirmation). Both can be false (purely informational newsletters, marketing/event invitations, optional offers, ambient updates).

    Always emit both flags explicitly as true or false. Empty, missing, or uncertain field text is not a false verdict. When actionable, describe the actual requested response in ActionSummary, independently of the social tone or Purpose label.

    confidence is a 0.0–1.0 estimate of how certain the classification is given the available evidence.
    """

    static let actionSpecGuide = """
    Populate when isActionable is true; otherwise omit. Describes the direct response the sender wants:

    - summary: one sentence stating the ask in concrete terms ("Send the Q3 financials", "Decide whether to approve the budget", "Schedule a 30-minute review").
    - kind: one of \(actionKindValues).
    - directedAt: one of \(assigneeValues). Use user when the ask is to the account owner specifically; userTeam when addressed to a group the owner is part of; thirdParty when the owner is informed but someone else is responsible; ambiguous when the addressee is unclear.
    - deadline: optional. Populate only when the message states a specific date, day, time, or bounded window tied to the ask ("by Friday", "before the exec meeting", "within 24 hours"): capture the surface text in dateString; classify type as "hard" (explicit deadline), "soft" (a preferred-by window), or "conditional" (depends on something else); record confidence and an evidence span pointing to the text. A generic request for a timely reply with no stated date, day, event, or window — "let me know soon", "looking forward to hearing from you", "at your earliest convenience", "hoping to hear from you soon", or an equivalent polite closing in any language — is NOT a deadline; leave this empty.
    - decisionInputs: 0–5 short questions the account owner must answer before a reply can be drafted. Each question must be answerable by the owner alone (do not include questions the owner would have to ask the sender). Examples: "Do you have the Q3 figures finalized?", "Are you available the week of October 14?", "Have you already replied off-platform?". Order from most-blocking to least.
    - evidenceSpans: text spans in the body that support the classification. Use the same start/end offsets as `MessageDimensions.evidenceSpans`.
    """

    static let acknowledgementSpecGuide = """
    Populate when requiresConfirmation is true; otherwise omit. Describes what the recipient must absorb:

    - summary: one sentence stating the material signal ("Flight UA1234 moved to 9am Friday", "Verification code 423891, expires in 10 minutes", "Statement available for September").
    - signalKind: one of \(signalKindValues). Use verificationCode for one-time codes / magic links; securityAlert for persistent security state changes; calendarChange for meeting moves/cancels; financialAlert for bills, statements, charges; legalDeadline for contract or compliance dates; shippingMilestone for carrier updates; bookingConfirmation for reservations the owner holds; accountChange for settings/plan changes; deliveryConfirmation for generic transactional confirmations; other when nothing fits.
    - deadline: optional. Same rule as the action deadline above — populate only when a specific date, day, time, or bounded window is stated; a polite closing with no stated timeframe is not a deadline. For verification codes, the deadline is when the code expires (parse from the body when stated; otherwise omit).
    - materialFacts: 0–5 short bullets the recipient needs to internalize. Each bullet must stand alone as a fact — no instructions to act, no questions, no editorializing. Examples: "Code: 423891", "New flight time: Friday 9:00 AM", "Statement covers Sept 1–30".
    - evidenceSpans: text spans that support the classification.
    """

    static let meetingGuide = """
    Meeting extraction is independent of both attention flags and Purpose. Populate Meeting* fields only when the anchor explicitly schedules a concrete meeting with a resolvable calendar date and start time. This includes in-person meetings and online meetings. Do not treat deadlines, office hours, availability polls, marketing webinars, vague suggestions to meet, or requests to choose a time as scheduled meetings. Preserve the stated title, start, end, time zone, physical location, and recognized meeting-host URL. Leave all Meeting* fields empty when no concrete timed meeting is present. A recognized calendar invitation is parsed separately and supersedes these body-derived fields.
    """

    static let deadlineDisciplineGuide = """
    Deadline fields (ActionDeadline / AcknowledgementDeadline): populate only when the message states a specific date, day, time, named event, or bounded window tied to the ask ("by Friday", "before the exec meeting", "within 24 hours", "expires in 10 minutes", "9/29"). A generic request for a timely reply with no stated date, day, event, or window — "let me know soon", "looking forward to hearing from you", "at your earliest convenience", "hoping to hear from you soon", or an equivalent polite closing in any language — is NOT a deadline. Leave the field empty rather than restate a pleasantry as a deadline.
    """

    static let sourceGroundingGuide = """
    Source grounding:
    - The visible summary may state only facts supported by the anchor body, subject, visual attachment summaries, or extracted text attachments.
    - Visual attachment summaries are generated separately from Apple Vision evidence only; use them as source evidence, but do not infer beyond them.
    - Extracted text attachments are source evidence from the anchor item; preserve document names, page/sheet/slide markers, and explicit values when they matter.
    - Reader identity is ground truth only for resolving references to the account owner and their outgoing aliases; do not add unrelated biographical facts.
    - Match the account owner by their full display name or by the supplied account/alias addresses. A shared first name alone is not enough.
    - If the anchor or context names another person who shares the account owner's first name, keep that person's full name or role from the source and do not rewrite them as the account owner.
    - Direction metadata is supplied when available. Sent items were written by the account owner; received items were written by the From sender, not the account owner.
    - Recipient metadata is supplied when available. Use To/Cc only to resolve who wrote, sent, or received the anchor; do not infer intent from being copied.
    - When there is any ambiguity, prefer full names over "you" or "your". Do not convert a third-party possessive such as "Maria Lopez's update" into "your update".
    - Use "you" or "your" only when the direction and identity evidence make the account owner unambiguous. Never use "you" or "your" for another same-first-name person.
    - Use local context silently to classify Purpose, resolve ambiguous references already present in the anchor, or choose a clearer noun for something the anchor itself mentions.
    - Do not add context-only facts such as permit numbers, addresses, dollar amounts, deadlines, cancellation terms, approval conditions, contact instructions, order IDs, tracking numbers, meeting times, or status changes unless they appear in the anchor body, subject, visual attachment summaries, or extracted text attachments.
    - For short direct anchors, stay close to the sender's wording. Lightly compress, quote, or closely translate the anchor rather than expanding it into a synthetic report.
    - Before finalizing, remove every clause that cannot be traced to the anchor body, subject, visual attachment summaries, or extracted text attachments.
    """

    static let summaryVoiceGuide = """
    Summary voice:
    - Make the grammatical subject explicit whenever the source identifies the actor, owner, or responsible party; do not hide them behind passive wording.
    - Prefer active voice. For actionable work summaries, state who is asking whom to do what instead of writing passive constructions such as "Dana should be informed" or "it was requested."
    - For short direct anchors, preserve the sender's actor-action-object shape instead of converting the note into "needs to be handled" or "should be informed" language.
    """

    static let interpretationClassificationGuide = classificationGuide

    static let interpretationSourceGroundingGuide = sourceGroundingGuide
        .replacingOccurrences(
            of: "The visible summary may state only facts",
            with: "The Headline and Intents output may use only facts"
        )
        .replacingOccurrences(
            of: "visible factual claim",
            with: "factual claim"
        )
        .replacingOccurrences(
            of: "the visible summary",
            with: "the output"
        )

    static func interpretationOutputContract(
        _ context: SummarizationContext?,
        purposes: [MailPurpose] = MailPurpose.allCases
    ) -> String {
        """
        Final triage check: distinguish a request for the owner's answer from an offer of help. "Let me know whether you plan to visit campus" requests information and is actionable, even inside a friendly arrival update. "Let me know if you need anything" only offers help if the owner wants it: no answer is expected otherwise, so that offer alone is NOT actionable. Do not turn an invitation to request assistance into an obligation to report whether assistance is needed. Greetings, thanks, and an arrival update alone are also not actionable. Judge the complete anchor: a separate actual request still requires a reply even when an optional offer appears too. Emit both flags explicitly; when IsActionable is false, leave every Action* field empty.

        Return exactly the field lines below in this order, with canonical enum raw values, finite confidence from 0.0 to 1.0, lists separated by ` || `, and classification candidates formatted as `rawValue | confidence | comma-separated-rule-ids`. ClassificationEvidence repeats the stable rule IDs used by the candidates, separated by commas. Leave a value empty only where the contract explicitly permits an empty bounded array. Provide values for the matching triage block when a flag is true. Do not return any summary text, reasoning, or the /no_think control token. End with \(GenerationStopPolicy.summaryEndMarker).
        \(interpretationDisplayLanguageLine(context, includesTriage: true))
        \(classificationOutputLines(context, purposes: purposes))
        SemanticTags: <zero to three preferred label | aliases=surface form/surface form | qualifiers=kind:value,kind:value | centrality=value | roles=value+value | confidence=number entries, separated by  ||  | empty>
        IsActionable: <true|false>
        RequiresConfirmation: <true|false>
        ActionSummary: <one sentence stating what the sender wants | empty>
        ActionKind: <one of \(actionKindValues) | empty>
        ActionDirectedAt: <one of \(assigneeValues) | empty>
        ActionDeadline: <surface text e.g. "by Friday" or "before the exec meeting" | empty>
        ActionDeadlineKind: <hard|soft|conditional | empty>
        ActionInputs: <up to five short questions the recipient must answer to draft a reply, separated by  ||  | empty>
        AcknowledgementSummary: <one sentence stating the material signal | empty>
        AcknowledgementSignalKind: <one of \(signalKindValues) | empty>
        AcknowledgementDeadline: <surface text e.g. "expires in 10 minutes" | empty>
        AcknowledgementDeadlineKind: <hard|soft|conditional | empty>
        AcknowledgementFacts: <up to five standalone fact bullets, separated by  ||  | empty>
        MeetingTitle: <short meeting title | empty>
        MeetingStart: <explicit meeting date and start time as surface text | empty>
        MeetingEnd: <explicit meeting date and end time as surface text | empty>
        MeetingTimeZone: <explicit IANA time zone or abbreviation | empty>
        MeetingLocation: <physical location as stated | empty>
        MeetingURL: <recognized meeting-host URL | empty>
        \(GenerationStopPolicy.summaryEndMarker)
        """
    }

    /// The reader-facing fields follow the configured display language; the
    /// surface-text fields stay verbatim because deadline and meeting-time
    /// resolution parse them in the source's own wording. Empty when no
    /// display language is bound, which leaves the line out of the prompt.
    static func interpretationDisplayLanguageLine(
        _ context: SummarizationContext?,
        includesTriage: Bool
    ) -> String {
        guard let target = context?.summaryTargetLanguage else { return "" }
        let language = target.promptDescription
        if includesTriage {
            return "Display language: write ActionSummary, AcknowledgementSummary, MeetingTitle, and every SemanticTags preferred label in \(language), translating source-language names and terms (romanize a personal or place name that has no established form). Keep ActionDeadline, AcknowledgementDeadline, MeetingStart, MeetingEnd, MeetingLocation, and SemanticTags aliases as surface text from the anchor.\n"
        }
        return "Display language: write every SemanticTags preferred label in \(language), translating source-language terms; keep SemanticTags aliases as surface text from the anchor.\n"
    }

    static func interpretationMetadataOutputContract(
        _ context: SummarizationContext?,
        purposes: [MailPurpose] = MailPurpose.allCases
    ) -> String {
        """
        Return exactly the field lines below in this order, with canonical enum raw values, finite confidence from 0.0 to 1.0, lists separated by ` || `, and classification candidates formatted as `rawValue | confidence | comma-separated-rule-ids`. ClassificationEvidence repeats the stable rule IDs used by the candidates, separated by commas. Do not classify action state, confirmation state, deadlines, or reply obligations. Do not return any summary text, reasoning, or the /no_think control token. End with \(GenerationStopPolicy.summaryEndMarker).
        \(interpretationDisplayLanguageLine(context, includesTriage: false))
        \(classificationOutputLines(context, purposes: purposes))
        SemanticTags: <zero to three preferred label | aliases=surface form/surface form | qualifiers=kind:value,kind:value | centrality=value | roles=value+value | confidence=number entries, separated by  ||  | empty>
        \(GenerationStopPolicy.summaryEndMarker)
        """
    }

    static func classificationOutputLines(
        _ context: SummarizationContext?,
        purposes: [MailPurpose] = MailPurpose.allCases
    ) -> String {
        let values = purposes.map(\.rawValue).joined(separator: ", ")
        return """
        PurposeCandidates: <one primary \(values) candidate as rawValue | confidence | rule-ids; only genuinely unresolved alternatives may add up to two candidates separated by  ||  >
        ClassificationEvidence: <zero to twelve stable Purpose rule identifiers separated by commas | empty>\(customCategoriesContractLine(context))
        """
    }

    /// Purposes a second pass may offer. The first pass always offers the full
    /// taxonomy: stating the list exclusion there shifted already-correct list
    /// posts (calendar, finance, legal, security) toward announcement or
    /// uncertainty. A second pass only runs once the first answer is already
    /// unusable, so it can drop what the writer would discard. The contract and
    /// rule table enumerate only these, because the model copies that
    /// enumeration far more reliably than it obeys a prose exclusion.
    static func secondPassPurposes(_ context: SummarizationContext?) -> [MailPurpose] {
        guard context?.correspondenceExcludingListID != nil else { return MailPurpose.allCases }
        return MailPurpose.allCases.filter { $0 != .correspondence }
    }

    static func interpretationRepairPrompt(
        _ prompt: PrefixCachedPrompt,
        context: SummarizationContext?,
        includesTriage: Bool,
        reason: InterpretationSecondPassReason
    ) -> PrefixCachedPrompt {
        let purposes = secondPassPurposes(context)
        let rulePairs = purposes.compactMap { purpose -> String? in
            guard let rule = MailClassificationResolver.necessaryPurposeRuleID(for: purpose) else { return nil }
            return "\(purpose.rawValue) -> \(rule)"
        }.joined(separator: "\n")
        let contract = includesTriage
            ? interpretationOutputContract(context, purposes: purposes)
            : interpretationMetadataOutputContract(context, purposes: purposes)
        let reasonText: String
        switch reason {
        case .formatRepair:
            reasonText = "FORMAT REPAIR: The prior answer failed the interpretation contract. Re-read the original anchor above and return all required field lines again. Do not copy an invalid rule or infer certainty from this repair request. Choose the primary job from the anchor and keep genuinely insufficient confidence low."
        case .competingPurposes:
            reasonText = """
            PURPOSE REVIEW: The first interpretation left competing purposes unresolved. Re-read the original anchor and identify its primary communicative job, separating that job from incidental topics. Apply the taxonomy's necessary conditions and exclusions. A completed-payment acknowledgement is not an outstanding financial obligation; possible future charges in boilerplate do not create a current obligation. A scheduled event mentioned in a community notice is not automatically event coordination. Return one primary candidate when the evidence supports a dominant job. Keep competing candidates if their central jobs genuinely remain equally plausible, and keep confidence low when evidence is insufficient. Do not invent certainty or select a winner just to satisfy this review.
            """
        case .listCorrespondenceExcluded:
            reasonText = "LIST PURPOSE REVIEW: The first interpretation chose correspondence, which is unavailable for this anchor. Re-read the original anchor and identify the job the post performs with the most specific defined purpose whose necessary central condition holds. Apply the taxonomy's necessary conditions and exclusions, and keep confidence low when evidence is insufficient."
        }
        let listNote = context?.correspondenceExcludingListID.map { listID in
            "\nMAILING LIST: This anchor was delivered through mailing list \(clean(listID, limit: 160)), and no address the account owner owns is a direct To recipient. Purpose correspondence is unavailable for it even when a person wrote it."
        } ?? ""
        return PrefixCachedPrompt(cacheKey: prompt.cacheKey, prefix: prompt.prefix, suffix: prompt.suffix + """


        \(reasonText)\(listNote)
        PurposeCandidates uses rawValue | finite decimal confidence from 0 to 1 | exact canonical rule ID. Copy the rule ID from this table verbatim; no alternate suffixes, prose, or labels within the tuple:
        \(rulePairs)

        \(contract)
        """)
    }

    static let appleInstructions = """
    Produce an economical proportional summary about the anchor item, interpreted through Ohia's local constellation of semantic evidence, AND classify the anchor on two independent attention axes. \
    Classify the anchor's Purpose. Then decide whether the anchor is actionable (asks the recipient for a direct reply or draftable response) and whether it requires confirmation (carries information the recipient must absorb without replying). When either flag is true, populate the matching structured payload (action for actionable, acknowledgement for confirmation). When both are true, populate both. \
    Then write the summary in the shape that fits the resolved Purpose. \
    Use the anchor body, subject, visual attachment summaries, and extracted text attachments as the source of truth for every visible factual claim. Use local context only to clarify evidence already present in the anchor. \
    This summary is shown to the account owner. In the visible summary, never write "account owner" or "the user" as a name for that person; use "you" or "your" when the direction and identity evidence make the account owner unambiguous, otherwise use the supplied display name. Never treat a same-first-name person as the account owner without full-name or address evidence. \
    Make the summary's subject clear: name the actor or responsible person when the source identifies them, and prefer active voice over passive wording that hides who is asking or doing the work. \
    Write one compact paragraph, usually 2-4 sentences. Short anchors should get short summaries; long or context-rich anchors may get a fuller paragraph, but still compress aggressively. Do not write a blow-by-blow chronology; keep only facts that change the recipient's understanding, decision, or next action. \
    Do not editorialize. Do not mention the existence of email, message, thread, node, graph, vector, embedding, ANN, constellation, satellite, moon, or connection. \
    Write in the target system language named in the prompt, translating source text when necessary.
    """

    static let guide = "Economical proportional Purpose-aware summary. Write one compact paragraph, usually 2-4 sentences: short anchors stay brief; long or context-rich anchors may be fuller but should still compress aggressively. Use complete, readable prose rather than clipped fragments. Capture the central practical signal required by the resolved Purpose and omit incidental context, repeated rationale, secondary details, and background that does not affect the recipient's understanding, decision, or next action. Every visible factual claim must be supported by the anchor body, subject, visual attachment summaries, or extracted text attachments; include local context only when it clarifies meaning already present in the anchor. Make the summary's subject clear by naming the actor, owner, or responsible party when source evidence identifies them, and prefer active voice over passive wording that hides who is asking or doing the work. Use reader identity only to disambiguate people: full name or email/alias evidence is required to identify the account owner, same first name alone is not enough, and other same-name people must keep their own names. Use you/your only when direction and identity evidence make the account owner unambiguous; otherwise use the supplied display name. Never write account owner or the user in the visible summary. Skip greetings, pleasantries, and sign-offs. Do not use the words email, message, thread, node, graph, vector, embedding, ANN, constellation, satellite, moon, or connection. Write in the target system language named in the prompt."

    static func applePrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        bodyCharacterLimit: Int = bodyCharacterLimit
    ) -> String {
        let targetLanguage = context?.summaryTargetLanguage ?? targetLanguage
        let bodyExcerpt = appleBodyExcerpt(bodyText, limit: bodyCharacterLimit)
        return """
        Target system language:
        \(targetLanguage.promptDescription)

        Summary length:
        \(lengthGuidance(bodyText: bodyText, context: context))

        \(translationGroundingSection(context))

        Mail purpose classification:
        \(classificationGuide)

        \(customCategorySection(context))

        \(purposeSummaryGuide)

        Triage classification:
        \(triageGuide)

        \(sourceGroundingGuide)

        \(summaryVoiceGuide)

        \(readerIdentitySection(context?.userIdentity))

        Anchor metadata:
        Direction: \(anchorDirectionSection(context))
        AuthorFrom: \(clean(senderName, limit: 120))
        \(anchorRecipientSection(context))
        Subject: \(clean(subject, limit: 180))

        Body:
        \(bodyExcerpt)

        \(messageEvidenceSection(context))

        \(visualAttachmentSection(context))

        \(textAttachmentSection(context))

        \(contextSection(context))
        """
    }

    static func appleBodyExcerpt(_ bodyText: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var text = bodyText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(
                of: #"(?is)<script\b[^>]*>.*?</script>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)<style\b[^>]*>.*?</style>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)<\s*(br|/p|/div|/li|/tr|/td|/h[1-6])\b[^>]*>"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bhttps?://[^\s<>()"]+"#,
                with: "[link]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bwww\.[^\s<>()"]+"#,
                with: "[link]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(data|cid):[^\s<>()"]+"#,
                with: "[image]",
                options: .regularExpression
            )

        text = text.components(separatedBy: .newlines)
            .map {
                $0.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return TranslationGlossaryProtection.markerSafePrefix(text, limit: limit)
    }

    static func mlxPrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> String {
        mlxPromptParts(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: context,
            targetLanguage: targetLanguage
        ).prompt
    }

    static func mlxPromptParts(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> PrefixCachedPrompt {
        let prompt = mlxLegacyPrompt(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: context,
            targetLanguage: targetLanguage
        )
        return prefixCachedPrompt(
            cacheKey: "email-body-summary-v2",
            prompt: prompt,
            suffixStartMarker: "Summary length:\n"
        )
    }

    static func mlxSummaryOnlyPromptParts(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> PrefixCachedPrompt {
        let prompt = mlxSummaryOnlyPrompt(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            context: context,
            targetLanguage: targetLanguage
        )
        return prefixCachedPrompt(
            cacheKey: "email-summary-only-v1",
            prompt: prompt,
            suffixStartMarker: "Target system language:\n"
        )
    }

    static func mlxSummaryOnlyPrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> String {
        let targetLanguage = context?.summaryTargetLanguage ?? targetLanguage
        return """
        Write only the visible body summary for the anchor. The Purpose and Intents verdict below already exist and are fixed; use them to shape the summary, but do not recalculate, revise, or emit classification or triage fields.
        Focus on what the sender is asking or informing and why it matters in the nearby semantic neighborhood, while keeping the anchor body and subject as the source of truth for visible facts.
        Write one compact paragraph, usually 2-4 sentences. Short anchors should get short summaries; long or context-rich anchors may get a fuller paragraph, but still compress aggressively. Do not write a blow-by-blow chronology; keep only facts that change the recipient's understanding, decision, or next action.
        Skip greetings, pleasantries, and sign-offs. Do not use the words "email", "message", "thread", "node", "graph", "vector", "embedding", "ANN", "constellation", "satellite", "moon", or "connection" in the summary.
        Do not include reasoning, analysis, planning, scratchpad text, and use no <think> tags. If the model supports thinking controls, disable thinking.
        Write in the target system language named below, translating source text when necessary.

        Target system language:
        \(targetLanguage.promptDescription)

        Summary length:
        \(lengthGuidance(bodyText: bodyText, context: context))

        \(translationGroundingSection(context))

        Existing Purpose and Intents:
        \(knownInterpretationSection(knownInterpretation))

        \(purposeSummaryGuide)

        \(sourceGroundingGuide)

        \(summaryVoiceGuide)

        \(readerIdentitySection(context?.userIdentity))

        Anchor metadata:
        Direction: \(anchorDirectionSection(context))
        AuthorFrom: \(clean(senderName, limit: 120))
        \(anchorRecipientSection(context))
        Subject: \(clean(subject, limit: 180))

        Body:
        \(TranslationGlossaryProtection.markerSafePrefix(bodyText, limit: bodyCharacterLimit))

        \(messageEvidenceSection(context))

        \(visualAttachmentSection(context))

        \(textAttachmentSection(context))

        \(contextSection(context))

        /no_think

        Return exactly the field line below. Do not return classification, triage, JSON, bullets, reasoning, or the /no_think control token. End with the single line \(GenerationStopPolicy.summaryEndMarker) and stop immediately after it.

        Summary: <Purpose-aware proportional summary written in \(targetLanguage.promptDescription)>
        \(GenerationStopPolicy.summaryEndMarker)
        """
    }

    static func mlxLegacyPrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> String {
        let targetLanguage = context?.summaryTargetLanguage ?? targetLanguage
        return """
        Summarize the anchor proportionally but economically, using Ohia's local constellation context when it clarifies the anchor. \
        Classify the anchor's Purpose. Then decide two independent attention flags: whether the anchor is actionable (asks the recipient for a direct reply or draftable response) and whether it requires confirmation (carries information the recipient must absorb without replying). Then write the summary in the shape that fits the resolved Purpose. \
        Focus on what the sender is asking or informing and why it matters in the nearby semantic neighborhood, while keeping the anchor body and subject as the source of truth for visible facts. \
        Write one compact paragraph, usually 2-4 sentences. Short anchors should get short summaries; long or context-rich anchors may get a fuller paragraph, but still compress aggressively. Do not write a blow-by-blow chronology; keep only facts that change the recipient's understanding, decision, or next action. \
        Skip greetings, pleasantries, and sign-offs. Do not use the words "email", "message", "thread", "node", "graph", "vector", "embedding", "ANN", "constellation", "satellite", "moon", or "connection" in the summary. \
        Do not include reasoning, analysis, planning, scratchpad text, and use no <think> tags. If the model supports thinking controls, disable thinking. \
        Write in the target system language named below, translating source text when necessary.

        Target system language:
        \(targetLanguage.promptDescription)

        Summary length:
        \(lengthGuidance(bodyText: bodyText, context: context))

        \(translationGroundingSection(context))

        Mail purpose classification:
        \(classificationGuide)

        \(customCategorySection(context))

        \(semanticTagGuide)

        \(purposeSummaryGuide)

        Triage classification:
        \(triageGuide)

        \(sourceGroundingGuide)

        \(summaryVoiceGuide)

        \(readerIdentitySection(context?.userIdentity))

        Anchor metadata:
        Direction: \(anchorDirectionSection(context))
        AuthorFrom: \(clean(senderName, limit: 120))
        \(anchorRecipientSection(context))
        Subject: \(clean(subject, limit: 180))

        Body:
        \(TranslationGlossaryProtection.markerSafePrefix(bodyText, limit: bodyCharacterLimit))

        \(messageEvidenceSection(context))

        \(visualAttachmentSection(context))

        \(textAttachmentSection(context))

        \(contextSection(context))

        /no_think

        Return exactly the field lines below in this order, with all field names in English exactly as shown, enum raw values in English exactly as listed, booleans as the literal strings true or false, deadlines as their surface text from the body, lists separated by ` || ` (the literal characters space, pipe, pipe, space), user-defined category candidates as `canonicalKey=confidence`, semantic-tag candidates in the exact format above, confidence from 0.0 to 1.0, and the summary written in \(targetLanguage.promptDescription), translating source text when necessary. Leave a value empty (after the colon and space) when it does not apply — for example, all Action* fields stay empty when IsActionable is false. Provide values for the matching block when a flag is true. Do not return the /no_think control token. End with the single line \(GenerationStopPolicy.summaryEndMarker) and stop immediately after it.

        \(classificationOutputLines(context))
        SemanticTags: <zero to three preferred label | aliases=surface form/surface form | qualifiers=kind:value,kind:value | centrality=value | roles=value+value | confidence=number entries, separated by  ||  | empty>
        IsActionable: <true|false>
        RequiresConfirmation: <true|false>
        ActionSummary: <one sentence stating what the sender wants | empty>
        ActionKind: <one of \(actionKindValues) | empty>
        ActionDirectedAt: <one of \(assigneeValues) | empty>
        ActionDeadline: <surface text e.g. "by Friday" or "before the exec meeting" | empty>
        ActionDeadlineKind: <hard|soft|conditional | empty>
        ActionInputs: <up to five short questions the recipient must answer to draft a reply, separated by  ||  | empty>
        AcknowledgementSummary: <one sentence stating the material signal | empty>
        AcknowledgementSignalKind: <one of \(signalKindValues) | empty>
        AcknowledgementDeadline: <surface text e.g. "expires in 10 minutes" | empty>
        AcknowledgementDeadlineKind: <hard|soft|conditional | empty>
        AcknowledgementFacts: <up to five standalone fact bullets, separated by  ||  | empty>
        Summary: <Purpose-aware proportional summary written in \(targetLanguage.promptDescription)>
        \(GenerationStopPolicy.summaryEndMarker)
        """
    }

    static func mlxInterpretationPrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        includesTriage: Bool = true
    ) -> String {
        mlxInterpretationPromptParts(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: context,
            includesTriage: includesTriage
        ).prompt
    }

    static func mlxInterpretationPromptParts(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        includesTriage: Bool = true
    ) -> PrefixCachedPrompt {
        let prompt = mlxLegacyInterpretationPrompt(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: context,
            includesTriage: includesTriage
        )
        let identitySection = readerIdentitySection(context?.userIdentity)
        let suffixStartMarker = identitySection.isEmpty
            ? "Anchor metadata:\n"
            : identitySection
        // The custom-category definitions live in the cached *prefix* of
        // this prompt, so the key must change whenever the catalog does —
        // otherwise the engine would reuse KV state built from a stale
        // taxonomy.
        let baseCacheKey = includesTriage
            ? "email-interpretation-v8-conversational-requests"
            : "email-interpretation-metadata-v5-primary-purpose"
        return prefixCachedPrompt(
            cacheKey: baseCacheKey + customCategoryCacheKeySuffix(context),
            prompt: prompt,
            suffixStartMarker: suffixStartMarker
        )
    }

    static func mlxLegacyInterpretationPrompt(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?,
        includesTriage: Bool = true
    ) -> String {
        let intentBullet = includesTriage
            ? "- Intents: the two independent attention flags and their structured payloads.\n- Meetings: independent scheduling evidence for a concrete timed meeting."
            : "- Historical metadata: no action state, confirmation state, reply obligation, or deadline triage."
        let triageSection = includesTriage
            ? """

        Triage classification:
        \(triageGuide)

        \(deadlineDisciplineGuide)

        Meeting detection:
        \(meetingGuide)

        """
            : ""
        let finalFields = includesTriage
            ? interpretationOutputContract(context)
            : interpretationMetadataOutputContract(context)
        return """
        Interpret the anchor for Ohia's pipeline. This pass produces only:
        - Classification: bounded Purpose candidates plus stable Purpose rule identifiers.
        - Semantic tags: up to three canonical reusable concepts in one flat vocabulary.
        \(intentBullet)

        Do not write or infer a body summary. Rich body summaries are generated only on demand when the user opens a detail surface.
        Classify from the anchor evidence first: subject, body, extracted text attachments, visual attachment summaries, sender identity, and recipient/direction metadata. Use the supplied local signals only to resolve ambiguity already present in the anchor.
        Do not include reasoning, analysis, planning, scratchpad text, and use no <think> tags. If the model supports thinking controls, disable thinking.

        Mail purpose classification:
        \(interpretationClassificationGuide)

        \(customCategorySection(context))

        \(semanticTagGuide)

        \(triageSection)
        \(interpretationSourceGroundingGuide)

        Anchor evidence:
        \(readerIdentitySection(context?.userIdentity))

        Anchor metadata:
        Direction: \(anchorDirectionSection(context))
        AuthorFrom: \(clean(senderName, limit: 120))
        \(anchorRecipientSection(context))
        Subject: \(clean(subject, limit: 180))

        Body:
        \(bodyText.prefix(interpretationBodyCharacterLimit))

        \(messageEvidenceSection(context))

        \(visualAttachmentSection(context))

        \(textAttachmentSection(context))

        \(contextSection(context))

        /no_think

        Use only the anchor evidence above. Return this final answer now, exactly as these field lines. Do not include any other text.

        \(finalFields)
        """
    }

    static func knownInterpretationSection(_ known: SummaryKnownInterpretation) -> String {
        var lines = [
            "- Purpose: \(known.classification.purpose?.rawValue ?? "uncertain")",
            "- Intents.actionNeeded: \(known.triageVerdict.isActionable ? "true" : "false")",
            "- Intents.confirm: \(known.triageVerdict.requiresConfirmation ? "true" : "false")"
        ]
        if let action = known.triageVerdict.action {
            lines.append("- Existing action summary: \(clean(action.summary, limit: 220))")
            if let deadline = action.deadline {
                lines.append("- Existing action deadline: \(clean(deadline.dateString, limit: 80))")
            }
            if !action.decisionInputs.isEmpty {
                let inputs = action.decisionInputs
                    .prefix(3)
                    .map { clean($0, limit: 120) }
                    .joined(separator: " || ")
                if !inputs.isEmpty {
                    lines.append("- Existing action inputs: \(inputs)")
                }
            }
        }
        if let acknowledgement = known.triageVerdict.acknowledgement {
            lines.append("- Existing confirmation summary: \(clean(acknowledgement.summary, limit: 220))")
            if let deadline = acknowledgement.deadline {
                lines.append("- Existing confirmation deadline: \(clean(deadline.dateString, limit: 80))")
            }
            if !acknowledgement.materialFacts.isEmpty {
                let facts = acknowledgement.materialFacts
                    .prefix(3)
                    .map { clean($0, limit: 120) }
                    .joined(separator: " || ")
                if !facts.isEmpty {
                    lines.append("- Existing confirmation facts: \(facts)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func contextSection(_ context: SummarizationContext?) -> String {
        guard let context, context.hasLocalSemanticEvidence else {
            return """
            Local constellation context:
            - No local semantic context is available; use only the anchor body.
            """
        }

        var lines = [
            "Local constellation context:",
            "- Use this only as disambiguating evidence. Do not copy facts from this section into the visible summary unless the anchor body, subject, or visual attachment summaries also support them."
        ]

        if let shape = context.vectorShape {
            lines.append("- Anchor shape: \(shape.contextCount) body moon\(suffix(shape.contextCount)), \(shape.attachmentCount) attachment moon\(suffix(shape.attachmentCount)), \(shape.entityCount) entity moon\(suffix(shape.entityCount)); \(shape.neighborCount) high-affinity neighbor\(suffix(shape.neighborCount)).")
        }

        if context.analysisSignals.isEmpty == false {
            let signals = context.analysisSignals
                .prefix(8)
                .map { clean($0, limit: 96) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            if signals.isEmpty == false {
                lines.append("- Anchor signals: \(signals).")
            }
        }

        let connected = context.connectedItems
            .prefix(4)
            .enumerated()
            .map { index, item in
                let score = String(format: "%.2f", Double(item.similarity))
                let sender = clean(item.senderName, limit: 80)
                let subject = clean(item.subject, limit: 120)
                let excerpt = clean(item.excerpt, limit: 220)
                let recipients = recipientList(item.recipients?.to ?? [])
                if let direction = item.direction {
                    return "\(index + 1). Score: \(score); Direction: \(direction.evidenceCode) (\(direction.evidenceDescription)); From: \(sender); To: \(recipients); Subject: \(subject); Excerpt: \(excerpt)"
                }
                return "\(index + 1). Score: \(score); From: \(sender); To: \(recipients); Subject: \(subject); Excerpt: \(excerpt)"
            }
        if connected.isEmpty == false {
            lines.append("Connected items:")
            lines.append(contentsOf: connected)
        }

        let satellites = context.satelliteEvidence
            .prefix(5)
            .enumerated()
            .map { index, item in
                "\(index + 1). \(clean(item.kind, limit: 48)): \(clean(item.text, limit: 180))"
            }
        if satellites.isEmpty == false {
            lines.append("Satellite evidence:")
            lines.append(contentsOf: satellites)
        }

        return lines.joined(separator: "\n")
    }

    static func translationGroundingSection(_ context: SummarizationContext?) -> String {
        guard let translationContext = context?.translationContext else { return "" }
        var sections = [
            "Cross-language summary grounding:",
            "Use the established terminology and translation preferences below while translating source facts into the target summary language. Exact terminology pins override the model's own rendering. Do not mention or reproduce these reference blocks in the visible summary."
        ]
        if let exact = TranslationPromptBuilder.omissionTolerantExactMarkerBlock(
            context?.translationProtection?.mappings ?? []
        ) {
            sections.append(exact)
        }
        if let provisional = TranslationPromptBuilder.provisionalGlossaryBlock(
            translationContext.provisionalGlossary
        ) {
            sections.append(provisional)
        }
        if let rules = TranslationPromptBuilder.rulesBlock(translationContext.rules) {
            sections.append(rules)
        }
        return sections.joined(separator: "\n")
    }

    static func anchorDirectionSection(_ context: SummarizationContext?) -> String {
        guard let direction = context?.anchorDirection else {
            return "unknown; do not infer sender/recipient beyond the From field and body text."
        }
        return "\(direction.evidenceCode); \(direction.promptDescription)"
    }

    static func anchorRecipientSection(_ context: SummarizationContext?) -> String {
        guard let recipients = context?.anchorRecipients else {
            return "To: unknown\nCc: unknown"
        }

        let toLine = recipientList(recipients.to)
        let ccLine = recipientList(recipients.cc)
        let perspective = nonDirectDeliveryPerspective(context)
        return """
        To: \(toLine)
        Cc: \(ccLine)
        \(perspective)
        """
    }

    private static func nonDirectDeliveryPerspective(_ context: SummarizationContext?) -> String {
        guard context?.anchorDirection == .incoming,
              let identity = context?.userIdentity,
              let recipients = context?.anchorRecipients,
              !recipients.to.isEmpty else {
            return ""
        }

        let ownedAddresses = Set(
            ([identity.primaryEmailAddress] + identity.aliasEmailAddresses)
                .filter { !$0.isEmpty }
        )
        guard !ownedAddresses.isEmpty else { return "" }

        let ownerIsDirectRecipient = recipients.to.contains {
            ownedAddresses.contains($0.address)
        }
        let ownerIsCopied = recipients.cc.contains {
            ownedAddresses.contains($0.address)
        }
        guard !ownerIsDirectRecipient else { return "" }

        let ownerDelivery = ownerIsCopied
            ? "account owner is Cc-only"
            : "account owner is not a direct To recipient"

        return """
        Delivery perspective: \(ownerDelivery). Direct To recipient(s): \(recipientList(recipients.to)).
        - Being copied does not make the account owner the addressee.
        - Treat second-person language in the anchor as referring to the direct To recipient(s) unless the body explicitly addresses the account owner by full name or owned address.
        - In the visible summary, name the direct To recipient for their roles, assignments, requests, or obligations; do not use "you" or "your" for the direct To recipient and do not transfer the direct recipient's roles, assignments, requests, or obligations to the account owner.
        """
    }

    static func readerIdentitySection(_ identity: SummarizationUserIdentity?) -> String {
        guard let identity, identity.isUseful else { return "" }

        var lines: [String] = ["Reader identity:"]
        if !identity.displayName.isEmpty {
            lines.append("- Account owner display name: \(clean(identity.displayName, limit: 120))")
        }
        if !identity.primaryEmailAddress.isEmpty {
            lines.append("- Account owner primary address: \(clean(identity.primaryEmailAddress, limit: 160))")
        }
        if !identity.aliasEmailAddresses.isEmpty {
            let aliases = identity.aliasEmailAddresses
                .prefix(8)
                .map { clean($0, limit: 120) }
                .joined(separator: ", ")
            if !aliases.isEmpty {
                lines.append("- Other outgoing addresses for the same person: \(aliases)")
            }
        }
        lines.append("- Use this identity only to resolve references to the account owner and their addresses.")
        lines.append("- Match the account owner by full display name, primary address, or alias address. Same first name alone is not enough.")
        lines.append("- If another named person shares the account owner's first name, preserve that person's full name or role and do not rewrite them as \"you\" or \"your\".")
        lines.append("- When there is any ambiguity, prefer full names over \"you\" or \"your\".")
        lines.append("- Do not convert a third-party possessive such as \"Maria Lopez's update\" into \"your update\".")
        lines.append("- Use \"you\" or \"your\" only when the direction and identity evidence make the account owner unambiguous.")
        lines.append("- Never write \"account owner\" or \"the user\" in the visible summary; use \"you\"/\"your\" when unambiguous, otherwise use the supplied display name.")
        return lines.joined(separator: "\n")
    }

    static func visualAttachmentSection(_ context: SummarizationContext?) -> String {
        let summaries = context?.visualAttachmentSummaries
            .prefix(appleVisualAttachmentLimit)
            .enumerated()
            .compactMap { index, item -> String? in
                let filename = clean(item.filename, limit: 96)
                let summary = clean(item.summary, limit: appleVisualAttachmentSummaryCharacterLimit)
                guard !summary.isEmpty else { return nil }
                return "\(index + 1). \(filename): \(summary)"
            } ?? []

        guard !summaries.isEmpty else { return "" }

        return ([
            "Visual attachments:",
            "- From Apple Vision classifications, object detections, and OCR text, plus capture time, place, or caption the file itself recorded. Treat them as anchor evidence and do not infer beyond them."
        ] + summaries).joined(separator: "\n")
    }

    static func messageEvidenceSection(_ context: SummarizationContext?) -> String {
        guard let digest = context?.messageEvidenceDigest,
              !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return [
            "Multimodal evidence bundle:",
            "- Body claims and attachment-derived claims are separated below. Use body claims as sender-authored text; use attachment claims as extracted visual/OCR evidence with uncertainty.",
            digest
        ].joined(separator: "\n")
    }

    static func textAttachmentSection(_ context: SummarizationContext?) -> String {
        let excerpts = context?.textAttachmentEvidence
            .prefix(appleTextAttachmentLimit)
            .enumerated()
            .compactMap { index, item -> String? in
                let filename = clean(item.filename, limit: 96)
                let text = clean(item.text, limit: appleTextAttachmentCharacterLimit)
                guard !text.isEmpty else { return nil }
                return "\(index + 1). \(filename): \(text)"
            } ?? []

        guard !excerpts.isEmpty else { return "" }

        return ([
            "Text attachments:",
            "- These excerpts were extracted from anchor documents. Treat them as source evidence and preserve explicit page, sheet, or slide markers when relevant."
        ] + excerpts).joined(separator: "\n")
    }

    static func lengthGuidance(bodyText: String, context: SummarizationContext?) -> String {
        let textLength = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let contextWeight = (context?.analysisSignals.count ?? 0)
            + ((context?.connectedItems.count ?? 0) * 2)
            + ((context?.satelliteEvidence.count ?? 0) * 2)
            + (context?.messageEvidenceDigest == nil ? 0 : 3)
            + ((context?.visualAttachmentSummaries.count ?? 0) * 3)
            + ((context?.textAttachmentEvidence.count ?? 0) * 3)
            + ((context?.vectorShape?.neighborCount ?? 0) > 0 ? 2 : 0)

        if textLength < 700 && contextWeight <= 2 {
            return "Brief: one compact sentence or two short sentences; preserve the useful meaning without expanding the sender's note."
        }
        if textLength < 2200 && contextWeight <= 7 {
            return "Standard: usually 2-3 sentences; preserve the request, key facts, Purpose-specific signal, and useful clarifying context."
        }
        return "Fuller: usually 3-4 sentences; cover the main ask, important facts, deadlines, decisions, Purpose-specific details, and relevant nearby context without padding, chronology, or unsupported facts."
    }

    private static func prefixCachedPrompt(
        cacheKey: String,
        prompt: String,
        suffixStartMarker: String
    ) -> PrefixCachedPrompt {
        guard !suffixStartMarker.isEmpty,
              let suffixStart = prompt.range(of: suffixStartMarker)?.lowerBound else {
            return PrefixCachedPrompt(cacheKey: cacheKey, prefix: "", suffix: prompt)
        }

        return PrefixCachedPrompt(
            cacheKey: cacheKey,
            prefix: String(prompt[..<suffixStart]),
            suffix: String(prompt[suffixStart...])
        )
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return TranslationGlossaryProtection.markerSafePrefix(collapsed, limit: max(0, limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func recipientList(_ recipients: [SummarizationContext.Recipient]) -> String {
        let values = recipients
            .prefix(8)
            .map { recipient in
                if let displayName = recipient.displayName, !recipient.address.isEmpty {
                    return "\(clean(displayName, limit: 80)) <\(clean(recipient.address, limit: 120))>"
                }
                if let displayName = recipient.displayName {
                    return clean(displayName, limit: 120)
                }
                return clean(recipient.address, limit: 120)
            }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "unknown" : values.joined(separator: ", ")
    }

    private static func suffix(_ count: Int) -> String {
        count == 1 ? "" : "s"
    }
}
