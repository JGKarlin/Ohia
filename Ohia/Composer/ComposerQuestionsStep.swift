// Ohia/Composer/ComposerQuestionsStep.swift
// Step 1 of the Composer flow: deterministic local traversal of the planned
// conditional interview. The flow rail keeps this step available after
// generation so the user can revisit its decisions.

import SwiftUI
import OhiaML

@MainActor
protocol ComposerDecisionsHost: ComposerSourceHost, ComposerQuestionRoundsHost {
    var step: ComposerStep { get set }
    var decisionsPhase: ComposerDecisionsPhase { get }
    var decisionsStepSubtitle: String { get }
    var draftingInstructionText: String { get set }
    var decisionVersions: [ComposerDecisionVersion] { get }
    var activeDecisionVersionID: UUID? { get }
    var resolvedAnswerCount: Int { get }
    var allQuestionsResolved: Bool { get }
    var isAwaitingModel: Bool { get }
    var awaitingReason: String { get }
    var isGenerationBlocked: Bool { get }
    var generationBlockedReason: String { get }
    var showsCentralPreparationIndicator: Bool { get }
    var versions: [ComposerDraftVersion] { get }
    var hasDraftVersions: Bool { get }
    var draftVersionCount: Int { get }
    var draftNoun: String { get }
    var canAdvanceFromSources: Bool { get }
    var needsInitialSourcePreparation: Bool { get }
    var isDeterminingInitialSources: Bool { get }
    var showsDraftGuidanceWhileCurating: Bool { get }
    var hasPendingDecisionSourceChanges: Bool { get }
    /// The current question's typed or picked answer, not yet submitted.
    var pendingAnswerDraft: ComposerPendingAnswerDraft { get set }
}

/// An answer the author has typed or picked for the current question but not
/// submitted. Held on the host rather than in the view, so a remount of the
/// Decisions step (switching to Draft and back) keeps what was typed.
struct ComposerPendingAnswerDraft: Equatable {
    /// The question this answer belongs to, compared whole: node ids alone
    /// can repeat across re-checks.
    var node: ComposerInterviewNode?
    var selectedOptionID: String?
    var text = ""

    var nodeID: String? { node?.id }

    /// The draft to hold once `currentNode` is the question on screen. A
    /// remount showing the very same question keeps what was typed; any other
    /// question, or a remount after the question itself changed, starts empty.
    func reconciled(toCurrentNode currentNode: ComposerInterviewNode?, isRemount: Bool) -> ComposerPendingAnswerDraft {
        if isRemount, node == currentNode { return self }
        return ComposerPendingAnswerDraft(node: currentNode)
    }

    /// The draft Generate may submit. Text held for a question that is no
    /// longer current (a re-check replaced the interview, or settled it with
    /// no questions) belongs to nothing on screen, so it is dropped rather
    /// than left to block the draft.
    func submittable(currentNodeID: String?) -> ComposerPendingAnswerDraft {
        nodeID == currentNodeID ? self : ComposerPendingAnswerDraft()
    }
}

enum ComposerDecisionUpdateState {
    private struct AnswerValue: Equatable {
        let nodeID: String
        let selectedOptionID: String?
        let freeText: String?
        let skipped: Bool
    }

    static func hasChanges(
        currentState: ComposerInterviewState?,
        activeVersion: ComposerDecisionVersion,
        latestDraftCreatedAt: Date
    ) -> Bool {
        if values(for: currentState) != values(for: activeVersion.interviewState) {
            return true
        }
        if activeVersion.createdAt > latestDraftCreatedAt {
            return true
        }
        return activeVersion.interviewState.answers.contains {
            $0.committedAt > latestDraftCreatedAt
        }
    }

    static func hasChanges(
        currentState: ComposerInterviewState?,
        currentDraftGuidance: String,
        activeVersion: ComposerDecisionVersion,
        generatedVersion: ComposerDecisionVersion,
        legacyGeneratedDraftGuidance: String?
    ) -> Bool {
        if values(for: currentState) != values(for: generatedVersion.interviewState) {
            return true
        }
        let generatedGuidance = normalizedGuidance(
            generatedVersion.draftGuidance ?? legacyGeneratedDraftGuidance
        )
        if normalizedGuidance(currentDraftGuidance) != generatedGuidance {
            return true
        }
        return activeVersion.sources != generatedVersion.sources
    }

    static func generatedVersion(
        from versions: [ComposerDecisionVersion],
        latestDraftCreatedAt: Date
    ) -> ComposerDecisionVersion? {
        versions
            .filter { $0.createdAt <= latestDraftCreatedAt }
            .max { $0.createdAt < $1.createdAt }
            ?? versions.min { $0.index < $1.index }
    }

    static func guidanceToRestore(
        from version: ComposerDecisionVersion,
        latestDraftCreatedAt: Date
    ) -> String? {
        guard version.createdAt <= latestDraftCreatedAt else { return nil }
        return version.draftGuidance
    }

    static func showsDraftGuidance(
        hasDraftVersions: Bool,
        hasChanges: Bool,
        isDrafting: Bool
    ) -> Bool {
        hasDraftVersions || !isDrafting
    }

    static func isGenerateDisabled(
        isAwaitingModel: Bool,
        hasPendingSourceChanges: Bool,
        canAdvanceFromSources: Bool,
        hasDraftVersions: Bool,
        hasChanges: Bool
    ) -> Bool {
        isAwaitingModel
            || hasPendingSourceChanges
            || !canAdvanceFromSources
            || (hasDraftVersions && !hasChanges)
    }

    private static func values(for state: ComposerInterviewState?) -> [AnswerValue] {
        (state?.answers ?? []).map { answer in
            let trimmed = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AnswerValue(
                nodeID: answer.nodeID,
                selectedOptionID: answer.selectedOptionID,
                freeText: trimmed?.isEmpty == false ? trimmed : nil,
                skipped: answer.skipped
            )
        }
        .sorted { $0.nodeID < $1.nodeID }
    }

    private static func normalizedGuidance(_ guidance: String?) -> String {
        guidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension ComposerDecisionsHost {
    var needsInitialSourcePreparation: Bool { false }
    var isDeterminingInitialSources: Bool { false }
    var showsCentralPreparationIndicator: Bool { false }
}

enum ComposerDraftGuidanceDisclosure {
    static func initialState(isNewMessage: Bool) -> ComposerDisclosureState {
        isNewMessage ? .locked : .open
    }

    static func chevronName(isExpanded: Bool) -> String {
        isExpanded ? "chevron.down" : "chevron.right"
    }
}

enum ComposerDraftGuidanceAction: Equatable {
    case continueSources
    case generateDraft
}

enum ComposerDraftGuidanceShortcut {
    static func action(
        key: KeyEquivalent,
        modifiers: EventModifiers,
        phase: ComposerDecisionsPhase
    ) -> ComposerDraftGuidanceAction? {
        guard key == .return,
              modifiers.isEmpty || modifiers == .command else {
            return nil
        }

        switch phase {
        case .curatingSources:
            return .continueSources
        case .answering, .readyToDraft, .drafting, .invalid:
            return .generateDraft
        case .evaluating, .decidingNext:
            return nil
        }
    }
}

enum ComposerCentralWorkPresentation {
    static func showsIndicator(
        phase: ComposerDecisionsPhase,
        isAwaitingModel: Bool,
        showsCentralPreparationIndicator: Bool
    ) -> Bool {
        guard isAwaitingModel else { return false }
        return showsCentralPreparationIndicator
            || phase == .evaluating
            || phase == .decidingNext
    }
}

struct ComposerQuestionsStep<Host: ComposerDecisionsHost, StageRail: View>: View {
    @Bindable var session: Host
    @Environment(\.readingTextSize) private var readingTextSize
    /// The incoming message's summary, shown so the user can decide without
    /// leaving the flow.
    let messageSummary: String?
    /// The cleaned incoming message body, shown when the "They wrote" section
    /// is opened. HTML remains rich; plain-text mail keeps the native text path.
    let messageBody: ComposerIncomingMessageBody?
    /// New-message addressing requirement shown beside the disabled first
    /// Continue button. Nil once both recipient and subject are present.
    let initialSourceRequirementText: String?
    /// Curate-then-evaluate: submit the curated sources for the model to
    /// evaluate (and re-evaluate after the sources change). Flips the draft to
    /// `evaluatingSources`.
    let onContinue: () -> Void
    /// Commit one answer into the persisted graph. Closed answers and skips
    /// advance locally; free text may enqueue one bounded repair.
    let onCommitAnswer: (ComposerInterviewNode, String?, String?, Bool) -> Void
    /// Reopen one path entry and prune all downstream state deterministically.
    let onChangeAnswer: (String) -> Void
    /// Write the draft from the resolved decisions (or directly when the
    /// sources already cover the reply). Flips the draft to `generating`.
    let onGenerate: () -> Void
    /// The 1 Decisions › 2 Draft rail, shown under the column header.
    let stageRail: StageRail

    @State private var sectionDisclosureStates: [DecisionSection: ComposerDisclosureState] = [:]
    @State private var hoveredSection: DecisionSection?
    @State private var pendingAnswerError: String?
    @FocusState private var focusedSection: DecisionSection?
    @FocusState private var instructionEditorFocused: Bool

    /// ⌥ morphs Continue into an immediate Generate Draft override (see
    /// `OptionKeyMonitor`); observed here so the footer relabels live.
    private var isGenerateDraftOverride: Bool {
        !session.needsInitialSourcePreparation && OptionKeyMonitor.shared.isOptionHeld
    }

    var body: some View {
        GlassPane(
            accentColor: OhiaColors.chipActiveForeground,
            isForeground: true,
            isFocused: true
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned column header: it shares one line with the Queue,
                // Sources, and Style headers, with the stage rail under it.
                // The column keeps its "Draft" title on both steps; the rail
                // says which step is showing. It never closes, so it carries
                // no chevron.
                ComposerColumnHeader(control: nil, columnTitle: "Draft") {
                    ComposerSectionHeader(
                        title: "Draft",
                        symbolName: "square.and.pencil",
                        titleWeight: .bold
                    )
                } trailing: {
                    if let progressText = decisionsProgressText {
                        HStack(spacing: 6) {
                            if session.isAwaitingModel && !session.isGenerationBlocked {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                            Text(progressText)
                                .font(OhiaTypography.cardSignal)
                                .foregroundStyle(OhiaColors.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 260, alignment: .trailing)
                    } else if session.decisionsPhase == .answering
                        || session.decisionsPhase == .readyToDraft
                        || session.decisionsPhase == .drafting {
                        Text("\(session.resolvedAnswerCount) decided")
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.textTertiary)
                    }
                }

                stageRail
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                            if incomingMessageTextAvailable {
                                expandableSection(
                                    .theyWrote,
                                    title: "They wrote",
                                    symbolName: "envelope.open"
                                ) {
                                    if let summary = normalized(messageSummary) {
                                        Text(summary)
                                            .font(readingTextSize.font(base: 13))
                                            .lineSpacing(readingTextSize.spacing(2))
                                            .foregroundStyle(OhiaColors.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } expanded: {
                                    if let document = messageBody?.htmlDocument {
                                        LockedEmailHTMLView(
                                            document: document,
                                            blendsWithCanvas: true,
                                            loadsRemoteImages: false
                                        )
                                        .frame(height: 360)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    } else if let text = normalized(messageBody?.plainText)
                                        ?? normalized(messageSummary) {
                                        Text(text)
                                            .font(readingTextSize.font(base: 13))
                                            .lineSpacing(readingTextSize.spacing(2))
                                            .foregroundStyle(OhiaColors.textSecondary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }

                            scrollPhaseContent
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .padding(.top, 12)

                pinnedFooter
            }
        }
        .alert("Could Not Start Draft", isPresented: Binding(
            get: { pendingAnswerError != nil },
            set: { if !$0 { pendingAnswerError = nil } }
        )) {
            Button("OK", role: .cancel) { pendingAnswerError = nil }
        } message: {
            Text(pendingAnswerError ?? "")
        }
        .onChange(of: session.activeDecisionVersionID) { previousID, activeID in
            guard previousID != activeID,
                  let activeID,
                  let active = session.decisionVersions.first(where: { $0.id == activeID }),
                  let latestDraftCreatedAt = session.versions.last?.createdAt,
                  let guidance = ComposerDecisionUpdateState.guidanceToRestore(
                    from: active,
                    latestDraftCreatedAt: latestDraftCreatedAt
                  ) else {
                return
            }
            session.draftingInstructionText = guidance
        }
    }

    private enum DecisionSection: Hashable {
        case theyWrote
        case draftInstruction
    }

    /// The scrolling decision interview or sources-are-sufficient confirmation.
    /// Action buttons live in `pinnedFooter` so they stay in view.
    @ViewBuilder
    private var scrollPhaseContent: some View {
        switch session.decisionsPhase {
        case .curatingSources:
            if session.isGenerationBlocked {
                blockedWorkMessage
            } else if session.showsDraftGuidanceWhileCurating {
                initialDraftInstructionSection
            }
        case .evaluating:
            if showsCentralWorkIndicator {
                centralWorkIndicator
            } else if session.isGenerationBlocked {
                blockedWorkMessage
            }
        case .decidingNext:
            if showsCentralWorkIndicator {
                centralWorkIndicator
            } else {
                questionsBlock
                initialDraftInstructionSection
            }
        case .answering:
            questionsBlock
            initialDraftInstructionSection
        case .invalid:
            questionsBlock
            initialDraftInstructionSection
        case .readyToDraft, .drafting:
            if session.showsCentralPreparationIndicator {
                centralWorkIndicator
            } else {
                // Two ready states: the sources covered the draft outright (no
                // questions were ever asked), so the completion card stands in for
                // the interview; otherwise the resolved transcript stays visible.
                // (`.drafting` mirrors this if the collapsed step is reopened.)
                if session.interviewState?.planningOutcome == .empty {
                    readyCard
                } else {
                    questionsBlock
                }
                initialDraftInstructionSection
            }
        }
    }

    /// The static action line, pinned below the scrolling content so Continue,
    /// Generate, and Re-check never slide off-screen. Processing state belongs
    /// beside the pane header rather than occupying a second content row.
    @ViewBuilder
    private var pinnedFooter: some View {
        if phaseHasActionButtons {
            VStack(alignment: .leading, spacing: 10) {
                actionBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(OhiaColors.iconPillBorder)
                    .frame(height: 0.5)
            }
        }
    }

    /// Whether the current phase offers action buttons in the footer.
    private var phaseHasActionButtons: Bool {
        guard session.hasDraftRow else { return false }
        switch session.decisionsPhase {
        case .curatingSources:
            return session.hasDraftRow
        case .answering, .readyToDraft, .drafting, .invalid:
            return true
        case .evaluating, .decidingNext:
            // A check that failed and is parked offers its retry.
            return session.isGenerationBlocked
        }
    }

    private var decisionsProgressText: String? {
        if session.isGenerationBlocked {
            let reason = session.generationBlockedReason
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? nil : reason
        }
        guard session.isAwaitingModel else { return nil }
        let reason = session.awaitingReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    private var showsCentralWorkIndicator: Bool {
        ComposerCentralWorkPresentation.showsIndicator(
            phase: session.decisionsPhase,
            isAwaitingModel: session.isAwaitingModel,
            showsCentralPreparationIndicator: session.showsCentralPreparationIndicator
        )
    }

    private var centralWorkIndicator: some View {
        AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 520, slotHeight: 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            .accessibilityLabel(decisionsProgressText ?? "Composer working")
    }

    private var blockedWorkMessage: some View {
        Label(
            session.generationBlockedReason,
            systemImage: "exclamationmark.triangle"
        )
        .font(OhiaTypography.cardBody)
        .foregroundStyle(OhiaColors.ohiaRed)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var readyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 14))
                .foregroundStyle(OhiaColors.chipActiveForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your sources cover this \(session.draftNoun)")
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                Text("No questions needed — generate the draft when you're ready, or add a source and re-check.")
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipActiveBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The decision interview, shown open (not collapsed behind hover) once
    /// the evaluation has produced it — it is the focus of this phase.
    private var questionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerSectionHeader(
                title: "Draft Questions",
                symbolName: "questionmark.bubble",
                titleWeight: .bold
            )
            ComposerQuestionRoundsView(
                state: session.interviewState,
                phase: session.decisionsPhase,
                draftNoun: session.draftNoun,
                interactionLocked: session.isAwaitingModel
                    || session.hasPendingDecisionSourceChanges,
                onCommit: onCommitAnswer,
                onChangeAnswer: onChangeAnswer,
                pendingAnswer: $session.pendingAnswerDraft
            )
            .padding(.vertical, 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var initialDraftInstructionSection: some View {
        if ComposerDecisionUpdateState.showsDraftGuidance(
            hasDraftVersions: session.hasDraftVersions,
            hasChanges: hasUpdatedDecisions,
            isDrafting: session.decisionsPhase == .drafting
        ) {
            expandableSection(
                .draftInstruction,
                title: "Draft guidance",
                symbolName: "text.quote"
            ) {
                Text(collapsedDraftInstructionText)
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(collapsedDraftInstructionIsEmpty ? OhiaColors.textTertiary : OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } expanded: {
                draftInstructionEditor
            }
        }
    }

    private var collapsedDraftInstructionText: String {
        let trimmed = session.draftingInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No draft guidance" : trimmed
    }

    private var collapsedDraftInstructionIsEmpty: Bool {
        session.draftingInstructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftInstructionEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $session.draftingInstructionText)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(OhiaColors.toolbarBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 78, maxHeight: 118)
                .focused($instructionEditorFocused)
                .onKeyPress(.return, phases: .down) { press in
                    handleDraftInstructionKeyPress(press)
                }

            if collapsedDraftInstructionIsEmpty {
                Text(
                    session.draftNoun == "email"
                        ? "Describe the aim, purpose, and intent of the message."
                        : "Add anything else the Composer should know before drafting."
                )
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var incomingMessageTextAvailable: Bool {
        normalized(messageSummary) != nil || normalized(messageBody?.plainText) != nil
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            actionButtons
            Spacer()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.decisionsPhase {
        case .curatingSources:
            continueButton
            if session.needsInitialSourcePreparation {
                Text(
                    session.canAdvanceFromSources
                        ? "Continue to determine relevant sources."
                        : (initialSourceRequirementText
                            ?? "Add at least one recipient and a subject, then Continue.")
                )
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
            } else if session.hasDraftRow {
                Text("Continue and the model checks these sources, asking only what they can't settle.")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        case .evaluating, .decidingNext:
            // The pane header carries these phases; only a check that failed
            // and is parked offers an action: checking the sources again.
            if session.isGenerationBlocked {
                recheckButton
            }
        case .answering:
            generateButton
            recheckButton
            if !session.allQuestionsResolved {
                Text("Unanswered questions remain unknown; the draft will not invent those details.")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        case .readyToDraft, .drafting:
            generateButton
            recheckButton
        case .invalid:
            generateButton
            recheckButton
        }
    }

    /// Submit the curated sources for evaluation (`collectingSources` → the
    /// model decides whether anything needs asking). Hold ⌥ to skip the
    /// interview and generate the draft immediately.
    private var continueButton: some View {
        Button {
            activateContinueButton()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isGenerateDraftOverride ? "text.append" : "arrow.right.circle")
                    .font(.system(size: 12))
                Text(isGenerateDraftOverride ? generateDraftLabel : "Continue")
                    .font(OhiaTypography.button)
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 16, verticalPadding: 8))
        .keyboardShortcut(.defaultAction)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(continueButtonDisabled)
        .help(isGenerateDraftOverride
            ? "Generate the draft now without waiting for source evaluation"
            : (session.needsInitialSourcePreparation
                ? "Determine sources from the recipients and subject"
                : "Submit curated sources for the model to evaluate"))
    }

    private var continueButtonDisabled: Bool {
        isGenerateDraftOverride
            ? (session.isAwaitingModel || !session.canAdvanceFromSources)
            : (!session.hasDraftRow || session.isAwaitingModel || !session.canAdvanceFromSources)
    }

    private func activateContinueButton() {
        guard session.decisionsPhase == .curatingSources,
              !continueButtonDisabled else {
            return
        }
        if isGenerateDraftOverride {
            generateWithPendingAnswer()
        } else {
            onContinue()
        }
    }

    private func handleDraftInstructionKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let action = ComposerDraftGuidanceShortcut.action(
            key: press.key,
            modifiers: press.modifiers,
            phase: session.decisionsPhase
        ) else {
            return .ignored
        }

        switch action {
        case .continueSources:
            activateContinueButton()
        case .generateDraft:
            guard !generateButtonDisabled else { return .handled }
            generateWithPendingAnswer()
        }
        return .handled
    }

    private var generateDraftLabel: String {
        session.hasDraftVersions ? "Regenerate with Updated Decisions" : "Generate Draft"
    }

    private var generateButton: some View {
        Button {
            generateWithPendingAnswer()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.append")
                    .font(.system(size: 12))
                Text(generateDraftLabel)
                    .font(OhiaTypography.button)
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 16, verticalPadding: 8))
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(generateButtonDisabled)
    }

    private func generateWithPendingAnswer() {
        let pending = session.pendingAnswerDraft.submittable(
            currentNodeID: session.interviewProjection?.currentNode?.id
        )
        if pending != session.pendingAnswerDraft {
            session.pendingAnswerDraft = pending
        }
        let text = pending.text
        do {
            if let (node, optionID) = try ComposerQuestionRoundsPresentation.pendingAnswerNode(
                in: session.interviewState, nodeID: pending.nodeID,
                selectedOptionID: pending.selectedOptionID, freeText: text
            ) {
                onCommitAnswer(node, optionID, text, false)
                guard session.interviewState?.answers.contains(where: {
                    $0.nodeID == node.id && $0.freeText == text && !$0.skipped
                }) == true else {
                    pendingAnswerError = "Your answer could not be saved. It remains in the question field; try submitting it again."
                    return
                }
            }
            onGenerate()
        } catch ComposerInterviewExecutionError.invalidAnswer {
            pendingAnswerError = "Your answer no longer fits this question's choices. Review it and submit it before generating."
        } catch {
            pendingAnswerError = "Your answer could not be submitted for the current question. Review it and submit it before generating."
        }
    }

    private var activeDecisionVersion: ComposerDecisionVersion? {
        if let activeID = session.activeDecisionVersionID,
           let active = session.decisionVersions.first(where: { $0.id == activeID }) {
            return active
        }
        return session.decisionVersions.last
    }

    private var hasUpdatedDecisions: Bool {
        guard session.hasDraftVersions,
              let activeDecisionVersion,
              let latestDraftCreatedAt = session.versions.last?.createdAt,
              let generatedDecisionVersion = ComposerDecisionUpdateState.generatedVersion(
                from: session.decisionVersions,
                latestDraftCreatedAt: latestDraftCreatedAt
              ) else {
            return false
        }
        return ComposerDecisionUpdateState.hasChanges(
            currentState: session.interviewState,
            currentDraftGuidance: session.draftingInstructionText,
            activeVersion: activeDecisionVersion,
            generatedVersion: generatedDecisionVersion,
            legacyGeneratedDraftGuidance: latestFullGenerationGuidance
        )
    }

    private var latestFullGenerationGuidance: String? {
        session.versions.reversed().first {
            $0.trigger == "initial" || $0.trigger == "regenerate"
        }?.instruction
    }

    private var generateButtonDisabled: Bool {
        ComposerDecisionUpdateState.isGenerateDisabled(
            isAwaitingModel: session.isAwaitingModel,
            hasPendingSourceChanges: session.hasPendingDecisionSourceChanges,
            canAdvanceFromSources: session.canAdvanceFromSources,
            hasDraftVersions: session.hasDraftVersions,
            hasChanges: hasUpdatedDecisions
        )
    }

    /// Re-run the source evaluation after curating sources further — questions
    /// are regenerated from the updated evidence.
    private var recheckButton: some View {
        Button {
            onContinue()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                Text("Re-check sources")
                    .font(OhiaTypography.button)
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 8))
        .disabled(
            session.isAwaitingModel
                || (!session.isGenerationBlocked
                    && !session.hasPendingDecisionSourceChanges
                    && session.decisionsPhase != .invalid)
        )
    }

    private func expandableSection<CollapsedContent: View, ExpandedContent: View>(
        _ section: DecisionSection,
        title: String,
        symbolName: String,
        count: Int? = nil,
        @ViewBuilder collapsed: () -> CollapsedContent,
        @ViewBuilder expanded: () -> ExpandedContent
    ) -> some View {
        let isOpen = sectionIsOpen(section)
        let disclosureState = sectionDisclosureState(section)
        let isFocused = focusedSection == section
        let chevronName = section == .draftInstruction && session.draftNoun == "email"
            ? ComposerDraftGuidanceDisclosure.chevronName(isExpanded: isOpen)
            : (section == .theyWrote
                ? (isOpen ? "chevron.down" : "chevron.right")
                : disclosureState.chevronName(isExpanded: isOpen))
        let disclosureHelpText = section == .theyWrote
            ? (isOpen ? "Collapse \(title)" : "Expand \(title)")
            : disclosureState.helpText(title: title, isExpanded: isOpen)
        let disclosureAccessibilityValue = section == .theyWrote
            ? (isOpen ? "Open" : "Closed")
            : disclosureState.accessibilityValue
        return VStack(alignment: .leading, spacing: 8) {
            ComposerDisclosureHeaderButton {
                advanceDisclosureState(for: section)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: chevronName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .frame(width: 14, height: 14)

                    ComposerSectionHeader(title: title, symbolName: symbolName, count: count, titleWeight: .bold)
                    Spacer()
                }
            }
            .help(disclosureHelpText)
            .accessibilityLabel(disclosureHelpText)
            .accessibilityValue(disclosureAccessibilityValue)

            if isOpen {
                expanded()
                    .transition(ComposerDisclosureState.transition)
            } else if section == .theyWrote {
                ComposerDisclosureHeaderButton {
                    advanceDisclosureState(for: section)
                } label: {
                    collapsed()
                }
                .help(disclosureHelpText)
                .accessibilityHint(disclosureHelpText)
                .transition(.opacity)
            } else {
                collapsed()
                    .transition(.opacity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isFocused ? OhiaColors.ohiaYellow : OhiaColors.chipRestBorder,
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .focusable(true)
        .focused($focusedSection, equals: section)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleSectionKeyPress(press, section: section)
        }
        .onHover { hovering in
            withAnimation(ComposerDisclosureState.animation) {
                updateHover(hovering, for: section)
            }
        }
        .animation(ComposerDisclosureState.animation, value: isOpen)
    }

    private func sectionIsOpen(_ section: DecisionSection) -> Bool {
        if section == .theyWrote {
            return sectionDisclosureState(section) == .locked
        }
        return sectionDisclosureState(section).isExpanded(isHovering: hoveredSection == section)
    }

    private func sectionDisclosureState(_ section: DecisionSection) -> ComposerDisclosureState {
        sectionDisclosureStates[section]
            ?? (section == .draftInstruction
                ? ComposerDraftGuidanceDisclosure.initialState(
                    isNewMessage: session.draftNoun == "email"
                )
                : .closed)
    }

    private func advanceDisclosureState(for section: DecisionSection) {
        withAnimation(ComposerDisclosureState.animation) {
            let current = sectionDisclosureState(section)
            focusedSection = section
            if section == .theyWrote {
                sectionDisclosureStates[section] = current == .locked ? .closed : .locked
                return
            }
            if current == .locked {
                hoveredSection = section
            }
            sectionDisclosureStates[section] = current.next
        }
    }

    private func handleSectionKeyPress(_ press: KeyPress, section: DecisionSection) -> KeyPress.Result {
        guard focusedSection == section,
              !instructionEditorFocused,
              press.key == .space else {
            return .ignored
        }
        advanceDisclosureState(for: section)
        return .handled
    }

    private func updateHover(_ hovering: Bool, for section: DecisionSection) {
        if hovering {
            hoveredSection = section
            focusedSection = section
        } else if hoveredSection == section {
            hoveredSection = nil
            if focusedSection == section {
                focusedSection = nil
            }
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
