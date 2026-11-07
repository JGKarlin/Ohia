import Foundation
import SwiftData
import OhiaCore

// MARK: - LifecycleResult

public struct LifecycleResult: Sendable {
    public let promoted: Int
    public let deprecated: Int
    public let merged: Int

    public init(promoted: Int, deprecated: Int, merged: Int) {
        self.promoted = promoted
        self.deprecated = deprecated
        self.merged = merged
    }
}

// MARK: - CategoryLifecycleEngine

/// Manages the emergent category lifecycle: promoting candidates to active,
/// deprecating stale categories, merging convergent ones, and updating global weights.
public final class CategoryLifecycleEngine: @unchecked Sendable {
    public let promotionThreshold: Int
    public let promotionMinAgeDays: Int
    public let promotionMinConfidence: Double
    public let deprecationStaleDays: Int
    public let mergeOverlapThreshold: Double

    public init(
        promotionThreshold: Int = 10,
        promotionMinAgeDays: Int = 7,
        promotionMinConfidence: Double = 0.5,
        deprecationStaleDays: Int = 90,
        mergeOverlapThreshold: Double = 0.5
    ) {
        self.promotionThreshold = promotionThreshold
        self.promotionMinAgeDays = promotionMinAgeDays
        self.promotionMinConfidence = promotionMinConfidence
        self.deprecationStaleDays = deprecationStaleDays
        self.mergeOverlapThreshold = mergeOverlapThreshold
    }

    // MARK: - Run Lifecycle

    /// Processes all CategoryDefinition records and applies lifecycle rules.
    ///
    /// 1. Promote qualifying candidates to active
    /// 2. Deprecate stale active categories
    /// 3. Merge convergent active categories in the same dimension
    /// 4. Update globalWeight on all active categories
    @MainActor
    public func runLifecycle(context: ModelContext) throws -> LifecycleResult {
        let allCategories = try context.fetch(FetchDescriptor<CategoryDefinition>())
        let totalMessages = try context.fetchCount(FetchDescriptor<Message>())

        var promotedCount = 0
        var deprecatedCount = 0
        var mergedCount = 0

        // 1. Promote candidates that meet all criteria
        let candidates = allCategories.filter { $0.status == .candidate }
        for category in candidates {
            if shouldPromote(category) {
                category.status = .active
                category.lastUpdatedAt = Date()
                promotedCount += 1
            }
        }

        // 2. Deprecate stale active categories
        let active = allCategories.filter { $0.status == .active }
        for category in active {
            if shouldDeprecate(category) {
                category.status = .deprecated
                category.lastUpdatedAt = Date()
                deprecatedCount += 1
            }
        }

        // 3. Merge convergent active categories within the same dimension
        let stillActive = allCategories.filter { $0.status == .active }
        let byDimension = Dictionary(grouping: stillActive) { $0.dimension }
        for (_, group) in byDimension {
            mergedCount += mergeConvergentCategories(group, context: context)
        }

        // 4. Update globalWeight on all active categories
        let finalActive = allCategories.filter { $0.status == .active }
        for category in finalActive {
            if totalMessages > 0 {
                category.globalWeight = Double(category.assignments.count) / Double(totalMessages)
            } else {
                category.globalWeight = 0.0
            }
        }

        try context.save()
        return LifecycleResult(promoted: promotedCount, deprecated: deprecatedCount, merged: mergedCount)
    }

    // MARK: - Promotion

    private func shouldPromote(_ category: CategoryDefinition) -> Bool {
        let assignmentCount = category.assignments.count
        guard assignmentCount >= promotionThreshold else { return false }

        let calendar = Calendar.current
        let minCreationDate = calendar.date(byAdding: .day, value: -promotionMinAgeDays, to: Date())!
        guard category.createdAt <= minCreationDate else { return false }

        let confidences = category.assignments.map(\.confidence)
        guard !confidences.isEmpty else { return false }
        let averageConfidence = confidences.reduce(0.0, +) / Double(confidences.count)
        guard averageConfidence > promotionMinConfidence else { return false }

        return true
    }

    // MARK: - Deprecation

    private func shouldDeprecate(_ category: CategoryDefinition) -> Bool {
        let calendar = Calendar.current
        let staleDate = calendar.date(byAdding: .day, value: -deprecationStaleDays, to: Date())!

        // Deprecate if no recent updates and no assignments (or very old)
        if category.lastUpdatedAt <= staleDate && category.assignments.isEmpty {
            return true
        }

        // Also check: if it has assignments but the most recent one is stale
        if !category.assignments.isEmpty {
            let latestAssignmentDate = mostRecentAssignmentDate(category)
            if let latest = latestAssignmentDate, latest <= staleDate {
                return true
            }
        }

        // Deprecate if last update is stale and no assignments remain
        if category.lastUpdatedAt <= staleDate {
            return true
        }

        return false
    }

    /// Approximate the most recent assignment date using the message's ingestedAt.
    private func mostRecentAssignmentDate(_ category: CategoryDefinition) -> Date? {
        category.assignments.compactMap { $0.message?.ingestedAt }.max()
    }

    // MARK: - Merge

    /// Checks all pairs within a dimension group and merges convergent categories.
    /// Returns the number of merges performed.
    private func mergeConvergentCategories(
        _ group: [CategoryDefinition],
        context: ModelContext
    ) -> Int {
        var mergedCount = 0
        var deprecatedIDs = Set<UUID>()

        for i in 0..<group.count {
            let a = group[i]
            guard !deprecatedIDs.contains(a.id) else { continue }

            for j in (i + 1)..<group.count {
                let b = group[j]
                guard !deprecatedIDs.contains(b.id) else { continue }

                if shouldMerge(a, b) {
                    let (keeper, loser) = a.assignments.count >= b.assignments.count ? (a, b) : (b, a)
                    performMerge(keeper: keeper, loser: loser, context: context)
                    deprecatedIDs.insert(loser.id)
                    mergedCount += 1
                }
            }
        }

        return mergedCount
    }

    private func shouldMerge(_ a: CategoryDefinition, _ b: CategoryDefinition) -> Bool {
        guard a.dimension == b.dimension else { return false }
        guard labelsAreSimilar(a.label, b.label) else { return false }
        guard messageOverlap(a, b) > mergeOverlapThreshold else { return false }
        return true
    }

    /// Two labels are similar if one contains the other or their Levenshtein distance
    /// is small relative to the longer label's length.
    private func labelsAreSimilar(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased()
        let lb = b.lowercased()

        if la.contains(lb) || lb.contains(la) {
            return true
        }

        let maxLen = max(la.count, lb.count)
        guard maxLen > 0 else { return true }

        let distance = levenshteinDistance(la, lb)
        let ratio = Double(distance) / Double(maxLen)
        return ratio < 0.3
    }

    /// Returns the fraction of message overlap between two categories.
    /// Overlap is measured relative to the smaller category.
    private func messageOverlap(_ a: CategoryDefinition, _ b: CategoryDefinition) -> Double {
        let idsA = Set(a.assignments.compactMap { $0.message?.id })
        let idsB = Set(b.assignments.compactMap { $0.message?.id })

        let smaller = min(idsA.count, idsB.count)
        guard smaller > 0 else { return 0.0 }

        let intersection = idsA.intersection(idsB).count
        return Double(intersection) / Double(smaller)
    }

    /// Transfers all assignments from the loser to the keeper and deprecates the loser.
    private func performMerge(
        keeper: CategoryDefinition,
        loser: CategoryDefinition,
        context: ModelContext
    ) {
        let keeperMessageIDs = Set(keeper.assignments.compactMap { $0.message?.id })

        for assignment in loser.assignments {
            // Only transfer if the message isn't already assigned to the keeper
            if let msgID = assignment.message?.id, !keeperMessageIDs.contains(msgID) {
                assignment.category = keeper
            }
        }

        loser.status = .deprecated
        loser.lastUpdatedAt = Date()
        keeper.lastUpdatedAt = Date()
    }

    // MARK: - Levenshtein Distance

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            current[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            previous = current
        }

        return previous[n]
    }
}
