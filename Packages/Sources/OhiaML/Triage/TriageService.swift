import Foundation
import OhiaCore

/// User-facing triage helpers. Automatic MessageType production is owned by
/// Qwen interpretation through `MessageSummaryWriter`.
public final class TriageService: @unchecked Sendable {
    public var autoreplyRules: AutoreplyRuleStore

    public init(
        autoreplyRules: AutoreplyRuleStore = AutoreplyRuleStore()
    ) {
        self.autoreplyRules = autoreplyRules
    }

    // MARK: - Promote / Demote (User Override)

    /// Sets the message type to `newType` as a user override, returning a
    /// `MessageClassification` with `isUserOverride: true`.
    @discardableResult
    public func promote(message: Message, to newType: MessageType) -> MessageClassification {
        let effectiveType: MessageType = message.isSentByUser && newType == .actionable
            ? .report
            : newType
        message.messageType = effectiveType
        message.classifiedAt = Date()
        return MessageClassification(
            type: effectiveType,
            confidence: 1.0,
            alternatives: [],
            draftEligible: effectiveType == .actionable,
            isUserOverride: true
        )
    }

    // MARK: - Autoreply Eligibility

    /// Returns `true` if the message is actionable and at least one autoreply rule matches.
    public func shouldAutoreply(senderEmail: String, messageType: MessageType) -> Bool {
        guard messageType == .actionable else { return false }
        return autoreplyRules.shouldAutoreply(senderEmail: senderEmail, messageType: messageType)
    }
}
