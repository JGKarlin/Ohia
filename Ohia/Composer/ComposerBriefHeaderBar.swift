// Ohia/Composer/ComposerBriefHeaderBar.swift
// Brief-first Composer top bar: who this reply is for, what the user owes,
// and the few timing/workflow facts worth seeing before the body.

import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

struct ComposerBriefHeaderBar: View {
    let session: ComposerSession?
    let composeState: ComposeState?
    let provisionalComposeState: ComposerProvisionalComposeState?
    let message: Message?
    let queueItem: ComposerQueueItem?
    let replyIdentities: [Identity]
    let replyIdentity: Binding<Identity?>?
    let replySignatureSlots: [SignatureSlot]
    let replySignatureSlotID: Binding<UUID?>?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let host = newMessageHost {
                ComposerRecipientConstellationHeader(
                    host: host,
                    summary: composeSummary(for: host.toChips),
                    subject: "",
                    deadlineText: nil,
                    receivedAt: Date(),
                    routesFirstRecipientDirectlyToTo: true,
                    composeSubject: newMessageSubject,
                    composeIdentities: composeState?.availableIdentities
                        ?? provisionalComposeState?.availableIdentities ?? [],
                    composeIdentity: newMessageIdentity,
                    composeSignatureSlots: composeState?.availableSignatureSlots
                        ?? provisionalComposeState?.availableSignatureSlots ?? [],
                    composeSignatureSlotID: newMessageSignatureSlotID,
                    onSubjectCommit: composeState == nil
                        ? { provisionalComposeState?.commitSubject() }
                        : nil
                )
                // Promotion persists the provisional ID, retaining this exact
                // subtree and its recipient query/focus during subject blur.
                .id(composeState?.draft?.id ?? provisionalComposeState?.id)
            } else if let session {
                ComposerRecipientConstellationHeader(
                    host: session,
                    summary: briefText(for: session, message: message),
                    subject: subjectLine(for: session),
                    deadlineText: deadlineText(for: message, queueItem: queueItem),
                    receivedAt: receivedDate(for: message, queueItem: queueItem),
                    routesFirstRecipientDirectlyToTo: false,
                    composeSubject: nil,
                    composeIdentities: replyIdentities,
                    composeIdentity: replyIdentity,
                    composeSignatureSlots: replySignatureSlots,
                    composeSignatureSlotID: replySignatureSlotID,
                    onSubjectCommit: nil
                )
                .id(session.messageID)
            }
        }
        .onAppear {
            if let session {
                session.loadRecipientSuggestions(context: modelContext)
            }
        }
        .onChange(of: session?.messageID) {
            if let session {
                session.loadRecipientSuggestions(context: modelContext)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OhiaColors.composerPanelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
    }

    private var newMessageHost: (any ComposerRecipientHost)? {
        if let composeState { return composeState }
        guard session == nil else { return nil }
        return provisionalComposeState
    }

    private var newMessageSubject: Binding<String> {
        Binding(
            get: {
                if let composeState { return composeState.draft?.composeSubject ?? "" }
                return provisionalComposeState?.subject ?? ""
            },
            set: { subject in
                if let composeState {
                    composeState.setSubject(subject)
                } else {
                    provisionalComposeState?.subject = subject
                }
            }
        )
    }

    private var newMessageIdentity: Binding<Identity?> {
        Binding(
            get: {
                if let composeState { return composeState.fromIdentity }
                return provisionalComposeState?.selectedIdentity
            },
            set: { identity in
                if let composeState {
                    if let identity { composeState.setIdentity(identity) }
                } else {
                    provisionalComposeState?.setIdentity(identity)
                }
            }
        )
    }

    private var newMessageSignatureSlotID: Binding<UUID?> {
        Binding(
            get: {
                if let composeState { return composeState.resolvedSignatureSlot?.id }
                return provisionalComposeState?.selectedSignatureSlotID
            },
            set: { newID in
                if let composeState {
                    composeState.setSignatureSlot(
                        composeState.availableSignatureSlots.first(where: { $0.id == newID })
                    )
                } else {
                    provisionalComposeState?.selectedSignatureSlotID = newID
                }
            }
        )
    }

    private func composeSummary(
        for recipients: [ComposeAddressEncoding.ParsedAddress]
    ) -> String {
        guard let recipient = recipients.first else {
            return ""
        }
        let name = recipient.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientLabel = name?.isEmpty == false ? name ?? recipient.asciiAddress : recipient.asciiAddress
        return "Write a new email to \(recipientLabel)."
    }

    private func briefText(for session: ComposerSession, message: Message?) -> String {
        if let actionSummary = triageVerdict(for: message)?.action?.summary
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !actionSummary.isEmpty {
            return actionSummary
        }
        if let bodySummary = message?.analysis?.bodySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodySummary.isEmpty {
            return bodySummary
        }
        return "\(session.correspondentName) needs a reply about \(session.subject)."
    }

    private func subjectLine(for session: ComposerSession) -> String {
        "Re: \(session.subject)"
    }

    private func deadlineText(for message: Message?, queueItem: ComposerQueueItem?) -> String? {
        if let deadline = queueItem?.deadline?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deadline.isEmpty {
            return deadline
        }
        let rawDeadline = triageVerdict(for: message)?.action?.deadline?.dateString
        let trimmedDeadline = rawDeadline?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDeadline?.isEmpty == false ? trimmedDeadline : nil
    }

    private func receivedDate(for message: Message?, queueItem: ComposerQueueItem?) -> Date {
        queueItem?.receivedAt
            ?? message?.receivedAt
            ?? message?.sentAt
            ?? message?.ingestedAt
            ?? Date()
    }

    private func triageVerdict(for message: Message?) -> TriageVerdict? {
        guard let json = message?.analysis?.triageVerdictJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TriageVerdict.self, from: data)
    }
}

@MainActor
protocol ComposerRecipientHost: AnyObject, Observable {
    var recipientSuggestions: [ComposeRecipientSuggestion] { get }
    var toChips: [ComposeAddressEncoding.ParsedAddress] { get }
    var ccChips: [ComposeAddressEncoding.ParsedAddress] { get }
    var bccChips: [ComposeAddressEncoding.ParsedAddress] { get }
    var hasDraftRow: Bool { get }
    var recipientMutationsEnabled: Bool { get }
    var replyScopeMode: ReplyRecipientMode? { get }
    var canSelectReplyAll: Bool { get }
    var replyAllRecipientCount: Int { get }

    func addRecipient(
        _ suggestion: ComposeRecipientSuggestion,
        to field: ComposeRecipientField.Kind,
        context: ModelContext
    )
    func removeToChip(at index: Int, context: ModelContext)
    func removeCcChip(at index: Int, context: ModelContext)
    func removeBccChip(at index: Int, context: ModelContext)
    func setReplyRecipientMode(_ mode: ReplyRecipientMode, context: ModelContext)
}

extension ComposerRecipientHost {
    var replyScopeMode: ReplyRecipientMode? { nil }
    var canSelectReplyAll: Bool { false }
    var replyAllRecipientCount: Int { 0 }
    func setReplyRecipientMode(_ mode: ReplyRecipientMode, context: ModelContext) {}
}

enum ComposerHeaderRecipientRouting {
    static func immediateField(
        routesFirstRecipientDirectlyToTo: Bool,
        hasPrimaryToRecipient: Bool,
        hasDraftRow: Bool
    ) -> ComposeRecipientField.Kind? {
        routesFirstRecipientDirectlyToTo && (!hasDraftRow || !hasPrimaryToRecipient) ? .to : nil
    }
}

private enum ComposerHeaderLayout {
    static let newMessageLeadingColumnWidth: CGFloat = 420
    static let replySenderMinimumWidth: CGFloat = 320
    static let cardHeight: CGFloat = 78
}

nonisolated private struct ComposerHeaderCorrespondenceRefreshID: Equatable {
    let target: ComposerHeaderCorrespondenceTarget
    let accountID: UUID?
}

private struct ComposerRecipientConstellationHeader: View {
    // Both provisional and persisted hosts use the same view type. Observable
    // property reads remain tracked; host mutations go through its methods.
    let host: any ComposerRecipientHost
    let summary: String
    let subject: String
    let deadlineText: String?
    let receivedAt: Date
    let routesFirstRecipientDirectlyToTo: Bool
    let composeSubject: Binding<String>?
    let composeIdentities: [Identity]
    let composeIdentity: Binding<Identity?>?
    let composeSignatureSlots: [SignatureSlot]
    let composeSignatureSlotID: Binding<UUID?>?
    let onSubjectCommit: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.readingTextSize) private var readingTextSize
    @Environment(AppServices.self) private var appServices: AppServices?
    @Query private var mailingLists: [MailingList]
    @State private var generatorMode: ComposerHeaderOrbGeneratorMode = .correspondent
    @State private var generatorQuery = ""
    @State private var stagedRecipients: [ComposerHeaderStagedRecipient] = []
    @State private var collapsingRecipientVersions: [String: Int] = [:]
    @State private var collapseVersion = 0
    @State private var correspondenceSnapshot: ComposerHeaderCorrespondenceSnapshot?
    @State private var correspondenceSummary = ""
    @State private var correspondenceSummaryIsLoading = false
    @State private var correspondenceRequestID: UUID?

    private var alreadyAdded: Set<String> {
        Set(
            (host.toChips + host.ccChips + host.bccChips).map { Self.normalizedAddress($0.asciiAddress) }
                + stagedRecipients.map { Self.normalizedAddress($0.suggestion.address) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let composeSubject {
                ComposerNewMessageCorrespondenceHeaderRow(
                    subject: composeSubject,
                    onSubjectCommit: onSubjectCommit,
                    hasCorrespondenceTarget: correspondenceTarget != nil,
                    snapshot: correspondenceSnapshot,
                    summary: correspondenceSummary,
                    isLoading: correspondenceSummaryIsLoading
                )
                .disabled(!host.recipientMutationsEnabled)
                .opacity(host.recipientMutationsEnabled ? 1 : 0.56)
            } else {
                ComposerHeaderSubjectSummaryRow(
                    subject: subject,
                    deadlineText: deadlineText,
                    receivedAt: receivedAt,
                    summary: summary
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    if let composeIdentity,
                       composeSubject != nil
                        || composeIdentities.count >= 2
                        || !composeSignatureSlots.isEmpty {
                        ComposerHeaderSenderCard(
                            identities: composeIdentities,
                            selectedIdentity: composeIdentity,
                            signatureSlots: composeSignatureSlots,
                            selectedSignatureSlotID: composeSignatureSlotID
                        )
                    }

                    HStack(alignment: .top, spacing: 8) {
                        ComposerHeaderOrbGenerator(
                            mode: $generatorMode,
                            query: $generatorQuery,
                            suggestions: host.recipientSuggestions,
                            stagedRecipients: stagedRecipients,
                            collapsingRecipientIDs: Set(collapsingRecipientVersions.keys),
                            alreadyAdded: alreadyAdded,
                            showsOnDeckSocket: !routesFirstRecipientDirectlyToTo || !host.toChips.isEmpty,
                            fixedWidth: composeSubject == nil ? nil : ComposerHeaderLayout.newMessageLeadingColumnWidth,
                            replyScopeMode: host.replyScopeMode,
                            canSelectReplyAll: host.canSelectReplyAll,
                            replyAllRecipientCount: host.replyAllRecipientCount,
                            isReplyScopeEnabled: host.recipientMutationsEnabled,
                            onStageRecipient: { stageRecipient($0) },
                            onRemoveRecipient: { collapseAndRemoveStaged($0) },
                            onSelectReplyScope: {
                                host.setReplyRecipientMode($0, context: modelContext)
                            }
                        )

                        ForEach(ComposerHeaderRecipientField.allCases) { field in
                            ComposerHeaderCompactFieldCard(
                                field: field,
                                recipients: recipients(for: field),
                                collapsingRecipientIDs: Set(collapsingRecipientVersions.keys),
                                onDropRecipient: { moveRecipient(payload: $0, to: field) },
                                onRemoveRecipient: { collapseAndRemovePlaced($0) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!host.recipientMutationsEnabled)
                    .opacity(host.recipientMutationsEnabled ? 1 : 0.56)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OhiaColors.composerPanelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.72), lineWidth: 1)
        )
        .help(recipientHelpText)
        .task(id: correspondenceRefreshID) {
            await refreshCorrespondenceSummary()
        }
    }

    private var selectedComposeIdentity: Identity? {
        composeIdentity?.wrappedValue
    }

    private var correspondenceTarget: ComposerHeaderCorrespondenceTarget? {
        ComposerHeaderCorrespondenceBuilder.target(
            recipients: host.toChips,
            accountID: selectedComposeIdentity?.account?.id,
            mailingLists: mailingLists.map {
                ComposerHeaderMailingListIdentity(
                    accountID: $0.accountID,
                    listID: $0.listId,
                    displayName: $0.displayName,
                    postingAddress: $0.listAddress
                )
            }
        )
    }

    private var correspondenceRefreshID: ComposerHeaderCorrespondenceRefreshID? {
        guard composeSubject != nil, let target = correspondenceTarget else { return nil }
        return ComposerHeaderCorrespondenceRefreshID(
            target: target,
            accountID: selectedComposeIdentity?.account?.id
        )
    }

    private func refreshCorrespondenceSummary() async {
        guard composeSubject != nil,
              let target = correspondenceTarget else {
            correspondenceRequestID = nil
            correspondenceSnapshot = nil
            correspondenceSummary = ""
            correspondenceSummaryIsLoading = false
            return
        }

        let requestID = UUID()
        correspondenceRequestID = requestID
        correspondenceSnapshot = nil
        correspondenceSummary = ""
        correspondenceSummaryIsLoading = true

        guard let appServices else {
            correspondenceSummary = "Correspondence summary unavailable."
            correspondenceSummaryIsLoading = false
            return
        }

        let accountID = selectedComposeIdentity?.account?.id
        let storeURL = appServices.messageStoreURL
        let memoryProvider = appServices.askMemoryProvider
        let loaded = await Task.detached(priority: .userInitiated) {
            let snapshot = try? ComposerHeaderCorrespondenceBuilder.loadSnapshot(
                target: target,
                accountID: accountID,
                storeURL: storeURL
            )
            let memoryNotes = ComposerHeaderCorrespondenceBuilder.memoryNotes(
                provider: memoryProvider,
                target: target,
                accountID: accountID
            )
            return (snapshot, memoryNotes)
        }.value

        guard !Task.isCancelled, correspondenceRequestID == requestID else { return }
        guard let snapshot = loaded.0 else {
            correspondenceSummary = "Correspondence summary unavailable."
            correspondenceSummaryIsLoading = false
            return
        }

        correspondenceSnapshot = snapshot
        guard snapshot.hasHistory else {
            correspondenceSummary = "No prior correspondence."
            correspondenceSummaryIsLoading = false
            return
        }

        let selectedIdentity = selectedComposeIdentity
        let userIdentity = selectedIdentity.map {
            SummarizationUserIdentity(
                displayName: $0.displayName ?? "",
                primaryEmailAddress: $0.address
            )
        }
        let input = ComposerHeaderCorrespondenceBuilder.orientationInput(
            snapshot: snapshot,
            userIdentity: userIdentity,
            memoryNotes: loaded.1
        )
        let result = await appServices.contextOrientationService.orientation(
            for: ComposerHeaderCorrespondenceBuilder.cacheVectorID(
                target: target,
                accountID: accountID
            ),
            input: input,
            accountID: accountID
        )

        guard !Task.isCancelled, correspondenceRequestID == requestID else { return }
        if let paragraph = result?.paragraph, !paragraph.isEmpty {
            correspondenceSummary = ComposerHeaderCorrespondenceBuilder.plainSummary(paragraph)
        } else {
            correspondenceSummary = "Correspondence summary unavailable."
        }
        correspondenceSummaryIsLoading = false
    }

    private var recipientHelpText: String {
        if !host.hasDraftRow {
            return "Edit recipients now; the first change will prepare this message's draft"
        }
        if !host.recipientMutationsEnabled {
            return "Recipients are locked while the Composer is writing"
        }
        return composeSubject == nil ? "Edit reply recipients" : "Edit message recipients"
    }

    private func recipients(for field: ComposerHeaderRecipientField) -> [ComposerHeaderRecipientPlacement] {
        chips(for: field).map { address in
            ComposerHeaderRecipientPlacement(field: field, address: address)
        }
    }

    private func chips(for field: ComposerHeaderRecipientField) -> [ComposeAddressEncoding.ParsedAddress] {
        switch field {
        case .to: host.toChips
        case .cc: host.ccChips
        case .bcc: host.bccChips
        }
    }

    private func stageRecipient(_ suggestion: ComposeRecipientSuggestion) {
        let normalized = Self.normalizedAddress(suggestion.address)
        guard stagedRecipients.isEmpty, !alreadyAdded.contains(normalized) else { return }
        if let immediateField = ComposerHeaderRecipientRouting.immediateField(
            routesFirstRecipientDirectlyToTo: routesFirstRecipientDirectlyToTo,
            hasPrimaryToRecipient: !host.toChips.isEmpty,
            hasDraftRow: host.hasDraftRow
        ) {
            host.addRecipient(suggestion, to: immediateField, context: modelContext)
            generatorQuery = ""
            return
        }
        let staged = ComposerHeaderStagedRecipient(suggestion: suggestion, kind: ComposerHeaderOrbKind(suggestion.kind))
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            stagedRecipients.append(staged)
            generatorQuery = ""
        }
    }

    @discardableResult
    private func moveRecipient(payload: String, to field: ComposerHeaderRecipientField) -> Bool {
        let normalized = Self.normalizedAddress(payload)
        if let staged = stagedRecipients.first(where: { Self.normalizedAddress($0.suggestion.address) == normalized }) {
            host.addRecipient(staged.suggestion, to: field.composeKind, context: modelContext)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                stagedRecipients.removeAll { Self.normalizedAddress($0.suggestion.address) == normalized }
            }
            return true
        }

        guard let located = locatedRecipient(address: normalized) else { return false }
        guard located.field != field else { return true }
        removePlaced(located)
        let suggestion = ComposeRecipientSuggestion(
            name: located.address.displayName ?? "",
            address: located.address.asciiAddress,
            organization: nil,
            frequency: 0,
            lastSeen: nil
        )
        host.addRecipient(suggestion, to: field.composeKind, context: modelContext)
        return true
    }

    private func collapseAndRemovePlaced(_ placement: ComposerHeaderRecipientPlacement) {
        collapse(placement.id) {
            removePlaced(placement)
        }
    }

    private func collapseAndRemoveStaged(_ staged: ComposerHeaderStagedRecipient) {
        collapse(staged.id) {
            stagedRecipients.removeAll { $0.id == staged.id }
        }
    }

    private func collapse(_ id: String, removal: @escaping () -> Void) {
        guard collapsingRecipientVersions[id] == nil else { return }
        collapseVersion += 1
        let version = collapseVersion
        withAnimation(.easeInOut(duration: 0.18)) {
            collapsingRecipientVersions[id] = version
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            guard collapsingRecipientVersions[id] == version else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                removal()
                collapsingRecipientVersions[id] = nil
            }
        }
    }

    private func locatedRecipient(address normalized: String) -> ComposerHeaderRecipientPlacement? {
        for field in ComposerHeaderRecipientField.allCases {
            if let match = recipients(for: field).first(where: {
                Self.normalizedAddress($0.address.asciiAddress) == normalized
            }) {
                return match
            }
        }
        return nil
    }

    private func removePlaced(_ placement: ComposerHeaderRecipientPlacement) {
        // Removal is deferred ~0.46s by the collapse animation; during that
        // window other removals or drag-moves can shift the field's array, so a
        // frozen index would delete the wrong recipient (or no-op). Re-resolve
        // the index by address against the live chips at execution time.
        let target = Self.normalizedAddress(placement.address.asciiAddress)
        guard let index = chips(for: placement.field).firstIndex(where: {
            Self.normalizedAddress($0.asciiAddress) == target
        }) else { return }
        switch placement.field {
        case .to: host.removeToChip(at: index, context: modelContext)
        case .cc: host.removeCcChip(at: index, context: modelContext)
        case .bcc: host.removeBccChip(at: index, context: modelContext)
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct ComposerReplyScopeSelector: View {
    let mode: ReplyRecipientMode
    let replyAllRecipientCount: Int
    let isEnabled: Bool
    let onSelect: (ReplyRecipientMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            modeButton(.reply, title: "Reply")
            modeButton(.replyAll, title: "Reply All (\(replyAllRecipientCount))")

            if mode == .custom {
                Label("Custom", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(OhiaColors.chipActiveBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Custom reply recipients")
            }
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply recipient scope")
    }

    // Reply/Reply All is a two-way mode picker, not a primary action — the
    // filter-chip idiom FrameSelectorBar already uses to pick one of a
    // small set fits it better than EmblemButtonStyle's CTA-weight chrome.
    private func modeButton(_ candidate: ReplyRecipientMode, title: String) -> some View {
        let isSelected = mode == candidate
        return Button {
            onSelect(candidate)
        } label: {
            FilterChipLabel(text: title, isOn: isSelected)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(candidate == .reply
            ? "Addresses the reply target only"
            : "Includes the original To and Cc recipients")
    }
}

private struct ComposerHeaderCompactFieldCard: View {
    let field: ComposerHeaderRecipientField
    let recipients: [ComposerHeaderRecipientPlacement]
    let collapsingRecipientIDs: Set<String>
    let onDropRecipient: (String) -> Bool
    let onRemoveRecipient: (ComposerHeaderRecipientPlacement) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(field.title)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 28, alignment: .leading)

            if !recipients.isEmpty {
                ViewThatFits(in: .horizontal) {
                    recipientOrbs
                    recipientAddressSummary
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(
            minWidth: 72,
            idealWidth: recipients.isEmpty ? 72 : 174,
            maxWidth: recipients.isEmpty ? 72 : .infinity,
            alignment: .leading
        )
        .frame(height: ComposerHeaderLayout.cardHeight, alignment: .leading)
        .layoutPriority(recipients.isEmpty ? 0 : -1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OhiaColors.surface(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OhiaColors.glassBorderBright.opacity(0.72), lineWidth: 1)
        )
        .dropDestination(for: String.self) { payloads, _ in
            var movedAny = false
            for payload in payloads {
                movedAny = onDropRecipient(payload) || movedAny
            }
            return movedAny
        }
    }

    private var recipientOrbs: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(recipients) { recipient in
                CompactInteractiveOrb(
                    recipient: recipient.viewModel,
                    isCollapsing: collapsingRecipientIDs.contains(recipient.id),
                    onRemove: { onRemoveRecipient(recipient) }
                )
                .draggable(recipient.address.asciiAddress) {
                    ComposerHeaderDragOrbPreview(recipient: recipient.viewModel)
                }
            }
        }
    }

    private var recipientAddressSummary: some View {
        Text(recipients.map { $0.address.asciiAddress }.joined(separator: ", "))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(OhiaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct ComposerHeaderSenderCard: View {
    let identities: [Identity]
    @Binding var selectedIdentity: Identity?
    let signatureSlots: [SignatureSlot]
    let selectedSignatureSlotID: Binding<UUID?>?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("FROM")
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.8)
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                ComposeFromPicker(
                    identities: identities,
                    selected: $selectedIdentity,
                    showsLabel: false,
                    showsPrimaryTagInSelection: false
                )

                if let selectedSignatureSlotID, !signatureSlots.isEmpty {
                    let selectedSignatureName = selectedSignatureSlotID.wrappedValue.flatMap { selectedID in
                        signatureSlots.first(where: { $0.id == selectedID })?.name
                    } ?? "No Signature"

                    Menu {
                        Button {
                            selectedSignatureSlotID.wrappedValue = nil
                        } label: {
                            signatureMenuItem(
                                name: "No Signature",
                                isSelected: selectedSignatureSlotID.wrappedValue == nil
                            )
                        }

                        ForEach(signatureSlots, id: \.id) { slot in
                            Button {
                                selectedSignatureSlotID.wrappedValue = slot.id
                            } label: {
                                signatureMenuItem(
                                    name: slot.name,
                                    isSelected: selectedSignatureSlotID.wrappedValue == slot.id
                                )
                            }
                        }
                    } label: {
                        Text(selectedSignatureName)
                            .font(OhiaTypography.cardDetail)
                            .foregroundStyle(OhiaColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.leading, 40)
                    .padding(.trailing, 28)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(OhiaColors.iconPillBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                    )
                    .overlay(alignment: .leading) {
                        Image(systemName: "signature")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OhiaColors.ohiaYellow)
                            .padding(.leading, 10)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(OhiaColors.ohiaYellow)
                            .padding(.trailing, 10)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Signature")
                    .accessibilityValue(selectedSignatureName)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(
            minWidth: ComposerHeaderLayout.replySenderMinimumWidth,
            alignment: .leading
        )
        .frame(height: ComposerHeaderLayout.cardHeight, alignment: .leading)
        .layoutPriority(1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OhiaColors.surface(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OhiaColors.glassBorderBright.opacity(0.72), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func signatureMenuItem(name: String, isSelected: Bool) -> some View {
        if isSelected {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: Self.yellowCheckmarkImage)
            }
        } else {
            Text(name)
        }
    }

    private static let yellowCheckmarkImage: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let checkmark = NSBezierPath()
            checkmark.move(to: NSPoint(x: 1.5, y: 6.0))
            checkmark.line(to: NSPoint(x: 4.5, y: 3.0))
            checkmark.line(to: NSPoint(x: 10.5, y: 10.0))
            checkmark.lineWidth = 1.6
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            NSColor(
                srgbRed: 248 / 255,
                green: 248 / 255,
                blue: 56 / 255,
                alpha: 1
            ).setStroke()
            checkmark.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

// Compact recipient orb: 30pt circle, name and email underneath. Draggable at
// the call site; hover reveals the remove button and, for lists, hides the kind
// badge so it doesn't collide with the button.
private struct CompactInteractiveOrb: View {
    let recipient: ComposerHeaderRecipientViewModel
    let isCollapsing: Bool
    let onRemove: () -> Void

    @State private var hovering = false
    private let diameter: CGFloat = 30

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(OhiaColors.chipActiveBackground)
                    Circle()
                        .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.72), lineWidth: 1)
                    Circle()
                        .strokeBorder(OhiaColors.surface(0.42), lineWidth: 0.5)
                        .padding(3)
                    Text(recipient.initials)
                        .font(.system(size: diameter * 0.36, weight: .semibold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: OhiaColors.chipActiveForeground.opacity(hovering ? 0.26 : 0.12), radius: hovering ? 8 : 3)

                if isCollapsing {
                    ComposerHeaderEventHorizonCollapse()
                        .frame(width: diameter, height: diameter)
                }

                Image(systemName: recipient.kind.symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .padding(2)
                    .background(Circle().fill(OhiaColors.toolbarBackground))
                    .offset(x: 3, y: -3)
                    .opacity(recipient.kind == .list && !hovering ? 1 : 0)

                ComposerHeaderOrbCloseButton(
                    label: "Remove \(recipient.name)",
                    size: 15,
                    action: onRemove
                )
                .offset(x: 4, y: -4)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }

            Text(recipient.name)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 136)

            if shouldShowEmailLine {
                Text(recipient.email)
                    .font(.system(size: 8.8, weight: .semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.38)
                    .frame(width: 136)
            }
        }
        .scaleEffect(isCollapsing ? 0.18 : (hovering ? 1.05 : 1))
        .rotationEffect(.degrees(isCollapsing ? -18 : 0))
        .blur(radius: isCollapsing ? 2.0 : 0)
        .opacity(isCollapsing ? 0.12 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: hovering)
        .animation(.easeInOut(duration: 0.34), value: isCollapsing)
        .onHover { hovering = $0 }
        .help("\(recipient.name)\n\(recipient.email)")
        .accessibilityElement(children: .contain)
    }

    private var shouldShowEmailLine: Bool {
        recipient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(recipient.email.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
    }
}

private struct ComposerHeaderDragOrbPreview: View {
    let recipient: ComposerHeaderRecipientViewModel
    private let diameter: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(OhiaColors.chipActiveBackground)
            Circle()
                .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.82), lineWidth: 1.2)
            Circle()
                .strokeBorder(OhiaColors.surface(0.42), lineWidth: 0.6)
                .padding(3)
            Text(recipient.initials)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .minimumScaleFactor(0.62)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: OhiaColors.chipActiveForeground.opacity(0.18), radius: 5)
    }
}

private struct ComposerHeaderOrbGenerator: View {
    @Binding var mode: ComposerHeaderOrbGeneratorMode
    @Binding var query: String
    let suggestions: [ComposeRecipientSuggestion]
    let stagedRecipients: [ComposerHeaderStagedRecipient]
    let collapsingRecipientIDs: Set<String>
    let alreadyAdded: Set<String>
    let showsOnDeckSocket: Bool
    let fixedWidth: CGFloat?
    let replyScopeMode: ReplyRecipientMode?
    let canSelectReplyAll: Bool
    let replyAllRecipientCount: Int
    let isReplyScopeEnabled: Bool
    let onStageRecipient: (ComposeRecipientSuggestion) -> Void
    let onRemoveRecipient: (ComposerHeaderStagedRecipient) -> Void
    let onSelectReplyScope: (ReplyRecipientMode) -> Void

    private var canStageRecipient: Bool {
        stagedRecipients.isEmpty
    }

    private var searchFieldWidth: CGFloat {
        if fixedWidth != nil { return 300 }
        return canSelectReplyAll ? 250 : 190
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("ADD")
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                ComposerHeaderRecipientSearchField(
                    query: $query,
                    mode: mode,
                    suggestions: suggestions,
                    alreadyAdded: alreadyAdded,
                    isEnabled: canStageRecipient,
                    width: searchFieldWidth,
                    onSelect: onStageRecipient
                )
                .disabled(!canStageRecipient)
                .opacity(canStageRecipient ? 1 : 0.48)

                HStack(spacing: 5) {
                    ForEach(ComposerHeaderOrbGeneratorMode.allCases) { option in
                        ComposerHeaderModeButton(
                            option: option,
                            isSelected: mode == option,
                            isEnabled: canStageRecipient
                        ) {
                            guard canStageRecipient else { return }
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                mode = option
                                query = ""
                            }
                        }
                    }

                    if let replyScopeMode, canSelectReplyAll {
                        Rectangle()
                            .fill(OhiaColors.glassBorder)
                            .frame(width: 1, height: 16)
                            .frame(width: 9, height: 22)

                        ComposerReplyScopeSelector(
                            mode: replyScopeMode,
                            replyAllRecipientCount: replyAllRecipientCount,
                            isEnabled: isReplyScopeEnabled,
                            onSelect: onSelectReplyScope
                        )
                    }

                    if !stagedRecipients.isEmpty {
                        Spacer(minLength: 2)
                        Text("Drag into To/Cc/Bcc.")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(OhiaColors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: searchFieldWidth, alignment: .leading)

            if showsOnDeckSocket {
                ComposerHeaderOnDeckSocket(
                    recipient: stagedRecipients.first,
                    collapsingRecipientIDs: collapsingRecipientIDs,
                    onRemoveRecipient: onRemoveRecipient
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: fixedWidth, alignment: .leading)
        .frame(height: ComposerHeaderLayout.cardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OhiaColors.surface(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OhiaColors.glassBorderBright.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct ComposerHeaderModeButton: View {
    let option: ComposerHeaderOrbGeneratorMode
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: option.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? OhiaColors.chipActiveBackground : OhiaColors.surface(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : OhiaColors.glassBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .disabled(!isEnabled)
    }
}

private struct ComposerHeaderOnDeckSocket: View {
    let recipient: ComposerHeaderStagedRecipient?
    let collapsingRecipientIDs: Set<String>
    let onRemoveRecipient: (ComposerHeaderStagedRecipient) -> Void

    var body: some View {
        Group {
            if let recipient {
                VStack(spacing: 3) {
                    ZStack {
                        ComposerHeaderGeneratedOrbHint()
                        ComposerHeaderOnDeckRecipientOrb(
                            recipient: recipient.viewModel,
                            isCollapsing: collapsingRecipientIDs.contains(recipient.id),
                            isShimmering: !collapsingRecipientIDs.contains(recipient.id),
                            onRemove: { onRemoveRecipient(recipient) }
                        )
                        .draggable(recipient.suggestion.address) {
                            ComposerHeaderDragOrbPreview(recipient: recipient.viewModel)
                        }
                        .transition(.scale(scale: 0.78).combined(with: .opacity))
                    }
                    .frame(width: 42, height: 42)

                    Text(recipient.suggestion.address)
                        .font(.system(size: 7.6, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .frame(width: 86, height: 9)
                }
            } else {
                ComposerHeaderGeneratedOrbHint()
                    .frame(width: 42, height: 42)
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: recipient?.id)
    }
}

private struct ComposerHeaderRecipientSearchField: View {
    @Binding var query: String
    let mode: ComposerHeaderOrbGeneratorMode
    let suggestions: [ComposeRecipientSuggestion]
    let alreadyAdded: Set<String>
    let isEnabled: Bool
    let width: CGFloat
    let onSelect: (ComposeRecipientSuggestion) -> Void

    @State private var suppressSuggestions = false
    @State private var highlightedSuggestionID: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: query.isEmpty ? .regular : .semibold))
                .foregroundStyle(OhiaColors.ohiaYellow)
            TextField(placeholderText, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: query.isEmpty ? .regular : .semibold))
                .foregroundStyle(query.isEmpty ? OhiaColors.textPrimary : OhiaColors.chipActiveForeground)
                .frame(maxWidth: .infinity)
                .focused($fieldFocused)
                .onSubmit { acceptHighlightedSuggestionOrQuery() }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.return) {
                    acceptHighlightedSuggestionOrQuery()
                    return .handled
                }
                .onKeyPress(.escape) { handleEscape() }
                .onChange(of: query) { _, _ in
                    suppressSuggestions = false
                    highlightedSuggestionID = nil
                }
                .onChange(of: fieldFocused) { _, focused in
                    if focused {
                        suppressSuggestions = false
                    }
                }
            Button(action: clearQuery) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(query.isEmpty ? OhiaColors.textSecondary : OhiaColors.chipActiveForeground)
                    .opacity(clearButtonVisible ? 0.75 : 0)
            }
            .buttonStyle(.plain)
            .tooltip("Clear recipient search")
            .accessibilityLabel("Clear recipient search")
            .accessibilityHidden(!clearButtonVisible)
            .allowsHitTesting(clearButtonVisible)
            .frame(width: 12, height: 14)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(query.isEmpty ? OhiaColors.iconPillBackground : OhiaColors.chipActiveBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(query.isEmpty ? OhiaColors.iconPillBorder : OhiaColors.chipActiveBorder, lineWidth: 1)
        }
        .popover(isPresented: suggestionPopoverBinding, arrowEdge: .top) {
            ComposerHeaderSuggestionList(
                mode: mode,
                candidates: visibleCandidates,
                highlightedID: highlightedID(in: visibleCandidates),
                onSelect: selectCandidate(_:)
            )
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                suppressSuggestions = false
            }
            highlightedSuggestionID = nil
        }
    }

    private var clearButtonVisible: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholderText: String {
        mode.kind == .list ? "list or address" : "name or address"
    }

    private var shouldShowSuggestions: Bool {
        isEnabled && fieldFocused && !suppressSuggestions && !visibleCandidates.isEmpty
    }

    private var suggestionPopoverBinding: Binding<Bool> {
        Binding(
            get: { shouldShowSuggestions },
            set: { isPresented in
                if !isPresented, isEnabled, fieldFocused {
                    suppressSuggestions = true
                }
            }
        )
    }

    private var visibleCandidates: [ComposerHeaderRecipientCandidate] {
        let needle = query.normalizedForCorrespondentAutocomplete
        guard isEnabled, !needle.isEmpty else { return [] }
        let contactMatches = suggestions
            .filter {
                ComposerHeaderOrbKind($0.kind) == mode.kind
                    && !alreadyAdded.contains($0.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            .compactMap { suggestion -> (ComposeRecipientSuggestion, Int)? in
                let title = suggestion.displayTitle.normalizedForCorrespondentAutocomplete
                let value = suggestion.address.normalizedForCorrespondentAutocomplete
                let words = title.split(separator: " ") + value.split(separator: "@")
                let rank: Int
                if title.hasPrefix(needle) {
                    rank = 0
                } else if value.hasPrefix(needle) {
                    rank = 1
                } else if words.contains(where: { $0.hasPrefix(needle) }) {
                    rank = 2
                } else if title.contains(needle) || value.contains(needle) {
                    rank = 3
                } else {
                    return nil
                }
                return (suggestion, rank)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.frequency != rhs.0.frequency { return lhs.0.frequency > rhs.0.frequency }
                let l = lhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                let r = rhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                return l > r
            }
            .prefix(7)
            .map { ComposerHeaderRecipientCandidate(suggestion: $0.0, isSelectable: true) }
        guard let typedSuggestion else { return contactMatches }
        if contactMatches.contains(where: {
            $0.suggestion.address.caseInsensitiveCompare(typedSuggestion.suggestion.address) == .orderedSame
        }) {
            return contactMatches
        }
        if !typedSuggestion.isSelectable,
           !query.contains("@") {
            return contactMatches
        }
        return [typedSuggestion] + contactMatches.prefix(6)
    }

    private var typedSuggestion: ComposerHeaderRecipientCandidate? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = ComposeAddressEncoding.parseInput(trimmed)
        guard parsed.invalid.isEmpty, parsed.valid.count == 1, let address = parsed.valid.first else {
            return ComposerHeaderRecipientCandidate(
                suggestion: ComposeRecipientSuggestion(
                    name: "",
                    address: trimmed,
                    organization: nil,
                    frequency: Int.max,
                    lastSeen: .distantFuture,
                    kind: mode.kind.suggestionKind
                ),
                isSelectable: false
            )
        }
        guard !alreadyAdded.contains(address.asciiAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return nil
        }
        return ComposerHeaderRecipientCandidate(
            suggestion: ComposeRecipientSuggestion(
                name: address.displayName ?? "",
                address: address.asciiAddress,
                organization: nil,
                frequency: Int.max,
                lastSeen: .distantFuture,
                kind: mode.kind.suggestionKind
            ),
            isSelectable: true
        )
    }

    private func clearQuery() {
        query = ""
        suppressSuggestions = true
        highlightedSuggestionID = nil
    }

    private func handleEscape() -> KeyPress.Result {
        if shouldShowSuggestions {
            suppressSuggestions = true
            highlightedSuggestionID = nil
            return .handled
        }
        if clearButtonVisible {
            clearQuery()
            return .handled
        }
        return .ignored
    }

    private func selectCandidate(_ candidate: ComposerHeaderRecipientCandidate) {
        guard isEnabled, candidate.isSelectable else { return }
        onSelect(candidate.suggestion)
        query = ""
        suppressSuggestions = false
        highlightedSuggestionID = nil
        fieldFocused = false
    }

    private func acceptHighlightedSuggestionOrQuery() {
        guard isEnabled else { return }
        if let candidate = highlightedCandidate(in: visibleCandidates)
            ?? visibleCandidates.first(where: \.isSelectable) {
            selectCandidate(candidate)
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = ComposeAddressEncoding.parseInput(trimmed)
        guard !parsed.valid.isEmpty else { return }
        parsed.valid.forEach { address in
            onSelect(
                ComposeRecipientSuggestion(
                    name: address.displayName ?? "",
                    address: address.asciiAddress,
                    organization: nil,
                    frequency: 0,
                    lastSeen: nil
                )
            )
        }
        if parsed.invalid.isEmpty {
            clearQuery()
            fieldFocused = false
        } else {
            query = parsed.invalid.joined(separator: ", ")
            suppressSuggestions = false
            highlightedSuggestionID = nil
            fieldFocused = true
        }
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let selectableCandidates = visibleCandidates.filter(\.isSelectable)
        guard shouldShowSuggestions, !selectableCandidates.isEmpty else { return .ignored }
        let currentID = highlightedID(in: selectableCandidates)
        let currentIndex = currentID.flatMap { id in
            selectableCandidates.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = (currentIndex + delta + selectableCandidates.count) % selectableCandidates.count
        highlightedSuggestionID = selectableCandidates[nextIndex].id
        return .handled
    }

    private func highlightedCandidate(in visibleCandidates: [ComposerHeaderRecipientCandidate]) -> ComposerHeaderRecipientCandidate? {
        guard let id = highlightedID(in: visibleCandidates) else { return nil }
        return visibleCandidates.first { $0.id == id && $0.isSelectable }
    }

    private func highlightedID(in visibleCandidates: [ComposerHeaderRecipientCandidate]) -> String? {
        guard !visibleCandidates.isEmpty else { return nil }
        if let highlightedSuggestionID,
           visibleCandidates.contains(where: { $0.id == highlightedSuggestionID && $0.isSelectable }) {
            return highlightedSuggestionID
        }
        return visibleCandidates.first(where: \.isSelectable)?.id
    }
}

private struct ComposerHeaderRecipientCandidate: Identifiable {
    let suggestion: ComposeRecipientSuggestion
    let isSelectable: Bool

    var id: String {
        "\(suggestion.id)|\(isSelectable ? "ready" : "typing")"
    }
}

private struct ComposerHeaderSuggestionList: View {
    let mode: ComposerHeaderOrbGeneratorMode
    let candidates: [ComposerHeaderRecipientCandidate]
    let highlightedID: String?
    let onSelect: (ComposerHeaderRecipientCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(candidates) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.suggestion.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OhiaColors.textPrimary)
                                .lineLimit(1)
                            if let subtitle = subtitle(for: candidate) {
                                Text(subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(OhiaColors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .opacity(candidate.isSelectable ? 1 : 0.55)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill((highlightedID.map { $0 == candidate.id } ?? false) ? OhiaColors.surface(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!candidate.isSelectable)
            }
        }
        .padding(6)
        .frame(width: 300)
        .composerPresentationFrame(inset: 8, cornerRadius: 8)
    }

    private func subtitle(for candidate: ComposerHeaderRecipientCandidate) -> String? {
        let suggestion = candidate.suggestion
        if !candidate.isSelectable { return nil }
        if suggestion.name.isEmpty { return nil }
        if let organization = suggestion.organization, !organization.isEmpty {
            return "\(suggestion.address) · \(organization)"
        }
        return suggestion.address
    }
}

private struct ComposerHeaderGeneratedOrbHint: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(OhiaColors.surface(0.03))
            Circle()
                .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.86), lineWidth: 1.2)
            Circle()
                .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.38), lineWidth: 0.8)
                .padding(5)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

private struct ComposerHeaderOnDeckRecipientOrb: View {
    let recipient: ComposerHeaderRecipientViewModel
    let isCollapsing: Bool
    let isShimmering: Bool
    let onRemove: () -> Void

    @State private var hovering = false
    private let diameter: CGFloat = 34

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(OhiaColors.chipActiveBackground)
                if isShimmering && !isCollapsing {
                    ComposerHeaderOrbShimmer(diameter: diameter)
                }
                Circle()
                    .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.82), lineWidth: 1.2)
                Circle()
                    .strokeBorder(OhiaColors.surface(0.42), lineWidth: 0.6)
                    .padding(3)
                Text(recipient.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .minimumScaleFactor(0.62)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: OhiaColors.chipActiveForeground.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 9 : 4)

            if isCollapsing {
                ComposerHeaderEventHorizonCollapse()
                    .frame(width: diameter, height: diameter)
            }

            ComposerHeaderOrbCloseButton(
                label: "Remove \(recipient.name)",
                size: 15,
                action: onRemove
            )
            .offset(x: 4, y: -4)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .scaleEffect(isCollapsing ? 0.18 : (hovering ? 1.06 : 1))
        .rotationEffect(.degrees(isCollapsing ? -18 : 0))
        .blur(radius: isCollapsing ? 2.0 : 0)
        .opacity(isCollapsing ? 0.12 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: hovering)
        .animation(.easeInOut(duration: 0.34), value: isCollapsing)
        .animation(.easeInOut(duration: 0.18), value: isShimmering)
        .onHover { hovering = $0 }
        .help("\(recipient.name)\n\(recipient.email)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recipient.name), on deck")
    }
}

private struct ComposerHeaderRecipientBubble: View {
    let recipient: ComposerHeaderRecipientViewModel
    let size: ComposerHeaderRecipientBubbleSize
    let emailMode: ComposerHeaderRecipientEmailMode
    let isCollapsing: Bool
    let isShimmering: Bool
    let showsRemoveButton: Bool
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: size.emailSpacing) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(OhiaColors.chipActiveBackground)
                    if isShimmering && !isCollapsing {
                        ComposerHeaderOrbShimmer(diameter: size.circleDiameter)
                    }
                    Circle()
                        .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.72), lineWidth: 1)
                    Circle()
                        .strokeBorder(OhiaColors.surface(0.42), lineWidth: 0.5)
                        .padding(size.innerRingInset)
                    Text(recipient.initials)
                        .font(.system(size: size.initialsSize, weight: .semibold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .minimumScaleFactor(0.62)
                }
                .frame(width: size.circleDiameter, height: size.circleDiameter)
                .shadow(color: OhiaColors.chipActiveForeground.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 10 : 4)

                if isCollapsing {
                    ComposerHeaderEventHorizonCollapse()
                        .frame(width: size.circleDiameter, height: size.circleDiameter)
                }

                if showsRemoveButton {
                    ComposerHeaderOrbCloseButton(
                        label: "Remove \(recipient.name)",
                        size: size.removeDiameter,
                        action: onRemove
                    )
                    .offset(x: size.removeOffset, y: -size.removeOffset)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: recipient.kind.symbol)
                    .font(.system(size: size.kindIconSize, weight: .semibold))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .accessibilityHidden(true)
                Text(recipient.name)
                    .font(size.nameFont)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: size.labelWidth)

            if emailMode != .hidden {
                Text(recipient.email)
                    .font(size.emailFont)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                    .frame(width: size.labelWidth)
                    .opacity(emailMode == .hover && !hovering ? 0 : 1)
            }
        }
        .padding(size.padding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? OhiaColors.surface(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? OhiaColors.chipActiveBorder.opacity(0.58) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isCollapsing ? 0.18 : (hovering ? 1.04 : 1))
        .rotationEffect(.degrees(isCollapsing ? -18 : 0))
        .blur(radius: isCollapsing ? 2.2 : 0)
        .opacity(isCollapsing ? 0.12 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: hovering)
        .animation(.easeInOut(duration: 0.34), value: isCollapsing)
        .animation(.easeInOut(duration: 0.18), value: isShimmering)
        .onHover { hovering = $0 }
        .help("\(recipient.name)\n\(recipient.email)")
        .accessibilityElement(children: .contain)
    }
}

private struct ComposerHeaderOrbCloseButton: View {
    let label: String
    let size: CGFloat
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(OhiaColors.ohiaRed)
                Image(systemName: "xmark")
                    .font(.system(size: max(CGFloat(7), size * 0.48), weight: .bold))
                    .foregroundStyle(OhiaColors.clusterHoverFillOnRed)
                if hovering {
                    Circle()
                        .stroke(OhiaColors.clusterHoverFillOnRed, lineWidth: 1.4)
                        .frame(width: size + 3, height: size + 3)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(hovering ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering in
            if reduceMotion {
                hovering = isHovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    hovering = isHovering
                }
            }
        }
    }
}

private struct ComposerHeaderOrbShimmer: View {
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            // Flat sweep bar. Composer chrome bans gradient fills (see
            // `WindowSceneSeparationTests.composerChromeUsesConstellationDesignTokens`),
            // so the shimmer is a translucent flat highlight riding across
            // the orb instead of a feathered gradient.
            Rectangle()
                .fill(OhiaColors.chipActiveForeground.opacity(0.34))
                .frame(width: diameter * 0.44, height: diameter * 1.72)
                .rotationEffect(.degrees(24))
                .offset(x: phase && !reduceMotion ? diameter * 0.95 : -diameter * 0.95)
            Circle()
                .fill(OhiaColors.chipActiveForeground.opacity(phase && !reduceMotion ? 0.10 : 0.03))
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .opacity(0.72)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: false)) {
                phase = true
            }
        }
    }
}

private struct ComposerHeaderEventHorizonCollapse: View {
    @State private var closing = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(OhiaColors.ohiaRed.opacity(0.88), lineWidth: 2)
                .scaleEffect(closing ? 0.24 : 1.2)
                .opacity(closing ? 0.15 : 0.9)
            Circle()
                .strokeBorder(OhiaColors.chipActiveForeground.opacity(0.72), lineWidth: 1)
                .scaleEffect(closing ? 1.72 : 0.72)
                .opacity(closing ? 0 : 0.9)
            Image(systemName: "circle.dashed.inset.filled")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaRed)
                .rotationEffect(.degrees(closing ? 110 : 0))
                .scaleEffect(closing ? 0.3 : 1)
                .opacity(closing ? 0 : 0.95)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.42)) {
                closing = true
            }
        }
    }
}

private struct ComposerHeaderEmptyDropHint: View {
    let field: ComposerHeaderRecipientField

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 13, weight: .semibold))
            Text("Drop \(field.title)")
                .font(OhiaTypography.cardDetail)
        }
        .foregroundStyle(OhiaColors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OhiaColors.surface(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        )
    }
}

// Subject/date sits left of the summary, sized to its own content (capped
// so a long subject can't crowd the summary out) with a vertical divider
// between them; summary fills whatever's left. Subject now outranks the
// summary in weight — it's the ground-truth line, the summary is an AI
// gist — so subject reads larger/brighter and summary drops to a small,
// secondary, textSecondary tone. Neither ever truncates: the subject
// wraps onto a second line rather than claiming the whole row, and the
// summary just wraps to as many lines as it needs.
private struct ComposerHeaderSubjectSummaryRow: View {
    let subject: String
    let deadlineText: String?
    let receivedAt: Date
    let summary: String

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .padding(.top, 2)
                    Text(subject)
                        .font(readingTextSize.font(base: 16, weight: .semibold, maximumScale: 1.20))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let deadlineText {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OhiaColors.ohiaRed)
                        Text("Due \(deadlineText)")
                            .font(readingTextSize.font(base: 12.5, weight: .medium, maximumScale: 1.20))
                            .foregroundStyle(OhiaColors.ohiaRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ComposerHeaderDateLine(
                        content: ComposerHeaderDateLineContent(
                            absoluteDate: ComposerHeaderDateFormatter.longDate(receivedAt),
                            relativeDate: ComposerHeaderDateFormatter.relative(receivedAt)
                        )
                    )
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.trailing, 20)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(OhiaColors.glassBorderBright)
                    .frame(width: 1)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(readingTextSize.font(base: 14, weight: .regular, maximumScale: 1.20))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ComposerNewMessageCorrespondenceHeaderRow: View {
    @Binding var subject: String
    let onSubjectCommit: (() -> Void)?
    let hasCorrespondenceTarget: Bool
    let snapshot: ComposerHeaderCorrespondenceSnapshot?
    let summary: String
    let isLoading: Bool

    @Environment(\.readingTextSize) private var readingTextSize
    @FocusState private var subjectIsFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)

                    TextField("Subject", text: $subject)
                        .textFieldStyle(.plain)
                        .font(readingTextSize.font(base: 16, weight: .semibold, maximumScale: 1.20))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(OhiaColors.iconPillBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .focused($subjectIsFocused)
                        .onSubmit {
                            onSubjectCommit?()
                        }
                        .onChange(of: subjectIsFocused) { wasFocused, isFocused in
                            if wasFocused, !isFocused {
                                onSubjectCommit?()
                            }
                        }
                        .accessibilityLabel("Email subject")
                }

                if let dateLineContent {
                    ComposerHeaderDateLine(content: dateLineContent)
                }
            }
            .frame(maxWidth: ComposerHeaderLayout.newMessageLeadingColumnWidth, alignment: .leading)
            .padding(.trailing, hasCorrespondenceTarget ? 20 : 0)
            .overlay(alignment: .trailing) {
                if hasCorrespondenceTarget {
                    Rectangle()
                        .fill(OhiaColors.glassBorderBright)
                        .frame(width: 1)
                }
            }

            if hasCorrespondenceTarget {
                Group {
                    if isLoading {
                        AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 520, slotHeight: 32)
                    } else if !summary.isEmpty {
                        Text(summary)
                            .font(readingTextSize.font(base: 14, weight: .regular, maximumScale: 1.20))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateLineContent: ComposerHeaderDateLineContent? {
        guard let lastCorrespondenceAt = snapshot?.lastCorrespondenceAt else { return nil }
        return ComposerHeaderDateLineContent(
            absoluteDatePrefix: "Last on",
            absoluteDate: ComposerHeaderDateFormatter.longDate(lastCorrespondenceAt),
            relativeDate: ComposerHeaderDateFormatter.relative(lastCorrespondenceAt)
        )
    }
}

private struct ComposerHeaderDateLine: View {
    let content: ComposerHeaderDateLineContent

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: content.iconSystemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(content.absoluteDateText)
                Text("•")
                    .foregroundStyle(OhiaColors.ohiaYellow)
                Text(content.relativeDate)
            }
        }
        .font(readingTextSize.font(base: 12.5, weight: .medium, maximumScale: 1.20))
        .foregroundStyle(OhiaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

nonisolated struct ComposerHeaderDateLineContent: Equatable {
    let iconSystemName = "calendar"
    let absoluteDatePrefix: String?
    let absoluteDate: String
    let relativeDate: String

    init(
        absoluteDatePrefix: String? = nil,
        absoluteDate: String,
        relativeDate: String
    ) {
        self.absoluteDatePrefix = absoluteDatePrefix
        self.absoluteDate = absoluteDate
        self.relativeDate = relativeDate
    }

    var absoluteDateText: String {
        guard let absoluteDatePrefix else { return absoluteDate }
        return "\(absoluteDatePrefix) \(absoluteDate)"
    }
}

private enum ComposerHeaderOrbKind: String, CaseIterable, Identifiable {
    case correspondent
    case list

    init(_ kind: ComposeRecipientSuggestion.Kind) {
        switch kind {
        case .correspondent: self = .correspondent
        case .list: self = .list
        }
    }

    var id: String { rawValue }

    var suggestionKind: ComposeRecipientSuggestion.Kind {
        switch self {
        case .correspondent: .correspondent
        case .list: .list
        }
    }

    var title: String {
        switch self {
        case .correspondent: "Correspondent"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .correspondent: "person.crop.circle"
        case .list: "person.3.sequence"
        }
    }
}

private enum ComposerHeaderOrbGeneratorMode: String, CaseIterable, Identifiable {
    case correspondent
    case list

    var id: String { rawValue }

    var kind: ComposerHeaderOrbKind {
        switch self {
        case .correspondent: .correspondent
        case .list: .list
        }
    }

    var title: String { kind.title }
    var symbol: String { kind.symbol }
}

private enum ComposerHeaderRecipientField: String, CaseIterable, Identifiable {
    case to
    case cc
    case bcc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        }
    }

    var composeKind: ComposeRecipientField.Kind {
        switch self {
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        }
    }
}

private enum ComposerHeaderRecipientEmailMode: Equatable {
    case below
    case hover
    case hidden
}

private enum ComposerHeaderRecipientBubbleSize: Equatable {
    case standard
    case compact

    var circleDiameter: CGFloat {
        switch self {
        case .standard: 42
        case .compact: 34
        }
    }

    var initialsSize: CGFloat {
        switch self {
        case .standard: 13
        case .compact: 11
        }
    }

    var kindIconSize: CGFloat {
        switch self {
        case .standard: 8
        case .compact: 7
        }
    }

    var nameFont: Font {
        switch self {
        case .standard:
            Font.system(size: 10.5, weight: .semibold)
        case .compact:
            Font.system(size: 9.5, weight: .semibold)
        }
    }

    var emailFont: Font {
        switch self {
        case .standard:
            Font.system(size: 9.2)
        case .compact:
            Font.system(size: 8.5)
        }
    }

    var labelWidth: CGFloat {
        switch self {
        case .standard: 104
        case .compact: 82
        }
    }

    var padding: EdgeInsets {
        switch self {
        case .standard:
            EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        case .compact:
            EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        }
    }

    var emailSpacing: CGFloat {
        switch self {
        case .standard: 3
        case .compact: 2
        }
    }

    var innerRingInset: CGFloat {
        switch self {
        case .standard: 4
        case .compact: 3
        }
    }

    var removeDiameter: CGFloat {
        switch self {
        case .standard: 16
        case .compact: 15
        }
    }

    var removeOffset: CGFloat {
        switch self {
        case .standard: 0
        case .compact: -1
        }
    }
}

private struct ComposerHeaderStagedRecipient: Identifiable, Hashable {
    let suggestion: ComposeRecipientSuggestion
    let kind: ComposerHeaderOrbKind

    var id: String {
        "staged|\(suggestion.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var viewModel: ComposerHeaderRecipientViewModel {
        ComposerHeaderRecipientViewModel(
            id: id,
            kind: kind,
            name: suggestion.displayTitle,
            email: suggestion.address
        )
    }
}

private struct ComposerHeaderRecipientPlacement: Identifiable {
    let field: ComposerHeaderRecipientField
    let address: ComposeAddressEncoding.ParsedAddress

    // Address-stable identity (not index-based): the render-time index shifts
    // when another recipient is removed mid-collapse, which would desync the
    // collapse-animation tracking keyed on this id.
    var id: String {
        "\(field.rawValue)|\(address.asciiAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var viewModel: ComposerHeaderRecipientViewModel {
        ComposerHeaderRecipientViewModel(
            id: id,
            kind: .correspondent,
            name: address.displayName?.isEmpty == false ? address.displayName! : address.asciiAddress,
            email: address.asciiAddress
        )
    }
}

private struct ComposerHeaderRecipientViewModel: Identifiable, Hashable {
    let id: String
    let kind: ComposerHeaderOrbKind
    let name: String
    let email: String

    var initials: String {
        ComposerPersonInitials.initials(name: name, email: email)
    }
}

/// The one or two letters a person's circle shows: the first letters of the
/// first two words of their name, or of their address when no name is known
/// ("maria.j.santos@example.com" reads "MJ"). Quotes, brackets and other
/// punctuation around a name are passed over ("'Bob' (Ops)" reads "BO").
/// Shared by the recipient orbs and the closed Queue's rail.
enum ComposerPersonInitials {
    static func initials(name: String, email: String) -> String {
        let source = name.isEmpty ? email : name
        let words = source.split { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" }
        let letters = words
            .compactMap { $0.first { $0.isLetter || $0.isNumber } }
            .prefix(2)
        if !letters.isEmpty {
            return String(letters).uppercased()
        }
        return String(email.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }
}

// Chained Date.FormatStyle expressions have hit type-checker limits
// elsewhere in this codebase; cached DateFormatter / RelativeDateTimeFormatter
// instances sidestep that entirely.
private enum ComposerHeaderDateFormatter {
    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func longDate(_ date: Date) -> String {
        longFormatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
