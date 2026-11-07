import Foundation
import OSLog
import OhiaCore

/// Thread-unit discourse extraction contract. `ThreadDiscoursePrompt`
/// extracts selective, evidence-grounded durable guidance from a whole thread rendered by
/// `ThreadExtractionPacketBuilder`, then attributes each claim back to the
/// message its evidence quotes — so persistence stays per-message
/// (`MessageAnalysis.discourseMemoryJSON`) while the reasoning unit is the
/// thread.
///
/// The prompt text is the primary deliverable: it is language-neutral and
/// encodes the counterfactual admission test, the ascertainment rules, and the
/// rejection rules from the durable email-memory design. Individual malformed
/// or non-durable items are excluded and, when attributable, recorded as
/// `uncertainties` rather than aborting the whole extraction. Only
/// genuinely undecodable input throws.
///
/// Pure, deterministic, no I/O, no `Date()`.
public enum ThreadDiscoursePrompt {
    public static let extractionVersion = DiscourseMemory.threadVersion

    // Thread-level caps (see design §1 rejection/limits).
    static let maxClaims = 12
    static let maxSupersessions = 4
    static let maxUncertainties = 6
    // Clipping idioms for oversized model output.
    static let textClipLimit = 360
    static let quoteClipLimit = 280

    /// The durable-guidance taxonomy, keyed by a case-folded form so the model
    /// may vary casing without losing the kind. Unknown kinds fail closed.
    static let canonicalKinds: [String: String] = {
        var map: [String: String] = [:]
        for kind in AccountMemoryKind.all { map[kind.lowercased()] = kind }
        return map
    }()

    // MARK: - Prompt

    /// Build the static extraction prompt plus the thread INPUT block. The
    /// engine wraps this with its own role tokens; the text here is the
    /// contract the model must obey, verbatim across MLX and Apple Foundation.
    public static func makePrompt(
        packet: ThreadExtractionPacket,
        userAddresses: Set<String>,
        language: String?
    ) -> String {
        var lines: [String] = []

        // Block 1 — Role.
        lines.append("ROLE: You propose reusable guidance from ONE email thread belonging to one user.")
        lines.append("")

        // User + language context so the model can attribute sides correctly.
        let addresses = userAddresses.sorted()
        if addresses.isEmpty {
            lines.append("USER ADDRESSES: (none provided)")
        } else {
            lines.append("USER ADDRESSES: \(addresses.joined(separator: ", "))")
        }
        lines.append("THREAD LANGUAGE: \(language ?? "unknown — respond in the thread's own language")")
        lines.append("")

        lines.append("SELECTION PRIORITY:")
        lines.append("Most threads produce no memory candidates. Empty output is normal and preferred to a weak memory.")
        lines.append("Do not summarize the thread and do not create a candidate merely to cover an email.")
        lines.append("")

        // Block 2 — The counterfactual admission test.
        lines.append("ADMISSION TEST:")
        lines.append("Emit guidance ONLY if its absence could later cause a repeated correction, an unnecessary question, a violated norm, or an incorrect handling of future correspondence. If removing it would change nothing, do not emit it.")
        lines.append("")

        // Block 3 — Atomicity.
        lines.append("ATOMICITY:")
        lines.append("- Emit one reusable instruction or orientation per candidate.")
        lines.append("- State the conditions and scope under which it applies.")
        lines.append("- Each candidate must be self-contained in the thread's own language.")
        lines.append("")

        // Block 4 — Kinds.
        lines.append("KINDS (choose one per candidate):")
        lines.append("preference | relationship | roleResponsibility | norm | ruleConstraint | procedure | convention | orientation | learnedLesson")
        lines.append("")
        lines.append("FORMATION BASIS (choose one):")
        lines.append("explicitStanding | explicitCorrection | repeatedPattern")
        lines.append("")
        lines.append("USE POLICY (choose one):")
        lines.append("internalGuidance | draftingGuidance | contextualOrientation | assertableKnowledge")
        lines.append("")

        // Block 4b — Scopes.
        lines.append("SCOPES (optional per-claim {\"kind\",\"value\"} applicability hints; \"kind\" is one of):")
        lines.append("project | team | time | policy | amount | location | exception | classification | correspondent | language")
        lines.append("")

        // Block 5 — Ascertainment rules.
        lines.append("ASCERTAINMENT RULES:")
        lines.append("- One email may qualify when it explicitly establishes an enduring preference, rule, role, relationship, procedure, orientation, or correction.")
        lines.append("- An inferred pattern requires evidence from multiple independent threads; do not label repetition within one thread as repeatedPattern.")
        lines.append("- A request, proposal, completion, scheduled event, current status, or task is not reusable guidance.")
        lines.append("- Dates do not make an event durable.")
        lines.append("- Corrections may establish future guidance only when they clearly govern future handling.")
        lines.append("- quoted or forwarded text belongs to its original author, never the quoter.")
        lines.append("- Use internalGuidance for behavior that should guide reasoning but must never be stated to a recipient.")
        lines.append("")

        // Block 6 — Rejection rules.
        lines.append("REJECT (do not emit) any of the following:")
        lines.append("- email or thread summaries, objectives, and contextless fragments;")
        lines.append("- calendar events, deadlines, appointments, dinner plans, and scheduled meetings;")
        lines.append("- task completion, current project state, queue state, or temporary status;")
        lines.append("- one-off approvals, exceptions, waivers, decisions, and commitments;")
        lines.append("- biographical summaries, vague characterizations, and descriptions of general activity;")
        lines.append("- unsupported extrapolations or claims whose future applicability cannot be determined;")
        lines.append("- secrets or unnecessary personal data;")
        lines.append("- anything trivial to rediscover or unlikely to change future reasoning, questions, or drafts.")
        lines.append("")

        // Block 7 — Evidence.
        lines.append("EVIDENCE:")
        lines.append("- Every candidate carries at least one {\"message\": index, \"quote\": exact substring}.")
        lines.append("- The quote MUST appear verbatim in that message's body. Never paraphrase a quote.")
        lines.append("- message is the 1-based index shown in brackets in the THREAD block below.")
        lines.append("")

        // Block 8 — Caps.
        lines.append("LIMITS:")
        lines.append("- At most \(maxClaims) claims, \(maxSupersessions) supersessions, \(maxUncertainties) uncertainties per thread.")
        lines.append("- A candidate whose support is weaklyInferred goes to uncertainties, never to claims.")
        lines.append("")

        // Block 9 — Output.
        lines.append("OUTPUT: JSON only. No prose. No code fences.")
        lines.append("SCHEMA:")
        lines.append(schemaTemplate)
        lines.append("")

        // Thread INPUT.
        lines.append("THREAD — subject: \(packet.subject)")
        lines.append(packet.promptSection)

        return lines.joined(separator: "\n")
    }

    private static let schemaTemplate =
        """
        {"claims":[{"text":"…","kind":"preference","futureUse":"How this changes future handling",\
        "formationBasis":"explicitStanding|explicitCorrection|repeatedPattern",\
        "usePolicy":"internalGuidance|draftingGuidance|contextualOrientation|assertableKnowledge",\
        "isEpisodic":false,"subject":"…","assertedBy":"user|<address>|shared",\
        "direction":"sent|received","support":"explicitlyStated|stronglyImplied|repeatedPattern|weaklyInferred",\
        "confidence":0.9,"asOf":"2026-07-01","expires":null,"conditions":"…",\
        "scopes":[{"kind":"project","value":"…"}],\
        "evidence":[{"message":2,"quote":"exact words from that message"}]}],\
        "supersessions":[{"newer":"…","older":"…","message":3}],\
        "uncertainties":[{"question":"…","candidate":"…","message":1}]}
        """

    // MARK: - Parse

    /// Parse model JSON, enforce the contract, and attribute each item to its
    /// evidence message. Returns one `DiscourseMemory` per message that
    /// received at least one item; every returned memory is stamped
    /// `extractionVersion = threadVersion`, `threadFingerprint = packet.fingerprint`.
    ///
    /// A generation that hit its token budget mid-object fails the top-level
    /// decode; before giving up, one salvage pass is attempted (see
    /// `salvageTruncatedJSON`) that recovers whatever complete claims,
    /// supersessions, or uncertainties the model finished emitting and drops
    /// the trailing partial one. Only when salvage also fails to produce
    /// decodable JSON does this throw (no JSON object at all / genuinely
    /// undecodable at the top level even after salvage). Individual
    /// malformed items within a successfully decoded payload are demoted,
    /// not fatal.
    public static func parse(
        modelOutput: String,
        packet: ThreadExtractionPacket
    ) throws -> [UUID: DiscourseMemory] {
        let jsonText = try extractJSONObject(from: modelOutput)
        let output: ModelOutput
        do {
            output = try JSONDecoder().decode(ModelOutput.self, from: Data(jsonText.utf8))
        } catch {
            guard let salvaged = salvageParse(modelOutput) else {
                throw ThreadDiscoursePromptError.undecodable(String(describing: error))
            }
            threadDiscourseLogger.info("Thread discourse parse: salvaged truncated JSON output (claims=\(salvaged.claims?.count ?? 0, privacy: .public), supersessions=\(salvaged.supersessions?.count ?? 0, privacy: .public), uncertainties=\(salvaged.uncertainties?.count ?? 0, privacy: .public))")
            output = salvaged
        }

        // Body text keyed by message id, for verbatim quote containment.
        var bodyByID: [UUID: String] = [:]
        for message in packet.messages { bodyByID[message.messageID] = message.bodyText }

        var claimsByMessage: [UUID: [ClaimCandidate]] = [:]
        var tacitRulesByMessage: [UUID: [TacitRuleSignal]] = [:]
        var supersessionsByMessage: [UUID: [SupersessionSignal]] = [:]

        // Uncertainties are capped thread-wide; collect them ordered
        // (model-emitted first, then demoted claims — matching enforceContract)
        // and bucket after the cap.
        var modelUncertainties: [(UUID, Uncertainty)] = []
        var demotedUncertainties: [(UUID, Uncertainty)] = []

        // MARK: claims
        for claim in (output.claims ?? []).prefix(maxClaims) {
            let text = clip(claim.text ?? "", limit: textClipLimit)
            guard !text.isEmpty else { continue }

            // Resolve evidence: first in-range message (landing target for a
            // demotion), and the spans whose quote is actually present.
            var firstResolvableMessage: UUID?
            var firstSurvivingMessage: UUID?
            var survivingSpansByMessage: [UUID: [DiscourseEvidenceSpan]] = [:]
            for entry in claim.evidence ?? [] {
                guard let index = entry.message, let messageID = packet.messageIDByIndex[index] else { continue }
                if firstResolvableMessage == nil { firstResolvableMessage = messageID }
                let quote = clip(entry.quote ?? "", limit: quoteClipLimit)
                guard !quote.isEmpty else { continue }
                guard let body = bodyByID[messageID], body.contains(quote) else { continue }
                survivingSpansByMessage[messageID, default: []].append(
                    DiscourseEvidenceSpan(start: 0, end: 0, text: quote)
                )
                if firstSurvivingMessage == nil { firstSurvivingMessage = messageID }
            }
            let survivingSpans = survivingSpansByMessage.values.flatMap { $0 }

            let support = supportLevel(from: claim.support)
            let confidence = clampConfidence(claim.confidence)

            // Demotion 1: insufficient support.
            guard support.qualifiesAsCandidate else {
                if let target = firstResolvableMessage {
                    demotedUncertainties.append((target, Uncertainty(
                        question: "Weakly inferred — needs confirmation before use.",
                        candidate: text,
                        evidenceSpans: survivingSpans,
                        sourceField: .llmDirectExtraction
                    )))
                }
                continue
            }

            // Demotion 2: no evidence survived (missing or fabricated quote).
            guard let landing = firstSurvivingMessage, !survivingSpans.isEmpty else {
                if let target = firstResolvableMessage {
                    demotedUncertainties.append((target, Uncertainty(
                        question: "Claim evidence not found in the thread — needs confirmation.",
                        candidate: text,
                        evidenceSpans: survivingSpans,
                        sourceField: .llmDirectExtraction
                    )))
                }
                continue
            }

            let kind = canonicalKind(claim.kind)
            let futureUse = trimmedNonEmpty(claim.futureUse, limit: textClipLimit)
            let formationBasis = trimmedNonEmpty(claim.formationBasis, limit: textClipLimit)
            let usePolicy = trimmedNonEmpty(claim.usePolicy, limit: textClipLimit)

            // Fail closed: legacy claim-ledger fields, incomplete guidance,
            // and explicitly episodic items never become memory candidates.
            guard let kind,
                  let futureUse,
                  let formationBasis,
                  AccountMemoryFormationBasis.generated.contains(formationBasis),
                  let usePolicy,
                  AccountMemoryUsePolicy.all.contains(usePolicy),
                  claim.isEpisodic == false else {
                demotedUncertainties.append((landing, Uncertainty(
                    question: "Excluded from durable memory: unknown kind, incomplete guidance, or episodic content.",
                    candidate: text,
                    evidenceSpans: survivingSpans,
                    sourceField: .llmDirectExtraction
                )))
                continue
            }
            let assertedBy = normalizeAssertedBy(claim.assertedBy)
            // Persist one per-message candidate with only that message's exact
            // quotes. The assembler reunites them by claim identity, preserving
            // both message breadth and every cited passage without attributing
            // all thread evidence to the first message.
            for messageID in packet.messages.map(\.messageID) {
                guard let messageSpans = survivingSpansByMessage[messageID],
                      messageSpans.isEmpty == false else { continue }
                let candidate = ClaimCandidate(
                    text: text,
                    support: support,
                    confidence: confidence,
                    evidenceSpans: messageSpans,
                    scope: mapScopes(claim.scopes),
                    sourceField: .llmDirectExtraction,
                    kindRaw: kind,
                    subjectText: trimmedNonEmpty(claim.subject, limit: textClipLimit),
                    assertedBy: assertedBy,
                    directionRaw: trimmedNonEmpty(claim.direction, limit: textClipLimit),
                    asOf: parseDate(claim.asOf),
                    expiresAt: parseDate(claim.expires),
                    conditionsText: trimmedNonEmpty(claim.conditions, limit: textClipLimit),
                    futureUseText: futureUse,
                    formationBasisRaw: formationBasis,
                    usePolicyRaw: usePolicy,
                    isEpisodic: false
                )
                claimsByMessage[messageID, default: []].append(candidate)

                // Norms continue feeding the cross-thread signal path.
                if kind == AccountMemoryKind.norm {
                    tacitRulesByMessage[messageID, default: []].append(TacitRuleSignal(
                        rule: text,
                        pattern: .explicitNormLanguage,
                        support: support,
                        confidence: confidence,
                        evidenceSpans: messageSpans,
                        sourceField: .llmDirectExtraction
                    ))
                }
            }
        }

        // MARK: supersessions
        for supersession in (output.supersessions ?? []).prefix(maxSupersessions) {
            guard let index = supersession.message, let messageID = packet.messageIDByIndex[index] else { continue }
            let newer = clip(supersession.newer ?? "", limit: textClipLimit)
            guard !newer.isEmpty else { continue }
            supersessionsByMessage[messageID, default: []].append(SupersessionSignal(
                newerStatement: newer,
                olderHint: trimmedNonEmpty(supersession.older, limit: textClipLimit),
                support: .explicitlyStated,
                confidence: 0.9,
                evidenceSpans: [],
                sourceField: .llmDirectExtraction
            ))
        }

        // MARK: model uncertainties
        for uncertainty in output.uncertainties ?? [] {
            guard let index = uncertainty.message, let messageID = packet.messageIDByIndex[index] else { continue }
            let candidate = clip(uncertainty.candidate ?? "", limit: textClipLimit)
            let question = clip(uncertainty.question ?? "", limit: textClipLimit)
            guard !candidate.isEmpty || !question.isEmpty else { continue }
            modelUncertainties.append((messageID, Uncertainty(
                question: question,
                candidate: candidate,
                evidenceSpans: [],
                sourceField: .llmDirectExtraction
            )))
        }

        // Cap uncertainties thread-wide, then bucket.
        var uncertaintiesByMessage: [UUID: [Uncertainty]] = [:]
        for (messageID, uncertainty) in (modelUncertainties + demotedUncertainties).prefix(maxUncertainties) {
            uncertaintiesByMessage[messageID, default: []].append(uncertainty)
        }

        // Assemble one memory per message that received at least one item.
        var messageIDs = Set(claimsByMessage.keys)
        messageIDs.formUnion(tacitRulesByMessage.keys)
        messageIDs.formUnion(supersessionsByMessage.keys)
        messageIDs.formUnion(uncertaintiesByMessage.keys)

        var result: [UUID: DiscourseMemory] = [:]
        for messageID in messageIDs {
            result[messageID] = DiscourseMemory(
                claimCandidates: claimsByMessage[messageID] ?? [],
                tacitRuleSignals: tacitRulesByMessage[messageID] ?? [],
                supersessionSignals: supersessionsByMessage[messageID] ?? [],
                uncertainties: uncertaintiesByMessage[messageID] ?? [],
                extractionVersion: DiscourseMemory.threadVersion,
                threadFingerprint: packet.fingerprint
            )
        }
        return result
    }

    // MARK: - Helpers

    /// Strip code-fence markers and surrounding prose, then isolate the JSON
    /// object from the first `{` to the last `}`. Throws when no object exists.
    ///
    /// For well-formed output the last `}` in the text is the root object's
    /// own close, so this is exact. For *truncated* output it is merely a
    /// heuristic — the last `}` may sit deep inside an unfinished nested
    /// structure — which is why the salvage path (`salvageParse`) re-derives
    /// its own working text from `stripCodeFences` rather than reusing this
    /// slice.
    private static func extractJSONObject(from raw: String) throws -> String {
        let text = stripCodeFences(raw)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            throw ThreadDiscoursePromptError.noJSONObject
        }
        return String(text[start...end])
    }

    /// Strips a leading/trailing ``` code fence (with optional language tag)
    /// and surrounding whitespace/prose. Shared by `extractJSONObject` and
    /// the truncation salvage path.
    private static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Truncation salvage
    //
    // A generation that hits its `maxTokens` cap stops mid-stream, usually
    // mid-object inside one of the three top-level arrays. The top-level
    // decode then fails even though a prefix of that array is perfectly
    // well-formed JSON. This recovers that prefix.
    //
    // The scanner is pure JSON bracket/string/escape-state mechanics — it
    // never looks at field names or values, so it works identically
    // regardless of the thread's language or content.

    /// Attempts to recover a `ModelOutput` from truncated model output.
    /// Only ever called after the primary top-level decode has already
    /// failed (see `parse`), so it can never change well-formed-input
    /// behavior. Returns `nil` when nothing can be salvaged.
    private static func salvageParse(_ modelOutput: String) -> ModelOutput? {
        let text = stripCodeFences(modelOutput)
        guard let start = text.firstIndex(of: "{") else { return nil }
        guard let repaired = salvageTruncatedJSON(String(text[start...])) else { return nil }
        return try? JSONDecoder().decode(ModelOutput.self, from: Data(repaired.utf8))
    }

    /// `text` starts at the outermost `{`. Scans it tracking only
    /// string/escape state and bracket depth (no content awareness), finds
    /// whichever container is still open at the end of the text — the array
    /// the model was mid-way through emitting when generation stopped, or
    /// (if every array had already closed by then — truncation landed
    /// between two top-level fields, or between the last array and the root
    /// object's own closing brace) the root object itself — and cuts back
    /// to the end of the last fully-closed direct child inside that
    /// container, dropping any trailing partial child entirely. Appends the
    /// closing brackets/braces the remaining open containers need to
    /// balance.
    ///
    /// Returns `nil` when the target container has no complete child to
    /// recover (truncation happened inside its very first child with
    /// nothing to salvage).
    private static func salvageTruncatedJSON(_ text: String) -> String? {
        guard let finalStack = openBracketStack(in: text) else { return nil }
        // Prefer the array still open at EOF (the common case — truncation
        // mid-array). When none is open, every top-level array already
        // closed by the time the text ended, so fall back to the root
        // object itself (depth 0) and recover the last array that fully
        // closed, rather than discarding already-complete arrays just
        // because the root's own closing brace never arrived.
        let targetDepth = finalStack.firstIndex(of: "[") ?? 0

        var stack: [Character] = []
        var inString = false
        var escaped = false
        var lastSafeIndex: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{", "[":
                stack.append(char)
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
                // A close that lands exactly one level inside the target
                // array just finished one of its direct-child elements —
                // the array's own bracket sits at `targetDepth`, so a
                // direct child element closing returns the stack to
                // `targetDepth + 1`. Closes deeper than that belong to an
                // unfinished element's own nested structure and are not
                // safe cut points.
                if stack.count == targetDepth + 1 {
                    lastSafeIndex = next
                }
            default:
                break
            }
            index = next
        }

        guard let cutIndex = lastSafeIndex else { return nil }

        var repaired = String(text[text.startIndex..<cutIndex])
        for bracket in finalStack.prefix(targetDepth + 1).reversed() {
            repaired.append(bracket == "{" ? "}" : "]")
        }
        return repaired
    }

    /// The stack of brackets (`{`/`[`) still open at the end of `text`,
    /// tracked purely through string/escape state — never bracket
    /// characters that appear inside a string literal. `nil` when the text
    /// is already fully balanced (nothing to salvage).
    private static func openBracketStack(in text: String) -> [Character]? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        for char in text {
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{", "[":
                stack.append(char)
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
            default:
                break
            }
        }
        return stack.isEmpty ? nil : stack
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonEmpty(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let clipped = clip(text, limit: limit)
        return clipped.isEmpty ? nil : clipped
    }

    private static func supportLevel(from raw: String?) -> SupportLevel {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let level = SupportLevel(rawValue: raw) else {
            // Unknown / missing support cannot qualify; demote to review.
            return .weaklyInferred
        }
        return level
    }

    private static func clampConfidence(_ value: Double?) -> Double {
        guard let value else { return 0.5 }
        return min(1, max(0, value))
    }

    private static func canonicalKind(_ raw: String?) -> String? {
        guard let folded = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !folded.isEmpty else { return nil }
        return canonicalKinds[folded]
    }

    /// `"user"` stays `"user"`; `"shared"` → nil; anything else is a verbatim,
    /// lowercased address.
    private static func normalizeAssertedBy(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "user" { return "user" }
        if lowered == "shared" { return nil }
        return lowered
    }

    private static func mapScopes(_ scopes: [ModelScope]?) -> [ScopeHint] {
        guard let scopes else { return [] }
        return scopes.compactMap { scope in
            guard let kindRaw = scope.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let kind = ScopeKind(rawValue: kindRaw) else { return nil }
            let value = (scope.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ScopeHint(kind: kind, value: value)
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }

    // MARK: - Model DTOs

    private struct ModelOutput: Decodable {
        var claims: [ModelClaim]?
        var supersessions: [ModelSupersession]?
        var uncertainties: [ModelUncertainty]?
    }

    private struct ModelClaim: Decodable {
        var text: String?
        var kind: String?
        var subject: String?
        var assertedBy: String?
        var direction: String?
        var support: String?
        var confidence: Double?
        var asOf: String?
        var expires: String?
        var conditions: String?
        var futureUse: String?
        var formationBasis: String?
        var usePolicy: String?
        var isEpisodic: Bool?
        var scopes: [ModelScope]?
        var evidence: [ModelEvidence]?
    }

    private struct ModelScope: Decodable {
        var kind: String?
        var value: String?
    }

    private struct ModelEvidence: Decodable {
        var message: Int?
        var quote: String?
    }

    private struct ModelSupersession: Decodable {
        var newer: String?
        var older: String?
        var message: Int?
    }

    private struct ModelUncertainty: Decodable {
        var question: String?
        var candidate: String?
        var message: Int?
    }
}

public enum ThreadDiscoursePromptError: Error, Sendable, Equatable {
    /// No `{ … }` object could be located in the model output.
    case noJSONObject
    /// A JSON object was found but failed to decode at the top level.
    case undecodable(String)
}
