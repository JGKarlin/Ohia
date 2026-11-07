import Foundation

public extension MemoryDistiller {
    /// Renders the reader-facing fields of generated add and split operations
    /// (text, futureUse, conditions) into the reading language before they are
    /// applied, so dedup and curation keys are computed on the text the user
    /// sees. An add or split part without its own conditions inherits the
    /// cited clusters' conditions exactly as `apply` would, rendered the same
    /// way. A field whose source-language passage could not be translated
    /// keeps its generated wording, never a romanization.
    static func displayingLanguage(
        _ operations: [Operation],
        clusters: [CandidateCluster],
        using guardrail: DisplayLanguageGuard,
        targetLanguage: SummarizationTargetLanguage,
        source: DisplayLanguageGuard.Source
    ) async -> [Operation] {
        let clusterByIndex = Dictionary(clusters.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        func inheritedConditions(_ from: [Int]?) -> String? {
            let sources = Array(Set(from ?? [])).sorted().compactMap { clusterByIndex[$0] }
            return sources.lazy
                .compactMap { $0.claim.conditionsText?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.isEmpty == false }
        }

        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
                return nil
            }
            return value
        }

        var fields: [String] = []
        for operation in operations {
            switch operation.op {
            case "add":
                fields.append(operation.text ?? "")
                fields.append(operation.futureUse ?? "")
                fields.append(nonEmpty(operation.conditions) ?? inheritedConditions(operation.from) ?? "")
            case "split":
                for part in operation.into ?? [] {
                    fields.append(part.text)
                    fields.append(part.futureUse ?? "")
                    fields.append(nonEmpty(part.conditions) ?? inheritedConditions(part.from) ?? "")
                }
            default:
                continue
            }
        }
        guard DisplayLanguageGuard.needsResolution(fields, targetLanguage: targetLanguage) else { return operations }
        var resolved = await guardrail.resolve(fields, targetLanguage: targetLanguage, source: source).fields[...]
        func next(_ original: String?) -> String? {
            let value = resolved.popFirst() ?? original ?? ""
            return original == nil && value.isEmpty ? nil : value
        }

        return operations.map { operation in
            switch operation.op {
            case "add":
                let text = next(operation.text)
                let futureUse = next(operation.futureUse)
                let conditions = next(nonEmpty(operation.conditions) ?? inheritedConditions(operation.from))
                return Operation(
                    op: operation.op, memory: operation.memory, text: text, kind: operation.kind,
                    from: operation.from, subject: operation.subject, assertedBy: operation.assertedBy,
                    direction: operation.direction, origin: operation.origin, asOf: operation.asOf,
                    expires: operation.expires, conditions: conditions, futureUse: futureUse,
                    formationBasis: operation.formationBasis, usePolicy: operation.usePolicy,
                    scopes: operation.scopes, into: operation.into
                )
            case "split":
                let parts = operation.into?.map { part in
                    let text = next(part.text) ?? part.text
                    let futureUse = next(part.futureUse)
                    let conditions = next(nonEmpty(part.conditions) ?? inheritedConditions(part.from))
                    return Operation.SplitPart(
                        text: text,
                        kind: part.kind,
                        from: part.from,
                        subject: part.subject,
                        conditions: conditions,
                        futureUse: futureUse,
                        formationBasis: part.formationBasis,
                        usePolicy: part.usePolicy
                    )
                }
                return Operation(
                    op: operation.op, memory: operation.memory, text: operation.text, kind: operation.kind,
                    from: operation.from, subject: operation.subject, assertedBy: operation.assertedBy,
                    direction: operation.direction, origin: operation.origin, asOf: operation.asOf,
                    expires: operation.expires, conditions: operation.conditions, futureUse: operation.futureUse,
                    formationBasis: operation.formationBasis, usePolicy: operation.usePolicy,
                    scopes: operation.scopes, into: parts
                )
            default:
                return operation
            }
        }
    }
}
