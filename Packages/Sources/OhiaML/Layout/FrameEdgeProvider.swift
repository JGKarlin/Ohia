// Packages/Sources/OhiaML/Layout/FrameEdgeProvider.swift
import Foundation
import OhiaCore

/// Supplies per-source structural edges for the force-directed simulation.
/// The default implementation in the app target reads SwiftData; tests use a
/// mock conforming type.
///
/// Structural edges are queried lazily per frame because the underlying data
/// (threads, participants, received timestamps, interpretation labels) is
/// small per-node — not worth persisting. The frame-burst call path pulls
/// edges once and feeds them into the kernel for a single 200-iteration window;
/// continuous `.refine` passes reuse cosine edges only to stay cheap.
public protocol FrameEdgeProvider: Sendable {
    /// Thread neighbors: other vectors whose `Message` shares the same
    /// `MessageThread.id` as `vectorId`'s message. Returns top-`topK` rows
    /// sorted by temporal proximity (closest-in-time first) so the rank field
    /// has a stable meaning.
    func threadEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]]

    /// Correspondent neighbors: other vectors whose `Message.fromAddress`
    /// (case-insensitive match) equals this message's fromAddress.
    func correspondentEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]]

    /// Temporal neighbors: other vectors whose message arrived within
    /// ±`windowDays` of this message. Similarity in the returned rows is
    /// `1 - |Δdays| / windowDays`, clamped to `[0, 1]`.
    func temporalEdges(
        for vectorIds: [Int64],
        topK: Int,
        windowDays: Double
    ) async throws -> [Int64: [VectorNeighbor]]

    /// Attention neighbors: other vectors whose messages share Qwen-derived
    /// responsibility state (action-needed, confirmation/acknowledgement, or a
    /// narrower action/signal kind when available).
    func actionEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]]

    /// Classification neighbors: other vectors whose messages share a
    /// specific Purpose or Domain affinity key.
    func classificationEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]]

    /// Arc neighbors: other vectors whose analysis dimensions share project,
    /// team, or topic labels, weighted toward durable project labels.
    func arcEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]]
}

/// Null implementation — returns no edges from any source. Used during cold
/// build before Message data is available, and as a safe fallback in headless
/// test runs.
public struct NullFrameEdgeProvider: FrameEdgeProvider {
    public init() {}
    public func threadEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    public func correspondentEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    public func temporalEdges(for vectorIds: [Int64], topK: Int, windowDays: Double) async throws -> [Int64: [VectorNeighbor]] { [:] }
    public func actionEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    public func classificationEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    public func arcEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
}

public extension FrameEdgeProvider {
    func actionEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    func classificationEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
    func arcEdges(for vectorIds: [Int64], topK: Int) async throws -> [Int64: [VectorNeighbor]] { [:] }
}
