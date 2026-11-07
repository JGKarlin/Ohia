import SwiftUI
import OhiaCore
import OhiaML

struct ProjectExplicitMembershipPresentation: Equatable, Sendable {
    let pageTitle: String
    let includedSectionTitle: String
    let excludedSectionTitle: String
    let includeActionTitle: String
    let excludeActionTitle: String
    let includeActionSymbol: String
    let excludeActionSymbol: String

    static func make(targetKind: MailProjectDecisionTargetKind) -> Self {
        let noun = targetKind == .thread ? "Thread" : "Message"
        let isThread = targetKind == .thread
        return Self(
            pageTitle: "\(noun)s",
            includedSectionTitle: "Included \(noun)s",
            excludedSectionTitle: "Excluded \(noun)s",
            includeActionTitle: isThread ? "Include" : "Include \(noun)",
            excludeActionTitle: isThread ? "Exclude" : "Exclude \(noun)",
            includeActionSymbol: "plus.circle",
            excludeActionSymbol: "minus.circle"
        )
    }
}

struct ProjectExplicitMembershipView: View {
    @Bindable var state: ProjectConfigurationState
    let targetKind: MailProjectDecisionTargetKind

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                searchCard

                if state.historicalSearchQuery.isEmpty == false {
                    searchResultsCard
                }

                decisionCard(value: .include)
                decisionCard(value: .exclude)
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var explanation: String {
        if targetKind == .thread {
            return "Included threads add their current and future messages. Excluded threads remove their messages and block future replies. Both override the automatic account, correspondent, and rule scope."
        }
        return "Included and excluded messages are the most specific project decisions. They override thread choices and the automatic account, correspondent, and rule scope."
    }

    private var searchCard: some View {
        OhiaSettingsCard(presentation.pageTitle) {
            SettingsBlock {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: targetSymbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(decisions.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            SettingsRowDivider()
            SettingsBlock {
                Text("Find \(targetKind == .thread ? "Threads" : "Messages")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.textPrimary)
                HStack(spacing: 8) {
                    TextField(
                        "Search by subject, correspondent, participant, or thread",
                        text: $state.historicalSearchQuery
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await state.searchHistoricalMail(query: state.historicalSearchQuery) }
                    }
                    Button("Search", systemImage: "magnifyingglass") {
                        Task { await state.searchHistoricalMail(query: state.historicalSearchQuery) }
                    }
                    .buttonStyle(.emblem)
                }
                Text("Search uses the complete stored mailbox inside Account Scope and never creates a rule.")
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
    }

    private var searchResultsCard: some View {
        OhiaSettingsCard("Search Results") {
            if displayedSearchTargets.isEmpty {
                SettingsBlock {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(OhiaColors.textTertiary)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No matching \(targetKind == .thread ? "threads" : "messages")")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OhiaColors.textPrimary)
                            Text("Try another subject, correspondent, participant, or thread term.")
                                .font(.caption)
                                .foregroundStyle(OhiaColors.textSecondary)
                        }
                    }
                }
            } else {
                ForEach(Array(displayedSearchTargets.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { SettingsRowDivider() }
                    searchResultRow(target)
                }
            }
        }
    }

    private func searchResultRow(_ target: ExplicitSearchTarget) -> some View {
        let currentValue = decisions.first(where: { $0.targetID == target.id })?.decision
        return SettingsBlock {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(2)
                    Text(target.detail)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .lineLimit(1)
                    Text(Self.dateFormatter.string(from: target.date))
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                Spacer(minLength: 8)
                Button {
                    apply(.include, to: target.id)
                } label: {
                    actionLabel(for: .include)
                }
                .buttonStyle(.emblem)
                .disabled(currentValue == .include)
                Button {
                    apply(.exclude, to: target.id)
                } label: {
                    actionLabel(for: .exclude)
                }
                .buttonStyle(.emblem)
                .disabled(currentValue == .exclude)
            }
        }
    }

    private func decisionCard(value: MailProjectDecisionValue) -> some View {
        let matching = decisions.filter { $0.decision == value }
        let isIncluded = value == .include
        return OhiaSettingsCard(
            isIncluded
                ? presentation.includedSectionTitle
                : presentation.excludedSectionTitle
        ) {
            SettingsBlock {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isIncluded ? "checkmark.circle" : "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(isIncluded ? includedColumnCopy : excludedColumnCopy)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(matching.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            SettingsRowDivider()
            if matching.isEmpty {
                SettingsCaption("No explicitly \(isIncluded ? "included" : "excluded") \(targetKind == .thread ? "threads" : "messages")")
            } else {
                ForEach(Array(matching.enumerated()), id: \.element.id) { index, decision in
                    if index > 0 { SettingsRowDivider() }
                    decisionRow(decision)
                }
            }
        }
    }

    private var includedColumnCopy: String {
        targetKind == .thread
            ? "These threads are followed even when they do not match automatic rules."
            : "These messages stay in the project as explicit inclusions."
    }

    private var excludedColumnCopy: String {
        targetKind == .thread
            ? "These threads are blocked even when automatic rules would include them."
            : "These messages stay out of the project as explicit exclusions."
    }

    private func decisionRow(_ decision: MailProjectDecisionSnapshot) -> some View {
        let decisionPresentation = state.decisionPresentation(for: decision)
        return SettingsBlock {
            HStack(spacing: 9) {
                Image(systemName: decision.decision == .include
                    ? "checkmark.circle.fill"
                    : "minus.circle.fill")
                    .foregroundStyle(decision.decision == .include
                        ? OhiaColors.ohiaGreen
                        : OhiaColors.ohiaRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(decisionPresentation?.title ?? "Unavailable \(targetKind == .thread ? "Thread" : "Message")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(2)
                    Text(decisionPresentation?.detail ?? decision.targetID.uuidString)
                        .font(.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    apply(decision.decision == .include ? .exclude : .include, to: decision.targetID)
                } label: {
                    actionLabel(for: decision.decision == .include ? .exclude : .include)
                }
                .buttonStyle(.emblem)
                Button("Remove", systemImage: "trash") {
                    state.removeDecision(decision.id)
                }
                .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
            }
        }
    }

    private var targetSymbolName: String {
        targetKind == .thread
            ? "point.3.connected.trianglepath.dotted"
            : "envelope.badge"
    }

    private var decisions: [MailProjectDecisionSnapshot] {
        (state.draft?.manualDecisions ?? [])
            .filter { $0.targetKind == targetKind }
            .sorted { lhs, rhs in
                if lhs.decision.rawValue != rhs.decision.rawValue {
                    return lhs.decision.rawValue < rhs.decision.rawValue
                }
                return lhs.targetID.uuidString < rhs.targetID.uuidString
            }
    }

    private var presentation: ProjectExplicitMembershipPresentation {
        .make(targetKind: targetKind)
    }

    private func actionLabel(for value: MailProjectDecisionValue) -> some View {
        let title = value == .include
            ? presentation.includeActionTitle
            : presentation.excludeActionTitle
        let symbol = value == .include
            ? presentation.includeActionSymbol
            : presentation.excludeActionSymbol
        return Label(title, systemImage: symbol)
    }

    private var displayedSearchTargets: [ExplicitSearchTarget] {
        if targetKind == .message {
            return state.historicalSearchResults.map { result in
                ExplicitSearchTarget(
                    id: result.messageID,
                    title: result.subject,
                    detail: result.correspondent,
                    date: result.date
                )
            }
        }

        var latestByThreadID: [UUID: ProjectHistoricalSearchResult] = [:]
        for result in state.historicalSearchResults {
            guard let threadID = result.threadID else { continue }
            if let current = latestByThreadID[threadID], current.date >= result.date { continue }
            latestByThreadID[threadID] = result
        }
        return latestByThreadID.map { threadID, result in
            ExplicitSearchTarget(
                id: threadID,
                title: result.subject,
                detail: result.correspondent,
                date: result.date
            )
        }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func apply(_ value: MailProjectDecisionValue, to targetID: UUID) {
        switch (targetKind, value) {
        case (.message, .include): state.includeHistoricalMessage(targetID)
        case (.message, .exclude): state.excludeHistoricalMessage(targetID)
        case (.thread, .include): state.followHistoricalThread(targetID)
        case (.thread, .exclude): state.excludeHistoricalThread(targetID)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ExplicitSearchTarget: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let date: Date
}
