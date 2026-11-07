import Foundation

/// One of the six whole-email controls that a revision instruction can
/// change. These cases deliberately mirror `StyleAxisValues` without making
/// the UI's slider type part of the model layer.
public enum StyleRevisionAxis: String, CaseIterable, Sendable {
    case detail
    case formality
    case urgency
    case technicality
    case warmth
    case seriousness
}

/// The exact draft-local controls produced by interpreting a revision.
public struct StyleRevisionResolution: Equatable, Sendable {
    public let effectiveAxes: StyleAxisValues
    public let changedAxes: Set<StyleRevisionAxis>

    public init(effectiveAxes: StyleAxisValues, changedAxes: Set<StyleRevisionAxis>) {
        self.effectiveAxes = effectiveAxes
        self.changedAxes = changedAxes
    }
}

/// Reconciles clear whole-email style requests with the six visible controls.
///
/// The current body is the reference for every axis named by the instruction;
/// pending slider choices remain selected for axes the instruction does not
/// touch. Local passage requests are intentionally left in prose because a
/// whole-email slider would misrepresent requests such as "make the closing
/// warmer" or "add more detail about Mexico."
public enum StyleRevisionInstructionReconciler {
    private enum Direction: Int {
        case lower = -1
        case higher = 1
    }

    private struct Adjustment {
        let direction: Direction
        let targetPoint: Int?
        let steps: Int
    }

    private struct DirectionMatch {
        let direction: Direction
        let range: Range<String.Index>
    }

    private struct ScopedClause {
        let text: String
        let isExcluded: Bool
    }

    public static func resolve(
        instruction: String,
        currentAxes: StyleAxisValues,
        selectedAxes: StyleAxisValues
    ) -> StyleRevisionResolution? {
        var adjustments: [StyleRevisionAxis: Adjustment] = [:]

        for scopedClause in scopedClauses(in: instruction) where scopedClause.isExcluded == false {
            let clause = scopedClause.text
            for axis in StyleRevisionAxis.allCases {
                if let targetPoint = explicitPoint(for: axis, in: clause) {
                    adjustments[axis] = Adjustment(
                        direction: targetPoint >= displayPoint(value(for: axis, in: currentAxes))
                            ? .higher
                            : .lower,
                        targetPoint: targetPoint,
                        steps: 0
                    )
                    continue
                }
                guard let directionMatch = directionMatch(for: axis, in: clause) else { continue }
                let modifiers = modifiers(for: directionMatch, in: clause)
                adjustments[axis] = Adjustment(
                    direction: directionMatch.direction,
                    targetPoint: modifiers.reachesEndpoint
                        ? (directionMatch.direction == .higher ? 10 : 1)
                        : nil,
                    steps: modifiers.isIntensified ? 2 : 1
                )
            }
        }

        guard adjustments.isEmpty == false else { return nil }

        var resolved = selectedAxes
        var changedAxes = Set<StyleRevisionAxis>()
        for axis in StyleRevisionAxis.allCases {
            guard let adjustment = adjustments[axis] else { continue }
            let reference = value(for: axis, in: currentAxes)
            let target = adjustedValue(from: reference, adjustment: adjustment)
            guard abs(target - value(for: axis, in: resolved)) > 0.0001 else { continue }
            resolved = replacing(axis, in: resolved, with: target)
            changedAxes.insert(axis)
        }

        guard changedAxes.isEmpty == false else { return nil }
        return StyleRevisionResolution(effectiveAxes: resolved, changedAxes: changedAxes)
    }

    /// Conjunctions inherit a local or negated scope until the user starts a
    /// new explicit command. This keeps "make the opening warmer and
    /// friendlier" local while still allowing "add detail about X and make it
    /// shorter" to start a new whole-email request.
    private static func scopedClauses(in instruction: String) -> [ScopedClause] {
        let normalized = instruction
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let segments = normalized
            .replacingOccurrences(of: #"[\n;.!?]+"#, with: "|", options: .regularExpression)
            .split(separator: "|")

        return segments.flatMap { segment -> [ScopedClause] in
            let clauses = String(segment)
                .replacingOccurrences(
                    of: #",+|\b(and|but|while|also|or)\b"#,
                    with: "|",
                    options: .regularExpression
                )
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            var localScope = false
            var negatedScope = false
            return clauses.map { clause in
                if startsNewCommand(clause) {
                    localScope = false
                    negatedScope = false
                }
                if isLocalPassageRequest(clause) {
                    localScope = true
                }
                if isNegatedRequest(clause) {
                    negatedScope = true
                }
                return ScopedClause(
                    text: clause,
                    isExcluded: localScope || negatedScope
                )
            }
        }
    }

    private static func startsNewCommand(_ clause: String) -> Bool {
        matches(
            clause,
            patterns: [#"\b(make|keep|sound|write|rewrite|set|move|change|put|shorten|condense|trim|expand|elaborate|soften|reduce|lower|heighten|increase|raise|explain)\b"#]
        )
    }

    private static func isLocalPassageRequest(_ clause: String) -> Bool {
        matches(
            clause,
            patterns: [
                #"\b(about|regarding|concerning)\b"#,
                #"\b(paragraph|sentence|section|passage|opening|greeting|closing|sign[ -]?off|subject line|headline|bullet|list|first line|last line|explanation|description)\b"#,
            ]
        )
    }

    /// A deterministic mapper must never turn a negated instruction into the
    /// opposite slider choice. Leave these clauses in prose for the model,
    /// whose revision instruction already outranks the style controls.
    private static func isNegatedRequest(_ clause: String) -> Bool {
        matches(
            clause,
            patterns: [#"\b(do\s+not|don['’]?t|not|never|avoid|without)\b"#]
        )
    }

    private static func directionMatch(
        for axis: StyleRevisionAxis,
        in clause: String
    ) -> DirectionMatch? {
        let lowerPatterns: [String]
        let higherPatterns: [String]

        switch axis {
        case .detail:
            lowerPatterns = [
                #"\b(shorter|briefer|more concise|less detailed|less verbose|less wordy)\b"#,
                #"\b(shorten|condense|trim)\b(?:\s+(it|the (email|draft|message)))?\b"#,
                #"\b(make|keep|write|rewrite)\b.{0,28}\b(short|brief|concise|compact)\b"#,
            ]
            higherPatterns = [
                #"\b(longer|more detailed|more thorough|more expansive|more verbose|less concise|less brief)\b"#,
                #"\b(expand|elaborate)\b(?:\s+(it|the (email|draft|message)))?\b"#,
                #"\b(make|write|rewrite)\b.{0,28}\b(long|detailed|thorough|expansive)\b"#,
            ]
        case .formality:
            lowerPatterns = [
                #"\b(less formal|less polite|more casual|more direct|more conversational)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(casual|direct|conversational)\b"#,
            ]
            higherPatterns = [
                #"\b(more formal|more polite|less casual|less direct|more professional)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(formal|polite|professional)\b"#,
            ]
        case .urgency:
            lowerPatterns = [
                #"\b(less urgent|more relaxed|less pressing|more unhurried|no rush)\b"#,
                #"\b(soften|reduce|lower)\b.{0,20}\b(urgency|pressure)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(relaxed|unhurried)\b"#,
            ]
            higherPatterns = [
                #"\b(more urgent|less relaxed|more pressing|time[ -]sensitive|stronger urgency)\b"#,
                #"\b(heighten|increase|raise)\b.{0,20}\b(urgency|pressure)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(urgent|pressing|time[ -]sensitive)\b"#,
            ]
        case .technicality:
            lowerPatterns = [
                #"\b(less technical|less dense|more plain|plainer|simpler language|more accessible|less jargon|non[ -]?technical)\b"#,
                #"\b(explain|write|rewrite)\b.{0,28}\b(simply|plainly|accessibly)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(plain|simple|accessible|non[ -]?technical)\b"#,
            ]
            higherPatterns = [
                #"\b(more technical|more dense|more specialized|more specialist|more expert|less plain)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(technical|dense|specialist|expert[ -]level)\b"#,
            ]
        case .warmth:
            lowerPatterns = [
                #"\b(less warm|cooler|more reserved|more neutral|less emotional|less friendly)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(cool|reserved|neutral|detached)\b"#,
            ]
            higherPatterns = [
                #"\b(warmer|more warm|friendlier|more friendly|more empathetic|more appreciative|more personable|less reserved|more emotional)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(warm|friendly|empathetic|appreciative|personable)\b"#,
            ]
        case .seriousness:
            lowerPatterns = [
                #"\b(less serious|more humorous|funnier|more playful|lighter tone|less sober|add humor|add a joke)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(humorous|funny|playful|lighthearted)\b"#,
            ]
            higherPatterns = [
                #"\b(more serious|less humorous|less funny|less playful|more sober|no jokes|remove humor)\b"#,
                #"\b(make|keep|sound|write|rewrite)\b.{0,28}\b(serious|sober|restrained)\b"#,
            ]
        }

        if let range = firstMatch(in: clause, patterns: lowerPatterns) {
            return DirectionMatch(direction: .lower, range: range)
        }
        if let range = firstMatch(in: clause, patterns: higherPatterns) {
            return DirectionMatch(direction: .higher, range: range)
        }
        return nil
    }

    private static func modifiers(
        for directionMatch: DirectionMatch,
        in clause: String
    ) -> (reachesEndpoint: Bool, isIntensified: Bool) {
        let matchedText = String(clause[directionMatch.range])
        let prefix = String(clause[..<directionMatch.range.lowerBound])
        let suffix = String(clause[directionMatch.range.upperBound...])
        let intensityPattern = #"\b(much|very|far|substantially|significantly|considerably|extremely)\b"#
        let endpointPattern = #"\b(maximum|maximally|completely|entirely)\b"#

        let isIntensified = matches(matchedText, patterns: [intensityPattern])
            || matches(prefix, patterns: [intensityPattern + #"\s*$"#])
        let reachesEndpoint = matches(matchedText, patterns: [endpointPattern])
            || matches(prefix, patterns: [endpointPattern + #"\s*$"#])
            || matches(suffix, patterns: [#"^\s*"# + endpointPattern])
            || (
                matches(matchedText, patterns: [#"\bas\b"#])
                    && matches(suffix, patterns: [#"^\s+as possible\b"#])
            )
        return (reachesEndpoint, isIntensified)
    }

    private static func explicitPoint(
        for axis: StyleRevisionAxis,
        in clause: String
    ) -> Int? {
        let label: String
        switch axis {
        case .detail: label = #"(?:length|detail)"#
        case .formality: label = "formality"
        case .urgency: label = "urgency"
        case .technicality: label = "technicality"
        case .warmth: label = "warmth"
        case .seriousness: label = "seriousness"
        }
        let pattern = #"\b(?:set|move|change|put|make)?\s*(?:the\s+)?"#
            + label
            + #"\s*(?:slider\s*)?(?:to|at|=)?\s*([1-9]|10)(?:\s*/\s*10)?\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: clause,
                range: NSRange(clause.startIndex..., in: clause)
              ),
              let range = Range(match.range(at: 1), in: clause),
              let point = Int(clause[range])
        else { return nil }
        return point
    }

    private static func matches(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func firstMatch(
        in text: String,
        patterns: [String]
    ) -> Range<String.Index>? {
        patterns.lazy.compactMap {
            text.range(of: $0, options: .regularExpression)
        }.first
    }

    private static func adjustedValue(from value: Double, adjustment: Adjustment) -> Double {
        if let targetPoint = adjustment.targetPoint {
            return Double(targetPoint - 1) / 9.0
        }
        let currentPoint = displayPoint(value)
        let targetPoint = min(10, max(1, currentPoint + adjustment.direction.rawValue * adjustment.steps))
        return Double(targetPoint - 1) / 9.0
    }

    private static func displayPoint(_ value: Double) -> Int {
        min(10, max(1, Int((value * 9).rounded()) + 1))
    }

    private static func value(for axis: StyleRevisionAxis, in axes: StyleAxisValues) -> Double {
        switch axis {
        case .detail: axes.detail
        case .formality: axes.formality
        case .urgency: axes.urgency
        case .technicality: axes.technicality
        case .warmth: axes.warmth
        case .seriousness: axes.seriousness
        }
    }

    private static func replacing(
        _ axis: StyleRevisionAxis,
        in axes: StyleAxisValues,
        with value: Double
    ) -> StyleAxisValues {
        StyleAxisValues(
            detail: axis == .detail ? value : axes.detail,
            formality: axis == .formality ? value : axes.formality,
            urgency: axis == .urgency ? value : axes.urgency,
            technicality: axis == .technicality ? value : axes.technicality,
            warmth: axis == .warmth ? value : axes.warmth,
            seriousness: axis == .seriousness ? value : axes.seriousness
        )
    }
}

public extension Draft {
    /// Stages the one resolved preference that a revision and any pending
    /// sliders jointly express. The instruction owns only the axes it names;
    /// all other axes retain the pending slider selection.
    @discardableResult
    func stageRevisionStyleControlDecision(
        instruction: String,
        registerID: UUID?,
        registerRevision: Int?,
        defaults: StyleAxisValues?
    ) -> StyleControlSnapshot? {
        let matchingPending = pendingStyleControlSnapshot.flatMap {
            $0.registerID == registerID ? $0 : nil
        }
        let matchingApplied = styleControlSnapshot.flatMap {
            $0.registerID == registerID ? $0 : nil
        }
        guard let baseAxes = defaults
                ?? matchingPending?.baseAxes
                ?? matchingApplied?.baseAxes
                ?? styleControlSnapshot?.baseAxes
        else { return nil }
        let currentAxes = styleControlSnapshot?.effectiveAxes
            ?? matchingApplied?.effectiveAxes
            ?? baseAxes
        let selectedAxes = matchingPending?.effectiveAxes
            ?? matchingApplied?.effectiveAxes
            ?? baseAxes

        guard let resolution = StyleRevisionInstructionReconciler.resolve(
            instruction: instruction,
            currentAxes: currentAxes,
            selectedAxes: selectedAxes
        ) else { return nil }

        let source: StyleControlDecisionSource = matchingPending?.isExplicitPreference == true
            ? .slidersAndRevisionInstruction
            : .revisionInstruction
        let snapshot: StyleControlSnapshot
        if resolution.effectiveAxes.differs(from: baseAxes, tolerance: 0.0001) {
            snapshot = .explicitOverride(
                registerID: registerID,
                registerRevision: registerRevision,
                defaults: baseAxes,
                effectiveAxes: resolution.effectiveAxes,
                decisionSource: source
            )
        } else {
            snapshot = .explicitReset(
                registerID: registerID,
                registerRevision: registerRevision,
                defaults: baseAxes,
                decisionSource: source
            )
        }
        pendingStyleControlSnapshot = snapshot
        return snapshot
    }
}
