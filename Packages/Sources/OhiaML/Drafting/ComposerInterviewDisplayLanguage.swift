import Foundation

/// Interview questions and their option labels and details are read by the
/// author in the reading language. Node and option identifiers, routing,
/// conditions (keyed by option id), and draft effects are never rewritten. A
/// field whose source-language passage could not be translated keeps its
/// generated wording, never a romanization.
extension Array where Element == ComposerInterviewNode {
    func displayingLanguage(
        using guardrail: DisplayLanguageGuard,
        targetLanguage: SummarizationTargetLanguage,
        source: DisplayLanguageGuard.Source,
        cancellation: GenerationCancellation
    ) -> [ComposerInterviewNode] {
        var fields: [String] = []
        for node in self where node.kind == .question {
            fields.append(node.text ?? "")
            for option in node.options {
                fields.append(option.label)
                fields.append(option.detail ?? "")
            }
        }
        guard DisplayLanguageGuard.needsResolution(fields, targetLanguage: targetLanguage) else { return self }
        let resolved = guardrail.resolveSynchronously(
            fields,
            targetLanguage: targetLanguage,
            source: source,
            cancellation: cancellation
        ).fields
        guard resolved.count == fields.count else { return self }

        var next = resolved.makeIterator()
        return map { node in
            guard node.kind == .question else { return node }
            let text = next.next() ?? node.text ?? ""
            let options = node.options.map { option in
                let label = next.next() ?? option.label
                let detail = next.next() ?? option.detail ?? ""
                return ComposerInterviewOption(
                    id: option.id,
                    kind: option.kind,
                    label: label,
                    detail: option.detail == nil ? nil : detail,
                    nextNodeID: option.nextNodeID,
                    draftEffects: option.draftEffects
                )
            }
            return ComposerInterviewNode(
                id: node.id,
                kind: node.kind,
                variableID: node.variableID,
                scope: node.scope,
                authority: node.authority,
                text: node.text == nil ? nil : text,
                responseType: node.responseType,
                options: options,
                answeredNextNodeID: node.answeredNextNodeID,
                skipNextNodeID: node.skipNextNodeID,
                impactWeight: node.impactWeight,
                condition: node.condition
            )
        }
    }
}
