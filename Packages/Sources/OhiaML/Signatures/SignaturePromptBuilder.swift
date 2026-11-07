import CryptoKit
import Foundation
import OhiaCore

/// One signature-design session's inputs: the vetted contact lines, the
/// chosen format, an optional typed image, and the output language. The
/// prompt builder derives every generation of the session (tiers,
/// regenerates, revisions) from one stable prefix so the engine's KV
/// prefix cache is reused across all of them.
public struct SignatureDesignRequest: Sendable, Equatable {
    public struct ImageContext: Sendable, Equatable {
        public var asset: SignatureImageAsset
        /// The design-session id the `ohia-sig://` tokens carry until the
        /// signature is saved into a slot.
        public var ownerID: UUID

        public init(asset: SignatureImageAsset, ownerID: UUID) {
            self.asset = asset
            self.ownerID = ownerID
        }
    }

    public var format: SignatureFormat
    public var contact: SignatureContactFields
    public var image: ImageContext?
    /// Canonical language id ("en", "ja", …) the signature is written in.
    /// Descriptive field values may be translated, while identity and
    /// contact coordinates remain verbatim.
    public var languageID: String
    /// Account owning the studio session. Dyads remain user-wide; this scopes
    /// only target-language style rules before prompting.
    public var accountID: UUID?
    /// Canonical language of the vetted contact facts when the studio can
    /// identify it directly. When absent, the generation service uses strict
    /// local detection and leaves ambiguous facts ungrounded.
    public var sourceLanguageID: String?
    /// Bounded, curated target-language grounding loaded by the generation
    /// service. Internal so callers cannot accidentally inject unvetted text.
    var translationContext: TranslationContext?
    /// Exact source occurrences prepared once across all vetted contact values.
    var translationProtection: PreparedTranslationGlossaryProtection?
    /// Prompt-only values keyed by the user-owned contact row. The public
    /// contact model stays unchanged for privacy validation and editor state.
    var protectedContactValues: [UUID: String]

    public init(
        format: SignatureFormat,
        contact: SignatureContactFields,
        image: ImageContext? = nil,
        languageID: String,
        accountID: UUID? = nil,
        sourceLanguageID: String? = nil
    ) {
        self.format = format
        self.contact = contact
        self.image = image
        self.languageID = languageID
        self.accountID = accountID
        self.sourceLanguageID = DraftLanguage.familyID(for: sourceLanguageID)
        self.translationContext = nil
        self.translationProtection = nil
        self.protectedContactValues = [:]
    }

    /// The link targets the sanitizer accepts for one tier's output: every
    /// URL a vetted contact value justifies (the website, plus each social
    /// handle's derived profile URL) **that the tier admits**. `mailto:`
    /// and `tel:` are permitted by the policy itself. A link the model
    /// invents cannot survive this.
    ///
    /// Tier-scoped: an unscoped policy let a minimal signature keep a live
    /// link to a field that tier forbids.
    public func linkPolicy(for tier: SignatureTier) -> SignatureHTMLSanitizer.LinkPolicy {
        SignatureHTMLSanitizer.LinkPolicy(allowedHTTPURLs: contact.allowedLinkURLs(in: tier))
    }

    /// The policy for hand-edits in the studio editor, where no tier is in
    /// play — the user has already chosen a design and may keep any link
    /// their own vetted facts justify.
    public var editorLinkPolicy: SignatureHTMLSanitizer.LinkPolicy {
        SignatureHTMLSanitizer.LinkPolicy(allowedHTTPURLs: contact.allowedLinkURLs(in: .detailed))
    }

    /// Exact target-language renderings pinned for the source name, or the
    /// source name itself when no pin exists. Once the user has established a
    /// rendering, accepting the untranslated source would silently ignore it.
    var acceptableNameRenderings: [String] {
        guard let name = contact.value(for: .name) else { return [] }
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let established = translationContext?.exactGlossary.compactMap { entry -> String? in
            let source = entry.sourceTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rendering = entry.targetRendering
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard source == normalizedName, rendering.isEmpty == false else { return nil }
            return rendering
        } ?? []
        return established.isEmpty ? [name] : established
    }

    var preferredNameRendering: String? {
        acceptableNameRenderings.first
    }

    var promptPreferredNameRendering: String? {
        guard let line = contact.line(for: .name) else { return nil }
        return protectedContactValues[line.id] ?? line.trimmedValue
    }

    func promptContactLines(in tier: SignatureTier) -> [SignatureContactLine] {
        contact.lines(allowedIn: tier).map { line in
            var protected = line
            if let value = protectedContactValues[line.id] {
                protected.value = value
            }
            return protected
        }
    }

    /// Translation references safe to expose to one tier. The stable prefix
    /// deliberately carries no contact facts or account memories: otherwise a
    /// small model could translate a tier-forbidden address and evade a scrub
    /// that only knows its source text. Each suffix receives allowed facts and
    /// drops pins/rules that disclose a forbidden value.
    func promptTranslationContext(in tier: SignatureTier) -> TranslationContext? {
        guard let translationContext, translationContext.isEmpty == false else { return nil }
        let forbiddenSources = normalizedForbiddenSources(in: tier)
        let allowedExact = translationContext.exactGlossary.filter { entry in
            refersToForbiddenFact(entry.sourceTerm, forbiddenSources: forbiddenSources) == false
        }
        let allowedProvisional = translationContext.provisionalGlossary.filter { entry in
            refersToForbiddenFact(entry.sourceTerm, forbiddenSources: forbiddenSources) == false
        }
        let forbiddenTargets = (translationContext.exactGlossary + translationContext.provisionalGlossary).compactMap { entry -> String? in
            guard refersToForbiddenFact(entry.sourceTerm, forbiddenSources: forbiddenSources)
            else { return nil }
            return normalized(entry.targetRendering)
        }
        let blockedText = forbiddenSources + forbiddenTargets
        let allowedRules = translationContext.rules.filter { rule in
            let text = normalized(rule)
            return blockedText.contains { blocked in
                blocked.isEmpty == false && text.contains(blocked)
            } == false
        }
        let result = TranslationContext(
            exactGlossary: allowedExact,
            provisionalGlossary: allowedProvisional,
            rules: allowedRules
        )
        return result.isEmpty ? nil : result
    }

    func promptProtection(in tier: SignatureTier) -> [TranslationGlossaryMarkerMapping] {
        guard let translationProtection else { return [] }
        let allowedText = promptContactLines(in: tier)
            .compactMap(\.trimmedValue)
            .joined(separator: "\n")
        return translationProtection.mappings.filter { allowedText.contains($0.marker) }
    }

    /// Exact pins for facts this tier may render. If the model emits one of
    /// these facts in its source form, the parser rejects the candidate so an
    /// explicit user rendering cannot degrade into advisory prompt text.
    func enforcedTranslationPins(in tier: SignatureTier) -> [TranslationGlossaryEntry] {
        let allowed = contact.lines(allowedIn: tier).compactMap { line in
            line.trimmedValue.map(normalized)
        }
        return promptTranslationContext(in: tier)?.exactGlossary.filter { entry in
            let source = normalized(entry.sourceTerm)
            guard source.isEmpty == false,
                  source != normalized(entry.targetRendering) else { return false }
            return allowed.contains { fact in
                fact == source || fact.contains(source) || source.contains(fact)
            }
        } ?? []
    }

    /// Raw forbidden values plus any exact target-language renderings pinned
    /// for them. Once the prompt is allowed to translate a value, privacy
    /// enforcement must recognize that translated form too.
    func forbiddenRenderings(in tier: SignatureTier) -> [String] {
        let forbidden = contact.forbiddenValues(in: tier)
        let forbiddenSources = normalizedForbiddenSources(in: tier)
        let translated = translationContext?.exactGlossary.compactMap { entry -> String? in
            let rendering = entry.targetRendering
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard refersToForbiddenFact(entry.sourceTerm, forbiddenSources: forbiddenSources),
                  rendering.isEmpty == false else { return nil }
            return rendering
        } ?? []
        return forbidden + translated.filter { forbidden.contains($0) == false }
    }

    private func normalizedForbiddenSources(in tier: SignatureTier) -> [String] {
        contact.forbiddenValues(in: tier).map(normalized)
    }

    private func refersToForbiddenFact(
        _ candidate: String,
        forbiddenSources: [String]
    ) -> Bool {
        let candidate = normalized(candidate)
        guard candidate.isEmpty == false else { return false }
        return forbiddenSources.contains { source in
            source == candidate || source.contains(candidate) || candidate.contains(source)
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One earlier design from this session, fed back so the variation engine
/// can avoid repeating itself. Populated from each candidate's parsed META
/// block.
public struct SignatureDesignHistoryEntry: Sendable, Equatable {
    public var archetype: String
    public var fingerprint: String

    public init(archetype: String, fingerprint: String) {
        self.archetype = archetype
        self.fingerprint = fingerprint
    }
}

/// Builds the signature-design prompt.
///
/// The design grammar here is adapted to this pipeline's hard constraints,
/// which differ from generic HTML-signature guidance in three ways:
///
/// 1. **The model writes no tables.** It returns clean content that the app
///    places into a vetted, email-safe presentation-table template after
///    parsing. This keeps arbitrary model markup out while allowing real
///    rails, frames, bands, and split layouts that AppKit preserves.
/// 2. **No image URLs.** Images are local assets addressed by
///    `ohia-sig://` tokens that become CID attachments at send. The model
///    is handed the exact tag and never composes a `src`.
/// 3. **Markers, not JSON.** A small local model emitting HTML inside JSON
///    string escaping is brittle; `SignatureOutputParser` reads delimited
///    blocks and salvages truncated output instead.
enum SignaturePromptBuilder {

    static let beginMetaMarker = "BEGIN_SIGNATURE_META"
    static let endMetaMarker = "END_SIGNATURE_META"
    static let beginHTMLMarker = "BEGIN_SIGNATURE_HTML"
    static let endHTMLMarker = "END_SIGNATURE_HTML"
    static let beginTextMarker = "BEGIN_SIGNATURE_TEXT"
    static let endTextMarker = "END_SIGNATURE_TEXT"

    /// The session-stable prefix: role, truth rules, image contract, markup
    /// rules, language, and the design grammar. Tier-scoped contact facts and
    /// translation references live in the suffix so forbidden facts are never
    /// exposed to the model.
    /// Byte-identical across the session's tier calls, regenerates, and
    /// revisions — the prefix-cache invariant.
    static func prefix(for request: SignatureDesignRequest) -> String {
        var lines: [String] = []
        lines.append("/no_think")
        lines.append(
            "You are an expert email-signature designer. Compose polished content for the exact app-owned template named in the task suffix."
        )
        lines.append("")

        lines.append("[TRUTH RULES]")
        lines.append(
            "Use only the contact facts below. Never invent, embellish, or \"improve\" a fact: no title, credential, address, number, URL, account, tagline, award, or affiliation that is not listed. Preserve each fact's meaning exactly; translate descriptive text only as required by the [LANGUAGE] rule. Omit any fact that is absent and close the space cleanly — never leave an empty label, a dummy value, a placeholder, or a dangling separator. Never infer an account from a name. Never add a quotation, maxim, political or religious statement, confidentiality notice, environmental notice, legal disclaimer, or sign-off: none were supplied. Never add tracking parameters."
        )
        // Load-bearing: without it the model drops the name from denser
        // styles, and a signature that does not say who sent the mail is
        // not a signature.
        lines.append(
            "Always include the name, in every style, and lead the signature with it. The name is the one fact that is never optional."
        )
        lines.append("")

        if let image = request.image, request.format == .htmlWithImages {
            let asset = image.asset
            var tag = "<img src=\"\(SignatureImageToken.url(ownerID: image.ownerID, assetID: asset.id))\""
            if let width = asset.imageType.stampedWidth { tag += " width=\"\(width)\"" }
            if let height = asset.imageType.stampedHeight { tag += " height=\"\(height)\"" }
            tag += ">"
            lines.append("[IMAGE]")
            lines.append("Kind: \(asset.imageType.rawValue)")
            lines.append("Tag (use exactly once, verbatim): \(tag)")
            lines.append("Placement: \(placementRule(for: asset.imageType))")
            lines.append(
                "The tag is already sized correctly. Never alter its src, never add another image, and never turn the signature into one image. Identity and contact facts stay live text beside it."
            )
            lines.append("")
        }

        if request.format == .plainText {
            lines.append(contentsOf: plainTextGrammar())
        } else {
            lines.append(contentsOf: markupRules(for: request))
        }

        lines.append("[STYLE SYSTEM]")
        lines.append(
            "MINIMAL is restrained identity, not an unfinished signature: the name, the most useful role or affiliation line, and one or two high-value contact routes. One compact visual group, abundant whitespace, and at most one accent color. When decoration is required, use one restrained separator or accent gesture; when it is not, let typography and whitespace provide the hierarchy."
        )
        lines.append(
            "STANDARD is a complete professional card: the name, role and organization, and two to four useful contact routes. Four to seven visual lines or two balanced groups with clear hierarchy. Use a principal separator treatment only when the decoration state requires one."
        )
        lines.append(
            "DETAILED is comprehensive but controlled: every allowed fact, grouped into a legible hierarchy — identity, organization, direct contact, address, profiles, then supplementary detail. Keep the identity block dominant and supplementary material subordinate. Never give every field equal emphasis, and never pile on competing panels or dense ornament."
        )
        lines.append("")

        lines.append("[VARIATION]")
        lines.append(
            "The app selects the outer template. Within that template, privately choose the information hierarchy, field grouping and order, typographic scale and emphasis, palette family, label style, and image emphasis when one is supplied. Do not narrate these choices or expose your reasoning — return only the output blocks."
        )
        lines.append("")

        lines.append("[LANGUAGE]")
        let languageName = DraftLanguage.displayName(for: request.languageID)
        lines.append("Write the complete signature in \(languageName).")
        lines.append(
            "Translate descriptive contact text into \(languageName) when it is written in another language, including professional titles, department and organization names, address words, and labels. Keep personal names, phone numbers, email addresses, URLs, and social handles verbatim."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A tier-generation suffix. The app selects one of two mutually
    /// exclusive design prompts from the tier and attempt number; model META
    /// is used only for variety and can never determine alternation state.
    static func tierSuffix(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int,
        history: [SignatureDesignHistoryEntry] = []
    ) -> String {
        var lines = taskHeader(tier: tier, request: request)
        lines.append(contentsOf: decorationDesignPrompt(
            tier: tier,
            format: request.format,
            attempt: attempt
        ))
        lines.append(contentsOf: historyBlock(history))
        if attempt > 1 {
            lines.append(
                "Attempt \(attempt) — produce a fresh design that differs clearly from every earlier attempt. Change at least four axes. A new palette alone does not qualify; neither does a left-right mirror. Keep every fact, the style, and the format unchanged."
            )
        }
        lines.append(contentsOf: outputContract(
            for: request.format,
            archetypePlaceholder: SignatureTemplateComposer.templateID(
                tier: tier,
                attempt: attempt
            )
        ))
        return lines.joined(separator: "\n")
    }

    /// A revision suffix: same tier contract plus the current output and
    /// the user's free-text instruction.
    static func revisionSuffix(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        currentOutput: String,
        instruction: String
    ) -> String {
        var lines = taskHeader(tier: tier, request: request)
        lines.append("")
        lines.append("[DECORATION STATE]")
        lines.append("Required decoration for this signature: preserve_existing.")
        lines.append(
            "This is a revision, not an alternation turn. Preserve the current signature's decorated or undecorated state unless the revision instruction explicitly asks to change it."
        )
        lines.append("")
        lines.append("[CURRENT SIGNATURE]")
        lines.append(currentOutput)
        lines.append("")
        lines.append("[REVISION INSTRUCTION]")
        lines.append(instruction)
        lines.append("")
        lines.append(
            "Apply the revision instruction to the current signature; keep everything else unchanged. This is an edit, not a redesign — hold the archetype, palette, and structure steady unless the instruction asks otherwise."
        )
        lines.append(contentsOf: outputContract(
            for: request.format,
            archetypePlaceholder: "<the current signature's archetype token>"
        ))
        return lines.joined(separator: "\n")
    }

    /// Content-hashed cache key for the contact-free prefix. Contact facts and
    /// account translation references are tier-scoped suffix content, while
    /// image, format, and language changes still rotate this key.
    static func cacheKey(for request: SignatureDesignRequest) -> String {
        let digest = SHA256.hash(data: Data(prefix(for: request).utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "signature-design-\(hex)"
    }

    // MARK: - Markup rules

    private static func markupRules(for request: SignatureDesignRequest) -> [String] {
        var lines: [String] = []
        lines.append("[MARKUP RULES]")
        lines.append(
            "Return an HTML fragment — no doctype, no <html>, no <head>, no <style> block. Inline styles only."
        )
        lines.append("Allowed elements: <p>, <br>, <a>, <b>, <strong>, <i>, <em>, <u>, <span>, <img>.")
        lines.append(
            "Allowed style properties: color, font-family, font-size, font-weight, font-style, text-decoration, text-align, margin, padding, border, border-left, border-right, border-top, border-bottom, background-color, line-height."
        )
        lines.append(
            "Forbidden: tables, div, lists, headings, blockquote, CSS classes, stylesheets, web fonts, JavaScript, background images, gradients, floats, flexbox, grid, and positioning. Layout comes from paragraphs, spacing, borders, and typographic contrast — never from a grid or a table."
        )
        lines.append(
            "Every line stands on its own: give each its own <p>, or separate lines inside a <p> with <br>. Two facts must never sit next to each other with nothing between them — \"MorganProfessor\" and \"BostonPhone:\" are failures. Where facts share a line, separate them with a visible separator padded with spaces, and put a space after every comma and colon."
        )
        // The permitted link targets vary by tier, and this prefix is
        // byte-frozen across the session's tiers for the KV cache — so the
        // list itself lives in the task suffix, not here.
        lines.append(
            "Links (<a href>) may target only what the [TASK] section permits; never invent a URL — any other link is discarded."
        )
        lines.append(
            "Keep the signature about 300–600px wide, readable in a narrow mobile viewport, and never dependent on horizontal scrolling. Escape &, <, and > in text."
        )
        lines.append("")

        lines.append("[TYPOGRAPHY & COLOR]")
        lines.append(
            "Use one web-safe font stack throughout — Arial/Helvetica, Verdana, Tahoma, Georgia, or Calibri — and vary size, weight, capitalization, and color within it. Never load a web font. Sizes: name 15–19px, role or organization 12–14px, contact text 11–13px. Keep line height readable."
        )
        lines.append(
            "Pick one palette family at random: black and warm gray; charcoal and slate blue; charcoal and forest; charcoal and burgundy; deep navy and muted teal; indigo and cool gray; or monochrome. Use at most two chromatic colors plus neutrals. No neon, no rainbow, no hairline low-contrast gray body text, no large saturated panel. Use color to establish hierarchy, not to decorate every field."
        )
        lines.append(
            "Author for light mode with strong contrast, and keep the design legible if a client inverts colors: never place essential meaning in color alone, and avoid white text on a transparent background."
        )
        lines.append("")
        return lines
    }

    private static func plainTextGrammar() -> [String] {
        var lines: [String] = []
        lines.append("[PLAIN-TEXT DESIGN SYSTEM]")
        lines.append(
            "Plain text is a designed medium: build hierarchy from lineation, grouping, and labels. No HTML, no markdown, no tabs, no ANSI color, no emoji, and no pictographic phone/envelope/globe icons. Never depend on exact space alignment — a proportional font destroys it. Keep most lines under 72 characters. Show full URLs so they stay actionable."
        )
        lines.append(
            "A separator always sits between two things and a rule always has content under it. Never end the signature on a separator, a rule, or a flourish with nothing after it. Put a space after every comma and colon, and pad inline separators with a space on each side."
        )
        lines.append("")
        return lines
    }

    // MARK: - Pieces

    private static func taskHeader(
        tier: SignatureTier,
        request: SignatureDesignRequest
    ) -> [String] {
        let allowedLines = request.promptContactLines(in: tier)
        let allowed = allowedLines.map(\.displayLabel)
        let forbidden = request.contact.lines(forbiddenIn: tier).map(\.displayLabel)
        var lines: [String] = []
        lines.append("[TASK]")
        lines.append("Design the \(tier.rawValue) variant of this signature.")
        if !allowed.isEmpty {
            lines.append("Fields allowed: \(allowed.joined(separator: ", ")).")
        }
        // Restating the name here, next to the field list and by value, is
        // what actually holds it in. The prefix's truth rule alone did not:
        // the model still dropped the name from the denser styles, and from
        // any style once an image block joined the prompt.
        if let name = request.promptPreferredNameRendering {
            lines.append("The signature must state the name \"\(name)\" and lead with it.")
        }
        if !forbidden.isEmpty {
            lines.append("Do not include: \(forbidden.joined(separator: ", ")).")
        }
        lines.append("")
        lines.append("[CONTACT FIELDS]")
        for line in allowedLines {
            lines.append("\(line.displayLabel): \(line.trimmedValue ?? "")")
        }
        if let context = request.promptTranslationContext(in: tier) {
            let context = signatureSafeTranslationContext(context)
            lines.append("")
            lines.append(
                "The established terminology and translation preferences below override the generic verbatim rules wherever they provide an explicit rendering. Follow them exactly, but never reproduce these reference blocks in the signature."
            )
            if let exact = signatureExactMarkerBlock(request.promptProtection(in: tier)) {
                lines.append(exact)
            }
            if let provisional = TranslationPromptBuilder.provisionalGlossaryBlock(
                context.provisionalGlossary
            ) {
                lines.append(provisional)
            }
            if let rules = TranslationPromptBuilder.rulesBlock(context.rules) {
                lines.append(rules)
            }
        }
        lines.append("")
        if request.format != .plainText {
            lines.append(linkRule(for: request.contact, tier: tier))
        }
        return lines
    }

    /// Account memories are data, not prompt structure. Keep their content on
    /// one line and neutralize this prompt's section/output delimiters before
    /// passing them to the shared translation reference formatter.
    private static func signatureSafeTranslationContext(
        _ context: TranslationContext
    ) -> TranslationContext {
        TranslationContext(
            exactGlossary: context.exactGlossary.map { entry in
                TranslationGlossaryEntry(
                    pairID: entry.pairID,
                    sourceTerm: signatureSafeReferenceText(entry.sourceTerm),
                    targetRendering: signatureSafeReferenceText(entry.targetRendering),
                    authority: entry.authority
                )
            },
            provisionalGlossary: context.provisionalGlossary.map { entry in
                TranslationGlossaryEntry(
                    pairID: entry.pairID,
                    sourceTerm: signatureSafeReferenceText(entry.sourceTerm),
                    targetRendering: signatureSafeReferenceText(entry.targetRendering),
                    authority: entry.authority
                )
            },
            rules: context.rules.map(signatureSafeReferenceText)
        )
    }

    private static func signatureExactMarkerBlock(
        _ mappings: [TranslationGlossaryMarkerMapping]
    ) -> String? {
        let lines = mappings.compactMap { mapping -> String? in
            let marker = signatureSafeReferenceText(mapping.marker)
            let rendering = signatureSafeReferenceText(mapping.targetRendering)
            guard marker.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(marker) => \(rendering)"
        }
        guard lines.isEmpty == false else { return nil }
        return ([
            "Protected exact terminology (copy a field's marker unchanged whenever that field is included; optional fields may be omitted, but the required name must survive):"
        ] + lines).joined(separator: "\n")
    }

    private static func signatureSafeReferenceText(_ text: String) -> String {
        var result = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let delimiters = [
            "[TASK]", "[CONTACT FIELDS]", "[CURRENT SIGNATURE]",
            "[REVISION INSTRUCTION]", "[DESIGN HISTORY]", "[LANGUAGE]",
            "[TRUTH RULES]", "[DECORATION STATE]",
            "BEGIN_SIGNATURE_META", "END_SIGNATURE_META",
            "BEGIN_SIGNATURE_HTML", "END_SIGNATURE_HTML",
            "BEGIN_SIGNATURE_TEXT", "END_SIGNATURE_TEXT", "/no_think"
        ]
        for delimiter in delimiters {
            while let range = result.range(of: delimiter, options: .caseInsensitive) {
                let neutral = delimiter
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "/", with: "")
                result.replaceSubrange(range, with: neutral)
            }
        }
        return result
    }

    private enum DecorationMode {
        case decorated
        case undecorated
    }

    /// Initial cards are decorated, undecorated, decorated. Each card then
    /// flips on every regenerate. This depends only on app-owned inputs, not
    /// on optional META returned by a separate model call.
    private static func decorationMode(
        tier: SignatureTier,
        attempt: Int
    ) -> DecorationMode {
        let tierOffset: Int = switch tier {
        case .minimal: 0
        case .standard: 1
        case .detailed: 2
        }
        return (tierOffset + max(1, attempt) - 1).isMultiple(of: 2)
            ? .decorated
            : .undecorated
    }

    static func requiresDecoration(
        tier: SignatureTier,
        attempt: Int
    ) -> Bool {
        decorationMode(tier: tier, attempt: attempt) == .decorated
    }

    private static func decorationDesignPrompt(
        tier: SignatureTier,
        format: SignatureFormat,
        attempt: Int
    ) -> [String] {
        let required = decorationMode(tier: tier, attempt: attempt)
        let previousValue: String
        if tier == .minimal && attempt <= 1 {
            previousValue = "first_signature"
        } else {
            previousValue = required == .decorated ? "no" : "yes"
        }
        var lines = [
            "",
            "[DECORATION STATE]",
            "Previous generated signature used decoration: \(previousValue).",
            "Required decoration for this signature: \(required == .decorated ? "decorated" : "undecorated").",
            "The app selected this state from the tier and regeneration count. It takes precedence over design history, META, and all other variation instructions.",
            ""
        ]

        if required == .undecorated {
            lines.append("[UNDECORATED DESIGN PROMPT]")
            lines.append(
                "Compose deliberately unframed content. Build hierarchy with typography and ordinary whitespace only. The app will place it in the selected borderless template."
            )
        } else {
            lines.append("[DECORATED DESIGN PROMPT]")
            lines.append(
                "The app will apply the selected visible border, band, rail, or frame after parsing. Compose the content hierarchy to fit that treatment."
            )
        }
        lines.append(contentsOf: appOwnedTemplateBlock(
            tier: tier,
            format: format,
            attempt: attempt
        ))
        lines.append("")
        return lines
    }

    private static func appOwnedTemplateBlock(
        tier: SignatureTier,
        format: SignatureFormat,
        attempt: Int
    ) -> [String] {
        let templateID = SignatureTemplateComposer.templateID(
            tier: tier,
            attempt: attempt
        )
        var lines = [
            "",
            "[APP-OWNED TEMPLATE]",
            "Selected template: \(templateID).",
            "Template character: \(SignatureTemplateComposer.templateInstruction(tier: tier, attempt: attempt)).",
            "The app owns and applies the exact outer structure. State archetype: \(templateID) in META. Do not choose or name a different archetype. Do not add your own border, box, rule, accent line, colored panel, ornamental mark, or divider character."
        ]
        if format != .plainText {
            lines.append(
                "Return clean paragraph/span content only; do not return a table. The app will wrap it in its vetted email-safe presentation table."
            )
        }
        if format == .htmlWithImages {
            lines.append(
                "Use the required image exactly once; the app will move it into the template's vetted image position."
            )
        }
        return lines
    }

    private static func historyBlock(_ history: [SignatureDesignHistoryEntry]) -> [String] {
        guard !history.isEmpty else { return [] }
        var lines = ["", "[DESIGN HISTORY]"]
        lines.append(
            "Designs already produced this session — do not repeat a fingerprint. The app may deliberately select a previously seen archetype when its template catalog cycles:"
        )
        for entry in history {
            lines.append("- archetype: \(entry.archetype) · fingerprint: \(entry.fingerprint)")
        }
        lines.append("Within the selected app-owned template, vary hierarchy, grouping, typography, and palette from every fingerprint above.")
        lines.append("")
        return lines
    }

    private static func outputContract(
        for format: SignatureFormat,
        archetypePlaceholder: String = "<one token from the list above>"
    ) -> [String] {
        var lines: [String] = ["", "Respond with exactly:"]
        lines.append(beginMetaMarker)
        lines.append("archetype: \(archetypePlaceholder)")
        lines.append(
            "fingerprint: <style/format/archetype/hierarchy/grouping/decoration/type/palette/image>"
        )
        lines.append(endMetaMarker)
        if format != .plainText {
            lines.append(beginHTMLMarker)
            lines.append("<the signature markup>")
            lines.append(endHTMLMarker)
        }
        lines.append(beginTextMarker)
        lines.append("<the same signature as plain text lines>")
        lines.append(endTextMarker)
        lines.append(GenerationStopPolicy.signatureEndMarker)
        lines.append("")
        lines.append(
            "Return nothing else: no commentary, no markdown fences, no explanation of the design."
        )
        return lines
    }

    private static func placementRule(for type: SignatureImageType) -> String {
        switch type {
        case .headshot:
            "compact avatar at the start of the first line, before the name block"
        case .logo:
            "on its own line directly above the name block"
        case .banner:
            "on its own full-width line at the very top of the signature"
        }
    }

    /// The tier's permitted link targets. Scoped to the tier's own fields:
    /// listing a forbidden field's URL here would tell the model to link
    /// the very account the next line forbids.
    private static func linkRule(for contact: SignatureContactFields, tier: SignatureTier) -> String {
        let targets = contact.allowedLinkTargets(in: tier)
        guard !targets.isEmpty else {
            return "Do not include any links."
        }
        return "Links allowed: \(targets.joined(separator: ", ")). Keep the visible link text human-readable; any other link is discarded."
    }
}
