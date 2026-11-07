// EmailLanguageDetection.swift
// Language-agnostic detection of an email body's dominant language, plus the
// decision of whether to offer an on-demand translation into the user's chosen
// summary/translation language. Backed by Apple's NaturalLanguage recognizer
// so no language is privileged — the same path runs for every script.

import Foundation
import NaturalLanguage
import OhiaCore

/// The outcome of evaluating a body against the active translation target: a
/// yes/no on whether to surface the Translate affordance, plus the detected
/// source language code (BCP-47 identifier from the recognizer, e.g. `ja`,
/// `zh-Hans`, `fr`) when one was found confidently. Used for the column
/// header autonym and passed to the Apple Translation API as the source
/// locale; the offer decision is what gates the control.
public struct EmailTranslationOffer: Sendable, Equatable {
    public let shouldOffer: Bool
    public let detectedLanguageCode: String?

    public init(shouldOffer: Bool, detectedLanguageCode: String?) {
        self.shouldOffer = shouldOffer
        self.detectedLanguageCode = detectedLanguageCode
    }

    public static let none = EmailTranslationOffer(shouldOffer: false, detectedLanguageCode: nil)
}

public enum EmailLanguageDetector {
    /// Minimum count of letters/ideographs the cleaned sample must contain
    /// before detection is trusted. Below this, NLLanguageRecognizer's guess is
    /// noise (a one-word greeting, a tracking footer) and we never offer.
    static let minimumMeaningfulCharacters = 16

    /// Confidence floor for the top language hypothesis. Foreign scripts (CJK,
    /// Cyrillic, Arabic, Thai, …) clear this trivially; same-script European
    /// pairs (es/pt/it) need the recognizer to be reasonably sure before we
    /// claim the body is "foreign" relative to the target.
    static let minimumConfidence = 0.55

    /// Characters of body text fed to the recognizer. A prefix is plenty for a
    /// dominant-language read and keeps detection cheap enough to run on the
    /// main actor when a body loads.
    static let sampleCharacterLimit = 1_600

    /// A mixed-language body needs enough non-target evidence before we offer.
    /// This keeps signatures, greetings, and isolated proper nouns from making
    /// every mostly-target-language message look translatable.
    static let minimumMixedLanguageCharacters = 48

    /// Mixed-language evidence also has to be a meaningful share of the body, not
    /// merely an absolute count. This keeps long same-language messages from
    /// offering translation because of a single noisy segment.
    static let minimumMixedLanguageProportion = 0.15

    /// Paragraph/window-level recognition is noisier than whole-body detection,
    /// so require a little more confidence before treating a segment as source
    /// evidence.
    static let minimumSegmentConfidence = 0.65

    /// Non-Latin script buckets are strong evidence, but very small runs often
    /// come from names or short greetings rather than body content.
    static let minimumScriptEvidenceCharacters = 32

    /// Bound paragraph/window recognizer work; this runs when a body appears in
    /// the reader, so it must stay comfortably cheap on the main actor.
    static let maxSegmentCandidates = 24

    /// Detects the dominant language of `text` and returns its normalized BCP-47
    /// identifier (e.g. `ja`, `zh-Hans`, `pt-BR`), or `nil` when the text is too
    /// short, the recognizer is unsure, or the language is undetermined.
    /// Keep this strict: corpus filters use it to decide whether a chunk is
    /// actually written in one target language.
    public static func detectDominantLanguageCode(in text: String) -> String? {
        guard let dominant = dominantLanguage(in: text) else { return nil }
        return normalizedLanguageIdentifier(dominant.rawValue)
    }

    /// Returns the dominant `NLLanguage` for `text`, or `nil` when detection is
    /// inconclusive.
    static func dominantLanguage(in text: String) -> NLLanguage? {
        let sample = meaningfulSample(from: text)
        guard countMeaningfulCharacters(in: sample) >= minimumMeaningfulCharacters else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else {
            return nil
        }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[dominant] ?? 0
        guard confidence >= minimumConfidence else { return nil }
        return dominant
    }

    /// Decides whether to offer translation of `bodyText` into the language
    /// identified by `targetLanguageIdentifier` (the resolved summary/translation
    /// language). Offers when a confident dominant language, mixed-language
    /// paragraph, or substantial script run differs from the target's base
    /// language.
    public static func evaluate(
        bodyText: String,
        targetLanguageIdentifier: String
    ) -> EmailTranslationOffer {
        let target = canonicalBaseCode(targetLanguageIdentifier)
        let primary = primaryLanguageCandidate(in: bodyText)
        if let primary,
           canonicalBaseCode(primary.code) != target {
            return EmailTranslationOffer(shouldOffer: true, detectedLanguageCode: primary.code)
        }

        let totalMeaningfulCharacters = countMeaningfulCharacters(in: meaningfulOfferSample(from: bodyText))
        let candidates = languageCandidates(primary: nil, mixed: mixedLanguageCandidates(in: bodyText))

        if let foreign = candidates.first(where: { candidate in
            candidate.isMeaningfulForMixedOffer(totalMeaningfulCharacters: totalMeaningfulCharacters)
                && canonicalBaseCode(candidate.code) != target
        }) {
            return EmailTranslationOffer(shouldOffer: true, detectedLanguageCode: foreign.code)
        }

        guard let primary else {
            return .none
        }
        return EmailTranslationOffer(shouldOffer: false, detectedLanguageCode: primary.code)
    }

    // MARK: - Helpers

    /// BCP-47 base (primary subtag) lowercased: `pt-BR` → `pt`, `zh-Hans` → `zh`.
    static func baseCode(_ identifier: String) -> String {
        let normalized = normalizedLanguageIdentifier(identifier)
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }

    static func normalizedLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    /// Canonical family used for equality: collapses the model's supported
    /// aliases (e.g. Mandarin/Cantonese → `zh`) via `LocalModelLanguageSupport`,
    /// falling back to the raw base code for languages outside that set so the
    /// comparison still works for any detected source language. Public so
    /// cross-module callers (e.g. the dreaming worker) can key translation
    /// dossiers by the same canonical code the producers/consumer use.
    public static func canonicalBaseCode(_ identifier: String) -> String {
        if let canonical = LocalModelLanguageSupport.canonicalLanguageID(for: identifier) {
            return canonical
        }
        return baseCode(identifier)
    }

    private static func meaningfulSample(from text: String) -> String {
        // Bound the raw slice before the O(n) whitespace collapse so detection
        // stays cheap on the main actor even for very long bodies. A 4× window
        // over the sample limit leaves ample margin for runs of whitespace that
        // collapse away before the final prefix.
        let rawWindow = text.prefix(sampleCharacterLimit * 4)
        let collapsed = rawWindow
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(sampleCharacterLimit))
    }

    private static func meaningfulOfferSample(from text: String) -> String {
        let rawWindow = text.prefix(sampleCharacterLimit * 4)
        let cleaned = meaningfulDetectionLines(from: String(rawWindow))
            .joined(separator: " ")
        let source = countMeaningfulCharacters(in: cleaned) >= minimumMeaningfulCharacters
            ? cleaned
            : String(rawWindow)
        let collapsed = source
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(sampleCharacterLimit))
    }

    private static func countMeaningfulCharacters(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
    }

    private struct LanguageCandidate: Equatable {
        let code: String
        let confidence: Double
        let meaningfulCharacters: Int
        let priority: Int

        func isMeaningfulForMixedOffer(totalMeaningfulCharacters: Int) -> Bool {
            guard meaningfulCharacters >= minimumMixedLanguageCharacters,
                  totalMeaningfulCharacters > 0 else {
                return false
            }
            let proportion = Double(meaningfulCharacters) / Double(totalMeaningfulCharacters)
            return proportion >= minimumMixedLanguageProportion
        }

        var sortKey: Double {
            Double(priority * 10_000 + meaningfulCharacters) + confidence
        }
    }

    private static func primaryLanguageCandidate(in text: String) -> LanguageCandidate? {
        let sample = meaningfulOfferSample(from: text)
        guard countMeaningfulCharacters(in: sample) >= minimumMeaningfulCharacters else {
            return nil
        }
        return confidentLanguageCandidate(in: sample, priority: 0)
    }

    private static func languageCandidates(
        primary: LanguageCandidate?,
        mixed: [LanguageCandidate]
    ) -> [LanguageCandidate] {
        var candidates = mixed
        if let primary {
            candidates.append(primary)
        }
        return candidates
            .reduce(into: [String: LanguageCandidate]()) { bestByCode, candidate in
                let key = canonicalBaseCode(candidate.code)
                guard let existing = bestByCode[key] else {
                    bestByCode[key] = candidate
                    return
                }
                if candidate.sortKey > existing.sortKey {
                    bestByCode[key] = candidate
                }
            }
            .values
            .sorted { lhs, rhs in
                if lhs.sortKey == rhs.sortKey {
                    return lhs.code < rhs.code
                }
                return lhs.sortKey > rhs.sortKey
            }
    }

    private static func mixedLanguageCandidates(in text: String) -> [LanguageCandidate] {
        let sample = meaningfulOfferSample(from: text)
        var candidates = scriptLanguageCandidates(in: sample)
        candidates.append(contentsOf: segmentLanguageCandidates(in: text))
        return candidates.sorted { lhs, rhs in
            if lhs.sortKey == rhs.sortKey {
                return lhs.code < rhs.code
            }
            return lhs.sortKey > rhs.sortKey
        }
    }

    private static func confidentLanguageCandidate(
        in text: String,
        priority: Int,
        confidenceFloor: Double = minimumConfidence
    ) -> LanguageCandidate? {
        let meaningfulCharacters = countMeaningfulCharacters(in: text)
        guard meaningfulCharacters >= minimumMeaningfulCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else {
            return nil
        }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[dominant] ?? 0
        guard confidence >= confidenceFloor else { return nil }
        return LanguageCandidate(
            code: normalizedLanguageIdentifier(dominant.rawValue),
            confidence: confidence,
            meaningfulCharacters: meaningfulCharacters,
            priority: priority
        )
    }

    private static func segmentLanguageCandidates(in text: String) -> [LanguageCandidate] {
        meaningfulSegments(from: text).compactMap { rawSegment in
            let segment = cleanedSegmentForLanguageEvidence(rawSegment)
            guard countMeaningfulCharacters(in: segment) >= minimumMixedLanguageCharacters else {
                return nil
            }
            guard isLikelyProseSegment(segment) else { return nil }
            return confidentLanguageCandidate(
                in: segment,
                priority: 1,
                confidenceFloor: minimumSegmentConfidence
            )
        }
    }

    private static func cleanedSegmentForLanguageEvidence(_ segment: String) -> String {
        segment
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { token in
                isNoisyEvidenceToken(String(token)) == false
            }
            .joined(separator: " ")
    }

    private static func isNoisyEvidenceToken(_ token: String) -> Bool {
        var trimmingSet = CharacterSet.whitespacesAndNewlines
        trimmingSet.formUnion(.punctuationCharacters)
        trimmingSet.formUnion(.symbols)

        let trimmed = token.trimmingCharacters(in: trimmingSet)
        guard trimmed.isEmpty == false else { return true }

        let lowerToken = token.lowercased()
        let lowerTrimmed = trimmed.lowercased()
        if lowerToken.hasPrefix("http://")
            || lowerToken.hasPrefix("https://")
            || lowerTrimmed.hasPrefix("www.") {
            return true
        }
        if trimmed.contains("@") && trimmed.contains(".") {
            return true
        }

        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.isEmpty == false else { return true }
        let letterCount = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digitCount = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let otherCount = scalars.count - letterCount - digitCount
        guard letterCount > 0 else { return true }

        let noisyShare = Double(digitCount + otherCount) / Double(scalars.count)
        if digitCount > 0 && noisyShare >= 0.35 {
            return true
        }
        if (trimmed.contains("/") || trimmed.contains("=") || trimmed.contains("&") || trimmed.contains("_"))
            && noisyShare >= 0.25 {
            return true
        }
        return false
    }

    private static func isLikelyProseSegment(_ segment: String) -> Bool {
        let words = lexicalWords(in: segment)
        guard words.count >= 8 else { return true }
        guard containsSentenceTerminator(in: segment) == false else { return true }

        let properNounLikeCount = words.filter { word in
            isTitlecaseLikeWord(word) || isUppercaseLikeWord(word)
        }.count
        return Double(properNounLikeCount) / Double(words.count) < 0.70
    }

    private static func lexicalWords(in segment: String) -> [String] {
        var trimmingSet = CharacterSet.whitespacesAndNewlines
        trimmingSet.formUnion(.punctuationCharacters)
        trimmingSet.formUnion(.symbols)

        return segment
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { token -> String? in
                let word = String(token).trimmingCharacters(in: trimmingSet)
                let scalars = Array(word.unicodeScalars)
                guard scalars.count >= 2 else { return nil }
                let letterCount = scalars.filter { CharacterSet.letters.contains($0) }.count
                guard letterCount >= 2,
                      Double(letterCount) / Double(scalars.count) >= 0.75 else {
                    return nil
                }
                return word
            }
    }

    private static func containsSentenceTerminator(in segment: String) -> Bool {
        segment.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x002E, 0x003F, 0x0021, 0x3002, 0xFF1F, 0xFF01:
                return true
            default:
                return false
            }
        }
    }

    private static func isTitlecaseLikeWord(_ word: String) -> Bool {
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2,
              let first = letters.first,
              CharacterSet.uppercaseLetters.contains(first) else {
            return false
        }
        let remaining = letters.dropFirst()
        let lowercaseCount = remaining.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        return lowercaseCount >= max(1, remaining.count - 1)
    }

    private static func isUppercaseLikeWord(_ word: String) -> Bool {
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func meaningfulSegments(from text: String) -> [String] {
        let rawWindow = text.prefix(sampleCharacterLimit * 4)
        let normalized = rawWindow.replacingOccurrences(of: "\u{00a0}", with: " ")
        var segments: [String] = []
        var current: [String] = []

        func flush() {
            let segment = current.joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            if segment.isEmpty == false {
                segments.append(String(segment.prefix(sampleCharacterLimit)))
            }
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = strippedEmailQuotePrefix(from: rawLine)
            if line.isEmpty {
                flush()
            } else if isDetectionNoiseLine(line) {
                continue
            } else {
                current.append(line)
            }
            if segments.count >= maxSegmentCandidates { break }
        }
        flush()
        return Array(segments.prefix(maxSegmentCandidates))
    }

    private static func meaningfulDetectionLines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map(strippedEmailQuotePrefix(from:))
            .filter { line in
                line.isEmpty == false && isDetectionNoiseLine(line) == false
            }
    }

    private static func strippedEmailQuotePrefix(from line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(">") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func isDetectionNoiseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("www.")
            || lowercased.contains("://") {
            return true
        }

        let meaningfulCount = countMeaningfulCharacters(in: trimmed)
        guard meaningfulCount > 0 else { return true }

        let scalarCount = max(trimmed.unicodeScalars.count, 1)
        let digitCount = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if digitCount >= 4 && Double(digitCount) / Double(scalarCount) > 0.12 {
            return true
        }

        let sentencePunctuation = CharacterSet(charactersIn: ".!?。！？")
        if trimmed.unicodeScalars.contains(where: { sentencePunctuation.contains($0) }) {
            return false
        }

        return isSubstantialUnpunctuatedLanguageEvidence(trimmed) == false
    }

    private static func isSubstantialUnpunctuatedLanguageEvidence(_ line: String) -> Bool {
        let cleaned = cleanedSegmentForLanguageEvidence(line)
        let meaningfulCount = countMeaningfulCharacters(in: cleaned)
        guard meaningfulCount >= minimumMeaningfulCharacters else { return false }

        let words = lexicalWords(in: cleaned)
        if words.count >= 3 {
            let properNounLikeCount = words.filter { word in
                isTitlecaseLikeWord(word) || isUppercaseLikeWord(word)
            }.count
            if Double(properNounLikeCount) / Double(words.count) >= 0.70 {
                return false
            }
        }

        if words.count < 5 && meaningfulCount < minimumMixedLanguageCharacters {
            return false
        }
        return isLikelyProseSegment(cleaned)
    }

    private static func scriptLanguageCandidates(in sample: String) -> [LanguageCandidate] {
        let buckets = ScriptBuckets(sample)
        var candidates: [LanguageCandidate] = []

        if buckets.japaneseEvidenceCount >= minimumScriptEvidenceCharacters,
           let candidate = confidentLanguageCandidate(
            in: buckets.japaneseEvidence,
            priority: 2,
            confidenceFloor: minimumSegmentConfidence
           ) {
            candidates.append(candidate)
        }

        for scriptText in [
            buckets.han,
            buckets.hangul,
            buckets.cyrillic,
            buckets.arabic,
            buckets.hebrew,
            buckets.devanagari,
            buckets.thai,
            buckets.greek
        ] where countMeaningfulCharacters(in: scriptText) >= minimumScriptEvidenceCharacters {
            if let candidate = confidentLanguageCandidate(
                in: scriptText,
                priority: 2,
                confidenceFloor: minimumSegmentConfidence
            ) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    private struct ScriptBuckets {
        let japaneseEvidence: String
        let japaneseEvidenceCount: Int
        let han: String
        let hangul: String
        let cyrillic: String
        let arabic: String
        let hebrew: String
        let devanagari: String
        let thai: String
        let greek: String

        init(_ sample: String) {
            var kanaScalars: [UnicodeScalar] = []
            var hanScalars: [UnicodeScalar] = []
            var hangulScalars: [UnicodeScalar] = []
            var cyrillicScalars: [UnicodeScalar] = []
            var arabicScalars: [UnicodeScalar] = []
            var hebrewScalars: [UnicodeScalar] = []
            var devanagariScalars: [UnicodeScalar] = []
            var thaiScalars: [UnicodeScalar] = []
            var greekScalars: [UnicodeScalar] = []

            for scalar in sample.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF:
                    kanaScalars.append(scalar)
                case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                    hanScalars.append(scalar)
                case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                    hangulScalars.append(scalar)
                case 0x0400...0x052F:
                    cyrillicScalars.append(scalar)
                case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
                    arabicScalars.append(scalar)
                case 0x0590...0x05FF:
                    hebrewScalars.append(scalar)
                case 0x0900...0x097F:
                    devanagariScalars.append(scalar)
                case 0x0E00...0x0E7F:
                    thaiScalars.append(scalar)
                case 0x0370...0x03FF, 0x1F00...0x1FFF:
                    greekScalars.append(scalar)
                default:
                    continue
                }
            }

            let kana = String(String.UnicodeScalarView(kanaScalars))
            let han = String(String.UnicodeScalarView(hanScalars))
            self.japaneseEvidence = kana + han
            self.japaneseEvidenceCount = kanaScalars.count + hanScalars.count
            self.han = han
            self.hangul = String(String.UnicodeScalarView(hangulScalars))
            self.cyrillic = String(String.UnicodeScalarView(cyrillicScalars))
            self.arabic = String(String.UnicodeScalarView(arabicScalars))
            self.hebrew = String(String.UnicodeScalarView(hebrewScalars))
            self.devanagari = String(String.UnicodeScalarView(devanagariScalars))
            self.thai = String(String.UnicodeScalarView(thaiScalars))
            self.greek = String(String.UnicodeScalarView(greekScalars))
        }
    }
}
