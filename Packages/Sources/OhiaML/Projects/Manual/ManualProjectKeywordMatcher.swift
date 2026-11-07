import Foundation
import OhiaCore

public enum ManualProjectKeywordMatcher {
    public static func matches(
        values: [String],
        quantifier: MailProjectValueQuantifier,
        scopes: Set<MailProjectKeywordScope>,
        operator keywordOperator: MailProjectKeywordOperator,
        message: MailProjectMessageSnapshot
    ) -> Bool {
        evaluate(
            values: values,
            quantifier: quantifier,
            scopes: scopes,
            operator: keywordOperator,
            message: message,
            pendingFacets: []
        ) == .matches
    }

    static func evaluate(
        values: [String],
        quantifier: MailProjectValueQuantifier,
        scopes: Set<MailProjectKeywordScope>,
        operator keywordOperator: MailProjectKeywordOperator,
        message: MailProjectMessageSnapshot
    ) -> ManualProjectRuleMatchEvaluation {
        let pendingFacets = Set(selectedScopes(scopes).compactMap { scope in
            let facet = facet(for: scope)
            return message.readinessByFacet[facet] == .pendingForNewMessage ? facet : nil
        })
        return evaluate(
            values: values,
            quantifier: quantifier,
            scopes: scopes,
            operator: keywordOperator,
            message: message,
            pendingFacets: pendingFacets
        )
    }

    private static let fixedLocale = Locale(identifier: "en_US_POSIX")

    private static func evaluate(
        values: [String],
        quantifier: MailProjectValueQuantifier,
        scopes: Set<MailProjectKeywordScope>,
        operator keywordOperator: MailProjectKeywordOperator,
        message: MailProjectMessageSnapshot,
        pendingFacets: Set<MailProjectRuleFacet>
    ) -> ManualProjectRuleMatchEvaluation {
        guard values.isEmpty == false else { return .doesNotMatch }

        let valueEvaluations = values.map { value in
            evaluate(
                value: value,
                scopes: selectedScopes(scopes),
                operator: keywordOperator,
                message: message,
                pendingFacets: pendingFacets
            )
        }
        return switch quantifier {
        case .any: disjunction(valueEvaluations)
        case .all: conjunction(valueEvaluations)
        }
    }

    private static func evaluate(
        value: String,
        scopes: Set<MailProjectKeywordScope>,
        operator keywordOperator: MailProjectKeywordOperator,
        message: MailProjectMessageSnapshot,
        pendingFacets: Set<MailProjectRuleFacet>
    ) -> ManualProjectRuleMatchEvaluation {
        disjunction(scopes.map { scope in
            let scopeFacet = facet(for: scope)
            if pendingFacets.contains(scopeFacet) {
                return .pending([scopeFacet])
            }
            let scopeMatches = fields(for: scope, message: message)
                .map(normalize)
                .contains { field in
                    matches(value: value, field: field, operator: keywordOperator)
                }
            return scopeMatches ? .matches : .doesNotMatch
        })
    }

    private static func disjunction(
        _ evaluations: [ManualProjectRuleMatchEvaluation]
    ) -> ManualProjectRuleMatchEvaluation {
        var pendingFacets: Set<MailProjectRuleFacet> = []
        for evaluation in evaluations {
            switch evaluation {
            case .matches:
                return .matches
            case .doesNotMatch:
                break
            case let .pending(facets):
                pendingFacets.formUnion(facets)
            }
        }
        return pendingFacets.isEmpty ? .doesNotMatch : .pending(pendingFacets)
    }

    private static func conjunction(
        _ evaluations: [ManualProjectRuleMatchEvaluation]
    ) -> ManualProjectRuleMatchEvaluation {
        var pendingFacets: Set<MailProjectRuleFacet> = []
        for evaluation in evaluations {
            switch evaluation {
            case .matches:
                break
            case .doesNotMatch:
                return .doesNotMatch
            case let .pending(facets):
                pendingFacets.formUnion(facets)
            }
        }
        return pendingFacets.isEmpty ? .matches : .pending(pendingFacets)
    }

    private static func selectedScopes(
        _ scopes: Set<MailProjectKeywordScope>
    ) -> Set<MailProjectKeywordScope> {
        scopes.isEmpty ? [.subject, .body] : scopes
    }

    private static func facet(for scope: MailProjectKeywordScope) -> MailProjectRuleFacet {
        switch scope {
        case .subject: .subject
        case .body: .body
        case .attachmentFilename: .attachmentFilename
        case .attachmentText: .attachmentText
        }
    }

    private static func fields(
        for scope: MailProjectKeywordScope,
        message: MailProjectMessageSnapshot
    ) -> [String] {
        switch scope {
        case .subject: [message.subject]
        case .body: [message.body]
        case .attachmentFilename: message.attachmentFilenames
        case .attachmentText: message.attachmentTexts
        }
    }

    private static func matches(
        value: String,
        field: String,
        operator keywordOperator: MailProjectKeywordOperator
    ) -> Bool {
        let normalizedValue = normalize(value)
        guard normalizedValue.isEmpty == false else { return false }

        switch keywordOperator {
        case .containsPhrase:
            return field.contains(normalizedValue)
        case .anyWord:
            let ruleWords = words(in: normalizedValue)
            guard ruleWords.isEmpty == false else { return false }
            return ruleWords.isDisjoint(with: words(in: field)) == false
        case .allWords:
            let ruleWords = words(in: normalizedValue)
            guard ruleWords.isEmpty == false else { return false }
            return ruleWords.isSubset(of: words(in: field))
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: fixedLocale)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func words(in value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.isEmpty == false })
    }
}

enum ManualProjectRuleMatchEvaluation: Sendable, Equatable {
    case matches
    case doesNotMatch
    case pending(Set<MailProjectRuleFacet>)
}
