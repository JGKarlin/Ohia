import AppKit
import SwiftUI
import OhiaCore
import OhiaML

/// The input region of the Ask tab: question editor + voice / clear-history /
/// Ask actions. Pulled out of `ConstellationAskTab` so the parent body stays
/// short and structural.
struct AskInputArea: View {
    @Bindable var viewModel: QAViewModel
    let dictation: VoiceDictation
    // `@MainActor @Sendable`: required because `submit()` captures these
    // closures inside a `Task { … }`, which has a `@Sendable` initializer.
    // The parent (`ConstellationAskTab`) supplies them by wrapping its
    // own main-actor closures in a closure literal so the Sendable
    // attribution is explicit at the conversion site.
    let activeFilter: @MainActor @Sendable () async -> FilterSpec
    let threadContextProvider: @MainActor @Sendable ([RetrievalResult]) async -> AskThreadExpansion
    var focus: SwiftUI.FocusState<AskFocus?>.Binding
    /// Called when Tab is pressed inside the editor — hops focus to the first
    /// (newest) history row. Parent computes the target id since the editor
    /// doesn't see the history list.
    let onTabForward: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            editor
            actionRow
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.question.isEmpty {
                Text("Ask anything about the filtered constellation...")
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $viewModel.question)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .tint(OhiaColors.ohiaGreen)
                .padding(4)
                .frame(minHeight: 70, maxHeight: 110)
                .focused(focus, equals: .editor)
                .onKeyPress(.return, action: handleReturnKey)
                .onKeyPress(.tab, action: handleTabKey)
        }
        .background(OhiaColors.surface(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(OhiaColors.glassBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            AskVoiceButton(viewModel: viewModel, dictation: dictation)
            clearHistoryButton
            Spacer()
            askButton
        }
    }

    private var clearHistoryButton: some View {
        Button(action: clearHistory) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                Text("Clear history")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OhiaColors.ohiaGreen)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(OhiaColors.buttonBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Clear all past questions and answers from this session")
        .disabled(viewModel.history.isEmpty)
        .opacity(viewModel.history.isEmpty ? 0.5 : 1)
    }

    private var askButton: some View {
        Button(action: submit) {
            HStack(spacing: 4) {
                Text("Ask").fontWeight(.semibold)
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 11))
            .foregroundStyle(OhiaColors.ohiaGreen)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(OhiaColors.buttonBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSubmitQuestion)
        .opacity(canSubmitQuestion ? 1 : 0.5)
    }

    private var canSubmitQuestion: Bool {
        !viewModel.isAnyRunning
            && !viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleReturnKey() -> KeyPress.Result {
        if NSEvent.modifierFlags.contains(.shift) {
            return .ignored
        }
        let trimmed = viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard !viewModel.isAnyRunning else { return .handled }
        submit()
        return .handled
    }

    /// Tab inside the editor moves focus into the history list (if any rows
    /// exist) instead of inserting a literal tab character. Falls through
    /// when there's no history so the system can do its default thing.
    private func handleTabKey() -> KeyPress.Result {
        guard !viewModel.history.isEmpty else { return .ignored }
        onTabForward()
        return .handled
    }

    private func clearHistory() {
        viewModel.reset()
        // The rows that owned focus just disappeared; land focus back in
        // the editor explicitly so it doesn't fall through to window level.
        focus.wrappedValue = .editor
    }

    private func submit() {
        Task {
            let filter = await activeFilter()
            await viewModel.submit(
                filter: filter,
                threadContextProvider: threadContextProvider
            )
        }
    }
}
