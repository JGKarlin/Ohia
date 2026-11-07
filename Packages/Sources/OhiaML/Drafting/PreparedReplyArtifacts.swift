import Foundation
import SwiftData
import OhiaCore

public struct PreparedReplyDraftPayload: Codable, Sendable {
    public let output: DraftOutput
    public let generatedAt: Date
    public let sourceThreadCount: Int

    public init(
        output: DraftOutput,
        generatedAt: Date,
        sourceThreadCount: Int
    ) {
        self.output = output
        self.generatedAt = generatedAt
        self.sourceThreadCount = sourceThreadCount
    }
}

public protocol ReplyQuestionGrounding: Sendable {
    func ground(
        questions: [ComposerInterviewNode],
        contextPack: ComposerContextPack,
        framing: ComposerInterviewFraming,
        subject: String?,
        accountID: UUID?,
        languageIdentifier: String,
        cachedGroundings: [QuestionGrounding]
    ) async throws -> [QuestionGrounding]
}

public protocol ReplyInterviewPlanning: Sendable {
    @MainActor
    func plan(
        for message: Message,
        sourcesJSON: String,
        inputFingerprint: String,
        context: ModelContext
    ) async throws -> ComposerInterviewState
}

public protocol PreparedReplyGenerating: Sendable {
    @MainActor
    func generatePreparedReply(
        for message: Message,
        sourcesJSON: String,
        interviewState: ComposerInterviewState,
        context: ModelContext
    ) async throws -> PreparedReplyDraftPayload

    /// The prepared reply's writer fit for these sources and this interview,
    /// measured by the same compile the draft uses. Throws the transient
    /// `TrainingEngineError.modelNotLoaded` without a tokenizer, or the
    /// compile's own error when the request cannot be compiled.
    @MainActor
    func preparedReplyWriterWindowUsage(
        for message: Message,
        sourcesJSON: String,
        interviewState: ComposerInterviewState,
        context: ModelContext
    ) throws -> ComposerWriterWindowUsage
}
