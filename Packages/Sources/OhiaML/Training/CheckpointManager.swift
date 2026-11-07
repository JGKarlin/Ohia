import Foundation
import CryptoKit
import SwiftData
import OhiaCore

public struct TrainingCheckpointAttempt: Codable, Sendable, Equatable {
    public let targetID: UUID
    public let pairID: UUID
    public let evidenceRevision: Int

    public init(targetID: UUID, pairID: UUID, evidenceRevision: Int) {
        self.targetID = targetID
        self.pairID = pairID
        self.evidenceRevision = evidenceRevision
    }
}

public struct TrainingCheckpointOptimizerState: Codable, Sendable, Equatable {
    public let filename: String
    public let descriptor: TrainingOptimizerStateDescriptor

    public init(filename: String, descriptor: TrainingOptimizerStateDescriptor) {
        self.filename = filename
        self.descriptor = descriptor
    }
}

public struct TrainingCheckpointManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3
    public static let oldestSupportedPromotedSchemaVersion = 2

    public let schemaVersion: Int
    public let checkpointID: UUID
    public let createdAt: Date
    public let compatibility: TrainingCheckpointCompatibility
    public let stepCount: Int
    public var lifecycle: TrainingCheckpointLifecycle
    public var baselineValidationLoss: Double?
    public var validationLoss: Double?
    public var validationExampleCount: Int?
    /// Identity of the exact held-out set `validationLoss` was measured on,
    /// so a later judgment on the same set can reuse it.
    public var validationFingerprint: String?
    public var rejectionReason: String?
    public let parentCheckpointID: UUID?
    public let runID: UUID?
    public let attempts: [TrainingCheckpointAttempt]
    public let optimizerState: TrainingCheckpointOptimizerState?
    public var quality: CheckpointQualityReport?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        checkpointID: UUID,
        createdAt: Date,
        compatibility: TrainingCheckpointCompatibility,
        stepCount: Int,
        lifecycle: TrainingCheckpointLifecycle,
        baselineValidationLoss: Double? = nil,
        validationLoss: Double? = nil,
        validationExampleCount: Int? = nil,
        validationFingerprint: String? = nil,
        rejectionReason: String? = nil,
        parentCheckpointID: UUID? = nil,
        runID: UUID? = nil,
        attempts: [TrainingCheckpointAttempt] = [],
        optimizerState: TrainingCheckpointOptimizerState? = nil,
        quality: CheckpointQualityReport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.checkpointID = checkpointID
        self.createdAt = createdAt
        self.compatibility = compatibility
        self.stepCount = stepCount
        self.lifecycle = lifecycle
        self.baselineValidationLoss = baselineValidationLoss
        self.validationLoss = validationLoss
        self.validationExampleCount = validationExampleCount
        self.validationFingerprint = validationFingerprint
        self.rejectionReason = rejectionReason
        self.parentCheckpointID = parentCheckpointID
        self.runID = runID
        self.attempts = attempts
        self.optimizerState = optimizerState
        self.quality = quality
    }
}

public final class CheckpointManager: Sendable {
    private let checkpointDirectory: URL

    public init(checkpointDirectory: URL) {
        self.checkpointDirectory = checkpointDirectory
    }

    @MainActor
    private static func qualityIdentity(context: ModelContext) throws -> CheckpointQualityIdentity {
        let identities = try context.fetch(FetchDescriptor<Identity>()).sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let identity = identities.first else { return .unconfigured }
        return .init(name: identity.displayName ?? identity.address, address: identity.address)
    }

    @MainActor
    @discardableResult
    public func saveCheckpoint(
        engine: TrainingEngine,
        stepCount: Int,
        loss: Double,
        learningRate: Double,
        corpusCoverage: Double,
        lifecycle: TrainingCheckpointLifecycle = .promoted,
        parentCheckpointID: UUID? = nil,
        runID: UUID? = nil,
        attempts: [TrainingCheckpointAttempt] = [],
        context: ModelContext
    ) async throws -> TrainingCheckpoint {
        guard let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
              let compatibility = checkpointEngine.checkpointCompatibility
        else {
            throw TrainingEngineError.saveFailed(
                "The loaded engine did not provide checkpoint compatibility metadata."
            )
        }
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)

        // MLX LoRATrain.saveLoRAWeights rejects generic .bin — it dispatches on
        // extension and accepts .safetensors (modern, preferred) or .npz (legacy).
        let checkpointID = UUID()
        let adapterFilename = "adapter-step-\(stepCount)-\(checkpointID.uuidString.lowercased()).safetensors"
        let adapterPath = checkpointDirectory.appendingPathComponent(adapterFilename).path

        // Write the adapter file. On throw, sweep any partial .safetensors so
        // the next call doesn't inherit a half-written file at the same path.
        do {
            try engine.saveAdapter(to: adapterPath)
        } catch {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: adapterPath))
            throw error
        }

        // Confirm the file landed — defends against an MLX backend that returns
        // without throwing yet fails to produce the output (we've seen it) — and
        // fsync the bytes to stable storage before committing the SwiftData row.
        // Without the fsync, a crash between the write-cache flush and the row
        // save leaves an orphan row whose adapterPath points at a ghost file,
        // which is the exact shape of the "adapter-step-20.safetensors not
        // found" boot error that motivated this fix.
        let fm = FileManager.default
        guard fm.fileExists(atPath: adapterPath),
              let validation = Self.validateAdapterFile(atPath: adapterPath),
              validation.isLoadable
        else {
            try? fm.removeItem(at: URL(fileURLWithPath: adapterPath))
            throw TrainingEngineError.saveFailed(
                "adapter file missing, empty, or invalid after save: \(adapterPath)"
            )
        }
        let fd = open(adapterPath, O_RDONLY)
        if fd >= 0 {
            _ = fsync(fd)
            close(fd)
        }

        var optimizerState: TrainingCheckpointOptimizerState?
        var optimizerURL: URL?
        if let optimizerEngine = engine as? any OptimizerCheckpointingTrainingEngine {
            let filename = "optimizer-step-\(stepCount)-\(checkpointID.uuidString.lowercased()).safetensors"
            let url = checkpointDirectory.appendingPathComponent(filename)
            do {
                let descriptor = try optimizerEngine.saveOptimizerState(
                    to: url.path,
                    policyIdentifier: TrainingOptimizationPolicy.current.identifier
                )
                guard let size = Self.fileSize(atPath: url.path), size > 0 else {
                    throw TrainingEngineError.saveFailed(
                        "optimizer state missing or empty after save: \(url.path)"
                    )
                }
                let optimizerFD = open(url.path, O_RDONLY)
                if optimizerFD >= 0 {
                    _ = fsync(optimizerFD)
                    close(optimizerFD)
                }
                optimizerURL = url
                optimizerState = TrainingCheckpointOptimizerState(
                    filename: filename,
                    descriptor: descriptor
                )
            } catch {
                try? fm.removeItem(at: URL(fileURLWithPath: adapterPath))
                try? fm.removeItem(at: url)
                throw error
            }
        }

        let checkpoint = TrainingCheckpoint(
            stepCount: stepCount,
            loss: loss,
            learningRate: learningRate,
            adapterPath: adapterPath
        )
        checkpoint.id = checkpointID
        checkpoint.corpusCoverage = corpusCoverage
        checkpoint.lifecycleRaw = lifecycle.rawValue
        checkpoint.parentCheckpointID = parentCheckpointID

        var manifest = TrainingCheckpointManifest(
            checkpointID: checkpointID,
            createdAt: checkpoint.createdAt,
            compatibility: compatibility,
            stepCount: stepCount,
            lifecycle: lifecycle,
            parentCheckpointID: parentCheckpointID,
            runID: runID,
            attempts: attempts,
            optimizerState: optimizerState
        )
        do {
            if lifecycle == .promoted {
                let digest = try CheckpointQuality.digest(at: adapterPath)
                let identity = try Self.qualityIdentity(context: context)
                let cancellation = GenerationCancellation()
                let report = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .background) {
                        try cancellation.checkCancellation()
                        try engine.loadAdapter(from: adapterPath)
                        return try checkpointEngine.evaluateCheckpointQuality(adapterDigest: digest, identity: identity,
                                                                              resuming: nil, cancellation: cancellation)
                    }.value
                } onCancel: { cancellation.cancel() }
                try Task.checkCancellation()
                guard report.qualifies(digest: digest, identity: identity) else {
                    throw CheckpointQualityError.rejected(report.rejectionSummary)
                }
                manifest.quality = report
            }
            checkpoint.manifestJSON = try Self.writeManifest(manifest, adapterPath: adapterPath)
        } catch {
            if lifecycle == .promoted {
                try? await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
            }
            try? fm.removeItem(at: URL(fileURLWithPath: adapterPath))
            if let optimizerURL { try? fm.removeItem(at: optimizerURL) }
            try? fm.removeItem(at: Self.manifestURL(adapterPath: adapterPath))
            throw TrainingEngineError.saveFailed("Could not persist checkpoint manifest: \(error)")
        }
        do {
            context.insert(checkpoint)
            try context.save()
        } catch {
            context.rollback()
            try? fm.removeItem(at: URL(fileURLWithPath: adapterPath))
            if let optimizerURL { try? fm.removeItem(at: optimizerURL) }
            try? fm.removeItem(at: Self.manifestURL(adapterPath: adapterPath))
            throw error
        }
        return checkpoint
    }

    @MainActor
    public func setLifecycle(
        _ lifecycle: TrainingCheckpointLifecycle,
        checkpoint: TrainingCheckpoint,
        baselineValidationLoss: Double? = nil,
        validationLoss: Double? = nil,
        validationExampleCount: Int? = nil,
        validationFingerprint: String? = nil,
        reason: String? = nil,
        saveChanges: Bool = true,
        context: ModelContext
    ) throws {
        guard var manifest = Self.manifest(for: checkpoint),
              Self.manifest(manifest, isBoundTo: checkpoint) else {
            throw TrainingEngineError.saveFailed("Checkpoint manifest is missing or unreadable.")
        }
        if lifecycle == .promoted {
            guard let quality = manifest.quality,
                  quality.qualifies(digest: try CheckpointQuality.digest(at: checkpoint.adapterPath), identity: try Self.qualityIdentity(context: context)) else {
                throw CheckpointQualityError.rejected("No passing quality evidence for the saved adapter and current writer.")
            }
        }
        manifest.lifecycle = lifecycle
        manifest.baselineValidationLoss = baselineValidationLoss
        manifest.validationLoss = validationLoss
        manifest.validationExampleCount = validationExampleCount
        manifest.validationFingerprint = validationFingerprint
        manifest.rejectionReason = reason

        let json = try Self.writeManifest(manifest, adapterPath: checkpoint.adapterPath)
        checkpoint.manifestJSON = json
        checkpoint.lifecycleRaw = lifecycle.rawValue
        checkpoint.baselineValidationLoss = baselineValidationLoss
        checkpoint.validationLoss = validationLoss
        checkpoint.validationExampleCount = validationExampleCount
        checkpoint.rejectionReason = reason
        if saveChanges {
            try context.save()
        }
    }

    /// The caller owns the background model lane. This never runs for an individual draft.
    ///
    /// Resumable: an interrupted check stores its drafts in the manifest and
    /// the next check continues from them. The base model's drafts are cached
    /// across checkpoints, so a new candidate drafts only its own probes.
    @MainActor
    public func qualify(_ checkpoint: TrainingCheckpoint, engine: TrainingEngine,
                        context: ModelContext,
                        shouldYield: (@MainActor @Sendable () -> String?)? = nil) async throws -> CheckpointQualityReport {
        guard let evaluator = engine as? any CheckpointAwareTrainingEngine,
              var manifest = Self.manifest(for: checkpoint), Self.manifest(manifest, isBoundTo: checkpoint) else {
            throw CheckpointQualityError.provenance
        }
        let path = checkpoint.adapterPath
        let digest = try CheckpointQuality.digest(at: path)
        let identity = try Self.qualityIdentity(context: context)
        if let quality = manifest.quality, quality.qualifies(digest: digest, identity: identity) { return quality }

        let state = TrainingRunState.current(context: context)
        let baseFingerprint = try evaluator.checkpointCompatibility.map {
            try CheckpointQuality.baseFingerprint(identity: identity, baseModelID: $0.baseModelID,
                                                  chatTemplateVersion: $0.chatTemplateVersion)
        }
        var resuming = manifest.quality?.resumable(adapterDigest: digest, identity: identity)
        if let baseFingerprint, state.baseQualityFingerprint == baseFingerprint,
           let json = state.baseQualityProbesJSON,
           let cached = try? JSONDecoder().decode([CheckpointQualityReport.Probe].self, from: Data(json.utf8)) {
            resuming = (resuming ?? CheckpointQualityReport(version: CheckpointQuality.version,
                writerVersion: ComposerWriterPrompt.taskIdentifier, adapterDigest: digest, checkedAt: .now,
                probes: [], baseProbes: [], identity: identity)).fillingBaseProbes(cached)
        }
        func record(_ report: CheckpointQualityReport) throws {
            manifest.quality = report
            checkpoint.manifestJSON = try Self.writeManifest(manifest, adapterPath: path)
            if let baseFingerprint, report.hasCompleteBaseProbes, state.baseQualityFingerprint != baseFingerprint,
               let base = report.baseProbes, let data = try? JSONEncoder().encode(base) {
                state.baseQualityProbesJSON = String(decoding: data, as: UTF8.self)
                state.baseQualityFingerprint = baseFingerprint
            }
            try context.save()
        }

        let cancellation = GenerationCancellation()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if shouldYield?() != nil || engine.isCancelled {
                    cancellation.cancel()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
        defer { monitor.cancel() }
        let report: CheckpointQualityReport
        do {
            report = try await withTaskCancellationHandler {
                try await Task.detached(priority: .background) { [resuming] in
                    try cancellation.checkCancellation()
                    return try evaluator.evaluateCheckpointQuality(adapterDigest: digest, identity: identity,
                                                                   resuming: resuming, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        } catch CheckpointQualityError.incomplete(let partial) {
            if partial.adapterDigest == digest, (try? CheckpointQuality.digest(at: path)) == digest {
                try? record(partial)
            }
            throw CheckpointQualityError.interrupted
        }
        try Task.checkCancellation()
        guard report.adapterDigest == digest,
              digest == (try CheckpointQuality.digest(at: path)) else { throw CheckpointQualityError.provenance }
        try record(report)
        return report
    }

    /// Quarantine any active `TrainingCheckpoint` row whose adapter file no
    /// longer exists on disk or fails a cheap adapter preflight. Defense-in-depth
    /// for ghost/truncated/wrong-payload rows: runs at boot before
    /// `BootAdapterLoader` picks the latest, so an invalid file can't trick
    /// `latestAdapterPath` into returning a row that can fatal inside MLX before
    /// Swift error handling has a chance to catch it. Rows stay in the store
    /// (history chart still works); `archived = true` just removes them from the
    /// active set.
    /// Returns the number of rows newly removed from active selection.
    @MainActor
    @discardableResult
    public func sweepOrphanRows(context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        var archivedCount = 0
        for ck in all where !ck.archived
            && ck.lifecycleRaw != TrainingCheckpointLifecycle.quarantined.rawValue
            && ck.lifecycleRaw != TrainingCheckpointLifecycle.rejected.rawValue
        {
            let manifest = Self.manifest(for: ck)
            if let manifest, !Self.manifest(manifest, isBoundTo: ck) {
                ck.lifecycleRaw = TrainingCheckpointLifecycle.quarantined.rawValue
                ck.rejectionReason = "checkpoint manifest does not match its persisted row"
                archivedCount += 1
                continue
            }
            if let reason = Self.artifactPreflightFailure(for: ck, manifest: manifest) {
                ck.lifecycleRaw = TrainingCheckpointLifecycle.quarantined.rawValue
                ck.rejectionReason = reason
                archivedCount += 1
                continue
            }
        }
        if archivedCount > 0 {
            try context.save()
        }
        return archivedCount
    }

    /// The read-only artifact test resume applies before it will load a
    /// checkpoint: the adapter file exists, is non-empty and parses as a
    /// LoRA adapter, and any optimizer state needed for restoration exists
    /// inside the checkpoint directory. Promoted weights with an obsolete
    /// policy start fresh moments, so their old optimizer artifact is optional.
    /// Nil when the artifacts are loadable;
    /// otherwise the reason `sweepOrphanRows` records.
    static func artifactPreflightFailure(
        for checkpoint: TrainingCheckpoint,
        manifest: TrainingCheckpointManifest?
    ) -> String? {
        guard let validation = validateAdapterFile(atPath: checkpoint.adapterPath) else {
            return "missing or empty"
        }
        guard validation.isLoadable else {
            return validation.reason ?? "adapter file is not loadable"
        }
        if let optimizerState = manifest?.optimizerState {
            if checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
               manifest?.lifecycle == .promoted,
               optimizerState.descriptor.policyIdentifier != TrainingOptimizationPolicy.current.identifier {
                return nil
            }
            guard let url = optimizerURL(for: optimizerState, adapterPath: checkpoint.adapterPath),
                  let size = fileSize(atPath: url.path), size > 0 else {
                return "optimizer state is missing, empty, or outside the checkpoint directory"
            }
        }
        return nil
    }

    private struct AdapterFileValidation {
        let isLoadable: Bool
        let reason: String?
    }

    private static func validateAdapterFile(atPath path: String) -> AdapterFileValidation? {
        guard let size = fileSize(atPath: path), size > 0 else {
            return AdapterFileValidation(isLoadable: false, reason: "missing or empty")
        }

        // Legacy tests and older .npz/.bin adapters have no safetensors header
        // to inspect here. Production LoRA checkpoints are .safetensors, so keep
        // the structural guard focused there.
        guard path.hasSuffix(".safetensors") else {
            return AdapterFileValidation(isLoadable: true, reason: nil)
        }

        do {
            try validateSafetensorsLoRAAdapter(atPath: path, fileSize: size)
            return AdapterFileValidation(isLoadable: true, reason: nil)
        } catch {
            return AdapterFileValidation(isLoadable: false, reason: "\(error)")
        }
    }

    private static func manifestURL(adapterPath: String) -> URL {
        URL(fileURLWithPath: adapterPath + ".manifest.json")
    }

    private static func optimizerURL(
        for state: TrainingCheckpointOptimizerState,
        adapterPath: String
    ) -> URL? {
        guard state.filename.isEmpty == false,
              state.filename == URL(fileURLWithPath: state.filename).lastPathComponent,
              state.filename.contains("/") == false,
              state.filename != ".",
              state.filename != ".." else {
            return nil
        }
        let directory = URL(fileURLWithPath: adapterPath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let candidate = directory
            .appendingPathComponent(state.filename)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else {
            return nil
        }
        return candidate
    }

    /// Whether a promoted checkpoint the given engine compatibility can load
    /// exists: the same row, manifest, binding, schema and compatibility
    /// tests `resumeFromLatest` applies, plus the artifact preflight its
    /// orphan sweep applies, so a promoted row whose adapter file vanished
    /// after startup is no lineage. Read-only: the row is left for resume's
    /// own recovery. Pair promotion stamps are meaningful only under such a
    /// lineage; an earlier task's stamps say nothing about the current one,
    /// so every eligible pair is untrained without it.
    @MainActor
    public static func hasPromotedLineage(
        compatibility: TrainingCheckpointCompatibility?,
        context: ModelContext
    ) throws -> Bool {
        guard let compatibility else { return false }
        let identity = try Self.qualityIdentity(context: context)
        return try context.fetch(FetchDescriptor<TrainingCheckpoint>()).contains { checkpoint in
            guard !checkpoint.archived,
                  checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                  let manifest = Self.manifest(for: checkpoint),
                  Self.manifest(manifest, isBoundTo: checkpoint) else { return false }
            return Self.isSupportedPromotedManifest(manifest)
                && manifest.lifecycle == .promoted
                && Self.hasCurrentQualityEvidence(manifest, identity: identity)
                && compatibility.canRetainVoice(from: manifest.compatibility)
                && Self.artifactPreflightFailure(for: checkpoint, manifest: manifest) == nil
        }
    }

    private static func isSupportedPromotedManifest(
        _ manifest: TrainingCheckpointManifest
    ) -> Bool {
        manifest.schemaVersion >= TrainingCheckpointManifest.oldestSupportedPromotedSchemaVersion
            && manifest.schemaVersion <= TrainingCheckpointManifest.currentSchemaVersion
    }

    /// Cheap status/selection check. Activation separately hashes the actual
    /// artifact; scheduler reads must not repeatedly hash adapter files.
    private static func hasCurrentQualityEvidence(_ manifest: TrainingCheckpointManifest,
                                                  identity: CheckpointQualityIdentity) -> Bool {
        guard let quality = manifest.quality else { return false }
        return quality.qualifies(digest: quality.adapterDigest, identity: identity)
    }

    struct VoiceLineage {
        let checkpoint: TrainingCheckpoint
        let revisions: [UUID: Set<Int>]
    }

    /// Resolve the artifact used by generation, then follow only its promoted
    /// ancestors. A newer failed descendant or another model cannot contribute
    /// learned examples to this snapshot. Archived parents still carry history.
    @MainActor
    static func voiceLineage(compatibility: TrainingCheckpointCompatibility?,
                             modelID: String? = nil, adapterRevision: String? = nil,
                             context: ModelContext) throws -> VoiceLineage? {
        guard compatibility != nil || (modelID != nil && adapterRevision != nil) else { return nil }
        let identity = try Self.qualityIdentity(context: context)
        let rows = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contract = TrainingCheckpointCompatibility.voiceContract(TrainingTaskIdentity.production.identifier)
        func accepted(_ row: TrainingCheckpoint) -> TrainingCheckpointManifest? {
            guard row.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                  let manifest = Self.manifest(for: row), Self.manifest(manifest, isBoundTo: row),
                  Self.isSupportedPromotedManifest(manifest), manifest.lifecycle == .promoted else { return nil }
            if let compatibility {
                guard compatibility.canRetainVoice(from: manifest.compatibility) else { return nil }
            } else {
                guard let contract, manifest.compatibility.baseModelID == modelID,
                      TrainingCheckpointCompatibility.voiceContract(manifest.compatibility.taskIdentifier) == contract
                else { return nil }
            }
            return manifest
        }
        let candidates = rows.filter { !$0.archived }.sorted {
            $0.stepCount == $1.stepCount ? $0.createdAt > $1.createdAt : $0.stepCount > $1.stepCount
        }
        guard let selected = candidates.first(where: { row in
            guard let manifest = accepted(row), Self.hasCurrentQualityEvidence(manifest, identity: identity),
                  Self.artifactPreflightFailure(for: row, manifest: manifest) == nil
            else { return false }
            guard let adapterRevision else { return true }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: row.adapterPath), options: .mappedIfSafe)
            else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == adapterRevision
        }) else { return nil }
        var revisions: [UUID: Set<Int>] = [:]
        var visited = Set<UUID>()
        var next: TrainingCheckpoint? = selected
        while let row = next, visited.insert(row.id).inserted, let manifest = accepted(row) {
            for attempt in manifest.attempts {
                revisions[attempt.pairID, default: []].insert(attempt.evidenceRevision)
            }
            next = manifest.parentCheckpointID.flatMap { byID[$0] }
        }
        return VoiceLineage(checkpoint: selected, revisions: revisions)
    }

    private static func restoreOptimizerState(
        manifest: TrainingCheckpointManifest,
        adapterPath: String,
        engine: TrainingEngine,
        exactResumeRequired: Bool
    ) throws {
        guard let optimizerEngine = engine as? any OptimizerCheckpointingTrainingEngine else {
            if exactResumeRequired {
                throw TrainingEngineError.loadFailed(
                    "Exact resume requires an optimizer-checkpointing training engine."
                )
            }
            return
        }
        guard let optimizerState = manifest.optimizerState,
              let url = optimizerURL(for: optimizerState, adapterPath: adapterPath) else {
            optimizerEngine.clearOptimizerState()
            if exactResumeRequired
                || manifest.schemaVersion >= TrainingCheckpointManifest.currentSchemaVersion {
                throw TrainingEngineError.loadFailed(
                    "Resume checkpoint did not contain optimizer state."
                )
            }
            return
        }
        guard optimizerState.descriptor.policyIdentifier == TrainingOptimizationPolicy.current.identifier else {
            optimizerEngine.clearOptimizerState()
            if exactResumeRequired {
                throw TrainingEngineError.loadFailed("Exact resume requires the current optimizer policy.")
            }
            // Qualification approves the voice weights independently of the
            // optimization schedule. Keep those weights and begin fresh Adam
            // moments when the policy changes; never quarantine a passing
            // personalized adapter merely because its optimizer is obsolete.
            return
        }
        guard let size = fileSize(atPath: url.path), size > 0 else {
            optimizerEngine.clearOptimizerState()
            throw TrainingEngineError.loadFailed(
                "Optimizer state file was missing or empty: \(url.path)"
            )
        }
        try optimizerEngine.loadOptimizerState(
            from: url.path,
            descriptor: optimizerState.descriptor
        )
    }

    private static func encodedManifest(_ manifest: TrainingCheckpointManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    @discardableResult
    private static func writeManifest(
        _ manifest: TrainingCheckpointManifest,
        adapterPath: String
    ) throws -> String {
        let data = try encodedManifest(manifest)
        try data.write(to: manifestURL(adapterPath: adapterPath), options: .atomic)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TrainingEngineError.saveFailed("Manifest was not valid UTF-8.")
        }
        return json
    }

    public static func manifest(for checkpoint: TrainingCheckpoint) -> TrainingCheckpointManifest? {
        let decoder = JSONDecoder()
        if let json = checkpoint.manifestJSON,
           let data = json.data(using: .utf8),
           let manifest = try? decoder.decode(TrainingCheckpointManifest.self, from: data)
        {
            return manifest
        }
        guard let data = try? Data(contentsOf: manifestURL(adapterPath: checkpoint.adapterPath)) else {
            return nil
        }
        return try? decoder.decode(TrainingCheckpointManifest.self, from: data)
    }

    private static func manifest(
        _ manifest: TrainingCheckpointManifest,
        isBoundTo checkpoint: TrainingCheckpoint
    ) -> Bool {
        manifest.checkpointID == checkpoint.id
            && manifest.stepCount == checkpoint.stepCount
    }

    private static func managedArtifactURL(
        for path: String,
        checkpointDirectory: URL
    ) -> URL? {
        let directory = checkpointDirectory.standardizedFileURL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return nil }
        return candidate
    }

    private enum AdapterPreflightError: Error, CustomStringConvertible {
        case headerTooSmall
        case headerLengthOutOfBounds(UInt64)
        case unreadableHeader
        case invalidJSON
        case noTensors
        case nonLoRATensor(String)
        case invalidTensor(String)

        var description: String {
            switch self {
            case .headerTooSmall:
                return "safetensors header is incomplete"
            case .headerLengthOutOfBounds(let length):
                return "safetensors header length is out of bounds: \(length)"
            case .unreadableHeader:
                return "safetensors header could not be read"
            case .invalidJSON:
                return "safetensors header is not valid JSON"
            case .noTensors:
                return "safetensors file contains no tensors"
            case .nonLoRATensor(let name):
                return "unexpected non-LoRA tensor: \(name)"
            case .invalidTensor(let name):
                return "invalid tensor metadata: \(name)"
            }
        }
    }

    private static func validateSafetensorsLoRAAdapter(
        atPath path: String,
        fileSize: Int64
    ) throws {
        guard fileSize >= 9 else {
            throw AdapterPreflightError.headerTooSmall
        }

        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let lengthData = try handle.read(upToCount: 8),
              lengthData.count == 8
        else {
            throw AdapterPreflightError.headerTooSmall
        }

        let headerLength = littleEndianUInt64(from: lengthData)
        let maxHeaderLength = UInt64(4 * 1024 * 1024)
        guard headerLength > 0,
              headerLength <= maxHeaderLength
        else {
            throw AdapterPreflightError.headerLengthOutOfBounds(headerLength)
        }
        let payloadStart = UInt64(8) + headerLength
        guard payloadStart <= UInt64(fileSize) else {
            throw AdapterPreflightError.headerLengthOutOfBounds(headerLength)
        }

        guard let headerData = try handle.read(upToCount: Int(headerLength)),
              headerData.count == Int(headerLength)
        else {
            throw AdapterPreflightError.unreadableHeader
        }

        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw AdapterPreflightError.invalidJSON
        }

        let payloadSize = UInt64(fileSize) - payloadStart
        var tensorCount = 0
        for (name, value) in header where name != "__metadata__" {
            tensorCount += 1
            guard name.contains(".lora_") else {
                throw AdapterPreflightError.nonLoRATensor(name)
            }
            guard let tensor = value as? [String: Any],
                  tensor["dtype"] is String,
                  let shape = tensor["shape"] as? [Any],
                  shape.isEmpty == false,
                  shape.allSatisfy({ int64Value($0).map { $0 > 0 } == true }),
                  let offsets = tensor["data_offsets"] as? [Any],
                  offsets.count == 2,
                  let start = uint64Value(offsets[0]),
                  let end = uint64Value(offsets[1]),
                  start < end,
                  end <= payloadSize
            else {
                throw AdapterPreflightError.invalidTensor(name)
            }
        }

        guard tensorCount > 0 else {
            throw AdapterPreflightError.noTensors
        }
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let value = try? FileManager.default.attributesOfItem(atPath: path)[.size] else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let int = value as? Int {
            return Int64(int)
        }
        if let int64 = value as? Int64 {
            return int64
        }
        return nil
    }

    private static func littleEndianUInt64(from data: Data) -> UInt64 {
        data.enumerated().reduce(UInt64(0)) { partial, pair in
            partial | (UInt64(pair.element) << UInt64(pair.offset * 8))
        }
    }

    private static func int64Value(_ value: Any) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let int = value as? Int {
            return Int64(int)
        }
        if let int64 = value as? Int64 {
            return int64
        }
        return nil
    }

    private static func uint64Value(_ value: Any) -> UInt64? {
        guard let int = int64Value(value), int >= 0 else {
            return nil
        }
        return UInt64(int)
    }

    @MainActor
    public func resumeFromLatest(
        engine: TrainingEngine,
        context: ModelContext,
        onLoadFailure: ((TrainingCheckpoint, Error) -> Void)? = nil
    ) async throws -> TrainingCheckpoint? {
        try await resumeFromLatest(
            engine: engine,
            context: context,
            restoreOptimizer: false,
            onLoadFailure: onLoadFailure
        )
    }

    /// Training-only promoted resume. Inference uses `resumeFromLatest` and
    /// therefore never retains optimizer moments. Schema-v2 promoted adapters
    /// remain valid and start a fresh bias-corrected optimizer.
    @MainActor
    public func resumeTrainingFromLatest(
        engine: TrainingEngine,
        context: ModelContext,
        onLoadFailure: ((TrainingCheckpoint, Error) -> Void)? = nil
    ) async throws -> TrainingCheckpoint? {
        try await resumeFromLatest(
            engine: engine,
            context: context,
            restoreOptimizer: true,
            onLoadFailure: onLoadFailure
        )
    }

    /// Restores one already-selected promoted checkpoint for continued
    /// training. The SwiftData values are copied before the detached MLX work
    /// so no model object crosses the actor boundary.
    @MainActor
    public func restoreTrainingCheckpoint(
        _ checkpoint: TrainingCheckpoint,
        engine: TrainingEngine,
        context: ModelContext
    ) async throws {
        guard checkpoint.archived == false,
              checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
              let manifest = Self.manifest(for: checkpoint),
              Self.manifest(manifest, isBoundTo: checkpoint),
              Self.isSupportedPromotedManifest(manifest),
              manifest.lifecycle == .promoted,
              let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
              let compatibility = checkpointEngine.checkpointCompatibility,
              compatibility.canRetainVoice(from: manifest.compatibility) else {
            throw TrainingEngineError.loadFailed(
                "The selected promoted checkpoint is no longer compatible or loadable."
            )
        }
        let adapterPath = checkpoint.adapterPath
        guard manifest.quality?.qualifies(digest: try CheckpointQuality.digest(at: adapterPath),
                                         identity: try Self.qualityIdentity(context: context)) == true else {
            throw CheckpointQualityError.rejected("The retained checkpoint has no current passing qualification.")
        }
        try await Task.detached(priority: .background) {
            try engine.loadAdapter(from: adapterPath)
            if compatibility == manifest.compatibility {
                try Self.restoreOptimizerState(manifest: manifest, adapterPath: adapterPath,
                    engine: engine, exactResumeRequired: false)
            } else {
                (engine as? any OptimizerCheckpointingTrainingEngine)?.clearOptimizerState()
            }
        }.value
    }

    @MainActor
    private func resumeFromLatest(
        engine: TrainingEngine,
        context: ModelContext,
        restoreOptimizer: Bool,
        onLoadFailure: ((TrainingCheckpoint, Error) -> Void)?
    ) async throws -> TrainingCheckpoint? {
        // Quarantine rows whose adapter files are missing before selection.
        // Without this, a row pointing at a deleted file (training_checkpoints/
        // wiped, prune partially failed, app-data migration) gets picked and
        // engine.loadAdapter throws adapterNotFound — aborting the training
        // session from the Settings "Train Now" button with no way to recover
        // from the UI. Mirrors BootAdapterLoader's graceful behavior: proceed
        // from base weights rather than refuse to train.
        try sweepOrphanRows(context: context)

        guard let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
              let compatibility = checkpointEngine.checkpointCompatibility
        else {
            return nil
        }

        let all = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let candidates = all
            .filter { checkpoint in
                guard !checkpoint.archived,
                      checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                      let manifest = Self.manifest(for: checkpoint),
                      Self.manifest(manifest, isBoundTo: checkpoint)
                else { return false }
                return Self.isSupportedPromotedManifest(manifest)
                    && manifest.lifecycle == .promoted
                    && compatibility.canRetainVoice(from: manifest.compatibility)
            }
            .sorted { lhs, rhs in
                if lhs.stepCount != rhs.stepCount { return lhs.stepCount > rhs.stepCount }
                return lhs.createdAt > rhs.createdAt
            }

        var hadFailure = false
        var transientQualityError: Error?
        let identity = try Self.qualityIdentity(context: context)
        for candidate in candidates {
            if Task.isCancelled {
                try? await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
                throw CancellationError()
            }
            if transientQualityError != nil {
                // A timeout or unavailable inference is not evidence against
                // these weights. Restore an already-qualified fallback without
                // spending another inference budget or poisoning uncertain rows.
                guard let report = Self.manifest(for: candidate)?.quality,
                      let digest = try? CheckpointQuality.digest(at: candidate.adapterPath),
                      report.qualifies(digest: digest, identity: identity) else { continue }
            }
            var evaluatingQuality = false
            var reconcilingLedger = false
            do {
                let path = candidate.adapterPath
                try await Task.detached(priority: .background) { try engine.loadAdapter(from: path) }.value
                evaluatingQuality = true
                let report = try await qualify(candidate, engine: engine, context: context)
                evaluatingQuality = false
                guard report.passed else {
                    throw CheckpointQualityError.rejected(report.rejectionSummary)
                }
                if restoreOptimizer, let manifest = Self.manifest(for: candidate) {
                    if manifest.compatibility == compatibility {
                        try Self.restoreOptimizerState(manifest: manifest, adapterPath: candidate.adapterPath,
                            engine: engine, exactResumeRequired: false)
                    } else {
                        // Warm-start the new task from approved voice weights;
                        // an interrupted run still requires exact identity below.
                        (engine as? any OptimizerCheckpointingTrainingEngine)?.clearOptimizerState()
                    }
                }
                reconcilingLedger = true
                try TrainingCorpusPlanner.reconcileRetainedCheckpoint(candidate, context: context)
                return candidate
            } catch {
                // A store failure is not a verdict about valid adapter bytes.
                // The selected passing weights remain safe for inference.
                if reconcilingLedger { throw error }
                if Task.isCancelled || error is CancellationError {
                    try? await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
                    throw error
                }
                if evaluatingQuality || (error as? CheckpointQualityError).map({
                    if case .interrupted = $0 { return true }; return false
                }) == true {
                    transientQualityError = error
                    try? await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
                    onLoadFailure?(candidate, error)
                    continue
                }
                hadFailure = true
                // Preserve the bytes for diagnosis, but make this row
                // ineligible and continue to the next compatible promoted
                // checkpoint. One bad latest candidate must not discard the
                // last-known-good adapter.
                candidate.lifecycleRaw = TrainingCheckpointLifecycle.quarantined.rawValue
                candidate.rejectionReason = error.localizedDescription
                if var manifest = Self.manifest(for: candidate) {
                    manifest.lifecycle = .quarantined
                    manifest.rejectionReason = error.localizedDescription
                    candidate.manifestJSON = try? Self.writeManifest(
                        manifest,
                        adapterPath: candidate.adapterPath
                    )
                }
                try? context.save()
                onLoadFailure?(candidate, error)
            }
        }
        if let transientQualityError {
            try await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
            throw transientQualityError
        }
        if hadFailure {
            try await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
            try TrainingCorpusPlanner.reconcileRetainedCheckpoint(nil, context: context)
        }
        return nil
    }

    /// Loads the newest exact, persisted attempt frontier for one run. This is
    /// training-only state: inference lookup continues to accept promoted
    /// checkpoints exclusively.
    @MainActor
    /// With `loading` false the newest candidate is returned without being
    /// loaded: the caller already holds that frontier's weights in memory.
    public func resumeCandidate(
        for runID: UUID,
        engine: TrainingEngine,
        context: ModelContext,
        loading: Bool = true,
        onLoadFailure: ((TrainingCheckpoint, Error) -> Void)? = nil
    ) throws -> (checkpoint: TrainingCheckpoint, manifest: TrainingCheckpointManifest)? {
        try sweepOrphanRows(context: context)
        guard let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
              let compatibility = checkpointEngine.checkpointCompatibility else {
            return nil
        }

        let all = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let identity = try Self.qualityIdentity(context: context)
        let qualifiedParent = all.filter { checkpoint in
            guard !checkpoint.archived, checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                  let manifest = Self.manifest(for: checkpoint), Self.manifest(manifest, isBoundTo: checkpoint),
                  let report = manifest.quality,
                  report.qualifies(digest: report.adapterDigest, identity: identity),
                  compatibility.canRetainVoice(from: manifest.compatibility) else { return false }
            return true
        }.sorted {
            $0.stepCount == $1.stepCount ? $0.createdAt > $1.createdAt : $0.stepCount > $1.stepCount
        }.first?.id
        let candidates = all
            .compactMap { checkpoint -> (TrainingCheckpoint, TrainingCheckpointManifest)? in
                guard !checkpoint.archived,
                      checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.resumeCandidate.rawValue,
                      let manifest = Self.manifest(for: checkpoint),
                      Self.manifest(manifest, isBoundTo: checkpoint),
                      manifest.lifecycle == .resumeCandidate,
                      manifest.schemaVersion == TrainingCheckpointManifest.currentSchemaVersion,
                      manifest.runID == runID,
                      manifest.parentCheckpointID == qualifiedParent,
                      manifest.compatibility == compatibility else {
                    return nil
                }
                return (checkpoint, manifest)
            }
            .sorted { lhs, rhs in
                if lhs.0.createdAt != rhs.0.createdAt {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.0.id.uuidString > rhs.0.id.uuidString
            }

        guard loading else { return candidates.first }
        for (checkpoint, manifest) in candidates {
            do {
                try engine.loadAdapter(from: checkpoint.adapterPath)
                try Self.restoreOptimizerState(
                    manifest: manifest,
                    adapterPath: checkpoint.adapterPath,
                    engine: engine,
                    exactResumeRequired: true
                )
                return (checkpoint, manifest)
            } catch {
                checkpoint.lifecycleRaw = TrainingCheckpointLifecycle.quarantined.rawValue
                checkpoint.rejectionReason = error.localizedDescription
                if var updatedManifest = Self.manifest(for: checkpoint) {
                    updatedManifest.lifecycle = .quarantined
                    updatedManifest.rejectionReason = error.localizedDescription
                    checkpoint.manifestJSON = try? Self.writeManifest(
                        updatedManifest,
                        adapterPath: checkpoint.adapterPath
                    )
                }
                try? context.save()
                onLoadFailure?(checkpoint, error)
            }
        }
        return nil
    }

    /// Returns the newest non-archived TrainingCheckpoint, or nil if none exist.
    /// Safe to call after restart — boot-time adapter load reads this.
    @MainActor
    public func latestAdapterPath(context: ModelContext) throws -> TrainingCheckpoint? {
        let identity = try Self.qualityIdentity(context: context)
        let all = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        return all
            .filter { checkpoint in
                guard !checkpoint.archived,
                      checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                      let manifest = Self.manifest(for: checkpoint)
                else { return false }
                return manifest.lifecycle == .promoted
                    && Self.manifest(manifest, isBoundTo: checkpoint)
                    && Self.isSupportedPromotedManifest(manifest)
                    && Self.hasCurrentQualityEvidence(manifest, identity: identity)
                    && Self.artifactPreflightFailure(for: checkpoint, manifest: manifest) == nil
            }
            .sorted {
                if $0.stepCount != $1.stepCount { return $0.stepCount < $1.stepCount }
                return $0.createdAt < $1.createdAt
            }
            .last
    }

    /// Retains the newest promoted and non-authoritative checkpoints for the
    /// requested exact compatibility. Foreign-model and legacy artifacts are
    /// never pruned. Older matching rows are archived and their files deleted.
    /// The TrainingCheckpoint SwiftData rows remain so the Training tab can
    /// still show historical loss.
    @MainActor
    public func pruneOld(
        keep: Int,
        keepNonPromoted: Int = 2,
        compatibility: TrainingCheckpointCompatibility? = nil,
        context: ModelContext
    ) throws {
        let keep = max(0, keep)
        let keepNonPromoted = max(0, keepNonPromoted)
        let identity = try Self.qualityIdentity(context: context)
        let all = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let active = all.filter { checkpoint in
            guard !checkpoint.archived,
                  checkpoint.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
                  let manifest = Self.manifest(for: checkpoint),
                  manifest.lifecycle == .promoted,
                  Self.hasCurrentQualityEvidence(manifest, identity: identity),
                  Self.manifest(manifest, isBoundTo: checkpoint)
            else { return false }
            guard let compatibility else { return true }
            return manifest.compatibility == compatibility
        }.sorted { $0.stepCount < $1.stepCount }
        let nonPromoted = all.filter { checkpoint in
            guard !checkpoint.archived,
                  checkpoint.lifecycleRaw != TrainingCheckpointLifecycle.promoted.rawValue,
                  let manifest = Self.manifest(for: checkpoint),
                  manifest.lifecycle != .promoted,
                  Self.manifest(manifest, isBoundTo: checkpoint)
            else { return false }
            guard let compatibility else { return true }
            return manifest.compatibility == compatibility
        }.sorted { $0.createdAt < $1.createdAt }
        let promotedToArchive = active.count > keep
            ? Array(active.prefix(active.count - keep))
            : []
        let nonPromotedToArchive = nonPromoted.count > keepNonPromoted
            ? Array(nonPromoted.prefix(nonPromoted.count - keepNonPromoted))
            : []
        let toArchive = promotedToArchive + nonPromotedToArchive
        guard !toArchive.isEmpty else { return }
        for ck in toArchive {
            if let adapterURL = Self.managedArtifactURL(
                for: ck.adapterPath,
                checkpointDirectory: checkpointDirectory
            ) {
                if let manifest = Self.manifest(for: ck),
                   let optimizerState = manifest.optimizerState,
                   let optimizerURL = Self.optimizerURL(
                       for: optimizerState,
                       adapterPath: adapterURL.path
                   ) {
                    try? FileManager.default.removeItem(at: optimizerURL)
                }
                try? FileManager.default.removeItem(at: adapterURL)
                try? FileManager.default.removeItem(
                    at: Self.manifestURL(adapterPath: adapterURL.path)
                )
            }
            ck.archived = true
        }
        try context.save()
    }

    /// Nukes all training state: adapter files on disk, TrainingCheckpoint
    /// rows, run traversal, pair incorporation stamps, and `TrainingRunState`
    /// last-run metadata — then flushes in-memory LoRA state by resetting
    /// the base model. `async` because the base-model reload can take
    /// seconds; the SwiftData writes run on MainActor and are fast.
    @MainActor
    public func resetToBase(
        engine: TrainingEngine,
        context: ModelContext,
        publisher: TrainingStatusPublisher
    ) async throws {
        publisher.setPhase(.resetting)

        // Commit the DB + disk reset before touching the engine, so a mid-reset
        // failure can't leave SwiftData pointing at deleted files.
        try Self.resetPersistedTrainingState(
            context: context,
            checkpointDirectory: checkpointDirectory
        )
        publisher.syncFromState(TrainingRunState.current(context: context))
        publisher.project(
            run: nil,
            pendingTrainingTargetCount: 0,
            checkpointLifecycle: nil
        )

        // Flush only the adapter from the already-loaded model. Re-resolving
        // "default" here could silently switch base models after a hardware or
        // catalog change, which would make reset itself a compatibility bug.
        do {
            guard let checkpointEngine = engine as? any CheckpointAwareTrainingEngine else {
                throw TrainingEngineError.loadFailed(
                    "The loaded engine cannot reset its adapter in place."
                )
            }
            try await Task.detached(priority: .userInitiated) {
                try checkpointEngine.resetAdapter()
            }.value
        } catch {
            publisher.recordError("reset failed: \(error.localizedDescription)")
            publisher.setPhase(.idle)
            throw error
        }

        publisher.clearAdapter()
        publisher.clearError()
        publisher.setPhase(.idle)
    }

    /// Deletes persisted adapters and run traversal, then clears every pair's
    /// promoted incorporation stamps without deleting the underlying evidence.
    /// Commits the DB before deleting files
    /// so a mid-reset failure can't strand rows pointing at missing adapters.
    @MainActor
    public static func resetPersistedTrainingState(
        context: ModelContext,
        checkpointDirectory: URL
    ) throws {
        let checkpoints = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let adapterPaths = checkpoints.map(\.adapterPath)
        let optimizerURLs = checkpoints.compactMap { checkpoint -> URL? in
            guard let adapterURL = Self.managedArtifactURL(
                for: checkpoint.adapterPath,
                checkpointDirectory: checkpointDirectory
            ), let manifest = Self.manifest(for: checkpoint),
              let optimizerState = manifest.optimizerState else {
                return nil
            }
            return Self.optimizerURL(
                for: optimizerState,
                adapterPath: adapterURL.path
            )
        }
        for ck in checkpoints { context.delete(ck) }

        let pairs = try context.fetch(FetchDescriptor<TrainingPair>())
        for pair in pairs {
            pair.latestPromotedEvidenceRevision = nil
            pair.latestPromotedRunID = nil
            pair.latestPromotedCheckpointID = nil
            pair.latestFailedEvidenceRevision = nil
            pair.latestFailedTrainingProfileID = nil
            pair.latestFailedSequenceTokens = nil
            pair.latestDeferredEvidenceRevision = nil
            pair.latestDeferredTrainingProfileID = nil
            pair.latestDeferredAt = nil
        }
        for run in try context.fetch(FetchDescriptor<TrainingCorpusRun>()) {
            context.delete(run)
        }

        let state = TrainingRunState.current(context: context)
        state.lastRunAt = nil
        state.lastLoss = nil
        state.lastDurationSeconds = nil
        state.lastPairsUsed = nil
        state.lastStepCount = 0
        state.lastError = nil
        try context.save()

        // The DB is now consistent. Delete the adapter files — orphan files are
        // benign; orphan rows are boot-path crashes.
        for path in adapterPaths {
            guard let adapterURL = Self.managedArtifactURL(
                for: path,
                checkpointDirectory: checkpointDirectory
            ) else { continue }
            try? FileManager.default.removeItem(at: adapterURL)
            try? FileManager.default.removeItem(
                at: Self.manifestURL(adapterPath: adapterURL.path)
            )
        }
        for optimizerURL in optimizerURLs {
            try? FileManager.default.removeItem(at: optimizerURL)
        }
        // Sweep any stray adapter/optimizer files and sidecars the DB didn't know about.
        if FileManager.default.fileExists(atPath: checkpointDirectory.path) {
            if let files = try? FileManager.default.contentsOfDirectory(at: checkpointDirectory, includingPropertiesForKeys: nil) {
                for url in files where url.lastPathComponent.hasPrefix("adapter-")
                    || url.lastPathComponent.hasPrefix("optimizer-") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Invalidates learned state after a prompt-format change without deleting
    /// historical adapter artifacts. Exact compatibility already prevents old
    /// manifests from loading; quarantining the rows makes that state explicit
    /// while preserving the evidence for diagnosis or export.
    @MainActor
    public static func invalidatePersistedTrainingStateForFormatChange(
        context: ModelContext,
        checkpointDirectory: URL,
        currentPromptFormatVersion: Int
    ) throws {
        let manager = CheckpointManager(checkpointDirectory: checkpointDirectory)
        let checkpoints = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let reason = "prompt format changed to version \(currentPromptFormatVersion)"
        for checkpoint in checkpoints {
            if let manifest = Self.manifest(for: checkpoint),
               Self.manifest(manifest, isBoundTo: checkpoint) {
                try manager.setLifecycle(
                    .quarantined,
                    checkpoint: checkpoint,
                    reason: reason,
                    context: context
                )
            } else {
                checkpoint.lifecycleRaw = TrainingCheckpointLifecycle.quarantined.rawValue
                checkpoint.rejectionReason = reason
            }
        }

        let pairs = try context.fetch(FetchDescriptor<TrainingPair>())
        for pair in pairs {
            pair.latestPromotedEvidenceRevision = nil
            pair.latestPromotedRunID = nil
            pair.latestPromotedCheckpointID = nil
            pair.latestDeferredEvidenceRevision = nil
            pair.latestDeferredTrainingProfileID = nil
            pair.latestDeferredAt = nil
        }
        for run in try context.fetch(FetchDescriptor<TrainingCorpusRun>()) {
            context.delete(run)
        }

        let state = TrainingRunState.current(context: context)
        state.lastRunAt = nil
        state.lastLoss = nil
        state.lastDurationSeconds = nil
        state.lastPairsUsed = nil
        state.lastStepCount = 0
        state.lastError = nil
        try context.save()
    }
}
