// Ohia/Composer/ComposerEvidenceFooterBar.swift
// Compact Composer grounding ledger beside the shared live Activity Strip.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

struct ComposerEvidenceFooterBar: View {
    @Environment(\.modelContext) private var modelContext

    let sources: [ComposerSource]
    let sourceContextTokenCount: Int?
    let sourceContextTokenLimit: Int?
    /// True while the worker owes a measurement of the source list. A count
    /// that is missing without one pending could not be measured, so the
    /// meter is hidden rather than left spinning.
    let isMeasuringSourceContext: Bool

    var body: some View {
        GeometryReader { proxy in
            let activityWidth = proxy.size.width / 2
            let groundingWidth = max(0, proxy.size.width - activityWidth - 1)

            HStack(spacing: 0) {
                groundingLedger
                    .frame(width: groundingWidth, height: proxy.size.height, alignment: .leading)
                    .clipped()

                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(width: 1, height: 30)

                ActivityStripView(mode: .composer)
                    .frame(width: activityWidth, height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 57)
        .background(OhiaColors.composerPanelBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
    }

    private var groundingLedger: some View {
        let categories = presentCategories
        let threadCount = groundedThreadCount
        let messagesSummary = ComposerMessagesEvidenceSummary(sources: sources)

        return HStack(spacing: 0) {
            sectionLabel("Grounding")
                .padding(.trailing, 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    groundingItem(title: "total", value: sources.count, color: OhiaColors.ohiaGreen)
                    if !categories.isEmpty {
                        groundingDivider
                    }
                    ForEach(categories) { category in
                        if category.id == GroundingBucket.emails.rawValue, threadCount > 0 {
                            groundingConversationItem(
                                threadCount: threadCount,
                                emailCount: category.count,
                                compact: false
                            )
                        } else if category.id == GroundingBucket.messages.rawValue,
                                  let messagesSummary {
                            groundingMessagesItem(messagesSummary)
                        } else {
                            ComposerEvidenceLedgerToken(
                                title: category.title,
                                value: category.count,
                                color: category.color
                            )
                        }
                    }
                    if hasSourceContextUsage {
                        groundingDivider
                        sourceContextUsageItem
                    }
                }

                HStack(spacing: 10) {
                    compactGroundingItem(value: sources.count, color: OhiaColors.ohiaGreen, label: "total")
                    if !categories.isEmpty {
                        groundingDivider
                    }
                    ForEach(categories) { category in
                        if category.id == GroundingBucket.emails.rawValue, threadCount > 0 {
                            groundingConversationItem(
                                threadCount: threadCount,
                                emailCount: category.count,
                                compact: true
                            )
                        } else if category.id == GroundingBucket.messages.rawValue,
                                  let messagesSummary {
                            groundingMessagesItem(messagesSummary)
                        } else {
                            compactGroundingItem(
                                value: category.count,
                                color: category.color,
                                label: category.title
                            )
                        }
                    }
                    if hasSourceContextUsage {
                        groundingDivider
                        sourceContextUsageItem
                    }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
    }

    private var sourceContextUsageText: String? {
        guard let sourceContextTokenCount,
              let sourceContextTokenLimit,
              sourceContextTokenCount >= 0,
              sourceContextTokenLimit > 0 else {
            return nil
        }
        return ComposerSourceContextUsagePresentation.text(
            tokenCount: sourceContextTokenCount,
            tokenLimit: sourceContextTokenLimit
        )
    }

    private var hasSourceContextUsage: Bool {
        guard let sourceContextTokenLimit, sourceContextTokenLimit > 0 else { return false }
        return sourceContextTokenCount != nil || isMeasuringSourceContext
    }

    private var sourceContextUsageItem: some View {
        HStack(spacing: 12) {
            sectionLabel("Context")
            if let sourceContextUsageText {
                sourceContextUsageTextLabel(sourceContextUsageText)
            } else if let sourceContextTokenLimit {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(OhiaColors.textSecondary)
                    sourceContextUsageTextLabel(
                        ComposerSourceContextUsagePresentation.limitText(
                            tokenLimit: sourceContextTokenLimit
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sourceContextAccessibilityLabel)
        .help("The draft writer's prompt with every selected source, against the writer's limit. Over the limit, automatic sources are left out of the draft.")
    }

    private func sourceContextUsageTextLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(OhiaColors.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var sourceContextAccessibilityLabel: String {
        if let sourceContextUsageText {
            return "Context, \(sourceContextUsageText)"
        }
        guard let sourceContextTokenLimit else { return "Context updating" }
        return "Context updating, \(ComposerSourceContextUsagePresentation.limitText(tokenLimit: sourceContextTokenLimit))"
    }

    private func sectionLabel(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 9))
            .tracking(1.0)
            .foregroundStyle(OhiaColors.textTertiary)
            .fixedSize()
            .layoutPriority(3)
    }

    /// Buckets each source's kind via `GroundingBucket.of(_:)` — an exhaustive
    /// switch, so a newly-added `ComposerSource.Kind` fails to compile until it is
    /// assigned a bucket and can never silently escape the breakdown. Buckets
    /// render in `allCases` order and partition the source list. Messages uses
    /// that bucket for presence and ordering, then presents its transcript-row
    /// and people counts instead of the internal source-object count.
    private var presentCategories: [EvidenceCategory] {
        var counts: [GroundingBucket: Int] = [:]
        for source in sources {
            counts[GroundingBucket.of(source.kind), default: 0] += 1
        }
        return GroundingBucket.allCases.compactMap { bucket in
            let value = counts[bucket] ?? 0
            guard value > 0 else { return nil }
            return EvidenceCategory(
                id: bucket.rawValue,
                title: bucket.title,
                count: value,
                color: bucket.color
            )
        }
    }

    /// Distinct conversations represented by the email-backed grounding
    /// sources. This is an overlapping structural count, not another source
    /// bucket, so it never contributes to Total.
    private var groundedThreadCount: Int {
        let messageIDs = ComposerEvidenceThreadCounter.backingMessageIDs(in: sources)
        guard !messageIDs.isEmpty else { return 0 }

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { messageIDs.contains($0.id) }
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        let threadIDByMessageID = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
            message.thread.map { (message.id, $0.id) }
        })
        return ComposerEvidenceThreadCounter.count(
            sources: sources,
            threadIDByMessageID: threadIDByMessageID
        )
    }

    private func groundingItem(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            GroundingActivityDot(color: color)
            Text(title)
                .foregroundStyle(OhiaColors.textSecondary)
            Text("\(value)")
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) sources")
        .help("\(title.capitalized): \(value) grounding sources")
    }

    private var groundingDivider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 1, height: 30)
            .accessibilityHidden(true)
    }

    private func compactGroundingItem(
        value: Int,
        color: Color,
        label: String
    ) -> some View {
        HStack(spacing: 4) {
            GroundingActivityDot(color: color)
            Text("\(value)")
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value) sources")
        .help("\(label.capitalized): \(value) grounding sources")
    }

    private func groundingConversationItem(
        threadCount: Int,
        emailCount: Int,
        compact: Bool
    ) -> some View {
        let threadNoun = threadCount == 1 ? "thread" : "threads"
        let emailNoun = emailCount == 1 ? "email" : "emails"

        return HStack(spacing: compact ? 4 : 6) {
            GroundingActivityDot(color: OhiaColors.chipActiveForeground)
            Text(compact
                 ? "\(threadCount) / \(emailCount)"
                 : "\(emailCount) \(emailNoun) (\(threadCount) \(threadNoun))")
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(emailCount) grounded \(emailNoun) across \(threadCount) \(threadNoun)")
        .help("\(emailCount) grounded \(emailNoun) (\(threadCount) \(threadNoun))")
    }

    private func groundingMessagesItem(
        _ summary: ComposerMessagesEvidenceSummary
    ) -> some View {
        HStack(spacing: 6) {
            GroundingActivityDot(color: OhiaColors.chipActiveForeground)
            Text(summary.displayText)
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityText)
        .help(summary.accessibilityText)
    }
}

struct ComposerMessagesEvidenceSummary: Equatable {
    let messageCount: Int
    let peopleCount: Int

    init?(sources: [ComposerSource]) {
        let messageSources = sources.filter { $0.kind == .messages }
        guard !messageSources.isEmpty,
              messageSources.allSatisfy({ $0.transcriptMessageCount != nil }) else {
            return nil
        }
        messageCount = messageSources.reduce(0) {
            $0 + max(0, $1.transcriptMessageCount ?? 0)
        }
        peopleCount = messageSources.count
    }

    var displayText: String {
        "\(messageCount) \(messageCount == 1 ? "text" : "texts") "
            + "(\(peopleCount) \(peopleCount == 1 ? "person" : "people"))"
    }

    var accessibilityText: String {
        "\(messageCount) grounded \(messageCount == 1 ? "text" : "texts") "
            + "across \(peopleCount) \(peopleCount == 1 ? "person" : "people")"
    }
}

enum ComposerSourceContextUsagePresentation {
    static func text(
        tokenCount: Int,
        tokenLimit: Int,
        locale: Locale = .current
    ) -> String {
        "\(formatted(tokenCount, locale: locale)) / "
            + "\(formatted(tokenLimit, locale: locale)) tokens"
    }

    static func limitText(
        tokenLimit: Int,
        locale: Locale = .current
    ) -> String {
        "/ \(formatted(tokenLimit, locale: locale)) tokens"
    }

    private static func formatted(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

enum ComposerEvidenceThreadCounter {
    static func backingMessageIDs(in sources: [ComposerSource]) -> [UUID] {
        Array(Set(sources.compactMap { source in
            guard GroundingBucket.of(source.kind) == .emails else { return nil }
            return source.messageID
        }))
    }

    static func count(
        sources: [ComposerSource],
        threadIDByMessageID: [UUID: UUID]
    ) -> Int {
        Set(backingMessageIDs(in: sources).map { messageID in
            threadIDByMessageID[messageID] ?? messageID
        }).count
    }
}

private struct ComposerEvidenceLedgerToken: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            GroundingActivityDot(color: color)
            Text(title)
                .foregroundStyle(OhiaColors.textSecondary)
            Text("\(value)")
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) sources")
        .help("\(title.capitalized): \(value) grounding sources")
    }
}

private struct GroundingActivityDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.75), radius: 2)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

private struct EvidenceCategory: Identifiable {
    let id: String
    let title: String
    let count: Int
    let color: Color
}

/// The grounding-ledger buckets. Every `ComposerSource.Kind` maps to exactly one
/// via the exhaustive `of(_:)` switch, so the per-bucket counts partition the
/// source list and always sum to the total. Threads are an overlapping
/// structural count rendered separately and never enter this partition.
/// Adding a new `Kind` is a compile error here until it's bucketed — the
/// counter can never silently under-count. The Messages bucket is displayed
/// as transcript rows across people rather than as its source-object count.
private enum GroundingBucket: String, CaseIterable {
    case emails, web, files, calendar, contacts, notes, messages, memory

    static func of(_ kind: ComposerSource.Kind) -> GroundingBucket {
        switch kind {
        case .threadState, .thread, .pastReply, .retrieved, .email: return .emails
        case .website, .mcp: return .web
        case .attachment, .file, .screenshot: return .files
        case .calendar: return .calendar
        case .contact: return .contacts
        case .note, .notesApp: return .notes
        case .messages: return .messages
        case .memory: return .memory
        }
    }

    var color: Color {
        switch self {
        case .emails: return OhiaColors.chipActiveForeground
        case .web: return OhiaColors.ohiaGreen
        case .files: return OhiaColors.accentOrange
        case .calendar: return OhiaColors.accentPurple
        case .contacts: return OhiaColors.accentPink
        case .notes: return OhiaColors.ohiaYellow
        case .messages: return OhiaColors.chipActiveForeground
        case .memory: return OhiaColors.ohiaGreen
        }
    }

    var title: String {
        switch self {
        case .emails: return "emails"
        case .web: return "web"
        case .files: return "files"
        case .calendar: return "calendar"
        case .contacts: return "contacts"
        case .notes: return "notes"
        case .messages: return "texts"
        case .memory: return "memory"
        }
    }
}
