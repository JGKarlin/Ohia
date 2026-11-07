// TranslationMemoryDreamer.swift
// The orchestration of the dreaming producer for translation memories. Invoked
// from the account-memory "dreaming" worker once per qualifying target language,
// it samples a representative slice of the user's real correspondence in that
// language (straight from the vector store, no body-file reads), shows it to the
// model alongside the existing dossier, and distills durable translation STYLE
// rules plus reinforce / weaken / delete maintenance of the stored preferences.
//
// Cross-language terminology PINS are NOT produced here — a monolingual corpus
// cannot evidence a source→target pairing. Those come from the write-back
// producer, which has both sides. Dreaming complements it: always-on, corpus-
// wide style learning and consolidation. All writes go through
// `TranslationDreamDistiller`/`TranslationStyleRuleWriter`, so style-rule
// curation and dedup hold across dreaming passes.

import Foundation
import SwiftData
import OhiaCore

/// Distills translation style rules and consolidates a dossier for one target
/// language on one account. Best-effort; returns the number of rows changed.
public protocol TranslationMemoryDreaming: Sendable {
    @MainActor @discardableResult
    func dream(
        accountID: UUID,
        targetLanguageCode: String,
        displayName: String,
        modelContext: ModelContext,
        now: Date
    ) async -> Int
}

public final class TranslationMemoryDreamer: TranslationMemoryDreaming, @unchecked Sendable {
    private let engine: any TrainingEngine
    private let vectorStore: VectorStore
    /// How many distinct target-language messages to sample as evidence.
    private let corpusSampleCount: Int
    /// Below this, the dossier has too little corpus to dream over — no-op.
    private let minimumCorpusSamples: Int
    /// Upper bound on messages walked (newest first) while hunting for
    /// target-language samples. Deep so a minority language is still found in
    /// a mostly-other-language mailbox; the sampler hydrates in small batches
    /// and exits as soon as enough samples are collected, so the common case
    /// stays cheap.
    private let scanLimit: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        vectorStore: VectorStore,
        corpusSampleCount: Int = 10,
        minimumCorpusSamples: Int = 3,
        scanLimit: Int = 2000,
        generationTaskPriority: TaskPriority = .background
    ) {
        self.engine = engine
        self.vectorStore = vectorStore
        self.corpusSampleCount = max(1, corpusSampleCount)
        self.minimumCorpusSamples = max(1, minimumCorpusSamples)
        self.scanLimit = max(corpusSampleCount, scanLimit)
        self.generationTaskPriority = generationTaskPriority
    }

    @MainActor
    @discardableResult
    public func dream(
        accountID: UUID,
        targetLanguageCode: String,
        displayName: String,
        modelContext: ModelContext,
        now: Date
    ) async -> Int {
        let target = EmailLanguageDetector.canonicalBaseCode(targetLanguageCode)

        // Sample the target-language corpus off-main: the vector-store reads
        // (synchronous SQLite) and per-chunk language detection must not stall
        // the main thread on a large mailbox. Only the bounded evidence-readout
        // fetches and the apply stay on the worker's @MainActor context.
        let samples = await sampleCorpus(accountID: accountID, target: target)
        guard Task.isCancelled == false else { return 0 }
        guard samples.count >= minimumCorpusSamples else { return 0 }

        let existing = fetchExistingVisible(accountID: accountID, target: target, modelContext: modelContext)

        let promptBatch = TranslationDreamDistiller.buildPromptBatch(
            displayName: displayName,
            existing: existing,
            samples: samples.map(\.snippet)
        )
        let prompt = promptBatch.prompt
        let references = buildReferences(
            from: Array(samples.prefix(promptBatch.sampleCount)),
            modelContext: modelContext
        )
        let maxTokens = TranslationDreamDistiller.maxTokens(
            existingCount: promptBatch.existing.count
        )
        let raw: String
        do {
            raw = try await runCancellableGeneration { [engine] cancellation in
                try PrefixCachedGeneration.generate(
                    engine: engine,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    cancellation: cancellation
                )
            }
        } catch {
            return 0
        }
        guard Task.isCancelled == false else { return 0 }

        let ops = MemoryDistiller.parseOperations(raw)
        guard ops.isEmpty == false else { return 0 }

        let dossier = AccountMemoryDimensionTarget(
            kindRaw: AccountMemoryDimension.translation,
            value: target,
            displayName: displayName
        )
        return (try? TranslationDreamDistiller.apply(
            ops: ops,
            existing: promptBatch.existing,
            accountID: accountID,
            target: dossier,
            evidence: references,
            modelContext: modelContext,
            now: now
        )) ?? 0
    }

    // MARK: - Corpus

    /// Samples recent target-language correspondence for the account from the
    /// vector store, one snippet per message. Runs the synchronous SQLite reads
    /// and per-chunk language detection off-main via the shared sampler.
    private func sampleCorpus(accountID: UUID, target: String) async -> [TranslationCorpusSample] {
        let vectorStore = self.vectorStore
        let corpusSampleCount = self.corpusSampleCount
        let scanLimit = self.scanLimit
        return await Task.detached(priority: generationTaskPriority) {
            TranslationCorpusSampler.sample(
                vectorStore: vectorStore,
                accountID: accountID,
                languageCode: target,
                count: corpusSampleCount,
                scanLimit: scanLimit
            )
        }.value
    }

    /// Builds evidence references for the sampled chunks, enriching each with its
    /// source message's subject / sender / timestamp from the @MainActor store.
    @MainActor
    private func buildReferences(from samples: [TranslationCorpusSample], modelContext: ModelContext) -> [AccountMemoryEvidenceReference] {
        samples.compactMap { sample in
            guard let messageID = UUID(uuidString: sample.messageId) else { return nil }
            let readout = messageReadout(for: messageID, modelContext: modelContext)
            return AccountMemoryEvidenceReference(
                messageID: messageID,
                subject: readout?.subject ?? "(translation evidence)",
                senderAddress: readout?.senderAddress ?? "",
                senderName: readout?.senderName,
                timestamp: readout?.timestamp
                    ?? sample.receivedAt.map { Date(timeIntervalSince1970: $0) }
                    ?? Date(timeIntervalSince1970: 0),
                fieldSourceRaw: "body",
                spanText: sample.snippet,
                summary: nil,
                confidence: 0.6
            )
        }
    }

    private struct Readout {
        let subject: String
        let senderAddress: String
        let senderName: String?
        let timestamp: Date
    }

    @MainActor
    private func messageReadout(for messageID: UUID, modelContext: ModelContext) -> Readout? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return nil }
        return Readout(
            subject: message.subject,
            senderAddress: message.fromAddress,
            senderName: message.fromName,
            timestamp: message.receivedAt ?? message.sentAt ?? message.ingestedAt
        )
    }

    // MARK: - Existing dossier

    /// Visible (non-curation-hidden) rows on the translation dossier for this
    /// language, ordered for stable 1-based indexing in the prompt and apply.
    @MainActor
    private func fetchExistingVisible(accountID: UUID, target: String, modelContext: ModelContext) -> [AccountMemory] {
        let rows = (try? modelContext.fetch(
            FetchDescriptor<AccountMemory>(
                predicate: #Predicate<AccountMemory> { $0.accountID == accountID }
            )
        )) ?? []
        return rows
            .filter { row in
                row.resolvedDimensionValue == target
                    && row.isHiddenByDefault == false
                    && TranslationStyleRuleWriter.isStyleRule(row)
            }
            .sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.createdAt < rhs.createdAt
            }
    }

    // MARK: - Generation

    private func runCancellableGeneration(
        operation: @escaping @Sendable (GenerationCancellation) throws -> String
    ) async throws -> String {
        let cancellation = GenerationCancellation()
        let priority = generationTaskPriority
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation(cancellation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }
}
