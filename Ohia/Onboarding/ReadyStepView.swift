import Foundation
import SwiftUI
import OhiaCore
import OhiaIngest
import OhiaML

struct ReadyStepView: View {
    let selectedAccount: DiscoveredAccount?
    let selectedColorIndex: Int?
    let selectedLanguages: [String]
    let onPrepareModel: (ModelInfo, GenerationModelMode) -> Void
    let onBegin: () -> Void

    @Environment(WorkerFleetStatusPublisher.self) private var workerStatuses: WorkerFleetStatusPublisher?
    @State private var modelPreparation = ReadyStepModelPreparationState()
    @AppStorage(
        ModelManager.stoppedGenerationModelIDKey,
        store: OhiaSharedDefaults.store
    ) private var stoppedGenerationModelID = ""

    private var languageNames: String {
        let names = Dictionary(
            uniqueKeysWithValues: ContentLanguageOption.supported.map { ($0.id, $0.displayName) }
        )
        return selectedLanguages
            .compactMap { names[$0] }
            .joined(separator: ", ")
    }

    /// The account color the user picked on the account step, resolved to a
    /// SwiftUI color at full brightness so the account row's envelope matches
    /// the selected swatch. Falls back to the palette default when unset.
    private var accountColor: Color {
        let paletteColor = AccountColorPalette.color(forIndex: selectedColorIndex)
        let rgb = AccountColorPalette.rgb(for: paletteColor, brightness: 1.0)
        return Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1.0)
    }

    private var recommendationPair: ModelRecommendationPair {
        ModelManager.recommendedPairForCurrentHardware()
    }

    /// The primary memory-compatible opt-in model, when this Mac can run one.
    /// Mirrors Model Settings, whose single Ultra tab targets the first entry.
    private var ultraModel: ModelInfo? {
        recommendationPair.optInModels.first
    }

    private var availableSegments: [ReadyStepModelSelection] {
        ReadyStepModelSelection.availableSegments(hasOptInModel: ultraModel != nil)
    }

    private var selectedModel: ModelInfo {
        switch modelPreparation.selectedSegment {
        case .mode(let mode):
            return recommendationPair.model(for: mode)
        case .ultra:
            // The Ultra segment is only offered when an opt-in model exists;
            // the fallback keeps this total if state and hardware ever disagree.
            return ultraModel ?? recommendationPair.model(for: .quality)
        }
    }

    private var hardwareInfo: HardwareInfo {
        ModelManager.hardwareInfo()
    }

    private var generationModelDownloadBaseDirectory: URL {
        OhiaStorageRoot.required().publicModels
    }

    private var selectedModelIsFullyDownloaded: Bool {
        GenerationModelStorage.isModelDownloaded(
            downloadBaseDirectory: generationModelDownloadBaseDirectory,
            modelID: selectedModel.modelId
        )
    }

    private var reportedModelDownloadState: WorkerModelLoadState {
        guard workerStatuses?.qwen.worker.model?.name == selectedModel.displayName else {
            return .unavailable
        }
        return workerStatuses?.qwen.worker.model?.state ?? .unavailable
    }

    private var modelDownloadState: WorkerModelLoadState {
        guard modelPreparation.shouldShowDownloadProgress else {
            return .unavailable
        }
        if ModelManager.isGenerationModelDownloadStopped(for: selectedModel.modelId) {
            return .paused("Download stopped. Select Resume Download to continue.")
        }
        if selectedModelIsFullyDownloaded {
            switch reportedModelDownloadState {
            case .loading, .ready:
                return reportedModelDownloadState
            case .unavailable, .downloading, .downloaded, .paused, .failed:
                return .downloaded
            }
        }
        switch reportedModelDownloadState {
        case .downloaded, .loading, .ready:
            return .unavailable
        case .unavailable, .downloading, .paused, .failed:
            return reportedModelDownloadState
        }
    }

    private var modelDownloadSnapshot: WorkerModelDownloadSnapshot? {
        guard workerStatuses?.qwen.worker.model?.name == selectedModel.displayName else {
            return nil
        }
        return workerStatuses?.qwen.worker.model?.download
    }

    private var modelDownloadProgress: Double? {
        if let fraction = modelDownloadSnapshot?.fraction {
            return fraction
        }
        if case .downloading(let fraction) = modelDownloadState {
            return min(1, max(0, fraction))
        }
        return nil
    }

    private var selectedModelDownloadDetail: String {
        if let totalBytes = modelDownloadSnapshot?.totalBytes {
            return "\(formattedBytes(totalBytes)) download"
        }
        return String(format: "%.1f GB download", selectedModel.estimatedDownloadGB)
    }

    /// Hardware line plus a description of the currently selected tier only,
    /// so the card stays compact with three segments.
    private var selectedSegmentCaption: String {
        let hardware = "Recommended for \(hardwareInfo.chipName) · \(hardwareInfo.memoryGB) GB."
        switch modelPreparation.selectedSegment {
        case .mode(.performance):
            return "\(hardware)\nPerformance uses \(recommendationPair.performance.displayName)."
        case .mode(.quality):
            return "\(hardware)\nQuality uses \(recommendationPair.quality.displayName)."
        case .ultra:
            return "\(hardware)\nUltra uses \(selectedModel.displayName) — the largest local model for the most demanding tasks."
        }
    }

    private var modelDownloadDetail: String {
        guard modelPreparation.shouldShowDownloadProgress else {
            return "Choose a mode, then prepare the selected Qwen model."
        }
        switch modelDownloadState {
        case .unavailable:
            return "Preparing the model download."
        case .downloading:
            return modelDownloadByteProgressText ?? "Downloading model files."
        case .downloaded:
            return "The download is complete. You can continue now."
        case .loading:
            return "The download is complete. You can continue now."
        case .ready:
            return "The download is complete. You can continue now."
        case .paused(let message):
            return message ?? "The model download is stopped. Select Resume Download to continue."
        case .failed(let message):
            return message.isEmpty ? "Check the network connection, then reopen Ohia to retry." : message
        }
    }

    private var modelDownloadByteProgressText: String? {
        guard let snapshot = modelDownloadSnapshot else { return nil }
        let downloaded = formattedBytes(snapshot.downloadedBytes)
        if let totalBytes = snapshot.totalBytes {
            let total = formattedBytes(totalBytes)
            if let progress = modelDownloadProgress {
                let percent = Int((progress * 100).rounded())
                return "\(downloaded) of \(total) downloaded · \(percent)%"
            }
            return "\(downloaded) of \(total) downloaded"
        }
        guard snapshot.downloadedBytes > 0 else { return nil }
        return "\(downloaded) downloaded"
    }

    private var modelDownloadFootnote: String {
        guard modelPreparation.shouldShowDownloadProgress else {
            return "Performance is selected by default."
        }
        switch modelDownloadState {
        case .downloaded, .loading, .ready:
            return "You're ready to continue."
        case .paused:
            return "The model download is stopped. Select Resume Download to continue."
        case .failed:
            return "Ohia couldn't finish setup. Check your connection, then reopen Ohia to retry."
        case .unavailable, .downloading:
            return "Keep Ohia open while setup continues."
        }
    }

    private var isModelDownloadComplete: Bool {
        guard modelPreparation.shouldShowDownloadProgress,
              selectedModelIsFullyDownloaded
        else { return false }
        switch modelDownloadState {
        case .downloaded, .loading, .ready:
            return true
        case .unavailable, .downloading, .paused, .failed:
            return false
        }
    }

    private var isModelDownloadStoppable: Bool {
        guard modelPreparation.shouldShowDownloadProgress else { return false }
        switch modelDownloadState {
        case .unavailable, .downloading:
            return true
        case .downloaded, .loading, .paused, .ready, .failed:
            return false
        }
    }

    private var isModelDownloadPaused: Bool {
        guard modelPreparation.shouldShowDownloadProgress else { return false }
        if case .paused = modelDownloadState { return true }
        return false
    }

    var body: some View {
        ZStack {
            NightSkyView(showsMilkyWay: false)
            NightSkyNebulaOverlay()

            VStack(spacing: 0) {
                Spacer()

                Text("Ready")
                    .font(OhiaTypography.stepHeading)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 28)

                // Summary card
                VStack(spacing: 0) {
                    // Account
                    if let account = selectedAccount {
                        summaryRow(
                            icon: "envelope.fill",
                            iconColor: accountColor,
                            title: account.emailAddress,
                            detail: "Direct mail connection"
                        )
                        Divider().background(OhiaColors.glassBorder)
                    }

                    // Languages
                    if !languageNames.isEmpty {
                        let count = selectedLanguages.count
                        summaryRow(
                            icon: "globe",
                            iconColor: OhiaColors.textSecondary,
                            title: languageNames,
                            detail: "\(count) language\(count == 1 ? "" : "s")"
                        )
                        Divider().background(OhiaColors.glassBorder)
                    }

                    // Model recommendation
                    VStack(spacing: 0) {
                        summaryRow(
                            icon: "cpu",
                            iconColor: OhiaColors.textSecondary,
                            title: "\(modelPreparation.selectedSegment.displayName): \(selectedModel.displayName)",
                            detail: selectedModelDownloadDetail
                        )

                        Picker("Generation mode", selection: $modelPreparation.selectedSegment) {
                            ForEach(availableSegments, id: \.self) { segment in
                                Text(segment.displayName).tag(segment)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(modelPreparation.hasRequestedDownload)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .accessibilityLabel("Generation mode")

                        HStack {
                            Text(selectedSegmentCaption)
                                .font(OhiaTypography.caption)
                                .foregroundStyle(OhiaColors.textPrimary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                        modelDownloadStatusView
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }
                // No fill — border only, matching the box-free wizard steps
                // (Choose email history, Choose an account, Sign in).
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(OhiaColors.glassBorder, lineWidth: 1)
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 24)

                Text(modelDownloadFootnote)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 32)

                primaryActionButton

                Spacer()

            }
            .padding(.horizontal, 48)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if !modelPreparation.hasRequestedDownload || isModelDownloadFailed {
            Button(action: prepareSelectedModel) {
                Text(isModelDownloadFailed ? "Retry Download" : "Prepare Model")
                    .font(OhiaTypography.buttonLarge)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
            .help("Download the selected Qwen model")
        } else if isModelDownloadPaused {
            Button(action: prepareSelectedModel) {
                Text("Resume Download")
                    .font(OhiaTypography.buttonLarge)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
            .help("Resume the selected Qwen model download")
        } else {
            Button(action: {
                guard isModelDownloadComplete else { return }
                onBegin()
            }) {
                Text("Begin")
                    .font(OhiaTypography.buttonLarge)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 40, verticalPadding: 12))
            .disabled(!isModelDownloadComplete)
            .help(isModelDownloadComplete ? "Continue" : "Waiting for the Qwen model download to finish")
        }
    }

    private var isModelDownloadFailed: Bool {
        guard modelPreparation.hasRequestedDownload else { return false }
        if case .failed = modelDownloadState { return true }
        return false
    }

    private func prepareSelectedModel() {
        modelPreparation.requestDownload()
        let mode = modelPreparation.selectedSegment.persistedMode
        ModelManager.setSelectedGenerationModelMode(mode)
        ModelManager.setSelectedGenerationModelID(selectedModel.modelId)
        stoppedGenerationModelID = ""
        onPrepareModel(selectedModel, mode)
    }

    private func stopSelectedModelDownload() {
        ModelManager.setGenerationModelDownloadStopped(true, modelID: selectedModel.modelId)
        stoppedGenerationModelID = selectedModel.modelId
        AppCommand.cancelGenerationModelPreparation(selectedModel.modelId)
    }

    @ViewBuilder
    private var modelDownloadStatusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: modelDownloadIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(modelDownloadColor)
                    .frame(width: 16)

                Text(modelDownloadTitle)
                    .font(OhiaTypography.caption)
                    .foregroundStyle(modelDownloadColor)
                    .lineLimit(1)

                Spacer()
            }

            if case .downloading = modelDownloadState {
                if let progress = modelDownloadProgress {
                    ProgressView(value: progress)
                        .tint(OhiaColors.chipActiveForeground)
                        .accessibilityLabel("Qwen model download progress")
                        .accessibilityValue(modelDownloadAccessibilityValue(for: progress))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Qwen model download progress")
                }
            } else if modelPreparation.shouldShowDownloadProgress, case .unavailable = modelDownloadState {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Starting Qwen model download")
            }

            Text(modelDownloadDetail)
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if isModelDownloadStoppable {
                Button(action: stopSelectedModelDownload) {
                    Label("Stop Download", systemImage: "pause.circle")
                        .font(OhiaTypography.caption)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 6))
                .help("Stop the selected Qwen model download")
            }
        }
    }

    private var modelDownloadTitle: String {
        guard modelPreparation.shouldShowDownloadProgress else {
            return "Ready to prepare"
        }
        switch modelDownloadState {
        case .unavailable:
            return "Starting model download"
        case .downloading:
            if let progress = modelDownloadProgress {
                return "Downloading model \(Int((progress * 100).rounded()))%"
            }
            return "Downloading model"
        case .downloaded:
            return "Download complete"
        case .loading:
            return "Download complete"
        case .ready:
            return "Download complete"
        case .paused:
            return "Download stopped"
        case .failed:
            return "Model preparation failed"
        }
    }

    private var modelDownloadIcon: String {
        guard modelPreparation.shouldShowDownloadProgress else {
            return "cpu"
        }
        switch modelDownloadState {
        case .unavailable:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.fill"
        case .downloaded, .loading, .ready:
            return "checkmark.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var modelDownloadColor: Color {
        guard modelPreparation.shouldShowDownloadProgress else {
            return OhiaColors.textSecondary
        }
        switch modelDownloadState {
        case .unavailable:
            return OhiaColors.textSecondary
        case .downloading:
            return OhiaColors.chipActiveForeground
        case .downloaded, .loading, .ready:
            return OhiaColors.ohiaGreen
        case .paused:
            return OhiaColors.textSecondary
        case .failed:
            return OhiaColors.ohiaRed
        }
    }

    private func modelDownloadAccessibilityValue(for progress: Double) -> String {
        let percent = "\(Int((progress * 100).rounded())) percent"
        guard let snapshot = modelDownloadSnapshot,
              let totalBytes = snapshot.totalBytes
        else {
            return percent
        }
        return "\(formattedBytes(snapshot.downloadedBytes)) of \(formattedBytes(totalBytes)), \(percent)"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: bytes)
    }

    private func summaryRow(icon: String, iconColor: Color, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(title)
                .font(OhiaTypography.body)
                .foregroundStyle(OhiaColors.textPrimary)

            Spacer()

            if let detail {
                Text(detail)
                    .font(OhiaTypography.bodySecondary)
                    .foregroundStyle(OhiaColors.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
