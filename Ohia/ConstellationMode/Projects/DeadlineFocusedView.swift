import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

/// The Deadlines-tab focused view — the analogue of the Projects workroom.
/// Opened by clicking a deadline row, it shows a dossier header (the deadline,
/// its countdown, reminder, resolve) over the actual emails of the deadline's
/// thread, each with its full body.
struct DeadlineFocusedView: View {
    let entry: DeadlineEntry
    @Bindable var workspace: ProjectsWorkspaceState
    let snapshot: ProjectsSnapshot
    let modelContext: ModelContext
    let messageActions: FrontPageMessageActionHandlers
    let composerDispatch: ComposerDispatchCoordinator
    let leadTime: DeadlineReminderLeadTime
    let calendarStatus: DeadlineCalendarSyncStatus
    let hasCalendarDateOverride: Bool
    let isCalendarSyncSuppressed: Bool
    let onSetLeadTime: (DeadlineReminderLeadTime) -> Void
    let onRestoreEmailDate: () -> Void
    let onRestoreCalendarEvent: () -> Void
    let onRequestCalendarSync: () -> Void
    let onResolve: () -> Void
    let onPresentMessageMenu: (UUID, NSPoint, NSView) -> Void

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var messages: [MessageCard] = []
    @State private var bodies: [UUID: BodyState] = [:]
    @State private var didLoad = false

    private static let feedWidth: CGFloat = 680

    enum BodyState: Equatable { case loading, loaded(String), empty }

    struct MessageCard: Identifiable, Equatable {
        let id: UUID
        let subject: String
        let fromName: String
        let fromAddress: String
        let date: Date
        let isSentByUser: Bool
        let hasAttachments: Bool
        let htmlPath: String?
        let textPath: String?
        let rawPath: String?
    }

    /// The departing (delete / resolve / send-to-Composer) gesture playing on
    /// this deadline's representative email, if any. Drives the reader's in-place
    /// Collapse / Comet — the same one the Front Page and Timeline readers use.
    private var departingGesture: MessageStatusGesture? {
        guard let gesture = workspace.statusGestureCoordinator.gesture(for: entry.representativeMessageID),
              gesture.action.usesDepartingOverlay else { return nil }
        return gesture
    }

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    VStack(spacing: 16) {
                        dossierHeader(now: context.date)
                        ForEach(messages) { card in
                            emailCard(card)
                        }
                        if messages.isEmpty && didLoad {
                            Text("The emails for this deadline are no longer in scope.")
                                .font(.system(size: 12))
                                .foregroundStyle(OhiaColors.textSecondary)
                                .padding(.top, 24)
                        }
                    }
                    .frame(maxWidth: Self.feedWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 24)
                }
            }
            // A resolve / delete / send-to-Composer on the focused deadline fades
            // the reader and lets the same inset crumble card the Front Page reader
            // uses collapse in its place.
            .opacity(departingGesture == nil ? 1 : 0)
            .allowsHitTesting(departingGesture == nil)

            if let departingGesture {
                FrontPageReaderDepartureCard(gesture: departingGesture)
            }
        }
        .background(OhiaColors.spaceBackground)
        .animation(.easeOut(duration: 0.28), value: departingGesture != nil)
        .modifier(ComposerDepartureSource(messageIDs: [entry.representativeMessageID]))
        .task(id: entry.id) { await load() }
    }

    // MARK: - Header

    private func dossierHeader(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                countdownBadge(now: now)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title.isEmpty ? "(no subject)" : entry.title)
                        .font(readingTextSize.font(base: 17, weight: .bold, maximumScale: 1.20))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(dateLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(statusColor(now: now))
                        if !entry.surfaceText.isEmpty {
                            Text("· stated as \u{201C}\(entry.surfaceText)\u{201D}")
                                .font(readingTextSize.font(base: 11, maximumScale: 1.35))
                                .foregroundStyle(OhiaColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !correspondents.isEmpty {
                        Text(correspondents)
                            .font(readingTextSize.font(base: 11.5, maximumScale: 1.35))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                reminderControl
                resolveButton
                Spacer()
                Text("\(messages.count) email\(messages.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OhiaColors.glassPanelBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
        )
    }

    private func countdownBadge(now: Date) -> some View {
        let delta = DeadlineFormatting.dayDelta(from: now, to: entry.deadlineDate)
        return VStack(spacing: 1) {
            if entry.status == .resolved {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
            } else if delta == 0 {
                Text("Today").font(.system(size: 13, weight: .bold))
            } else {
                Text("\(abs(delta))").font(.system(size: 24, weight: .bold)).monospacedDigit()
                Text(abs(delta) == 1 ? (delta < 0 ? "day ago" : "day") : (delta < 0 ? "days ago" : "days"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .textCase(.uppercase)
            }
        }
        .foregroundStyle(statusColor(now: now))
        .frame(width: 64, height: 60)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(statusColor(now: now).opacity(0.12))
        )
    }

    @ViewBuilder
    private var reminderControl: some View {
        if entry.status != .resolved {
            if calendarStatus.isSynced == false {
                Button(action: onRequestCalendarSync) {
                    Label(
                        calendarStatus == .disabled ? "Calendar off" : "Enable Calendar",
                        systemImage: "calendar.badge.plus"
                    )
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 5))
            } else if isCalendarSyncSuppressed {
                Button("Add to Calendar", systemImage: "calendar.badge.plus", action: onRestoreCalendarEvent)
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 5))
            } else {
                Menu {
                    ForEach(DeadlineReminderLeadTime.choices(hasTimeOfDay: entry.granularity == .dateTime)) { choice in
                        Button {
                            onSetLeadTime(choice)
                        } label: {
                            Label(
                                choice.title,
                                systemImage: choice == leadTime ? "checkmark" : "bell"
                            )
                        }
                    }
                    if hasCalendarDateOverride {
                        Divider()
                        Button(
                            "Restore date from email",
                            systemImage: "arrow.uturn.backward",
                            action: onRestoreEmailDate
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: leadTime == .none ? "bell.slash" : "bell.fill").font(.system(size: 10, weight: .semibold))
                        Text(leadTime == .none ? "Add reminder" : leadTime.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(leadTime == .none ? OhiaColors.textSecondary : OhiaColors.chipActiveForeground)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OhiaColors.buttonBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var resolveButton: some View {
        Button(action: onResolve) {
            HStack(spacing: 5) {
                Image(systemName: entry.isResolvedByUser ? "arrow.uturn.backward" : "checkmark").font(.system(size: 10, weight: .semibold))
                Text(entry.isResolvedByUser ? "Reopen" : "Mark resolved").font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 5))
    }

    // MARK: - Email card

    private func emailCard(_ card: MessageCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: card.isSentByUser ? "arrowshape.turn.up.right" : "tray.and.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
                Text(card.isSentByUser ? "You" : displayName(card))
                    .font(readingTextSize.font(base: 11.5, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textSecondary)
                if card.hasAttachments {
                    Image(systemName: "paperclip").font(.system(size: 9)).foregroundStyle(OhiaColors.textTertiary)
                }
                Spacer()
                Text(cardDate(card))
                    .font(readingTextSize.font(base: 10.5, maximumScale: 1.35))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            if !card.subject.isEmpty {
                Text(card.subject)
                    .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bodyView(card)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OhiaColors.glassPanelBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func bodyView(_ card: MessageCard) -> some View {
        switch bodies[card.id] {
        case .loaded(let text):
            Text(text)
                .font(readingTextSize.font(base: 13))
                .lineSpacing(readingTextSize.spacing(2))
                .foregroundStyle(OhiaColors.textPrimary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            Text("No readable body.")
                .font(readingTextSize.font(base: 11))
                .foregroundStyle(OhiaColors.textTertiary)
        case .loading, .none:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("Loading").font(.system(size: 11)).foregroundStyle(OhiaColors.textTertiary)
            }
        }
    }

    // MARK: - Formatting

    private var dateLabel: String {
        entry.granularity == .dateTime ? DeadlineFormatting.dayTimeLabel(entry.deadlineDate) : DeadlineFormatting.dayLabel(entry.deadlineDate)
    }

    private var correspondents: String {
        let names = entry.correspondents.prefix(5).map { $0.displayName ?? $0.email }
        let extra = entry.correspondents.count - names.count
        let base = names.joined(separator: ", ")
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    private func statusColor(now: Date) -> Color {
        switch entry.status {
        case .resolved: return OhiaColors.textTertiary
        case .past: return OhiaColors.ohiaRed
        case .upcoming:
            return DeadlineFormatting.dayDelta(from: now, to: entry.deadlineDate) <= 2 ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary
        }
    }

    private func displayName(_ card: MessageCard) -> String {
        let name = card.fromName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? card.fromAddress : name
    }

    private func cardDate(_ card: MessageCard) -> String {
        DeadlineFormatting.dayLabel(card.date)
    }

    // MARK: - Loading

    private func load() async {
        didLoad = false
        // Clear stale bodies so an A→B entry switch never shows A's content.
        bodies = [:]
        let repID = entry.representativeMessageID
        let cards = fetchThreadCards(representativeID: repID)
        messages = cards
        didLoad = true
        for card in cards where bodies[card.id] == nil {
            bodies[card.id] = .loading
            let html = card.htmlPath, text = card.textPath, raw = card.rawPath
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.bodyText(htmlPath: text == nil ? html : nil, textPath: text, rawPath: raw)
            }.value
            // The `.task(id:)` cancels this on an entry switch; the detached
            // work still resolves, so bail before writing a superseded body.
            if Task.isCancelled { return }
            if let loaded, !loaded.isEmpty {
                bodies[card.id] = .loaded(loaded)
            } else {
                bodies[card.id] = .empty
            }
        }
    }

    private func fetchThreadCards(representativeID: UUID) -> [MessageCard] {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == representativeID })
        descriptor.fetchLimit = 1
        guard let rep = try? modelContext.fetch(descriptor).first else { return [] }
        let threadMessages = rep.thread?.messages ?? [rep]
        let cards = threadMessages.map { message in
            MessageCard(
                id: message.id,
                subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
                fromName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? "",
                fromAddress: message.fromAddress,
                date: message.receivedAt ?? message.sentAt ?? message.ingestedAt,
                isSentByUser: message.isSentByUser,
                hasAttachments: message.hasAttachments,
                htmlPath: message.bodyHtmlPath,
                textPath: message.bodyTextPath,
                rawPath: message.rawPath
            )
        }
        return cards.sorted { $0.date > $1.date }
    }

    nonisolated private static func bodyText(htmlPath: String?, textPath: String?, rawPath: String?) -> String? {
        guard case .loaded(let source) = LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath) else {
            return nil
        }
        switch source.format {
        case .plainText:
            return OriginalMessageText.cleaned(from: source.text)
        case .html:
            return OriginalMessageText.cleaned(from: strippedHTML(source.text))
        }
    }

    /// Off-main-safe HTML → text (no WebKit): drop script/style, strip tags,
    /// decode the common entities. Good enough for the focused reader; the
    /// cleaner then trims quoted history.
    nonisolated private static func strippedHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?s)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }
}
