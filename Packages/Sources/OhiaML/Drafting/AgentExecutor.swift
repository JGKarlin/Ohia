import Foundation
import OhiaCore

public final class AgentExecutor: Sendable {
    private let tools: [AgentTool]
    private let toolRegistry: ToolRegistry?

    public init(tools: [AgentTool]) {
        self.tools = tools
        self.toolRegistry = nil
    }

    public init(toolRegistry: ToolRegistry) {
        self.tools = []
        self.toolRegistry = toolRegistry
    }

    /// Execute a single task unit. Compose tasks return immediately.
    /// Reports a gap if no findings are returned.
    public func execute(task: TaskUnit, toolContext: ToolContext) throws -> AgentResult {
        guard task.taskType != .compose else {
            return AgentResult(taskDescription: task.description, status: .completed)
        }

        let taskTools = toolRegistry?.toolsForTask(
            type: task.taskType,
            query: task.searchQuery
        ) ?? tools

        guard let tool = taskTools.first else {
            return AgentResult(
                taskDescription: task.description,
                status: .needsInput,
                gaps: [Gap(description: "No tools available", whatWasSearched: task.searchQuery, suggestedAction: "Configure agent tools")]
            )
        }

        let result = try tool.execute(query: task.searchQuery, context: toolContext)

        if result.findings.isEmpty && result.deliverables.isEmpty {
            return AgentResult(
                taskDescription: task.description,
                status: .needsInput,
                gaps: [Gap(description: "Could not find relevant information", whatWasSearched: task.searchQuery, suggestedAction: "You may need to provide this information manually")]
            )
        }

        let avgConfidence = result.findings.isEmpty ? 0.0 :
            result.findings.reduce(0.0) { $0 + $1.confidence } / Double(result.findings.count)
        let status: AgentResultStatus = avgConfidence < 0.3 ? .lowConfidence : .completed

        return AgentResult(
            taskDescription: task.description,
            status: status,
            findings: result.findings,
            deliverables: result.deliverables
        )
    }

    /// Execute all non-compose tasks.
    public func executeAll(tasks: [TaskUnit], toolContext: ToolContext) throws -> [AgentResult] {
        try tasks.filter { $0.taskType != .compose }.map { try execute(task: $0, toolContext: toolContext) }
    }

    /// Aggregate multiple results into combined findings, deliverables, gaps, and statuses.
    /// Deduplicates findings by sourceMessageId.
    public static func aggregate(_ results: [AgentResult]) -> (
        findings: [Finding], deliverables: [Deliverable], gaps: [Gap], taskStatuses: [TaskStatus]
    ) {
        var allFindings: [Finding] = []
        var allDeliverables: [Deliverable] = []
        var allGaps: [Gap] = []
        var statuses: [TaskStatus] = []

        for result in results {
            allFindings.append(contentsOf: result.findings)
            allDeliverables.append(contentsOf: result.deliverables)
            allGaps.append(contentsOf: result.gaps)
            statuses.append(TaskStatus(description: result.taskDescription, status: result.status))
        }

        var seenIds = Set<String>()
        allFindings = allFindings.filter { f in
            guard let id = f.sourceMessageId else { return true }
            return seenIds.insert(id).inserted
        }

        return (allFindings, allDeliverables, allGaps, statuses)
    }
}
