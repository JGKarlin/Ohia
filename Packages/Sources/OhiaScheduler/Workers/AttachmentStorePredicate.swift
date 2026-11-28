import Foundation
import OhiaCore

/// The pieces the attachment extraction workers build their store
/// predicates from: comparisons of `Attachment`'s optional columns with
/// constants, joined by `||` and `&&`. Written as expressions because
/// `#Predicate` with that many alternatives takes the type checker too long.
/// Comparisons follow the store's SQL: `!=` does not match a missing value.
enum AttachmentStorePredicate {
    typealias Condition = any StandardPredicateExpression<Bool>
    typealias Row = PredicateExpressions.Variable<Attachment>

    static func column<Value: Codable & Sendable & Equatable>(
        _ row: Row,
        _ keyPath: KeyPath<Attachment, Value?> & Sendable,
        is value: Value?
    ) -> Condition {
        PredicateExpressions.Equal(
            lhs: PredicateExpressions.KeyPath(root: row, keyPath: keyPath),
            rhs: PredicateExpressions.Value(value)
        )
    }

    static func column<Value: Codable & Sendable & Equatable>(
        _ row: Row,
        _ keyPath: KeyPath<Attachment, Value?> & Sendable,
        isNot value: Value?
    ) -> Condition {
        PredicateExpressions.NotEqual(
            lhs: PredicateExpressions.KeyPath(root: row, keyPath: keyPath),
            rhs: PredicateExpressions.Value(value)
        )
    }

    static func any(_ first: Condition, _ rest: Condition...) -> Condition {
        rest.reduce(first) { either($0, $1) }
    }

    static func all(_ first: Condition, _ rest: Condition...) -> Condition {
        rest.reduce(first) { both($0, $1) }
    }

    private static func either(_ lhs: Condition, _ rhs: Condition) -> Condition {
        func join<L: StandardPredicateExpression<Bool>, R: StandardPredicateExpression<Bool>>(
            _ lhs: L,
            _ rhs: R
        ) -> Condition {
            PredicateExpressions.Disjunction(lhs: lhs, rhs: rhs)
        }
        return join(lhs, rhs)
    }

    private static func both(_ lhs: Condition, _ rhs: Condition) -> Condition {
        func join<L: StandardPredicateExpression<Bool>, R: StandardPredicateExpression<Bool>>(
            _ lhs: L,
            _ rhs: R
        ) -> Condition {
            PredicateExpressions.Conjunction(lhs: lhs, rhs: rhs)
        }
        return join(lhs, rhs)
    }
}
