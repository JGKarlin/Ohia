import Foundation
import FoundationModels
import OhiaCore

/// The model family used for signature design, regeneration, and revision.
/// Read at call time so changing Models Settings affects the next request
/// without rebuilding `AppServices` or reopening the signature studio.
public enum SignatureGenerationEngineKind: String, CaseIterable, Identifiable, Sendable {
    case generativeModel
    case appleIntelligence

    public static let selectedEngineKey = "ohia.signature.selectedEngine"
    public static let defaultEngine: SignatureGenerationEngineKind = .generativeModel

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generativeModel:  return "Generative Model"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    public var shortDescription: String {
        switch self {
        case .generativeModel:
            return "Your selected downloaded Qwen model. Fully on-device."
        case .appleIntelligence:
            return "Apple's on-device foundation model, managed by macOS."
        }
    }

    public static func selected(defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: selectedEngineKey),
              let engine = Self(rawValue: rawValue) else {
            return defaultEngine
        }
        return engine
    }

    public static func setSelected(
        _ engine: Self,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(engine.rawValue, forKey: selectedEngineKey)
    }
}

typealias AppleSignatureGenerator = @Sendable (
    _ instructions: String,
    _ prompt: String,
    _ sampling: GenerationSampling
) async throws -> String

/// Signature-studio generation: one pass produces the three detail tiers
/// of the chosen format as separate engine calls sharing a KV-cached
/// prefix; regenerate and revise reuse the exact same call shape.
///
/// Async because Apple Foundation Models generation is asynchronous. The Qwen
/// engine remains blocking internally, so the studio runs calls in a detached
/// task. Cancellation is cooperative via `GenerationCancellation`.
public final class SignatureGenerationService: @unchecked Sendable {
    private let engine: any TrainingEngine
    private let translationContextProvider: (any TranslationContextProviding)?
    private let maxTokensPerCall: Int
    private let selectedEngine: @Sendable () -> SignatureGenerationEngineKind
    private let appleAvailability: @Sendable () -> Bool
    private let appleGenerator: AppleSignatureGenerator

    /// A detailed HTML tier carries every allowed fact plus a META block
    /// and a plain-text twin, and the styling is inline on every element —
    /// 600 tokens truncated those, which the parser then had to salvage.
    public convenience init(
        engine: any TrainingEngine,
        translationContextProvider: (any TranslationContextProviding)? = nil,
        maxTokensPerCall: Int = 1200
    ) {
        self.init(
            engine: engine,
            translationContextProvider: translationContextProvider,
            maxTokensPerCall: maxTokensPerCall,
            selectedEngine: { SignatureGenerationEngineKind.selected() },
            appleAvailability: {
                AppleIntelligenceAvailability.current().isAvailable
            },
            appleGenerator: { instructions, prompt, sampling in
                try await Self.generateWithAppleIntelligence(
                    instructions: instructions,
                    prompt: prompt,
                    sampling: sampling
                )
            }
        )
    }

    init(
        engine: any TrainingEngine,
        translationContextProvider: (any TranslationContextProviding)? = nil,
        maxTokensPerCall: Int = 1200,
        selectedEngine: @escaping @Sendable () -> SignatureGenerationEngineKind,
        appleAvailability: @escaping @Sendable () -> Bool,
        appleGenerator: @escaping AppleSignatureGenerator
    ) {
        self.engine = engine
        self.translationContextProvider = translationContextProvider
        self.maxTokensPerCall = maxTokensPerCall
        self.selectedEngine = selectedEngine
        self.appleAvailability = appleAvailability
        self.appleGenerator = appleGenerator
    }

    /// True when the model can serve a generation right now. The studio
    /// shows the readiness message and offers only the deterministic
    /// template composer while this is false.
    public var isAvailable: Bool {
        isAvailable(for: selectedEngine())
    }

    public func isAvailable(for engineKind: SignatureGenerationEngineKind) -> Bool {
        switch engineKind {
        case .generativeModel:
            return engine.isModelLoaded
        case .appleIntelligence:
            return appleAvailability()
        }
    }

    /// One pass: all three tiers, minimal → detailed, sequentially (the
    /// local model is single-lane; sequencing also maximizes prefix-cache
    /// hits). Each tier's reported design feeds the next tier's history, so
    /// the three cards diverge instead of converging on one archetype. A
    /// cancellation mid-pass returns the tiers finished so far by throwing
    /// only from the unfinished call.
    public func generateAllTiers(
        request: SignatureDesignRequest,
        cancellation: GenerationCancellation? = nil
    ) async throws -> [SignatureCandidate] {
        let request = grounded(request)
        var results: [SignatureCandidate] = []
        for tier in SignatureTier.allCases {
            try cancellation?.checkCancellation()
            let candidate = try await generate(
                tier: tier,
                request: request,
                attempt: 1,
                history: results.compactMap(\.historyEntry),
                cancellation: cancellation
            )
            results.append(candidate)
        }
        return results
    }

    /// Generates one tier at a caller-chosen attempt number. The studio
    /// drives its opening pass through this (one card at a time, so each
    /// lands in the UI as it finishes) rather than `generateAllTiers`, and
    /// passes `attempt: 1` — a first design must not be told to differ from
    /// attempts that never happened.
    public func generateTier(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int = 1,
        history: [SignatureDesignHistoryEntry] = [],
        cancellation: GenerationCancellation? = nil
    ) async throws -> SignatureCandidate {
        let request = grounded(request)
        return try await generate(
            tier: tier,
            request: request,
            attempt: max(1, attempt),
            history: history,
            cancellation: cancellation
        )
    }

    /// Regenerates one tier; `attempt` numbers and `history` force design
    /// variation (both ride the prompt suffix, so the prefix and cache key
    /// stay stable). The floor of 2 is what marks the call a regenerate in
    /// the prompt.
    public func regenerate(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int,
        history: [SignatureDesignHistoryEntry] = [],
        cancellation: GenerationCancellation? = nil
    ) async throws -> SignatureCandidate {
        let request = grounded(request)
        return try await generate(
            tier: tier,
            request: request,
            attempt: max(2, attempt),
            history: history,
            cancellation: cancellation
        )
    }

    /// Applies a free-text revision instruction to one tier's current
    /// output.
    public func revise(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        currentOutput: SignatureCandidate,
        instruction: String,
        cancellation: GenerationCancellation? = nil
    ) async throws -> SignatureCandidate {
        let request = grounded(request)
        let current = currentOutput.html ?? currentOutput.plainText
        let suffix = SignaturePromptBuilder.revisionSuffix(
            tier: tier,
            request: request,
            currentOutput: current,
            instruction: instruction
        )
        // A revision is an edit, not a redesign: it must apply the user's
        // instruction faithfully and leave everything else alone, so it
        // keeps the deterministic decode rather than the design lane's
        // creative one.
        let raw = try await run(
            suffix: suffix,
            request: request,
            sampling: .deterministic,
            cancellation: cancellation
        )
        var candidate = try parsingCandidate(raw, tier: tier, request: request)
        candidate = try repairingRequiredImage(candidate, request: request)
        candidate = preparingForAppTemplate(candidate)
        let revisionTemplateID = SignatureTemplateComposer.templateIDForRevision(
            currentID: currentOutput.archetype,
            instruction: instruction
        )
        candidate = SignatureTemplateComposer.preservingTemplate(
            revisionTemplateID,
            in: candidate,
            request: request
        )
        try validateRequiredImage(candidate, request: request)
        return normalizedForStudioPresentation(
            candidate,
            request: request,
            tier: tier
        )
    }

    /// Adds applicable user-wide dyads plus this account's target-language
    /// style rules. This happens before the tier-scoped suffix is built so the
    /// same grounded request reaches prompt construction and output validation.
    private func grounded(_ request: SignatureDesignRequest) -> SignatureDesignRequest {
        guard let translationContextProvider else { return request }
        let languageID = DraftLanguage.familyID(for: request.languageID) ?? request.languageID
        let target = SummarizationTargetLanguage(
            identifier: languageID,
            displayName: DraftLanguage.displayName(for: languageID)
        )
        let sourceLines = request.contact.populatedLines
        let sourceValues = sourceLines.compactMap(\.trimmedValue)
        let sourceText = sourceValues.joined(separator: "\n")
        let sourceLanguage = request.sourceLanguageID
            ?? DraftLanguage.detectedFamilyID(ofText: sourceText)
        var grounded = request
        grounded.translationContext = translationContextProvider.translationContext(
            forAccount: request.accountID,
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguage,
            targetLanguage: target
        )
        guard let translationContext = grounded.translationContext else { return grounded }
        let prepared = Self.protectingSignatureValues(
            sourceValues,
            exactGlossary: translationContext.exactGlossary
        )
        grounded.translationProtection = prepared.protection.mappings.isEmpty
            ? nil
            : prepared.protection
        grounded.protectedContactValues = Dictionary(
            uniqueKeysWithValues: zip(sourceLines.map(\.id), prepared.values)
        )
        return grounded
    }

    private static func protectingSignatureValues(
        _ values: [String],
        exactGlossary: [TranslationGlossaryEntry]
    ) -> (values: [String], protection: PreparedTranslationGlossaryProtection) {
        guard values.isEmpty == false else {
            return ([], .init(protectedText: "", mappings: [], requiredMarkerIDs: []))
        }
        var delimiter: String
        repeat {
            delimiter = "\n[[OHIA_SIGNATURE_SEGMENT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))]]\n"
        } while values.contains { $0.contains(delimiter) }
        let prepared = TranslationGlossaryProtection().prepare(
            bodyText: values.joined(separator: delimiter),
            exactGlossary: exactGlossary
        )
        let protectedValues = prepared.protectedText.components(separatedBy: delimiter)
        guard protectedValues.count == values.count else {
            return (values, .init(
                protectedText: values.joined(separator: "\n"),
                mappings: [],
                requiredMarkerIDs: []
            ))
        }
        return (protectedValues, prepared)
    }

    // MARK: - Engine dispatch

    /// Generates one tier, retrying once when the model returns something
    /// the parser refuses — in practice a design that dropped the name, the
    /// one failure the prompt cannot reliably prevent. Creative sampling
    /// re-rolls the output while the same attempt number keeps the retry in
    /// its app-selected decoration branch. A second failure propagates: the
    /// studio's card keeps the deterministic template it seeded with, which
    /// always states the name, and reports the error.
    private func generate(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int,
        history: [SignatureDesignHistoryEntry],
        cancellation: GenerationCancellation?
    ) async throws -> SignatureCandidate {
        do {
            return try await generateOnce(
                tier: tier, request: request, attempt: attempt,
                history: history, cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellation?.checkCancellation()
            guard case TrainingEngineError.generationFailed = error else { throw error }
            return try await generateOnce(
                tier: tier, request: request, attempt: attempt,
                history: history, cancellation: cancellation
            )
        }
    }

    private func generateOnce(
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int,
        history: [SignatureDesignHistoryEntry],
        cancellation: GenerationCancellation?
    ) async throws -> SignatureCandidate {
        let suffix = SignaturePromptBuilder.tierSuffix(
            tier: tier, request: request, attempt: attempt, history: history
        )
        let raw = try await run(
            suffix: suffix,
            request: request,
            sampling: .creative,
            cancellation: cancellation
        )
        var candidate = try parsingCandidate(raw, tier: tier, request: request)
        candidate = try repairingRequiredImage(candidate, request: request)
        candidate = repairingDecoration(
            candidate,
            tier: tier,
            request: request,
            attempt: attempt
        )
        try validateRequiredImage(candidate, request: request)
        try validateDecoration(
            candidate,
            tier: tier,
            format: request.format,
            attempt: attempt
        )
        return normalizedForStudioPresentation(
            candidate,
            request: request,
            tier: tier
        )
    }

    /// The sender's name is owned input, so dropping it is repairable model
    /// drift rather than a reason to discard an otherwise usable design.
    /// Parse first to preserve the parser's full validation; only its exact
    /// missing-name failure permits one deterministic insertion and reparse.
    private func parsingCandidate(
        _ raw: String,
        tier: SignatureTier,
        request: SignatureDesignRequest
    ) throws -> SignatureCandidate {
        let restoredRaw: String
        do {
            restoredRaw = try request.translationProtection?.restore(
                in: raw,
                requireAll: false
            ) ?? raw
        } catch {
            throw TrainingEngineError.generationFailed(
                "The model corrupted a protected glossary rendering."
            )
        }
        do {
            return try SignatureOutputParser.parse(restoredRaw, tier: tier, request: request)
        } catch let error as TrainingEngineError {
            guard case .generationFailed(let detail) = error,
                  detail == "The model produced a signature without the name.",
                  let preferredName = request.preferredNameRendering else {
                throw error
            }
            return try SignatureOutputParser.parse(
                insertingRequiredName(preferredName, in: restoredRaw, format: request.format),
                tier: tier,
                request: request
            )
        }
    }

    private func insertingRequiredName(
        _ name: String,
        in raw: String,
        format: SignatureFormat
    ) -> String {
        let safeName = safeRequiredName(name)
        guard safeName.isEmpty == false else { return raw }

        if format == .plainText {
            return inserting(
                safeName,
                after: SignaturePromptBuilder.beginTextMarker,
                in: raw
            ) ?? (safeName + "\n" + raw)
        }

        let htmlName = "<p><strong>\(escapedHTMLText(safeName))</strong></p>"
        var result = inserting(
            htmlName,
            after: SignaturePromptBuilder.beginHTMLMarker,
            in: raw
        ) ?? (htmlName + raw)
        if let withTextName = inserting(
            safeName,
            after: SignaturePromptBuilder.beginTextMarker,
            in: result
        ) {
            result = withTextName
        }
        return result
    }

    private func inserting(
        _ content: String,
        after marker: String,
        in text: String
    ) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        return String(text[..<range.upperBound])
            + "\n" + content
            + String(text[range.upperBound...])
    }

    private func safeRequiredName(_ name: String) -> String {
        var result = name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        for marker in [
            "BEGIN_SIGNATURE_META", "END_SIGNATURE_META",
            SignaturePromptBuilder.beginHTMLMarker, "END_SIGNATURE_HTML",
            SignaturePromptBuilder.beginTextMarker, "END_SIGNATURE_TEXT"
        ] {
            result = result.replacingOccurrences(of: marker, with: " ")
        }
        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func escapedHTMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Repairs model drift at the owned-asset boundary. The prompt still asks
    /// for exact placement, but an omitted tag must not turn HTML + Image into
    /// ordinary HTML or strand the user on the built-in card.
    private func repairingRequiredImage(
        _ candidate: SignatureCandidate,
        request: SignatureDesignRequest
    ) throws -> SignatureCandidate {
        guard request.format == .htmlWithImages else { return candidate }
        guard let image = request.image else {
            throw TrainingEngineError.generationFailed(
                "HTML plus image generation had no image context."
            )
        }
        let token = SignatureImageToken.url(
            ownerID: image.ownerID,
            assetID: image.asset.id
        )
        guard candidate.html?.contains(token) != true else { return candidate }

        guard let html = candidate.html else {
            return SignatureTemplateComposer.compose(
                tier: candidate.tier,
                request: request
            )
        }

        var result = candidate
        result.html = insertingRequiredImage(image, in: html)
        return result
    }

    private func insertingRequiredImage(
        _ image: SignatureDesignRequest.ImageContext,
        in html: String
    ) -> String {
        let tag = signatureImageTag(image)
        switch image.asset.imageType {
        case .headshot:
            guard let expression = try? NSRegularExpression(
                pattern: #"(?i)<p(?:\s+style="[^"]*")?>"#
            ) else { return tag + "<br>" + html }
            let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = expression.firstMatch(in: html, range: fullRange),
                  let range = Range(match.range, in: html) else {
                return tag + "<br>" + html
            }
            let openingTag = String(html[range])
            return html.replacingCharacters(
                in: range,
                with: openingTag + tag + "&nbsp;"
            )
        case .logo, .banner:
            return #"<p style="margin: 0">\#(tag)</p>"# + html
        }
    }

    private func signatureImageTag(
        _ image: SignatureDesignRequest.ImageContext
    ) -> String {
        let asset = image.asset
        let token = SignatureImageToken.url(
            ownerID: image.ownerID,
            assetID: asset.id
        )
        var tag = "<img src=\"\(token)\""
        if let width = asset.imageType.stampedWidth {
            tag += " width=\"\(width)\""
        }
        if let height = asset.imageType.stampedHeight {
            tag += " height=\"\(height)\""
        }
        return tag + ">"
    }

    /// The alternation and exact structure are app-owned. Qwen still supplies
    /// the localized wording, links, and typographic emphasis, but its outer
    /// decoration is removed and replaced with one concrete catalog template.
    private func repairingDecoration(
        _ candidate: SignatureCandidate,
        tier: SignatureTier,
        request: SignatureDesignRequest,
        attempt: Int
    ) -> SignatureCandidate {
        if request.format != .plainText, candidate.html == nil {
            return SignatureTemplateComposer.compose(
                tier: tier,
                request: request,
                attempt: attempt
            )
        }
        let prepared = preparingForAppTemplate(candidate)
        return SignatureTemplateComposer.applyingCatalogTemplate(
            to: prepared,
            tier: tier,
            request: request,
            attempt: attempt
        )
    }

    private func preparingForAppTemplate(
        _ candidate: SignatureCandidate
    ) -> SignatureCandidate {
        var result = candidate
        if let html = result.html {
            result.html = removingStandaloneHTMLDecoration(
                from: removingDecorationStyles(in: html, removePanels: true)
            )
        }
        result.plainText = removingDecorationOnlyLines(from: result.plainText)
        return result
    }

    private func removingDecorationStyles(
        in html: String,
        removePanels: Bool
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\sstyle="([^"]*)""#
        ) else { return html }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in expression.matches(in: html, range: fullRange).reversed() {
            guard let attributeRange = Range(match.range, in: result),
                  let styleRange = Range(match.range(at: 1), in: html) else { continue }
            let kept = String(html[styleRange])
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { declaration in
                    guard let colon = declaration.firstIndex(of: ":") else {
                        return true
                    }
                    let property = declaration[..<colon]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if Self.borderProperties.contains(property) { return false }
                    if removePanels, property == "background-color" {
                        let value = declaration[declaration.index(after: colon)...]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return !isVisibleCSSColor(value)
                    }
                    return true
                }
            let replacement = kept.isEmpty
                ? ""
                : " style=\"\(kept.joined(separator: "; "))\""
            result.replaceSubrange(attributeRange, with: replacement)
        }
        return result
    }

    private func removingStandaloneHTMLDecoration(from html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<p(?:\s+style="[^"]*")?>\s*(?:<span(?:\s+style="[^"]*")?>\s*)?[^\p{L}\p{N}<]{1,80}(?:\s*</span>)?\s*</p>"#
        ) else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html),
            withTemplate: ""
        )
    }

    private func removingDecorationOnlyLines(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter {
            !isDecorationOnlyLine($0)
        }
        return trimmingSignatureLines(in: lines.joined(separator: "\n"))
    }

    private func isDecorationOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private func trimmingSignatureLines(in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// `HTML + Image` is a format contract, not a prompt preference. The
    /// sanitizer has already reduced the markup to owned `ohia-sig://`
    /// tokens, so the exact expected token is both necessary and sufficient.
    /// Generation repairs an omission first; this check guards that repair so
    /// a card can never silently become ordinary HTML.
    private func validateRequiredImage(
        _ candidate: SignatureCandidate,
        request: SignatureDesignRequest
    ) throws {
        guard request.format == .htmlWithImages else { return }
        guard let image = request.image else {
            throw TrainingEngineError.generationFailed(
                "HTML plus image generation had no image context."
            )
        }
        let token = SignatureImageToken.url(
            ownerID: image.ownerID,
            assetID: image.asset.id
        )
        guard candidate.html?.contains(token) == true else {
            throw TrainingEngineError.generationFailed(
                "The model omitted the required signature image."
            )
        }
    }

    /// The cards are editable Cocoa attributed strings. Catalog layouts use
    /// presentation tables because AppKit preserves their borders; paragraph
    /// margins still need compaction so the editor stays readable.
    private func normalizedForStudioPresentation(
        _ candidate: SignatureCandidate,
        request: SignatureDesignRequest,
        tier: SignatureTier
    ) -> SignatureCandidate {
        var result = candidate
        if var html = candidate.html {
            html = normalizedParagraphMargins(in: html)
            html = normalizedPunctuation(inHTML: html)
            html = normalizedInlineBoundaries(in: html)
            html = normalizedSemanticGrouping(
                in: html,
                request: request,
                tier: tier
            )
            result.html = html
        }

        result.plainText = normalizedPlainFactBoundaries(
            in: normalizedPunctuation(in: candidate.plainText),
            request: request,
            tier: tier
        )
        return result
    }

    /// Keeps a creative design's typography while preventing detailed
    /// signatures from collapsing into one dense sentence. Identity facts
    /// stay compact; labeled routes begin on their own lines.
    private func normalizedSemanticGrouping(
        in html: String,
        request: SignatureDesignRequest,
        tier: SignatureTier
    ) -> String {
        let allowedLines = request.contact.lines(allowedIn: tier)
        let compactIdentityKinds: Set<SignatureFieldKind> = [
            .title, .organization, .department, .lab
        ]
        let identityValues = allowedLines.compactMap { line -> String? in
            guard compactIdentityKinds.contains(line.kind) else { return nil }
            return line.trimmedValue
        }

        var result = html
        for pair in zip(identityValues, identityValues.dropFirst()) {
            let first = NSRegularExpression.escapedPattern(for: pair.0)
            let second = NSRegularExpression.escapedPattern(for: pair.1)
            let closingTags = #"((?:\s*</(?:span|b|strong|i|em|u|a|font)>)*)"#
            let openingTags = #"((?:<(?:span|b|strong|i|em|u|a|font)\b[^>]*>\s*)*)"#
            result = replacingMatches(
                in: result,
                pattern: first + closingTags + #"(?:\s|&nbsp;)*"# + openingTags + second,
                with: NSRegularExpression.escapedTemplate(for: pair.0)
                    + "$1&nbsp;·&nbsp;$2"
                    + NSRegularExpression.escapedTemplate(for: pair.1)
            )
        }
        result = normalizedHTMLFactBoundaries(
            in: result,
            lines: allowedLines
        )

        let labeledLines = allowedLines.filter {
            $0.kind.category != .identity
                && !compactIdentityKinds.contains($0.kind)
        }
        for line in labeledLines {
            let label = NSRegularExpression.escapedPattern(for: line.displayLabel)
            result = replacingMatches(
                in: result,
                pattern: #"(?i)(?<!\p{L})("# + label + #")\s*:(?:\s|&nbsp;)*"#,
                with: "$1:&nbsp;"
            )
            result = replacingMatches(
                in: result,
                pattern: #"(?i)(<br>\s*)("# + label + #")\s*:(?:\s|&nbsp;)*"#,
                with: "$1$2:&nbsp;"
            )
            result = replacingMatches(
                in: result,
                pattern: #"(?i)(?<![\p{L}\p{N}>])("# + label + #")\s*:(?:\s|&nbsp;)*"#,
                with: "<br>$1:&nbsp;"
            )
            result = replacingMatches(
                in: result,
                pattern: #"(?i)(?<![\p{L}\p{N}])("# + label + #")(?=\s*<br>)"#,
                with: "<br>$1"
            )
        }

        result = replacingMatches(
            in: result,
            pattern: #"(?i)(?:<br>\s*){2,}"#,
            with: "<br>"
        )
        return replacingMatches(
            in: result,
            pattern: #"(?i)(<p(?:\s+style=\"[^\"]*\")?>)\s*<br>"#,
            with: "$1"
        )
    }

    private func normalizedHTMLFactBoundaries(
        in html: String,
        lines: [SignatureContactLine]
    ) -> String {
        let closingTags = #"((?:\s*</(?:span|b|strong|i|em|u|a|font)>)*)"#
        let openingTags = #"((?:<(?:span|b|strong|i|em|u|a|font)\b[^>]*>\s*)*)"#
        var result = html

        for sourceLine in lines {
            for sourceValue in sourceLine.scrubValues {
                for targetLine in lines {
                    if sourceLine.id != targetLine.id,
                       targetLine.kind.category != .identity {
                        let targetLabel = NSRegularExpression.escapedPattern(
                            for: targetLine.displayLabel
                        )
                        result = replacingMatches(
                            in: result,
                            pattern: NSRegularExpression.escapedPattern(for: sourceValue)
                                + closingTags + #"(?:\s|&nbsp;)*"# + openingTags
                                + "(" + targetLabel + #")\s*:(?:\s|&nbsp;)*"#,
                            with: NSRegularExpression.escapedTemplate(for: sourceValue)
                                + "$1<br>$2$3:&nbsp;"
                        )
                    }
                    for targetValue in targetLine.scrubValues {
                        guard sourceLine.id != targetLine.id
                                || sourceValue != targetValue else { continue }
                        let sameLine = sourceLine.id == targetLine.id
                        let between = sameLine
                            ? #"(?:\s|&nbsp;|,)*"#
                            : #"(?:\s|&nbsp;)*"#
                        result = replacingMatches(
                            in: result,
                            pattern: NSRegularExpression.escapedPattern(for: sourceValue)
                                + closingTags + between + openingTags
                                + NSRegularExpression.escapedPattern(for: targetValue),
                            with: NSRegularExpression.escapedTemplate(for: sourceValue)
                                + "$1"
                                + (sameLine ? ", " : "<br>")
                                + "$2"
                                + NSRegularExpression.escapedTemplate(for: targetValue)
                        )
                    }
                }
            }
        }
        return result
    }

    private func normalizedPlainFactBoundaries(
        in text: String,
        request: SignatureDesignRequest,
        tier: SignatureTier
    ) -> String {
        let lines = request.contact.lines(allowedIn: tier)
        var result = text
        for sourceLine in lines {
            for sourceValue in sourceLine.scrubValues {
                for targetLine in lines {
                    if sourceLine.id != targetLine.id,
                       targetLine.kind.category != .identity {
                        let targetLabel = NSRegularExpression.escapedPattern(
                            for: targetLine.displayLabel
                        )
                        result = replacingMatches(
                            in: result,
                            pattern: NSRegularExpression.escapedPattern(for: sourceValue)
                                + #"[ \t]*("# + targetLabel + #")\s*:\s*"#,
                            with: NSRegularExpression.escapedTemplate(for: sourceValue)
                                + "\n$1: "
                        )
                    }
                    for targetValue in targetLine.scrubValues {
                        guard sourceLine.id != targetLine.id
                                || sourceValue != targetValue else { continue }
                        let sameLine = sourceLine.id == targetLine.id
                        let between = sameLine
                            ? #"(?:[ \t]*,[ \t]*|[ \t]*)"#
                            : #"[ \t]*"#
                        result = replacingMatches(
                            in: result,
                            pattern: NSRegularExpression.escapedPattern(for: sourceValue)
                                + between
                                + NSRegularExpression.escapedPattern(for: targetValue),
                            with: NSRegularExpression.escapedTemplate(for: sourceValue)
                                + (sameLine ? ", " : "\n")
                                + NSRegularExpression.escapedTemplate(for: targetValue)
                        )
                    }
                }
            }
        }
        return result
    }

    private func normalizedInlineBoundaries(in html: String) -> String {
        var result = replacingMatches(
            in: html,
            pattern: #"([\p{L}\p{N}])(?=<a\b)"#,
            with: "$1<br>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)(</a>)\s*(?=<a\b)"#,
            with: "$1&nbsp;|&nbsp;"
        )
        return result
    }

    private static let borderProperties: Set<String> = [
        "border", "border-left", "border-right", "border-top", "border-bottom",
        "border-style", "border-width", "border-color"
    ]

    private func normalizedParagraphMargins(in html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)<p(?:\s+style="([^"]*)")?>"#
        ) else { return html }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in expression.matches(in: html, range: fullRange).reversed() {
            guard let openingRange = Range(match.range, in: result) else { continue }
            let replacement: String
            if match.range(at: 1).location == NSNotFound {
                replacement = #"<p style="margin: 0">"#
            } else if let styleRange = Range(match.range(at: 1), in: html) {
                let style = String(html[styleRange])
                replacement = #"<p style="\#(normalizedMargin(in: style))">"#
            } else {
                continue
            }
            result.replaceSubrange(openingRange, with: replacement)
        }
        return result
    }

    private func normalizedMargin(in style: String) -> String {
        var declarations = style.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if let index = declarations.firstIndex(where: {
            $0.split(separator: ":", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "margin"
        }) {
            let parts = declarations[index].split(separator: ":", maxSplits: 1)
            if parts.count != 2 || !isCompactMargin(String(parts[1])) {
                declarations[index] = "margin: 0"
            }
        } else {
            declarations.append("margin: 0")
        }
        return declarations.joined(separator: "; ")
    }

    private func isCompactMargin(_ value: String) -> Bool {
        let components = value.split(whereSeparator: { $0.isWhitespace })
        guard !components.isEmpty, components.count <= 4 else { return false }
        return components.allSatisfy { component in
            let part = component.lowercased()
            if part == "0" { return true }
            guard part.hasSuffix("px"),
                  let points = Double(part.dropLast(2)) else { return false }
            return (0...8).contains(points)
        }
    }

    private func normalizedPunctuation(inHTML html: String) -> String {
        var result = ""
        var cursor = html.startIndex
        while cursor < html.endIndex,
              let tagStart = html[cursor...].firstIndex(of: "<") {
            result += normalizedHTMLTextPunctuation(
                in: String(html[cursor..<tagStart])
            )
            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else {
                result += String(html[tagStart...])
                return result
            }
            result += String(html[tagStart...tagEnd])
            cursor = html.index(after: tagEnd)
        }
        if cursor < html.endIndex {
            result += normalizedHTMLTextPunctuation(in: String(html[cursor...]))
        }
        return result
    }

    private func normalizedHTMLTextPunctuation(in text: String) -> String {
        let normalized = normalizedPunctuation(in: text)
        return replacingMatches(
            in: normalized,
            pattern: #"(?:(?:&nbsp;)|\s)*([|·•])(?:(?:&nbsp;)|\s)*"#,
            with: "&nbsp;$1&nbsp;"
        )
    }

    private func normalizedPunctuation(in text: String) -> String {
        var result = replacingMatches(
            in: text,
            pattern: #"(\p{L}):(?=[^\s/])"#,
            with: "$1: "
        )
        result = replacingMatches(
            in: result,
            pattern: #",(?=\S)"#,
            with: ", "
        )
        result = replacingMatches(
            in: result,
            pattern: #"\s*([|·•])\s*"#,
            with: " $1 "
        )
        return result
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement
        )
    }

    /// Prompt compliance is a visible-output contract, not a META claim.
    /// Validate the sanitized HTML so malformed tags or ignored instructions
    /// trigger the existing one-shot retry instead of shipping an apparently
    /// undecorated result from a decorated turn (or vice versa).
    private func validateDecoration(
        _ candidate: SignatureCandidate,
        tier: SignatureTier,
        format: SignatureFormat,
        attempt: Int
    ) throws {
        guard format != .plainText, let html = candidate.html else { return }
        let declarations = inlineStyleDeclarations(in: html)
        let hasBorder = hasVisibleBorder(in: html)
        let hasPanel = declarations.contains { declaration in
            declaration.property == "background-color"
                && isVisibleCSSColor(declaration.value)
        }
        let requiresDecoration = SignaturePromptBuilder.requiresDecoration(
            tier: tier,
            attempt: attempt
        )

        if requiresDecoration && !hasBorder {
            throw TrainingEngineError.generationFailed(
                "The decorated signature did not contain a visible border."
            )
        }
        if !requiresDecoration && (hasBorder || hasPanel) {
            throw TrainingEngineError.generationFailed(
                "The undecorated signature contained decorative styling."
            )
        }
    }

    private func hasVisibleBorder(in html: String) -> Bool {
        return inlineStyleDeclarations(in: html).contains { declaration in
            Self.borderProperties.contains(declaration.property)
                && isVisibleBorderValue(declaration.value)
        }
    }

    private func inlineStyleDeclarations(
        in html: String
    ) -> [(property: String, value: String)] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)style\s*=\s*[\"']([^\"']*)[\"']"#
        ) else { return [] }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: fullRange).flatMap {
            match -> [(property: String, value: String)] in
            guard let range = Range(match.range(at: 1), in: html) else { return [] }
            return html[range].split(separator: ";").compactMap { rawDeclaration in
                guard let colon = rawDeclaration.firstIndex(of: ":") else { return nil }
                let property = rawDeclaration[..<colon]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = rawDeclaration[rawDeclaration.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !property.isEmpty, !value.isEmpty else { return nil }
                return (property, value)
            }
        }
    }

    /// App-owned templates use 1–4px email-compatible borders: hairlines for
    /// quiet cards and stronger rails/bands for the editorial set. Declaration
    /// presence alone is not visual proof.
    private func isVisibleBorderValue(_ value: String) -> Bool {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 3 else { return false }
        let widthText = parts[0].lowercased()
        guard widthText.hasSuffix("px"),
              let width = Double(widthText.dropLast(2)),
              (1...4).contains(width) else { return false }
        let lineStyle = parts[1].lowercased()
        guard ["solid", "dashed", "double"].contains(lineStyle) else { return false }
        return isVisibleCSSColor(parts.dropFirst(2).joined(separator: " "))
    }

    private func isVisibleCSSColor(_ value: String) -> Bool {
        let color = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !color.isEmpty,
              color != "transparent",
              color != "none" else { return false }

        if color.hasPrefix("#") {
            let hex = color.dropFirst()
            guard [3, 4, 6, 8].contains(hex.count),
                  hex.allSatisfy(\.isHexDigit) else { return false }
            if hex.count == 4, let alpha = Int(String(hex.suffix(1)), radix: 16) {
                return alpha > 0
            }
            if hex.count == 8, let alpha = Int(String(hex.suffix(2)), radix: 16) {
                return alpha > 0
            }
            return true
        }

        if color.hasPrefix("rgba(") || color.hasPrefix("hsla(") {
            guard color.hasSuffix(")") else { return false }
            if let comma = color.lastIndex(of: ",") {
                let alpha = color[color.index(after: comma)..<color.index(before: color.endIndex)]
                return isPositiveCSSAlpha(String(alpha))
            }
            guard let slash = color.lastIndex(of: "/") else { return false }
            let alpha = color[color.index(after: slash)..<color.index(before: color.endIndex)]
            return isPositiveCSSAlpha(String(alpha))
        }

        if color.hasPrefix("rgb(") || color.hasPrefix("hsl(") {
            guard color.hasSuffix(")") else { return false }
            guard let slash = color.lastIndex(of: "/") else { return true }
            let alpha = color[color.index(after: slash)..<color.index(before: color.endIndex)]
            return isPositiveCSSAlpha(String(alpha))
        }

        let namedColors: Set<String> = [
            "black", "silver", "gray", "grey", "white", "maroon", "red",
            "purple", "fuchsia", "green", "lime", "olive", "yellow", "navy",
            "blue", "teal", "aqua", "orange", "brown", "currentcolor"
        ]
        return namedColors.contains(color)
    }

    private func isPositiveCSSAlpha(_ rawValue: String) -> Bool {
        let alpha = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if alpha.hasSuffix("%"), let value = Double(alpha.dropLast()) {
            return value > 0
        }
        return Double(alpha).map { $0 > 0 } ?? false
    }

    private func run(
        suffix: String,
        request: SignatureDesignRequest,
        sampling: GenerationSampling,
        cancellation: GenerationCancellation?
    ) async throws -> String {
        let prompt = PrefixCachedPrompt(
            cacheKey: SignaturePromptBuilder.cacheKey(for: request),
            prefix: SignaturePromptBuilder.prefix(for: request),
            suffix: suffix
        )

        let output: String
        switch selectedEngine() {
        case .generativeModel:
            guard engine.isModelLoaded else {
                throw TrainingEngineError.modelUnavailable(
                    "The generative model is not ready yet."
                )
            }
            if let worker = engine as? WorkerGenerationEngine {
                output = try worker.generate(
                    prompt: prompt,
                    maxTokens: maxTokensPerCall,
                    cancellation: cancellation ?? GenerationCancellation(),
                    lane: .userInteractive,
                    activityKind: .designing,
                    sampling: sampling
                )
            } else {
                // In-process engines (and test doubles) go through the
                // capability dispatch. Engines that cannot honor sampling
                // still generate; they simply decode deterministically.
                output = try PrefixCachedGeneration.generate(
                    engine: engine,
                    prompt: prompt,
                    maxTokens: maxTokensPerCall,
                    cancellation: cancellation ?? GenerationCancellation(),
                    sampling: sampling
                )
            }

        case .appleIntelligence:
            guard appleAvailability() else {
                throw TrainingEngineError.modelUnavailable(
                    "Apple Intelligence is not available on this Mac right now."
                )
            }
            try cancellation?.checkCancellation()
            try Task.checkCancellation()
            output = try await appleGenerator(
                prompt.prefix,
                prompt.suffix,
                sampling
            )
            try Task.checkCancellation()
            try cancellation?.checkCancellation()
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrainingEngineError.generationFailed(
                "The model returned empty signature output."
            )
        }
        return trimmed
    }

    private static func generateWithAppleIntelligence(
        instructions: String,
        prompt: String,
        sampling: GenerationSampling
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            temperature: Double(sampling.temperature)
        )
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw TrainingEngineError.generationFailed(
                    "Apple Intelligence declined this signature request."
                )
            case .exceededContextWindowSize:
                throw TrainingEngineError.modelUnavailable(
                    "This signature request is too large for Apple Intelligence."
                )
            default:
                throw TrainingEngineError.generationFailed(
                    "Apple Intelligence could not generate the signature: \(error.localizedDescription)"
                )
            }
        } catch {
            throw TrainingEngineError.generationFailed(
                "Apple Intelligence could not generate the signature: \(error.localizedDescription)"
            )
        }
    }
}
