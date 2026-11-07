import Foundation
import OhiaCore

public struct AutoreplyRule: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let correspondentEmail: String?
    public let messageType: MessageType?

    public init(correspondentEmail: String? = nil, messageType: MessageType? = nil) {
        self.id = UUID()
        self.correspondentEmail = correspondentEmail?.lowercased()
        self.messageType = messageType
    }

    public func matches(senderEmail: String, messageType: MessageType) -> Bool {
        if let ruleEmail = correspondentEmail, ruleEmail != senderEmail.lowercased() { return false }
        if let ruleType = self.messageType, ruleType != messageType { return false }
        return true
    }
}

public struct AutoreplyRuleStore: Codable, Sendable {
    public var rules: [AutoreplyRule]

    public init(rules: [AutoreplyRule] = []) { self.rules = rules }

    public mutating func addRule(_ rule: AutoreplyRule) { rules.append(rule) }

    public mutating func removeRule(_ rule: AutoreplyRule) { rules.removeAll { $0.id == rule.id } }

    public func shouldAutoreply(senderEmail: String, messageType: MessageType) -> Bool {
        rules.contains { $0.matches(senderEmail: senderEmail, messageType: messageType) }
    }
}
