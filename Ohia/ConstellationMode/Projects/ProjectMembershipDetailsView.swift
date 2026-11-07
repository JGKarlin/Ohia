import SwiftData
import SwiftUI
import OhiaCore
import OhiaML

struct ProjectMembershipConditionDetail: Equatable, Identifiable, Sendable {
    let id: UUID
    let summary: String
}

struct ProjectMembershipDetailsPresentation: Equatable, Identifiable, Sendable {
    var id: UUID { messageID }

    let messageID: UUID
    let projectName: String
    let sourceTitle: String
    let winningGroupTitle: String?
    let matchedConditions: [ProjectMembershipConditionDetail]
    let categoryRequirementLabel: String?
    let messageDecisionTitle: String?
    let threadDecisionTitle: String?
    let isExceptionToAutomaticRules: Bool
    let otherProjectNames: [String]
}

@MainActor
enum ProjectMembershipDetailsBuilder {
    static func build(
        projectID: UUID,
        messageID: UUID,
        in modelContext: ModelContext
    ) throws -> ProjectMembershipDetailsPresentation? {
        var projectDescriptor = FetchDescriptor<MailProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        projectDescriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(projectDescriptor).first else { return nil }

        let membershipKey = MailProjectMembership.key(projectID: projectID, messageID: messageID)
        var membershipDescriptor = FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.membershipKey == membershipKey }
        )
        membershipDescriptor.fetchLimit = 1
        guard let membership = try modelContext.fetch(membershipDescriptor).first,
              let provenanceData = membership.provenanceJSON.data(using: .utf8) else {
            return nil
        }
        let provenance = try JSONDecoder().decode(
            MailProjectMembershipProvenance.self,
            from: provenanceData
        )

        let group = provenance.rule.flatMap { rule in
            project.ruleGroups.first { $0.id == rule.matchingGroupID }
        }
        let conditionIDs = provenance.rule?.matchingConditionIDs ?? []
        let conditions = project.ruleGroups
            .filter { candidate in
                candidate.kind == .sharedCriteria || candidate.id == group?.id
            }
            .sorted(by: provenanceGroupOrder)
            .flatMap { candidate in
                candidate.conditions
                    .filter { conditionIDs.contains($0.id) }
                    .sorted(by: conditionOrder)
            }
        let customNames = Dictionary(
            uniqueKeysWithValues: CustomMailCategoryCatalog.descriptors(in: modelContext)
                .map { ($0.key, $0.displayName) }
        )

        var messageDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        messageDescriptor.fetchLimit = 1
        let message = try modelContext.fetch(messageDescriptor).first
        let decisions = try modelContext.fetch(FetchDescriptor<MailProjectDecision>(
            predicate: #Predicate { $0.projectID == projectID }
        ))
        let messageDecision = preferredDecision(
            decisions.filter { $0.targetKind == .message && $0.targetID == messageID }
        )
        let threadDecision: MailProjectDecision?
        if let threadID = message?.thread?.id {
            threadDecision = preferredDecision(
                decisions.filter { $0.targetKind == .thread && $0.targetID == threadID }
            )
        } else {
            threadDecision = nil
        }

        let otherMemberships = try modelContext.fetch(FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.messageID == messageID }
        )).filter { $0.projectID != projectID }
        let otherIDs = Set(otherMemberships.map(\.projectID))
        let otherProjectNames = try modelContext.fetch(FetchDescriptor<MailProject>())
            .filter { otherIDs.contains($0.id) }
            .map(\.displayName)
            .sorted { lhs, rhs in
                let left = lhs.localizedCaseInsensitiveCompare(rhs)
                return left == .orderedSame ? lhs < rhs : left == .orderedAscending
            }

        return ProjectMembershipDetailsPresentation(
            messageID: messageID,
            projectName: project.displayName,
            sourceTitle: sourceTitle(membership.source),
            winningGroupTitle: group.flatMap { groupTitle($0, in: project) },
            matchedConditions: conditions.map {
                ProjectMembershipConditionDetail(
                    id: $0.id,
                    summary: conditionSummary($0, customNames: customNames)
                )
            },
            categoryRequirementLabel: categoryRequirement(
                conditions: conditions,
                message: message,
                customNames: customNames
            ),
            messageDecisionTitle: decisionTitle(messageDecision, noun: "message"),
            threadDecisionTitle: decisionTitle(threadDecision, noun: "thread"),
            isExceptionToAutomaticRules: provenance.isExceptionToAutomaticRules,
            otherProjectNames: otherProjectNames
        )
    }

    private static func conditionOrder(
        _ lhs: MailProjectRuleCondition,
        _ rhs: MailProjectRuleCondition
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func provenanceGroupOrder(
        _ lhs: MailProjectRuleGroup,
        _ rhs: MailProjectRuleGroup
    ) -> Bool {
        let lhsIsShared = lhs.kind == .sharedCriteria
        let rhsIsShared = rhs.kind == .sharedCriteria
        if lhsIsShared != rhsIsShared { return lhsIsShared }
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func preferredDecision(
        _ decisions: [MailProjectDecision]
    ) -> MailProjectDecision? {
        decisions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }

    private static func sourceTitle(_ source: MailProjectMembershipSource) -> String {
        switch source {
        case .rule: return "Project rules"
        case .messageOverride: return "Message override"
        case .threadOverride: return "Thread override"
        }
    }

    private static func groupTitle(
        _ group: MailProjectRuleGroup,
        in project: MailProject
    ) -> String? {
        let prefix: String
        switch group.kind {
        case .match:
            prefix = "Match group"
        case .projectWideExclusion:
            prefix = "Project exclusion"
        case .sharedCriteria, .invalid:
            return nil
        }
        let peers = project.ruleGroups
            .filter { $0.kind == group.kind }
            .sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.id.uuidString < $1.id.uuidString
            }
        let index = (peers.firstIndex { $0.id == group.id } ?? 0) + 1
        return "\(prefix) \(index)"
    }

    private static func conditionSummary(
        _ condition: MailProjectRuleCondition,
        customNames: [String: String]
    ) -> String {
        let values = (try? condition.values()) ?? []
        let displayValues = values.map { displayValue($0, facet: condition.facet, customNames: customNames) }
        let valueText = displayValues.joined(separator: condition.quantifier == .all ? " and " : " or ")
        let verb = condition.polarity == .include ? "includes" : "excludes"
        return "\(facetTitle(condition)) \(verb) \(valueText)"
    }

    private static func facetTitle(_ condition: MailProjectRuleCondition) -> String {
        switch condition.facet {
        case .invalid: return "Invalid criterion"
        case .account: return "Account"
        case .correspondent:
            switch condition.correspondentRole ?? .involves {
            case .from: return "From correspondent"
            case .to: return "To correspondent"
            case .cc: return "Cc correspondent"
            case .bcc: return "Bcc correspondent"
            case .involves: return "Correspondent"
            }
        case .mailingList: return "Mailing list"
        case .fixedCategory: return "Category"
        case .customCategory: return "Custom category"
        case .semanticTag: return "Tag"
        case .language: return "Language"
        case .subject: return "Subject"
        case .body: return "Body"
        case .attachmentFilename: return "Attachment filename"
        case .attachmentText: return "Attachment text"
        }
    }

    private static func displayValue(
        _ value: String,
        facet: MailProjectRuleFacet,
        customNames: [String: String]
    ) -> String {
        switch facet {
        case .fixedCategory:
            return MailPurpose(rawValue: value)?.displayLabel ?? value
        case .customCategory:
            return customNames[value] ?? value
        default:
            return value
        }
    }

    private static func categoryRequirement(
        conditions: [MailProjectRuleCondition],
        message: Message?,
        customNames: [String: String]
    ) -> String? {
        let purpose = MailClassificationJSON.decode(message?.analysis?.mailClassificationJSON)?.purpose?.rawValue
        let customKeys = Set(CustomCategoryKeysJSON.decode(message?.analysis?.customCategoryKeysJSON))
        for condition in conditions where condition.polarity == .include {
            let values = (try? condition.values()) ?? []
            switch condition.facet {
            case .fixedCategory:
                let selected = values.first { $0 == purpose } ?? values.first
                if let selected {
                    return displayValue(selected, facet: .fixedCategory, customNames: customNames)
                }
            case .customCategory:
                let selected = values.first { customKeys.contains($0) } ?? values.first
                if let selected {
                    return displayValue(selected, facet: .customCategory, customNames: customNames)
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func decisionTitle(
        _ decision: MailProjectDecision?,
        noun: String
    ) -> String? {
        guard let decision else { return nil }
        return decision.decision == .include
            ? "Include this \(noun)"
            : "Exclude this \(noun)"
    }
}

struct ProjectMembershipDetailsView: View {
    let details: ProjectMembershipDetailsPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var showsOtherProjects = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ComposerSectionHeader(title: "Membership Details", symbolName: "folder.badge.questionmark")
                Spacer()
                Button("Done", systemImage: "checkmark") { dismiss() }
                    .buttonStyle(.emblem)
            }
            .padding(16)

            Divider().overlay(OhiaColors.glassBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailSection("Included by") {
                        Text(details.sourceTitle)
                        Text(details.isExceptionToAutomaticRules
                            ? "Manual exception to the automatic rules"
                            : "Matches the automatic rules")
                            .foregroundStyle(details.isExceptionToAutomaticRules
                                ? OhiaColors.ohiaYellow
                                : OhiaColors.textSecondary)
                    }

                    if details.winningGroupTitle != nil || !details.matchedConditions.isEmpty {
                        detailSection("Winning rule") {
                            if let title = details.winningGroupTitle {
                                Text(title).fontWeight(.semibold)
                            }
                            ForEach(details.matchedConditions) { condition in
                                Label(condition.summary, systemImage: "checkmark.circle")
                            }
                        }
                    }

                    if details.messageDecisionTitle != nil || details.threadDecisionTitle != nil {
                        detailSection("Manual decisions") {
                            if let title = details.messageDecisionTitle {
                                Label(title, systemImage: "envelope.badge")
                            }
                            if let title = details.threadDecisionTitle {
                                Label(title, systemImage: "rectangle.stack.badge.person.crop")
                            }
                        }
                    }

                    if !details.otherProjectNames.isEmpty {
                        DisclosureGroup(
                            "Also in \(details.otherProjectNames.count) other project\(details.otherProjectNames.count == 1 ? "" : "s")",
                            isExpanded: $showsOtherProjects
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(details.otherProjectNames, id: \.self) { name in
                                    Text(name)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding(14)
                        .background(OhiaColors.composerPanelBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 460)
        .background(OhiaColors.spaceBackground)
        .environment(\.colorScheme, .dark)
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OhiaColors.textTertiary)
            content()
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OhiaColors.composerPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
