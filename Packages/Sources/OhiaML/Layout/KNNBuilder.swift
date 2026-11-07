import Foundation
import Metal
import MetalPerformanceShaders
import OhiaCore

public final class KNNBuilder {

    public enum Error: Swift.Error, Sendable {
        case deviceUnavailable
        case bufferAllocationFailed
        case commandExecutionFailed(String)
    }

    /// Bounds the temporary M x N cosine matrix. The corpus matrix is uploaded
    /// once; only this result buffer is recycled as query batches advance.
    private static let defaultMaximumSimilarityBufferBytes = 32 * 1024 * 1024
    private static let cancellationCheckStride = 256

    private struct PreparedRows {
        let ids: [Int64]
        var flatVectors: [Float]
        let dimension: Int

        var count: Int { ids.count }
    }

    private struct ScoredCandidate {
        let id: Int64
        let similarity: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.deviceUnavailable
        }
        self.device = device
        self.commandQueue = queue
    }

    /// Cosine-similarity top-K between `newVector` and `existing`. Brute-force via MPS matmul.
    /// For Phase 1 corpus sizes (up to ~60K vectors, 512-d), this runs in tens of ms on M1.
    public func buildKNN(
        newVector: [Float],
        existing: [(id: Int64, vec: [Float])],
        topK: Int
    ) throws -> [VectorNeighbor] {
        try buildKNNBatch(
            newVectors: [(id: -1, vec: newVector)],
            existing: existing,
            topK: topK
        )[-1] ?? []
    }

    /// Batched cosine-similarity top-K. The existing corpus is normalized and
    /// uploaded once, then query chunks are multiplied against it while a
    /// bounded result buffer is reused. Indexing currently sends at most 32
    /// queries, so it normally remains a single MPS dispatch.
    public func buildKNNBatch(
        newVectors: [(id: Int64, vec: [Float])],
        existing: [(id: Int64, vec: [Float])],
        topK: Int
    ) throws -> [Int64: [VectorNeighbor]] {
        guard !newVectors.isEmpty, !existing.isEmpty, topK > 0 else { return [:] }
        let dimension = newVectors[0].vec.count
        guard dimension > 0 else { return [:] }

        var queries = try Self.prepareRows(newVectors, dimension: dimension)
        var corpus = try Self.prepareRows(existing, dimension: dimension)
        guard queries.count > 0, corpus.count > 0 else { return [:] }

        let queryBuffer = try makeBuffer(for: queries.flatVectors)
        let corpusBuffer = try makeBuffer(for: corpus.flatVectors)
        queries.flatVectors.removeAll(keepingCapacity: false)
        corpus.flatVectors.removeAll(keepingCapacity: false)
        var results: [Int64: [VectorNeighbor]] = [:]
        results.reserveCapacity(queries.count)

        try processSimilarityBatches(
            queries: queries,
            queryBuffer: queryBuffer,
            corpus: corpus,
            corpusBuffer: corpusBuffer,
            topK: topK,
            maximumSimilarityBufferBytes: Self.defaultMaximumSimilarityBufferBytes,
            excludeMatchingIDs: false
        ) { batch, _, _ in
            for row in batch {
                results[row.sourceId] = row.neighbors
            }
        }
        return results
    }

    /// Streams an all-corpus k-NN graph in bounded query batches. The corpus is
    /// normalized and uploaded exactly once and doubles as the query matrix;
    /// `MPSMatrix` offsets select each consecutive query chunk without copying.
    /// The consumer can persist each batch without retaining a second full
    /// O(N x K) result dictionary.
    public func buildAllKNNBatches(
        vectors: [(id: Int64, vec: [Float])],
        topK: Int,
        maximumSimilarityBufferBytes: Int = 32 * 1024 * 1024,
        consume: (
            _ batch: [(sourceId: Int64, neighbors: [VectorNeighbor])],
            _ completedQueryCount: Int,
            _ totalQueryCount: Int
        ) throws -> Void
    ) throws {
        guard !vectors.isEmpty, topK > 0 else { return }
        let dimension = vectors[0].vec.count
        guard dimension > 0 else { return }

        var corpus = try Self.prepareRows(vectors, dimension: dimension)
        guard corpus.count > 0 else { return }
        let corpusBuffer = try makeBuffer(for: corpus.flatVectors)
        corpus.flatVectors.removeAll(keepingCapacity: false)

        try processSimilarityBatches(
            queries: corpus,
            queryBuffer: corpusBuffer,
            corpus: corpus,
            corpusBuffer: corpusBuffer,
            topK: topK,
            maximumSimilarityBufferBytes: maximumSimilarityBufferBytes,
            excludeMatchingIDs: true,
            consume: consume
        )
    }

    private func processSimilarityBatches(
        queries: PreparedRows,
        queryBuffer: MTLBuffer,
        corpus: PreparedRows,
        corpusBuffer: MTLBuffer,
        topK: Int,
        maximumSimilarityBufferBytes: Int,
        excludeMatchingIDs: Bool,
        consume: (
            _ batch: [(sourceId: Int64, neighbors: [VectorNeighbor])],
            _ completedQueryCount: Int,
            _ totalQueryCount: Int
        ) throws -> Void
    ) throws {
        guard queries.count > 0, corpus.count > 0, topK > 0 else { return }
        try Task.checkCancellation()

        let scalarBytes = MemoryLayout<Float>.size
        let queryRowBytes = try Self.checkedProduct(queries.dimension, scalarBytes)
        let similarityRowBytes = try Self.checkedProduct(corpus.count, scalarBytes)
        guard similarityRowBytes <= device.maxBufferLength else {
            throw Error.bufferAllocationFailed
        }

        let requestedLimit = max(similarityRowBytes, maximumSimilarityBufferBytes)
        let effectiveLimit = min(requestedLimit, device.maxBufferLength)
        let queriesPerBatch = max(
            1,
            min(queries.count, effectiveLimit / similarityRowBytes)
        )
        let outputBufferBytes = try Self.checkedProduct(queriesPerBatch, similarityRowBytes)
        guard let outputBuffer = device.makeBuffer(
            length: outputBufferBytes,
            options: .storageModeShared
        ) else {
            throw Error.bufferAllocationFailed
        }

        let corpusDescriptor = MPSMatrixDescriptor(
            rows: corpus.count,
            columns: corpus.dimension,
            rowBytes: queryRowBytes,
            dataType: .float32
        )
        let corpusMatrix = MPSMatrix(buffer: corpusBuffer, descriptor: corpusDescriptor)

        for start in stride(from: 0, to: queries.count, by: queriesPerBatch) {
            try Task.checkCancellation()
            let batchCount = min(queriesPerBatch, queries.count - start)
            let queryDescriptor = MPSMatrixDescriptor(
                rows: batchCount,
                columns: queries.dimension,
                rowBytes: queryRowBytes,
                dataType: .float32
            )
            let outputDescriptor = MPSMatrixDescriptor(
                rows: batchCount,
                columns: corpus.count,
                rowBytes: similarityRowBytes,
                dataType: .float32
            )
            let queryMatrix = MPSMatrix(
                buffer: queryBuffer,
                offset: start * queryRowBytes,
                descriptor: queryDescriptor
            )
            let outputMatrix = MPSMatrix(buffer: outputBuffer, descriptor: outputDescriptor)
            let multiplication = MPSMatrixMultiplication(
                device: device,
                transposeLeft: false,
                transposeRight: true,
                resultRows: batchCount,
                resultColumns: corpus.count,
                interiorColumns: queries.dimension,
                alpha: 1.0,
                beta: 0.0
            )

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw Error.bufferAllocationFailed
            }
            multiplication.encode(
                commandBuffer: commandBuffer,
                leftMatrix: queryMatrix,
                rightMatrix: corpusMatrix,
                resultMatrix: outputMatrix
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status == .error {
                throw Error.commandExecutionFailed(
                    commandBuffer.error?.localizedDescription ?? "Metal k-NN command failed"
                )
            }
            try Task.checkCancellation()

            let pointer = outputBuffer.contents().bindMemory(
                to: Float.self,
                capacity: queriesPerBatch * corpus.count
            )
            var batch: [(sourceId: Int64, neighbors: [VectorNeighbor])] = []
            batch.reserveCapacity(batchCount)
            for localRow in 0..<batchCount {
                let queryIndex = start + localRow
                let sourceID = queries.ids[queryIndex]
                let similarities = UnsafeBufferPointer(
                    start: pointer.advanced(by: localRow * corpus.count),
                    count: corpus.count
                )
                batch.append((
                    sourceId: sourceID,
                    neighbors: try Self.selectTopK(
                        sourceID: sourceID,
                        candidateIDs: corpus.ids,
                        similarities: similarities,
                        topK: topK,
                        excludingTargetID: excludeMatchingIDs ? sourceID : nil
                    )
                ))
            }
            try consume(batch, start + batchCount, queries.count)
        }
    }

    private func makeBuffer(for values: [Float]) throws -> MTLBuffer {
        let byteCount = try Self.checkedProduct(values.count, MemoryLayout<Float>.size)
        guard byteCount > 0, byteCount <= device.maxBufferLength else {
            throw Error.bufferAllocationFailed
        }
        return try values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let buffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: byteCount,
                    options: []
                  ) else {
                throw Error.bufferAllocationFailed
            }
            return buffer
        }
    }

    private static func prepareRows(
        _ rows: [(id: Int64, vec: [Float])],
        dimension: Int
    ) throws -> PreparedRows {
        var ids: [Int64] = []
        ids.reserveCapacity(rows.count)
        var flat: [Float] = []
        let reserve = rows.count.multipliedReportingOverflow(by: dimension)
        if !reserve.overflow {
            flat.reserveCapacity(reserve.partialValue)
        }

        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: cancellationCheckStride) {
                try Task.checkCancellation()
            }
            guard row.vec.count == dimension else { continue }
            var squaredNorm: Double = 0
            for value in row.vec {
                let finiteValue = value.isFinite ? value : 0
                squaredNorm += Double(finiteValue) * Double(finiteValue)
            }
            ids.append(row.id)
            if squaredNorm.isFinite, squaredNorm > 1e-24 {
                let inverseNorm = Float(1.0 / sqrt(squaredNorm))
                for value in row.vec {
                    flat.append((value.isFinite ? value : 0) * inverseNorm)
                }
            } else {
                flat.append(contentsOf: repeatElement(Float(0), count: dimension))
            }
        }
        try Task.checkCancellation()
        return PreparedRows(ids: ids, flatVectors: flat, dimension: dimension)
    }

    /// Maintains the worst retained candidate at the heap root, replacing it
    /// only when a better candidate arrives. This is O(N log K), followed by a
    /// deterministic K-element rank sort; the former full N-element sort was
    /// O(N log N) for every query row.
    private static func selectTopK(
        sourceID: Int64,
        candidateIDs: [Int64],
        similarities: UnsafeBufferPointer<Float>,
        topK: Int,
        excludingTargetID: Int64?
    ) throws -> [VectorNeighbor] {
        guard topK > 0 else { return [] }
        var heap: [ScoredCandidate] = []
        heap.reserveCapacity(min(topK, candidateIDs.count))

        for index in candidateIDs.indices {
            if index.isMultiple(of: cancellationCheckStride) {
                try Task.checkCancellation()
            }
            let candidateID = candidateIDs[index]
            if candidateID == excludingTargetID { continue }
            let raw = similarities[index]
            let similarity = raw.isFinite ? min(Float(1), max(Float(-1), raw)) : 0
            let candidate = ScoredCandidate(id: candidateID, similarity: similarity)

            if heap.count < topK {
                heap.append(candidate)
                siftWorstUp(&heap, from: heap.count - 1)
            } else if let worst = heap.first, ranksBefore(candidate, worst) {
                heap[0] = candidate
                siftWorstDown(&heap, from: 0)
            }
        }

        heap.sort(by: ranksBefore)
        return heap.enumerated().map { rank, candidate in
            VectorNeighbor(
                sourceId: sourceID,
                targetId: candidate.id,
                similarity: candidate.similarity,
                rank: rank
            )
        }
    }

    private static func ranksBefore(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.similarity == rhs.similarity {
            return lhs.id < rhs.id
        }
        return lhs.similarity > rhs.similarity
    }

    private static func isWorse(_ lhs: ScoredCandidate, than rhs: ScoredCandidate) -> Bool {
        ranksBefore(rhs, lhs)
    }

    private static func siftWorstUp(_ heap: inout [ScoredCandidate], from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftWorstDown(_ heap: inout [ScoredCandidate], from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var worst = left
            if right < heap.count, isWorse(heap[right], than: heap[left]) {
                worst = right
            }
            guard isWorse(heap[worst], than: heap[parent]) else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        guard !product.overflow, product.partialValue >= 0 else {
            throw Error.bufferAllocationFailed
        }
        return product.partialValue
    }
}
