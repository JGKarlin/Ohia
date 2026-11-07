import Foundation
import OhiaCore

public enum ProjectAttachmentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case document
    case spreadsheet
    case presentation
    case image
    case archive
    case calendar
    case other

    public static func classify(mimeType: String, fileName: String) -> ProjectAttachmentKind {
        let mime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if mime.contains("spreadsheet") || mime.contains("excel") || ["xls", "xlsx", "csv", "tsv"].contains(ext) {
            return .spreadsheet
        }
        if mime.contains("presentation") || mime.contains("powerpoint") || ["ppt", "pptx", "key"].contains(ext) {
            return .presentation
        }
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(ext) {
            return .image
        }
        if mime.contains("zip") || mime.contains("tar") || mime.contains("gzip") || ["zip", "gz", "tgz", "rar", "7z"].contains(ext) {
            return .archive
        }
        if mime.contains("calendar") || ["ics", "ical"].contains(ext) {
            return .calendar
        }
        if mime.contains("pdf")
            || mime.hasPrefix("text/")
            || mime.contains("word")
            || ["pdf", "txt", "rtf", "md", "doc", "docx", "pages"].contains(ext) {
            return .document
        }
        return .other
    }
}

public struct ProjectParticipant: Codable, Sendable, Hashable {
    public let email: String
    public let displayName: String?
    public let role: ParticipantRole

    public init(email: String, displayName: String? = nil, role: ParticipantRole) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = trimmedName?.isEmpty == false ? trimmedName : nil
        self.role = role
    }
}

public struct ProjectMessageInput: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let accountID: UUID?
    public let threadID: UUID?
    public let date: Date
    public let subject: String
    public let bodySummary: String?
    public let fromAddress: String
    public let fromName: String?
    public let isSentByUser: Bool
    public let isLiveInbound: Bool
    public let isRead: Bool
    public let isFlagged: Bool
    public let isInComposerQueue: Bool
    public let hasAttachments: Bool
    public let attachmentKinds: Set<ProjectAttachmentKind>
    public let participants: [ProjectParticipant]
    public let messageType: MessageType
    public let triageVerdict: TriageVerdict?
    public let purpose: MailPurpose?
    /// Deterministic `List-ID`, unsubscribe, bulk-precedence, or
    /// `Auto-Submitted` evidence. This is a routing fact, not a category.
    public let isNonHumanTraffic: Bool
    public let customCategoryKeys: Set<String>
    public let semanticTags: [SemanticTagProjection]
    public let deadlines: [DeadlineCandidate]
    public let messageIDHeader: String?
    public let inReplyTo: String?
    public let referencesChain: String?
    public let repliedAt: Date?

    public init(
        id: UUID,
        accountID: UUID?,
        threadID: UUID?,
        date: Date,
        subject: String = "",
        bodySummary: String? = nil,
        fromAddress: String = "",
        fromName: String? = nil,
        isSentByUser: Bool,
        isLiveInbound: Bool = false,
        isRead: Bool,
        isFlagged: Bool = false,
        isInComposerQueue: Bool = false,
        hasAttachments: Bool,
        attachmentKinds: Set<ProjectAttachmentKind> = [],
        participants: [ProjectParticipant] = [],
        messageType: MessageType,
        triageVerdict: TriageVerdict?,
        purpose: MailPurpose?,
        isNonHumanTraffic: Bool = false,
        customCategoryKeys: Set<String> = [],
        semanticTags: [SemanticTagProjection],
        deadlines: [DeadlineCandidate] = [],
        messageIDHeader: String? = nil,
        inReplyTo: String? = nil,
        referencesChain: String? = nil,
        repliedAt: Date? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.threadID = threadID
        self.date = date
        self.subject = subject
        self.bodySummary = bodySummary
        self.fromAddress = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedFromName = fromName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fromName = trimmedFromName?.isEmpty == false ? trimmedFromName : nil
        self.isSentByUser = isSentByUser
        self.isLiveInbound = isLiveInbound && !isSentByUser
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isInComposerQueue = isInComposerQueue
        self.hasAttachments = hasAttachments
        self.attachmentKinds = attachmentKinds
        self.participants = participants
        self.messageType = messageType
        self.triageVerdict = triageVerdict?.normalizingActionability(isSentByUser: isSentByUser)
        self.purpose = purpose
        self.isNonHumanTraffic = isNonHumanTraffic
        self.customCategoryKeys = Set(CustomCategoryKeysJSON.canonicalKeys(customCategoryKeys))
        self.semanticTags = SemanticTagProjectionPresentation.canonical(semanticTags)
        self.deadlines = deadlines
        self.messageIDHeader = Self.normalizedHeader(messageIDHeader)
        self.inReplyTo = Self.normalizedHeader(inReplyTo)
        self.referencesChain = referencesChain
        self.repliedAt = repliedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case threadID
        case date
        case subject
        case bodySummary
        case fromAddress
        case fromName
        case isSentByUser
        case isLiveInbound
        case isRead
        case isFlagged
        case isInComposerQueue
        case hasAttachments
        case attachmentKinds
        case participants
        case messageType
        case triageVerdict
        case purpose
        case isNonHumanTraffic
        case customCategoryKeys
        case semanticTags
        case deadlines
        case messageIDHeader
        case inReplyTo
        case referencesChain
        case repliedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            accountID: try container.decodeIfPresent(UUID.self, forKey: .accountID),
            threadID: try container.decodeIfPresent(UUID.self, forKey: .threadID),
            date: try container.decode(Date.self, forKey: .date),
            subject: try container.decode(String.self, forKey: .subject),
            bodySummary: try container.decodeIfPresent(String.self, forKey: .bodySummary),
            fromAddress: try container.decode(String.self, forKey: .fromAddress),
            fromName: try container.decodeIfPresent(String.self, forKey: .fromName),
            isSentByUser: try container.decode(Bool.self, forKey: .isSentByUser),
            isLiveInbound: try container.decodeIfPresent(Bool.self, forKey: .isLiveInbound) ?? false,
            isRead: try container.decode(Bool.self, forKey: .isRead),
            isFlagged: try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false,
            isInComposerQueue: try container.decodeIfPresent(Bool.self, forKey: .isInComposerQueue) ?? false,
            hasAttachments: try container.decode(Bool.self, forKey: .hasAttachments),
            attachmentKinds: try container.decode(Set<ProjectAttachmentKind>.self, forKey: .attachmentKinds),
            participants: try container.decode([ProjectParticipant].self, forKey: .participants),
            messageType: try container.decode(MessageType.self, forKey: .messageType),
            triageVerdict: try container.decodeIfPresent(TriageVerdict.self, forKey: .triageVerdict),
            purpose: try container.decodeIfPresent(MailPurpose.self, forKey: .purpose),
            isNonHumanTraffic: try container.decode(Bool.self, forKey: .isNonHumanTraffic),
            customCategoryKeys: try container.decode(Set<String>.self, forKey: .customCategoryKeys),
            semanticTags: try container.decode([SemanticTagProjection].self, forKey: .semanticTags),
            deadlines: try container.decode([DeadlineCandidate].self, forKey: .deadlines),
            messageIDHeader: try container.decodeIfPresent(String.self, forKey: .messageIDHeader),
            inReplyTo: try container.decodeIfPresent(String.self, forKey: .inReplyTo),
            referencesChain: try container.decodeIfPresent(String.self, forKey: .referencesChain),
            repliedAt: try container.decodeIfPresent(Date.self, forKey: .repliedAt)
        )
    }

    public var normalizedParticipantEmails: Set<String> {
        Set(participants.map(\.email).filter { !$0.isEmpty })
    }

    public var referencesHeaders: Set<String> {
        var values: Set<String> = []
        if let inReplyTo { values.insert(inReplyTo) }
        if let referencesChain {
            for token in referencesChain.split(whereSeparator: \.isWhitespace) {
                if let normalized = Self.normalizedHeader(String(token)) {
                    values.insert(normalized)
                }
            }
        }
        return values
    }

    private static func normalizedHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
