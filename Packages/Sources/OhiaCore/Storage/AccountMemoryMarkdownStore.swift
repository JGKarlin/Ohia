import Foundation

public struct AccountMemoryMarkdownStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func accountDirectoryURL(accountID: UUID) -> URL {
        rootDirectory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
    }

    public func exportURL(accountID: UUID) -> URL {
        accountDirectoryURL(accountID: accountID)
            .appendingPathComponent("memories.md", isDirectory: false)
    }

    public func dimensionExportURL(accountID: UUID, dimensionKind: String) -> URL {
        accountDirectoryURL(accountID: accountID)
            .appendingPathComponent(Self.fileName(for: dimensionKind), isDirectory: false)
    }

    static func fileName(for dimensionKind: String) -> String {
        switch dimensionKind {
        case AccountMemoryDimension.correspondent: return "people.md"
        case AccountMemoryDimension.classification: return "classification.md"
        case AccountMemoryDimension.project: return "projects.md"
        case AccountMemoryDimension.translation: return "translations.md"
        default: return "memories.md"
        }
    }

    /// Writes one markdown file per dossier dimension under the account
    /// directory: `memories.md` (account), `people.md`, `classification.md`,
    /// `projects.md`, and `translations.md`. Returns the account-dimension
    /// file URL as the primary result of this one-shot export.
    @discardableResult
    public func export(
        accountID: UUID,
        accountDisplayName: String,
        accountEmailAddress: String,
        memories: [AccountMemory],
        generatedAt: Date = .now
    ) throws -> URL {
        let directory = accountDirectoryURL(accountID: accountID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var byDimension: [String: [AccountMemory]] = [:]
        for memory in memories {
            byDimension[memory.dimensionKind, default: []].append(memory)
        }

        for dimensionKind in AccountMemoryDimension.all {
            let url = dimensionExportURL(accountID: accountID, dimensionKind: dimensionKind)
            let markdown: String
            if dimensionKind == AccountMemoryDimension.account {
                markdown = makeMarkdown(
                    accountID: accountID,
                    accountDisplayName: accountDisplayName,
                    accountEmailAddress: accountEmailAddress,
                    memories: byDimension[dimensionKind] ?? [],
                    generatedAt: generatedAt
                )
            } else {
                markdown = makeGroupedMarkdown(
                    accountID: accountID,
                    accountDisplayName: accountDisplayName,
                    accountEmailAddress: accountEmailAddress,
                    dimensionKind: dimensionKind,
                    memories: byDimension[dimensionKind] ?? [],
                    generatedAt: generatedAt
                )
            }
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
        return exportURL(accountID: accountID)
    }

    /// Grouped variant for the non-account dimensions: one `##` section per
    /// dimension value (a person, a classification facet, a project), with each memory
    /// rendered in the same prompt-context block as the account file.
    public func makeGroupedMarkdown(
        accountID: UUID,
        accountDisplayName: String,
        accountEmailAddress: String,
        dimensionKind: String,
        memories: [AccountMemory],
        generatedAt: Date = .now
    ) -> String {
        // Pre-compute decay data once per memory then sort (Schwartzian transform):
        // avoids repeated `pow()` calls inside the sort comparator.
        let visible = Self.sortedWithDecay(
            memories.filter {
                $0.isMarkdownExportEligible
                    && $0.isExpired(now: generatedAt) == false
                    && Self.isLiveStale($0, now: generatedAt) == false
            },
            now: generatedAt
        )
        var lines: [String] = []
        lines.append("# Ohia memories — \(AccountMemoryDimension.displayLabel(dimensionKind))")
        lines.append("")
        lines.append("- Account: \(accountDisplayName) <\(accountEmailAddress)>")
        lines.append("- Account ID: \(accountID.uuidString)")
        lines.append("- Generated: \(Self.isoString(generatedAt))")
        lines.append("- Source: SwiftData AccountMemory projection")
        lines.append("")
        if visible.isEmpty {
            lines.append("No prompt-eligible durable guidance has been projected for this dimension.")
            return lines.joined(separator: "\n") + "\n"
        }

        var byValue: [String: [(AccountMemory, liveStale: Bool)]] = [:]
        for pair in visible {
            byValue[pair.0.resolvedDimensionValue, default: []].append(pair)
        }
        let orderedValues = byValue.keys.sorted { left, right in
            let leftName = byValue[left]?.first?.0.resolvedDimensionDisplayName ?? left
            let rightName = byValue[right]?.first?.0.resolvedDimensionDisplayName ?? right
            return leftName.localizedStandardCompare(rightName) == .orderedAscending
        }
        for value in orderedValues {
            guard let group = byValue[value] else { continue }
            let displayName = group.first?.0.resolvedDimensionDisplayName ?? value
            if displayName.caseInsensitiveCompare(value) == .orderedSame || value.isEmpty {
                lines.append("## \(Self.markdownText(displayName))")
            } else {
                lines.append("## \(Self.markdownText(displayName)) (\(Self.markdownText(value)))")
            }
            lines.append("")
            for (memory, liveStale) in group {
                appendMemoryBlock(memory, headingLevel: 3, liveStale: liveStale, to: &lines)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func makeMarkdown(
        accountID: UUID,
        accountDisplayName: String,
        accountEmailAddress: String,
        memories: [AccountMemory],
        generatedAt: Date = .now
    ) -> String {
        // Pre-compute decay data once per memory then sort (Schwartzian transform):
        // avoids repeated `pow()` calls inside the sort comparator.
        let visible = Self.sortedWithDecay(
            memories.filter {
                $0.isMarkdownExportEligible
                    && $0.isExpired(now: generatedAt) == false
                    && Self.isLiveStale($0, now: generatedAt) == false
            },
            now: generatedAt
        )
        var lines: [String] = []
        lines.append("# Ohia memories")
        lines.append("")
        lines.append("- Account: \(accountDisplayName) <\(accountEmailAddress)>")
        lines.append("- Account ID: \(accountID.uuidString)")
        lines.append("- Generated: \(Self.isoString(generatedAt))")
        lines.append("- Source: SwiftData AccountMemory projection")
        lines.append("")
        if visible.isEmpty {
            lines.append("No prompt-eligible durable guidance has been projected yet.")
            return lines.joined(separator: "\n") + "\n"
        }

        for (memory, liveStale) in visible {
            appendMemoryBlock(memory, headingLevel: 2, liveStale: liveStale, to: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Active generated guidance ages out of exported prompt context. User-
    /// confirmed guidance remains durable until explicitly reviewed.
    private static func isLiveStale(_ memory: AccountMemory, now: Date) -> Bool {
        guard memory.statusRaw == AccountMemoryProjectedStatus.active else { return false }
        return AccountMemoryDecay.isStale(lastSeenAt: memory.lastSeenAt, now: now)
    }

    private func appendMemoryBlock(
        _ memory: AccountMemory,
        headingLevel: Int,
        liveStale: Bool,
        to lines: inout [String]
    ) {
        let displayText = Self.markdownText(memory.displayText)
        let scope = Self.sortedScope(memory.decodedScope())
        let evidence = Self.sortedEvidence(memory.decodedEvidence())
        let heading = String(repeating: "#", count: max(1, headingLevel))

        lines.append("\(heading) \(displayText)")
        lines.append("")
        lines.append("Prompt guidance:")
        lines.append("- Guidance: \(displayText)")
        lines.append("- Future use: \(Self.useWhenText(for: memory))")
        lines.append("- Use policy: \(memory.usePolicyRaw ?? "")")
        lines.append("- Formation basis: \(memory.formationBasisRaw ?? "")")
        lines.append("- Evidence summary: \(Self.evidenceSummary(for: memory, evidence: evidence))")
        lines.append("- Caution: \(Self.cautionText(for: memory, liveStale: liveStale, scope: scope, evidence: evidence))")
        lines.append("")
        lines.append("Metadata:")
        lines.append("- Key: \(memory.memoryKey)")
        let effectiveStatus = liveStale ? "\(memory.statusRaw) (stale)" : memory.statusRaw
        lines.append("- Status: \(effectiveStatus)")
        lines.append("- Provenance: \(Self.provenanceLine(for: memory))")
        lines.append("- Dimension: \(memory.dimensionKind)")
        if memory.resolvedDimensionValue.isEmpty == false {
            lines.append("- Dimension value: \(Self.markdownText(memory.resolvedDimensionValue))")
        }
        lines.append("- Sensitivity: \(memory.sensitivityRiskRaw)")
        lines.append("- Last revised: \(Self.isoString(memory.updatedAt))")
        lines.append("- First seen: \(Self.isoString(memory.firstSeenAt))")
        lines.append("- Last seen: \(Self.isoString(memory.lastSeenAt))")
        if let affirmed = memory.lastAffirmedAt {
            lines.append("- Last affirmed: \(Self.isoString(affirmed))")
        }

        if scope.isEmpty == false {
            let rendered = Self.scopeSummary(scope)
            lines.append("- Scope: \(rendered)")
        }

        if evidence.isEmpty == false {
            lines.append("")
            lines.append("Evidence:")
            for item in evidence.prefix(8) {
                lines.append("- \(Self.isoString(item.timestamp)) | \(Self.markdownText(item.subject)) | \(Self.markdownText(item.senderAddress)) | \(item.messageID.uuidString)")
                if let span = item.spanText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   span.isEmpty == false {
                    lines.append("  - Span: \(Self.markdownText(span))")
                } else if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                          summary.isEmpty == false {
                    lines.append("  - Summary: \(Self.markdownText(summary))")
                }
            }
        }
        lines.append("")
    }

    private static func sortedScope(_ scope: [AccountMemoryScopeReference]) -> [AccountMemoryScopeReference] {
        scope.sorted { left, right in
            if left.kindRaw != right.kindRaw { return left.kindRaw < right.kindRaw }
            return left.value < right.value
        }
    }

    private static func sortedEvidence(_ evidence: [AccountMemoryEvidenceReference]) -> [AccountMemoryEvidenceReference] {
        evidence.sorted { left, right in
            if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
            return left.messageID.uuidString < right.messageID.uuidString
        }
    }

    private static func useWhenText(for memory: AccountMemory) -> String {
        memory.futureUseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func evidenceSummary(
        for memory: AccountMemory,
        evidence: [AccountMemoryEvidenceReference]
    ) -> String {
        if evidence.isEmpty {
            return "No citations are attached; memory confidence \(percent(memory.extractionConfidence)), evidence strength \(percent(memory.evidenceStrength)), first seen \(isoString(memory.firstSeenAt)), last seen \(isoString(memory.lastSeenAt))."
        }

        var parts: [String] = [
            countText(evidence.count, singular: "citation", plural: "citations")
        ]
        if let strongest = evidence.map(\.confidence).max() {
            parts.append("strongest citation confidence \(percent(strongest))")
        }
        parts.append("memory confidence \(percent(memory.extractionConfidence))")
        parts.append("evidence strength \(percent(memory.evidenceStrength))")
        parts.append("first seen \(isoString(memory.firstSeenAt))")
        parts.append("last seen \(isoString(memory.lastSeenAt))")
        if let freshest = evidence.map(\.timestamp).max() {
            parts.append("freshest citation \(isoString(freshest))")
        }

        let sources = topEvidenceSources(evidence)
        if sources.isEmpty == false {
            parts.append("top sources \(sources)")
        }

        return "Supported by \(parts.joined(separator: ", "))."
    }

    private static func cautionText(
        for memory: AccountMemory,
        liveStale: Bool,
        scope: [AccountMemoryScopeReference],
        evidence: [AccountMemoryEvidenceReference]
    ) -> String {
        var clauses: [String] = []

        if liveStale {
            clauses.append("This active guidance is stale and must not be used until refreshed.")
        } else if memory.statusRaw == AccountMemoryProjectedStatus.confirmed {
            clauses.append("User-confirmed durable guidance; keep it within the listed scope.")
        } else {
            clauses.append("Generated durable guidance; verify fit against the current thread.")
        }

        switch memory.usePolicyRaw {
        case AccountMemoryUsePolicy.internalGuidance:
            clauses.append("Internal model guidance only; never state or quote it in outbound text.")
        case AccountMemoryUsePolicy.contextualOrientation:
            clauses.append("Use only to orient interpretation; never assert it as a fact.")
        case AccountMemoryUsePolicy.draftingGuidance:
            clauses.append("Use to shape language, structure, routing, or procedure; do not present it as new factual content.")
        case AccountMemoryUsePolicy.assertableKnowledge:
            clauses.append("It may be stated only when current-thread evidence and scope remain compatible.")
        default:
            clauses.append("Unknown use policy; do not use.")
        }

        clauses.append("Current user instructions and current-thread evidence always take precedence.")

        if memory.isSensitiveAndUnaffirmed {
            clauses.append("Sensitive and unaffirmed; do not surface directly unless the draft explicitly requires it.")
        } else if memory.sensitivityRiskRaw != "none" {
            clauses.append("Review sensitivity before using direct personal details.")
        }

        if scope.isEmpty {
            clauses.append("Do not generalize beyond the cited evidence.")
        } else {
            clauses.append("Do not apply outside \(scopeSummary(scope)) unless the current thread explicitly supports it.")
        }

        if evidence.isEmpty {
            clauses.append("No citations are attached; rely on current-thread evidence before using it.")
        }

        return clauses.joined(separator: " ")
    }

    private static func scopeSummary(_ scope: [AccountMemoryScopeReference]) -> String {
        scope
            .map { "\(markdownText($0.kindRaw)): \(markdownText($0.value))" }
            .joined(separator: "; ")
    }

    private static func topEvidenceSources(_ evidence: [AccountMemoryEvidenceReference]) -> String {
        var seen = Set<String>()
        var sources: [String] = []
        for item in evidence {
            let source = evidenceSource(item)
            if seen.insert(source).inserted {
                sources.append(source)
            }
            if sources.count == 3 { break }
        }
        return sources.joined(separator: "; ")
    }

    private static func evidenceSource(_ item: AccountMemoryEvidenceReference) -> String {
        let name = item.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = item.senderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty == false, address.isEmpty == false {
            return markdownText("\(name) <\(address)>")
        }
        if let name, name.isEmpty == false {
            return markdownText(name)
        }
        if address.isEmpty == false {
            return markdownText(address)
        }
        return "unknown sender"
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    /// Pre-computed sort key for a single memory. Captured once before sorting
    /// so `pow()` (in `AccountMemoryDecay.factor`) is called O(N) times rather
    /// than O(N log N) times.
    private struct MemorySortKey {
        let memory: AccountMemory
        let decayedWeight: Double
        let liveStale: Bool
        let rank: Int
    }

    /// Sorts eligible memories by decayed weight using a Schwartzian transform:
    /// decay factors are computed once per memory before sorting, not inside
    /// the comparator. Returns `(memory, liveStale)` pairs so callers can use
    /// the pre-computed staleness flag during rendering without re-computing it.
    ///
    /// Ordering:
    ///   1. Effective rank: confirmed (0) > active (1) > unknown (9) >
    ///      **live-stale (10)**. Live-stale memories — those whose decay factor has fallen below
    ///      `AccountMemoryDecay.staleFactorThreshold` sort last. Export callers
    ///      remove them before prompt guidance is rendered.
    ///   2. Within the same rank: live decayed weight descending.
    ///   3. `lastSeenAt` descending (tiebreaker).
    ///   4. Display text ascending (stable final tiebreaker).
    private static func sortedWithDecay(
        _ memories: [AccountMemory],
        now: Date
    ) -> [(AccountMemory, liveStale: Bool)] {
        let keys: [MemorySortKey] = memories.map { m in
            let decayFactor = AccountMemoryDecay.factor(lastSeenAt: m.lastSeenAt, now: now)
            let stale = isLiveStale(m, now: now)
            return MemorySortKey(
                memory: m,
                decayedWeight: m.weight * decayFactor,
                liveStale: stale,
                rank: effectiveRank(statusRaw: m.statusRaw, liveStale: stale)
            )
        }
        let sorted = keys.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.decayedWeight != b.decayedWeight { return a.decayedWeight > b.decayedWeight }
            if a.memory.lastSeenAt != b.memory.lastSeenAt { return a.memory.lastSeenAt > b.memory.lastSeenAt }
            return a.memory.displayText.localizedStandardCompare(b.memory.displayText) == .orderedAscending
        }
        return sorted.map { ($0.memory, liveStale: $0.liveStale) }
    }

    /// Effective sort rank incorporating live-stale status.
    /// Live-stale active guidance receives the final rank. Export callers
    /// filter it out; keeping the rank makes this helper safe for direct reuse.
    private static func effectiveRank(statusRaw: String, liveStale: Bool) -> Int {
        if liveStale { return 10 }
        return statusRank(statusRaw)
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case AccountMemoryProjectedStatus.confirmed: return 0
        case AccountMemoryProjectedStatus.active: return 1
        default: return 9
        }
    }

    private static func percent(_ value: Double) -> String {
        let clamped = min(1, max(0, value))
        return "\(Int((clamped * 100).rounded()))%"
    }

    private static func markdownText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "…", with: ".")
            .replacingOccurrences(of: "...", with: ".")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    /// Single consolidated provenance line for a memory's structured
    /// claim-ledger fields. Renders `kind` and `origin` always, then appends
    /// `asserted by`, `as of`, `expires`, and `conditions` only when the
    /// underlying field is present. Values are joined with a real separator
    /// (` · `) so no ellipsis is ever introduced.
    private static func provenanceLine(for memory: AccountMemory) -> String {
        var parts: [String] = [
            "kind \(markdownText(memory.targetKindRaw))",
            "origin \(markdownText(memory.resolvedOrigin))"
        ]
        if let asserted = memory.assertedByAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           asserted.isEmpty == false {
            parts.append("asserted by \(markdownText(asserted))")
        }
        if let asOf = memory.asOf {
            parts.append("as of \(dayString(asOf))")
        }
        if let expires = memory.expiresAt {
            parts.append("expires \(dayString(expires))")
        }
        if let conditions = memory.conditionsText?.trimmingCharacters(in: .whitespacesAndNewlines),
           conditions.isEmpty == false {
            parts.append("conditions \(markdownText(conditions))")
        }
        return parts.joined(separator: " · ")
    }

    /// Date-only `yyyy-MM-dd` rendering in a fixed locale/timezone so temporal
    /// scope reads identically regardless of the running machine's settings.
    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
