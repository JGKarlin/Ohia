import Foundation
import OhiaCore

/// One parsed, sanitized signature candidate.
public struct SignatureCandidate: Sendable, Equatable {
    public var tier: SignatureTier
    /// Sanitized fragment HTML (`ohia-sig://` tokens), nil for plain format.
    public var html: String?
    /// Plain-text rendering; never empty.
    public var plainText: String
    /// The archetype token the model reported, when it emitted a usable
    /// META block. Nil for template-composed candidates and for model
    /// output that dropped the block.
    public var archetype: String?
    /// The model's compact design fingerprint. Fed back through
    /// `SignatureDesignHistoryEntry` so later generations in the session
    /// avoid repeating a design.
    public var fingerprint: String?

    public init(
        tier: SignatureTier,
        html: String?,
        plainText: String,
        archetype: String? = nil,
        fingerprint: String? = nil
    ) {
        self.tier = tier
        self.html = html
        self.plainText = plainText
        self.archetype = archetype
        self.fingerprint = fingerprint
    }

    /// This candidate's contribution to the session's design history, when
    /// it reported one.
    public var historyEntry: SignatureDesignHistoryEntry? {
        guard let archetype, let fingerprint else { return nil }
        return SignatureDesignHistoryEntry(archetype: archetype, fingerprint: fingerprint)
    }
}

/// Parses raw model output into a sanitized candidate. Tolerant of the
/// small local model's failure modes: markdown fences, a missing END
/// marker on the last block (truncation salvage), or a missing TEXT block
/// (derived from the HTML). A candidate that survives with no content at
/// all throws `TrainingEngineError.generationFailed`.
enum SignatureOutputParser {

    static func parse(
        _ raw: String,
        tier: SignatureTier,
        request: SignatureDesignRequest
    ) throws -> SignatureCandidate {
        var work = raw.replacingOccurrences(
            of: GenerationStopPolicy.signatureEndMarker, with: ""
        )
        work = stripFences(work)

        // The META block is prose, not signature content: it is lifted out
        // before the bare-markup salvage below can mistake it for output.
        let (meta, remainder) = extractMeta(from: work)
        work = remainder

        let htmlBlock = extractBlock(
            from: work,
            begin: SignaturePromptBuilder.beginHTMLMarker,
            end: SignaturePromptBuilder.endHTMLMarker,
            nextMarkers: [SignaturePromptBuilder.beginTextMarker]
        )
        let textBlock = extractBlock(
            from: work,
            begin: SignaturePromptBuilder.beginTextMarker,
            end: SignaturePromptBuilder.endTextMarker,
            nextMarkers: []
        )

        var html: String?
        if request.format != .plainText {
            // No HTML block at all: some drift modes emit bare markup
            // without the delimiters — accept it when it contains a tag.
            let rawHTML = htmlBlock ?? (work.contains("<") && textBlock == nil ? work : nil)
            if let rawHTML {
                let assets = request.image.map { [$0.asset] } ?? []
                let sanitized = SignatureHTMLSanitizer.sanitize(
                    rawHTML,
                    assets: assets,
                    ownerID: request.image?.ownerID ?? UUID(),
                    linkPolicy: request.linkPolicy(for: tier),
                    allowLayoutTables: false
                )
                html = sanitized.isEmpty ? nil : sanitized
            }
        }

        var plainText = textBlock?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if plainText.isEmpty, let html {
            plainText = derivedPlainText(fromHTML: html)
        }
        // Plain-text drift mode: no TEXT block, and no HTML to derive one
        // from. The bare remainder *is* the signature — the same salvage the
        // HTML path gets from its bare-markup branch. Without this a
        // plain-text design that merely omitted its delimiters fails
        // outright, and plain text is where a small model drifts most.
        if plainText.isEmpty, request.format == .plainText {
            plainText = work.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The privacy scrub is deterministic and value-based: any
        // disallowed field value that leaked into the output removes its
        // containing element (HTML) or line (text).
        let forbidden = request.forbiddenRenderings(in: tier)
        if let current = html {
            html = scrubHTML(current, forbiddenValues: forbidden)
        }
        plainText = scrubText(plainText, forbiddenValues: forbidden)

        if request.format == .plainText { html = nil }

        let hasContent = !(plainText.isEmpty && (html?.isEmpty ?? true))
        guard hasContent else {
            throw TrainingEngineError.generationFailed(
                "The model produced no usable signature output."
            )
        }
        // Exact glossary pins are contractual, not suggestions. A pinned
        // contact fact may be omitted when the tier's design does not need it,
        // but if the model renders that fact in its source form, retry rather
        // than ship a signature that ignored the user's established wording.
        let renderedHTMLText = html.map { derivedPlainText(fromHTML: $0) } ?? ""
        for pin in request.enforcedTranslationPins(in: tier) {
            let source = pin.sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.isEmpty == false else { continue }
            if plainText.range(of: source, options: .caseInsensitive) != nil
                || renderedHTMLText.range(of: source, options: .caseInsensitive) != nil {
                throw TrainingEngineError.generationFailed(
                    "The model ignored an established translation rendering."
                )
            }
        }
        // A signature that never says who sent the mail is not a signature.
        // The prompt states this twice — in the truth rules and again per
        // tier, by value — and the small local model still drops the name
        // from dense designs. Prompting cannot guarantee it, so the
        // contract is enforced here: the caller retries, and a design that
        // will not state the name never reaches the user.
        //
        // Both forms are checked, not either: a rich signature ships its
        // HTML *and* a text/plain alternative, and the model has produced
        // designs that named the sender only in the text twin while the
        // markup — the part most recipients see — had no name at all.
        let acceptedNames = request.acceptableNameRenderings
        if acceptedNames.isEmpty == false {
            let statedInText = acceptedNames.contains { plainText.contains($0) }
            let statedInHTML = html.map { rendered in
                let text = derivedPlainText(fromHTML: rendered)
                return acceptedNames.contains { text.contains($0) }
            } ?? true
            guard statedInText, statedInHTML else {
                throw TrainingEngineError.generationFailed(
                    "The model produced a signature without the name."
                )
            }
        }

        // Two facts rendered with nothing between them — "Alex R.
        // MorganProfessor" — is a formatting failure, not a style. It comes
        // from the model grouping with inline <span>s instead of <p>/<br>,
        // and no amount of prompt text reliably prevents it.
        //
        // Repair rather than refuse. The design is otherwise sound and the
        // only thing missing is a separator whose exact position is known:
        // between two vetted strings. Throwing the whole design away for
        // that spent two generations and handed back an error instead of a
        // signature. The refusal below now only catches glue the repair
        // could not reach.
        let allowedLines = request.contact.lines(allowedIn: tier)
        let facts = allowedLines.compactMap(\.trimmedValue)
        let labels = allowedLines.map(\.displayLabel)
        html = html.map { separateGluedFacts(inHTML: $0, values: facts, labels: labels) }
        plainText = separateGluedFacts(inText: plainText, values: facts, labels: labels)

        if gluesFacts(plainText, values: facts, labels: labels)
            || (html.map {
                gluesFacts(derivedPlainText(fromHTML: $0), values: facts, labels: labels)
            } ?? false) {
            throw TrainingEngineError.generationFailed(
                "The model ran two facts together with no separator."
            )
        }
        if plainText.isEmpty, let html {
            plainText = derivedPlainText(fromHTML: html)
        }
        return SignatureCandidate(
            tier: tier,
            html: html,
            plainText: plainText,
            archetype: meta.archetype,
            fingerprint: meta.fingerprint
        )
    }

    // MARK: - META

    /// The only keys the META block may carry. Used both to read it and —
    /// when the model truncates before the END marker — to find where it
    /// stops.
    static let metaKeys: Set<String> = ["archetype", "fingerprint"]

    /// Lifts the META block out, returning what it said and the text with
    /// it removed.
    ///
    /// With the END marker present this is a plain delimited cut. Without
    /// it — truncation, or a model that skips the marker — the block is the
    /// run of recognized `key: value` lines directly after the begin
    /// marker, ending at the first line that is not one. Cutting to the end
    /// of the output instead would delete the signature in the drift mode
    /// where bare markup follows an unterminated block; leaving the prose
    /// in would ship "fingerprint: …" inside the user's signature.
    static func extractMeta(
        from text: String
    ) -> (meta: (archetype: String?, fingerprint: String?), remainder: String) {
        guard let beginRange = text.range(of: SignaturePromptBuilder.beginMetaMarker) else {
            return ((nil, nil), text)
        }
        let head = String(text[..<beginRange.lowerBound])
        let tail = String(text[beginRange.upperBound...])

        if let endRange = tail.range(of: SignaturePromptBuilder.endMetaMarker) {
            let block = String(tail[..<endRange.lowerBound])
            return (parseMeta(block), head + String(tail[endRange.upperBound...]))
        }

        var metaLines: [String] = []
        var rest: [String] = []
        var consuming = true
        for line in tail.components(separatedBy: "\n") {
            if consuming {
                // A blank line between the marker and the first key is
                // formatting, not content.
                if metaLines.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
                if isMetaLine(line) {
                    metaLines.append(line)
                    continue
                }
                consuming = false
            }
            rest.append(line)
        }
        return (
            parseMeta(metaLines.joined(separator: "\n")),
            head + rest.joined(separator: "\n")
        )
    }

    /// True for a `key: value` line whose key is one this block defines.
    /// Gating on known keys is what stops a signature line that happens to
    /// contain a colon ("Tel: 03-1234") from being eaten as metadata.
    static func isMetaLine(_ line: String) -> Bool {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return metaKeys.contains(parts[0].trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Reads `archetype:` / `fingerprint:` out of the META block. Both are
    /// advisory — they only feed the variation engine's design history — so
    /// a missing or malformed block never fails a generation.
    static func parseMeta(_ block: String?) -> (archetype: String?, fingerprint: String?) {
        guard let block else { return (nil, nil) }
        var archetype: String?
        var fingerprint: String?
        for line in block.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("<") else { continue }
            switch key {
            case "archetype":   archetype = value
            case "fingerprint": fingerprint = value
            default:            break
            }
        }
        return (archetype, fingerprint)
    }

    // MARK: - Block extraction

    /// Extracts the text between `begin` and `end`. Truncation salvage:
    /// when `end` is missing, the block runs to the next known marker or
    /// the end of the output.
    static func extractBlock(
        from text: String,
        begin: String,
        end: String,
        nextMarkers: [String]
    ) -> String? {
        guard let beginRange = text.range(of: begin) else { return nil }
        let tail = text[beginRange.upperBound...]
        if let endRange = tail.range(of: end) {
            return String(tail[..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in nextMarkers {
            if let markerRange = tail.range(of: marker) {
                return String(tail[..<markerRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripFences(_ text: String) -> String {
        var work = text
        for fence in ["```html", "```text", "```plaintext", "```"] {
            work = work.replacingOccurrences(of: fence, with: "")
        }
        return work
    }

    // MARK: - Privacy scrub

    /// Deterministic value-based scrub with three detectors per forbidden
    /// value: literal substring, entity-decoded substring, and — for
    /// number-heavy values like phone numbers (7+ digits) — a digit-stream
    /// substring that survives re-punctuation ("(555) 123-4567" leaking as
    /// "555.123.4567"). It is defense in depth, not a proof: a model that
    /// paraphrases a postal address into different words defeats it, which
    /// is why the tier field lists also gate the prompt and the user
    /// reviews every card before saving.
    static func leaks(_ candidate: String, value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if candidate.contains(value) { return true }
        let decoded = decodeEntities(candidate)
        if decoded.contains(value) { return true }
        let valueDigits = value.filter(\.isNumber)
        if valueDigits.count >= 7, decoded.filter(\.isNumber).contains(valueDigits) {
            return true
        }
        return false
    }

    /// Tags that do not end a line. Only these may sit between two facts for
    /// the run to count as glue: `</p><p>` or `<br>` between them already
    /// breaks the line, and treating that as glue inserted a second break
    /// into designs that were correctly separated to begin with.
    private static let inlineTagPattern = "(?:</?(?:span|b|strong|i|em|u|a|font|img)\\b[^>]*>)*"

    /// Inserts a line break wherever the markup runs one fact straight into
    /// the next, leaving everything else untouched.
    ///
    /// The break goes immediately after the first string's text, so it lands
    /// inside whichever element was holding it and before any tags that
    /// close or open around the boundary. Only *inline* tags may sit between
    /// the two strings for this to fire — if the model put any visible
    /// character there (a separator, a space, a comma) or anything that ends
    /// the line, it is not glue and nothing is touched.
    static func separateGluedFacts(
        inHTML html: String,
        values: [String],
        labels: [String]
    ) -> String {
        let facts = values.filter { !$0.isEmpty }
        guard !facts.isEmpty else { return html }
        var work = html
        for first in facts {
            for second in (facts + labels) where second != first && !second.isEmpty {
                let pattern = NSRegularExpression.escapedPattern(for: first)
                    + "(" + inlineTagPattern + ")"
                    + NSRegularExpression.escapedPattern(for: second)
                let template = NSRegularExpression.escapedTemplate(for: first)
                    + "<br>$1"
                    + NSRegularExpression.escapedTemplate(for: second)
                work = replaceAll(in: work, pattern: pattern, with: template)
            }
        }
        return work
    }

    /// The plain-text twin of the same repair: a newline where two facts
    /// were concatenated.
    static func separateGluedFacts(
        inText text: String,
        values: [String],
        labels: [String]
    ) -> String {
        let facts = values.filter { !$0.isEmpty }
        guard !facts.isEmpty else { return text }
        var work = text
        for first in facts {
            for second in (facts + labels) where second != first && !second.isEmpty {
                work = work.replacingOccurrences(of: first + second, with: first + "\n" + second)
            }
        }
        return work
    }

    /// True when the rendered text runs one fact straight into the next
    /// thing — another fact, or the label introducing one.
    ///
    /// Both shapes were produced live: "Alex R. MorganProfessor" (value
    /// into value) and "810358410374Email:" (value into label). Only whole
    /// vetted values and known labels are compared, so a value that
    /// legitimately contains a case boundary ("McGrath", "iPhone") can never
    /// trip this — the check asks whether two *separate* pieces were
    /// concatenated, which no correct signature does.
    ///
    /// Labels are matched in English only, since that is the set this app
    /// knows. A signature written in another language simply has fewer
    /// detectable shapes here; it never yields a false refusal.
    static func gluesFacts(_ rendered: String, values: [String], labels: [String] = []) -> Bool {
        let facts = values.filter { !$0.isEmpty }
        guard !facts.isEmpty else { return false }
        for first in facts {
            for second in facts where first != second {
                if rendered.contains(first + second) { return true }
            }
            for label in labels where !label.isEmpty {
                if rendered.contains(first + label) { return true }
            }
        }
        return false
    }

    /// True when an HTML fragment leaks a forbidden value through either
    /// its rendered text or a link target.
    ///
    /// Both halves are needed. `<a href="https://x.com/amorgan">Profile</a>`
    /// renders as "Profile" — the rendered-text check sees nothing, while
    /// the href carries the whole account. `forbiddenValues(in:)` supplies
    /// the derived URL alongside the raw value so this comparison can land.
    static func fragmentLeaks(_ fragment: String, values: [String]) -> Bool {
        let rendered = derivedPlainText(fromHTML: fragment)
        if values.contains(where: { leaks(rendered, value: $0) }) { return true }
        let hrefs = hrefTargets(in: fragment)
        guard !hrefs.isEmpty else { return false }
        return values.contains { value in
            hrefs.contains { leaks($0, value: value) }
        }
    }

    /// The `href` values in a fragment, entity-decoded.
    static func hrefTargets(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "href\\s*=\\s*(\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                for group in 2...3 where match.range(at: group).location != NSNotFound {
                    return decodeEntities(ns.substring(with: match.range(at: group)))
                }
                return nil
            }
    }

    /// Removes every `<p>` element (a structural unit after sanitization)
    /// whose rendered text leaks a forbidden value, applies the same
    /// line-level drop to bare `<br>`-separated runs between paragraphs
    /// (the sanitizer renders dropped table/list layouts in that shape),
    /// then removes any leftover bare literal.
    static func scrubHTML(_ html: String, forbiddenValues: [String]) -> String? {
        let values = forbiddenValues.filter { !$0.isEmpty }
        guard !values.isEmpty else { return html }

        var work = html
        let paragraphRegex = try? NSRegularExpression(
            pattern: "<p\\b[^>]*>.*?</p>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if let paragraphRegex {
            let ns = work as NSString
            let matches = paragraphRegex.matches(
                in: work, range: NSRange(location: 0, length: ns.length)
            )
            var rebuilt = ""
            var location = 0
            for match in matches {
                rebuilt += scrubBareRun(
                    ns.substring(
                        with: NSRange(location: location, length: match.range.location - location)
                    ),
                    values: values
                )
                let paragraph = ns.substring(with: match.range)
                if !fragmentLeaks(paragraph, values: values) {
                    rebuilt += paragraph
                } else if let salvaged = scrubParagraphLines(paragraph, values: values) {
                    // The paragraph leaks, but only on some of its lines —
                    // keep the rest. Dropping the whole element would take
                    // innocent content with it, and the name is usually in
                    // the same paragraph as whatever the model over-shared.
                    rebuilt += salvaged
                }
                location = match.range.location + match.range.length
            }
            rebuilt += scrubBareRun(ns.substring(from: location), values: values)
            work = rebuilt
        }
        for value in values {
            work = work.replacingOccurrences(of: value, with: "")
        }
        let stripped = work.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Rebuilds a leaking paragraph from only its clean `<br>`-separated
    /// lines, or returns nil when nothing inside it survives (in which case
    /// the caller drops the element).
    ///
    /// Without this, one over-shared fact takes its whole paragraph down —
    /// and a model that writes the name and the department as two lines of
    /// one paragraph produces a signature with no name at all.
    private static func scrubParagraphLines(_ paragraph: String, values: [String]) -> String? {
        guard let openEnd = paragraph.firstIndex(of: ">"),
              let close = paragraph.range(of: "</p>", options: [.caseInsensitive, .backwards]),
              paragraph.index(after: openEnd) <= close.lowerBound
        else { return nil }
        let openTag = String(paragraph[...openEnd])
        let inner = String(paragraph[paragraph.index(after: openEnd)..<close.lowerBound])
        let kept = scrubBareRun(inner, values: values)
        guard !derivedPlainText(fromHTML: kept)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return openTag + kept + "</p>"
    }

    /// Scrubs a non-`<p>` run with the same `leaks()` detectors the
    /// paragraph pass uses: the run splits into `<br>`-separated lines and
    /// a leaking line is dropped whole (mirroring `scrubText`'s newline
    /// semantics). Without this, a re-punctuated phone number on a bare
    /// line — the normal shape for a dropped table layout — would only
    /// face the weaker literal-substring pass.
    private static func scrubBareRun(_ fragment: String, values: [String]) -> String {
        guard !fragment.isEmpty else { return fragment }
        let leaked: (String) -> Bool = { segment in
            fragmentLeaks(segment, values: values)
        }
        guard let breakRegex = try? NSRegularExpression(
            pattern: "<br\\s*/?>", options: [.caseInsensitive]
        ) else {
            return leaked(fragment) ? "" : fragment
        }
        let ns = fragment as NSString
        let matches = breakRegex.matches(
            in: fragment, range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else {
            return leaked(fragment) ? "" : fragment
        }
        var segments: [String] = []
        var location = 0
        for match in matches {
            segments.append(ns.substring(
                with: NSRange(location: location, length: match.range.location - location)
            ))
            location = match.range.location + match.range.length
        }
        segments.append(ns.substring(from: location))
        return segments.filter { !leaked($0) }.joined(separator: "<br>")
    }

    static func scrubText(_ text: String, forbiddenValues: [String]) -> String {
        let values = forbiddenValues.filter { !$0.isEmpty }
        guard !values.isEmpty else { return text }
        return text
            .components(separatedBy: "\n")
            .filter { line in
                !values.contains { leaks(line, value: $0) }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - Helpers

    static func derivedPlainText(fromHTML html: String) -> String {
        var work = html
        work = replaceAll(in: work, pattern: "<br\\s*/?>", with: "\n")
        work = replaceAll(in: work, pattern: "</p>", with: "\n")
        work = replaceAll(in: work, pattern: "<img\\b[^>]*>", with: "")
        work = replaceAll(in: work, pattern: "<[^>]+>", with: "")
        work = work
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return work
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func replaceAll(
        in text: String, pattern: String, with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: replacement
        )
    }
}
