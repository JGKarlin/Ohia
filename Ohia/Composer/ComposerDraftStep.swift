// Ohia/Composer/ComposerDraftStep.swift
// Step 2 of the Composer flow: the rich draft editor with version history,
// the model-instruction box, citation annotations, and the Save /
// Regenerate / Send actions. The flow rail keeps the Decisions step available
// so the user can return to the interview at any time.

import AppKit
import SwiftUI
import OhiaCore
import OhiaML

enum ComposerDraftLoadingPresentation {
    nonisolated static func isTextRevisionPending(
        isAwaitingModel: Bool,
        isAwaitingInstructionRevision: Bool,
        hasPendingStyleRegeneration: Bool,
        hasGeneratedVersion: Bool,
        hasPendingSourceChanges: Bool
    ) -> Bool {
        return isAwaitingModel && (
            isAwaitingInstructionRevision
                || (
                    hasPendingStyleRegeneration
                        && hasGeneratedVersion
                        && !hasPendingSourceChanges
                )
        )
    }

    /// True for full-body generation and research. Current-body revisions use
    /// the word-morph overlay instead, including a style-only Regenerate.
    nonisolated static func showsPlaceholder(
        isAwaitingModel: Bool,
        isAwaitingInstructionRevision: Bool
    ) -> Bool {
        isAwaitingModel && !isAwaitingInstructionRevision
    }

    /// True while an existing body is being revised and a word-level diff is
    /// meaningful, either from typed guidance or style-slider adjustments.
    nonisolated static func showsRevisionOverlay(
        isAwaitingModel: Bool,
        isAwaitingInstructionRevision: Bool
    ) -> Bool {
        isAwaitingModel && isAwaitingInstructionRevision
    }

    /// Full-body generation replaces the editor with the generic loader.
    /// Current-body revisions keep the existing text visible for word-morph.
    nonisolated static func showsExistingDraft(
        isAwaitingModel: Bool,
        isAwaitingInstructionRevision: Bool
    ) -> Bool {
        !showsPlaceholder(
            isAwaitingModel: isAwaitingModel,
            isAwaitingInstructionRevision: isAwaitingInstructionRevision
        )
    }
}

enum ComposerOriginalMessagePresentation {
    /// Removes only the reply decoration added by `QuotedReplyFormatter.plain`.
    /// The persisted prepared quote remains unchanged for sending.
    nonisolated static func body(fromPreparedReplyQuote quote: String) -> String {
        let lines = quote.components(separatedBy: "\n")
        guard lines.count > 1 else { return quote }

        return lines.dropFirst().map { line in
            if line.hasPrefix("> ") {
                return String(line.dropFirst(2))
            }
            if line == ">" {
                return ""
            }
            return line
        }
        .joined(separator: "\n")
    }
}

enum ComposerRegenerationInputState {
    static func displayedGeneratedSourcesJSON(
        liveGeneratedSourcesJSON: String?,
        versions: [ComposerDraftVersion],
        viewingVersionIndex: Int?
    ) -> String? {
        guard let viewingVersionIndex else { return liveGeneratedSourcesJSON }
        return versions.first { $0.index == viewingVersionIndex }?.generatedSourcesJSON
    }

    static func hasPendingSourceChanges(
        currentSources: [ComposerSource],
        generatedSourcesJSON: String?
    ) -> Bool {
        guard let appliedJSON = generatedSourcesJSON else { return false }
        return ComposerSourceCoding.decode(appliedJSON) != currentSources
    }

    static func canRegenerate(
        hasVersions: Bool,
        isBusy: Bool,
        hasPendingSourceChanges: Bool,
        hasPendingStyleChanges: Bool,
        isGenerationBlocked: Bool
    ) -> Bool {
        !isBusy && (isGenerationBlocked
            || (hasVersions && (hasPendingSourceChanges || hasPendingStyleChanges)))
    }
}

@MainActor
protocol ComposerDraftEditingHost: AnyObject, Observable {
    var versions: [ComposerDraftVersion] { get }
    var viewingVersionIndex: Int? { get }
    var editorText: NSAttributedString { get }
    var messageFormat: ComposerMessageFormat { get }
    var isAwaitingModel: Bool { get }
    var isAwaitingInstructionRevision: Bool { get }
    var awaitingReason: String { get }
    var isGenerationBlocked: Bool { get }
    var generationBlockedReason: String { get }
    var annotations: [SourceAnnotation] { get }
    var replyQuotePresentation: ComposerReplyQuotePresentation { get }
    var includesQuotedOriginal: Bool { get }
    var hasEdits: Bool { get }
    var instructionText: String { get set }
    var plainEditorText: String { get }
    var attachmentPaths: [String] { get }
    var inlinePhotoOwnerID: UUID? { get }
    var inlinePhotos: [ComposerInlinePhotoAsset] { get }
    var canSendDraft: Bool { get }
    var hasPendingSourceChanges: Bool { get }
    var hasPendingStyleRegeneration: Bool { get }
    var hasPendingRegenerationInputs: Bool { get }
    /// True while a Send press should surface a review step rather than
    /// sending outright (e.g. the reply flow's training-signal diff).
    var sendNeedsConfirmationFirst: Bool { get }

    func updateEditorContent(_ content: NSAttributedString)
    func updateMessageFormat(_ format: ComposerMessageFormat)
    func updateInlinePhotos(_ photos: [ComposerInlinePhotoAsset])
    func refreshAnnotationOpacity()
    func showVersion(_ version: ComposerDraftVersion)
    func showLiveDraft()
}

struct ComposerDraftStep<Host: ComposerDraftEditingHost, StageRail: View>: View {
    @Bindable var session: Host
    let onSave: () -> Void
    let onRegenerate: () -> Void
    let onInstruction: (String) -> Void
    let onAddAttachment: (() -> Void)?
    let onDropAttachments: (([URL]) -> Void)?
    let onRemoveAttachment: ((Int) -> Void)?
    let onSetQuotedOriginalInclusion: ((Bool) -> Void)?
    let onRetryQuotedOriginal: (() -> Void)?
    let onDiscard: (() -> Void)?
    let reviewDraftEditsBeforeSending: Bool
    let onSend: () -> Void
    var beginInlinePhotoImport: (() -> ComposerAttachmentImport?)? = nil
    var validateInlinePhotoImport: ((ComposerAttachmentImport) -> Bool)? = nil
    var finishInlinePhotoImport: ((ComposerAttachmentImport) -> Void)? = nil
    /// The 1 Decisions › 2 Draft rail, shown under the column header.
    let stageRail: StageRail

    @State private var isQuotedOriginalExpanded = false
    @State private var quotedOriginalPaneHeight: CGFloat = 130

    /// Snapshot of the draft body taken when an in-place revision starts and
    /// held here, rather than letting the bound editor track
    /// `session.editorText` directly, for the entire
    /// scanning + landing-cascade window. `session.editorText` updates the
    /// instant the model resolves (a plain data write), but applying that
    /// to the live NSTextView is a synchronous, unanimated relayout; if it
    /// happened immediately, every line below the edit would jump the
    /// moment the response landed, fighting the word-morph cascade that's
    /// trying to animate on top of it. Holding this frozen keeps the real
    /// layout completely still for the whole animation; `draftEditor` reads
    /// through this instead of `session.editorText` while it's non-nil.
    @State private var frozenDraftContent: NSAttributedString?
    /// The resolved new body, set at the same moment `frozenDraftContent`
    /// starts being held back. Non-nil only once the model has actually
    /// responded (nil throughout scanning) — handed to the revision overlay
    /// purely for diffing/measurement, not for display.
    @State private var revisionTargetContent: NSAttributedString?

    private var sendNeedsConfirmationFirst: Bool {
        reviewDraftEditsBeforeSending && session.sendNeedsConfirmationFirst
    }

    /// True from the moment an in-place revision is submitted until the
    /// word-morph landing cascade fully settles — a strict superset of
    /// `session.isAwaitingModel`, which the session itself already clears
    /// once the model responds, before the cascade has had a chance to
    /// play. Every control that would let the user act on the draft again
    /// (edit it, submit another instruction, save, send) must stay gated on
    /// this, not just `session.isAwaitingModel`, or the draft could change
    /// out from under an animation that's still visually in flight.
    private var isBusy: Bool {
        session.isAwaitingModel || frozenDraftContent != nil
    }

    private var isAwaitingTextRevision: Bool {
        ComposerDraftLoadingPresentation.isTextRevisionPending(
            isAwaitingModel: session.isAwaitingModel,
            isAwaitingInstructionRevision: session.isAwaitingInstructionRevision,
            hasPendingStyleRegeneration: session.hasPendingStyleRegeneration,
            hasGeneratedVersion: session.versions.isEmpty == false,
            hasPendingSourceChanges: session.hasPendingSourceChanges
        )
    }

    private static var minimumDraftPaneHeight: CGFloat { 180 }
    private static var minimumQuotedOriginalPaneHeight: CGFloat { 120 }

    var body: some View {
        GlassPane(
            accentColor: OhiaColors.chipActiveForeground,
            isForeground: true,
            isFocused: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    stageRail
                }

                draftAndQuotedOriginal

                if !session.attachmentPaths.isEmpty,
                   let onAddAttachment,
                   let onRemoveAttachment {
                    ComposeAttachmentRow(
                        paths: session.attachmentPaths,
                        onRemove: onRemoveAttachment,
                        onAdd: onAddAttachment
                    )
                }

                if !session.annotations.isEmpty {
                    annotationStrip
                }

                instructionBar
                actionBar
            }
        }
        .onChange(of: isAwaitingTextRevision, initial: true) { wasRevising, isRevising in
            if isRevising {
                // In-place revision just started — OR this view was just
                // (re)created while one was already in flight (switching to
                // the Decisions step and back mid-revision tears down and
                // rebuilds this whole view, losing frozenDraftContent along
                // with every other @State here; `initial: true` is what
                // makes this branch also run on that rebuild, not just on a
                // genuine false→true transition). Either way, freeze the
                // currently-shown body so the overlay has a stable backdrop
                // to animate against while the model resolves.
                // session.editorText is still the pre-revision body at this
                // exact instant: it can only change once this flag flips
                // false, which hasn't happened yet.
                frozenDraftContent = session.editorText
                revisionTargetContent = nil
            } else if session.isGenerationBlocked {
                // A failed pass has no replacement body to animate toward.
                // Release the frozen editor so its Retry action is usable.
                frozenDraftContent = nil
                revisionTargetContent = nil
            } else if wasRevising {
                // The model resolved — session.editorText already reflects
                // the new body (same update as this flag flipping), but
                // frozenDraftContent keeps displaying the old one until the
                // overlay's onLandingComplete releases it below.
                revisionTargetContent = session.editorText
            }
        }
        .onChange(of: session.inlinePhotoOwnerID) { _, _ in
            // Switching drafts entirely — any in-flight hold belonged to
            // the previous draft and must not leak into this one.
            frozenDraftContent = nil
            revisionTargetContent = nil
        }
    }

    private var draftAndQuotedOriginal: some View {
        GeometryReader { geometry in
            let quoteIsExpanded = isQuotedOriginalExpanded && hasReadyQuotedOriginal
            let maximumQuoteHeight = max(
                Self.minimumQuotedOriginalPaneHeight,
                geometry.size.height
                    - Self.minimumDraftPaneHeight
                    - ComposerDraftQuoteDivider.hitTargetHeight
            )
            let displayedQuoteHeight = min(
                max(quotedOriginalPaneHeight, Self.minimumQuotedOriginalPaneHeight),
                maximumQuoteHeight
            )

            VStack(spacing: 0) {
                draftEditor
                    .frame(minHeight: Self.minimumDraftPaneHeight, maxHeight: .infinity)
                    .layoutPriority(1)

                if session.replyQuotePresentation != .notApplicable,
                   let onSetQuotedOriginalInclusion,
                   let onRetryQuotedOriginal {
                    if quoteIsExpanded {
                        ComposerDraftQuoteDivider(
                            lowerPaneHeight: $quotedOriginalPaneHeight,
                            minimumLowerPaneHeight: Self.minimumQuotedOriginalPaneHeight,
                            maximumLowerPaneHeight: maximumQuoteHeight
                        )
                    }

                    ComposerQuotedOriginalControl(
                        presentation: session.replyQuotePresentation,
                        isIncluded: session.includesQuotedOriginal,
                        isExpanded: $isQuotedOriginalExpanded,
                        onSetIncluded: onSetQuotedOriginalInclusion,
                        onRetry: onRetryQuotedOriginal
                    )
                    .frame(height: quoteIsExpanded ? displayedQuoteHeight : nil)
                    .padding(.top, quoteIsExpanded ? 0 : 10)
                }
            }
        }
        .frame(minHeight: Self.minimumDraftPaneHeight)
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var draftEditor: some View {
        ComposerRichTextEditor(
            content: Binding(
                get: { frozenDraftContent ?? session.editorText },
                set: {
                    session.updateEditorContent($0)
                    session.refreshAnnotationOpacity()
                }
            ),
            format: Binding(
                get: { session.messageFormat },
                set: { session.updateMessageFormat($0) }
            ),
            isEnabled: !isBusy,
            inlinePhotoOwnerID: session.inlinePhotoOwnerID,
            inlinePhotos: Binding(
                get: { session.inlinePhotos },
                set: { session.updateInlinePhotos($0) }
            ),
            beginInlinePhotoImport: beginInlinePhotoImport,
            validateInlinePhotoImport: validateInlinePhotoImport,
            finishInlinePhotoImport: finishInlinePhotoImport,
            onAddAttachment: onAddAttachment,
            onDropAttachments: onDropAttachments,
            placesUtilityActionsInHeader: true,
            revisionOverlay: { controller in
                AnyView(
                    ComposerDraftRevisionOverlay(
                        isActive: isRevisingExistingDraft,
                        resolvedContent: revisionTargetContent,
                        controller: controller,
                        onLandingComplete: {
                            frozenDraftContent = nil
                            revisionTargetContent = nil
                        }
                    )
                )
            }
        )
        .opacity(showsExistingDraft ? 1 : 0)
        .allowsHitTesting(showsExistingDraft)
        .accessibilityHidden(!showsExistingDraft)
        .overlay {
            if ComposerDraftLoadingPresentation.showsPlaceholder(
                isAwaitingModel: session.isAwaitingModel,
                isAwaitingInstructionRevision: isAwaitingTextRevision
            ) {
                ZStack {
                    OhiaColors.composerPanelBackground
                    AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 520, slotHeight: 32)
                        .frame(maxWidth: 520)
                        .accessibilityLabel("Draft loading")
                }
                .allowsHitTesting(false)
            }
        }
        .id(session.inlinePhotoOwnerID)
    }

    private var showsExistingDraft: Bool {
        ComposerDraftLoadingPresentation.showsExistingDraft(
            isAwaitingModel: session.isAwaitingModel,
            isAwaitingInstructionRevision: isAwaitingTextRevision
        )
    }

    private var isRevisingExistingDraft: Bool {
        ComposerDraftLoadingPresentation.showsRevisionOverlay(
            isAwaitingModel: session.isAwaitingModel,
            isAwaitingInstructionRevision: isAwaitingTextRevision
        )
    }

    private var hasReadyQuotedOriginal: Bool {
        if case .ready = session.replyQuotePresentation {
            true
        } else {
            false
        }
    }

    private var header: some View {
        // The stage column never closes, so its header carries no chevron;
        // the shared header keeps it on the line the other columns use.
        ComposerColumnHeader(control: nil, columnTitle: "Draft") {
            ComposerSectionHeader(title: "Draft", symbolName: "square.and.pencil", titleWeight: .bold)
        } trailing: {
            headerStatus
        }
    }

    @ViewBuilder
    private var headerStatus: some View {
        HStack(spacing: 6) {
            if session.isAwaitingModel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(session.awaitingReason)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .frame(maxWidth: 260, alignment: .trailing)
            } else if session.isGenerationBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                    // The editor below takes every spare point; without its
                    // own height the reason would be squeezed to one line
                    // and cut off.
                    Text(session.generationBlockedReason)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }
            if session.hasEdits {
                Text("edited")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(OhiaColors.chipActiveBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var annotationStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("source annotations")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
            ForEach(session.annotations) { annotation in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(annotation.color)
                        .frame(width: 12, height: 4)
                        .opacity(annotation.opacity)
                    Text(annotation.sourceLabel)
                        .font(OhiaTypography.editorAnnotation)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .opacity(annotation.opacity)
                    if annotation.opacity < 1.0 {
                        Text("(text changed)")
                            .font(OhiaTypography.editorAnnotation)
                            .foregroundStyle(OhiaColors.textDim)
                    }
                }
            }
        }
    }

    private var instructionBar: some View {
        HStack(spacing: 8) {
            TextField(
                "Tell the Composer how to revise this draft",
                text: $session.instructionText
            )
            .textFieldStyle(.plain)
            .font(OhiaTypography.cardBody)
            .foregroundStyle(OhiaColors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(OhiaColors.composerPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onSubmit { submitInstruction() }

            Button {
                submitInstruction()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11))
                    Text("Revise")
                        .font(OhiaTypography.button)
                }
            }
            .buttonStyle(.emblem)
            .disabled(
                isBusy
                    || session.instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private func submitInstruction() {
        let text = session.instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        onInstruction(text)
        session.instructionText = ""
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                onSave()
            } label: {
                Label {
                    Text("Save Draft")
                        .font(OhiaTypography.button)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.emblem)
            .disabled(!session.hasEdits)

            Button {
                onRegenerate()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text(session.isGenerationBlocked ? "Retry" : "Regenerate")
                        .font(OhiaTypography.button)
                }
            }
            .buttonStyle(.emblem)
            .disabled(!ComposerRegenerationInputState.canRegenerate(
                hasVersions: !session.versions.isEmpty,
                isBusy: isBusy,
                hasPendingSourceChanges: session.hasPendingSourceChanges,
                hasPendingStyleChanges: session.hasPendingStyleRegeneration,
                isGenerationBlocked: session.isGenerationBlocked
            ))

            Spacer()

            if let onDiscard {
                Button("Discard") {
                    onDiscard()
                }
                .font(OhiaTypography.button)
                .buttonStyle(EmblemButtonStyle(
                    tint: OhiaColors.ohiaRed,
                    horizontalPadding: 12,
                    verticalPadding: 6
                ))
            }

            Button {
                onSend()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: sendNeedsConfirmationFirst ? "checkmark" : "paperplane.fill")
                        .font(.system(size: 11))
                    Text(sendNeedsConfirmationFirst ? "Confirm" : "Send")
                        .font(OhiaTypography.button)
                }
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 16, verticalPadding: 8))
            .disabled(isBusy || !session.canSendDraft)
        }
    }
}

private struct ComposerQuotedOriginalControl: View {
    let presentation: ComposerReplyQuotePresentation
    let isIncluded: Bool
    @Binding var isExpanded: Bool
    let onSetIncluded: (Bool) -> Void
    let onRetry: () -> Void

    @State private var isHeaderHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                disclosureHeader

                Toggle(
                    "Include in reply",
                    isOn: Binding(
                        get: { isIncluded },
                        set: onSetIncluded
                    )
                )
                .toggleStyle(.checkbox)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize()
            }

            switch presentation {
            case .loading:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing the original message")
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            case .unavailable(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                    Text(message)
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textSecondary)
                    Spacer(minLength: 8)
                    Button("Retry", action: onRetry)
                        .font(OhiaTypography.button)
                        .buttonStyle(.emblem)
                }
            case .ready(let quoted) where isExpanded:
                ScrollView {
                    Text(
                        ComposerOriginalMessagePresentation.body(
                            fromPreparedReplyQuote: quoted
                        )
                    )
                        .font(readingTextSize.font(base: 11))
                        .lineSpacing(readingTextSize.spacing(2))
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 64, maxHeight: .infinity)
                .background(OhiaColors.chipRestBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            case .notApplicable, .ready:
                EmptyView()
            }
        }
        .padding(8)
        .background(OhiaColors.composerRaisedPanelBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isHeaderHovering ? OhiaColors.ohiaYellow : OhiaColors.iconPillBorder,
                    lineWidth: isHeaderHovering ? 1.5 : 1
                )
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHeaderHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Original Message")
    }

    @ViewBuilder
    private var disclosureHeader: some View {
        if case .ready(let quoted) = presentation {
            ComposerDisclosureHeaderButton(action: toggleExpansion) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .frame(width: 14, height: 14)

                    ComposerSectionHeader(
                        title: "Original Message",
                        symbolName: "text.quote"
                    )

                    Text(attribution(from: quoted))
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .help(isExpanded ? "Collapse Original Message" : "Expand Original Message")
            .accessibilityLabel(isExpanded ? "Collapse Original Message" : "Expand Original Message")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .onHover { isHeaderHovering = $0 }
        } else {
            ComposerSectionHeader(
                title: "Original Message",
                symbolName: "text.quote"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            isExpanded.toggle()
        }
    }

    private func attribution(from quote: String) -> String {
        quote.split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? "Prepared"
    }
}

private struct ComposerDraftQuoteDivider: View {
    static let hitTargetHeight: CGFloat = 10

    @Binding var lowerPaneHeight: CGFloat
    let minimumLowerPaneHeight: CGFloat
    let maximumLowerPaneHeight: CGFloat

    @State private var dragStartHeight: CGFloat?
    @State private var isHovering = false

    private var isActive: Bool {
        isHovering || dragStartHeight != nil
    }

    var body: some View {
        ZStack {
            Color.clear

            Rectangle()
                .fill(
                    isActive
                        ? OhiaColors.ohiaYellow.opacity(0.55)
                        : OhiaColors.glassBorderBright
                )
                .frame(height: isActive ? 2 : 1)
        }
        .frame(height: Self.hitTargetHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let renderedHeight = min(
                        max(lowerPaneHeight, minimumLowerPaneHeight),
                        maximumLowerPaneHeight
                    )
                    let startHeight = dragStartHeight ?? renderedHeight
                    if dragStartHeight == nil {
                        dragStartHeight = startHeight
                    }
                    lowerPaneHeight = min(
                        max(
                            startHeight - value.translation.height,
                            minimumLowerPaneHeight
                        ),
                        maximumLowerPaneHeight
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    if isHovering {
                        NSCursor.resizeUpDown.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
        )
        .onDisappear {
            NSCursor.arrow.set()
        }
        .help("Drag to resize the original message")
        .accessibilityLabel("Resize original message")
    }
}
