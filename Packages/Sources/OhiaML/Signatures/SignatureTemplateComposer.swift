import Foundation
import OhiaCore

/// Deterministic pure-Swift signature renderer — the studio's complete,
/// correct fallback when the generation engine is unavailable, and the
/// baseline the first cards show instantly while a model pass runs.
///
/// Layout follows the user's own row order. Image placement follows the
/// same per-type rules the model prompt states.
///
/// Labels are emitted only where a value cannot speak for itself. A phone
/// number, an email address, a URL, or a postal address is self-describing,
/// so those render as bare values and stay language-neutral. A license
/// number, an ORCID, a custom row, or a bare social handle is meaningless
/// without its label — "@amorgan" alone does not say X or Instagram — so
/// those carry one. Preset labels are English; a signature generated in
/// another language gets its labels from the model path, which is the
/// primary path. This fallback favors an intelligible signature over a
/// perfectly language-neutral one.
public enum SignatureTemplateComposer {

    /// App-owned layouts. Qwen supplies wording and emphasis; these concrete
    /// structures supply the part the small model could not reliably invent.
    /// The first six deliberately mix restrained professional treatments
    /// with bolder editorial ones. The last four are typography/spacing-only
    /// alternatives for undecorated turns.
    enum Template: String, CaseIterable {
        case accentRail = "accent-rail"
        case framedCard = "framed-card"
        case doubleRuleNameplate = "double-rule-nameplate"
        case headerBand = "header-band"
        case splitCard = "split-card"
        case editorialNameplate = "editorial-nameplate"
        case quietStack = "quiet-stack"
        case centeredNameplate = "centered-nameplate"
        case splitDirectory = "split-directory"
        case compactLedger = "compact-ledger"

        var instruction: String {
            switch self {
            case .accentRail:
                "restrained left accent rail with generous breathing room"
            case .framedCard:
                "subtle fully bordered card on a warm neutral field"
            case .doubleRuleNameplate:
                "crisp top-and-bottom nameplate frame"
            case .headerBand:
                "editorial colored header band above the detail block"
            case .splitCard:
                "two-zone identity and contact card with a strong vertical division"
            case .editorialNameplate:
                "bold outlined nameplate with a contrasting lower accent"
            case .quietStack:
                "unframed compact stack with quiet typography"
            case .centeredNameplate:
                "unframed centered identity treatment"
            case .splitDirectory:
                "unframed two-zone identity and contact directory"
            case .compactLedger:
                "unframed compact information ledger"
            }
        }
    }

    private static let decoratedTemplates: [Template] = [
        .accentRail,
        .framedCard,
        .doubleRuleNameplate,
        .headerBand,
        .splitCard,
        .editorialNameplate
    ]

    private static let undecoratedTemplates: [Template] = [
        .quietStack,
        .centeredNameplate,
        .splitDirectory,
        .compactLedger
    ]

    public static func compose(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int = 1
    ) -> SignatureCandidate {
        let allowed = request.contact.lines(allowedIn: tier)
        let identityKinds: Set<SignatureFieldKind> = [.name, .title, .organization]

        // Line 1: name (bold). Line 2: title · organization. Then one line
        // per remaining detail, in the user's row order.
        let name = allowed.first { $0.kind == .name }?.trimmedValue
        let roleLine = [
            allowed.first { $0.kind == .title }?.trimmedValue,
            allowed.first { $0.kind == .organization }?.trimmedValue
        ].compactMap { $0 }.joined(separator: " · ")

        let details = allowed
            .filter { !identityKinds.contains($0.kind) }
            .flatMap(detailUnits(for:))

        var textLines: [String] = []
        if let name { textLines.append(name) }
        if !roleLine.isEmpty { textLines.append(roleLine) }
        textLines.append(contentsOf: details.map(\.text))
        let plainText = textLines.joined(separator: "\n")

        let base = SignatureCandidate(
            tier: tier,
            html: request.format == .plainText
                ? nil
                : html(name: name, roleLine: roleLine, details: details),
            plainText: plainText
        )
        return applyingCatalogTemplate(
            to: base,
            tier: tier,
            request: request,
            attempt: attempt
        )
    }

    /// The exact template selected for one deterministic generation turn.
    /// Regenerations rotate within their decoration pool, so six decorated
    /// turns traverse all six structural families before repeating.
    static func selectedTemplate(
        tier: SignatureTier,
        attempt: Int
    ) -> Template {
        let requiresDecoration = SignaturePromptBuilder.requiresDecoration(
            tier: tier,
            attempt: attempt
        )
        let source = requiresDecoration ? decoratedTemplates : undecoratedTemplates
        let tierOffset: Int = switch tier {
        case .minimal: 0
        case .standard: 1
        case .detailed: 2
        }
        let turnOffset = max(0, max(1, attempt) - 1) / 2
        return source[(tierOffset + turnOffset) % source.count]
    }

    static func templateID(tier: SignatureTier, attempt: Int) -> String {
        selectedTemplate(tier: tier, attempt: attempt).rawValue
    }

    static func templateInstruction(tier: SignatureTier, attempt: Int) -> String {
        selectedTemplate(tier: tier, attempt: attempt).instruction
    }

    /// Applies the app-selected template to sanitized model content. The
    /// model's facts, translations, links, and typographic emphasis survive;
    /// only the unreliable outer layout is app-owned.
    static func applyingCatalogTemplate(
        to candidate: SignatureCandidate,
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int
    ) -> SignatureCandidate {
        applying(
            selectedTemplate(tier: tier, attempt: attempt),
            to: candidate,
            request: request
        )
    }

    /// Keeps a named app-owned layout. Unknown legacy/model archetypes are
    /// left untouched.
    static func preservingTemplate(
        _ templateID: String?,
        in candidate: SignatureCandidate,
        request: SignatureDesignRequest
    ) -> SignatureCandidate {
        guard let templateID, let template = Template(rawValue: templateID) else {
            return candidate
        }
        return applying(template, to: candidate, request: request)
    }

    /// Resolves the small set of explicit layout changes the revision field
    /// promises. All wording/content-only revisions keep the current layout.
    static func templateIDForRevision(
        currentID: String?,
        instruction: String
    ) -> String? {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let requestedTemplate: Template? = if containsAny(
            normalized,
            ["borderless", "no border", "remove the border", "remove border", "without a border"]
        ) {
            .quietStack
        } else if containsAny(normalized, ["header band", "banded header"]) {
            .headerBand
        } else if containsAny(normalized, ["accent rail", "left rail"]) {
            .accentRail
        } else if containsAny(normalized, ["framed card", "bordered card", "full border"]) {
            .framedCard
        } else if containsAny(normalized, ["double rule", "top and bottom rule"]) {
            .doubleRuleNameplate
        } else if containsAny(normalized, ["split card", "two-column card", "two column card"]) {
            .splitCard
        } else if normalized.contains("editorial nameplate") {
            .editorialNameplate
        } else if containsAny(normalized, ["centered nameplate", "center the signature"]) {
            .centeredNameplate
        } else if normalized.contains("split directory") {
            .splitDirectory
        } else if normalized.contains("compact ledger") {
            .compactLedger
        } else if containsAny(normalized, ["quiet stack", "simple stack"]) {
            .quietStack
        } else {
            nil
        }

        return requestedTemplate?.rawValue ?? currentID
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private static func applying(
        _ template: Template,
        to candidate: SignatureCandidate,
        request: SignatureDesignRequest
    ) -> SignatureCandidate {
        var result = candidate
        result.archetype = template.rawValue
        var fingerprintParts = [
            "app-template",
            template.rawValue,
            candidate.tier.rawValue,
            request.format.rawValue
        ]
        if let modelFingerprint = candidate.fingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !modelFingerprint.isEmpty {
            fingerprintParts.append(modelFingerprint)
        }
        result.fingerprint = fingerprintParts.joined(separator: "/")

        if request.format == .plainText {
            result.html = nil
            result.plainText = renderedPlainText(candidate.plainText, template: template)
        } else if let html = candidate.html {
            result.html = renderedHTML(html, template: template, request: request)
        }
        return result
    }

    // MARK: - Detail units

    /// One rendered detail: its plain text, plus the label/value/link parts
    /// the HTML pass needs. A multi-value row (comma-separated phones)
    /// yields one unit per value, matching the privacy scrub's granularity.
    private struct DetailUnit {
        var label: String?
        var value: String
        var link: String?

        var text: String {
            guard let label else { return value }
            return "\(label): \(value)"
        }
    }

    private static func detailUnits(for line: SignatureContactLine) -> [DetailUnit] {
        let label = needsLabel(line.kind) ? line.displayLabel : nil
        return line.scrubValues.map { value in
            DetailUnit(label: label, value: value, link: line.kind.linkTarget(for: value))
        }
    }

    /// True for values that cannot be read without their label.
    private static func needsLabel(_ kind: SignatureFieldKind) -> Bool {
        switch kind.category {
        case .identity, .contact: false
        case .social, .professional, .other: true
        }
    }

    // MARK: - HTML

    private static func html(
        name: String?,
        roleLine: String,
        details: [DetailUnit]
    ) -> String {
        var paragraphs: [String] = []
        let baseStyle = "margin: 0; font-family: -apple-system, sans-serif; font-size: 13px; color: #222222"
        let mutedStyle = "margin: 0; font-family: -apple-system, sans-serif; font-size: 12px; color: #555555"

        if let name {
            paragraphs.append(
                "<p style=\"\(baseStyle)\"><b>\(escape(name))</b></p>"
            )
        }
        if !roleLine.isEmpty {
            paragraphs.append("<p style=\"\(mutedStyle)\">\(escape(roleLine))</p>")
        }

        let detailHTMLLines = details.map { unit -> String in
            let rendered: String
            if let link = unit.link {
                rendered = "<a href=\"\(escapeAttribute(link))\">\(escape(unit.value))</a>"
            } else {
                rendered = escape(unit.value)
            }
            guard let label = unit.label else { return rendered }
            return "\(escape(label)): \(rendered)"
        }
        if !detailHTMLLines.isEmpty {
            paragraphs.append(
                "<p style=\"\(mutedStyle)\">\(detailHTMLLines.joined(separator: "<br>"))</p>"
            )
        }
        return paragraphs.joined(separator: "\n")
    }

    // MARK: - Catalog rendering

    private static func renderedHTML(
        _ sourceHTML: String,
        template: Template,
        request: SignatureDesignRequest
    ) -> String {
        let withoutImages = removingImageTags(from: sourceHTML)
        let (identitySource, details) = splitIdentityAndDetails(in: withoutImages)
        let content = addingRequiredImage(
            to: withoutImages,
            image: request.format == .htmlWithImages ? request.image : nil
        )
        let identity = addingRequiredImage(
            to: identitySource,
            image: request.format == .htmlWithImages ? request.image : nil
        )
        let hasDetails = !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tableStart = #"<table role="presentation" cellspacing="0" cellpadding="0" width="100%""#

        switch template {
        case .accentRail:
            return tableStart
                + #"><tbody><tr><td valign="top" style="border-left: 3px solid #2F5D62; padding: 4px 0 4px 12px">"#
                + content + "</td></tr></tbody></table>"
        case .framedCard:
            return tableStart
                + #" style="border: 1px solid #7B8790; background-color: #F5F2EC"><tbody><tr><td valign="top" style="padding: 12px 14px">"#
                + content + "</td></tr></tbody></table>"
        case .doubleRuleNameplate:
            return tableStart
                + #" style="border-top: 2px solid #243746; border-bottom: 2px solid #243746"><tbody><tr><td valign="top" style="padding: 9px 2px">"#
                + content + "</td></tr></tbody></table>"
        case .headerBand:
            guard hasDetails else {
                return tableStart
                    + #" style="border-bottom: 2px solid #7A2431"><tbody><tr><td valign="top" style="background-color: #F3E8EB; padding: 8px 12px">"#
                    + identity + "</td></tr></tbody></table>"
            }
            return tableStart
                + #" style="border-bottom: 2px solid #7A2431"><tbody><tr><td valign="top" style="background-color: #F3E8EB; padding: 8px 12px">"#
                + identity
                + #"</td></tr><tr><td valign="top" style="padding: 9px 12px 7px 12px">"#
                + details + "</td></tr></tbody></table>"
        case .splitCard:
            guard hasDetails else {
                return tableStart
                    + #" style="border-top: 3px solid #315C63"><tbody><tr><td valign="top" style="background-color: #EAF1F0; padding: 11px 14px">"#
                    + identity + "</td></tr></tbody></table>"
            }
            return tableStart
                + #" style="border-top: 3px solid #315C63"><tbody><tr><td valign="top" style="background-color: #EAF1F0; padding: 11px 14px">"#
                + identity
                + #"</td><td valign="top" style="border-left: 1px solid #8DA5A7; padding: 11px 14px">"#
                + details + "</td></tr></tbody></table>"
        case .editorialNameplate:
            guard hasDetails else {
                return tableStart
                    + #" style="border: 2px solid #222A35; border-bottom: 4px solid #B78734"><tbody><tr><td valign="top" style="padding: 11px 14px">"#
                    + identity + "</td></tr></tbody></table>"
            }
            return tableStart
                + #" style="border: 2px solid #222A35"><tbody><tr><td valign="top" style="padding: 11px 14px">"#
                + identity
                + #"</td></tr><tr><td valign="top" style="border-top: 4px solid #B78734; background-color: #F6F0E4; padding: 9px 14px">"#
                + details + "</td></tr></tbody></table>"
        case .quietStack:
            return tableStart
                + #"><tbody><tr><td valign="top">"#
                + content + "</td></tr></tbody></table>"
        case .centeredNameplate:
            return tableStart
                + #"><tbody><tr><td valign="top" style="text-align: center; padding: 2px 10px">"#
                + content + "</td></tr></tbody></table>"
        case .splitDirectory:
            guard hasDetails else {
                return tableStart
                    + #"><tbody><tr><td valign="top" style="padding-right: 18px">"#
                    + identity + "</td></tr></tbody></table>"
            }
            return tableStart
                + #"><tbody><tr><td valign="top" style="padding-right: 18px">"#
                + identity
                + #"</td><td valign="top" style="padding-left: 4px">"#
                + details + "</td></tr></tbody></table>"
        case .compactLedger:
            return tableStart
                + #"><tbody><tr><td valign="top" style="padding: 2px 0; line-height: 1.35">"#
                + content + "</td></tr></tbody></table>"
        }
    }

    private static func splitIdentityAndDetails(in html: String) -> (String, String) {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<p(?:\s+style="[^"]*")?>.*?</p>"#
        ) else { return (html, "") }
        let matches = expression.matches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html)
        )
        if matches.count >= 2 {
            let identityCount = matches.count >= 3 ? 2 : 1
            let boundaryMatch = matches[identityCount - 1]
            guard let boundaryRange = Range(boundaryMatch.range, in: html) else {
                return (html, "")
            }
            return (
                String(html[..<boundaryRange.upperBound]),
                String(html[boundaryRange.upperBound...])
            )
        }
        return (html, "")
    }

    private static func addingRequiredImage(
        to html: String,
        image: SignatureDesignRequest.ImageContext?
    ) -> String {
        guard let image else { return html }
        let tag = imageTag(image)
        switch image.asset.imageType {
        case .headshot:
            return #"<table role="presentation" cellspacing="0" cellpadding="0" width="100%"><tbody><tr><td valign="top" style="padding-right: 12px">"#
                + tag
                + #"</td><td valign="top">"#
                + html + "</td></tr></tbody></table>"
        case .logo, .banner:
            return #"<p style="margin: 0; padding-bottom: 8px">"#
                + tag + "</p>" + html
        }
    }

    private static func removingImageTags(from html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<img\b[^>]*>"#
        ) else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html),
            withTemplate: ""
        )
    }

    private static func renderedPlainText(
        _ source: String,
        template: Template
    ) -> String {
        let lines = source.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return source }
        let body = lines.joined(separator: "\n")
        switch template {
        case .accentRail:
            return lines.map { "│ \($0)" }.joined(separator: "\n")
        case .framedCard:
            let longestLine = lines.map(\.count).max() ?? 0
            if longestLine > 68 {
                let rule = String(repeating: "─", count: 68)
                return rule + "\n" + body + "\n" + rule
            }
            let width = max(24, longestLine)
            let top = "╭" + String(repeating: "─", count: width + 2) + "╮"
            let bottom = "╰" + String(repeating: "─", count: width + 2) + "╯"
            let middle = lines.map { line in
                "│ " + line.padding(toLength: width, withPad: " ", startingAt: 0) + " │"
            }
            return ([top] + middle + [bottom]).joined(separator: "\n")
        case .doubleRuleNameplate:
            let rule = String(repeating: "═", count: 32)
            return rule + "\n" + body + "\n" + rule
        case .headerBand:
            return "◆ " + lines[0] + "\n" + String(repeating: "─", count: 28)
                + (lines.count > 1 ? "\n" + lines.dropFirst().joined(separator: "\n") : "")
        case .splitCard:
            return "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" + body
                + "\n┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        case .editorialNameplate:
            return "╔═════════════════════════════╗\n" + body
                + "\n╚═════════════════════════════╝"
        case .quietStack:
            return body
        case .centeredNameplate:
            return lines[0] + (lines.count > 1 ? "\n\n" + lines.dropFirst().joined(separator: "\n") : "")
        case .splitDirectory:
            guard lines.count > 1 else { return body }
            return lines[0] + "\n"
                + lines.dropFirst().map { "│ \($0)" }.joined(separator: "\n")
        case .compactLedger:
            guard lines.count > 1 else { return body }
            return lines[0] + "\n"
                + lines.dropFirst().map { "· \($0)" }.joined(separator: "\n")
        }
    }

    private static func imageTag(_ image: SignatureDesignRequest.ImageContext) -> String {
        let asset = image.asset
        var tag = "<img src=\"\(SignatureImageToken.url(ownerID: image.ownerID, assetID: asset.id))\""
        if let width = asset.imageType.stampedWidth { tag += " width=\"\(width)\"" }
        if let height = asset.imageType.stampedHeight { tag += " height=\"\(height)\"" }
        tag += ">"
        return tag
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
