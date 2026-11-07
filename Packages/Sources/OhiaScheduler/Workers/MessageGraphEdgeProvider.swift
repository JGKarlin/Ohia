import Foundation
import OhiaCore
import OhiaML

/// SQLite-backed structural edge provider for frame-burst and Constellation
/// render work. It intentionally avoids SwiftData/ModelContext so frame edges
/// can be planned from worker actors without hopping to the main actor.
public final class MessageGraphEdgeProvider: FrameEdgeProvider {
    private let messageStoreURL: URL
    private let vectorStore: VectorStore

    private struct WeightedKey: Sendable {
        let key: String
        let weight: Float
    }

    private struct BucketPeer: Sendable {
        let vid: Int64
        let date: Date
        let weight: Float
    }

    public init(messageStoreURL: URL, vectorStore: VectorStore) {
        self.messageStoreURL = messageStoreURL
        self.vectorStore = vectorStore
    }

    public func threadEdges(
        for vectorIds: [Int64],
        topK: Int
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        var byThread: [UUID: [(vid: Int64, date: Date)]] = [:]
        for (vid, row) in context {
            guard let threadId = row.threadId else { continue }
            byThread[threadId, default: []].append((vid, row.date))
        }

        var out: [Int64: [VectorNeighbor]] = [:]
        for (vid, row) in context {
            guard let threadId = row.threadId else { continue }
            let peers = (byThread[threadId] ?? [])
                .filter { $0.vid != vid }
                .sorted {
                    let lhsDelta = abs($0.date.timeIntervalSince(row.date))
                    let rhsDelta = abs($1.date.timeIntervalSince(row.date))
                    if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
                    return $0.vid < $1.vid
                }
                .prefix(topK)
            out[vid] = peers.enumerated().map { rank, pair in
                VectorNeighbor(sourceId: vid, targetId: pair.vid, similarity: 1, rank: rank)
            }
        }
        return out
    }

    public func correspondentEdges(
        for vectorIds: [Int64],
        topK: Int
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        return Self.keyedEdges(context: context, topK: topK) { row in
            Self.correspondentSignals(for: row)
        }
    }

    public func temporalEdges(
        for vectorIds: [Int64],
        topK: Int,
        windowDays: Double
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        let windowSec = windowDays * 86_400
        let sorted = context.map { (vid: $0.key, date: $0.value.date) }
            .sorted { $0.date < $1.date }
        let dates = sorted.map(\.date)
        var out: [Int64: [VectorNeighbor]] = [:]

        for (vid, row) in context {
            let lo = Self.lowerBound(dates, value: row.date.addingTimeInterval(-windowSec))
            let hi = Self.upperBound(dates, value: row.date.addingTimeInterval(windowSec))
            let peers = sorted[lo..<hi]
                .filter { $0.vid != vid }
                .map { pair -> (vid: Int64, sim: Float) in
                    let delta = abs(pair.date.timeIntervalSince(row.date))
                    let sim = Float(max(0, 1 - delta / windowSec))
                    return (pair.vid, sim)
                }
                .sorted { $0.sim > $1.sim }
                .prefix(topK)
            out[vid] = peers.enumerated().map { rank, pair in
                VectorNeighbor(sourceId: vid, targetId: pair.vid, similarity: pair.sim, rank: rank)
            }
        }
        return out
    }

    public func actionEdges(
        for vectorIds: [Int64],
        topK: Int
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        return Self.keyedEdges(context: context, topK: topK) { row in
            Self.actionSignals(for: row)
        }
    }

    public func classificationEdges(
        for vectorIds: [Int64],
        topK: Int
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        return Self.keyedEdges(context: context, topK: topK) { row in
            Self.classificationSignals(for: row)
        }
    }

    public func arcEdges(
        for vectorIds: [Int64],
        topK: Int
    ) async throws -> [Int64: [VectorNeighbor]] {
        let context = try edgeContext(for: vectorIds)
        return Self.keyedEdges(context: context, topK: topK) { row in
            Self.arcSignals(for: row)
        }
    }

    private func edgeContext(for vectorIds: [Int64]) throws -> [Int64: MessageStoreFrameEdgeRow] {
        guard !vectorIds.isEmpty else { return [:] }
        let messageIdByVector = try vectorStore.messageIds(for: vectorIds)
        let rowsByMessage = try MessageStoreHotPath.frameEdgeRows(
            messageIds: Array(Set(messageIdByVector.values)),
            storeURL: messageStoreURL
        ) ?? [:]

        var out: [Int64: MessageStoreFrameEdgeRow] = [:]
        out.reserveCapacity(messageIdByVector.count)
        for (vectorId, messageId) in messageIdByVector {
            if let row = rowsByMessage[messageId] {
                out[vectorId] = row
            }
        }
        return out
    }

    private static func lowerBound(_ sorted: [Date], value: Date) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func lowerBound(_ sorted: [BucketPeer], value: Date) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].date < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func upperBound(_ sorted: [Date], value: Date) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func keyedEdges(
        context: [Int64: MessageStoreFrameEdgeRow],
        topK: Int,
        signals: (MessageStoreFrameEdgeRow) -> [WeightedKey]
    ) -> [Int64: [VectorNeighbor]] {
        guard topK > 0 else { return [:] }

        let signalRows: [Int64: [WeightedKey]] = context.mapValues(signals)
        var buckets: [String: [BucketPeer]] = [:]
        for (vid, rowSignals) in signalRows {
            guard let date = context[vid]?.date else { continue }
            for signal in rowSignals {
                buckets[signal.key, default: []].append(BucketPeer(vid: vid, date: date, weight: signal.weight))
            }
        }
        let bucketsByDate = buckets.mapValues {
            $0.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.vid < $1.vid
            }
        }
        let bucketsByWeight = buckets.mapValues {
            $0.sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.vid < $1.vid
            }
        }
        let perSignalCandidateLimit = max(topK * 6, 48)

        var out: [Int64: [VectorNeighbor]] = [:]
        for (vid, row) in context {
            let rowSignals = signalRows[vid] ?? []
            guard rowSignals.isEmpty == false else { continue }
            var scores: [Int64: Float] = [:]
            for signal in rowSignals {
                let candidates = boundedCandidates(
                    byDate: bucketsByDate[signal.key] ?? [],
                    byWeight: bucketsByWeight[signal.key] ?? [],
                    sourceId: vid,
                    sourceDate: row.date,
                    limit: perSignalCandidateLimit
                )
                for peer in candidates {
                    let score = min(signal.weight, peer.weight)
                    scores[peer.vid] = min(1, scores[peer.vid, default: 0] + score)
                }
            }
            let ranked = scores
                .map { (vid: $0.key, score: $0.value) }
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    let lhsDate = context[$0.vid]?.date ?? Date(timeIntervalSinceReferenceDate: 0)
                    let rhsDate = context[$1.vid]?.date ?? Date(timeIntervalSinceReferenceDate: 0)
                    let lhsDelta = abs(lhsDate.timeIntervalSince(row.date))
                    let rhsDelta = abs(rhsDate.timeIntervalSince(row.date))
                    if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
                    return $0.vid < $1.vid
                }
                .prefix(topK)
            out[vid] = ranked.enumerated().map { rank, pair in
                VectorNeighbor(sourceId: vid, targetId: pair.vid, similarity: pair.score, rank: rank)
            }
        }
        return out
    }

    private static func boundedCandidates(
        byDate: [BucketPeer],
        byWeight: [BucketPeer],
        sourceId: Int64,
        sourceDate: Date,
        limit: Int
    ) -> [BucketPeer] {
        guard limit > 0, byDate.count > 1 else { return [] }
        var selected: [Int64: BucketPeer] = [:]
        selected.reserveCapacity(min(limit * 2, max(0, byDate.count - 1)))

        func append(_ peer: BucketPeer) {
            guard peer.vid != sourceId else { return }
            selected[peer.vid] = peer
        }

        var left = lowerBound(byDate, value: sourceDate) - 1
        var right = left + 1
        while selected.count < limit && (left >= 0 || right < byDate.count) {
            if left < 0 {
                append(byDate[right])
                right += 1
            } else if right >= byDate.count {
                append(byDate[left])
                left -= 1
            } else {
                let leftPeer = byDate[left]
                let rightPeer = byDate[right]
                let leftDelta = abs(leftPeer.date.timeIntervalSince(sourceDate))
                let rightDelta = abs(rightPeer.date.timeIntervalSince(sourceDate))
                if leftDelta <= rightDelta {
                    append(leftPeer)
                    left -= 1
                } else {
                    append(rightPeer)
                    right += 1
                }
            }
        }

        for peer in byWeight.prefix(limit) {
            append(peer)
        }

        return Array(selected.values)
    }

    private static func correspondentSignals(for row: MessageStoreFrameEdgeRow) -> [WeightedKey] {
        let addresses: [String]
        if row.isSentByUser, row.participantAddresses.isEmpty == false {
            addresses = row.participantAddresses
        } else {
            addresses = [row.fromAddress]
        }
        return uniqueKeys(addresses).map { WeightedKey(key: "person:\($0)", weight: 1) }
    }

    private static func actionSignals(for row: MessageStoreFrameEdgeRow) -> [WeightedKey] {
        guard row.liveDetectedAt != nil, row.isSentByUser == false else {
            return []
        }
        let messageType = MessageType(rawValue: row.messageTypeRaw)
        let isActionable = row.triageIsActionable ?? (messageType == .actionable ? true : nil)
        let requiresConfirmation = row.triageRequiresConfirmation ?? (messageType == .confirmation ? true : nil)

        var signals: [WeightedKey] = []
        if isActionable == true {
            signals.append(WeightedKey(key: "attention:action", weight: 0.9))
            if let kind = normalized(row.actionKindRaw) {
                signals.append(WeightedKey(key: "action-kind:\(kind)", weight: 1.0))
            }
        }
        if requiresConfirmation == true {
            signals.append(WeightedKey(key: "attention:confirm", weight: 0.85))
            if let kind = normalized(row.signalKindRaw) {
                signals.append(WeightedKey(key: "signal-kind:\(kind)", weight: 1.0))
            }
        }
        if isActionable == false, requiresConfirmation == false {
            signals.append(WeightedKey(key: "attention:passive", weight: 0.6))
        }
        if signals.isEmpty, let messageType, messageType != .unclassified {
            signals.append(WeightedKey(key: "attention-type:\(messageType.rawValue)", weight: 0.55))
        }
        return signals
    }

    private static func classificationSignals(for row: MessageStoreFrameEdgeRow) -> [WeightedKey] {
        let classification = MailClassificationJSON.decode(row.mailClassificationJSON)
        return draftingMemoryFacets(
            classification: classification,
            customCategoryKeys: []
        ).semanticAffinityKeys.map { key in
            WeightedKey(
                key: "classification:\(key)",
                weight: key.hasPrefix("purpose.") ? 1.0 : 0.65
            )
        }
    }

    private static func arcSignals(for row: MessageStoreFrameEdgeRow) -> [WeightedKey] {
        guard let dimensionsJSON = row.dimensionsJSON,
              let data = dimensionsJSON.data(using: .utf8),
              let dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            return []
        }

        var signals: [WeightedKey] = []
        let ranked = SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .filter { $0.score >= 0.1 }
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(4)
        for tag in ranked {
            let key = tag.tagID.uuidString.lowercased()
            let weight = max(0.2, min(1.0, Float(tag.weightedScore)))
            signals.append(WeightedKey(key: "arc-tag:\(key)", weight: weight * 0.65))
            for role in tag.roles.prefix(2) {
                signals.append(WeightedKey(
                    key: "arc-tag-role:\(key):\(role.rawValue)",
                    weight: weight * 0.15
                ))
            }
        }
        return signals
    }

    private static func uniqueKeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            guard let key = normalized(value), seen.insert(key).inserted else { continue }
            out.append(key)
        }
        return out
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
