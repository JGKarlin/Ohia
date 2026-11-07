import Foundation

/// Pure filter helpers for the Interpretation Overlay's tri-state rows.
///
/// Honors §14 graceful deconstruction:
/// - `.any` always passes.
/// - Assertive states (`.hasTasks`, `.noTasks`, `.assignedToMe`,
///   `.hasHard`, `.hasSoft`, `.none_`) require non-nil signal evidence.
///   When the signal is nil (no analyzer output), assertive filters
///   fail the record — we don't pretend an unset signal exists.
public enum TriStateFilters {

    /// Returns true if a record's tasks pass the given task-state filter.
    /// Pass `tasks == nil` to indicate the message has no analyzer output.
    public static func taskStatePasses(
        _ state: TaskFilterState,
        tasks: [any TaskAssigneeProvider]?
    ) -> Bool {
        switch state {
        case .any:
            return true
        case .hasTasks:
            guard let tasks, !tasks.isEmpty else { return false }
            return true
        case .noTasks:
            guard let tasks, tasks.isEmpty else { return false }
            return true
        case .assignedToMe:
            guard let tasks else { return false }
            return tasks.contains(where: { $0.taskAssignee == "user" })
        }
    }

    /// Returns true if a record's deadlines pass the given deadline-state filter.
    /// Pass `deadlines == nil` to indicate the message has no analyzer output.
    public static func deadlineStatePasses(
        _ state: DeadlineFilterState,
        deadlines: [any DeadlineTypeProvider]?
    ) -> Bool {
        switch state {
        case .any:
            return true
        case .hasHard:
            guard let deadlines else { return false }
            return deadlines.contains(where: { $0.deadlineType == "hard" })
        case .hasSoft:
            guard let deadlines else { return false }
            return deadlines.contains(where: { $0.deadlineType == "soft" })
        case .none_:
            guard let deadlines, deadlines.isEmpty else { return false }
            return true
        }
    }
}

/// Minimal protocol so OhiaCore-level pure logic can read assignee
/// without depending on OhiaML's TaskRequirement type.
public protocol TaskAssigneeProvider {
    var taskAssignee: String? { get }
}

/// Same idea for deadlines.
public protocol DeadlineTypeProvider {
    var deadlineType: String { get }
}
