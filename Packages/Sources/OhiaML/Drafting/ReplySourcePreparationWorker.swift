import Foundation
import SwiftData
import OhiaCore

public enum ReplySourcePreparationWorkOutcome: Sendable, Equatable {
    case published
    case obsolete
    case stale
    case yielded
}

public protocol ReplySourcePreparationReconciling: Sendable {
    @MainActor
    @discardableResult
    func reconcileChangedPreparationInputs(
        context: ModelContext
    ) throws -> Int
}

public enum ReplySourcePreparationWorkerError: Error, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid reply source preparation payload."
        }
    }
}

/// Runs one complete, resumable reply preparation without creating a Draft.
/// Persisted artifacts determine the next phase, so a process restart resumes
/// at formulation or drafting instead of repeating completed model work.
/// Every post-await publication uses a fresh SwiftData context and revalidates
/// eligibility, fingerprint, phase, and Draft ownership before writing.
public final class ReplySourcePreparationWorker: @unchecked Sendable {
    private enum Phase: Equatable {
        case compilingSources
        case formulatingQuestions
        case drafting
        case ready

        var statusRaw: String {
            switch self {
            case .compilingSources:
                ReplySourcePreparationStatus.compilingSources
            case .formulatingQuestions:
                ReplySourcePreparationStatus.formulatingQuestions
            case .drafting:
                ReplySourcePreparationStatus.drafting
            case .ready:
                ReplySourcePreparationStatus.ready
            }
        }
    }

    @MainActor
    private enum AuthoritativeCheck {
        case valid(ModelContext, Message, ReplySourcePreparation)
        case terminal(ReplySourcePreparationWorkOutcome)
    }

    private let compiler: any ReplySourceCompiling
    private let interviewPlanner: any ReplyInterviewPlanning
    private let draftGenerator: any PreparedReplyGenerating
    private let reconciler: any ReplySourcePreparationReconciling
    private let shouldYield: @MainActor @Sendable () -> Bool

    /// `shouldYield` is read before each model phase (the compiler reads it
    /// within source compilation); each phase's output is saved, so a yielded
    /// preparation resumes at the phase it stopped before.
    public init(
        compiler: any ReplySourceCompiling,
        interviewPlanner: any ReplyInterviewPlanning,
        draftGenerator: any PreparedReplyGenerating,
        reconciler: any ReplySourcePreparationReconciling,
        shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.compiler = compiler
        self.interviewPlanner = interviewPlanner
        self.draftGenerator = draftGenerator
        self.reconciler = reconciler
        self.shouldYield = shouldYield
    }

    @MainActor
    public func run(
        job: Job,
        context: ModelContext
    ) async throws -> ReplySourcePreparationWorkOutcome {
        guard job.type == .prepareReplySources,
              let payload = ReplySourcePreparationJobPayload.decode(job.payload),
              job.messageId == payload.messageID else {
            throw ReplySourcePreparationWorkerError.invalidPayload
        }

        let container = context.container
        let initial = try authoritativeCheck(
            payload: payload,
            expectedPreparationID: nil,
            expectedPhase: nil,
            container: container
        )
        guard case let .valid(initialContext, _, initialPreparation) = initial else {
            if case let .terminal(outcome) = initial { return outcome }
            return .stale
        }
        try removeDuplicatePreparations(
            keeping: initialPreparation,
            messageID: payload.messageID,
            context: initialContext
        )
        let preparationID = initialPreparation.id

        while true {
            let check = try authoritativeCheck(
                payload: payload,
                expectedPreparationID: preparationID,
                expectedPhase: nil,
                container: container
            )
            guard case let .valid(phaseContext, message, preparation) = check else {
                if case let .terminal(outcome) = check { return outcome }
                return .stale
            }

            let phase = try Self.phase(for: preparation)
            if phase == .ready {
                publishReady(preparation: preparation, message: message)
                try phaseContext.save()
                return .published
            }

            preparation.statusRaw = phase.statusRaw
            preparation.updatedAt = .now
            try phaseContext.save()
            if phase != .compilingSources, shouldYield() {
                return try handleYield(
                    payload: payload,
                    preparationID: preparationID,
                    expectedPhase: phase,
                    container: container
                )
            }

            switch phase {
            case .compilingSources:
                let snapshot: ReplySourceCompilationSnapshot
                do {
                    snapshot = try await compiler.compile(
                        for: message,
                        context: phaseContext,
                        preservingUserAddedSources: []
                    )
                } catch ReplySourceCompilationControl.yielded {
                    return try handleYield(
                        payload: payload,
                        preparationID: preparationID,
                        expectedPhase: phase,
                        container: container
                    )
                }
                guard !Task.isCancelled else { return .stale }
                let publishCheck = try authoritativeCheck(
                    payload: payload,
                    expectedPreparationID: preparationID,
                    expectedPhase: phase,
                    container: container
                )
                guard case let .valid(publishContext, _, authoritative) = publishCheck else {
                    if case let .terminal(outcome) = publishCheck { return outcome }
                    return .stale
                }
                authoritative.sourcesJSON = snapshot.sourcesJSON
                authoritative.sourceThreadCoverageJSON = snapshot.threadCoverageJSON
                authoritative.sourceThreadCount = snapshot.sourceThreadCount
                authoritative.statusRaw = ReplySourcePreparationStatus.formulatingQuestions
                authoritative.updatedAt = .now
                try publishContext.save()

            case .formulatingQuestions:
                guard let sourcesJSON = preparation.sourcesJSON else {
                    return .stale
                }
                let state = try await interviewPlanner.plan(
                    for: message,
                    sourcesJSON: sourcesJSON,
                    inputFingerprint: preparation.inputFingerprint,
                    context: phaseContext
                )
                guard !Task.isCancelled else { return .stale }
                let publishCheck = try authoritativeCheck(
                    payload: payload,
                    expectedPreparationID: preparationID,
                    expectedPhase: phase,
                    container: container
                )
                guard case let .valid(publishContext, currentMessage, authoritative) = publishCheck else {
                    if case let .terminal(outcome) = publishCheck { return outcome }
                    return .stale
                }
                authoritative.interviewStateJSON = ComposerInterviewStateCoding.encode(state)
                // The writer's inputs are known once questions are planned:
                // findings and settled questions change what the fit keeps.
                // A failed measurement never blocks the preparation.
                do {
                    let usage = try draftGenerator.preparedReplyWriterWindowUsage(
                        for: currentMessage,
                        sourcesJSON: sourcesJSON,
                        interviewState: state,
                        context: publishContext
                    )
                    authoritative.sourceContextTokenCount = usage.promptTokens
                    authoritative.sourceContextTokenLimit = usage.promptBudget
                    authoritative.sourceContextFitJSON = usage.json
                } catch {
                    // A missing tokenizer leaves no limit, so the Draft that
                    // adopts this preparation is measured again; a request
                    // that cannot compile keeps the budget with no count.
                    var deferred = false
                    if case .modelNotLoaded? = error as? TrainingEngineError { deferred = true }
                    authoritative.sourceContextTokenCount = nil
                    authoritative.sourceContextTokenLimit = deferred ? nil : ComposerWriterWindow.promptBudget
                    authoritative.sourceContextFitJSON = nil
                    print("[Ohia] Prepared reply writer-window measurement unavailable: \(String(reflecting: type(of: error)))")
                }
                let projection = ComposerInterviewExecutor.project(state)
                authoritative.questionCount = projection.currentNode == nil ? 0 : 1
                authoritative.updatedAt = .now
                if projection.currentNode == nil {
                    authoritative.statusRaw = ReplySourcePreparationStatus.drafting
                } else {
                    publishReady(
                        preparation: authoritative,
                        message: currentMessage
                    )
                }
                try publishContext.save()
                if projection.currentNode != nil { return .published }

            case .drafting:
                guard let sourcesJSON = preparation.sourcesJSON,
                      let interviewState = ComposerInterviewStateCoding.decode(
                          preparation.interviewStateJSON
                      ) else {
                    return .stale
                }
                let generated = try await draftGenerator.generatePreparedReply(
                    for: message,
                    sourcesJSON: sourcesJSON,
                    interviewState: interviewState,
                    context: phaseContext
                )
                guard !Task.isCancelled else { return .stale }
                let publishCheck = try authoritativeCheck(
                    payload: payload,
                    expectedPreparationID: preparationID,
                    expectedPhase: phase,
                    container: container
                )
                guard case let .valid(publishContext, currentMessage, authoritative) = publishCheck else {
                    if case let .terminal(outcome) = publishCheck { return outcome }
                    return .stale
                }
                authoritative.generatedDraftJSON = try encodeJSON(generated)
                publishReady(preparation: authoritative, message: currentMessage)
                try publishContext.save()
                return .published

            case .ready:
                return .published
            }
        }
    }

    private static func phase(for preparation: ReplySourcePreparation) throws -> Phase {
        guard (-1...1).contains(preparation.questionCount) else {
            throw ReplySourcePreparationWorkerError.invalidPayload
        }
        if preparation.sourcesJSON == nil {
            return .compilingSources
        }
        if preparation.questionCount == -1 || preparation.interviewStateJSON == nil {
            return .formulatingQuestions
        }
        if preparation.questionCount == 0,
           preparation.generatedDraftJSON == nil {
            return .drafting
        }
        return .ready
    }

    @MainActor
    private func authoritativeCheck(
        payload: ReplySourcePreparationJobPayload,
        expectedPreparationID: UUID?,
        expectedPhase: Phase?,
        container: ModelContainer
    ) throws -> AuthoritativeCheck {
        let context = ModelContext(container)
        guard let message = try fetchMessage(payload.messageID, context: context) else {
            try deletePreparations(messageID: payload.messageID, context: context)
            return .terminal(.obsolete)
        }
        if try fetchDraft(messageID: payload.messageID, context: context) != nil {
            try deletePreparations(messageID: payload.messageID, context: context)
            return .terminal(.obsolete)
        }

        let snapshot: ReplyPreparationInputSnapshot
        switch ReplyPreparationInputReadiness.evaluate(
            message: message,
            context: context
        ) {
        case .ineligible:
            try deletePreparations(messageID: payload.messageID, context: context)
            return .terminal(.obsolete)
        case .waiting:
            _ = try reconciler.reconcileChangedPreparationInputs(context: context)
            return .terminal(.stale)
        case let .ready(readySnapshot):
            snapshot = readySnapshot
        }
        guard !Task.isCancelled else {
            return .terminal(.stale)
        }

        guard payload.contractVersion == ReplySourcePreparationFingerprint.contractVersion,
              payload.fingerprint == snapshot.fingerprint,
              let preparation = try matchingPreparation(
                  payload: payload,
                  expectedID: expectedPreparationID,
                  context: context
              ),
              preparation.inputFingerprint == snapshot.fingerprint,
              preparation.contractVersion == payload.contractVersion,
              let witnessedMessageIDs = decodedWitnessedLiveThreadMessageIDs(
                  in: preparation
              ),
              witnessedMessageIDs == snapshot.witnessedLiveThreadMessageIDs else {
            _ = try reconciler.reconcileChangedPreparationInputs(context: context)
            return .terminal(.stale)
        }
        if let expectedPhase,
           (try Self.phase(for: preparation)) != expectedPhase
            || preparation.statusRaw != expectedPhase.statusRaw {
            return .terminal(.stale)
        }
        return .valid(context, message, preparation)
    }

    @MainActor
    private func handleYield(
        payload: ReplySourcePreparationJobPayload,
        preparationID: UUID,
        expectedPhase: Phase,
        container: ModelContainer
    ) throws -> ReplySourcePreparationWorkOutcome {
        let check = try authoritativeCheck(
            payload: payload,
            expectedPreparationID: preparationID,
            expectedPhase: expectedPhase,
            container: container
        )
        guard case let .valid(context, _, preparation) = check else {
            if case let .terminal(outcome) = check { return outcome }
            return .stale
        }
        preparation.statusRaw = ReplySourcePreparationStatus.pending
        preparation.updatedAt = .now
        try context.save()
        return .yielded
    }

    @MainActor
    private func publishReady(
        preparation: ReplySourcePreparation,
        message: Message
    ) {
        let readyAt = Date()
        preparation.statusRaw = ReplySourcePreparationStatus.ready
        preparation.preparedAt = readyAt
        preparation.updatedAt = readyAt
        preparation.failureCount = 0
        preparation.lastError = nil
        preparation.nextAttemptAt = nil
        message.replyPreparationReadyAt = readyAt
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @MainActor
    private func fetchMessage(
        _ messageID: UUID,
        context: ModelContext
    ) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private func fetchDraft(
        messageID: UUID,
        context: ModelContext
    ) throws -> Draft? {
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private func matchingPreparation(
        payload: ReplySourcePreparationJobPayload,
        expectedID: UUID? = nil,
        context: ModelContext
    ) throws -> ReplySourcePreparation? {
        try preparations(messageID: payload.messageID, context: context)
            .filter {
                $0.inputFingerprint == payload.fingerprint
                    && $0.contractVersion == payload.contractVersion
                    && (expectedID == nil || $0.id == expectedID)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }

    private func decodedWitnessedLiveThreadMessageIDs(
        in preparation: ReplySourcePreparation
    ) -> Set<UUID>? {
        guard let encoded = preparation.witnessedLiveThreadMessageIDsJSON,
              let data = encoded.data(using: .utf8),
              let messageIDs = try? JSONDecoder().decode([UUID].self, from: data) else {
            return nil
        }
        return Set(messageIDs)
    }

    @MainActor
    private func preparations(
        messageID: UUID,
        context: ModelContext
    ) throws -> [ReplySourcePreparation] {
        try context.fetch(
            FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> {
                    $0.messageId == messageID
                }
            )
        )
    }

    @MainActor
    private func removeDuplicatePreparations(
        keeping preparation: ReplySourcePreparation,
        messageID: UUID,
        context: ModelContext
    ) throws {
        var changed = false
        for duplicate in try preparations(
            messageID: messageID,
            context: context
        ) where duplicate.id != preparation.id {
            deletePreparation(duplicate, context: context)
            changed = true
        }
        if preparation.message?.replySourcePreparation?.id != preparation.id {
            preparation.message?.replySourcePreparation = nil
            preparation.message?.replySourcePreparation = preparation
            changed = true
        }
        if changed { try context.save() }
    }

    @MainActor
    private func deletePreparations(
        messageID: UUID,
        context: ModelContext
    ) throws {
        // A late worker must not erase the completed baseline already adopted
        // by Composer. Discard still prevents any unfinished publication.
        let message = try fetchMessage(messageID, context: context)
        let preserveReady = message.map {
            ReplySourcePreparationEligibility.canRetainCompletedPreparation($0, context: context)
        } ?? false
        let rows = try preparations(messageID: messageID, context: context).filter {
            !preserveReady || $0.statusRaw != ReplySourcePreparationStatus.ready
        }
        guard !rows.isEmpty else { return }
        for preparation in rows {
            deletePreparation(preparation, context: context)
        }
        try context.save()
    }

    @MainActor
    private func deletePreparation(
        _ preparation: ReplySourcePreparation,
        context: ModelContext
    ) {
        if preparation.message?.replySourcePreparation?.id == preparation.id {
            preparation.message?.replySourcePreparation = nil
        }
        preparation.message = nil
        context.delete(preparation)
    }
}
