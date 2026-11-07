import Foundation

/// Predicate spec compiled to SQL by the retrieval stack.
public struct FilterSpec: Sendable, Equatable, Codable {
    public var accountIds: [UUID]
    public var dateRange: ClosedRange<Date>?
    public var senderEmails: [String]
    public var hasAttachment: Bool?
    public var keywords: [String]?
    public var collections: [VectorCollection]
    /// Optional hard gate for app-layer scopes that cannot be represented by
    /// `message_filter_metadata` columns, such as Constellation interpretation
    /// filters or correspondent To/Domain matching. `nil` means no gate; an
    /// empty array means the scope intentionally contains no messages.
    public var allowedMessageIds: [String]?

    public init(
        accountIds: [UUID] = [],
        dateRange: ClosedRange<Date>? = nil,
        senderEmails: [String] = [],
        hasAttachment: Bool? = nil,
        keywords: [String]? = nil,
        collections: [VectorCollection] = [],
        allowedMessageIds: [String]? = nil
    ) {
        self.accountIds = accountIds
        self.dateRange = dateRange
        self.senderEmails = senderEmails
        self.hasAttachment = hasAttachment
        self.keywords = keywords
        self.collections = collections
        self.allowedMessageIds = allowedMessageIds
    }

    public static let unfiltered = FilterSpec()

    public var requiresMessageMetadata: Bool {
        !accountIds.isEmpty || dateRange != nil || !senderEmails.isEmpty || hasAttachment != nil
    }

    /// SQL WHERE fragment without a leading `WHERE`. The fragment expects
    /// vector rows to use alias `v` and message filter metadata to use alias
    /// `m`.
    public func sqlWhereFragment() -> String {
        var clauses: [String] = []
        if !accountIds.isEmpty {
            let placeholders = Array(repeating: "?", count: accountIds.count).joined(separator: ",")
            clauses.append("m.account_id IN (\(placeholders))")
        }
        if dateRange != nil {
            clauses.append("m.received_at >= ?")
            clauses.append("m.received_at <= ?")
        }
        if !senderEmails.isEmpty {
            let placeholders = Array(repeating: "?", count: senderEmails.count).joined(separator: ",")
            clauses.append("m.sender_email IN (\(placeholders))")
        }
        if hasAttachment != nil {
            clauses.append("m.has_attachment = ?")
        }
        if !collections.isEmpty {
            let placeholders = Array(repeating: "?", count: collections.count).joined(separator: ",")
            clauses.append("v.collection IN (\(placeholders))")
        }
        return clauses.joined(separator: " AND ")
    }

    /// Binding values in the same order as `sqlWhereFragment()`.
    public var parameters: [SQLBindable] {
        var out: [SQLBindable] = []
        for id in accountIds { out.append(.text(id.uuidString)) }
        if let range = dateRange {
            out.append(.real(range.lowerBound.timeIntervalSince1970))
            out.append(.real(range.upperBound.timeIntervalSince1970))
        }
        for email in senderEmails { out.append(.text(email)) }
        if let hasAttachment { out.append(.integer(hasAttachment ? 1 : 0)) }
        for collection in collections { out.append(.text(collection.rawValue)) }
        return out
    }
}

public enum SQLBindable: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}
