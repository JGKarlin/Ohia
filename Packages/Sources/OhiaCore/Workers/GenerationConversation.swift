import Foundation

public enum GenerationConversationRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public enum GenerationReasoningEffort: String, Codable, Equatable, Sendable {
    case low
    case medium
    case xhigh
}

public struct GenerationConversationMessage: Codable, Equatable, Sendable {
    public let role: GenerationConversationRole
    public let content: String
    /// Hidden model reasoning from this assistant turn. It is never rendered
    /// to the user and is replayed only by a model that supports preservation.
    public let reasoningContent: String?
    /// Exact runtime state that produced `reasoningContent` (model plus
    /// personalization state). The receiving engine drops stale reasoning.
    public let continuationFingerprint: String?

    public init(
        role: GenerationConversationRole,
        content: String,
        reasoningContent: String? = nil,
        continuationFingerprint: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.continuationFingerprint = continuationFingerprint
    }
}

public struct GenerationConversation: Codable, Equatable, Sendable {
    public let messages: [GenerationConversationMessage]
    public let reasoningEffort: GenerationReasoningEffort
    public let preserveThinking: Bool

    public init(
        messages: [GenerationConversationMessage],
        reasoningEffort: GenerationReasoningEffort = .low,
        preserveThinking: Bool = true
    ) {
        self.messages = messages
        self.reasoningEffort = reasoningEffort
        self.preserveThinking = preserveThinking
    }

    /// Model-neutral fallback. Composer's latest user turn is already a
    /// complete grounded prompt containing the visible draft and durable
    /// instruction history, so replaying just that turn avoids duplicating
    /// old bodies for engines without structured conversation support.
    public var fallbackPrompt: String {
        messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""
    }

    public func keepingReasoning(matching fingerprint: String) -> GenerationConversation {
        GenerationConversation(
            messages: messages.map { message in
                guard message.role == .assistant,
                      message.continuationFingerprint == fingerprint else {
                    return GenerationConversationMessage(
                        role: message.role,
                        content: message.content
                    )
                }
                return message
            },
            reasoningEffort: reasoningEffort,
            preserveThinking: preserveThinking
        )
    }
}

public enum GenerationStopReason: String, Codable, Equatable, Sendable {
    case stopMarker
    case endOfSequence
    case maxTokens
}

/// What one model call cost. `promptTokenCount` counts the whole framed
/// prompt, including tokens whose KV state came from a saved cache.
/// `promptSeconds` is all prefill wall time for the call: building a cache
/// checkpoint, chunked prefill, and the generation iterator's own prompt step.
/// `decodeSeconds` is token generation time.
public struct GenerationDiagnostics: Codable, Equatable, Sendable {
    public let promptTokenCount: Int
    public let generatedTokenCount: Int
    public let promptSeconds: Double
    public let decodeSeconds: Double
    /// Prompt tokens whose KV state was restored from a saved cache instead of
    /// being prefilled. Nil when the engine cannot say (and for diagnostics
    /// persisted before this field existed).
    public let reusedPromptTokenCount: Int?

    public init(
        promptTokenCount: Int,
        generatedTokenCount: Int,
        promptSeconds: Double,
        decodeSeconds: Double,
        reusedPromptTokenCount: Int? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.generatedTokenCount = generatedTokenCount
        self.promptSeconds = promptSeconds
        self.decodeSeconds = decodeSeconds
        self.reusedPromptTokenCount = reusedPromptTokenCount
    }

    /// `p2510/r1800 pf3.1 dc8.9 g310`: prompt tokens, reused tokens, prefill
    /// seconds, decode seconds, generated tokens. A nil part is omitted.
    /// Numbers only, so it is safe to log publicly.
    public static func timingSummary(
        promptTokens: Int?, reusedTokens: Int?, prefillSeconds: Double?,
        decodeSeconds: Double?, generatedTokens: Int?
    ) -> String {
        var head = ""
        if let promptTokens { head += "p\(promptTokens)" }
        if let reusedTokens { head += (head.isEmpty ? "" : "/") + "r\(reusedTokens)" }
        var parts = head.isEmpty ? [] : [head]
        if let prefillSeconds { parts.append("pf" + String(format: "%.1f", prefillSeconds)) }
        if let decodeSeconds { parts.append("dc" + String(format: "%.1f", decodeSeconds)) }
        if let generatedTokens { parts.append("g\(generatedTokens)") }
        return parts.joined(separator: " ")
    }

    public var timingSummary: String {
        Self.timingSummary(promptTokens: promptTokenCount, reusedTokens: reusedPromptTokenCount,
            prefillSeconds: promptSeconds, decodeSeconds: decodeSeconds, generatedTokens: generatedTokenCount)
    }
}

/// Captured under the model's generation lock, so later training or adapter
/// reloads cannot change the provenance of an already generated draft.
public struct GenerationPersonalization: Codable, Equatable, Sendable {
    public let modelID: String
    public let adapterActive: Bool
    public let adapterRevision: String?

    public init(modelID: String, adapterActive: Bool, adapterRevision: String?) {
        self.modelID = modelID
        self.adapterActive = adapterActive
        self.adapterRevision = adapterActive ? adapterRevision : nil
    }
}

public struct GenerationResult: Codable, Equatable, Sendable {
    public let text: String
    public let reasoningContent: String?
    public let continuationFingerprint: String?
    public let stopReason: GenerationStopReason?
    public let diagnostics: GenerationDiagnostics?
    public var personalization: GenerationPersonalization?

    public init(
        text: String,
        reasoningContent: String? = nil,
        continuationFingerprint: String? = nil,
        stopReason: GenerationStopReason? = nil,
        diagnostics: GenerationDiagnostics? = nil,
        personalization: GenerationPersonalization? = nil
    ) {
        self.text = text
        self.reasoningContent = reasoningContent
        self.continuationFingerprint = continuationFingerprint
        self.stopReason = stopReason
        self.diagnostics = diagnostics
        self.personalization = personalization
    }
}
