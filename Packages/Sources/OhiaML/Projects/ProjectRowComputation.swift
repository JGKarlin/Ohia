import Foundation
import OhiaCore

/// Deterministic presentation posture derived from the committed project row.
/// This is not a model assessment and never invokes generation.
public enum ProjectLifecycleState: String, Codable, Sendable, Hashable, CaseIterable {
    case current
    case awaitingUser
    case awaitingOther
    case inactive
    case uncertain
}

public enum ProjectLifecycleAssessmentSource: String, Codable, Sendable, Hashable {
    case deterministic
}

public struct ProjectLifecycleAssessment: Codable, Sendable, Hashable {
    public let state: ProjectLifecycleState
    public let source: ProjectLifecycleAssessmentSource
    public let confidence: Double
    public let reasonSummary: String
    public let evidenceSummary: String
    public let assessedAt: Date
    public let inputFingerprint: String

    public init(
        state: ProjectLifecycleState,
        source: ProjectLifecycleAssessmentSource,
        confidence: Double,
        reasonSummary: String,
        evidenceSummary: String,
        assessedAt: Date,
        inputFingerprint: String
    ) {
        self.state = state
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.reasonSummary = reasonSummary
        self.evidenceSummary = evidenceSummary
        self.assessedAt = assessedAt
        self.inputFingerprint = inputFingerprint
    }
}

public struct ManualProjectRowInput: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let configurationRevision: Int
    /// Stable persisted creation time. Empty rows use this as their visual
    /// activity anchor; the refresh clock must never make them move.
    public let createdAt: Date
    public let isPinned: Bool
    public let pinSortIndex: Int?
    public let resolvedAt: Date?
    public let health: MailProjectHealth
    public let memberships: [MailProjectMembershipSnapshot]

    public init(
        id: UUID,
        displayName: String,
        configurationRevision: Int,
        createdAt: Date,
        isPinned: Bool,
        pinSortIndex: Int?,
        resolvedAt: Date?,
        health: MailProjectHealth,
        memberships: [MailProjectMembershipSnapshot]
    ) {
        self.id = id
        self.displayName = displayName
        self.configurationRevision = configurationRevision
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.pinSortIndex = pinSortIndex
        self.resolvedAt = resolvedAt
        self.health = health
        self.memberships = memberships
    }
}

public struct ProjectRowComputationConfiguration: Sendable, Equatable {
    public let now: Date
    public let revivalQuietGap: TimeInterval
    public let revivalRecentWindow: TimeInterval
    public let includeWeakSharedCorrespondentLinks: Bool

    public init(
        now: Date = .now,
        revivalQuietGap: TimeInterval = 45 * 86_400,
        revivalRecentWindow: TimeInterval = 21 * 86_400,
        includeWeakSharedCorrespondentLinks: Bool = false
    ) {
        self.now = now
        self.revivalQuietGap = revivalQuietGap
        self.revivalRecentWindow = revivalRecentWindow
        self.includeWeakSharedCorrespondentLinks = includeWeakSharedCorrespondentLinks
    }
}

public enum ProjectRowStatus: String, Codable, Sendable, Hashable {
    case active
    case revived
    case quiet
    case resolved
    case longTail
}

public enum ProjectsDensityTier: String, Codable, Sendable, Hashable {
    case full
    case condensed
    case minimal

    public static func tier(forVisibleRowCount count: Int) -> ProjectsDensityTier {
        if count >= 40 { return .minimal }
        if count >= 20 { return .condensed }
        return .full
    }

    public var rendersEmergenceMarkers: Bool { self == .full }
    public var rendersRevivalArcs: Bool { self != .minimal }
    public var rendersDeadlineTicks: Bool { self != .minimal }
}

public struct ProjectMessageMark: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let messageID: UUID
    public let date: Date
    public let isSentByUser: Bool
    public let isRead: Bool
    public let isFlagged: Bool
    public let isReplied: Bool
    public let isConfirmed: Bool
    public let isResolvedByUser: Bool
    public let hasAttachments: Bool
    public let hasDeadline: Bool
    public let deadlineText: String?
    public let isRevivedAfterInactiveGap: Bool
    public let sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
    public let subject: String
    public let obligationKinds: Set<ProjectOpenObligation.Kind>

    public init(
        messageID: UUID,
        date: Date,
        isSentByUser: Bool,
        isRead: Bool,
        isFlagged: Bool = false,
        isReplied: Bool = false,
        isConfirmed: Bool = false,
        isResolvedByUser: Bool = false,
        hasAttachments: Bool,
        hasDeadline: Bool = false,
        deadlineText: String? = nil,
        isRevivedAfterInactiveGap: Bool = false,
        sharedEvidenceKinds: Set<MessageSharedEvidenceKind> = [],
        subject: String,
        obligationKinds: Set<ProjectOpenObligation.Kind>
    ) {
        id = messageID
        self.messageID = messageID
        self.date = date
        self.isSentByUser = isSentByUser
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isReplied = isReplied
        self.isConfirmed = isConfirmed
        self.isResolvedByUser = isResolvedByUser
        self.hasAttachments = hasAttachments
        self.hasDeadline = hasDeadline
        let trimmedDeadline = deadlineText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deadlineText = hasDeadline && trimmedDeadline?.isEmpty == false ? trimmedDeadline : nil
        self.isRevivedAfterInactiveGap = isRevivedAfterInactiveGap
        self.sharedEvidenceKinds = sharedEvidenceKinds
        self.subject = subject
        self.obligationKinds = obligationKinds
    }

    private enum CodingKeys: String, CodingKey {
        case id, messageID, date, isSentByUser, isRead, isFlagged, isReplied
        case isConfirmed, isResolvedByUser, hasAttachments, hasDeadline
        case deadlineText, isRevivedAfterInactiveGap, sharedEvidenceKinds
        case subject, obligationKinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            date: try container.decode(Date.self, forKey: .date),
            isSentByUser: try container.decode(Bool.self, forKey: .isSentByUser),
            isRead: try container.decode(Bool.self, forKey: .isRead),
            isFlagged: try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false,
            isReplied: try container.decodeIfPresent(Bool.self, forKey: .isReplied) ?? false,
            isConfirmed: try container.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false,
            isResolvedByUser: try container.decodeIfPresent(Bool.self, forKey: .isResolvedByUser) ?? false,
            hasAttachments: try container.decode(Bool.self, forKey: .hasAttachments),
            hasDeadline: try container.decodeIfPresent(Bool.self, forKey: .hasDeadline) ?? false,
            deadlineText: try container.decodeIfPresent(String.self, forKey: .deadlineText),
            isRevivedAfterInactiveGap: try container.decodeIfPresent(Bool.self, forKey: .isRevivedAfterInactiveGap) ?? false,
            sharedEvidenceKinds: try container.decodeIfPresent(Set<MessageSharedEvidenceKind>.self, forKey: .sharedEvidenceKinds) ?? [],
            subject: try container.decode(String.self, forKey: .subject),
            obligationKinds: try container.decodeIfPresent(Set<ProjectOpenObligation.Kind>.self, forKey: .obligationKinds) ?? []
        )
    }
}

public struct ProjectDeadlineTick: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let messageID: UUID
    public let date: Date
    public let type: String
    public let evidenceText: String
    public let confidence: Double

    public init(messageID: UUID, date: Date, type: String, evidenceText: String, confidence: Double) {
        id = DeterministicProjectArtifactID.make(
            kind: "deadline",
            components: [
                messageID.uuidString.lowercased(),
                DeterministicProjectArtifactID.date(date),
                type,
                evidenceText,
                DeterministicProjectArtifactID.double(confidence)
            ]
        )
        self.messageID = messageID
        self.date = date
        self.type = type
        self.evidenceText = evidenceText
        self.confidence = confidence
    }
}

public struct ProjectRevivalArc: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let fromDate: Date
    public let toDate: Date
    public let quietDays: Int
    public let resumingMessageID: UUID?

    public init(fromDate: Date, toDate: Date, quietDays: Int, resumingMessageID: UUID? = nil) {
        id = DeterministicProjectArtifactID.make(
            kind: "revival",
            components: [
                DeterministicProjectArtifactID.date(fromDate),
                DeterministicProjectArtifactID.date(toDate),
                String(quietDays),
                resumingMessageID?.uuidString.lowercased() ?? "nil"
            ]
        )
        self.fromDate = fromDate
        self.toDate = toDate
        self.quietDays = quietDays
        self.resumingMessageID = resumingMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromDate, toDate, quietDays, resumingMessageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromDate = try container.decode(Date.self, forKey: .fromDate)
        toDate = try container.decode(Date.self, forKey: .toDate)
        quietDays = try container.decode(Int.self, forKey: .quietDays)
        resumingMessageID = try container.decodeIfPresent(UUID.self, forKey: .resumingMessageID)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
            ?? DeterministicProjectArtifactID.make(
                kind: "revival",
                components: [
                    DeterministicProjectArtifactID.date(fromDate),
                    DeterministicProjectArtifactID.date(toDate),
                    String(quietDays),
                    resumingMessageID?.uuidString.lowercased() ?? "nil"
                ]
            )
    }
}

public struct ProjectEmergenceMarker: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let messageID: UUID
    public let date: Date
    public let label: String

    public init(messageID: UUID, date: Date, label: String) {
        id = messageID
        self.messageID = messageID
        self.date = date
        self.label = label
    }
}

public struct ProjectParticipantSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: String { email }
    public let email: String
    public let displayName: String?
    public let messageCount: Int

    public init(email: String, displayName: String?, messageCount: Int) {
        self.email = email
        self.displayName = displayName
        self.messageCount = messageCount
    }
}

public struct ProjectRow: Codable, Sendable, Identifiable, Hashable {
    public let projectID: UUID
    public let displayLabel: String
    public let configurationRevision: Int
    public let messageIDs: [UUID]
    public let firstActivityAt: Date
    public let lastActivityAt: Date
    public let marks: [ProjectMessageMark]
    public let deadlineTicks: [ProjectDeadlineTick]
    public let revivalArcs: [ProjectRevivalArc]
    public let emergenceMarkers: [ProjectEmergenceMarker]
    public let obligations: [ProjectOpenObligation]
    public let obligationLoad: OpenObligationLoad
    public let participants: [ProjectParticipantSummary]
    public let isPinned: Bool
    public let pinSortIndex: Int?
    public let resolvedAt: Date?
    public let health: MailProjectHealth
    public let status: ProjectRowStatus
    public let lifecycleAssessment: ProjectLifecycleAssessment
    public let activityBursts: [ProjectActivityBurst]
    public let utilityRank: Int

    public init(
        projectID: UUID,
        displayLabel: String,
        configurationRevision: Int,
        messageIDs: [UUID],
        firstActivityAt: Date,
        lastActivityAt: Date,
        marks: [ProjectMessageMark],
        deadlineTicks: [ProjectDeadlineTick],
        revivalArcs: [ProjectRevivalArc],
        emergenceMarkers: [ProjectEmergenceMarker],
        obligations: [ProjectOpenObligation],
        obligationLoad: OpenObligationLoad,
        participants: [ProjectParticipantSummary],
        isPinned: Bool,
        pinSortIndex: Int?,
        resolvedAt: Date?,
        health: MailProjectHealth,
        status: ProjectRowStatus,
        lifecycleAssessment: ProjectLifecycleAssessment? = nil,
        activityBursts: [ProjectActivityBurst]? = nil,
        utilityRank: Int
    ) {
        self.projectID = projectID
        self.displayLabel = displayLabel
        self.configurationRevision = configurationRevision
        self.messageIDs = messageIDs
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.marks = marks
        self.deadlineTicks = deadlineTicks
        self.revivalArcs = revivalArcs
        self.emergenceMarkers = emergenceMarkers
        self.obligations = obligations
        self.obligationLoad = obligationLoad
        self.participants = participants
        self.isPinned = isPinned
        self.pinSortIndex = pinSortIndex
        self.resolvedAt = resolvedAt
        self.health = health
        self.status = status
        self.lifecycleAssessment = lifecycleAssessment ?? Self.deterministicLifecycleAssessment(
            status: status,
            obligationLoad: obligationLoad,
            assessedAt: lastActivityAt
        )
        self.activityBursts = activityBursts ?? ProjectActivityBursts.bursts(for: marks.map(\.date))
        self.utilityRank = utilityRank
    }

    public var id: UUID { projectID }
    public var projectKey: String { projectID.uuidString.lowercased() }
    public var isResolvedByUser: Bool { resolvedAt != nil }
    public var isResolvedEffective: Bool { isResolvedByUser || status == .resolved }

    public static func deterministicLifecycleAssessment(
        status: ProjectRowStatus,
        obligationLoad: OpenObligationLoad,
        assessedAt: Date,
        inputFingerprint: String = ""
    ) -> ProjectLifecycleAssessment {
        let state: ProjectLifecycleState
        let reason: String
        switch status {
        case .resolved:
            state = .current
            reason = "Project is resolved — no open items remain."
        case .quiet:
            state = .uncertain
            reason = "No current obligations and activity is past the quiet threshold."
        case .active where obligationLoad.hasVisibleObligations:
            state = .awaitingUser
            reason = "Current open obligations are visible for this project."
        case .active, .revived:
            state = .current
            reason = "Recent or revived project activity is visible."
        case .longTail:
            state = .current
            reason = "Long-tail row status."
        }
        return ProjectLifecycleAssessment(
            state: state,
            source: .deterministic,
            confidence: 1,
            reasonSummary: reason,
            evidenceSummary: "",
            assessedAt: assessedAt,
            inputFingerprint: inputFingerprint
        )
    }
}

public struct ProjectRowsSnapshot: Codable, Sendable, Equatable {
    public let builtAt: Date
    public let rows: [ProjectRow]
    public let links: [CrossProjectLink]
    public let messageLookup: [UUID: ProjectMessageInput]
    public let membershipByMessageID: [UUID: Set<UUID>]
    public let dateRange: ClosedRange<Date>?

    public init(
        builtAt: Date,
        rows: [ProjectRow],
        links: [CrossProjectLink],
        messageLookup: [UUID: ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        dateRange: ClosedRange<Date>?
    ) {
        self.builtAt = builtAt
        self.rows = rows
        self.links = links
        self.messageLookup = messageLookup
        self.membershipByMessageID = membershipByMessageID
        self.dateRange = dateRange
    }

    public var visibleRows: [ProjectRow] { rows }
    public var allowedMessageIDs: [UUID] { rows.flatMap(\.messageIDs) }

    public func crossProjectLinkCount(touching projectID: UUID?) -> Int {
        guard let projectID else { return 0 }
        return links.filter {
            $0.leftProjectID == projectID || $0.rightProjectID == projectID
        }.count
    }

    public func applyingLifecycleAssessments(
        _ assessmentsByProjectKey: [String: ProjectLifecycleAssessment]
    ) -> ProjectRowsSnapshot {
        guard assessmentsByProjectKey.isEmpty == false else { return self }
        return ProjectRowsSnapshot(
            builtAt: builtAt,
            rows: rows.map { row in
                guard let assessment = assessmentsByProjectKey[row.projectKey] else { return row }
                return row.withLifecycleAssessment(assessment)
            },
            links: links,
            messageLookup: messageLookup,
            membershipByMessageID: membershipByMessageID,
            dateRange: dateRange
        )
    }

    public func applyingMessageStatusSignals(_ signals: MessageStatusSignalIndex) -> ProjectRowsSnapshot {
        ProjectRowsSnapshot(
            builtAt: builtAt,
            rows: rows.map { $0.withMessageStatusSignals(signals) },
            links: links,
            messageLookup: messageLookup,
            membershipByMessageID: membershipByMessageID,
            dateRange: dateRange
        )
    }
}

public enum ProjectRowComputation {
    public static func snapshot(
        projects: [ManualProjectRowInput],
        messages rawMessages: [ProjectMessageInput],
        sharedMessageActions: ProjectLensSharedMessageActionState,
        configuration: ProjectRowComputationConfiguration = ProjectRowComputationConfiguration()
    ) -> ProjectRowsSnapshot {
        let messages = uniqueMessages(rawMessages)
            .sorted(by: PendingReplyResolver.projectMessageSort)
        let messageLookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        var membershipByMessageID: [UUID: Set<UUID>] = [:]
        for project in projects {
            for membership in project.memberships
            where membership.projectID == project.id && messageLookup[membership.messageID] != nil {
                membershipByMessageID[membership.messageID, default: []].insert(project.id)
            }
        }

        let attentionByMessageID = MessageAttentionResolver.states(
            messages: messages.map(MessageAttentionInput.init(projectMessage:)),
            userActions: MessageAttentionUserActionState(
                resolvedMessageIDs: sharedMessageActions.resolvedMessageIDs,
                replyNeededMessageIDs: sharedMessageActions.replyNeededMessageIDs,
                repliedMessageIDs: sharedMessageActions.repliedMessageIDs,
                confirmationNeededMessageIDs: sharedMessageActions.confirmationNeededMessageIDs,
                confirmedMessageIDs: sharedMessageActions.confirmedMessageIDs
            )
        )
        let obligations = PendingReplyResolver.openObligations(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            sharedMessageActions: sharedMessageActions
        )
        let obligationsByProjectID = Dictionary(grouping: obligations, by: \.projectID)
        let obligationKindsByMessageID = obligations.reduce(
            into: [UUID: Set<ProjectOpenObligation.Kind>]()
        ) { result, obligation in
            result[obligation.messageID, default: []].insert(obligation.kind)
        }

        var rows = projects.map { project in
            let memberIDs = Set(project.memberships.compactMap { membership -> UUID? in
                guard membership.projectID == project.id,
                      messageLookup[membership.messageID] != nil else { return nil }
                return membership.messageID
            })
            let memberMessages = messages.filter { memberIDs.contains($0.id) }
            return makeRow(
                project: project,
                messages: memberMessages,
                obligations: obligationsByProjectID[project.id] ?? [],
                obligationKindsByMessageID: obligationKindsByMessageID,
                attentionByMessageID: attentionByMessageID,
                sharedMessageActions: sharedMessageActions,
                configuration: configuration
            )
        }

        rows.sort(by: rowSort)
        rows = rows.enumerated().map { $0.element.withUtilityRank($0.offset) }

        let linkEvidence = CrossProjectLinkGraph.linkEvidence(
            messages: messages,
            rows: rows,
            membershipByMessageID: membershipByMessageID,
            includeWeakSharedCorrespondentLinks: configuration.includeWeakSharedCorrespondentLinks
        )
        let links = CrossProjectLinkGraph.links(from: linkEvidence)
        let memberDates = messages.compactMap { message in
            membershipByMessageID[message.id]?.isEmpty == false ? message.date : nil
        }
        let dateRange = memberDates.min().flatMap { lower in
            memberDates.max().map { lower ... $0 }
        }

        let snapshot = ProjectRowsSnapshot(
            builtAt: configuration.now,
            rows: rows,
            links: links,
            messageLookup: messageLookup,
            membershipByMessageID: membershipByMessageID,
            dateRange: dateRange
        )
        return snapshot.applyingMessageStatusSignals(
            MessageStatusSignalIndex(
                projectRowsSnapshot: snapshot,
                linkEvidence: linkEvidence.values.flatMap { $0 }
            )
        )
    }

    public static func projectedSnapshot(
        from definitions: ProjectRowsSnapshot,
        matchingMessageIDs: Set<UUID>
    ) -> ProjectRowsSnapshot {
        let rows = definitions.rows.map { definition in
            projectedRow(
                definition,
                matchingMessageIDs: matchingMessageIDs,
                messageLookup: definitions.messageLookup
            )
        }
        let visibleDates = rows.flatMap(\.marks).map(\.date)
        let dateRange = visibleDates.min().flatMap { lower in
            visibleDates.max().map { lower ... $0 }
        }
        return ProjectRowsSnapshot(
            builtAt: definitions.builtAt,
            rows: rows,
            links: definitions.links,
            messageLookup: definitions.messageLookup.filter { matchingMessageIDs.contains($0.key) },
            membershipByMessageID: definitions.membershipByMessageID.filter { matchingMessageIDs.contains($0.key) },
            dateRange: dateRange
        )
    }

    private static func makeRow(
        project: ManualProjectRowInput,
        messages: [ProjectMessageInput],
        obligations: [ProjectOpenObligation],
        obligationKindsByMessageID: [UUID: Set<ProjectOpenObligation.Kind>],
        attentionByMessageID: [UUID: MessageAttentionState],
        sharedMessageActions: ProjectLensSharedMessageActionState,
        configuration: ProjectRowComputationConfiguration
    ) -> ProjectRow {
        let firstActivityAt = messages.first?.date ?? project.createdAt
        let lastActivityAt = messages.last?.date ?? project.createdAt
        let pendingCount = obligations.filter { $0.kind == .pendingReply }.count
        let confirmationCount = obligations.filter { $0.kind == .confirmation }.count
        let load = OpenObligationLoad(
            pendingReplyCount: pendingCount,
            confirmationCount: confirmationCount,
            resolvedByUser: project.resolvedAt != nil,
            openMessageCount: Set(obligations.map(\.messageID)).count
        )
        let revivals = revivalArcs(messages: messages, configuration: configuration)
        let revivedMessageIDs = Set(revivals.compactMap(\.resumingMessageID))
        let marks = messages.map { message in
            let attention = attentionByMessageID[message.id]
            return ProjectMessageMark(
                messageID: message.id,
                date: message.date,
                isSentByUser: message.isSentByUser,
                isRead: message.isRead,
                isFlagged: message.isFlagged,
                isReplied: sharedMessageActions.repliedMessageIDs.contains(message.id)
                    || (sharedMessageActions.replyNeededMessageIDs.contains(message.id) == false
                        && (message.repliedAt != nil || attention?.clearsByMessageID != nil)),
                isConfirmed: sharedMessageActions.confirmedMessageIDs.contains(message.id),
                isResolvedByUser: sharedMessageActions.resolvedMessageIDs.contains(message.id),
                hasAttachments: message.hasAttachments,
                hasDeadline: message.deadlines.isEmpty == false,
                deadlineText: message.deadlines.compactMap(\.displayText).first,
                isRevivedAfterInactiveGap: revivedMessageIDs.contains(message.id),
                subject: message.subject,
                obligationKinds: obligationKindsByMessageID[message.id] ?? []
            )
        }
        let resolvedByMessageClosures = messageClosureResolutionApplies(
            messages: messages,
            openObligationCount: pendingCount + confirmationCount,
            sharedMessageActions: sharedMessageActions
        )
        let status: ProjectRowStatus
        if messages.isEmpty && project.resolvedAt == nil {
            status = .active
        } else {
            status = rowStatus(
                last: lastActivityAt,
                isResolved: project.resolvedAt != nil || resolvedByMessageClosures,
                hasVisibleObligations: load.hasVisibleObligations,
                revivalArcs: revivals,
                now: configuration.now
            )
        }
        return ProjectRow(
            projectID: project.id,
            displayLabel: project.displayName,
            configurationRevision: project.configurationRevision,
            messageIDs: messages.map(\.id),
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            marks: marks,
            deadlineTicks: messages.flatMap(parseDeadlineTicks),
            revivalArcs: revivals,
            emergenceMarkers: messages.first.map {
                [ProjectEmergenceMarker(messageID: $0.id, date: $0.date, label: project.displayName)]
            } ?? [],
            obligations: obligations.sorted { $0.openedAt > $1.openedAt },
            obligationLoad: load,
            participants: participantSummaries(messages: messages),
            isPinned: project.isPinned,
            pinSortIndex: project.pinSortIndex,
            resolvedAt: project.resolvedAt,
            health: project.health,
            status: status,
            lifecycleAssessment: ProjectRow.deterministicLifecycleAssessment(
                status: status,
                obligationLoad: load,
                assessedAt: messages.isEmpty ? project.createdAt : configuration.now
            ),
            utilityRank: 0
        )
    }

    private static func projectedRow(
        _ definition: ProjectRow,
        matchingMessageIDs: Set<UUID>,
        messageLookup: [UUID: ProjectMessageInput]
    ) -> ProjectRow {
        let marks = definition.marks.filter { matchingMessageIDs.contains($0.messageID) }
        let visibleMessageIDs = Set(marks.map(\.messageID))
        let obligations = definition.obligations.filter { visibleMessageIDs.contains($0.messageID) }
        let load = OpenObligationLoad(
            pendingReplyCount: obligations.filter { $0.kind == .pendingReply }.count,
            confirmationCount: obligations.filter { $0.kind == .confirmation }.count,
            resolvedByUser: definition.isResolvedByUser,
            openMessageCount: Set(obligations.map(\.messageID)).count
        )
        let inputs = definition.messageIDs.compactMap { messageID -> ProjectMessageInput? in
            guard visibleMessageIDs.contains(messageID) else { return nil }
            return messageLookup[messageID]
        }
        return ProjectRow(
            projectID: definition.projectID,
            displayLabel: definition.displayLabel,
            configurationRevision: definition.configurationRevision,
            messageIDs: definition.messageIDs.filter(visibleMessageIDs.contains),
            firstActivityAt: marks.map(\.date).min() ?? definition.firstActivityAt,
            lastActivityAt: marks.map(\.date).max() ?? definition.lastActivityAt,
            marks: marks,
            deadlineTicks: definition.deadlineTicks.filter { visibleMessageIDs.contains($0.messageID) },
            revivalArcs: definition.revivalArcs.filter { arc in
                arc.resumingMessageID.map(visibleMessageIDs.contains) ?? false
            },
            emergenceMarkers: definition.emergenceMarkers.filter { visibleMessageIDs.contains($0.messageID) },
            obligations: obligations,
            obligationLoad: load,
            participants: participantSummaries(messages: inputs),
            isPinned: definition.isPinned,
            pinSortIndex: definition.pinSortIndex,
            resolvedAt: definition.resolvedAt,
            health: definition.health,
            status: definition.status,
            lifecycleAssessment: definition.lifecycleAssessment,
            activityBursts: ProjectActivityBursts.bursts(for: marks.map(\.date)),
            utilityRank: definition.utilityRank
        )
    }

    private static func rowSort(_ lhs: ProjectRow, _ rhs: ProjectRow) -> Bool {
        let leftResolved = lhs.isResolvedEffective ? 1 : 0
        let rightResolved = rhs.isResolvedEffective ? 1 : 0
        if leftResolved != rightResolved { return leftResolved < rightResolved }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        let leftPin = lhs.pinSortIndex ?? .max
        let rightPin = rhs.pinSortIndex ?? .max
        if leftPin != rightPin { return leftPin < rightPin }
        if lhs.obligationLoad.pendingReplyCount != rhs.obligationLoad.pendingReplyCount {
            return lhs.obligationLoad.pendingReplyCount > rhs.obligationLoad.pendingReplyCount
        }
        if lhs.obligationLoad.confirmationCount != rhs.obligationLoad.confirmationCount {
            return lhs.obligationLoad.confirmationCount > rhs.obligationLoad.confirmationCount
        }
        if lhs.status != rhs.status { return statusRank(lhs.status) < statusRank(rhs.status) }
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
        let labelOrder = lhs.displayLabel.localizedStandardCompare(rhs.displayLabel)
        if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
        return lhs.projectID.uuidString < rhs.projectID.uuidString
    }

    private static func statusRank(_ status: ProjectRowStatus) -> Int {
        switch status {
        case .active: return 0
        case .revived: return 1
        case .quiet: return 2
        case .resolved: return 3
        case .longTail: return 4
        }
    }

    private static func rowStatus(
        last: Date,
        isResolved: Bool,
        hasVisibleObligations: Bool,
        revivalArcs: [ProjectRevivalArc],
        now: Date
    ) -> ProjectRowStatus {
        if isResolved { return .resolved }
        if revivalArcs.isEmpty == false { return .revived }
        if hasVisibleObligations { return .active }
        if now.timeIntervalSince(last) > 45 * 86_400 { return .quiet }
        return .active
    }

    static func messageClosureResolutionApplies(
        messages: [ProjectMessageInput],
        openObligationCount: Int,
        sharedMessageActions: ProjectLensSharedMessageActionState
    ) -> Bool {
        guard openObligationCount == 0 else { return false }
        return messages.contains { message in
            sharedMessageActions.resolvedMessageIDs.contains(message.id)
                || sharedMessageActions.confirmedMessageIDs.contains(message.id)
        }
    }

    private static func revivalArcs(
        messages: [ProjectMessageInput],
        configuration: ProjectRowComputationConfiguration
    ) -> [ProjectRevivalArc] {
        guard messages.count >= 2 else { return [] }
        return zip(messages, messages.dropFirst()).compactMap { earlier, later in
            let gap = later.date.timeIntervalSince(earlier.date)
            guard gap >= configuration.revivalQuietGap,
                  configuration.now.timeIntervalSince(later.date) <= configuration.revivalRecentWindow else {
                return nil
            }
            return ProjectRevivalArc(
                fromDate: earlier.date,
                toDate: later.date,
                quietDays: Int(gap / 86_400),
                resumingMessageID: later.id
            )
        }
    }

    private static func parseDeadlineTicks(message: ProjectMessageInput) -> [ProjectDeadlineTick] {
        message.deadlines.compactMap { candidate in
            guard candidate.confidence >= 0.70,
                  let resolved = DeadlineDateResolver.resolve(candidate.dateString, referenceDate: message.date) else {
                return nil
            }
            return ProjectDeadlineTick(
                messageID: message.id,
                date: resolved.date,
                type: candidate.type,
                evidenceText: candidate.evidenceSpan?.text ?? candidate.dateString,
                confidence: candidate.confidence
            )
        }
    }

    private static func participantSummaries(messages: [ProjectMessageInput]) -> [ProjectParticipantSummary] {
        struct Accumulator {
            var displayName: String?
            var count: Int
        }
        var byEmail: [String: Accumulator] = [:]
        for message in messages {
            for participant in message.participants where participant.email.isEmpty == false {
                var value = byEmail[participant.email] ?? Accumulator(
                    displayName: participant.displayName,
                    count: 0
                )
                value.count += 1
                if value.displayName == nil { value.displayName = participant.displayName }
                byEmail[participant.email] = value
            }
        }
        return byEmail
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.key < $1.key
            }
            .map {
                ProjectParticipantSummary(
                    email: $0.key,
                    displayName: $0.value.displayName,
                    messageCount: $0.value.count
                )
            }
    }

    private static func uniqueMessages(_ messages: [ProjectMessageInput]) -> [ProjectMessageInput] {
        var seen = Set<UUID>()
        return messages.filter { seen.insert($0.id).inserted }
    }
}

private extension ProjectRow {
    func withUtilityRank(_ rank: Int) -> ProjectRow {
        ProjectRow(
            projectID: projectID,
            displayLabel: displayLabel,
            configurationRevision: configurationRevision,
            messageIDs: messageIDs,
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            marks: marks,
            deadlineTicks: deadlineTicks,
            revivalArcs: revivalArcs,
            emergenceMarkers: emergenceMarkers,
            obligations: obligations,
            obligationLoad: obligationLoad,
            participants: participants,
            isPinned: isPinned,
            pinSortIndex: pinSortIndex,
            resolvedAt: resolvedAt,
            health: health,
            status: status,
            lifecycleAssessment: lifecycleAssessment,
            activityBursts: activityBursts,
            utilityRank: rank
        )
    }

    func withLifecycleAssessment(_ assessment: ProjectLifecycleAssessment) -> ProjectRow {
        ProjectRow(
            projectID: projectID,
            displayLabel: displayLabel,
            configurationRevision: configurationRevision,
            messageIDs: messageIDs,
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            marks: marks,
            deadlineTicks: deadlineTicks,
            revivalArcs: revivalArcs,
            emergenceMarkers: emergenceMarkers,
            obligations: obligations,
            obligationLoad: obligationLoad,
            participants: participants,
            isPinned: isPinned,
            pinSortIndex: pinSortIndex,
            resolvedAt: resolvedAt,
            health: health,
            status: status,
            lifecycleAssessment: assessment,
            activityBursts: activityBursts,
            utilityRank: utilityRank
        )
    }

    func withMessageStatusSignals(_ signals: MessageStatusSignalIndex) -> ProjectRow {
        ProjectRow(
            projectID: projectID,
            displayLabel: displayLabel,
            configurationRevision: configurationRevision,
            messageIDs: messageIDs,
            firstActivityAt: firstActivityAt,
            lastActivityAt: lastActivityAt,
            marks: marks.map { $0.withMessageStatusSignals(signals) },
            deadlineTicks: deadlineTicks,
            revivalArcs: revivalArcs,
            emergenceMarkers: emergenceMarkers,
            obligations: obligations,
            obligationLoad: obligationLoad,
            participants: participants,
            isPinned: isPinned,
            pinSortIndex: pinSortIndex,
            resolvedAt: resolvedAt,
            health: health,
            status: status,
            lifecycleAssessment: lifecycleAssessment,
            activityBursts: activityBursts,
            utilityRank: utilityRank
        )
    }
}

private extension ProjectMessageMark {
    func withMessageStatusSignals(_ signals: MessageStatusSignalIndex) -> ProjectMessageMark {
        ProjectMessageMark(
            messageID: messageID,
            date: date,
            isSentByUser: isSentByUser,
            isRead: isRead,
            isFlagged: isFlagged,
            isReplied: isReplied,
            isConfirmed: isConfirmed,
            isResolvedByUser: isResolvedByUser,
            hasAttachments: hasAttachments,
            hasDeadline: hasDeadline,
            deadlineText: deadlineText,
            isRevivedAfterInactiveGap: signals.isRevivedAfterInactiveGap(messageID),
            sharedEvidenceKinds: signals.sharedEvidenceKinds(for: messageID),
            subject: subject,
            obligationKinds: obligationKinds
        )
    }
}
