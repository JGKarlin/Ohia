import Foundation

/// Tri-state filter for messages with extracted task requirements.
public enum TaskFilterState: String, Codable, Sendable, Equatable, CaseIterable {
    case any
    case hasTasks
    case noTasks
    case assignedToMe
}

/// Tri-state filter for messages with extracted deadlines.
public enum DeadlineFilterState: String, Codable, Sendable, Equatable, CaseIterable {
    case any
    case hasHard
    case hasSoft
    case none_
}
