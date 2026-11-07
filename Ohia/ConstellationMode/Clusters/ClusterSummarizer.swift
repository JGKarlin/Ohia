import Foundation
import OhiaCore
import OhiaML

/// Computes short labels (≤ ~24 chars) for `ClusterRecord`s by inspecting
/// the metadata of the cluster's member messages. Phase 2 default is the
/// `<top-type> · <top-from-domain>` heuristic; the LLM hook is in place
/// for the developer toggle that ships in Task 15 (engine: nil at all
/// current call sites). `messageIndex` is the UUID-keyed Constellation snapshot
/// already used by render planning, so labeling does not perform a second store
/// round-trip.
@MainActor
public struct ClusterSummarizer {

    public let messageIndex: [String: MessageFilterRow]
    public let engine: (any TrainingEngine)?

    public init(messageIndex: [String: MessageFilterRow], engine: (any TrainingEngine)? = nil) {
        self.messageIndex = messageIndex
        self.engine = engine
    }

    /// Returns a short label per cluster, based on member message metadata.
    /// Tries LLM first when available; falls back to a heuristic
    /// "<top-type> · <top-from-domain>" pattern.
    public func label(
        forCluster cluster: ClusterRecord,
        memberVectorIds: [Int64],
        messageIdByVectorId: [Int64: String]
    ) -> String {
        let members: [MessageFilterRow] = memberVectorIds.compactMap { vid in
            guard let mid = messageIdByVectorId[vid] else { return nil }
            return messageIndex[mid]
        }
        guard !members.isEmpty else { return "cluster · \(cluster.memberCount)" }

        if let engine, engine.isModelLoaded {
            if let llm = tryLLMLabel(members: members) {
                return llm
            }
        }
        return heuristicLabel(members: members)
    }

    private func heuristicLabel(members: [MessageFilterRow]) -> String {
        let byType = Dictionary(grouping: members, by: \.messageType).mapValues(\.count)
        // Stable tie-break: alphabetically earlier key wins on equal counts.
        let topType = byType.max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) })?.key.rawValue ?? "mixed"
        let byDomain = Dictionary(grouping: members, by: { (row: MessageFilterRow) -> String in
            row.fromAddress.split(separator: "@").last.map(String.init) ?? "unknown"
        }).mapValues(\.count)
        // Stable tie-break: alphabetically earlier key wins on equal counts.
        let topDomain = byDomain.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key ?? "mixed"
        return "\(topType) · \(topDomain)"
    }

    private func tryLLMLabel(members: [MessageFilterRow]) -> String? {
        guard let engine else { return nil }
        let subjects = members.prefix(8).map { "• \($0.fromAddress)" }.joined(separator: "\n")
        let prompt = """
        Summarize this cluster of emails as a 2–4 word label. Return JUST the label, no prose.

        Members:
        \(subjects)

        Label:
        """
        let raw: String?
        if let workerEngine = engine as? WorkerGenerationEngine {
            raw = try? workerEngine.generate(
                prompt: prompt,
                maxTokens: 12,
                activityKind: .summarizing
            )
        } else {
            raw = try? engine.generate(prompt: prompt, maxTokens: 12)
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 32, !trimmed.isEmpty { return String(trimmed.prefix(32)) }
        return nil
    }
}
