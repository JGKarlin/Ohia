import Foundation

/// Centralized catalog of all agent tools, with filtering, tier management,
/// and smart task-type selection.
public final class ToolRegistry: @unchecked Sendable {

    private var registrations: [String: ToolRegistration] = [:]

    public init() {}

    // MARK: - Registration

    public func register(_ registration: ToolRegistration) {
        registrations[registration.id] = registration
    }

    public func unregister(toolNamed name: String) {
        registrations.removeValue(forKey: name)
    }

    /// Registers the 4 built-in corpus tools at the `.corpus` tier.
    public func registerBuiltInCorpusTools() {
        register(ToolRegistration(tool: CorpusSearchTool(),       tier: .corpus))
        register(ToolRegistration(tool: AttachmentSearchTool(),   tier: .corpus))
        register(ToolRegistration(tool: CorrespondentLookupTool(),tier: .corpus))
        register(ToolRegistration(tool: ThreadHistoryTool(),      tier: .corpus))
    }

    // MARK: - Querying

    /// All enabled and ready registrations, sorted by tier priority
    /// (native < corpus < preconfigured < custom).
    public var availableTools: [ToolRegistration] {
        registrations.values
            .filter { $0.isEnabled && $0.isReady }
            .sorted { tierPriority($0.tier) < tierPriority($1.tier) }
    }

    /// Looks up a tool by name; returns `nil` if not found, disabled, or not ready.
    public func tool(named name: String) -> ToolRegistration? {
        guard let reg = registrations[name], reg.isEnabled, reg.isReady else { return nil }
        return reg
    }

    /// All tools in the given tier, regardless of enabled/ready state.
    public func tools(forTier tier: ToolTier) -> [ToolRegistration] {
        registrations.values.filter { $0.tier == tier }
    }

    /// Every registration, for Settings display.
    public var allRegistrations: [ToolRegistration] {
        Array(registrations.values)
    }

    // MARK: - State Mutation

    public func setEnabled(_ enabled: Bool, forToolNamed name: String) {
        guard var reg = registrations[name] else { return }
        reg.isEnabled = enabled
        registrations[name] = reg
    }

    public func setReady(_ ready: Bool, forToolNamed name: String) {
        guard var reg = registrations[name] else { return }
        reg.isReady = ready
        registrations[name] = reg
    }

    // MARK: - Smart Selection

    /// Returns the best set of tools for a given task type and query,
    /// always falling back to corpus_search when available.
    public func toolsForTask(type taskType: TaskUnitType, query: String) -> [any AgentTool] {
        var selectedNames: [String]

        switch taskType {
        case .search:
            selectedNames = ["corpus_search"]
        case .locateAttachment:
            selectedNames = ["attachment_search"]
        case .compare:
            selectedNames = ["corpus_search", "thread_history"]
        case .summarize:
            selectedNames = ["corpus_search", "thread_history"]
        case .compose:
            selectedNames = ["corpus_search", "correspondent_lookup"]
        }

        // Scheduling hint: include calendar-like tools if query mentions scheduling keywords.
        let schedulingKeywords = ["schedule", "meeting", "calendar", "appointment", "event"]
        if schedulingKeywords.contains(where: { query.lowercased().contains($0) }) {
            if !selectedNames.contains("calendar") {
                selectedNames.append("calendar")
            }
        }

        // Collect matched, enabled, ready tools.
        var tools: [any AgentTool] = selectedNames.compactMap { self.tool(named: $0)?.tool }

        // Always include corpus_search as a fallback if not already present.
        if !selectedNames.contains("corpus_search"),
           let fallback = self.tool(named: "corpus_search") {
            tools.append(fallback.tool)
        }

        return tools
    }

    // MARK: - Private Helpers

    private func tierPriority(_ tier: ToolTier) -> Int {
        switch tier {
        case .native:        return 0
        case .corpus:        return 1
        case .preconfigured: return 2
        case .custom:        return 3
        }
    }
}
