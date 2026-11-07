import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

/// The top pane: a single-message email content viewer that follows the
/// playhead. Re-renders to show the message whose timestamp is nearest the
/// playhead (or, in conversation mode, nearest within the active chapter).
///
/// Loads the actual message body off-main via `LockReadoutBodyLoader` and
/// renders it through `LockedEmailHTMLView` (full HTML via WKWebView) or
/// the `LockReadoutBodyContent.plainText` path (plain-text / fallback).
/// Body loads are debounced (~80ms) so a rapid playhead drag doesn't fire
/// hundreds of file reads. A cross-fade animates the playhead-message
/// swap; with `LockReadoutBodyLoader`'s async load the previous message
/// stays visible until the next body is ready (plan §Semantic viewport).
struct TimelineSemanticViewport: View {

    @Bindable var workspace: TimelineWorkspaceState
    @Bindable var constellationState: ConstellationState
    let modelContext: ModelContext
    /// False while the parent is applying a Timeline filter. The viewport stays
    /// mounted for stable WebKit identity, but discards retained message state
    /// so the pre-filter email cannot flash back after the new snapshot lands.
    let contentAvailable: Bool
    /// Live custom-category catalog so the masthead classification pulldown can
    /// list user-defined categories and render their assigned chips. Forwarded
    /// from `ConstellationModeView` via
    /// `TimelineWorkspaceView`.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []
    /// Shared per-message action bundle. The header's category pulldown
    /// persists the canonical shared category and custom-key edits through
    /// the same action every other lens uses.
    var actions: FrontPageMessageActionHandlers = FrontPageMessageActionHandlers()

    @State private var bodyState: LockedEmailCardContent.BodyState = .loading
    @State private var loadedMessageID: UUID?
    @State private var loadGeneration: Int = 0
    @State private var displayedMessage: TimelineLayoutSnapshot.MessageMeta?
    @State private var headerParticipants: [HeaderParticipant] = []
    @State private var headerAttachments: [HeaderAttachment] = []
    /// Canonical classification plus its independent, catalog-restricted custom
    /// keys for the currently loaded message. Updated optimistically before the
    /// authoritative persist completes.
    @State private var assignedClassification: MailClassification?
    @State private var assignedCustomKeys: Set<String> = []
    @State private var classificationPickerShown = false

    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(\.readingTextSize) private var readingTextSize
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguageRaw: String = ""
    @AppStorage(ModelManager.selectedTranslationEngineKey, store: OhiaSharedDefaults.store)
    private var selectedTranslationEngineRaw = TranslationEngineKind.defaultEngine.rawValue
    @State private var translation = EmailTranslationModel()
    /// Plain body text of the currently loaded message, retained so the
    /// translate offer can re-evaluate when the language changes.
    @State private var loadedPlainText: String = ""

    private struct HeaderFingerprint: Equatable {
        let messageID: UUID?
        let metadata: TimelineLayoutSnapshot.MessageMeta?
        let contentAvailable: Bool
    }

    struct HeaderParticipant: Identifiable, Equatable {
        let id: String        // lowercased email
        let displayName: String
        let role: ParticipantRole
        enum ParticipantRole: Int { case to, cc, bcc, from }
    }

    private struct HeaderAttachment: Identifiable, Equatable {
        let id: UUID
        let filename: String
        let kind: TimelineAttachmentKind
        let filePath: String?
        let isInline: Bool?

        var isBodyImagePreview: Bool {
            TimelineSemanticViewport.shouldRenderSeparateImagePreview(
                kind: kind,
                filePath: filePath,
                isInline: isInline
            )
        }
    }

    var body: some View {
        ZStack {
            // Keep the message body view identity stable while the playhead
            // moves. The body can host a WebKit-backed HTML view, and tearing
            // that view down on every scrub can race WebKit's display link.
            // The previous loaded message stays visible until the next body is
            // ready, then the content swaps in place.
            Group {
                if contentAvailable == false || workspace.currentSnapshot == nil {
                    Color.clear
                } else if let meta = renderableMessage {
                    VStack(alignment: .leading, spacing: 0) {
                        header(for: meta)
                        if headerAttachments.isEmpty == false {
                            attachmentsStrip(headerAttachments)
                        }
                        Divider().background(OhiaColors.glassBorder)
                        body(for: meta)
                    }
                } else if workspace.playheadMessageID != nil {
                    OhiaLoadingIndicator(accessibilityLabel: "Loading message")
                } else {
                    emptyState
                        .id("empty")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: displayedMessage?.messageID ?? workspace.playheadMessageID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OhiaColors.glassPanel)
        .onChange(of: headerFingerprint) { previous, current in
            handleHeaderFingerprintChange(previous: previous, current: current)
        }
        .onAppear {
            scheduleBodyLoad(
                forMessageID: contentAvailable ? workspace.playheadMessageID : nil
            )
        }
        .onChange(of: translationConfigKey, initial: true) { _, _ in
            configureTranslation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateTimelineTranslation)) { _ in
            regenerateTranslation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaAccountIdentityChanged)) { _ in
            scheduleBodyLoad(forMessageID: workspace.playheadMessageID)
        }
    }

    private var headerFingerprint: HeaderFingerprint {
        HeaderFingerprint(
            messageID: workspace.playheadMessageID,
            metadata: workspace.playheadMessage,
            contentAvailable: contentAvailable
        )
    }

    /// Retained body content is valid only while it still belongs to the
    /// authoritative playhead message. A filter can replace the snapshot before
    /// the body debounce completes; never pair that new snapshot with the
    /// pre-filter email during the handoff.
    private var renderableMessage: TimelineLayoutSnapshot.MessageMeta? {
        guard let displayedMessage else {
            return workspace.playheadMessage
        }
        guard displayedMessage.messageID == workspace.playheadMessageID else {
            return nil
        }
        return displayedMessage
    }

    private func handleHeaderFingerprintChange(
        previous: HeaderFingerprint,
        current: HeaderFingerprint
    ) {
        if current.contentAvailable == false {
            scheduleBodyLoad(forMessageID: nil)
            return
        }
        if previous.contentAvailable == false {
            scheduleBodyLoad(forMessageID: current.messageID)
            return
        }
        if previous.messageID != current.messageID {
            scheduleBodyLoad(forMessageID: current.messageID)
            return
        }
        guard let metadata = current.metadata,
              metadata.messageID == loadedMessageID else { return }
        displayedMessage = metadata
    }

    private func header(for meta: TimelineLayoutSnapshot.MessageMeta) -> some View {
        let searchHighlight = activeSearchHighlight(for: meta)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Masthead title on a single fixed-height line. The height is
                // pinned (Self.titleRowHeight) so the row never resizes between
                // scripts — Latin, CJK, Arabic, Thai, Devanagari each have a
                // different intrinsic line box, and letting the row follow the
                // tallest one made the whole header (and the date chip below)
                // jump while scrubbing. Long subjects scale down to fit one
                // line rather than wrapping or truncating (no ellipsis), so the
                // full title stays visible in every language.
                Text(SearchMatchTextHighlighter.highlighted(meta.subject.isEmpty ? "(no subject)" : meta.subject, highlight: searchHighlight))
                    .font(readingTextSize.font(base: 20, weight: .bold, maximumScale: 1.20))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    // Scale far enough down (to ~6pt) that a one-line fit is
                    // found before SwiftUI would fall back to an ellipsis —
                    // the app forbids truncation dots, and a subject this long
                    // is unreadable at that size anyway, so no value is lost.
                    .minimumScaleFactor(0.3)
                    .frame(
                        height: readingTextSize.spacing(Self.titleRowHeight, maximumScale: 1.20),
                        alignment: .leading
                    )
                Spacer(minLength: 8)
                remoteImageChip(for: meta)
                EmailTranslationControl(
                    model: translation,
                    mode: .columns,
                    onTranslate: startTranslation
                )
            }
            HStack(spacing: 8) {
                MessageStatusMark(
                    descriptor: meta.statusDescriptor,
                    size: 13,
                    showsDeadlineSignal: false,
                    showsTextGloss: true,
                    showsAmbientSharedEvidence: true,
                    glossFont: .system(size: 10, weight: .semibold)
                )
                .layoutPriority(1)
                classificationControl
                // Deadline trails the whole line — after the category pulldown —
                // so the long "Deadline (…)" sits at the right end, matching the
                // Front Page. Lowest layout priority so it sheds to its bare
                // calendar glyph before the leading status labels do.
                MessageStatusDeadlineMark(
                    descriptor: meta.statusDescriptor,
                    size: 13,
                    glossFont: .system(size: 10, weight: .semibold)
                )
                .layoutPriority(-1)
            }
            metaLine(for: meta)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .translationLanguageDownload(translation, service: appServices?.translationService)
    }

    // MARK: - Remote images

    private func remoteImageSenderAddress(for meta: TimelineLayoutSnapshot.MessageMeta) -> String? {
        guard !meta.isSentByUser else { return nil }
        let address = meta.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }

    private func loadsRemoteImages(for meta: TimelineLayoutSnapshot.MessageMeta) -> Bool {
        RemoteImageSenderAllowlist.shared.isAllowed(remoteImageSenderAddress(for: meta))
    }

    @ViewBuilder
    private func remoteImageChip(for meta: TimelineLayoutSnapshot.MessageMeta) -> some View {
        let senderAddress = remoteImageSenderAddress(for: meta)
        let loadsRemoteImages = loadsRemoteImages(for: meta)
        if Self.shouldShowRemoteImageChip(
            senderAddress: senderAddress,
            bodyState: bodyState,
            loadsRemoteImages: loadsRemoteImages
        ) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    RemoteImageSenderAllowlist.shared.allow(senderAddress)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("Load images")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.emblem)
            .fixedSize(horizontal: true, vertical: false)
            .help("Load remote images and trust this sender")
            .accessibilityLabel("Load remote images from this sender")
            .transition(.opacity)
        }
    }

    nonisolated static func shouldShowRemoteImageChip(
        senderAddress: String?,
        bodyState: LockedEmailCardContent.BodyState,
        loadsRemoteImages: Bool
    ) -> Bool {
        guard !loadsRemoteImages,
              let senderAddress,
              !senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .loaded(let body) = bodyState,
              let htmlDocument = body.htmlDocument,
              !body.isEmpty else {
            return false
        }
        return RemoteImageBlocking.containsRemoteImages(in: htmlDocument.html)
    }

    /// Participants (leading) + date (trailing) on one line. The date moved here
    /// off the status line so the status marks and the category pulldown can
    /// share a line. The `Spacer` lives *outside* the participant `if` so the
    /// date chip stays pinned to the trailing edge whether or not participant
    /// chips are present — `headerParticipants` is repopulated asynchronously
    /// per message, so a conditional spacer made the date flip to a leading
    /// position every time the strip was briefly empty mid-load, reading as
    /// the chip jumping sideways while scrubbing.
    @ViewBuilder
    private func metaLine(for meta: TimelineLayoutSnapshot.MessageMeta) -> some View {
        HStack(spacing: 8) {
            if headerParticipants.isEmpty == false {
                participantsStrip
            }
            Spacer(minLength: 8)
            dateLabel(for: meta)
        }
    }

    /// Absolute date + time in a playhead-matching yellow chip. Full month name,
    /// bold type, and `ohiaYellow` fill so the masthead stamp reads at the same
    /// weight as the ruler playhead bubble.
    private func dateLabel(for meta: TimelineLayoutSnapshot.MessageMeta) -> some View {
        Text(Self.headerDateFormatter.string(from: meta.date))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(OhiaColors.ohiaYellow)
            )
            .fixedSize()
    }

    /// Fixed height for the masthead title line. Sized to clear the tallest
    /// script's single-line box at 20pt bold (CJK, Thai, Devanagari and
    /// Arabic all overrun Latin's ~24pt line) plus a little headroom, and to
    /// stay taller than the trailing translate control — so the title row is
    /// the same height in every language and the date chip below it never
    /// moves. Bump this if a script ever clips top/bottom.
    private static let titleRowHeight: CGFloat = 34

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy HH:mm"
        return formatter
    }()

    /// Clickable participant chips. Clicking one writes both the participant
    /// identity and its exact header role into the shared Voices filter — the
    /// same role-specific behavior as the multitrack chip overlay. Each chip carries a
    /// small role prefix (`to:` / `cc:` / `bcc:` / `from:`) so the reader can see
    /// the message's anatomy at a glance instead of guessing.
    private var participantsStrip: some View {
        HStack(spacing: 4) {
            ForEach(headerParticipants.enumerated(), id: \.element.id) { index, participant in
                let startsNewRoleGroup = index > 0
                    && headerParticipants[index - 1].role != participant.role
                HStack(spacing: startsNewRoleGroup ? 6 : 0) {
                    Rectangle()
                        .fill(OhiaColors.surface(1))
                        .frame(width: startsNewRoleGroup ? 1 : 0, height: 14)
                        .opacity(startsNewRoleGroup ? 1 : 0)
                        .accessibilityHidden(true)

                    Button {
                        constellationState.filter = Self.togglingParticipantFilter(
                            participant,
                            in: constellationState.filter
                        )
                    } label: {
                        let active = Self.participantFilterIsActive(
                            participant,
                            in: constellationState.filter
                        )
                        HStack(spacing: 4) {
                            Text(rolePrefix(participant.role))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .opacity(0.7)
                            Text(participant.displayName)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        // Participant chip is a toggle (isolate correspondent
                        // on/off); follow `chipActive*` / `chipRest*` idiom.
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(active ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    active ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                                    lineWidth: 1
                                )
                        )
                        .foregroundStyle(active ? OhiaColors.chipActiveForeground : OhiaColors.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func rolePrefix(_ role: HeaderParticipant.ParticipantRole) -> String {
        switch role {
        case .to:   return "to"
        case .cc:   return "cc"
        case .bcc:  return "bcc"
        case .from: return "from"
        }
    }

    static func togglingParticipantFilter(
        _ participant: HeaderParticipant,
        in filter: VectorFilter
    ) -> VectorFilter {
        var updated = filter
        let scope = correspondentScope(for: participant.role)
        if participantFilterIsActive(participant, in: filter) {
            updated.correspondentQuery = ""
        } else {
            updated.listIds = nil
            updated.correspondentQuery = participant.id
            updated.correspondentScopes = [scope]
        }
        return updated
    }

    private static func participantFilterIsActive(
        _ participant: HeaderParticipant,
        in filter: VectorFilter
    ) -> Bool {
        filter.correspondentQuery == participant.id
            && filter.correspondentScopes == [correspondentScope(for: participant.role)]
    }

    private static func correspondentScope(
        for role: HeaderParticipant.ParticipantRole
    ) -> CorrespondentScope {
        switch role {
        case .from: .from
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        }
    }

    // MARK: - Classification pulldown

    private var assignedPurposeState: TimelinePurposeState {
        TimelinePurposeState(classification: assignedClassification)
    }

    /// The shared category remains Timeline's primary grouping/coloring value;
    /// user-created categories are additional flat assignments.
    private var classificationControl: some View {
        HStack(spacing: 6) {
            Button {
                classificationPickerShown.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: assignedPurposeState.systemImageName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .opacity(0.85)
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(OhiaColors.iconPillBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(assignedClassification == nil && assignedCustomKeys.isEmpty
                ? "Set classification"
                : "Change classification")
            .accessibilityLabel(Text(classificationAccessibilityLabel))
            .popover(isPresented: $classificationPickerShown, arrowEdge: .bottom) {
                classificationPicker
            }

            FilterChipLabel(
                text: assignedPurposeState.displayLabel,
                isOn: assignedPurposeState.purpose != nil
            )
            ForEach(customCategoryCatalog.filter { assignedCustomKeys.contains($0.key) }) { descriptor in
                FilterChipLabel(text: descriptor.displayName, isOn: true)
            }
        }
    }

    private var classificationAccessibilityLabel: String {
        let customLabels = customCategoryCatalog
            .filter { assignedCustomKeys.contains($0.key) }
            .map(\.displayName)
        let secondaryLabels = customLabels
        let secondarySuffix = secondaryLabels.isEmpty
            ? ""
            : ", categories: \(secondaryLabels.joined(separator: ", "))"
        return "Category: \(assignedPurposeState.displayLabel)\(secondarySuffix). Change classification."
    }

    private var classificationPicker: some View {
        MenuPopoverContent(headerLabel: "Category") {
            ForEach(MailPurpose.allCases, id: \.rawValue) { purpose in
                MenuRow(
                    name: purpose.displayLabel,
                    symbolName: purpose.systemImageName,
                    isChecked: assignedClassification?.purpose == purpose,
                    action: { selectPurpose(purpose) }
                )
            }

            if customCategoryCatalog.isEmpty == false {
                classificationDivider
            }
            ForEach(customCategoryCatalog) { descriptor in
                MenuRow(
                    name: CustomCategoryStore.menuLabel(for: descriptor),
                    symbolName: ToggleIconography.customCategorySymbolName,
                    isChecked: assignedCustomKeys.contains(descriptor.key),
                    action: {
                        var nextCustom = assignedCustomKeys
                        if nextCustom.contains(descriptor.key) {
                            nextCustom.remove(descriptor.key)
                        } else {
                            nextCustom.insert(descriptor.key)
                        }
                        applyClassificationEdit(assignedClassification, custom: nextCustom)
                    }
                )
            }
        }
    }

    private var classificationDivider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(height: 1)
            .padding(.vertical, 3)
    }

    private func selectPurpose(_ purpose: MailPurpose) {
        let next = MailClassification.userAssigned(purpose: purpose)
        applyClassificationEdit(next, custom: assignedCustomKeys)
    }

    private func applyClassificationEdit(
        _ classification: MailClassification?,
        custom: Set<String>
    ) {
        guard let id = loadedMessageID else { return }
        assignedClassification = classification
        assignedCustomKeys = custom
        actions.setClassification(id, classification, custom)
    }

    /// Attachments strip below the header. Per plan §Semantic viewport
    /// line 178, clicking an attachment writes `isolatedAttachmentKind`
    /// so the multitrack highlights every message carrying that kind.
    /// The strip caps at `maxVisibleAttachments` named chips and folds
    /// the rest into a single overflow chip — preserves the no-ellipses
    /// rule from CLAUDE.md while keeping multi-image emails readable.
    @ViewBuilder
    private func attachmentsStrip(_ attachments: [HeaderAttachment]) -> some View {
        let visible = attachments.prefix(Self.maxVisibleAttachments)
        let hiddenCount = attachments.count - visible.count
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textSecondary)
            ForEach(Array(visible)) { attachment in
                attachmentChip(attachment)
            }
            if hiddenCount > 0 {
                overflowChip(count: hiddenCount)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private static let maxVisibleAttachments = 5

    @ViewBuilder
    private func attachmentChip(_ attachment: HeaderAttachment) -> some View {
        Button {
            let current = workspace.isolatedAttachmentKind
            workspace.isolateAttachmentKind(current == attachment.kind ? nil : attachment.kind)
        } label: {
            let active = workspace.isolatedAttachmentKind == attachment.kind
            HStack(spacing: 4) {
                Image(systemName: attachment.kind.symbolName)
                    .font(.system(size: 10))
                Text(attachment.filename)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // Attachment chip is a toggle (isolate attachment kind on/off);
            // follow `chipActive*` / `chipRest*` idiom.
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        active ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                        lineWidth: 1
                    )
            )
            .foregroundStyle(active ? OhiaColors.chipActiveForeground : OhiaColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    /// "+N more" chip rendered in the emblem style. Uses a real `+` glyph
    /// rather than the elided-trailing dots banned by CLAUDE.md.
    @ViewBuilder
    private func overflowChip(count: Int) -> some View {
        Text("+\(count) more")
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OhiaColors.buttonBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            )
            .foregroundStyle(OhiaColors.ohiaGreen)
    }

    @ViewBuilder
    private func body(for meta: TimelineLayoutSnapshot.MessageMeta) -> some View {
        GeometryReader { proxy in
            let maxBodyHeight = max(80, proxy.size.height - 16)
            let searchHighlight = activeSearchHighlight(for: meta)
            let original = TimelineEmailBodyView(
                bodyState: bodyState,
                imageAttachments: separateImagePreviewAttachments(
                    from: headerAttachments,
                    bodyState: bodyState
                ),
                maxBodyHeight: maxBodyHeight,
                senderAddress: meta.isSentByUser ? nil : meta.fromAddress,
                searchHighlight: searchHighlight
            )
            if translation.translationVisible {
                EmailTranslationColumns(
                    leadingHeader: translation.sourceLanguageAutonym ?? "Original",
                    trailingHeader: translation.targetLanguageAutonym
                ) {
                    original
                } trailing: {
                    TranslationColumnBody(model: translation, baseFontSize: 12.5)
                }
            } else {
                original
            }
        }
    }

    // MARK: - Translation

    private var translationConfigKey: String {
        let idKey = loadedMessageID?.uuidString ?? "none"
        return "\(idKey)|\(summaryOutputLanguageRaw)|\(selectedTranslationEngineRaw)|\(loadedPlainText.count)"
    }

    private func configureTranslation() {
        guard let id = loadedMessageID else { return }
        translation.configure(
            messageID: id,
            bodyText: loadedPlainText,
            targetLanguage: SummarizationTargetLanguage.ohiaPreferred()
        )
    }

    private func startTranslation() {
        guard let service = appServices?.translationService else { return }
        translation.translate(using: service)
    }

    private func regenerateTranslation() {
        guard let service = appServices?.translationService else { return }
        translation.regenerate(using: service)
    }

    private func activeSearchHighlight(for meta: TimelineLayoutSnapshot.MessageMeta) -> SearchMatchHighlight? {
        workspace.searchMatchHighlight?.scoped(to: meta.messageID)
    }

    private var emptyState: some View {
        return OhiaEmptyPaneStateView(
            systemName: "line.3.horizontal.decrease.circle",
            title: "No messages meet the filter criteria",
            detail: "Adjust the current filters to bring messages into view."
        )
    }

    private func scheduleBodyLoad(forMessageID id: UUID?) {
        // Invalidate every earlier debounce/load before clearing or scheduling
        // a replacement. Filter suppression passes `nil`; without this bump an
        // already-sleeping task could repopulate the stale pre-filter email.
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let id else {
            loadedMessageID = nil
            displayedMessage = nil
            headerParticipants = []
            headerAttachments = []
            assignedClassification = nil
            assignedCustomKeys = []
            loadedPlainText = ""
            bodyState = .loading
            return
        }
        // Debounce for 80ms, then load. A subsequent change cancels this load
        // by incrementing the generation past the captured value before the
        // await completes.
        if id != loadedMessageID, shouldShowLoadingPlaceholder {
            bodyState = .loading
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard generation == loadGeneration else { return }
            guard id == workspace.playheadMessageID else { return }
            await performLoad(messageID: id, generation: generation)
        }
    }

    private func performLoad(messageID: UUID, generation: Int) async {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in msg.id == messageID }
        )
        guard let message = try? modelContext.fetch(descriptor).first else {
            if generation == loadGeneration {
                bodyState = .failed
                loadedPlainText = ""
                displayedMessage = workspace.currentSnapshot?.messageMetadata[messageID]
                headerParticipants = []
                headerAttachments = []
                assignedClassification = nil
                assignedCustomKeys = []
                loadedMessageID = messageID
            }
            return
        }
        let htmlPath = message.bodyHtmlPath
        let textPath = message.bodyTextPath
        let rawPath = message.rawPath
        // Snapshot header data on the main actor while we hold the
        // SwiftData reference — these arrays back the participant chips
        // and attachment chips that the user can click to drive
        // workspace.isolate*.
        let participants = Self.timelineHeaderParticipants(for: message)
        let attachments = headerAttachments(for: message)
        let classification = resolvedClassification(for: message)
        let result = await Task.detached(priority: .userInitiated) {
            LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath)
        }.value
        guard generation == loadGeneration else { return }
        switch result {
        case .loaded(let source):
            let content = LockReadoutBodyContent(source: source)
            bodyState = .loaded(content)
            loadedPlainText = content.plainText
        case .missing, .failed:
            bodyState = .failed
            loadedPlainText = ""
        }
        headerParticipants = participants
        headerAttachments = attachments
        assignedClassification = classification.classification
        assignedCustomKeys = classification.custom
        displayedMessage = workspace.currentSnapshot?.messageMetadata[messageID]
        loadedMessageID = messageID
    }

    /// Decodes canonical classification independently from custom keys and
    /// restricts custom keys to the live catalog so removed keys do not render.
    private func resolvedClassification(
        for message: Message
    ) -> AssignedClassification {
        Self.decodeAssignedClassification(
            classificationJSON: message.analysis?.mailClassificationJSON,
            customKeysJSON: message.analysis?.customCategoryKeysJSON,
            catalogKeys: Set(customCategoryCatalog.map(\.key))
        )
    }

    struct AssignedClassification: Equatable {
        let classification: MailClassification?
        let purposeState: TimelinePurposeState
        let purpose: MailPurpose?
        let custom: Set<String>
    }

    /// Pure canonical decode seam shared by the Timeline editor and focused
    /// tests. Invalid or absent classification JSON remains pending; a valid
    /// uncertain classification remains distinct from pending and `.other`.
    static func decodeAssignedClassification(
        classificationJSON: String?,
        customKeysJSON: String?,
        catalogKeys: Set<String>
    ) -> AssignedClassification {
        let classification = MailClassificationJSON.decode(classificationJSON)
        return AssignedClassification(
            classification: classification,
            purposeState: TimelinePurposeState(classification: classification),
            purpose: classification?.purpose,
            custom: Set(CustomCategoryKeysJSON.decode(customKeysJSON)).intersection(catalogKeys)
        )
    }

    private var shouldShowLoadingPlaceholder: Bool {
        guard loadedMessageID != nil else { return true }
        if case .loaded = bodyState { return false }
        return true
    }

    static func timelineHeaderParticipants(for message: Message) -> [HeaderParticipant] {
        // Index participants by lowercased email so roles and canonical names
        // stay stable while account-owned addresses resolve through the
        // matching Identity below.
        var byEmail: [String: (displayName: String?, role: HeaderParticipant.ParticipantRole)] = [:]
        for mp in message.participants {
            guard let p = mp.participant else { continue }
            let key = p.emailAddress.lowercased()
            guard key.isEmpty == false else { continue }
            let role: HeaderParticipant.ParticipantRole
            switch mp.role {
            case .from:        role = .from
            case .to:          role = .to
            case .cc:          role = .cc
            case .bcc:         role = .bcc
            }
            byEmail[key] = (p.displayName, role)
        }

        var seen: Set<String> = []
        var result: [HeaderParticipant] = []
        let fromKey = message.fromAddress.lowercased()
        if fromKey.isEmpty == false, seen.insert(fromKey).inserted {
            let canonical = byEmail[fromKey]?.displayName
            let display = Self.timelineHeaderFromDisplayName(
                for: message,
                canonicalDisplayName: canonical
            )
            result.append(
                HeaderParticipant(id: fromKey, displayName: display, role: .from)
            )
        }
        for mp in message.participants {
            guard let p = mp.participant else { continue }
            let key = p.emailAddress.lowercased()
            guard key.isEmpty == false, seen.insert(key).inserted else { continue }
            let role = byEmail[key]?.role ?? .to
            result.append(
                HeaderParticipant(
                    id: key,
                    displayName: Self.timelineParticipantDisplayName(
                        for: message,
                        emailAddress: p.emailAddress,
                        canonicalDisplayName: p.displayName
                    ),
                    role: role
                )
            )
        }
        return result.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.role.rawValue != rhs.element.role.rawValue {
                    return lhs.element.role.rawValue < rhs.element.role.rawValue
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func timelineHeaderFromDisplayName(
        for message: Message,
        canonicalDisplayName: String?
    ) -> String {
        if message.isSentByUser {
            return trimmedNonEmpty(
                accountIdentityDisplayName(for: message, emailAddress: message.fromAddress)
            )
                ?? trimmedNonEmpty(message.fromName)
                ?? trimmedNonEmpty(message.fromAddress)
                ?? trimmedNonEmpty(canonicalDisplayName)
                ?? "Unknown sender"
        }

        return trimmedNonEmpty(canonicalDisplayName)
            ?? trimmedNonEmpty(message.fromName)
            ?? trimmedNonEmpty(message.fromAddress)
            ?? "Unknown sender"
    }

    static func timelineParticipantDisplayName(
        for message: Message,
        emailAddress: String,
        canonicalDisplayName: String?
    ) -> String {
        trimmedNonEmpty(
            accountIdentityDisplayName(for: message, emailAddress: emailAddress)
        )
            ?? trimmedNonEmpty(canonicalDisplayName)
            ?? trimmedNonEmpty(emailAddress)
            ?? "Unknown participant"
    }

    private static func accountIdentityDisplayName(
        for message: Message,
        emailAddress: String
    ) -> String? {
        guard let account = message.account else { return nil }
        let address = normalizedAddress(emailAddress)
        guard !address.isEmpty,
              let matching = account.identities.first(where: { normalizedAddress($0.address) == address }) else {
            return nil
        }
        return trimmedNonEmpty(matching.displayName)
    }

    private static func normalizedAddress(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func headerAttachments(for message: Message) -> [HeaderAttachment] {
        message.attachments.map { att in
            HeaderAttachment(
                id: att.id,
                filename: MIMEHeaderDecoder.decodeEncodedWords(att.filename),
                kind: TimelineAttachmentKind.classify(
                    mimeType: att.mimeType,
                    fileName: att.filename
                ),
                filePath: att.filePath,
                isInline: att.isInline
            )
        }
    }

    static func shouldRenderSeparateImagePreview(
        kind: TimelineAttachmentKind,
        filePath: String?,
        isInline: Bool?,
        bodyAlreadyRendersImage: Bool = false
    ) -> Bool {
        guard kind == .image,
              isInline != true,
              !bodyAlreadyRendersImage,
              let filePath,
              filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return true
    }

    private func separateImagePreviewAttachments(
        from attachments: [HeaderAttachment],
        bodyState: LockedEmailCardContent.BodyState
    ) -> [HeaderAttachment] {
        let bodyAlreadyRendersImage = Self.bodyAlreadyRendersImage(bodyState)
        return attachments.filter { attachment in
            Self.shouldRenderSeparateImagePreview(
                kind: attachment.kind,
                filePath: attachment.filePath,
                isInline: attachment.isInline,
                bodyAlreadyRendersImage: bodyAlreadyRendersImage
            )
        }
    }

    static func bodyAlreadyRendersImage(_ bodyState: LockedEmailCardContent.BodyState) -> Bool {
        guard case .loaded(let content) = bodyState,
              let html = content.htmlDocument?.html else {
            return false
        }
        return htmlContainsImageTag(html)
    }

    static func htmlContainsImageTag(_ html: String) -> Bool {
        html.range(
            of: #"<img\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private struct TimelineEmailBodyView: View {
        let bodyState: LockedEmailCardContent.BodyState
        let imageAttachments: [HeaderAttachment]
        let maxBodyHeight: CGFloat
        var senderAddress: String? = nil
        var searchHighlight: SearchMatchHighlight? = nil

        @State private var cachedImages: [UUID: NSImage] = [:]

        var body: some View {
            if imageAttachments.isEmpty {
                LockedEmailCardBody(
                    bodyState: bodyState,
                    maxBodyHeight: maxBodyHeight,
                    senderAddress: senderAddress,
                    searchHighlight: searchHighlight,
                    blendsHTMLWithCanvas: true
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if shouldShowBodySection {
                            // Continuous presentation renders both plain-text and
                            // HTML bodies at their natural height so the body and
                            // image share this single outer scroll pane.
                            LockedEmailCardBody(
                                bodyState: bodyState,
                                maxBodyHeight: maxBodyHeight,
                                senderAddress: senderAddress,
                                searchHighlight: searchHighlight,
                                blendsHTMLWithCanvas: true,
                                presentation: .continuousHostScroll
                            )
                        }
                        imagePreviewStack
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: maxBodyHeight, alignment: .top)
                .task(id: imageLoadKey) {
                    var images: [UUID: NSImage] = [:]
                    for attachment in imageAttachments {
                        guard let path = attachment.filePath,
                              FileManager.default.fileExists(atPath: path),
                              let image = NSImage(contentsOfFile: path) else {
                            continue
                        }
                        images[attachment.id] = image
                    }
                    cachedImages = images
                }
            }
        }

        private var shouldShowBodySection: Bool {
            switch bodyState {
            case .loading:
                return cachedImages.isEmpty
            case .failed:
                return cachedImages.isEmpty
            case .loaded(let content):
                return content.isEmpty == false
            }
        }

        private var imageLoadKey: String {
            imageAttachments
                .map { "\($0.id.uuidString):\($0.filePath ?? "")" }
                .joined(separator: "|")
        }

        @ViewBuilder
        private var imagePreviewStack: some View {
            if hasLoadedImageForCurrentAttachments {
                ForEach(imageAttachments) { attachment in
                    if let image = cachedImages[attachment.id] {
                        imagePreview(image: image, attachment: attachment)
                    }
                }
            } else if shouldShowBodySection == false {
                LockedEmailCardBody(
                    bodyState: .failed,
                    maxBodyHeight: maxBodyHeight
                )
            }
        }

        private var hasLoadedImageForCurrentAttachments: Bool {
            imageAttachments.contains { cachedImages[$0.id] != nil }
        }

        private func imagePreview(image: NSImage, attachment: HeaderAttachment) -> some View {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: imagePreviewHeight)
                .padding(.horizontal, 16)
                .accessibilityLabel("Preview of \(attachment.filename)")
        }

        private var imagePreviewHeight: CGFloat {
            max(220, min(maxBodyHeight, 560))
        }
    }
}
