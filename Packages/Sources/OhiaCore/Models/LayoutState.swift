import Foundation

public struct NodePosition: Sendable, Equatable {
    public let vectorId: Int64
    public let xyz: SIMD3<Float>
    public let arrivalTime: TimeInterval
    public let lastMoveMagnitude: Float
    public init(vectorId: Int64, xyz: SIMD3<Float>, arrivalTime: TimeInterval, lastMoveMagnitude: Float) {
        self.vectorId = vectorId
        self.xyz = xyz
        self.arrivalTime = arrivalTime
        self.lastMoveMagnitude = lastMoveMagnitude
    }
}

/// Categorical edge source. Lets `FrameVisualLanguage.threadStrands` and the
/// per-frame edge-kind tint table in the fiber fragment shader distinguish
/// "this fibre came from the thread builder" from "this fibre came from the
/// cosine knn." Optional because legacy callers don't annotate.
public enum VectorEdgeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case cosine
    case thread
    case correspondent
    case temporal
    case action
    case classification
    case arc

    /// Stable numeric code used by the fiber fragment shader to pick a
    /// per-kind tint from its small palette. `0` matches the legacy
    /// (kind-less) cosine rendering.
    public var rendererCode: Int {
        switch self {
        case .cosine:        return 0
        case .thread:        return 1
        case .correspondent: return 2
        case .temporal:      return 3
        case .action:        return 4
        case .classification: return 5
        case .arc:           return 6
        }
    }
}

public struct VectorNeighbor: Sendable, Equatable {
    public let sourceId: Int64
    public let targetId: Int64
    public let similarity: Float
    public let rank: Int
    /// Which edge builder produced this neighbour. `nil` keeps legacy
    /// behaviour (treated as `.cosine` by the renderer's tint table).
    public let kind: VectorEdgeKind?
    public init(
        sourceId: Int64,
        targetId: Int64,
        similarity: Float,
        rank: Int,
        kind: VectorEdgeKind? = nil
    ) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.similarity = similarity
        self.rank = rank
        self.kind = kind
    }
}

public struct BoundingBox: Sendable {
    public let min: SIMD3<Float>
    public let max: SIMD3<Float>
    public var centroid: SIMD3<Float> { (min + max) * 0.5 }
    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }
}

/// Message-header roles the Voices query can match against.
///
/// Multiple roles may be active simultaneously. Bcc matches only when that
/// header role is present in the ingested message data; received mail cannot
/// expose recipients the source message omitted.
public enum CorrespondentScope: String, Sendable, Hashable, CaseIterable, Codable {
    case from
    case to
    case cc
    case bcc
}

/// Tri-state criterion for one message-attention flag.
///
/// `.any` is the rest state, `.required` means the message must carry the flag,
/// and `.excluded` means the message must explicitly not carry the flag.
public enum AttentionFilterCriterion: String, Sendable, Equatable, CaseIterable, Codable {
    case any
    case required
    case excluded

    public var isActive: Bool { self != .any }

    public func matches(_ value: Bool?) -> Bool {
        switch self {
        case .any:
            return true
        case .required:
            return value == true
        case .excluded:
            return value == false
        }
    }
}

public struct VectorFilter: Codable, Sendable, Equatable {
    public var collections: Set<VectorCollection> = [.context, .attachment, .entity]
    public var accountIds: Set<UUID>? = nil               // nil = all
    public var timeRange: ClosedRange<Date>? = nil        // nil = all time
    public var messageTypes: Set<MessageType>? = nil      // nil = all
    public var readStates: Set<Bool>? = nil               // nil = both
    public var repliedStates: Set<Bool>? = nil            // nil = both
    /// Tri-state on the `Message.isSentByUser` flag:
    ///   nil = both received and sent
    ///   contains(true)  → include sent-by-user messages
    ///   contains(false) → include received messages
    public var sentStates: Set<Bool>? = nil
    public var flaggedOnly: Bool = false
    public var hasAttachmentsOnly: Bool = false
    /// Action section criteria. Each visible chip controls whether a resolved
    /// message-attention state is ignored, required, or excluded. This keeps
    /// the toolbar vocabulary to the two real action states while still
    /// allowing exact combinations: reply only, confirmation only, both, or
    /// neither.
    public var replyNeededCriterion: AttentionFilterCriterion = .any
    public var confirmationNeededCriterion: AttentionFilterCriterion = .any
    /// Third Action chip, persisted as an optional so each lens can supply its
    /// own untouched default: Front Page excludes resolved messages, while
    /// every other lens ignores this criterion. Once the user cycles the chip,
    /// the explicit tri-state value wins in every lens.
    public var resolvedCriterion: AttentionFilterCriterion? = nil
    /// Flat shared-category selection. `nil` means every shared purpose is
    /// selected; an empty set means no purpose is selected.
    public var purposes: Set<MailPurpose>? = nil
    /// `Lists` is derived from `Message.listId`, never model output. `nil`
    /// means selected; `false` means the flat Lists category is unchecked.
    public var mailingListCategoryIncluded: Bool? = nil
    /// User-authored categories participate in the same flat OR selection.
    public var customCategoryKeys: Set<String>? = nil
    public var correspondentQuery: String = ""
    /// Header roles the correspondent query matches against. The Voices
    /// pulldown exposes these as independent checkboxes; the rest state checks
    /// all four so a name search finds a person anywhere present in the
    /// message header.
    public var correspondentScopes: Set<CorrespondentScope> = Set(CorrespondentScope.allCases)
    public var clusterIds: Set<Int64>? = nil              // populated in Task 9
    /// Mailing-list scope: canonical RFC 2919 list identities
    /// (`Message.listId`). `nil` = no list restriction (the rest state);
    /// non-nil renders only rows from those lists. Set by the Subscriptions
    /// ledger's "Show in Constellation" action.
    public var listIds: Set<String>? = nil

    // Interpretation filters. All apply in-memory against the structured
    // Qwen dimensions, never via SQL. Defaults below are inert ("any").
    public var taskState: TaskFilterState = .any
    public var deadlineState: DeadlineFilterState = .any

    public init() {}

    /// Custom `Decodable` so old persisted payloads (`constellationViewStateSnapshotV1`
    /// in `UserDefaults`) keep restoring after new fields are added. The
    /// synthesized decoder throws `keyNotFound` for any non-Optional field
    /// missing from the JSON, which would silently wipe the user's saved
    /// frame / time range / chip selection on update. `decodeIfPresent`
    /// with the property's default value preserves prior state and lets
    /// the new fields fall back to their rest values until the next save
    /// rewrites the payload with all keys.
    private enum CodingKeys: String, CodingKey {
        case collections
        case accountIds
        case timeRange
        case messageTypes
        case readStates
        case repliedStates
        case sentStates
        case flaggedOnly
        case hasAttachmentsOnly
        case replyNeededCriterion
        case confirmationNeededCriterion
        case resolvedCriterion
        case headlineActionableOnly
        case headlineConfirmOnly
        case purposes
        case mailingListCategoryIncluded
        case customCategoryKeys
        case correspondentQuery
        case correspondentScopes
        // Decode-only key from the retired single-choice From / To / Domain
        // control. Old snapshots intentionally fall back to the new all-role
        // default instead of preserving a hidden narrow scope.
        case correspondentScope
        case clusterIds
        case listIds
        case taskState
        case deadlineState
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Set<VectorCollection>.self, forKey: .collections) {
            collections = v
        }
        accountIds         = try c.decodeIfPresent(Set<UUID>.self,             forKey: .accountIds)
        timeRange          = try c.decodeIfPresent(ClosedRange<Date>.self,     forKey: .timeRange)
        messageTypes       = try c.decodeIfPresent(Set<MessageType>.self,      forKey: .messageTypes)
        readStates         = try c.decodeIfPresent(Set<Bool>.self,             forKey: .readStates)
        repliedStates      = try c.decodeIfPresent(Set<Bool>.self,             forKey: .repliedStates)
        sentStates         = try c.decodeIfPresent(Set<Bool>.self,             forKey: .sentStates)
        flaggedOnly        = try c.decodeIfPresent(Bool.self,                  forKey: .flaggedOnly) ?? false
        hasAttachmentsOnly = try c.decodeIfPresent(Bool.self,                  forKey: .hasAttachmentsOnly) ?? false
        replyNeededCriterion = try c.decodeIfPresent(AttentionFilterCriterion.self, forKey: .replyNeededCriterion)
            ?? ((try c.decodeIfPresent(Bool.self, forKey: .headlineActionableOnly) ?? false) ? .required : .any)
        confirmationNeededCriterion = try c.decodeIfPresent(AttentionFilterCriterion.self, forKey: .confirmationNeededCriterion)
            ?? ((try c.decodeIfPresent(Bool.self, forKey: .headlineConfirmOnly) ?? false) ? .required : .any)
        resolvedCriterion = try c.decodeIfPresent(
            AttentionFilterCriterion.self,
            forKey: .resolvedCriterion
        )
        purposes = try Self.decodeEnumSet(MailPurpose.self, from: c, forKey: .purposes)
        mailingListCategoryIncluded = try? c.decode(
            Bool.self,
            forKey: .mailingListCategoryIncluded
        )
        customCategoryKeys = Self.decodeCustomKeySet(
            from: c,
            forKey: .customCategoryKeys
        )
        correspondentQuery = try c.decodeIfPresent(String.self,                forKey: .correspondentQuery) ?? ""
        if let v = try c.decodeIfPresent(Set<CorrespondentScope>.self, forKey: .correspondentScopes) {
            // The exact pre-Bcc default represented every role available at
            // the time. Preserve narrower explicit selections as-is.
            let preBccAllRoles: Set<CorrespondentScope> = [.from, .to, .cc]
            correspondentScopes = v == preBccAllRoles ? Set(CorrespondentScope.allCases) : v
        }
        clusterIds         = try c.decodeIfPresent(Set<Int64>.self,            forKey: .clusterIds)
        listIds            = try c.decodeIfPresent(Set<String>.self,           forKey: .listIds)
        if let v = try c.decodeIfPresent(TaskFilterState.self, forKey: .taskState) {
            taskState = v
        }
        if let v = try c.decodeIfPresent(DeadlineFilterState.self, forKey: .deadlineState) {
            deadlineState = v
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(collections,                  forKey: .collections)
        try c.encodeIfPresent(accountIds,          forKey: .accountIds)
        try c.encodeIfPresent(timeRange,           forKey: .timeRange)
        try c.encodeIfPresent(messageTypes,        forKey: .messageTypes)
        try c.encodeIfPresent(readStates,          forKey: .readStates)
        try c.encodeIfPresent(repliedStates,       forKey: .repliedStates)
        try c.encodeIfPresent(sentStates,          forKey: .sentStates)
        try c.encode(flaggedOnly,                  forKey: .flaggedOnly)
        try c.encode(hasAttachmentsOnly,           forKey: .hasAttachmentsOnly)
        try c.encode(replyNeededCriterion,         forKey: .replyNeededCriterion)
        try c.encode(confirmationNeededCriterion,  forKey: .confirmationNeededCriterion)
        try c.encodeIfPresent(resolvedCriterion,   forKey: .resolvedCriterion)
        try c.encodeIfPresent(purposes,            forKey: .purposes)
        try c.encodeIfPresent(
            mailingListCategoryIncluded,
            forKey: .mailingListCategoryIncluded
        )
        try c.encodeIfPresent(customCategoryKeys,  forKey: .customCategoryKeys)
        try c.encode(correspondentQuery,           forKey: .correspondentQuery)
        try c.encode(correspondentScopes,          forKey: .correspondentScopes)
        try c.encodeIfPresent(clusterIds,          forKey: .clusterIds)
        try c.encodeIfPresent(listIds,             forKey: .listIds)
        try c.encode(taskState,                    forKey: .taskState)
        try c.encode(deadlineState,                forKey: .deadlineState)
    }

    private static func decodeEnumSet<Value>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Set<Value>? where Value: RawRepresentable & Hashable, Value.RawValue == String {
        guard let rawValues = try? container.decode(Set<String>.self, forKey: key) else {
            return nil
        }
        let decoded = Set(rawValues.compactMap(Value.init(rawValue:)))
        return decoded.isEmpty && rawValues.isEmpty == false ? nil : decoded
    }

    private static func decodeCustomKeySet(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Set<String>? {
        guard let rawValues = try? container.decode(Set<String>.self, forKey: key) else {
            return nil
        }
        let decoded = Set(CustomCategoryKeysJSON.canonicalKeys(rawValues))
        return decoded.isEmpty && rawValues.isEmpty == false ? nil : decoded
    }

    /// SQL fragments for the WHERE clause; joined by " AND " at query time.
    /// The host VectorStore query already includes `layout_x IS NOT NULL`; filter adds on top.
    /// Only filters expressible purely on the `vectors` table are emitted here.
    /// Cross-table predicates (accountIds, messageTypes, readStates, repliedStates,
    /// flaggedOnly, hasAttachmentsOnly, correspondentQuery, clusterIds) require
    /// message metadata — Constellation's Metal render planner and retrieval
    /// paths evaluate them against the current message-filter snapshot.
    public func sqlClauses() -> [String] {
        var clauses: [String] = []
        if collections.isEmpty {
            clauses.append("0 = 1")
        } else {
            let list = collections.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("collection IN (\(list))")
        }
        if let timeRange {
            // Filter on the email's own date (`message_received_at` =
            // Unix epoch seconds of `Message.vectorTimeFilterDate`), not on
            // `arrival_time` (which stamps when the vector got its 3-D
            // position). NULL dates do not match ranged windows; launch-time
            // repair fills legacy rows from SwiftData so "Today" never means
            // "all unknown-date vectors."
            let lo = timeRange.lowerBound.timeIntervalSince1970
            let hi = timeRange.upperBound.timeIntervalSince1970
            clauses.append("message_received_at BETWEEN \(lo) AND \(hi)")
        }
        return clauses
    }

    /// Count of structured interpretation filters currently in non-default state.
    /// Used by the detailed interpretation overlay summary.
    public var interpretationActiveCount: Int {
        var n = 0
        if taskState        != .any             { n += 1 }
        if deadlineState    != .any             { n += 1 }
        if let cluster = clusterIds, !cluster.isEmpty { n += 1 }
        return n
    }
}
