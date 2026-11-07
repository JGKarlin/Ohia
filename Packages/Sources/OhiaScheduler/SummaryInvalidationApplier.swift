import Foundation
import SwiftData
import OhiaCore

/// One-shot wipe of pre-existing rich body summaries.
/// Structured mail interpretation is intentionally preserved; clearing only
/// the rich summary lets hover and lock repopulate detail prose on demand.
@MainActor
public final class SummaryInvalidationApplier {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func run() throws -> Int {
        let rows = try modelContext.fetch(FetchDescriptor<MessageAnalysis>())
        var count = 0
        for row in rows where row.bodySummary != nil
            || row.summarizedAt != nil
            || row.bodySummaryInputFingerprint != nil {
            row.bodySummary = nil
            row.bodySummaryInputFingerprint = nil
            row.summarizedAt = nil
            count += 1
        }
        try modelContext.save()
        return count
    }
}
