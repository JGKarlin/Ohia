import Foundation
import OhiaCore

/// One action owns all of its model calls, including cancellation between calls.
public final class ComposerGenerationAction: Sendable {
    public let id: UUID
    public let deadline: Date
    public let cancellation: GenerationCancellation

    public init(id: UUID = UUID(), timeout: TimeInterval = 60,
                cancellation: GenerationCancellation = GenerationCancellation()) {
        self.id = id
        self.deadline = Date().addingTimeInterval(max(0, timeout))
        self.cancellation = cancellation
    }

    public func cancel() { cancellation.cancel() }

    public func check() throws {
        guard Date() < deadline else {
            cancellation.cancel()
            throw ComposerContentError.deadlineExceeded
        }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
    }

    public var remainingSeconds: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
}

public enum ComposerModelRole: String, Codable, Sendable, Equatable {
    /// `writerRetry` is the writer on the author's adapter again, sampled
    /// differently, so a retry does not repeat the draft it replaces.
    /// `baseWriter` is the writer task on base weights: the content
    /// pipeline's last draw only when every draw on the author's adapter
    /// broke down (copied their email, looped, stopped short).
    /// `repair` answers with replacements for the sentences the check named,
    /// a structured answer like the check's; the email stays the writer's.
    /// `answerCheck` reads only the sentences the repair wrote to carry the
    /// author's answers, for whether each says that answer and nothing more.
    /// `assentCheck` reads the draft's statements the check passed beside a
    /// request the author left open, for whether one answers it.
    /// `doneCheck` reads an earlier answer the author kept against the email
    /// being answered, for which of its requests that email shows done.
    /// `courtesyCheck` reads what a draft on base weights says as courtesy,
    /// for whether a sentence says something of the author's beside it.
    case preparer, writer, auditor, repair, baseWriter, writerRetry, answerCheck, assentCheck, doneCheck, courtesyCheck

    public var scope: GenerationPersonalizationScope {
        switch self {
        case .preparer, .auditor, .repair, .answerCheck, .assentCheck, .doneCheck, .courtesyCheck, .baseWriter: .base
        case .writer, .writerRetry: .personalized
        }
    }

    /// Roles that write the email body share the writer's sampling and its
    /// complete-sequence window.
    var writesEmail: Bool {
        switch self {
        case .writer, .baseWriter, .writerRetry: true
        case .preparer, .auditor, .repair, .answerCheck, .assentCheck, .doneCheck, .courtesyCheck: false
        }
    }
}

public struct ComposerModelOutput: Sendable {
    public let text: String
    public let completed: Bool
    public var personalization: GenerationPersonalization? = nil
    public var diagnostics: GenerationDiagnostics? = nil
}

/// One model call of a Composer role. The prompt carries its checkpoints:
/// the leading text other calls about the same lane or email share, which
/// the engine may resume from instead of reading again.
public typealias ComposerModelCall = @Sendable (
    _ prompt: PrefixCachedPrompt, _ role: ComposerModelRole, _ maximumTokens: Int
) async throws -> ComposerModelOutput
