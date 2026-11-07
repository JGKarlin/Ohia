import SwiftUI
import OhiaCore
import OhiaML

struct ProjectConfigurationReviewPresentation: Equatable, Sendable {
    let exactAutomaticMatchCount: Int
    let sections: [ProjectConfigurationReviewSectionPresentation]

    static func make(
        preview: MailProjectPreview,
        searchText: String,
        messagesByID: [UUID: ProjectHistoricalSearchResult]
    ) -> Self {
        Self(
            exactAutomaticMatchCount: preview.exactMatchCount,
            sections: [
                ProjectConfigurationReviewSectionPresentation.make(
                    title: "Will Be Added",
                    memberships: preview.willBeAdded,
                    searchText: searchText,
                    messagesByID: messagesByID
                ),
                ProjectConfigurationReviewSectionPresentation.make(
                    title: "Will Be Removed",
                    memberships: preview.willBeRemoved,
                    searchText: searchText,
                    messagesByID: messagesByID
                ),
                ProjectConfigurationReviewSectionPresentation.make(
                    title: "Unchanged Exceptions",
                    memberships: preview.unchangedExceptions,
                    searchText: searchText,
                    messagesByID: messagesByID
                ),
            ]
        )
    }
}

struct ProjectConfigurationReviewSectionPresentation: Equatable, Sendable {
    let title: String
    let totalCount: Int
    let memberships: [MailProjectPreviewMembership]

    static func make(
        title: String,
        memberships: [MailProjectPreviewMembership],
        searchText: String,
        messagesByID: [UUID: ProjectHistoricalSearchResult]
    ) -> Self {
        let normalizedSearch = normalized(searchText)
        return Self(
            title: title,
            totalCount: memberships.count,
            memberships: normalizedSearch.isEmpty
                ? memberships
                : memberships.filter {
                    let semantics = ProjectConfigurationReviewMembershipSemantics.make(
                        membership: $0
                    )
                    let exactTerms = [title] + semantics.searchTerms
                    if ProjectConfigurationReviewMembershipSemantics.exactSearchPhrases
                        .contains(where: { normalized($0) == normalizedSearch }) {
                        return exactTerms.contains {
                            normalized($0) == normalizedSearch
                        }
                    }
                    return normalized(searchableText(
                        for: $0,
                        message: messagesByID[$0.messageID],
                        sectionTitle: title
                    )).contains(normalizedSearch)
                }
        )
    }

    private static func searchableText(
        for membership: MailProjectPreviewMembership,
        message: ProjectHistoricalSearchResult?,
        sectionTitle: String
    ) -> String {
        let conditions = (membership.ruleDetails?.sharedConditions ?? [])
            + (membership.ruleDetails?.pathConditions ?? [])
        let semantics = ProjectConfigurationReviewMembershipSemantics.make(
            membership: membership
        )
        return [
            message?.subject ?? "",
            message?.correspondent ?? "",
            membership.messageID.uuidString,
            sectionTitle,
            membership.source.rawValue,
            semantics.winningSource,
            semantics.manualExceptionStatus,
            conditions.flatMap { condition in
                [
                    condition.facet.projectConfigurationTitle,
                    condition.polarity.projectConfigurationTitle,
                    condition.quantifier.projectConfigurationTitle,
                ] + condition.values
            }.joined(separator: " "),
        ].joined(separator: " ")
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

struct ProjectConfigurationReviewMembershipSemantics: Equatable, Sendable {
    let winningSource: String
    let manualExceptionStatus: String

    var searchTerms: [String] {
        [winningSource, manualExceptionStatus]
    }

    static let exactSearchPhrases = [
        Copy.manualMessageInclusion,
        Copy.manualThreadInclusion,
        Copy.automaticRule,
        Copy.manualException,
        Copy.noManualException,
        Copy.manualDecisionAgrees,
        "Will Be Added",
        "Will Be Removed",
        "Unchanged Exceptions",
    ]

    static func make(
        membership: MailProjectPreviewMembership
    ) -> Self {
        let winningSource = switch membership.source {
        case .messageOverride: Copy.manualMessageInclusion
        case .threadOverride: Copy.manualThreadInclusion
        case .rule: Copy.automaticRule
        }
        let manualExceptionStatus: String
        if membership.provenance.isExceptionToAutomaticRules {
            manualExceptionStatus = Copy.manualException
        } else if membership.source == .rule {
            manualExceptionStatus = Copy.noManualException
        } else {
            manualExceptionStatus = Copy.manualDecisionAgrees
        }
        return Self(
            winningSource: winningSource,
            manualExceptionStatus: manualExceptionStatus
        )
    }

    private enum Copy {
        static let manualMessageInclusion = "Manual message inclusion"
        static let manualThreadInclusion = "Manual thread inclusion"
        static let automaticRule = "Automatic rule"
        static let manualException = "Manual exception to automatic rules"
        static let noManualException = "No manual exception"
        static let manualDecisionAgrees = "Manual decision agrees with automatic rules"
    }
}

struct ProjectConfigurationReviewRowPresentation: Equatable, Sendable, Identifiable {
    let messageID: UUID
    let identityTitle: String
    let identityDetail: String
    let winningSource: String
    let sharedConditions: String
    let pathConditions: String
    let manualExceptionStatus: String

    var id: UUID { messageID }

    var searchableText: String {
        [
            identityTitle,
            identityDetail,
            winningSource,
            sharedConditions,
            pathConditions,
            manualExceptionStatus,
        ].joined(separator: " ")
    }

    static func make(
        membership: MailProjectPreviewMembership,
        message: ProjectHistoricalSearchResult?
    ) -> Self {
        let semantics = ProjectConfigurationReviewMembershipSemantics.make(
            membership: membership
        )

        return Self(
            messageID: membership.messageID,
            identityTitle: message?.subject ?? "Message",
            identityDetail: [message?.correspondent, membership.messageID.uuidString]
                .compactMap { $0 }
                .joined(separator: " · "),
            winningSource: semantics.winningSource,
            sharedConditions: sharedConditions(for: membership),
            pathConditions: pathConditions(for: membership),
            manualExceptionStatus: semantics.manualExceptionStatus
        )
    }

    private static func sharedConditions(
        for membership: MailProjectPreviewMembership
    ) -> String {
        guard membership.provenance.rule != nil else { return "No shared conditions" }
        guard let details = membership.ruleDetails else {
            return "Rule provenance unavailable"
        }
        switch details.sharedKind {
        case .none:
            return details.configuration == .committed
                ? "No previous shared conditions"
                : "No shared conditions"
        case .matched:
            return ProjectCriteriaSummary.text(
                for: details.sharedConditions.map(ProjectRuleConditionDraft.init)
            )
        case .unavailable:
            return details.configuration == .committed
                ? "Previous shared-rule provenance unavailable"
                : "Shared-rule provenance unavailable"
        }
    }

    private static func pathConditions(
        for membership: MailProjectPreviewMembership
    ) -> String {
        guard membership.provenance.rule != nil else { return "No automatic path" }
        guard let details = membership.ruleDetails else {
            return "Rule provenance unavailable"
        }
        switch details.pathKind {
        case .matchedGroup:
            let summary = ProjectCriteriaSummary.text(
                for: details.pathConditions.map(ProjectRuleConditionDraft.init)
            )
            return details.configuration == .committed
                ? "Previous rule path · \(summary)"
                : summary
        case .accountWide:
            return details.configuration == .committed
                ? "Previous account-wide automatic path"
                : "Account-wide automatic path"
        case .unavailable:
            return details.configuration == .committed
                ? "Previous rule-path provenance unavailable"
                : "Rule-path provenance unavailable"
        }
    }
}

struct ProjectMembershipPreviewView: View {
    @Bindable var state: ProjectConfigurationState
    let searchText: String

    var body: some View {
        if let preview = state.preview {
            let presentation = ProjectConfigurationReviewPresentation.make(
                preview: preview,
                searchText: searchText,
                messagesByID: state.previewMessagesByID
            )
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(presentation.sections.enumerated(), id: \.element.title) {
                    index, section in
                    membershipSection(
                        section,
                        symbolName: ["plus.circle", "minus.circle", "hand.raised.circle"][index]
                    )
                }
            }
        } else {
            OhiaSettingsCard("Membership Preview") {
                SettingsBlock {
                    Label("Preview not prepared", systemImage: "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.textPrimary)
                    Text("Review the project to validate its rules and calculate exact membership changes.")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func membershipSection(
        _ section: ProjectConfigurationReviewSectionPresentation,
        symbolName: String
    ) -> some View {
        OhiaSettingsCard(section.title) {
            SettingsBlock {
                HStack(spacing: 10) {
                    Image(systemName: symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(sectionCountCopy(section))
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
            SettingsRowDivider()
            if section.memberships.isEmpty {
                SettingsCaption(section.totalCount == 0
                    ? "No messages"
                    : "No messages match this search")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(section.memberships.enumerated(), id: \.element.messageID) {
                        index, membership in
                        VStack(spacing: 0) {
                            if index > 0 { SettingsRowDivider() }
                            ProjectPreviewMembershipRow(row: .make(
                                membership: membership,
                                message: state.previewMessage(membership.messageID)
                            ))
                        }
                    }
                }
            }
        }
    }

    private func sectionCountCopy(
        _ section: ProjectConfigurationReviewSectionPresentation
    ) -> String {
        let visibleCount = section.memberships.count
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "\(visibleCount) of \(section.totalCount) messages shown"
        }
        return section.totalCount == 1 ? "1 message" : "\(section.totalCount) messages"
    }
}

private struct ProjectPreviewMembershipRow: View {
    let row: ProjectConfigurationReviewRowPresentation

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                detail(title: "Winning source", value: row.winningSource)
                detail(title: "Shared conditions", value: row.sharedConditions)
                detail(title: "Path conditions", value: row.pathConditions)
                detail(title: "Manual exception", value: row.manualExceptionStatus)
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.identityTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(2)
                Text(row.identityDetail)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .tint(OhiaColors.chipActiveForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.searchableText)
    }

    private func detail(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OhiaColors.textSecondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(OhiaColors.textTertiary)
        }
    }
}
