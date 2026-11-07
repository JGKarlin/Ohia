// Ohia/Composer/ComposerQuestionRounds.swift
// Shared rendering for the Composer's deterministic conditional interview.

import SwiftUI
import OhiaML

@MainActor
protocol ComposerQuestionRoundsHost: AnyObject {
    var interviewState: ComposerInterviewState? { get }
}

extension ComposerQuestionRoundsHost {
    var interviewProjection: ComposerInterviewProjection? {
        interviewState.map(ComposerInterviewExecutor.project)
    }

    var resolvedAnswerCount: Int {
        interviewProjection?.decidedCount ?? 0
    }

    var allQuestionsResolved: Bool {
        interviewProjection?.isTerminal == true
    }
}

enum ComposerQuestionGroundingPresentation {
    static func isDisplayableResolvedFact(
        _ grounding: QuestionGrounding,
        matching question: ComposerInterviewNode? = nil,
        evidenceFingerprint: String? = nil
    ) -> Bool {
        QuestionGroundingValidation.isResolvedFact(
            grounding,
            matching: question,
            evidenceFingerprint: evidenceFingerprint
        )
    }

    static func attribution(
        for citation: QuestionGroundingCitation,
        draftNoun: String
    ) -> String {
        if citation.origin == .anchor {
            return draftNoun == "reply"
                ? "Found in this message"
                : "Found in your brief"
        }

        let label = citation.label
        switch citation.sourceKindRawValue.flatMap(ComposerSource.Kind.init(rawValue:)) {
        case .thread, .pastReply, .attachment, .retrieved, .email:
            return "Found in mail · \(label)"
        case .note, .file, .calendar, .contact, .notesApp, .screenshot, .messages:
            return "Found in \(label)"
        case .website, .mcp:
            return "From \(label)"
        case .memory:
            return "From remembered context · \(label)"
        case .threadState:
            return "From thread context · \(label)"
        case nil:
            return "Found in \(label)"
        }
    }
}

enum ComposerQuestionRoundsPresentation {
    /// The choice an answer is submitted under on a choice question: the
    /// author's pick, or none when they only typed. Typed words replace the
    /// choice either way; the one repair reads which choice they mean.
    static func submittedOptionID(
        for node: ComposerInterviewNode, selectedOptionID: String?, freeText: String
    ) -> String? {
        guard node.responseType == .multipleChoice else { return nil }
        return selectedOptionID
    }

    /// How the one repair read an answer's typed words, shown when that is
    /// not simply the pick: no pick was made, or the words mean another
    /// choice. Words the repair could not read show nothing.
    static func readingNote(
        for answer: ComposerInterviewAnswer?, node: ComposerInterviewNode
    ) -> String? {
        guard let answer, !answer.skipped, node.responseType == .multipleChoice,
              answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let reading = answer.typedReading else {
            return nil
        }
        // Words that mean none of the choices stand for the open "Other".
        let option = reading.optionID.flatMap { id in node.options.first { $0.id == id } }
            ?? node.options.first { $0.kind == .otherUnanticipated }
        guard answer.selectedOptionID == nil || option?.id != answer.selectedOptionID else { return nil }
        return "Read as: \(option?.label ?? "none of the choices")"
    }

    static func pendingAnswerNode(
        in state: ComposerInterviewState?, nodeID: String?,
        selectedOptionID: String?, freeText: String
    ) throws -> (node: ComposerInterviewNode, selectedOptionID: String?)? {
        guard !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let state, let node = ComposerInterviewExecutor.project(state).currentNode,
              node.id == nodeID else {
            throw ComposerInterviewExecutionError.nodeIsNotCurrent(nodeID ?? "")
        }
        let optionID = submittedOptionID(for: node, selectedOptionID: selectedOptionID, freeText: freeText)
        _ = try ComposerInterviewExecutor.commit(
            nodeID: node.id, selectedOptionID: optionID, freeText: freeText,
            skipped: false, in: state
        )
        return (node, optionID)
    }

    static func currentNode(
        in projection: ComposerInterviewProjection?,
        phase: ComposerDecisionsPhase
    ) -> ComposerInterviewNode? {
        guard phase != .decidingNext else { return nil }
        return projection?.currentNode
    }
}

struct ComposerQuestionRoundsView: View {
    let state: ComposerInterviewState?
    let phase: ComposerDecisionsPhase
    let draftNoun: String
    let interactionLocked: Bool
    let onCommit: (
        _ node: ComposerInterviewNode,
        _ selectedOptionID: String?,
        _ freeText: String?,
        _ skipped: Bool
    ) -> Void
    let onChangeAnswer: (_ nodeID: String) -> Void

    /// The current question's unsubmitted answer, owned by the host so it
    /// survives this view being remounted.
    @Binding var pendingAnswer: ComposerPendingAnswerDraft
    /// A question the author is answering holds focus so its options can be
    /// picked by number: after an answer here or a click on the question,
    /// never on its own (a question appearing must not take keys from a
    /// field the author is typing in). The answer field takes focus back
    /// when clicked, and digits typed there are text.
    private var selectedOptionID: String? {
        get { pendingAnswer.selectedOptionID }
        nonmutating set { pendingAnswer.selectedOptionID = newValue }
    }

    private var freeText: String { pendingAnswer.text }

    @FocusState private var questionFocused: Bool
    @FocusState private var answerFieldFocused: Bool
    @State private var answeredHere = false

    private var projection: ComposerInterviewProjection? {
        state.map(ComposerInterviewExecutor.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state?.planningOutcome == .invalid {
                invalidPlanningCard
            } else {
                if let transcript = projection?.transcript, !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(transcript) { entry in
                            transcriptRow(entry)
                        }
                    }
                }

                if let node = ComposerQuestionRoundsPresentation.currentNode(
                    in: projection,
                    phase: phase
                ) {
                    questionBlock(node, number: (projection?.decidedCount ?? 0) + 1)
                        .id(node.id)
                }

                if phase == .decidingNext {
                    decidingRow
                }

                if hasRepairFailure {
                    repairFailureCard
                }

                if projection?.isTerminal == true, phase != .decidingNext {
                    interviewCompleteCard
                }
            }
        }
        .onChange(of: projection?.currentNode?.id, initial: true) { previousNodeID, currentNodeID in
            // The pending answer lives on the host, so remounting this view
            // (switching to Draft and back, or a phase that briefly hides the
            // questions) keeps it while the very same question is current. Node ids are
            // short model-assigned strings that a re-check can reuse for a
            // different question, so the kept answer must match the whole
            // node, not just its id.
            let reconciled = pendingAnswer.reconciled(
                toCurrentNode: projection?.currentNode,
                isRemount: previousNodeID == currentNodeID
            )
            if reconciled != pendingAnswer {
                pendingAnswer = reconciled
            }
            guard answeredHere else { return }
            answeredHere = false
            if projection?.currentNode?.responseType == .multipleChoice {
                // The new question's view replaces the answered one; focus it
                // once it is in the hierarchy.
                Task { @MainActor in questionFocused = true }
            }
        }
    }

    private var hasRepairFailure: Bool {
        state?.answers.contains { answer in
            if case .failed(let fingerprint) = answer.repairDisposition {
                return fingerprint == answer.answerFingerprint
            }
            return false
        } == true
    }

    private func transcriptRow(_ entry: ComposerInterviewTranscriptEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            questionNumberBadge(entry.ordinal)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.node.text ?? "Decision")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.ohiaYellow)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.displayText)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = ComposerQuestionRoundsPresentation.readingNote(
                        for: entry.answer, node: entry.node
                    ) {
                        Text(note)
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let grounding = entry.grounding {
                        ForEach(Array(grounding.citations.enumerated()), id: \.offset) { _, citation in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("“\(citation.supportingQuote)”")
                                    .font(OhiaTypography.cardSignal)
                                    .foregroundStyle(OhiaColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    ComposerQuestionGroundingPresentation.attribution(
                                        for: citation,
                                        draftNoun: draftNoun
                                    )
                                )
                                .font(OhiaTypography.cardSignal)
                                .foregroundStyle(OhiaColors.textTertiary)
                            }
                        }
                    }
                }
                Spacer()
                Button("Change") {
                    onChangeAnswer(entry.node.id)
                }
                .font(OhiaTypography.cardSignal)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                .disabled(interactionLocked)
                .help("Change this decision and discard later answers on its path")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipActiveBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 6))
    }

    private var decidingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Deciding what else is needed")
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textSecondary)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 6))
    }

    private var interviewCompleteCard: some View {
        statusCard(
            symbol: "checkmark.seal",
            title: "Nothing more to ask",
            detail: "Your decisions cover this \(draftNoun) — generate the draft when you're ready, or change a decision above."
        )
    }

    private var invalidPlanningCard: some View {
        statusCard(
            symbol: "exclamationmark.triangle",
            title: "Questions could not be prepared. Add Draft guidance or generate directly.",
            detail: nil
        )
    }

    private var repairFailureCard: some View {
        statusCard(
            symbol: "exclamationmark.bubble",
            title: "Ohia could not adapt the remaining questions. Your added detail will still guide the draft.",
            detail: nil
        )
    }

    private func statusCard(symbol: String, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 6))
    }

    private func questionBlock(_ node: ComposerInterviewNode, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                questionNumberBadge(number)
                if node.scope == .approach {
                    Text("Direction")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
                Spacer()
            }
            Text(node.text ?? "What should the draft do?")
                .font(node.scope == .approach ? OhiaTypography.cardTitle : OhiaTypography.questionText)
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    if node.responseType == .multipleChoice { questionFocused = true }
                }

            if node.responseType == .multipleChoice {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(node.options.enumerated()), id: \.element.id) { index, option in
                        optionRow(node: node, option: option, number: index + 1)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(
                    node.responseType != .multipleChoice ? "Your answer"
                        : node.options.first(where: { $0.id == selectedOptionID })?.kind == .authorWords
                            ? "Your answer now, then press Return"
                            : "Type to replace the choice, then press Return",
                    text: $pendingAnswer.text,
                    axis: .vertical
                )
                .lineLimit(1...)
                .textFieldStyle(.plain)
                .focused($answerFieldFocused)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(6)
                .background(OhiaColors.toolbarBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(.rect(cornerRadius: 4))
                .disabled(interactionLocked)
                .onSubmit {
                    commitCurrent(node)
                }

                Button("Skip") {
                    answeredHere = true
                    onCommit(node, nil, nil, true)
                }
                .font(OhiaTypography.cardSignal)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
                .disabled(interactionLocked)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.chipRestBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .focusable(node.responseType == .multipleChoice)
        .focusEffectDisabled()
        .focused($questionFocused)
        .onKeyPress(.return, phases: .down) { press in
            guard node.responseType == .multipleChoice, !interactionLocked, !answerFieldFocused,
                  press.modifiers.intersection([.command, .control, .option]).isEmpty,
                  selectedOptionID != nil || normalizedFreeText != nil else { return .ignored }
            commitCurrent(node)
            return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard node.responseType == .multipleChoice, !interactionLocked, !answerFieldFocused,
                  press.modifiers.intersection([.command, .control, .option]).isEmpty,
                  let number = Int(press.characters), node.options.indices.contains(number - 1) else { return .ignored }
            choose(node.options[number - 1], in: node)
            return .handled
        }
    }

    private func questionNumberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(OhiaTypography.cardSignal.monospacedDigit().weight(.bold))
            .foregroundStyle(OhiaColors.toolbarBackground)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 20, height: 20)
            .background(Circle().fill(OhiaColors.chipActiveForeground))
            .accessibilityLabel("Question \(number)")
    }

    /// A click and the option's number key pick the same way: they select,
    /// so the author can still type their own answer, which replaces the
    /// pick in the draft and in the route: the follow-up questions are those
    /// of the choice the typed words mean, not of the pick.
    /// Return, or picking the selected option again, submits.
    private func choose(_ option: ComposerInterviewOption, in node: ComposerInterviewNode) {
        if selectedOptionID == option.id {
            commitCurrent(node)
            return
        }
        selectedOptionID = option.id
        // A choice completed in the author's words.
        if option.kind == .authorWords {
            answerFieldFocused = true
        } else if !answerFieldFocused {
            questionFocused = true
        }
    }

    private func optionRow(
        node: ComposerInterviewNode,
        option: ComposerInterviewOption,
        number: Int
    ) -> some View {
        let isSelected = selectedOptionID == option.id
        return Button {
            choose(option, in: node)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                    .accessibilityHidden(true)
                Text("\(number)")
                    .font(OhiaTypography.questionOption.monospacedDigit())
                    .foregroundStyle(OhiaColors.textTertiary)
                    .accessibilityLabel("Option \(number)")
                Text(option.label)
                    .font(OhiaTypography.questionOption)
                    .foregroundStyle(isSelected ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? OhiaColors.chipActiveBackground : .clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(interactionLocked)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var normalizedFreeText: String? {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : freeText
    }

    private func commitCurrent(_ node: ComposerInterviewNode) {
        switch node.responseType {
        case .multipleChoice:
            let optionID = ComposerQuestionRoundsPresentation.submittedOptionID(
                for: node, selectedOptionID: selectedOptionID, freeText: freeText
            )
            // A pick, typed words, or both; the open "other" pick needs the
            // author's own words.
            guard optionID != nil || normalizedFreeText != nil else { return }
            if let optionID,
               node.options.first(where: { $0.id == optionID })?.needsMoreWords(than: normalizedFreeText) == true { return }
            // Typing only the label of a choice in the author's words ("No")
            // is not yet their answer.
            if optionID == nil,
               node.options.contains(where: { $0.kind == .authorWords && $0.needsMoreWords(than: normalizedFreeText) }) { return }
            answeredHere = true
            onCommit(node, optionID, normalizedFreeText, false)
        case .freeText:
            guard normalizedFreeText != nil else { return }
            answeredHere = true
            onCommit(node, nil, freeText, false)
        case nil:
            return
        }
    }
}
