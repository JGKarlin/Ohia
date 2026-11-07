import Foundation
import CryptoKit
import OhiaCore

/// Composite-key construction for `ConversationCurationAction`. Identity is
/// a hex digest of normalized claim text + kind + scope + extraction
/// version + supporting-message fingerprint. The same call site can also
/// resolve a previously-stored verdict through a fallback ladder when one
/// of the components has changed across recomputations (e.g. prompt
/// version bumps, slight evidence drift).
public enum ConversationCurationKey {
    /// Build the full composite key for a claim / issue / decision /
    /// precedent / tacit rule.
    public static func make(
        text: String,
        kind: ConversationCurationAction.TargetKind,
        scope: [ScopeHint],
        extractionVersion: String,
        supportingMessageContentHashes: [String]
    ) -> CurationKeyComponents {
        let scopeFingerprint = makeScopeFingerprint(scope)
        return make(
            text: text,
            kind: kind,
            scopeFingerprint: scopeFingerprint,
            extractionVersion: extractionVersion,
            supportingMessageContentHashes: supportingMessageContentHashes
        )
    }

    /// Build a composite key when the caller has already computed the
    /// scope fingerprint. Hot graph builders use this to avoid repeatedly
    /// sorting the same full scope for every issue / decision in a snapshot.
    public static func make(
        text: String,
        kind: ConversationCurationAction.TargetKind,
        scopeFingerprint: String,
        extractionVersion: String,
        supportingMessageContentHashes: [String]
    ) -> CurationKeyComponents {
        let normalized = normalize(text: text)
        let supportingFingerprint = makeSupportingFingerprint(supportingMessageContentHashes)
        let digest = digest(
            normalizedText: normalized,
            kind: kind,
            scopeFingerprint: scopeFingerprint,
            extractionVersion: extractionVersion,
            supportingFingerprint: supportingFingerprint
        )
        return CurationKeyComponents(
            targetKey: digest,
            normalizedClaimText: normalized,
            targetKind: kind,
            scopeFingerprint: scopeFingerprint,
            extractionVersion: extractionVersion,
            supportingFingerprint: supportingFingerprint
        )
    }

    /// Resolve a stored action against `candidate` through the fallback
    /// ladder. Returns the strongest match — the curation applier uses
    /// this to fold persisted verdicts onto recomputed snapshots.
    ///
    /// Ladder order: full key → text + scope + supporting fingerprint →
    /// text + scope → text + kind. Any earlier match short-circuits.
    public static func resolve(
        actions: [ConversationCurationAction],
        candidate: CurationKeyComponents
    ) -> ConversationCurationAction? {
        // Tier 1: full key match.
        if let exact = actions.first(where: { $0.isActive && $0.targetKey == candidate.targetKey }) {
            return exact
        }

        // Tier 2: text + scope + supporting fingerprint (extraction
        // version drifted, e.g. prompt bumped between sessions).
        let tier2 = actions.first { row in
            row.isActive
                && row.targetKindRaw == candidate.targetKind.rawValue
                && row.normalizedClaimText == candidate.normalizedClaimText
                && row.scopeFingerprint == candidate.scopeFingerprint
                && row.supportingFingerprint == candidate.supportingFingerprint
        }
        if let tier2 { return tier2 }

        // Tier 3: text + scope (supporting messages drifted but the
        // claim and its scope are stable).
        let tier3 = actions.first { row in
            row.isActive
                && row.targetKindRaw == candidate.targetKind.rawValue
                && row.normalizedClaimText == candidate.normalizedClaimText
                && row.scopeFingerprint == candidate.scopeFingerprint
        }
        if let tier3 { return tier3 }

        // Durable claims must never reuse a verdict across applicability
        // boundaries. Their scope fingerprint includes the complete durable
        // contract, so falling back to text + coarse `.claim` kind would
        // collapse intentionally distinct guidance.
        guard candidate.targetKind != .claim else { return nil }

        // Tier 4: text + kind only for non-claim graph objects.
        return actions.first { row in
            row.isActive
                && row.targetKindRaw == candidate.targetKind.rawValue
                && row.normalizedClaimText == candidate.normalizedClaimText
        }
    }

    // MARK: - Components

    /// Lowercased, whitespace-collapsed, punctuation-stripped form used
    /// across the composite key and the fallback ladder.
    public static func normalize(text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "\u{3000}"
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    public static func makeScopeFingerprint(_ scope: [ScopeHint]) -> String {
        let normalized = scope
            .map { "\($0.kind.rawValue):\($0.value.lowercased())" }
            .sorted()
            .joined(separator: "|")
        return sha256Hex(normalized)
    }

    /// Scope identity used for durable claim curation. The coarse curation
    /// target kind is always `.claim`, so every field that changes when or how
    /// guidance applies must participate in its fallback identity.
    public static func makeDurableClaimScopeFingerprint(
        scope: [ScopeHint],
        kindRaw: String?,
        subjectText: String?,
        conditionsText: String?,
        futureUseText: String?,
        formationBasisRaw: String?,
        usePolicyRaw: String?
    ) -> String {
        let payload = [
            "scope=\(makeScopeFingerprint(scope))",
            "memory-kind=\(normalize(text: kindRaw ?? ""))",
            "subject=\(normalize(text: subjectText ?? ""))",
            "conditions=\(normalize(text: conditionsText ?? ""))",
            "future-use=\(normalize(text: futureUseText ?? ""))",
            "formation=\(normalize(text: formationBasisRaw ?? ""))",
            "use-policy=\(normalize(text: usePolicyRaw ?? ""))"
        ].joined(separator: "\u{1F}")
        return sha256Hex(payload)
    }

    /// Sorted SHA-256 over the top-K most-evidential message content hashes.
    /// Empty input yields an empty string so the fingerprint can degrade
    /// gracefully on seed-only memory (no LLM extraction yet).
    public static func makeSupportingFingerprint(_ contentHashes: [String], topK: Int = 8) -> String {
        let normalized = contentHashes
            .compactMap { hash -> String? in
                let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .sorted()
            .prefix(topK)
            .joined(separator: "|")
        guard !normalized.isEmpty else { return "" }
        return sha256Hex(normalized)
    }

    private static func digest(
        normalizedText: String,
        kind: ConversationCurationAction.TargetKind,
        scopeFingerprint: String,
        extractionVersion: String,
        supportingFingerprint: String
    ) -> String {
        let payload = [
            "v=1",
            "kind=\(kind.rawValue)",
            "text=\(normalizedText)",
            "scope=\(scopeFingerprint)",
            "extraction=\(extractionVersion)",
            "support=\(supportingFingerprint)"
        ].joined(separator: "\u{1F}")
        return sha256Hex(payload)
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        var output: [UInt8] = []
        output.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}

/// Result of `ConversationCurationKey.make(…)`. Carries every component
/// stored on the persisted row so the fallback ladder can match without
/// re-hashing.
public struct CurationKeyComponents: Sendable, Equatable, Hashable {
    public let targetKey: String
    public let normalizedClaimText: String
    public let targetKind: ConversationCurationAction.TargetKind
    public let scopeFingerprint: String
    public let extractionVersion: String
    public let supportingFingerprint: String

    public init(
        targetKey: String,
        normalizedClaimText: String,
        targetKind: ConversationCurationAction.TargetKind,
        scopeFingerprint: String,
        extractionVersion: String,
        supportingFingerprint: String
    ) {
        self.targetKey = targetKey
        self.normalizedClaimText = normalizedClaimText
        self.targetKind = targetKind
        self.scopeFingerprint = scopeFingerprint
        self.extractionVersion = extractionVersion
        self.supportingFingerprint = supportingFingerprint
    }
}
