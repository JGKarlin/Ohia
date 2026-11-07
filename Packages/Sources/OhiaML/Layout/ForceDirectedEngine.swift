import Foundation
import Metal
import OhiaCore

public actor ForceDirectedEngine {

    public enum Error: Swift.Error {
        case deviceUnavailable
        case pipelineUnavailable
        case bufferAllocationFailed
        case commandExecutionFailed
    }

    /// Keep cancellation responsive without paying one command-buffer commit
    /// and one CPU/GPU rendezvous per simulation iteration.
    static let iterationsPerCommandBuffer = 16

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.deviceUnavailable
        }
        self.device = device
        self.queue = queue

        // SwiftPM's command-line build only *copies* .metal files, it doesn't invoke
        // the metal compiler (that's Xcode's build system). So load the source and
        // build the library at runtime; this works uniformly for SwiftPM tests and
        // Xcode app builds (Xcode provides a precompiled default library, but this
        // path is still valid there). See https://developer.apple.com/metal .
        let library: MTLLibrary
        do {
            if let precompiled = try? device.makeDefaultLibrary(bundle: Bundle.module),
               precompiled.functionNames.contains("force_directed_step") {
                library = precompiled
            } else if let url = Bundle.module.url(forResource: "ForceDirected", withExtension: "metal") {
                let source = try String(contentsOf: url, encoding: .utf8)
                library = try device.makeLibrary(source: source, options: nil)
            } else {
                throw Error.pipelineUnavailable
            }
        } catch {
            throw Error.pipelineUnavailable
        }
        guard let fn = library.makeFunction(name: "force_directed_step") else {
            throw Error.pipelineUnavailable
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            throw Error.pipelineUnavailable
        }
    }

    /// Runs `iterations` iterations of the force-directed update kernel.
    /// `neighbors[i]` is the list of i's outgoing edges, each carrying target + similarity.
    /// Note: `VectorNeighbor.targetId` is the *position index* in `positions`, not a DB vector_id —
    /// the caller (`LayoutOrchestrator`) translates DB IDs to position indices before calling.
    public func step(
        positions: [SIMD3<Float>],
        neighbors: [[VectorNeighbor]],
        iterations: Int,
        dt: Float = 0.01,
        restLength: Float = 0.05,
        repulsionConstant: Float = 0.02,
        velocityDamping: Float = 0.85,
        negativeSamples: UInt32 = 5,
        startingSeed: UInt32 = 1
    ) async throws -> [SIMD3<Float>] {

        let n = positions.count
        guard n > 0 else { return [] }

        var offsets = [UInt32](); offsets.reserveCapacity(n + 1)
        var ids = [UInt32]()
        var sims = [Float]()
        offsets.append(0)
        for i in 0..<n {
            for e in neighbors[i] {
                ids.append(UInt32(clamping: e.targetId))
                sims.append(e.similarity)
            }
            offsets.append(UInt32(ids.count))
        }

        guard
            let posBuf = device.makeBuffer(bytes: positions, length: MemoryLayout<SIMD3<Float>>.stride * n, options: .storageModeShared),
            let velBuf = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride * n, options: .storageModeShared),
            let offBuf = device.makeBuffer(bytes: offsets, length: MemoryLayout<UInt32>.stride * offsets.count, options: .storageModeShared),
            let moveBuf = device.makeBuffer(length: MemoryLayout<Float>.stride * n, options: .storageModeShared)
        else {
            throw Error.bufferAllocationFailed
        }
        memset(velBuf.contents(), 0, MemoryLayout<SIMD3<Float>>.stride * n)
        memset(moveBuf.contents(), 0, MemoryLayout<Float>.stride * n)

        // Zero-length Metal buffers are invalid; fall back to 1-element placeholders when no edges exist.
        let idBuf: MTLBuffer
        if ids.isEmpty {
            guard let placeholder = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
                throw Error.bufferAllocationFailed
            }
            idBuf = placeholder
        } else {
            guard let buf = device.makeBuffer(bytes: ids, length: MemoryLayout<UInt32>.stride * ids.count, options: .storageModeShared) else {
                throw Error.bufferAllocationFailed
            }
            idBuf = buf
        }

        let simBuf: MTLBuffer
        if sims.isEmpty {
            guard let placeholder = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared) else {
                throw Error.bufferAllocationFailed
            }
            simBuf = placeholder
        } else {
            guard let buf = device.makeBuffer(bytes: sims, length: MemoryLayout<Float>.stride * sims.count, options: .storageModeShared) else {
                throw Error.bufferAllocationFailed
            }
            simBuf = buf
        }

        let tgSize = MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let gridSize = MTLSize(width: n, height: 1, depth: 1)
        let maxNeighbors = UInt32(neighbors.map(\.count).max() ?? 0)

        var nextIteration = 0
        while nextIteration < iterations {
            try Task.checkCancellation()
            let batchCount = min(
                Self.iterationsPerCommandBuffer,
                iterations - nextIteration
            )
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw Error.bufferAllocationFailed
            }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(posBuf, offset: 0, index: 0)
            enc.setBuffer(velBuf, offset: 0, index: 1)
            enc.setBuffer(offBuf, offset: 0, index: 2)
            enc.setBuffer(idBuf, offset: 0, index: 3)
            enc.setBuffer(simBuf, offset: 0, index: 4)
            enc.setBuffer(moveBuf, offset: 0, index: 5)
            for batchIndex in 0..<batchCount {
                let iteration = nextIteration + batchIndex
                var params = SimParams(
                    nodeCount: UInt32(n),
                    maxNeighborsPerNode: maxNeighbors,
                    negativeSamplesPerNode: negativeSamples,
                    restLength: restLength,
                    repulsionConstant: repulsionConstant,
                    velocityDamping: velocityDamping,
                    dt: dt,
                    iterationSeed: startingSeed &+ UInt32(iteration)
                )
                enc.setBytes(&params, length: MemoryLayout<SimParams>.size, index: 6)
                enc.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
                if batchIndex + 1 < batchCount {
                    // The next dispatch consumes positions and velocities
                    // written by this one. Keep the dependency on-GPU instead
                    // of forcing a command-buffer completion on the CPU.
                    enc.memoryBarrier(scope: .buffers)
                }
            }
            enc.endEncoding()
            cmd.commit()
            await cmd.completed()
            guard cmd.status == .completed else {
                throw Error.commandExecutionFailed
            }
            nextIteration += batchCount
        }

        try Task.checkCancellation()

        let ptr = posBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
        return Array(UnsafeBufferPointer(start: ptr, count: n))
    }
}
