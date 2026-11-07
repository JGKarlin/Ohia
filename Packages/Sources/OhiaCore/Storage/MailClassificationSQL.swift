import Foundation

/// SQLite predicates that mirror the purpose-only `MailClassificationJSON`
/// document contract.
public enum MailClassificationSQL {
    public enum PredicateError: Error, Equatable {
        case invalidColumnReference(String)
    }

    public static func completePredicate(columnReference value: String) throws -> String {
        guard isQualifiedIdentifier(value) else {
            throw PredicateError.invalidColumnReference(value)
        }
        let canonicalPurposes = MailPurpose.allCases
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
        let necessaryPurposeRuleCase = MailPurpose.allCases.map { purpose in
            let ruleID = MailClassificationRuleInventory.necessaryPurposeRuleID[purpose] ?? ""
            return "WHEN '\(purpose.rawValue)' THEN '\(ruleID)'"
        }.joined(separator: " ")
        let requiredKeys = [
            "status", "purpose", "purposeConfidence", "purposeCandidates",
            "evidence", "classifierVersion", "resolverVersion",
        ].map { "'\($0)'" }.joined(separator: ", ")
        // JSON-quote text before applying SQLite's byte-oriented GLOB. This
        // exposes embedded NUL/control characters as escapes instead of
        // letting LENGTH/GLOB stop at the first NUL byte.
        func quotedTextBody(_ expression: String) -> String {
            "SUBSTR(json_quote(\(expression)), 2, LENGTH(json_quote(\(expression))) - 2)"
        }
        let candidateRuleBody = quotedTextBody("rule.value")
        let evidenceRuleBody = quotedTextBody("json_extract(item.value, '$.ruleID')")
        let classifierVersionBody = quotedTextBody("json_extract(\(value), '$.classifierVersion')")
        let resolverVersionBody = quotedTextBody("json_extract(\(value), '$.resolverVersion')")

        return """
        CASE
        WHEN \(value) IS NULL
          OR LENGTH(TRIM(\(value))) = 0
          OR NOT json_valid(\(value))
        THEN 0
        ELSE (
        json_type(\(value)) = 'object'
        AND (SELECT COUNT(*) FROM json_each(\(value))) = 7
        AND NOT EXISTS (
            SELECT 1 FROM json_each(\(value)) root
            WHERE root.key NOT IN (\(requiredKeys))
        )
        AND json_extract(\(value), '$.status') IN ('classified', 'uncertain', 'deterministicFallback')
        AND json_type(\(value), '$.purposeCandidates') = 'array'
        AND json_array_length(\(value), '$.purposeCandidates') <= \(MailClassificationJSON.maximumPurposeCandidates)
        AND NOT EXISTS (
            SELECT 1 FROM json_each(\(value), '$.purposeCandidates') candidate
            WHERE CASE WHEN candidate.type != 'object' THEN 1 ELSE (
                (SELECT COUNT(*) FROM json_each(candidate.value))
                    != (SELECT COUNT(DISTINCT key) FROM json_each(candidate.value))
                OR COALESCE(json_extract(candidate.value, '$.purpose') NOT IN (\(canonicalPurposes)), 1)
                OR COALESCE(json_type(candidate.value, '$.confidence') NOT IN ('integer', 'real'), 1)
                OR COALESCE(json_extract(candidate.value, '$.confidence') NOT BETWEEN 0 AND 1, 1)
                OR COALESCE(json_type(candidate.value, '$.ruleIDs') != 'array', 1)
                OR EXISTS (
                    SELECT 1 FROM json_each(candidate.value, '$.ruleIDs') rule
                    WHERE rule.type != 'text'
                       OR \(candidateRuleBody) GLOB '*[^A-Za-z0-9._-]*'
                       OR LENGTH(\(candidateRuleBody)) = 0
                )
            ) END
        )
        AND json_type(\(value), '$.evidence') = 'array'
        AND json_array_length(\(value), '$.evidence') <= \(MailClassificationJSON.maximumEvidenceRecords)
        AND NOT EXISTS (
            SELECT 1 FROM json_each(\(value), '$.evidence') item
            WHERE CASE WHEN item.type != 'object' THEN 1 ELSE (
               (SELECT COUNT(*) FROM json_each(item.value))
                    != (SELECT COUNT(DISTINCT key) FROM json_each(item.value))
               OR COALESCE(json_extract(item.value, '$.purpose') NOT IN (\(canonicalPurposes)), 1)
               OR COALESCE(json_type(item.value, '$.ruleID') != 'text', 1)
               OR COALESCE(LENGTH(\(evidenceRuleBody)) = 0, 1)
               OR COALESCE(\(evidenceRuleBody) GLOB '*[^A-Za-z0-9._-]*', 1)
               OR COALESCE(json_extract(item.value, '$.ruleID') != CASE json_extract(item.value, '$.purpose')
                   \(necessaryPurposeRuleCase)
                   END, 1)
               OR COALESCE(json_extract(item.value, '$.polarity') NOT IN ('supporting', 'contradicting'), 1)
               OR COALESCE(json_type(item.value, '$.strength') NOT IN ('integer', 'real'), 1)
               OR COALESCE(json_extract(item.value, '$.strength') NOT BETWEEN 0 AND 1, 1)
               OR COALESCE(json_extract(item.value, '$.sourceKind') NOT IN ('header', 'recipient', 'mime', 'thread', 'correspondent', 'bodyStructure', 'model'), 1)
            ) END
        )
        AND json_type(\(value), '$.classifierVersion') = 'text'
        AND LENGTH(\(classifierVersionBody)) > 0
        AND \(classifierVersionBody) NOT GLOB '*[^A-Za-z0-9._-]*'
        AND json_type(\(value), '$.resolverVersion') = 'text'
        AND LENGTH(\(resolverVersionBody)) > 0
        AND \(resolverVersionBody) NOT GLOB '*[^A-Za-z0-9._-]*'
        AND (
            (
                json_extract(\(value), '$.status') = 'uncertain'
                AND json_type(\(value), '$.purpose') = 'null'
                AND json_type(\(value), '$.purposeConfidence') = 'null'
            )
            OR (
                json_extract(\(value), '$.status') = 'classified'
                AND json_extract(\(value), '$.purpose') IN (\(canonicalPurposes))
                AND json_type(\(value), '$.purposeConfidence') IN ('integer', 'real')
                AND json_extract(\(value), '$.purposeConfidence') BETWEEN 0 AND 1
            )
            OR (
                json_extract(\(value), '$.status') = 'deterministicFallback'
                AND json_extract(\(value), '$.purpose') IN (\(canonicalPurposes))
                AND json_type(\(value), '$.purposeConfidence') IN ('integer', 'real')
                AND json_extract(\(value), '$.purposeConfidence') BETWEEN 0 AND 1
                AND EXISTS (
                    SELECT 1 FROM json_each(\(value), '$.evidence') item
                    WHERE json_extract(item.value, '$.purpose') = json_extract(\(value), '$.purpose')
                      AND json_extract(item.value, '$.ruleID') = CASE json_extract(\(value), '$.purpose')
                          \(necessaryPurposeRuleCase)
                          END
                      AND json_extract(item.value, '$.polarity') = 'supporting'
                      AND json_extract(item.value, '$.sourceKind') IN ('header', 'recipient', 'mime', 'bodyStructure')
                )
            )
        )
        )
        END
        """
    }

    private static func isQualifiedIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.isEmpty == false else { return false }
        return parts.allSatisfy { part in
            guard let first = part.utf8.first,
                  first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
                return false
            }
            return part.utf8.dropFirst().allSatisfy { byte in
                byte == 95
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || (48...57).contains(byte)
            }
        }
    }
}
