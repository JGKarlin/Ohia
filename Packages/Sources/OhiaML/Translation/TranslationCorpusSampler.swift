// TranslationCorpusSampler.swift
// Shared corpus sampling for the translation dreaming producers. Pulls recent
// chunks for one account straight from the vector store (no body-file reads),
// keeps one snippet per message, and language-filters per chunk so the caller
// sees only text actually written in the requested language. Pure synchronous
// SQLite reads — callers run it off-main.
//
// The scan is deep on purpose: a minority declared language (say 5% Japanese
// in a mostly-English mailbox) rarely appears in the newest few dozen
// messages, so the sampler walks newest-first through up to `scanLimit`
// messages, hydrating in small batches and stopping as soon as `count`
// qualifying samples are found. Majority-language passes exit after a batch
// or two; minority-language passes pay a bounded deeper walk instead of
// silently returning nothing.

import Foundation
import OhiaCore

/// One sampled chunk of real correspondence in a specific language. Sendable so
/// it crosses back from the off-main sampler to @MainActor callers.
struct TranslationCorpusSample: Sendable {
    let messageId: String
    let snippet: String
    let receivedAt: TimeInterval?
}

enum TranslationCorpusSampler {
    static let snippetCharacterLimit = 240
    /// Messages hydrated per batch while walking newest-first.
    static let hydrationBatchSize = 64

    /// Samples correspondence for `accountID` written in `languageCode`
    /// (canonical base code), newest first, one snippet per message, capped at
    /// `count`. Walks at most `scanLimit` messages so the pass stays bounded
    /// on a background lane.
    static func sample(
        vectorStore: VectorStore,
        accountID: UUID,
        languageCode: String,
        count: Int,
        scanLimit: Int,
        snippetCharacterLimit: Int = TranslationCorpusSampler.snippetCharacterLimit
    ) -> [TranslationCorpusSample] {
        guard count > 0, scanLimit > 0 else { return [] }
        let filter = FilterSpec(accountIds: [accountID], collections: [.context])
        guard let messageIds = try? vectorStore.enumerateMessageIds(
            filter: filter, orderBy: .receivedDesc, limit: scanLimit
        ), messageIds.isEmpty == false else { return [] }

        var samples: [TranslationCorpusSample] = []
        var seenMessages = Set<String>()
        var cursor = 0
        while cursor < messageIds.count, samples.count < count {
            let batch = Array(messageIds[cursor..<min(cursor + hydrationBatchSize, messageIds.count)])
            cursor += batch.count
            guard let vectorIds = try? vectorStore.vectorIds(
                forMessageIds: batch, filter: filter, limit: batch.count * 4
            ), vectorIds.isEmpty == false else { continue }
            guard let records = try? vectorStore.hydrate(vectorIds: vectorIds) else { continue }

            for record in records {
                if samples.count >= count { break }
                let messageIdString = record.messageId
                guard seenMessages.contains(messageIdString) == false else { continue }
                let payload = record.textPayload.trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload.isEmpty == false else { continue }
                guard let detected = EmailLanguageDetector.detectDominantLanguageCode(in: payload),
                      EmailLanguageDetector.canonicalBaseCode(detected) == languageCode else { continue }
                seenMessages.insert(messageIdString)
                samples.append(TranslationCorpusSample(
                    messageId: messageIdString,
                    snippet: String(payload.prefix(snippetCharacterLimit)),
                    receivedAt: record.messageReceivedAt
                ))
            }
        }
        return samples
    }
}
