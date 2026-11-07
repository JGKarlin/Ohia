import AppKit
import SwiftUI
import OhiaCore
import OhiaML

/// The focused, restructured "newspaper article" reader that replaces the page
/// in place (an in-place takeover — **not** the global lock session). Masthead
/// headline, byline, full + relative dateline, the summary as an italic lede,
/// then the body. The body is **hybrid**: conversational / plain-text mail
/// renders as a single readable text column; rich-HTML mail keeps its original
/// WebView rendering under newspaper chrome.
struct FrontPageReaderView: View {
    let article: FrontPageArticle
    let liveSummaries: [String: String]
    let summaryUnavailableMessageIds: Set<String>
    let isSummaryRegenerating: Bool
    /// Resolves the conversation and attachments only after the reader
    /// takeover has had a chance to paint. The controller moves the expensive
    /// RFC-header graph lookup into a private SwiftData context.
    let loadReaderPayload: @MainActor (UUID) async -> FrontPageReaderPayload
    let onRequestSummary: (String, OnDemandSummaryScope) -> Void
    let onBack: () -> Void
    /// Per-message action closures driving reader context actions and automatic
    /// read-state reconciliation. Acts on the single focused article.
    let actions: FrontPageMessageActionHandlers
    let searchHighlight: SearchMatchHighlight?
    /// Live custom-category catalog appended to the flat category picker.
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    /// Called after a manual shared-purpose or custom-category edit.
    let onClassificationChanged: (MailClassification?, Set<String>) -> Void

    @State private var content: ReaderContent = .loading
    @State private var classificationPickerShown = false
    /// Attachments on the focused article, loaded on focus. Drives the
    /// Attachments rail (wide windows) and end-of-story dossier (narrow).
    @State private var attachments: [LockedAttachmentSummary] = []
    /// To/Cc/Bcc metadata for the focused message, resolved from the same
    /// SwiftData fetch that supplies the reader's thread context.
    @State private var recipientHeader: FrontPageRecipientHeader = .empty

    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(\.readingTextSize) private var readingTextSize
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguageRaw: String = ""
    @AppStorage(ModelManager.selectedTranslationEngineKey, store: OhiaSharedDefaults.store)
    private var selectedTranslationEngineRaw = TranslationEngineKind.defaultEngine.rawValue
    @State private var translation = EmailTranslationModel()
    /// The article's own (quote-stripped) plain body, retained so a language
    /// switch can re-evaluate the translate offer without re-resolving the body.
    @State private var resolvedBodyText: String = ""

    private enum ReaderContent {
        case loading
        case empty
        case failed
        case article(ResolvedArticle)
    }

    /// The fully-resolved reader: the article's own (quote-stripped) body plus
    /// the prior conversation. Rich source HTML is retained so embedded quoted
    /// or forwarded history keeps its links and inline content; remote-image
    /// loading remains independently controlled by sender trust.
    private struct ResolvedArticle {
        let bodyText: String
        let webDocument: LockReadoutHTMLDocument?
        let replies: [FrontPageReplyNode]
        let containsEmbeddedHTMLHistory: Bool
    }

    private struct ResolvedReplies {
        let nodes: [FrontPageReplyNode]
        let containsEmbeddedHTMLHistory: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OhiaColors.glassBorder)
            topMatter
            Divider().overlay(OhiaColors.glassBorder)
            readerBodyRegion
        }
        .background(OhiaColors.spaceBackground)
        // Right-click anywhere in the reader → the same message context menu as
        // the cards. A window-scoped monitor (bounds-filtered to the reader)
        // also suppresses the HTML body WebView's default Cut/Copy menu.
        .background(
            TimelineEventCatcher(
                onRightClick: { point, view in actions.presentMenu(article.id, point, view) }
            )
        )
        .onChange(of: article.id) { _, _ in
            // Drop the previous article's catalog immediately so a stale dossier
            // never flashes before `.task` reloads attachments for the new one.
            attachments = []
            recipientHeader = .empty
            // Clear the retained body so the translate offer resets to "off"
            // until the new article's body resolves.
            resolvedBodyText = ""
        }
        .onChange(of: translationConfigKey, initial: true) { _, _ in
            configureTranslation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateFrontPageTranslation)) { _ in
            regenerateTranslation()
        }
        .task(id: article.id) {
            let payload = await loadReaderPayload(article.id)
            guard Task.isCancelled == false else { return }
            recipientHeader = payload.threadContext.recipientHeader
            attachments = payload.attachments
            markReadOnFocusIfNeeded()
            requestSummaryIfNeeded()
            await resolveContent(threadContext: payload.threadContext)
        }
    }

    /// Fixed top matter — kicker, headline, byline, and the summary lede.
    /// Pinned above the scrolling body.
    private var topMatter: some View {
        VStack(alignment: .leading, spacing: 14) {
            masthead
            if isSummaryRegenerating {
                AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 520, slotHeight: 32)
                    .padding(.top, 2)
                    .transition(.opacity)
            } else if let summary = article.resolvedSummary(liveSummaries: liveSummaries) {
                Text(summary)
                    .font(readingTextSize.font(base: 17).italic())
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Remote images

    /// Whether this sender's remote images load automatically (the user has
    /// trusted them). Reading the shared allowlist here registers observation,
    /// so allowing a sender live-updates the chip and reloads the body.
    private var loadsRemoteImages: Bool {
        RemoteImageSenderAllowlist.shared.isAllowed(article.senderAddress)
    }

    /// The focused message's HTML document, retained for remote-image privacy
    /// inspection and faithful rendering of embedded forwarded history.
    private var currentWebDocument: LockReadoutHTMLDocument? {
        if case .article(let resolved) = content { return resolved.webDocument }
        return nil
    }

    private var articleSearchHighlight: SearchMatchHighlight? {
        searchHighlight?.scoped(to: article.id)
    }

    /// Show the "Load images" chip only for an untrusted sender whose HTML body
    /// actually carries blocked remote images.
    private var showsRemoteImageChip: Bool {
        Self.shouldShowRemoteImageChip(
            loadsRemoteImages: loadsRemoteImages,
            document: currentWebDocument
        )
    }

    nonisolated static func shouldShowRemoteImageChip(
        loadsRemoteImages: Bool,
        document: LockReadoutHTMLDocument?
    ) -> Bool {
        guard !loadsRemoteImages, let document else { return false }
        return RemoteImageBlocking.containsRemoteImages(in: document.html)
    }

    nonisolated static func shouldRenderThreadedHTML(
        hasHTMLDocument: Bool,
        loadsRemoteImages: Bool,
        containsEmbeddedHistory: Bool = false
    ) -> Bool {
        hasHTMLDocument && (loadsRemoteImages || containsEmbeddedHistory)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            FrontPageBackButton(action: onBack)
            Spacer()
            EmailTranslationControl(
                model: translation,
                mode: .columns,
                onTranslate: startTranslation
            )
            remoteImageChip
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 48)
        .background(OhiaColors.toolbarBackground)
        .translationLanguageDownload(translation, service: appServices?.translationService)
    }

    @ViewBuilder
    private var remoteImageChip: some View {
        if showsRemoteImageChip {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    RemoteImageSenderAllowlist.shared.allow(article.senderAddress)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("Load images")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.emblem)
            .help("Load remote images and trust this sender")
            .accessibilityLabel("Load remote images from this sender")
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FrontPageAccountIndicator(
                    accountName: article.accountDisplayName,
                    accountEmailAddress: article.accountEmailAddress,
                    accountColor: article.accountColor,
                    size: 12
                )
                if article.isUnread {
                    Circle().fill(OhiaColors.chipActiveForeground).frame(width: 7, height: 7)
                }
                readerHeaderContextMarks
                classificationControl
                readerHeaderObligationMark
                deadlineHeaderMark
            }
            Text(SearchMatchTextHighlighter.highlighted(article.headline, highlight: articleSearchHighlight))
                .font(readingTextSize.font(base: 34, weight: .heavy, maximumScale: 1.20))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(SearchMatchTextHighlighter.highlighted(article.byline, highlight: articleSearchHighlight))
                    .font(readingTextSize.font(base: 14, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textSecondary)
                Text("·").foregroundStyle(OhiaColors.textTertiary)
                Text(fullDateline)
                    .font(readingTextSize.font(base: 13, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            if recipientHeader.lines.isEmpty == false {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(recipientHeader.lines) { line in
                        Text(line.plainText)
                            .font(readingTextSize.font(base: 13, weight: .medium, maximumScale: 1.35))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recipients")
            }
        }
    }

    // MARK: - Classification pulldown

    /// Custom keys assigned to this article, restricted to the live catalog so
    /// tokens of removed categories never render as a chip or a checked row.
    private var assignedCustomKeys: Set<String> {
        article.customCategoryKeys.intersection(Set(customCategoryCatalog.map(\.key)))
    }

    /// Masthead control retains the existing icon-pill and chip geometry while
    /// presenting the shared category and additive custom tags.
    private var classificationControl: some View {
        HStack(spacing: 6) {
            Button {
                classificationPickerShown.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: article.purposePresentation.systemImageName)
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
            .help(article.classification == nil ? "Set classification" : "Change classification")
            .accessibilityLabel(Text("Category: \(article.purposeLabel). Change classification."))
            .popover(isPresented: $classificationPickerShown, arrowEdge: .bottom) {
                classificationPicker
            }

            FilterChipLabel(
                text: article.purposeLabel,
                isOn: article.classification?.purpose != nil
            )
            ForEach(customCategoryCatalog.filter { assignedCustomKeys.contains($0.key) }) { descriptor in
                FilterChipLabel(text: descriptor.displayName, isOn: true)
            }
        }
    }

    private var classificationPicker: some View {
        MenuPopoverContent(headerLabel: "Category") {
            ForEach(MailPurpose.allCases, id: \.self) { purpose in
                MenuRow(
                    name: purpose.displayLabel,
                    symbolName: purpose.systemImageName,
                    isChecked: article.classification?.purpose == purpose,
                    action: {
                        commitClassification(purpose: purpose)
                    }
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
                        onClassificationChanged(article.classification, nextCustom)
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

    private func commitClassification(purpose: MailPurpose) {
        onClassificationChanged(
            .userAssigned(purpose: purpose),
            assignedCustomKeys
        )
    }

    @ViewBuilder
    private var readerHeaderContextMarks: some View {
        // Open reply/confirmation obligations render separately after the
        // classification control. Settled and contextual signals retain their
        // existing position ahead of the category.
        ForEach(article.statusDescriptor.actionStates.filter {
            $0 != .pendingReply && $0 != .needsConfirmation && $0 != .deadline
        }) { action in
            readerHeaderStatusMark(label: article.statusDescriptor.actionLabel(action), tint: action.tint) {
                MessageStatusActionGlyph(action: action, size: 13)
            }
        }
        if article.isFlagged {
            readerHeaderStatusMark(label: "Flagged", tint: MessageStatusColors.flagged) {
                MessageStatusFlaggedGlyph(size: 13)
            }
        }
        if article.statusDescriptor.isRevivedAfterInactiveGap {
            readerHeaderStatusMark(label: "Revived", tint: OhiaColors.chipActiveForeground) {
                MessageStatusRevivedGlyph(size: 13)
            }
        }
        if article.statusDescriptor.hasSharedEvidence {
            readerHeaderStatusMark(label: "Shared", tint: OhiaColors.chipActiveForeground) {
                MessageStatusSharedEvidenceGlyph(size: 13)
            }
        }
    }

    @ViewBuilder
    private var readerHeaderObligationMark: some View {
        ForEach(article.statusDescriptor.actionStates.filter {
            $0 == .pendingReply || $0 == .needsConfirmation
        }) { action in
            readerHeaderStatusMark(label: article.statusDescriptor.actionLabel(action), tint: action.tint) {
                MessageStatusActionGlyph(action: action, size: 13)
            }
        }
    }

    /// The deadline mark, pinned to the trailing end of the masthead line —
    /// after the classification control — so the long "Deadline (…)" always sits at
    /// the right end, mirroring the Front Page card and Timeline.
    @ViewBuilder
    private var deadlineHeaderMark: some View {
        if article.statusDescriptor.hasDeadline {
            readerHeaderStatusMark(
                label: article.statusDescriptor.actionLabel(.deadline),
                tint: MessageStatusActionState.deadline.tint
            ) {
                MessageStatusActionGlyph(action: .deadline, size: 13)
            }
        }
    }

    private func readerHeaderStatusMark<Glyph: View>(
        label: String,
        tint: Color,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 4) {
            glyph()
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(tint)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var fullDateline: String {
        let absolute = frontPageReaderDateFormatter.string(from: article.date)
        let relative = article.dateline()
        return "\(absolute) · \(relative)"
    }

    private func requestSummaryIfNeeded() {
        guard article.needsOnDemandSummary(
            liveSummaries: liveSummaries,
            unavailableMessageIds: summaryUnavailableMessageIds
        ) else { return }
        onRequestSummary(article.messageIdString, .lockedContext)
    }

    private func markReadOnFocusIfNeeded() {
        guard article.isUnread else { return }
        actions.setRead([article.id], true)
    }

    // MARK: - Attachment catalog placement

    /// Whether the body folds in the end-of-story Attachments catalog.
    /// - `.dossier`: catalog at the foot of the email, scrolling with the body
    ///   and reply tree. Empty / failed bodies retain a bounded catalog.
    /// - `.none`: the message has no attachments.
    private enum AttachmentPlacement { case dossier, none }

    /// The body with its Attachments catalog folded in at the foot of the
    /// story whenever the message carries attachments. When a translation is
    /// showing, the region splits into original / translation columns instead
    /// (the article body only — replies and the dossier belong to the single-
    /// column reading flow).
    @ViewBuilder
    private var readerBodyRegion: some View {
        if translation.translationVisible, case .article(let resolved) = content {
            translationColumns(resolved)
        } else {
            readerBody(placement: attachments.isEmpty ? .none : .dossier)
        }
    }

    private func translationColumns(_ resolved: ResolvedArticle) -> some View {
        EmailTranslationColumns(
            leadingHeader: translation.sourceLanguageAutonym ?? "Original",
            trailingHeader: translation.targetLanguageAutonym
        ) {
            originalColumn(resolved)
        } trailing: {
            TranslationColumnBody(model: translation, baseFontSize: 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func originalColumn(_ resolved: ResolvedArticle) -> some View {
        if let document = resolved.webDocument {
            LockedEmailHTMLView(
                document: document,
                blendsWithCanvas: true,
                loadsRemoteImages: loadsRemoteImages,
                searchHighlight: articleSearchHighlight
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                articleBodyText(resolved.bodyText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }
        }
    }

    /// End-of-story catalog that scrolls with the article body (columns and
    /// reply threads). Aligned to the same 36-pt column inset as the prose.
    private var inlineDossier: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
            LockedAttachmentsList(attachments: attachments, title: "Attachments", presentation: .reader)
        }
        .padding(.top, 20)
    }

    /// Bounded catalog for an empty / failed body. Sits at the foot of the
    /// reader and scrolls internally if it overflows.
    private var attachmentDossierFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
            ScrollView {
                LockedAttachmentsList(attachments: attachments, title: "Attachments", presentation: .reader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: 220)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 36)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Body

    @ViewBuilder
    private func readerBody(placement: AttachmentPlacement) -> some View {
        switch content {
        case .loading:
            centeredBodyMessage { OhiaLoadingIndicator(accessibilityLabel: "Loading message") }
        case .empty:
            emptyOrFailedBody(message: "This message has no readable body.", placement: placement)
        case .failed:
            emptyOrFailedBody(message: "The message body could not be loaded.", placement: placement)
        case .article(let resolved):
            articleView(resolved, placement: placement)
        }
    }

    /// A body-state message (no readable body / load failure). When the catalog
    /// folds to a dossier it is appended below so attachments stay reachable
    /// even when the body itself could not be shown.
    @ViewBuilder
    private func emptyOrFailedBody(message: String, placement: AttachmentPlacement) -> some View {
        let messageView = centeredBodyMessage {
            Text(message)
                .font(readingTextSize.font(base: 13))
                .foregroundStyle(OhiaColors.textTertiary)
        }
        if placement == .dossier {
            VStack(spacing: 0) {
                messageView
                attachmentDossierFooter
            }
        } else {
            messageView
        }
    }

    @ViewBuilder
    private func articleView(_ resolved: ResolvedArticle, placement: AttachmentPlacement) -> some View {
        if resolved.replies.isEmpty {
            // No prior conversation: keep the original reader presentation.
            if let document = resolved.webDocument {
                if placement == .dossier {
                    ScrollView {
                        VStack(spacing: 0) {
                            htmlBody(document, verticalScrollOwnership: .host)
                            inlineDossier
                                .padding(.horizontal, 36)
                                .padding(.bottom, 20)
                                .frame(maxWidth: 1100, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    htmlBody(document)
                }
            } else {
                plainTextBody(resolved.bodyText, placement: placement)
            }
        } else {
            if Self.shouldRenderThreadedHTML(
                hasHTMLDocument: resolved.webDocument != nil,
                loadsRemoteImages: loadsRemoteImages,
                containsEmbeddedHistory: resolved.containsEmbeddedHTMLHistory
            ), let document = resolved.webDocument {
                // Render either trusted threaded HTML or an embedded forwarded
                // history whose links and inline content must survive. Remote
                // resources remain blocked inside the WebView unless the sender
                // is trusted. Any unrelated stored replies remain below it.
                threadedHTMLStory(
                    document: document,
                    replies: resolved.replies,
                    placement: placement
                )
            } else {
                // A reply with history: the article's own content as a single
                // text column and the threaded comment section beneath it, in
                // one continuous scroll (the story-then-comments reading flow).
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        articleBodyText(resolved.bodyText)
                            .padding(.bottom, 6)
                        FrontPageReplyTreeView(nodes: resolved.replies, searchHighlight: searchHighlight)
                        if placement == .dossier { inlineDossier }
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 26)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Rich HTML and the canonical reply tree share the same host scroll. The
    /// WebView expands to its measured document height and forwards vertical
    /// wheel input to this `ScrollView`, so the story reads continuously into
    /// its thread instead of splitting into two independently scrolling panes.
    private func threadedHTMLStory(
        document: LockReadoutHTMLDocument,
        replies: [FrontPageReplyNode],
        placement: AttachmentPlacement
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                htmlBody(document, verticalScrollOwnership: .host)
                Divider().overlay(OhiaColors.glassBorder)
                threadedReplies(replies, placement: placement)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadedReplies(
        _ replies: [FrontPageReplyNode],
        placement: AttachmentPlacement
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FrontPageReplyTreeView(nodes: replies, searchHighlight: searchHighlight)
            if placement == .dossier { inlineDossier }
        }
        .padding(.horizontal, 36)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Re-themed HTML body that blends with the canvas (no white box). Standalone
    /// presentations fill the reader and scroll inside WebKit; a threaded story
    /// delegates scrolling to its host and expands to the measured HTML height.
    /// Both stay capped to the same centred 1100-pt column / 36-pt inset as the
    /// masthead.
    private func htmlBody(
        _ document: LockReadoutHTMLDocument,
        verticalScrollOwnership: LockedEmailHTMLView.VerticalScrollOwnership = .webView
    ) -> some View {
        LockedEmailHTMLView(
            document: document,
            blendsWithCanvas: true,
            loadsRemoteImages: loadsRemoteImages,
            searchHighlight: articleSearchHighlight,
            verticalScrollOwnership: verticalScrollOwnership
        )
            .padding(.horizontal, 36)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .frame(
                maxWidth: 1100,
                maxHeight: verticalScrollOwnership == .webView ? .infinity : nil
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: verticalScrollOwnership == .webView ? .infinity : nil
            )
    }

    /// The article's plain-text body: a single text column capped at a
    /// readable measure and aligned under the headline. Multi-column
    /// newspaper flow was retired — one column reads better for email bodies
    /// at every length.
    private func articleBodyText(_ text: String) -> some View {
        FrontPageLinkedPlainTextView(
            text: text,
            searchHighlight: articleSearchHighlight,
            font: .systemFont(ofSize: readingTextSize.pointSize(base: 15)),
            foregroundColor: OhiaColors.nsTextPrimary,
            lineSpacing: readingTextSize.spacing(2),
            paragraphSpacing: readingTextSize.spacing(9)
        )
        .frame(maxWidth: Self.maxBodyTextWidth, alignment: .leading)
    }

    /// Maximum text measure for the article body. ~90 characters of 15pt
    /// SF Pro — wide enough for dense CJK and URL-heavy mail, narrow enough
    /// to stay readable inside the 1100pt article frame.
    private static let maxBodyTextWidth: CGFloat = 700

    /// Plain-text body: a single readable column that fills the reader and
    /// scrolls when the text runs longer than the pane. Appends the dossier
    /// in-scroll when the catalog has folded down.
    private func plainTextBody(_ text: String, placement: AttachmentPlacement) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                articleBodyText(text)
                if placement == .dossier { inlineDossier }
            }
            .padding(.horizontal, 36)
            .padding(.top, 26)
            .padding(.bottom, 20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredBodyMessage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolveContent(threadContext: FrontPageThreadContext) async {
        content = .loading
        let htmlPath = article.bodyHtmlPath
        let textPath = article.bodyTextPath
        let rawPath = article.rawPath

        // 1. Load the focused message body (disk decode off-main; HTML render
        //    on the main actor, as `NSAttributedString` HTML import requires).
        let result = await Task.detached(priority: .userInitiated) {
            LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath)
        }.value
        if Task.isCancelled { return }

        let source: LockReadoutBodySource
        switch result {
        case .loaded(let loadedSource):
            source = loadedSource
        case .missing:
            content = .empty
            return
        case .failed:
            content = .failed
            return
        }
        let bodyContent = LockReadoutBodyContent(source: source)
        if bodyContent.isEmpty {
            content = .empty
            return
        }

        // `cleanedForDisplay` never carries the truncation marker, so the
        // house no-ellipsis rule holds without post-stripping; the raw
        // fallback covers bodies the cleaner reduces to nothing.
        let topPostText = OriginalMessageText.cleanedForDisplay(
            from: bodyContent.plainText,
            characterLimit: 20_000
        )?.text ?? bodyContent.plainText

        // 2. Resolve the prior conversation (hybrid: ingested thread first).
        let resolvedReplies = await resolveReplies(
            focusedBody: bodyContent,
            threadContext: threadContext
        )
        if Task.isCancelled { return }
        let replies = resolvedReplies.nodes

        // 3. Keep rich HTML even when replies are present so the remote-image
        //    privacy control can inspect the original source. Embedded forwarded
        //    or quoted history remains in the document so its links, inline
        //    images, and formatting survive. When history exists only as stored
        //    sibling messages, strip quoted HTML already represented below.
        let webDocument: LockReadoutHTMLDocument?
        if FrontPageBodyPresentation.decide(format: bodyContent.format) == .web,
           let document = bodyContent.htmlDocument {
            webDocument = replies.isEmpty && resolvedReplies.containsEmbeddedHTMLHistory == false
                ? document
                : LockReadoutHTMLDocument(
                    html: frontPageHTMLForThreadPresentation(
                        document.html,
                        containsEmbeddedHistory: resolvedReplies.containsEmbeddedHTMLHistory
                    ),
                    baseURL: document.baseURL
                )
        } else {
            webDocument = nil
        }
        resolvedBodyText = topPostText
        content = .article(
            ResolvedArticle(
                bodyText: topPostText,
                webDocument: webDocument,
                replies: replies,
                containsEmbeddedHTMLHistory: resolvedReplies.containsEmbeddedHTMLHistory
            )
        )
    }

    // MARK: - Translation

    /// Re-evaluates the translate offer when the focused article, its resolved
    /// body, or the chosen language changes.
    private var translationConfigKey: String {
        "\(article.id.uuidString)|\(summaryOutputLanguageRaw)|\(selectedTranslationEngineRaw)|\(resolvedBodyText.count)"
    }

    private func configureTranslation() {
        translation.configure(
            messageID: article.id,
            bodyText: resolvedBodyText,
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

    /// Hybrid reply resolution. Builds the reply tree from a stored
    /// conversation when the thread holds another non-duplicate message, then
    /// supplements it with structurally parsed in-body history when the stored
    /// thread is partial (common for Outlook-style forwarded/replied chains).
    private func resolveReplies(
        focusedBody: LockReadoutBodyContent,
        threadContext: FrontPageThreadContext
    ) async -> ResolvedReplies {
        let focusedID = article.id
        let threadMessages = threadContext.messages

        if threadMessages.contains(where: { $0.id != focusedID }) {
            // Resolve every sibling's *own* (quote-stripped) content entirely
            // off-main. We deliberately avoid `LockReadoutBodyContent`'s
            // `NSAttributedString` HTML import here — that is main-actor-only
            // and, run once per sibling, would hitch the UI on focus for a long
            // thread. A structurally intact text part remains authoritative;
            // the lightweight HTML pass repairs older HTML-only artifacts whose
            // synthesized text lost every paragraph and quote boundary.
            let bodyTextByID: [UUID: String] = await Task.detached(priority: .userInitiated) {
                var map: [UUID: String] = [:]
                for message in threadMessages where message.id != focusedID {
                    let text = frontPageSiblingBodyText(
                        htmlPath: message.bodyHtmlPath,
                        textPath: message.bodyTextPath,
                        rawPath: message.rawPath
                    )
                    if text.isEmpty == false { map[message.id] = text }
                }
                return map
            }.value
            if Task.isCancelled {
                return ResolvedReplies(nodes: [], containsEmbeddedHTMLHistory: false)
            }

            let descriptors = threadMessages.map { message in
                FrontPageThreadDescriptor(
                    id: message.id.uuidString,
                    messageID: message.messageIDHeader,
                    inReplyTo: message.inReplyTo,
                    references: message.references,
                    author: message.author,
                    isSentByUser: message.isSentByUser,
                    date: message.date,
                    // The focused message is the article above (skipped by the
                    // builder); a sibling with no extractable own content
                    // (quote-only / bottom-posted) renders as a byline-only
                    // beat rather than duplicating the deeper reply nodes.
                    bodyText: message.id == focusedID ? "" : (bodyTextByID[message.id] ?? "")
                )
            }
            let nodes = FrontPageReplyComposer.buildTree(
                descriptors: descriptors,
                focusedID: focusedID.uuidString
            )
            let inBodyNodes = await Task.detached(priority: .userInitiated) {
                FrontPageReplyComposer.extractInBody(plainText: focusedBody.plainText)
            }.value
            if Task.isCancelled {
                return ResolvedReplies(nodes: [], containsEmbeddedHTMLHistory: false)
            }
            let containsEmbeddedHTMLHistory = focusedBody.format == .html && inBodyNodes.isEmpty == false
            let displayedNodes = containsEmbeddedHTMLHistory
                ? frontPageStoredRepliesNotRepresentedInEmbeddedHistory(
                    embeddedNodes: inBodyNodes,
                    storedNodes: nodes
                )
                : frontPageMergedReplyNodes(inBodyNodes: inBodyNodes, storedNodes: nodes)
            return ResolvedReplies(
                nodes: displayedNodes,
                containsEmbeddedHTMLHistory: containsEmbeddedHTMLHistory
            )
        }

        // Fallback / supplement: parse the focused message's own quoted
        // history. If SwiftData knows a single-message thread, this still only
        // emits nodes when the body carries structural quote/header evidence.
        let plain = focusedBody.plainText
        let inBodyNodes = await Task.detached(priority: .userInitiated) {
            FrontPageReplyComposer.extractInBody(plainText: plain)
        }.value
        let containsEmbeddedHTMLHistory = focusedBody.format == .html && inBodyNodes.isEmpty == false
        return ResolvedReplies(
            nodes: containsEmbeddedHTMLHistory ? [] : inBodyNodes,
            containsEmbeddedHTMLHistory: containsEmbeddedHTMLHistory
        )
    }
}

/// Off-main plain text for a thread sibling's comment body, avoiding the
/// main-actor-only `NSAttributedString` HTML import (which, run once per
/// sibling, would hitch the UI on focus for a long thread). Uses a structurally
/// intact decoded text part when available; otherwise strips the HTML artifact
/// with a lightweight pass to recover boundaries lost in older synthesized
/// text. Free / `nonisolated` so it runs inside the detached load task.
private nonisolated func frontPageSiblingBodyText(htmlPath: String?, textPath: String?, rawPath: String?) -> String {
    var html: String?
    if let htmlPath, htmlPath.trimmingCharacters(in: .whitespaces).isEmpty == false,
       case .loaded(let source) = LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: nil) {
        html = source.format == .html ? source.text : nil
    }

    var text: String?
    if let textPath, textPath.trimmingCharacters(in: .whitespaces).isEmpty == false,
       case .loaded(let source) = LockReadoutBodyLoader.load(htmlPath: nil, textPath: textPath) {
        text = source.format == .html ? frontPageStripHTML(source.text) : source.text
    }

    let preferredBody = frontPagePreferredReplyBodyText(html: html, text: text)
    if preferredBody.isEmpty == false {
        return preferredBody
    }

    if let rawPath, rawPath.trimmingCharacters(in: .whitespaces).isEmpty == false,
       case .loaded(let source) = LockReadoutBodyLoader.load(htmlPath: nil, textPath: nil, rawPath: rawPath) {
        let text = source.format == .html ? frontPageStripHTML(source.text) : source.text
        return cleanedReplyBody(text)
    }
    return ""
}

nonisolated func frontPagePreferredReplyBodyText(html: String?, text: String?) -> String {
    let cleanedText = text.map(cleanedReplyBody) ?? ""
    if let text,
       text.contains(where: { $0.isNewline }),
       cleanedText.isEmpty == false {
        return cleanedText
    }

    if let html, html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        let body = cleanedReplyBody(frontPageStripHTML(html))
        if body.isEmpty == false {
            return body
        }
    }
    return cleanedText
}

private nonisolated func cleanedReplyBody(_ text: String) -> String {
    OriginalMessageText.cleanedForDisplay(from: text, characterLimit: 8_000)?.text ?? ""
}

nonisolated func frontPageHTMLForThreadPresentation(
    _ html: String,
    containsEmbeddedHistory: Bool
) -> String {
    containsEmbeddedHistory ? html : frontPageFocusedMessageHTML(html)
}

/// Keeps the focused message's original HTML styling and image elements while
/// removing quoted history already represented by the canonical reply tree.
/// Provider reply-tail containers run to the end of the message; semantic
/// blockquotes can be nested, so they are removed by depth rather than a
/// single non-greedy regular expression.
nonisolated func frontPageFocusedMessageHTML(_ html: String) -> String {
    var result = html
    let providerPattern =
        #"<[^>]*(?:gmail_quote|yahoo_quoted|protonmail_quote|moz-cite-prefix|divrplyfwdmsg|replyforwardmsg)[^>]*>"#
    if let boundary = result.range(
        of: providerPattern,
        options: [.regularExpression, .caseInsensitive]
    )?.lowerBound {
        result = String(result[..<boundary])
    }

    guard let blockquoteTag = try? NSRegularExpression(
        pattern: #"(?is)<\s*/?\s*blockquote\b[^>]*>"#
    ) else {
        return result
    }
    let matches = blockquoteTag.matches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result)
    )
    guard matches.isEmpty == false else { return result }

    var output = ""
    var cursor = result.startIndex
    var quoteDepth = 0
    for match in matches {
        guard let range = Range(match.range, in: result) else { continue }
        if quoteDepth == 0 {
            output.append(contentsOf: result[cursor..<range.lowerBound])
        }
        let tag = result[range]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("</") || tag.hasPrefix("< /") {
            quoteDepth = max(quoteDepth - 1, 0)
        } else {
            quoteDepth += 1
        }
        cursor = range.upperBound
    }
    if quoteDepth == 0 {
        output.append(contentsOf: result[cursor...])
    }
    return output
}

nonisolated func frontPageMergedReplyNodes(
    inBodyNodes: [FrontPageReplyNode],
    storedNodes: [FrontPageReplyNode]
) -> [FrontPageReplyNode] {
    guard inBodyNodes.isEmpty == false else {
        return frontPageChronologicallySortedReplyNodes(storedNodes)
    }
    guard storedNodes.isEmpty == false else {
        return frontPageChronologicallySortedReplyNodes(inBodyNodes)
    }

    var storedBucketsByFingerprint: [String: [FrontPageReplyNode]] = [:]
    for node in storedNodes {
        guard let fingerprint = frontPageReplyFingerprint(node) else { continue }
        storedBucketsByFingerprint[fingerprint, default: []].append(node)
    }

    var supplementalNodes: [FrontPageReplyNode] = []
    supplementalNodes.reserveCapacity(inBodyNodes.count)

    for inBodyNode in inBodyNodes {
        guard let fingerprint = frontPageReplyFingerprint(inBodyNode),
              var candidates = storedBucketsByFingerprint[fingerprint],
              candidates.isEmpty == false else {
            supplementalNodes.append(inBodyNode)
            continue
        }

        candidates.removeFirst()
        storedBucketsByFingerprint[fingerprint] = candidates
    }

    return frontPageChronologicallySortedReplyNodes(supplementalNodes + storedNodes)
}

nonisolated func frontPageStoredRepliesNotRepresentedInEmbeddedHistory(
    embeddedNodes: [FrontPageReplyNode],
    storedNodes: [FrontPageReplyNode]
) -> [FrontPageReplyNode] {
    var embeddedCountsByFingerprint: [String: Int] = [:]
    for node in embeddedNodes {
        guard let fingerprint = frontPageReplyFingerprint(node) else { continue }
        embeddedCountsByFingerprint[fingerprint, default: 0] += 1
    }

    let unrepresented = storedNodes.filter { node in
        guard let fingerprint = frontPageReplyFingerprint(node),
              let remaining = embeddedCountsByFingerprint[fingerprint],
              remaining > 0 else {
            return true
        }
        embeddedCountsByFingerprint[fingerprint] = remaining - 1
        return false
    }
    return frontPageChronologicallySortedReplyNodes(unrepresented)
}

private nonisolated func frontPageChronologicallySortedReplyNodes(
    _ nodes: [FrontPageReplyNode]
) -> [FrontPageReplyNode] {
    nodes.enumerated()
        .sorted { lhs, rhs in
            switch (lhs.element.date, rhs.element.date) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
}

private nonisolated func frontPageReplyFingerprint(_ node: FrontPageReplyNode) -> String? {
    let body = frontPageNormalizedFingerprintText(node.bodyText)
    if body.count >= 24 {
        return "body:" + String(body.prefix(240))
    }

    let author = frontPageNormalizedFingerprintText(node.author ?? "")
    guard author.isEmpty == false, body.isEmpty == false else { return nil }
    return "short:" + author + "|" + body
}

private nonisolated func frontPageNormalizedFingerprintText(_ text: String) -> String {
    var result = ""
    var lastWasSpace = true
    for scalar in text.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
        } else if lastWasSpace == false {
            result.append(" ")
            lastWasSpace = true
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Lightweight, main-actor-free HTML → plain text for Front Page previews:
/// drops script/style, turns block-level tags into line breaks, removes the
/// remaining tags, and decodes the handful of entities that survive. Lower
/// fidelity than the `NSAttributedString` import, but safe off-main and only
/// reached for preview text when no decoded plain-text body is available.
nonisolated func frontPageStripHTML(_ html: String) -> String {
    let quoteStartMarker = "\u{E000}OHIA_BLOCKQUOTE_START\u{E001}"
    let quoteEndMarker = "\u{E000}OHIA_BLOCKQUOTE_END\u{E001}"
    var s = html
    s = s.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(
        of: "(?i)<blockquote\\b[^>]*>",
        with: "\n\(quoteStartMarker)\n",
        options: .regularExpression
    )
    s = s.replacingOccurrences(
        of: "(?i)</blockquote\\s*>",
        with: "\n\(quoteEndMarker)\n",
        options: .regularExpression
    )
    s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?i)</(p|div|li|tr|h[1-6]|blockquote)\\s*>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
    for (entity, character) in entities {
        s = s.replacingOccurrences(of: entity, with: character)
    }
    var quoteDepth = 0
    var output: [String] = []
    for line in s.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == quoteStartMarker {
            quoteDepth += 1
            continue
        }
        if trimmed == quoteEndMarker {
            quoteDepth = max(quoteDepth - 1, 0)
            continue
        }
        if quoteDepth > 0, trimmed.isEmpty == false {
            output.append(String(repeating: ">", count: quoteDepth) + " " + line)
        } else {
            output.append(line)
        }
    }
    return output.joined(separator: "\n")
}

/// Hybrid-body routing. Rich HTML keeps its WebView rendering; everything else
/// (plain-text / low-markup conversational mail) flows into newspaper columns.
enum FrontPageBodyPresentation {
    case columns
    case web

    static func decide(format: LockReadoutBodyFormat) -> FrontPageBodyPresentation {
        switch format {
        case .html:
            return .web
        case .plainText:
            return .columns
        }
    }
}

/// Back affordance mirroring the Projects back disc at reader scale: 30×30, `surface(0.10)`
/// fill, `chipActiveBorder` ring, `chevron.left` glyph.
private struct FrontPageBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(OhiaColors.surface(0.10))
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
            .frame(width: 30, height: 30)
            .overlay { Circle().strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1) }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .background(
                TimelineEventCatcher(onLeftClick: { _, _, _ in action() })
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Back to Digest")
        .accessibilityLabel("Back to Digest")
    }
}

private let frontPageReaderDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .short
    return f
}()
