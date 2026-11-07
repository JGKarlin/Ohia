import Foundation
import simd
import OhiaCore

enum PeopleAccountColorResolver {
    struct AccountSegment: Equatable, Sendable {
        let colorIndex: Int
        let count: Int
        let latestDate: Date?
    }

    nonisolated static func dominantColorRGB(
        messageIds: Set<String>,
        messageIndex: [String: MessageFilterRow],
        accountColorIndexByAccountId: [UUID: Int]
    ) -> SIMD3<Float>? {
        guard let segment = distribution(
            messageIds: messageIds,
            messageIndex: messageIndex,
            accountColorIndexByAccountId: accountColorIndexByAccountId
        )
        .max(by: { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            let lhsDate = lhs.latestDate ?? Date.distantPast
            let rhsDate = rhs.latestDate ?? Date.distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.colorIndex > rhs.colorIndex
        }) else {
            return nil
        }

        let color = AccountColorPalette.color(forIndex: segment.colorIndex)
        let rgba = AccountColorPalette.rgb(for: color, brightness: 1.0)
        return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
    }

    nonisolated static func distribution(
        messageIds: Set<String>,
        messageIndex: [String: MessageFilterRow],
        accountColorIndexByAccountId: [UUID: Int]
    ) -> [AccountSegment] {
        guard !accountColorIndexByAccountId.isEmpty else { return [] }

        var countsByColorIndex: [Int: Int] = [:]
        var latestByColorIndex: [Int: Date] = [:]
        for messageId in messageIds {
            guard let row = messageIndex[messageId],
                  let accountId = row.accountId else {
                continue
            }
            let colorIndex = accountColorIndexByAccountId[accountId] ?? AccountColorPalette.defaultIndex
            countsByColorIndex[colorIndex, default: 0] += 1
            if let receivedAt = row.receivedAt,
               receivedAt > (latestByColorIndex[colorIndex] ?? Date.distantPast) {
                latestByColorIndex[colorIndex] = receivedAt
            }
        }

        return countsByColorIndex
            .map { colorIndex, count in
                AccountSegment(
                    colorIndex: colorIndex,
                    count: count,
                    latestDate: latestByColorIndex[colorIndex]
                )
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                let leftDate = $0.latestDate ?? Date.distantPast
                let rightDate = $1.latestDate ?? Date.distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return $0.colorIndex < $1.colorIndex
            }
    }
}
