import OhiaCore

extension TaskRequirement: TaskAssigneeProvider {
    public var taskAssignee: String? { assignee }
}

extension DeadlineCandidate: DeadlineTypeProvider {
    public var deadlineType: String { type }
}
