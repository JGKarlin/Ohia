// Ohia/ConstellationMode/QA/VoiceDictation.swift
import Foundation
import Observation
import Speech
import AVFoundation

/// Mic-button dictation service for the Ask sidebar. Wraps `SFSpeechRecognizer`
/// + `AVAudioEngine` for live partial transcription that streams into a
/// caller-supplied `onUpdate` closure (the Ask panel routes that into
/// `viewModel.question` so the field updates as the user speaks).
///
/// Privacy strings required in Info.plist (or as `INFOPLIST_KEY_*` build
/// settings, both of which are Apple-well-known):
/// - `NSSpeechRecognitionUsageDescription`
/// - `NSMicrophoneUsageDescription`
///
/// Without these, `SFSpeechRecognizer.requestAuthorization` either blocks
/// silently or returns `.denied`. The first run of the dictation button
/// shows the system permission sheets; subsequent runs reuse the grant.
@Observable @MainActor
public final class VoiceDictation {

    public enum Status: Sendable, Equatable {
        case idle
        case preparing
        case recording
        case denied(String)
        case unavailable(String)
    }

    public private(set) var status: Status = .idle
    public var isRecording: Bool { status == .recording }
    public var isPreparing: Bool { status == .preparing }

    /// Live transcript updates as the user speaks. Wired by the Ask panel
    /// to the question TextEditor's binding so the field shows the words
    /// as they're recognized.
    public var onUpdate: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored
    private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored
    private var task: SFSpeechRecognitionTask?
    @ObservationIgnored
    private var silenceTask: Task<Void, Never>?
    @ObservationIgnored
    private var maximumDurationTask: Task<Void, Never>?
    @ObservationIgnored
    private var inputTapInstalled = false
    /// Snapshotted at start so the dictated text appends to whatever the
    /// user already typed (rather than overwriting it). The recognition
    /// task only sees audio captured during this session.
    private var prefix: String = ""
    private var sessionID = UUID()
    private var hasRecognizedSpeech = false
    private var finishingAfterUserAction = false

    private static let initialSilenceTimeoutNanos: UInt64 = 6_000_000_000
    private static let completionSilenceTimeoutNanos: UInt64 = 1_400_000_000
    /// `SFSpeechRecognizer` imposes an approximately one-minute ceiling.
    /// Stop just before it so the request can finish cleanly.
    private static let maximumRecognitionDurationNanos: UInt64 = 55_000_000_000

    public init() {}

    public func toggle(currentText: String) async {
        switch status {
        case .recording:
            stop()
        case .preparing:
            return
        case .idle, .denied, .unavailable:
            await start(currentText: currentText)
        }
    }

    // MARK: - Start

    private func start(currentText: String) async {
        status = .preparing

        guard recognizer?.isAvailable == true else {
            status = .unavailable("Speech recognition is not available right now.")
            return
        }

        // Authorization (one-shot, cached by the system after first grant).
        let authStatus = await Self.authorizeSpeechRecognition()
        guard authStatus == .authorized else {
            status = .denied(Self.deniedMessage(for: authStatus))
            return
        }

        // macOS gates microphone access too. AVCaptureDevice covers it for
        // us — `requestAccess` returns immediately if previously granted.
        let micGranted = await Self.requestMicrophoneAccess()
        guard micGranted else {
            status = .denied("Microphone access was not granted. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }

        do {
            try beginAudioSession(prefix: currentText)
            status = .recording
        } catch {
            cancelRecognition()
            status = .unavailable("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func beginAudioSession(prefix: String) throws {
        // Reset any prior session.
        cancelRecognition()

        self.prefix = prefix
        sessionID = UUID()
        hasRecognizedSpeech = false
        finishingAfterUserAction = false
        let activeSessionID = sessionID

        guard let recognizer else {
            throw DictationError.recognizerUnavailable
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.taskHint = .dictation
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.contextualStrings = [
            "Ohia",
            "Qwen",
            "constellation",
            "sender",
            "thread",
            "attachment",
            "calendar",
            "citation"
        ]
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.microphoneUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        inputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        scheduleInitialSilenceTimeout(for: activeSessionID)
        scheduleMaximumDurationTimeout(for: activeSessionID)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.sessionID == activeSessionID else { return }
                var receivedFinalResult = false
                if let result {
                    receivedFinalResult = result.isFinal
                    self.handleRecognitionResult(result, sessionID: activeSessionID)
                }
                if let error, !receivedFinalResult {
                    self.handleRecognitionError(error)
                }
            }
        }
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult,
        sessionID activeSessionID: UUID
    ) {
        let spokenText = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !spokenText.isEmpty {
            hasRecognizedSpeech = true
            onUpdate?(combinedTranscript(with: spokenText))
            scheduleCompletionSilenceTimeout(for: activeSessionID)
        }

        if result.isFinal {
            completeRecognition()
        }
    }

    private func handleRecognitionError(_ error: Error) {
        let expectedStop = finishingAfterUserAction || Self.isExpectedStopError(error)
        completeRecognition()
        guard !expectedStop else { return }
        status = .unavailable("Speech recognition stopped: \(error.localizedDescription)")
    }

    private func combinedTranscript(with spokenText: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return spokenText }
        return prefix + (prefix.hasSuffix(" ") || prefix.hasSuffix("\n") ? "" : " ") + spokenText
    }

    // MARK: - Stop

    public func stop() {
        finishRecognition()
        if status == .recording { status = .idle }
    }

    private func finishRecognition() {
        finishingAfterUserAction = true
        stopAudioEngine()
        request?.endAudio()
        request = nil
        task?.finish()
        cancelTimers()
    }

    private func completeRecognition() {
        stopAudioEngine()
        request = nil
        task = nil
        cancelTimers()
        finishingAfterUserAction = false
        if status == .recording || status == .preparing {
            status = .idle
        }
    }

    private func cancelRecognition() {
        stopAudioEngine()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        cancelTimers()
        finishingAfterUserAction = false
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    // MARK: - Completion timers

    private func scheduleInitialSilenceTimeout(for activeSessionID: UUID) {
        scheduleSilenceTimeout(
            after: Self.initialSilenceTimeoutNanos,
            for: activeSessionID,
            requireRecognizedSpeech: false
        )
    }

    private func scheduleCompletionSilenceTimeout(for activeSessionID: UUID) {
        scheduleSilenceTimeout(
            after: Self.completionSilenceTimeoutNanos,
            for: activeSessionID,
            requireRecognizedSpeech: true
        )
    }

    private func scheduleSilenceTimeout(
        after nanoseconds: UInt64,
        for activeSessionID: UUID,
        requireRecognizedSpeech: Bool
    ) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await MainActor.run {
                guard let self,
                      self.sessionID == activeSessionID,
                      self.status == .recording,
                      !requireRecognizedSpeech || self.hasRecognizedSpeech
                else { return }
                self.finishRecognition()
                self.status = .idle
            }
        }
    }

    private func scheduleMaximumDurationTimeout(for activeSessionID: UUID) {
        maximumDurationTask?.cancel()
        maximumDurationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.maximumRecognitionDurationNanos)
            } catch {
                return
            }
            await MainActor.run {
                guard let self,
                      self.sessionID == activeSessionID,
                      self.status == .recording
                else { return }
                self.finishRecognition()
                self.status = .idle
            }
        }
    }

    private func cancelTimers() {
        silenceTask?.cancel()
        silenceTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
    }

    // MARK: - Authorization helpers

    private static func authorizeSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else { return currentStatus }

        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private static func deniedMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:        return "Speech recognition is denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .restricted:    return "Speech recognition is restricted on this device."
        case .notDetermined: return "Speech recognition permission was not granted."
        case .authorized:    return ""
        @unknown default:    return "Speech recognition is unavailable."
        }
    }

    private static func isExpectedStopError(_ error: Error) -> Bool {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 301), ("kAFAssistantErrorDomain", 1110):
            return true
        default:
            return false
        }
    }
}

private enum DictationError: LocalizedError {
    case recognizerUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "The system speech recognizer is not available for this language."
        case .microphoneUnavailable:
            "No microphone input format is available."
        }
    }
}
