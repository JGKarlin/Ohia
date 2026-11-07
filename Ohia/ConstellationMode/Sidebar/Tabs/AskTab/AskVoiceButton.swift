import SwiftUI
import OhiaCore
import OhiaML

/// Mic / waveform toggle that drives `VoiceDictation` and pipes the live
/// transcript into the Ask tab's question field.
struct AskVoiceButton: View {
    @Bindable var viewModel: QAViewModel
    let dictation: VoiceDictation

    var body: some View {
        Button(action: toggleDictation) {
            content
                .frame(minWidth: 18)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(OhiaColors.buttonBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Dictate question")
        .accessibilityValue(accessibilityValue)
        .disabled(dictation.isPreparing)
    }

    @ViewBuilder
    private var content: some View {
        if dictation.isPreparing {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
        }
    }

    private var symbolName: String {
        switch dictation.status {
        case .recording:                "waveform"
        case .denied, .unavailable:     "mic.slash"
        case .idle, .preparing:         "mic"
        }
    }

    private var tint: Color {
        switch dictation.status {
        case .denied, .unavailable:     OhiaColors.frameUrgencyHigh
        case .idle, .preparing, .recording: OhiaColors.ohiaGreen
        }
    }

    private var helpText: String {
        switch dictation.status {
        case .idle:                       "Dictate your question"
        case .preparing:                  "Preparing dictation..."
        case .recording:                  "Stop dictation"
        case .denied(let m), .unavailable(let m): m
        }
    }

    private var accessibilityValue: String {
        switch dictation.status {
        case .idle:                       "Off"
        case .preparing:                  "Preparing"
        case .recording:                  "Recording"
        case .denied:                     "Permission denied"
        case .unavailable:                "Unavailable"
        }
    }

    private func toggleDictation() {
        Task {
            dictation.onUpdate = { transcript in viewModel.question = transcript }
            await dictation.toggle(currentText: viewModel.question)
        }
    }
}
