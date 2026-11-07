import Foundation

public struct EntityProfile: Codable, Sendable {
    public static let supportingIdsCap = 100

    public var supportingMessageIds: [String]

    public var roleDistribution: [String: Double]?
    public var recentTopics: [String]?
    public var familiarityScore: Double?
    public var languages: [String]?

    public var contentType: String?
    public var sizeBytes: Int?
    public var parentMessageId: String?
    public var coAttachmentFilenames: [String]?
    public var extractedTextSummary: String?
    public var visualEvidenceKind: String?
    public var visualLabels: [String]?
    public var visualObjects: [String]?
    public var visualOCRText: String?
    public var visualConfidence: Double?
    public var documentType: String?
    public var visibleNamesDatesAmounts: [String]?
    public var parentMessageSubject: String?
    public var parentMessageSender: String?
    public var parentMessageContext: String?

    public init(supportingMessageIds: [String] = []) {
        self.supportingMessageIds = supportingMessageIds
    }
}
