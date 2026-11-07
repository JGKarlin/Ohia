import Foundation
import OhiaCore

/// Normalizes raw model output into a send-ready reply body.
///
/// The MLX engine's `.draft` stop policy already truncates at
/// `END_OHIA_DRAFT` during streaming; this sanitizer is the engine-agnostic
/// backstop (the Apple Foundation fallback has no stop policy) and removes
/// the artifacts an instruct model can still leak around the body: thinking
/// spans, ChatML control tokens, a trailing end marker, fence lines, and a
/// fabricated trailing quoted-history block ("On … wrote:" + "> " lines) —
/// the real quoted original is appended mechanically at send time, so any
/// quoted tail in model output is fabrication by construction.
/// Returns the trimmed body, or an empty string when nothing usable remains
/// — callers treat that as a failed generation so the retry/backoff path
/// engages instead of persisting an empty draft.
enum GeneratedReplySanitizer {

    /// `stripTrailingQuotedBlock` is on for the reply/revision lanes, where
    /// the real quoted original is appended mechanically at send time and a
    /// trailing quote block is therefore fabrication by construction. The
    /// compose lane passes false: a new outbound email gets no mechanical
    /// quote, so trailing ">"-content there (a quoted passage the brief
    /// asked for, a shell snippet) is legitimate output.
    static func sanitize(
        _ raw: String,
        stripTrailingQuotedBlock: Bool = true,
        authorDisplayName: String? = nil,
        explicitInstructions: [String] = []
    ) -> String {
        var working = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // Closed thinking spans disappear wholesale.
        working = working.replacingOccurrences(
            of: #"(?is)<think(?:ing)?>.*?</think(?:ing)?>"#,
            with: "",
            options: .regularExpression
        )
        // An unterminated span means the model spent its budget reasoning;
        // everything from the open tag on is reasoning, not reply.
        working = working.replacingOccurrences(
            of: #"(?is)<think(?:ing)?>.*"#,
            with: "",
            options: .regularExpression
        )

        // Cut at the end marker when the stop policy didn't already.
        if let markerRange = working.range(of: GenerationStopPolicy.draftEndMarker) {
            working = String(working[..<markerRange.lowerBound])
        }

        // Strip ChatML / control tokens and fence lines.
        let lines = working
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                var line = String(rawLine)
                // An inline-image placeholder a signature left is no text.
                line = line.replacingOccurrences(of: "\u{FFFC}", with: "")
                for token in [
                    "<|im_start|>assistant",
                    "<|im_start|>user",
                    "<|im_start|>",
                    "<|im_end|>",
                    "<|endoftext|>",
                    "</s>"
                ] {
                    line = line.replacingOccurrences(of: token, with: "", options: [.caseInsensitive])
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let lowered = trimmed.lowercased()
                if lowered == "/no_think" || lowered == "assistant" { return nil }
                if trimmed.hasPrefix("```") { return nil }
                return line
            }

        let body = droppingTemplatePlaceholders(droppingLeadingMetaLabel(droppingLeadingSubjectLine(lines)),
                authorDisplayName: authorDisplayName)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A trailing quoted block in a reply is fabricated history, never
        // content: the send path quotes the actual original itself.
        // Mid-text quoting (inline replies the user asked for) is preserved.
        let strippedBody = stripTrailingQuotedBlock
            ? QuotedHistoryTail.strippingTrailingQuotedBlock(from: body)
            : body
        return groundingClosingIdentity(
            in: strippedBody,
            authorDisplayName: authorDisplayName,
            explicitInstructions: explicitInstructions
        )
    }

    /// Words that name the draft itself, in the app's languages.
    private static let metaLabelWords = ["draft", "draft reply", "reply draft", "email draft", "email body", "e-mail body",
        "下書き", "返信案", "メール本文", "草稿", "回复草稿", "邮件正文", "郵件正文", "본문", "이메일 본문", "초안", "답장 초안",
        "brouillon", "corps du message", "entwurf", "e-mail-text", "borrador", "cuerpo del correo", "bozza",
        "corpo dell'email", "rascunho", "corpo do e-mail", "черновик", "черновик письма", "черновик ответа", "текст письма",
        "draft email", "draft response"]

    /// How a line that presents what follows begins, in the app's languages.
    private static let presentingOpenings = ["here is", "here's", "here are", "below is", "以下は", "以下が", "以下是", "下面是",
        "다음은", "아래는", "voici", "hier ist", "anbei", "aquí está", "aquí tienes", "ecco", "aqui está", "segue", "вот", "ниже"]

    /// A line above the email that labels it, ending on the label ("Here is
    /// the draft:", "이메일 본문:", «Привет! Вот черновик:») is the model
    /// talking about the email, never part of it. A first line that only
    /// mentions a draft ("Thanks for the revised draft. My comments are
    /// below:") is the email's.
    private static func droppingLeadingMetaLabel(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return lines }
        let line = lines[first].trimmingCharacters(in: .whitespaces)
        guard line.count <= 160, let last = line.last, ":：".contains(last) else { return lines }
        let label = line.dropLast().trimmingCharacters(in: .whitespaces).lowercased()
        // Ending on the label, or presenting one ("Here's a draft reply to
        // Sam:", 「以下は返信案です：」, «Вот черновик письма:»).
        // In an unspaced script the label may close on a copula
        // (「以下は返信案です」, 「以下是邮件草稿内容」).
        let closed = label.replacingOccurrences(of: #"(です|である|だ|입니다|이다|内容|內容)$"#, with: "", options: .regularExpression)
        let endsOnLabel = metaLabelWords.contains { word in
            let label = word.first.map(ComposerDraftEvidence.isUnspacedLetter) == true ? closed : label
            guard label.hasSuffix(word) else { return false }
            // A whole word: "the draft", not "redraft".
            let before = label.dropLast(word.count).last
            return before.map { !$0.isLetter || word.first.map(ComposerDraftEvidence.isUnspacedLetter) == true } ?? true
        }
        // Presenting the label itself, perhaps for someone ("Here's a draft
        // reply to Sam"), never something else ("Here is the draft agenda
        // for Friday").
        let addressed = closed.replacingOccurrences(of: #"\s+(to|for|an|für|à|pour|para|per|для)\s+\S+(\s+\S+)?$"#, with: "",
            options: .regularExpression)
        let presents = presentingOpenings.contains(where: label.hasPrefix) && metaLabelWords.contains { word in
            guard addressed.hasSuffix(word) else { return false }
            let before = addressed.dropLast(word.count).last
            return before.map { !$0.isLetter || word.first.map(ComposerDraftEvidence.isUnspacedLetter) == true } ?? true
        }
        guard endsOnLabel || presents else { return lines }
        return Array(lines[lines.index(after: first)...])
    }

    /// The body is not the message: a subject line ("件名：…", "Subject: …")
    /// the model wrote above it is a header the send path sets itself.
    private static func droppingLeadingSubjectLine(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              OriginalHeaderBlock.field(lines[first])?.field == .subject else { return lines }
        return Array(lines[lines.index(after: first)...])
    }

    /// A line that is only a template slot ("[Your Title/Position]",
    /// "［所属］") is never sent: the model imitated a signature template the
    /// author's own signature replaces. A rule line left at the end with them
    /// ("-----" above the name) goes too.
    private static func droppingTemplatePlaceholders(_ lines: [String], authorDisplayName: String?) -> [String] {
        func isPlaceholder(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for (open, close) in [("[", "]"), ("［", "］")] {
                guard trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count > 2 else { continue }
                let inner = trimmed.dropFirst().dropLast()
                if !inner.contains(where: { "[]［］".contains($0) }), inner.contains(where: \.isLetter) {
                    return true
                }
            }
            return false
        }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        func isRule(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 3 && trimmed.allSatisfy { "-_=—─━―*~".contains($0) }
        }
        // Only the slots that end the email, after content they cannot be.
        var kept = lines
        var slots: [String] = []
        while let last = kept.lastIndex(where: { !isBlank($0) }), isPlaceholder(kept[last]),
              kept[..<last].contains(where: { !isBlank($0) && !isPlaceholder($0) }) {
            slots.insert(kept[last], at: 0)
            kept.removeSubrange(last...)
        }
        guard !slots.isEmpty else { return lines }
        // A closing the slots signed ("Best regards,\n[Your Name]") is signed
        // with the author's name when it is known, never with a slot.
        if let last = kept.last(where: { !isBlank($0) }), isRecognizedClosing(last) {
            if let name = authorDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                kept.append(preferredAuthorName(name))
            }
            return kept
        }
        // A rule line above the name, or ending the email, goes with them.
        let tail = Array(kept.indices.filter { !isBlank(kept[$0]) }.suffix(2))
        if let rule = tail.last(where: { isRule(kept[$0]) }) {
            kept.remove(at: rule)
            if rule > 0, rule < kept.count, isBlank(kept[rule - 1]), isBlank(kept[rule]) { kept.remove(at: rule) }
        }
        return kept
    }

    /// Generated prose may imitate a closing style, but it cannot establish
    /// who is sending the email. When a recognizable closing ends in any
    /// identity other than the resolved From identity, replace that line
    /// locally. A co-signer survives only when the user named that person in
    /// an explicit instruction for this draft.
    private static func groundingClosingIdentity(
        in body: String,
        authorDisplayName: String?,
        explicitInstructions: [String]
    ) -> String {
        guard let authorDisplayName = authorDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !authorDisplayName.isEmpty else {
            return body
        }

        var lines = body.components(separatedBy: "\n")
        let nonemptyIndices = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonemptyIndices.count >= 2 else {
            return body
        }
        let identityPosition = nonemptyIndices.index(before: nonemptyIndices.endIndex)
        let identityIndex = nonemptyIndices[identityPosition]
        let closingIndex = nonemptyIndices[nonemptyIndices.index(before: identityPosition)]
        guard isRecognizedClosing(lines[closingIndex]) else { return body }

        let generatedIdentity = lines[identityIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authorForms = allowedAuthorForms(authorDisplayName)
        if authorForms.contains(canonicalName(generatedIdentity)) {
            return body
        }
        guard isPlausibleIdentityLine(
            generatedIdentity,
            authorForms: authorForms
        ) else {
            return body
        }
        if explicitlyAuthorizesCoSigner(
            generatedIdentity,
            authorForms: authorForms,
            instructions: explicitInstructions
        ) {
            return body
        }

        lines[identityIndex] = preferredAuthorName(authorDisplayName)
        return lines.joined(separator: "\n")
    }

    private static func isRecognizedClosing(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:!."))
            .lowercased()
        return recognizedClosings.contains(normalized)
    }

    private static let recognizedClosings: Set<String> = [
        "all the best", "aloha", "best", "best regards", "best wishes",
        "cheers", "cordially", "kind regards", "mahalo", "regards",
        "respectfully", "respectfully yours", "sincerely", "take care",
        "thank you", "thanks", "warm regards", "warmly", "with gratitude",
        "yours", "yours truly"
    ]

    private static func isPlausibleIdentityLine(
        _ line: String,
        authorForms: Set<String>
    ) -> Bool {
        guard !line.isEmpty, line.count <= 80 else { return false }
        guard line.rangeOfCharacter(from: .decimalDigits) == nil,
              !line.contains("@"),
              !line.contains(":") else {
            return false
        }
        let coSigners = coSignerComponents(line)
        if coSigners.count >= 2,
           coSigners.contains(where: { authorForms.contains(canonicalName($0)) }) {
            return true
        }

        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard (1...4).contains(words.count) else { return false }
        let particles: Set<String> = [
            "da", "de", "del", "der", "di", "dos", "la", "van", "von"
        ]
        return words.allSatisfy { rawWord in
            let word = String(rawWord)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,'’\"()"))
            guard let first = word.first else { return false }
            let normalized = word.lowercased()
            if particles.contains(normalized) { return true }
            let initial = String(first)
            // Cased scripts must look like a name; uncased scripts (for
            // example Japanese) have equal uppercase/lowercase forms.
            return initial == initial.uppercased()
                || initial.uppercased() == initial.lowercased()
        }
    }

    private static func allowedAuthorForms(_ displayName: String) -> Set<String> {
        let parts = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var forms = Set([canonicalName(displayName)])
        if let first = parts.first {
            forms.insert(canonicalName(first))
        }
        if parts.count >= 2, let first = parts.first, let last = parts.last {
            forms.insert(canonicalName("\(first) \(last)"))
        }
        return forms
    }

    private static func preferredAuthorName(_ displayName: String) -> String {
        displayName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? displayName
    }

    private static func explicitlyAuthorizesCoSigner(
        _ generatedIdentity: String,
        authorForms: Set<String>,
        instructions: [String]
    ) -> Bool {
        let components = coSignerComponents(generatedIdentity)
        guard components.count >= 2,
              let authorIndex = components.firstIndex(where: {
                  authorForms.contains(canonicalName($0))
              }) else {
            return false
        }

        return components.enumerated().allSatisfy { index, component in
            if index == authorIndex { return true }
            let name = canonicalName(component)
            guard !name.isEmpty else { return false }
            return instructions.contains { instruction in
                instructionExplicitlyAuthorizesCoSigner(
                    name,
                    authorForms: authorForms,
                    instruction: instruction
                )
            }
        }
    }

    private static func instructionExplicitlyAuthorizesCoSigner(
        _ name: String,
        authorForms: Set<String>,
        instruction: String
    ) -> Bool {
        let clauses = instruction.components(separatedBy: CharacterSet(
            charactersIn: ".;:!?\n"
        ))
        let cuePatterns = [
            ["sign", "this"], ["sign", "it"], ["sign", "the", "email"],
            ["sign", "the", "message"], ["sign", "as"], ["sign", "from"],
            ["sign", "off"], ["signed", "by"], ["close", "with"],
            ["end", "with"], ["co", "sign"], ["cosign"],
            ["use", "a", "closing"], ["use", "the", "closing"],
            ["email", "signature"], ["closing", "should"],
            ["signature", "should"], ["署名"], ["連名"], ["差出人"]
        ]
        let nameTokens = name.split(separator: " ").map(String.init)
        guard !nameTokens.isEmpty else { return false }

        for clause in clauses {
            let tokens = canonicalName(clause).split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { continue }
            let cueRanges = cuePatterns.flatMap { ranges(of: $0, in: tokens) }
            guard !cueRanges.isEmpty else { continue }

            var bindingPatterns = [
                ["me", "and"] + nameTokens,
                ["me", "with"] + nameTokens,
                ["with"] + nameTokens,
                ["by"] + nameTokens,
                ["as"] + nameTokens,
            ]
            for authorForm in authorForms {
                let authorTokens = authorForm.split(separator: " ").map(String.init)
                bindingPatterns.append(authorTokens + ["and"] + nameTokens)
                bindingPatterns.append(nameTokens + ["and"] + authorTokens)
                bindingPatterns.append(authorTokens + ["with"] + nameTokens)
            }

            let bindingRanges = bindingPatterns.flatMap { ranges(of: $0, in: tokens) }
            if cueRanges.contains(where: { cue in
                bindingRanges.contains(where: { binding in
                    tokenDistance(between: cue, and: binding) <= 4
                })
            }) {
                return true
            }
        }
        return false
    }

    private static func ranges(
        of pattern: [String],
        in tokens: [String]
    ) -> [Range<Int>] {
        guard !pattern.isEmpty, pattern.count <= tokens.count else { return [] }
        return (0...(tokens.count - pattern.count)).compactMap { start in
            let end = start + pattern.count
            return Array(tokens[start..<end]) == pattern ? start..<end : nil
        }
    }

    private static func tokenDistance(
        between left: Range<Int>,
        and right: Range<Int>
    ) -> Int {
        if left.upperBound <= right.lowerBound {
            return right.lowerBound - left.upperBound
        }
        if right.upperBound <= left.lowerBound {
            return left.lowerBound - right.upperBound
        }
        return 0
    }

    private static func coSignerComponents(_ identity: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\s+(?:and|&|\+|/)\s+"#
        ) else {
            return [identity]
        }
        let range = NSRange(identity.startIndex..<identity.endIndex, in: identity)
        let separated = expression.stringByReplacingMatches(
            in: identity,
            range: range,
            withTemplate: "\u{001F}"
        )
        return separated
            .split(separator: "\u{001F}")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func canonicalName(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
            }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
