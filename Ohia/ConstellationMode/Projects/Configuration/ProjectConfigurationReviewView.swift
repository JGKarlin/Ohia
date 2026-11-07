import SwiftUI
import OhiaCore
import OhiaML

struct ProjectConfigurationReviewView: View {
    @Bindable var state: ProjectConfigurationState
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ProjectConfigurationHealthView(state: state)

                if let preview = state.preview {
                    if let warning = preview.broadRuleWarning {
                        broadWarning(warning)
                    }
                    automaticTotals(preview.exactMatchCount)
                    reviewSearch
                    ProjectMembershipPreviewView(state: state, searchText: searchText)
                } else {
                    membershipPreviewBlocked
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var reviewSearch: some View {
        OhiaSettingsCard("Search Review") {
            SettingsBlock {
                TextField(
                    "Search message, source, condition, or exception status",
                    text: $searchText
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search Review")
                Text("Search filters only the review rows. It does not change the preview or project rules.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
    }

    private func automaticTotals(_ exactMatchCount: Int) -> some View {
        OhiaSettingsCard("Automatic Match Totals") {
            SettingsBlock {
                HStack(spacing: 12) {
                    Text("Exact automatic matches")
                        .foregroundStyle(OhiaColors.textPrimary)
                    Spacer(minLength: 12)
                    Text("\(exactMatchCount)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.textPrimary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Exact automatic matches")
                .accessibilityValue("\(exactMatchCount)")
            }
        }
    }

    private func broadWarning(_ warning: MailProjectBroadRuleWarning) -> some View {
        OhiaSettingsCard("Broad Rule Warning") {
            SettingsBlock {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OhiaColors.frameUrgencyMid)
                        .accessibilityHidden(true)
                    Text("These rules automatically match \(warning.exactMatchCount) of \(warning.eligibleMessageCount) eligible messages.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
            ForEach(warning.reasons, id: \.self) { reason in
                SettingsRowDivider()
                SettingsBlock {
                    Label(reasonCopy(reason), systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
        }
    }

    private var membershipPreviewBlocked: some View {
        OhiaSettingsCard("Membership Preview") {
            SettingsBlock {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.ohiaRed)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Membership preview blocked")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OhiaColors.textPrimary)
                        Text("Configuration Health lists what must be corrected before this project can be created or saved.")
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textSecondary)
                    }
                }
            }
        }
    }

    private func reasonCopy(_ reason: MailProjectBroadRuleReason) -> String {
        switch reason {
        case .exclusionOnlyGroup:
            "A group contains exclusions without a positive condition."
        case .singlePositiveCondition:
            "A group depends on only one positive condition."
        case .matchesAllEligibleMessages:
            "The rules match every eligible message in the selected accounts."
        }
    }
}

struct ProjectConfigurationHealthView: View {
    @Bindable var state: ProjectConfigurationState

    var body: some View {
        OhiaSettingsCard("Configuration Health") {
            if state.saveStatus == .reviewRequired {
                SettingsBlock {
                    Label("Membership preview refreshed", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
                SettingsRowDivider()
            }

            if let report = state.validationReport {
                SettingsBlock {
                    statusRow(
                        title: report.isValid
                            ? "Configuration is valid"
                            : "Configuration must be corrected",
                        isHealthy: report.isValid,
                        issueCount: report.issues.count
                    )
                    if report.isValid {
                        Text("Membership preview is current.")
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textSecondary)
                    } else {
                        Text("Automatic matching cannot be reviewed until these issues are repaired. Return to Configure to correct them.")
                            .font(.caption)
                            .foregroundStyle(OhiaColors.textSecondary)
                    }
                }
                ForEach(report.issues) { issue in
                    SettingsRowDivider()
                    validationIssue(issue)
                }
            } else if let preview = state.preview {
                SettingsBlock {
                    statusRow(
                        title: preview.health.projectConfigurationTitle,
                        isHealthy: preview.health == .healthy,
                        issueCount: nil
                    )
                }
            } else {
                SettingsBlock {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cross.case")
                            .font(.system(size: 12))
                            .foregroundStyle(OhiaColors.textTertiary)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review not available")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OhiaColors.textPrimary)
                            Text("Return to Configure and review the project again.")
                                .font(.caption)
                                .foregroundStyle(OhiaColors.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func validationIssue(_ issue: MailProjectValidationIssue) -> some View {
        SettingsBlock {
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.code.projectConfigurationCopy)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.ohiaRed)
                if let value = issue.invalidValue {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
        }
    }

    private func statusRow(
        title: String,
        isHealthy: Bool,
        issueCount: Int?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isHealthy
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(isHealthy ? OhiaColors.ohiaGreen : OhiaColors.ohiaRed)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OhiaColors.textPrimary)
            Spacer(minLength: 8)
            if let issueCount, issueCount > 0 {
                Text("\(issueCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        }
    }
}
