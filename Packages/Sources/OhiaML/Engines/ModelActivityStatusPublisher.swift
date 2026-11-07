import Foundation
import OhiaCore

public final class ModelActivityStatusPublisher: @unchecked Sendable {
    public static let recentActivityVisibleDuration: TimeInterval = 3.0

    public struct Activity: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: WorkerGenerationActivityKind
        public let source: String?
        public let accountID: UUID?
        public let subject: String?
        public let startedAt: Date
    }

    public struct Snapshot: Sendable, Equatable {
        public let activities: [Activity]
        public let recentActivities: [Activity]
        public let capturedAt: Date

        public var isActive: Bool {
            !activities.isEmpty
        }

        public var visibleActivities: [Activity] {
            activities + recentActivities
        }

        public var hasVisibleActivity: Bool {
            !visibleActivities.isEmpty
        }
    }

    public struct Token: Sendable, Equatable {
        fileprivate let id: UUID
    }

    private struct RecentActivity: Sendable, Equatable {
        let activity: Activity
        let endedAt: Date
    }

    private let lock = NSLock()
    private var activities: [UUID: Activity] = [:]
    private var recentActivities: [UUID: RecentActivity] = [:]

    public init() {}

    public var snapshot: Snapshot {
        makeSnapshot(at: Date())
    }

    public func makeSnapshot(at date: Date = Date()) -> Snapshot {
        lock.lock()
        pruneRecentActivities(at: date)
        let active = Self.sortedActivities(Array(activities.values))
        let recent = Self.sortedRecentActivities(Array(recentActivities.values))
        lock.unlock()
        return Snapshot(activities: active, recentActivities: recent, capturedAt: date)
    }

    @discardableResult
    public func begin(
        _ kind: WorkerGenerationActivityKind,
        source: String? = nil,
        accountID: UUID? = nil,
        subject: String? = nil,
        at date: Date = Date()
    ) -> Token {
        let id = UUID()
        let activity = Activity(
            id: id,
            kind: kind,
            source: source,
            accountID: accountID,
            subject: subject,
            startedAt: date
        )
        lock.lock()
        pruneRecentActivities(at: date)
        activities[id] = activity
        lock.unlock()
        SessionActivityLog.shared.record(SessionActivityEvent(
            operation: kind.label.capitalized, phase: .started,
            subject: subject, accountID: accountID, operationID: id, timestamp: date
        ))
        return Token(id: id)
    }

    public func end(_ token: Token, at date: Date = Date(),
                    outcome: SessionActivityEvent.Phase = .ended, detail: String? = nil) {
        lock.lock()
        let ended = activities.removeValue(forKey: token.id)
        if let activity = ended {
            recentActivities[token.id] = RecentActivity(activity: activity, endedAt: date)
        }
        pruneRecentActivities(at: date)
        lock.unlock()
        if let activity = ended {
            SessionActivityLog.shared.record(SessionActivityEvent(
                operation: activity.kind.label.capitalized, phase: outcome,
                subject: activity.subject, accountID: activity.accountID,
                detail: detail, operationID: activity.id, timestamp: date
            ))
        }
    }

    public func reset() {
        lock.lock()
        let interrupted = Array(activities.values)
        activities.removeAll()
        recentActivities.removeAll()
        lock.unlock()
        for activity in interrupted {
            SessionActivityLog.shared.record(SessionActivityEvent(
                operation: activity.kind.label.capitalized, phase: .cancelled,
                subject: activity.subject, accountID: activity.accountID,
                operationID: activity.id
            ))
        }
    }

    private func pruneRecentActivities(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.recentActivityVisibleDuration)
        recentActivities = recentActivities.filter { _, recent in
            recent.endedAt >= cutoff
        }
    }

    private static func sortedActivities(_ activities: [Activity]) -> [Activity] {
        activities.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private static func sortedRecentActivities(_ activities: [RecentActivity]) -> [Activity] {
        activities.sorted { lhs, rhs in
            if lhs.endedAt == rhs.endedAt {
                if lhs.activity.startedAt == rhs.activity.startedAt {
                    return lhs.activity.id.uuidString < rhs.activity.id.uuidString
                }
                return lhs.activity.startedAt > rhs.activity.startedAt
            }
            return lhs.endedAt > rhs.endedAt
        }
        .map(\.activity)
    }
}
