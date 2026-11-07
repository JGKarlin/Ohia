// EmbeddingDigestBuilder.swift
// Real implementation of DigestBuilding. Clusters messages for the
// Newsletters pane using two passes:
//
//   1) Thread-ID fast path — anything with the same threadID belongs to
//      the same digest entry automatically.
//   2) Semantic clustering — for messages that share no threadID, embed
//      the normalized subject and greedily assign to an existing cluster
//      whose centroid matches above `similarityThreshold`. Falls back to
//      one-entry-per-message when the embedder can't produce a vector
//      (empty string, missing provider, etc).
//
// The resulting DigestEntry keyTakeaway summarizes the *additional*
// subjects in the cluster so the user can see at a glance that e.g. a
// newsletter cluster spans "Harbor permit update · Riverside zoning · +2 more".

import Foundation
import OhiaCore

public final class EmbeddingDigestBuilder: DigestBuilding, @unchecked Sendable {

    private let embedder: EmbeddingProvider
    private let similarityThreshold: Float

    public init(embedder: EmbeddingProvider, similarityThreshold: Float = 0.70) {
        self.embedder = embedder
        self.similarityThreshold = similarityThreshold
    }

    public func buildDigest(messages: [DigestInput]) -> [DigestEntry] {
        guard !messages.isEmpty else { return [] }

        // 1. Thread-ID fast path.
        var threadClusters: [String: [DigestInput]] = [:]
        var unthreaded: [DigestInput] = []
        for msg in messages {
            if let tid = msg.threadID, !tid.isEmpty {
                threadClusters[tid, default: []].append(msg)
            } else {
                unthreaded.append(msg)
            }
        }

        // 2. Semantic clustering over unthreaded subjects.
        let clusters = semanticallyCluster(unthreaded)

        // 3. Build entries from both cluster sources.
        var entries = threadClusters.values.map { buildEntry(from: $0) }
        entries.append(contentsOf: clusters.map { buildEntry(from: $0.members) })

        // 4. Sort newest-first.
        entries.sort { a, b in
            mostRecent(in: a, source: messages) > mostRecent(in: b, source: messages)
        }

        return entries
    }

    // MARK: - Semantic clustering

    private struct EmbeddedCluster {
        var centroid: [Float]
        var count: Int
        var members: [DigestInput]
    }

    private func semanticallyCluster(_ inputs: [DigestInput]) -> [EmbeddedCluster] {
        var clusters: [EmbeddedCluster] = []

        // Process newest-first so cluster centroids are anchored to the
        // most recent (and typically most relevant) subject phrasing.
        for msg in inputs.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            let normalized = normalizeSubject(msg.subject)
            guard let embedding = embedder.embed(normalized), !embedding.isEmpty else {
                // Embedder unavailable for this subject — keep as singleton.
                clusters.append(EmbeddedCluster(centroid: [], count: 1, members: [msg]))
                continue
            }

            var joined = false
            for i in clusters.indices {
                guard !clusters[i].centroid.isEmpty,
                      clusters[i].centroid.count == embedding.count else { continue }
                let similarity = VectorStore.cosineSimilarity(embedding, clusters[i].centroid)
                if similarity >= similarityThreshold {
                    clusters[i].centroid = runningMean(
                        centroid: clusters[i].centroid,
                        count: clusters[i].count,
                        newVector: embedding
                    )
                    clusters[i].count += 1
                    clusters[i].members.append(msg)
                    joined = true
                    break
                }
            }
            if !joined {
                clusters.append(EmbeddedCluster(centroid: embedding, count: 1, members: [msg]))
            }
        }

        return clusters
    }

    /// Online mean update: `new = (old * n + sample) / (n + 1)`.
    private func runningMean(centroid: [Float], count: Int, newVector: [Float]) -> [Float] {
        let n = Float(count)
        var updated = centroid
        for i in 0..<updated.count {
            updated[i] = (updated[i] * n + newVector[i]) / (n + 1)
        }
        return updated
    }

    // MARK: - Entry construction

    private func buildEntry(from cluster: [DigestInput]) -> DigestEntry {
        let sorted = cluster.sorted { $0.receivedAt > $1.receivedAt }
        let newest = sorted.first!
        let oldest = sorted.last!
        let span = timeSpanString(from: oldest.receivedAt, to: newest.receivedAt)
        let headline = normalizeSubject(newest.subject)

        // Collect distinct normalized subjects for the takeaway.
        var distinct: [String] = []
        for member in sorted {
            let normalized = normalizeSubject(member.subject)
            if !distinct.contains(normalized) {
                distinct.append(normalized)
            }
        }

        let takeaway: String
        if distinct.count <= 1 {
            takeaway = "\(cluster.count) message\(cluster.count == 1 ? "" : "s")"
        } else {
            let others = distinct.dropFirst()  // skip headline subject
            let preview = others.prefix(3).joined(separator: " · ")
            let remaining = max(0, others.count - 3)
            takeaway = remaining > 0 ? "also: \(preview) +\(remaining) more" : "also: \(preview)"
        }

        return DigestEntry(
            headline: headline,
            keyTakeaway: takeaway,
            sourceCount: cluster.count,
            timeSpan: span,
            messageIDs: cluster.map(\.messageID),
            expandedSummary: nil
        )
    }

    private func mostRecent(in entry: DigestEntry, source: [DigestInput]) -> Date {
        let idSet = Set(entry.messageIDs)
        return source
            .filter { idSet.contains($0.messageID) }
            .map(\.receivedAt)
            .max() ?? .distantPast
    }

    private func normalizeSubject(_ subject: String) -> String {
        var s = subject
        let prefixes = ["Re: ", "RE: ", "Fwd: ", "FWD: ", "re: ", "fwd: ", "Fw: ", "fw: "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                changed = true
                break
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func timeSpanString(from start: Date, to end: Date) -> String {
        let seconds = end.timeIntervalSince(start)
        if seconds < 3600 {
            return "< 1 hour"
        } else if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let days = Int(seconds / 86400)
            return "\(days) day\(days == 1 ? "" : "s")"
        }
    }
}
