import Foundation

public enum ToolTier: String, Codable, Sendable {
    case native
    case corpus
    case preconfigured
    case custom
}

public struct ToolRegistration: Sendable, Identifiable {
    public let id: String
    public let tool: any AgentTool
    public let tier: ToolTier
    public var isEnabled: Bool
    public let requiresAuth: Bool
    public var isReady: Bool

    public var name: String { tool.name }
    public var toolDescription: String { tool.toolDescription }

    public init(
        tool: any AgentTool,
        tier: ToolTier,
        isEnabled: Bool = true,
        requiresAuth: Bool = false,
        isReady: Bool = true
    ) {
        self.id = tool.name
        self.tool = tool
        self.tier = tier
        self.isEnabled = isEnabled
        self.requiresAuth = requiresAuth
        self.isReady = isReady
    }
}
