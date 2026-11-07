import Foundation

/// Reader-facing text produced by the ingestion-time interpretation: the
/// action and confirmation sentences, the meeting title, and semantic-tag
/// labels. Deadline and meeting-time surface text stays in the source wording
/// because resolvers parse it; decision inputs and material facts are never
/// displayed and are matched against source-language evidence by Composer
/// source relevance and task decomposition, so they stay as generated. A
/// field whose source-language passage could not be translated keeps its
/// generated wording, never a romanization, until it is interpreted again.
public extension InterpretationResult {
    func finalizingDisplayLanguage(
        using guardrail: DisplayLanguageGuard,
        targetLanguage: SummarizationTargetLanguage,
        source: DisplayLanguageGuard.Source
    ) async -> InterpretationResult {
        var fields: [String] = []
        if let action = triageVerdict.action {
            fields.append(action.summary)
        }
        if let acknowledgement = triageVerdict.acknowledgement {
            fields.append(acknowledgement.summary)
        }
        if let meeting { fields.append(meeting.title) }
        fields.append(contentsOf: semanticTagCandidates.map(\.preferredLabel))
        guard DisplayLanguageGuard.needsResolution(fields, targetLanguage: targetLanguage) else { return self }

        var resolved = await guardrail.resolve(fields, targetLanguage: targetLanguage, source: source).fields[...]
        func next() -> String { resolved.popFirst() ?? "" }

        let action = triageVerdict.action.map { action in
            ActionSpec(
                summary: next(),
                kind: action.kind,
                directedAt: action.directedAt,
                deadline: action.deadline,
                decisionInputs: action.decisionInputs,
                evidenceSpans: action.evidenceSpans
            )
        }
        let acknowledgement = triageVerdict.acknowledgement.map { acknowledgement in
            AcknowledgementSpec(
                summary: next(),
                signalKind: acknowledgement.signalKind,
                deadline: acknowledgement.deadline,
                materialFacts: acknowledgement.materialFacts,
                evidenceSpans: acknowledgement.evidenceSpans
            )
        }
        let meeting = self.meeting.map { meeting in
            MeetingCandidate(
                title: next(),
                startText: meeting.startText,
                endText: meeting.endText,
                timeZoneIdentifier: meeting.timeZoneIdentifier,
                location: meeting.location,
                onlineMeetingURL: meeting.onlineMeetingURL,
                confidence: meeting.confidence
            )
        }
        let tags = semanticTagCandidates.map { $0.relabeled(next()) }
        return InterpretationResult(
            classificationCandidates: classificationCandidates,
            triageVerdict: TriageVerdict(
                isActionable: triageVerdict.isActionable,
                requiresConfirmation: triageVerdict.requiresConfirmation,
                confidence: triageVerdict.confidence,
                action: action,
                acknowledgement: acknowledgement,
                extractionVersion: triageVerdict.extractionVersion
            ),
            meeting: meeting,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: tags
        )
    }
}

public extension InterpretationMetadataResult {
    func finalizingDisplayLanguage(
        using guardrail: DisplayLanguageGuard,
        targetLanguage: SummarizationTargetLanguage,
        source: DisplayLanguageGuard.Source
    ) async -> InterpretationMetadataResult {
        let labels = semanticTagCandidates.map(\.preferredLabel)
        guard DisplayLanguageGuard.needsResolution(labels, targetLanguage: targetLanguage) else { return self }
        let resolved = await guardrail.resolve(labels, targetLanguage: targetLanguage, source: source).fields
        return InterpretationMetadataResult(
            classificationCandidates: classificationCandidates,
            customCategoryKeys: customCategoryKeys,
            semanticTagCandidates: zip(semanticTagCandidates, resolved).map { $0.relabeled($1) }
        )
    }
}

extension SemanticTagCandidate {
    /// A translated preferred label keeps the original wording as an alias,
    /// so the tag still matches mail that uses the source term.
    func relabeled(_ label: String) -> SemanticTagCandidate {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != preferredLabel else { return self }
        return SemanticTagCandidate(
            preferredLabel: trimmed,
            sourceForms: [preferredLabel] + sourceForms,
            qualifiers: qualifiers,
            centrality: centrality,
            roles: roles,
            confidence: confidence
        )
    }
}
