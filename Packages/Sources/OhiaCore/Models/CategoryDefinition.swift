import Foundation
import SwiftData

@Model
public final class CategoryDefinition {
    public var id: UUID
    public var dimension: String
    public var label: String
    public var definition: String?
    public var status: CategoryStatus
    public var globalWeight: Double
    public var keywordFeatures: String?
    public var createdAt: Date
    public var lastUpdatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MessageCategory.category)
    public var assignments: [MessageCategory] = []

    public init(dimension: String, label: String) {
        self.id = UUID()
        self.dimension = dimension
        self.label = label
        self.status = .candidate
        self.globalWeight = 0.0
        self.createdAt = Date()
        self.lastUpdatedAt = Date()
    }
}

@Model
public final class MessageCategory {
    public var id: UUID
    public var message: Message?
    public var category: CategoryDefinition?
    public var score: Double
    public var confidence: Double
    public var source: String?
    public var evidenceSpans: String?
    public var version: String?

    public init(score: Double, confidence: Double) {
        self.id = UUID()
        self.score = score
        self.confidence = confidence
    }
}
