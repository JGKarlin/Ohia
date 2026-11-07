// Packages/Sources/OhiaML/Layout/ClusterDetector.swift
import Foundation
import NaturalLanguage

public enum ClusterDetector {
    public static let defaultMinPoints = 4

    public struct MeaningAssociationWeights: Sendable, Equatable {
        public var embedding: Float
        public var semanticTag: Float
        public var subjectTerm: Float
        public var attachmentTerm: Float
        public var bodyPreviewTerm: Float
        public var senderDomain: Float
        public var dateBucket: Float

        public init(
            embedding: Float = 0.55,
            semanticTag: Float = 1.00,
            subjectTerm: Float = 0.42,
            attachmentTerm: Float = 0.34,
            bodyPreviewTerm: Float = 0.16,
            senderDomain: Float = 0.08,
            dateBucket: Float = 0.04
        ) {
            self.embedding = embedding
            self.semanticTag = semanticTag
            self.subjectTerm = subjectTerm
            self.attachmentTerm = attachmentTerm
            self.bodyPreviewTerm = bodyPreviewTerm
            self.senderDomain = senderDomain
            self.dateBucket = dateBucket
        }
    }

    /// Parses a summary-vector text payload into a namespaced sparse
    /// "aboutness" feature dictionary: Qwen semantic tags,
    /// tokenized subject/attachment/body terms, sender domain, and date
    /// bucket, each pre-weighted by `weights`. These features are persisted
    /// per vector (`VectorMeaningFeatureStore`) and boost kNN edge weights in
    /// `MeaningCommunityDetector`.
    public static func meaningFeatures(
        from textPayload: String,
        canonicalSemanticTagIDs: [String] = [],
        weights: MeaningAssociationWeights = MeaningAssociationWeights()
    ) -> [String: Float] {
        var features: [String: Float] = [:]
        let fields = parseMeaningFields(textPayload)

        appendSenderDomain(fields["from"], weight: weights.senderDomain, to: &features)
        appendDateBucket(fields["date_bucket"], weight: weights.dateBucket, to: &features)
        appendLabelLine(fields["semantic_tags"] ?? fields["semantictags"], weight: weights.semanticTag, to: &features)
        appendTerms(fields["subject"], namespace: "subject", weight: weights.subjectTerm, cap: 8, to: &features)
        appendTerms(fields["attachments"], namespace: "attachment", weight: weights.attachmentTerm, cap: 8, to: &features)
        appendTerms(fields["body_preview"], namespace: "body", weight: weights.bodyPreviewTerm, cap: 16, to: &features)
        appendCanonicalSemanticTagIDs(
            canonicalSemanticTagIDs,
            weight: weights.semanticTag,
            to: &features
        )

        return features
    }

    private static func parseMeaningFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            let rawKey = String(rawLine[..<separator])
            let valueStart = rawLine.index(after: separator)
            let value = String(rawLine[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    private static func appendSenderDomain(_ value: String?, weight: Float, to features: inout [String: Float]) {
        guard weight > 0, let value else { return }
        let domainSource = value.split(separator: "@").dropFirst().joined(separator: "@")
        let domain = domainSource
            .split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .first
            .map(String.init)?
            .lowercased()
        guard let domain, !domain.isEmpty else { return }
        features["sender:\(domain)", default: 0] += weight
    }

    private static func appendDateBucket(_ value: String?, weight: Float, to features: inout [String: Float]) {
        guard weight > 0, let value else { return }
        let month = value.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let month, !month.isEmpty, month != "unknown" else { return }
        features["date:\(month)", default: 0] += weight
    }

    private static func appendLabelLine(_ value: String?, weight: Float, to features: inout [String: Float]) {
        guard weight > 0, let value else { return }
        let parts: [String]
        if value.contains(" || ") {
            parts = value.components(separatedBy: " || ")
        } else if value.contains("|") {
            parts = [value]
        } else {
            parts = value.split(separator: ",").map(String.init)
        }
        for rawPart in parts {
            var label = rawPart
            if label.contains("|") {
                let segments = label
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if let preferred = segments.first, preferred.isEmpty == false {
                    appendMeaningLabel(preferred, weight: weight, to: &features)
                    continue
                }
                label = segments.first ?? label
            }
            if let open = label.lastIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
                label = String(label[..<open])
            }
            appendMeaningLabel(label, weight: weight, to: &features)
        }
    }

    /// LLM-emitted preferred labels are soft evidence only. Authoritative
    /// membership identity comes from the resolved `SemanticTagProjection`
    /// UUIDs supplied separately to `meaningFeatures`.
    private static func appendMeaningLabel(
        _ raw: String,
        weight: Float,
        to features: inout [String: Float]
    ) {
        appendCanonicalTerm(raw, namespace: "meaning", weight: weight, to: &features)
    }

    private static func appendCanonicalSemanticTagIDs(
        _ rawIDs: [String],
        weight: Float,
        to features: inout [String: Float]
    ) {
        guard weight > 0 else { return }
        for rawID in Set(rawIDs) {
            let identity = rawID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !identity.isEmpty else { continue }
            features["tag:\(identity)", default: 0] += weight
        }
    }

    private static func appendTerms(
        _ value: String?,
        namespace: String,
        weight: Float,
        cap: Int,
        to features: inout [String: Float]
    ) {
        guard weight > 0, let value else { return }
        var seen: Set<String> = []
        for token in tokenizedTerms(value) {
            guard seen.insert(token).inserted else { continue }
            features["\(namespace):\(token)", default: 0] += weight
            if seen.count >= cap { break }
        }
    }

    private static func appendCanonicalTerm(
        _ raw: String,
        namespace: String,
        weight: Float,
        to features: inout [String: Float]
    ) {
        let tokens = tokenizedTerms(raw, includesNumericQualifiers: true)
        guard !tokens.isEmpty else { return }
        let key = tokens.joined(separator: "_")
        features["\(namespace):\(key)", default: 0] += weight
        if tokens.count > 1 {
            for token in tokens.prefix(3) {
                features["\(namespace):\(token)", default: 0] += weight * 0.35
            }
        }
    }

    /// Language-agnostic word segmentation. NLTokenizer segments CJK text into
    /// real words instead of whole-phrase blobs; the tokenizer is created per
    /// call because NLTokenizer is not safe to share across threads.
    private static func tokenizedTerms(
        _ raw: String,
        includesNumericQualifiers: Bool = false
    ) -> [String] {
        let lowered = raw.lowercased()
        guard lowered.isEmpty == false else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lowered
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: lowered.startIndex..<lowered.endIndex) { range, _ in
            let token = String(lowered[range])
            if isMeaningTerm(token, includesNumericQualifiers: includesNumericQualifiers) {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    /// Purely numeric tokens carry no aboutness. Single-character tokens are
    /// noise except in Han/Hiragana/Katakana scripts, where one-character words
    /// are meaningful. There is no per-language stop-word list: corpus-relative
    /// document-frequency filtering in MeaningCommunityDetector handles
    /// ubiquitous terms in every language.
    private static func isMeaningTerm(
        _ token: String,
        includesNumericQualifiers: Bool
    ) -> Bool {
        guard token.isEmpty == false else { return false }
        if token.allSatisfy(\.isNumber) {
            return includesNumericQualifiers && token.count >= 2
        }
        if token.count >= 2 { return true }
        return token.unicodeScalars.allSatisfy(isCJKMeaningScalar)
    }

    private static func isCJKMeaningScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0xFF66...0xFF9D,   // Halfwidth Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // CJK Unified Ideographs Extensions B and beyond
            return true
        default:
            return false
        }
    }
}
