import Foundation
import OhiaCore

public enum EntityRefreshPolicy {
    public static let correspondentSupportDelta = 25
    public static let correspondentRoleShift = 0.2

    public static func shouldRefresh(
        kind: EntityKind,
        supportCountAtLastEmbed: Int,
        currentSupportCount: Int,
        roleDistributionAtLastEmbed: [String: Double]?,
        currentRoleDistribution: [String: Double]?
    ) -> Bool {
        switch kind {
        case .correspondent:
            if currentSupportCount - supportCountAtLastEmbed >= correspondentSupportDelta {
                return true
            }
            guard let roleDistributionAtLastEmbed, let currentRoleDistribution else {
                return false
            }
            return maxRoleShift(
                then: roleDistributionAtLastEmbed,
                now: currentRoleDistribution
            ) > correspondentRoleShift
        case .attachment:
            return false
        }
    }

    private static func maxRoleShift(then: [String: Double], now: [String: Double]) -> Double {
        var maxDelta = 0.0
        for role in Set(then.keys).union(now.keys) {
            maxDelta = max(maxDelta, abs((now[role] ?? 0) - (then[role] ?? 0)))
        }
        return maxDelta
    }
}
