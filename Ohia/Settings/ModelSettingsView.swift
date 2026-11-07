// Ohia/Settings/ModelSettingsView.swift
// Model selection, retrieval model display, and download/load status.

import SwiftUI
import AppKit
import OhiaCore
import OhiaML

struct ModelSettingsView: View {
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(ModelLoadingService.self) private var modelLoader: ModelLoadingService?
    @Environment(WorkerFleetStatusPublisher.self) private var workerStatuses: WorkerFleetStatusPublisher?
    @Environment(\.workerFleetSupervisor) private var workerSupervisor: WorkerFleetSupervisor?

    private let hardware = ModelManager.hardwareInfo()

    @State private var storageStats: ModelStorageStats?
    @State private var modelPendingDelete: DownloadedModel?
    @State private var modelPendingDownload: PendingDownloadConfirmation?
    @State private var storageStatusMessage: String?
    @State private var storageStatusIsError = false
    // Apple Intelligence is macOS-managed (not downloaded by Ohia), so the row
    // mirrors its live model generation, availability, and capabilities.
    // Refreshed on appear and app reactivation so it tracks system changes.
    @State private var appleIntelligenceProfile = AppleIntelligenceModelProfile.current()
    @AppStorage(ModelManager.selectedTranslationEngineKey, store: OhiaSharedDefaults.store)
    private var selectedTranslationEngineRaw = TranslationEngineKind.defaultEngine.rawValue
    @AppStorage(SignatureGenerationEngineKind.selectedEngineKey) private var selectedSignatureEngineRaw = SignatureGenerationEngineKind.defaultEngine.rawValue
    @AppStorage(ModelManager.selectedGenerationModelIDKey, store: OhiaSharedDefaults.store)
    private var selectedGenerationModelID = ""
    @AppStorage(ModelManager.selectedGenerationModelModeKey, store: OhiaSharedDefaults.store)
    private var selectedGenerationModeRaw = GenerationModelMode.performance.rawValue
    @AppStorage(ModelManager.pendingGenerationModelIDKey, store: OhiaSharedDefaults.store)
    private var pendingGenerationModelID = ""
    @AppStorage(ModelManager.pendingGenerationModelModeKey, store: OhiaSharedDefaults.store)
    private var pendingGenerationModeRaw = ""
    @AppStorage(ModelManager.stoppedGenerationModelIDKey, store: OhiaSharedDefaults.store)
    private var stoppedGenerationModelID = ""

    private struct ModelStorageStats: Sendable {
        let models: [DownloadedModel]

        var modelCount: Int { models.count }
        var totalBytes: Int64 { models.reduce(0) { $0 + $1.sizeBytes } }
    }

    private struct DownloadedModel: Identifiable, Hashable, Sendable {
        let id: String        // e.g. "mlx-community/Qwen3-8B-4bit"
        let url: URL
        let sizeBytes: Int64
        let isComplete: Bool
    }

    /// A tab-selected model that needs downloading, parked until the user
    /// confirms the fetch. `mode` carries the tier the tab maps to (`.quality`
    /// for the opt-in "Ultra" tab) so the confirmed selection persists it.
    private struct PendingDownloadConfirmation: Identifiable, Sendable {
        let model: ModelInfo
        let mode: GenerationModelMode?
        var id: String { model.modelId }
    }

    private enum GenerationReadinessKind: Equatable {
        case ready
        case starting
        case downloading
        case downloaded
        case loading
        case waiting
        case missing
        case failed
        case paused
    }

    private struct GenerationReadiness {
        let kind: GenerationReadinessKind
        let label: String
        let detail: String?
        let progress: Double?
    }

    /// The top-tab options for the Generation Model picker. The two recommended
    /// tiers map to `GenerationModelMode`; `.ultra` maps to the high-memory
    /// opt-in model. The shared `GenerationModelMode` enum stays two-valued;
    /// onboarding mirrors this segment shape via `ReadyStepModelSelection`,
    /// and the two must persist identical state for the same choice.
    private enum GenerationSegment: Hashable {
        case mode(GenerationModelMode)
        case ultra
    }

    private struct RetrievalModelPresentation: Identifiable {
        let id: String
        let name: String
        let detail: String
        let status: String
        let state: WorkerFleetResourceState
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hardwareSummarySection

                generationModelSection

                translationModelSection

                signatureModelSection

                retrievalModelsSection

                appleIntelligenceSection

                modelStorageFooter
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Read on appear; refreshed on app reactivation below. Kept
            // independent of the storage-refresh task so neither refresh path
            // silently depends on the other.
            refreshAppleIntelligenceProfile()
            let resolvedTranslationEngine = ModelManager.selectedTranslationEngine()
            if selectedTranslationEngineRaw != resolvedTranslationEngine.rawValue {
                selectedTranslationEngineRaw = resolvedTranslationEngine.rawValue
            }
            let resolvedSignatureEngine = SignatureGenerationEngineKind.selected()
            if selectedSignatureEngineRaw != resolvedSignatureEngine.rawValue {
                selectedSignatureEngineRaw = resolvedSignatureEngine.rawValue
            }
        }
        .task(id: storageRefreshKey) {
            await refreshStorageStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAppleIntelligenceProfile()
            Task { await refreshStorageStats() }
        }
    }

    @ViewBuilder
    private var generationModelSection: some View {
        Text("Generative Model")
            .font(.title2)

        if let modelLoader {
            generationModelContent(modelLoader)
        } else {
            generationWorkerContent
        }
    }

    // MARK: - Translation Model

    private struct TranslationEngineAvailability {
        let label: String
        let color: Color
        let isSelectable: Bool
    }

    @ViewBuilder
    private var translationModelSection: some View {
        Text("Translation Model")
            .font(.title2)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(TranslationEngineKind.allCases) { kind in
                    translationEngineRow(kind)
                }

                Text("Sets the model that translates email bodies in the reading lenses. Apple On-Device uses Apple's Translation API (Apple Intelligence on macOS 26.4+).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func translationEngineRow(_ kind: TranslationEngineKind) -> some View {
        let availability = translationEngineAvailability(kind)
        let isSelected = selectedTranslationEngineRaw == kind.rawValue
        Button {
            ModelManager.setSelectedTranslationEngine(kind)
            selectedTranslationEngineRaw = kind.rawValue
        } label: {
            HStack(spacing: 10) {
                selectionGlyph(isActive: isSelected, isPending: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.callout.weight(.medium))
                    Text(kind.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                selectionBadge(availability.label, color: availability.color)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!availability.isSelectable && !isSelected)
        .opacity((availability.isSelectable || isSelected) ? 1 : 0.55)
    }

    private func translationEngineAvailability(_ kind: TranslationEngineKind) -> TranslationEngineAvailability {
        switch kind {
        case .qwen:
            return TranslationEngineAvailability(label: "Ready", color: .green, isSelectable: true)
        case .appleOnDevice:
            switch appleIntelligenceAvailability {
            case .available:
                return TranslationEngineAvailability(label: "Ready", color: .green, isSelectable: true)
            case .appleIntelligenceNotEnabled:
                return TranslationEngineAvailability(label: "Off", color: .orange, isSelectable: false)
            case .modelNotReady:
                return TranslationEngineAvailability(label: "Preparing", color: .orange, isSelectable: false)
            case .deviceNotEligible:
                return TranslationEngineAvailability(label: "Unavailable", color: .secondary, isSelectable: false)
            case .unknown:
                return TranslationEngineAvailability(label: "Unknown", color: .secondary, isSelectable: false)
            }
        }
    }

    // MARK: - Signatures

    @ViewBuilder
    private var signatureModelSection: some View {
        Text("Signatures")
            .font(.title2)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SignatureGenerationEngineKind.allCases) { kind in
                    signatureEngineRow(kind)
                }

                Text("Sets the model used to generate, regenerate, and revise signatures. Generative Model uses your selected Qwen model; Apple Intelligence uses Apple's on-device Foundation Models framework.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func signatureEngineRow(_ kind: SignatureGenerationEngineKind) -> some View {
        let availability = signatureEngineAvailability(kind)
        let isSelected = selectedSignatureEngineRaw == kind.rawValue
        Button {
            SignatureGenerationEngineKind.setSelected(kind)
            selectedSignatureEngineRaw = kind.rawValue
        } label: {
            HStack(spacing: 10) {
                selectionGlyph(isActive: isSelected, isPending: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.callout.weight(.medium))
                    Text(kind.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                selectionBadge(availability.label, color: availability.color)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!availability.isSelectable && !isSelected)
        .opacity((availability.isSelectable || isSelected) ? 1 : 0.55)
        .accessibilityValue(
            isSelected ? "Selected, \(availability.label)" : availability.label
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func signatureEngineAvailability(
        _ kind: SignatureGenerationEngineKind
    ) -> TranslationEngineAvailability {
        switch kind {
        case .generativeModel:
            let ready = appServices?.signatureGenerationService.isAvailable(for: kind) ?? false
            return TranslationEngineAvailability(
                label: ready ? "Ready" : "Not Ready",
                color: ready ? .green : .orange,
                isSelectable: true
            )
        case .appleIntelligence:
            switch appleIntelligenceAvailability {
            case .available:
                return TranslationEngineAvailability(label: "Ready", color: .green, isSelectable: true)
            case .appleIntelligenceNotEnabled:
                return TranslationEngineAvailability(label: "Off", color: .orange, isSelectable: false)
            case .modelNotReady:
                return TranslationEngineAvailability(label: "Preparing", color: .orange, isSelectable: false)
            case .deviceNotEligible:
                return TranslationEngineAvailability(label: "Unavailable", color: .secondary, isSelectable: false)
            case .unknown:
                return TranslationEngineAvailability(label: "Unknown", color: .secondary, isSelectable: false)
            }
        }
    }

    @ViewBuilder
    private var hardwareSummarySection: some View {
        let pair = recommendationPair

        Text("Hardware")
            .font(.title2)

        GroupBox(label: Text("This Mac").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    hardwareStat(label: "Chip", value: hardware.chipName)
                    Divider().frame(height: 26)
                    hardwareStat(label: "Memory", value: "\(hardware.memoryGB) GB")
                    Divider().frame(height: 26)
                    hardwareStat(label: "CPU cores", value: "\(hardware.activeProcessorCount)")
                    Spacer(minLength: 8)
                }

                if let modelIdentifier = hardware.modelIdentifier {
                    Text(modelIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Recommended pair")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pair.performance.displayName) for Performance · \(pair.quality.displayName) for Quality")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var generationWorkerContent: some View {
        let selectedModel = selectedGenerationModel
        let pendingModelID = pendingGenerationModel?.modelId
        let status = workerStatuses?.snapshot(for: .qwen)

        generationModeChooser(
            activeModelID: selectedModel.modelId,
            pendingModelID: pendingModelID,
            loader: nil,
            workerStatus: status
        )
    }

    @ViewBuilder
    private func generationModelContent(_ loader: ModelLoadingService) -> some View {
        let selectedModel = selectedGenerationModel
        let pendingModelID = loader.pendingModel?.modelId ?? pendingGenerationModel?.modelId
        let status = workerStatuses?.snapshot(for: .qwen)
        generationModeChooser(
            activeModelID: selectedModel.modelId,
            pendingModelID: pendingModelID,
            loader: loader,
            workerStatus: status
        )
    }

    @ViewBuilder
    private func generationModeChooser(
        activeModelID: String?,
        pendingModelID: String?,
        loader: ModelLoadingService?,
        workerStatus: WorkerStatusPresentationSnapshot?
    ) -> some View {
        let pair = recommendationPair

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                OhiaSegmentedPicker(
                    selection: segmentSelectionBinding(loader: loader),
                    options: generationSegments,
                    title: { segmentTitle($0) }
                )
                .accessibilityLabel("Generation model")
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(GenerationModelMode.allCases) { mode in
                        generationModeRow(
                            mode: mode,
                            model: pair.model(for: mode),
                            activeModelID: activeModelID,
                            pendingModelID: pendingModelID,
                            loader: loader,
                            workerStatus: workerStatus
                        )
                    }
                    ForEach(pair.optInModels) { model in
                        ultraRow(
                            model: model,
                            activeModelID: activeModelID,
                            pendingModelID: pendingModelID,
                            loader: loader,
                            workerStatus: workerStatus
                        )
                    }
                }

                Text("Switching models downloads the new choice first, then activates it after the final load succeeds. The current Qwen model remains active during the download.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            downloadConfirmTitle,
            isPresented: Binding(
                get: { modelPendingDownload != nil },
                set: { if !$0 { modelPendingDownload = nil } }
            ),
            titleVisibility: .visible,
            presenting: modelPendingDownload
        ) { pending in
            Button("Download") {
                selectAndPrepareGenerationModel(pending.model, loader: loader, mode: pending.mode)
                modelPendingDownload = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingDownload = nil
            }
        } message: { pending in
            Text(downloadConfirmMessage(for: pending.model))
        }
    }

    @ViewBuilder
    private var retrievalModelsSection: some View {
        Text("Retrieval Models")
            .font(.title2)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(retrievalModelPresentations) { model in
                    retrievalModelRow(model)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var appleIntelligenceSection: some View {
        Text("Apple Intelligence")
            .font(.title2)

        GroupBox {
            appleIntelligenceRow
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var appleIntelligenceRow: some View {
        let state = appleIntelligenceResourceState
        HStack(spacing: 10) {
            workerResourceStateImage(state)
                .foregroundStyle(workerResourceStateColor(state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Apple Foundation Model")
                        .font(.callout.weight(.medium))
                    selectionBadge(appleIntelligenceStatusLabel, color: workerResourceStateColor(state))
                    selectionBadge(
                        appleIntelligenceProfile.supportsVision ? "Vision supported" : "Vision unsupported",
                        color: appleIntelligenceProfile.supportsVision ? .green : .secondary
                    )
                }
                Text("SystemLanguageModel.default · \(appleIntelligenceProfile.generation.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Image analysis: \(appleImageAnalysisPathLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Apple Intelligence isn't downloaded or managed by Ohia — macOS owns it —
    /// so the row mirrors its system availability rather than a download state,
    /// reusing the same status-glyph idiom as the retrieval-model rows.
    private var appleIntelligenceResourceState: WorkerFleetResourceState {
        switch appleIntelligenceAvailability {
        case .available:
            return .full
        case .modelNotReady:
            return .loading
        case .unknown:
            return .waiting
        case .appleIntelligenceNotEnabled, .deviceNotEligible:
            return .unavailable
        }
    }

    private var appleIntelligenceStatusLabel: String {
        switch appleIntelligenceAvailability {
        case .available:                   return "On"
        case .appleIntelligenceNotEnabled: return "Off"
        case .modelNotReady:               return "Preparing"
        case .deviceNotEligible:           return "Unavailable"
        case .unknown:                     return "Unknown"
        }
    }

    private var appleIntelligenceAvailability: AppleIntelligenceAvailability.State {
        appleIntelligenceProfile.availability
    }

    private var appleImageAnalysisPathLabel: String {
        switch appleIntelligenceProfile.imageAnalysisTier {
        case .legacy:
            return "Apple Vision + OCR"
        case .multimodal:
            return "Multimodal + OCR"
        }
    }

    private func refreshAppleIntelligenceProfile() {
        appleIntelligenceProfile = AppleIntelligenceModelProfile.current()
    }

    /// Generation downloads live in Ohia's Application Support directory.
    /// Retrieval model caches are intentionally omitted here; inactive
    /// internal caches are cleaned automatically and exposed only to Developer.
    @ViewBuilder
    private var modelStorageFooter: some View {
        let url = modelStorageURL
        GroupBox(label: Text("Storage").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if let stats = storageStats {
                        storageStat(label: "Generation models", value: "\(stats.modelCount)")
                        Divider().frame(height: 24)
                        storageStat(
                            label: "Generation disk",
                            value: ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
                        )
                    } else {
                        Text("Measuring…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        revealModelStorage(url)
                    } label: {
                        Label("Reveal generation downloads", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal generation model downloads in Finder")
                }

                if let storageStatusMessage {
                    Text(storageStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(storageStatusIsError ? .red : .secondary)
                }

                if let models = storageStats?.models, models.isEmpty {
                    Divider()
                    Text("No generation model downloaded yet. Ohia starts downloading it on the onboarding Ready screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let models = storageStats?.models {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(models) { m in
                            downloadedModelRow(m)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: modelPendingDelete
        ) { model in
            Button(deleteDialogAction(for: model), role: .destructive) {
                deleteModel(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(deleteDialogMessage(for: model))
        }
    }

    @ViewBuilder
    private func downloadedModelRow(_ m: DownloadedModel) -> some View {
        let isSelected = selectedGenerationModel.modelId == m.id
        let isPending = pendingGenerationModel?.modelId == m.id
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayName(forModelID: m.id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !m.isComplete {
                        selectionBadge("Partial", color: .orange)
                    } else if isPending {
                        selectionBadge("Pending", color: .orange)
                    } else if isSelected {
                        selectionBadge("Active", color: .green)
                    }
                }
                Text("\(storageIdentifier(forModelID: m.id)) · \(ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                modelPendingDelete = m
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(isSelected
                  ? "Delete this active model. Ohia will need to download it again before using it."
                  : "Delete this cached model to reclaim disk space.")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func storageStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    // MARK: Delete-confirmation copy

    private var deleteDialogTitle: String {
        guard let m = modelPendingDelete else { return "Delete model" }
        return "Delete \(m.id)?"
    }

    private func deleteDialogAction(for m: DownloadedModel) -> String {
        selectedGenerationModel.modelId == m.id
            ? "Delete Active Model"
            : "Delete Model"
    }

    private func deleteDialogMessage(for m: DownloadedModel) -> String {
        let size = ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)
        if selectedGenerationModel.modelId == m.id {
            return """
            This active model (\(size)) will be removed from disk. Ohia \
            will keep it selected, but it must be re-downloaded before it \
            can be used again.
            """
        }
        return """
        This will remove the cached weights (\(size)) from disk. If you \
        switch to this model later it will re-download from Hugging Face.
        """
    }

    private func deleteModel(_ m: DownloadedModel) {
        modelPendingDelete = nil
        Task {
            await deleteModelAfterStoppingPreparation(m)
        }
    }

    private func deleteModelAfterStoppingPreparation(_ m: DownloadedModel) async {
        let activeModel = selectedGenerationModel
        let workerStatus = workerStatuses?.snapshot(for: .qwen)
        let liveWorkerModelID = workerStatus?.processState == .running
            ? workerStatus?.worker.model.flatMap { modelID(forDisplayName: $0.name) }
            : nil
        let shouldCancelPendingSwitch = activeModel.modelId != m.id
            && (pendingGenerationModel?.modelId == m.id || liveWorkerModelID == m.id)
        let shouldAwaitWorkerStop = liveWorkerModelID == m.id

        if shouldCancelPendingSwitch {
            let cancellationRequestedAt = Date.now
            ModelManager.setGenerationModelDownloadStopped(true, modelID: m.id)
            stoppedGenerationModelID = m.id
            modelLoader?.pauseDownload()
            if let workerSupervisor {
                workerSupervisor.requestGenerativeModelPreparationCancellation(m.id)
            } else {
                AppCommand.cancelGenerationModelPreparation(m.id)
            }
            storageStatusMessage = "Stopping \(displayName(forModelID: m.id)) before deletion."
            storageStatusIsError = false

            if shouldAwaitWorkerStop {
                guard await workerAcknowledgedPreparationStop(
                    modelID: m.id,
                    requestedAt: cancellationRequestedAt
                ) else {
                    storageStatusMessage = "Could not confirm that \(displayName(forModelID: m.id)) stopped. The model was not deleted."
                    storageStatusIsError = true
                    await refreshStorageStats()
                    return
                }
            }
        }

        do {
            if FileManager.default.fileExists(atPath: m.url.path) {
                try FileManager.default.removeItem(at: m.url)
            }
            if shouldCancelPendingSwitch {
                ModelManager.clearPendingGenerationModel()
                pendingGenerationModelID = ""
                pendingGenerationModeRaw = ""
                stoppedGenerationModelID = ""
                modelLoader?.prepareModelSwitch(to: activeModel)
                if let workerSupervisor {
                    workerSupervisor.requestGenerativeModelSelection(activeModel.modelId)
                } else {
                    AppCommand.selectGenerationModel(activeModel.modelId)
                }
            }
            storageStatusMessage = shouldCancelPendingSwitch
                ? "Deleted \(displayName(forModelID: m.id)) and cancelled the pending switch."
                : "Deleted \(displayName(forModelID: m.id))."
            storageStatusIsError = false
        } catch {
            storageStatusMessage = "Could not delete \(displayName(forModelID: m.id)): \(error.localizedDescription)"
            storageStatusIsError = true
        }
        await refreshStorageStats()
    }

    private func workerAcknowledgedPreparationStop(
        modelID targetModelID: String,
        requestedAt: Date
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if let status = workerStatuses?.snapshot(for: .qwen),
               status.processState == .running,
               status.worker.updatedAt >= requestedAt,
               status.worker.state == .paused,
               let workerModel = status.worker.model,
               modelID(forDisplayName: workerModel.name) == targetModelID {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private var modelStorageURL: URL {
        if let appServices {
            return appServices.generationModelDownloadBaseDirectory
                .appendingPathComponent("models", isDirectory: true)
        }
        return OhiaStorageRoot.required().publicModels
            .appendingPathComponent("models", isDirectory: true)
    }

    private func revealModelStorage(_ url: URL) {
        // Create the directory if it doesn't exist yet — NSWorkspace.selectFile
        // fails silently on missing paths. activateFileViewerSelecting opens
        // Finder and selects the path itself (not a parent/child).
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Walks the cache directory off the MainActor and returns (model count,
    /// total bytes). A "model" here is a top-level subdirectory under
    /// `.../huggingface/models/<org>/<repo>/` — we count distinct repo dirs.
    private func refreshStorageStats() async {
        let url = modelStorageURL
        let stats = await Task.detached(priority: .utility) {
            ModelStorageStats(
                models: computeDownloadedModels(root: url)
            )
        }.value
        await MainActor.run { self.storageStats = stats }
    }

    /// Pure, off-MainActor: enumerate the cache and build per-model entries.
    nonisolated private func computeDownloadedModels(root: URL) -> [DownloadedModel] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return []
        }

        var models: [DownloadedModel] = []

        // Two-level walk: root/<org>/<repo>/. Each <repo> is one model, id
        // reconstructed as "<org>/<repo>" to match the mlx-community IDs used
        // in the registry.
        let orgURLs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for orgURL in orgURLs where (try? orgURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repoURLs = (try? fm.contentsOfDirectory(at: orgURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for repoURL in repoURLs where (try? repoURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let id = "\(orgURL.lastPathComponent)/\(repoURL.lastPathComponent)"
                let size = directorySize(repoURL)
                let isComplete = GenerationModelStorage.isModelDownloaded(
                    downloadBaseDirectory: root.deletingLastPathComponent(),
                    modelID: id
                )
                models.append(
                    DownloadedModel(
                        id: id,
                        url: repoURL,
                        sizeBytes: size,
                        isComplete: isComplete
                    )
                )
            }
        }

        // Largest first — makes it visually obvious which model is worth
        // deleting to reclaim space.
        models.sort { $0.sizeBytes > $1.sizeBytes }
        return models
    }

    nonisolated private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    @ViewBuilder
    private func generationModeRow(
        mode: GenerationModelMode,
        model: ModelInfo,
        activeModelID: String?,
        pendingModelID: String?,
        loader: ModelLoadingService?,
        workerStatus: WorkerStatusPresentationSnapshot?
    ) -> some View {
        let isActive = activeModelID == model.modelId
        let isPending = pendingModelID == model.modelId
        let readiness = readinessForOption(
            model,
            isActive: isActive,
            isPending: isPending,
            loader: loader,
            workerStatus: workerStatus
        )

        HStack(spacing: 10) {
            selectionGlyph(isActive: isActive, isPending: isPending)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.displayName)
                        .font(.callout.weight(.medium))
                    if isPending {
                        selectionBadge("Pending", color: .orange)
                    } else if isActive {
                        selectionBadge("Active", color: .green)
                    }
                    readinessPill(readiness)
                }
                Text("\(model.displayName) · \(modelNotation(for: model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mode.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = readiness.progress {
                    DownloadActivityIndicator(progress: progress)
                        .accessibilityLabel("\(mode.displayName) model download progress")
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                    Text(downloadProgressText(for: readiness, model: model))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                downloadLifecycleAction(
                    model: model,
                    isActive: isActive,
                    isPending: isPending,
                    readiness: readiness,
                    mode: mode,
                    loader: loader
                )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func ultraRow(
        model: ModelInfo,
        activeModelID: String?,
        pendingModelID: String?,
        loader: ModelLoadingService?,
        workerStatus: WorkerStatusPresentationSnapshot?
    ) -> some View {
        let isActive = activeModelID == model.modelId
        let isPending = pendingModelID == model.modelId
        let readiness = readinessForOption(
            model,
            isActive: isActive,
            isPending: isPending,
            loader: loader,
            workerStatus: workerStatus
        )

        let rowTitle = ultraRowTitle(for: model)

        HStack(spacing: 10) {
            selectionGlyph(isActive: isActive, isPending: isPending)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rowTitle)
                        .font(.callout.weight(.medium))
                    if isPending {
                        selectionBadge("Pending", color: .orange)
                    } else if isActive {
                        selectionBadge("Active", color: .green)
                    }
                    readinessPill(readiness)
                }
                Text("\(model.displayName) · \(modelNotation(for: model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("High-memory opt-in tier for the most demanding summaries and Ask answers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = readiness.progress {
                    DownloadActivityIndicator(progress: progress)
                        .accessibilityLabel("\(rowTitle) model download progress")
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                    Text(downloadProgressText(for: readiness, model: model))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !isActive && !isPending {
                    // The Ultra tab targets only the primary (largest
                    // compatible) opt-in model, so every other tier needs its
                    // own selection affordance to stay reachable.
                    Button {
                        guard modelPendingDownload == nil else { return }
                        requestGenerationModelSelection(model, mode: .quality, loader: loader)
                    } label: {
                        Label("Use", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(modelPendingDownload != nil)
                    .help("Switch generation to \(model.displayName)")
                }
                downloadLifecycleAction(
                    model: model,
                    isActive: isActive,
                    isPending: isPending,
                    readiness: readiness,
                    mode: .quality,
                    loader: loader
                )
            }
        }
        .padding(.vertical, 2)
    }

    /// Per-tier row title: "Ultra · 35B A3B OptiQ", "Ultra · 122B A10B", so
    /// multiple opt-in rows stay distinguishable at a glance.
    private func ultraRowTitle(for model: ModelInfo) -> String {
        var name = model.displayName
        for prefix in ["Qwen3.6 ", "Qwen3.5 ", "Qwen3 "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if let range = name.range(of: " (") {
            name = String(name[..<range.lowerBound])
        }
        return name.isEmpty ? "Ultra" : "Ultra · \(name)"
    }

    /// Right-side download-lifecycle controls. Model *selection* happens only
    /// through the top tabs, so there is no "Use" affordance here — a button
    /// appears only to Stop an in-flight download or to Retry / Resume the
    /// active or pending model.
    @ViewBuilder
    private func downloadLifecycleAction(
        model: ModelInfo,
        isActive: Bool,
        isPending: Bool,
        readiness: GenerationReadiness,
        mode: GenerationModelMode?,
        loader: ModelLoadingService?
    ) -> some View {
        if isPending || isActive {
            switch readiness.kind {
            case .downloading:
                stopDownloadButton(
                    model: model,
                    loader: loader,
                    help: isPending
                        ? "Stop this pending model download"
                        : "Stop this active model download"
                )
            case .missing, .failed, .paused:
                Button {
                    selectAndPrepareGenerationModel(model, loader: loader, mode: mode)
                } label: {
                    Label(downloadActionTitle(for: readiness), systemImage: downloadActionIcon(for: readiness))
                }
                .buttonStyle(.borderless)
                .help(isPending
                      ? "Continue preparing the pending model"
                      : "Prepare the active model")
            default:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func stopDownloadButton(
        model: ModelInfo,
        loader: ModelLoadingService?,
        help: String
    ) -> some View {
        Button {
            stopGenerationModelDownload(model, loader: loader)
        } label: {
            Label("Stop Download", systemImage: "pause.circle")
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private func modelStatusRow(
        name: String,
        detail: String,
        state: WorkerFleetResourceState
    ) -> some View {
        HStack(spacing: 10) {
            workerResourceStateImage(state)
                .foregroundStyle(workerResourceStateColor(state))
            modelText(name: name, detail: detail)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func retrievalModelRow(_ model: RetrievalModelPresentation) -> some View {
        HStack(spacing: 10) {
            workerResourceStateImage(model.state)
                .foregroundStyle(workerResourceStateColor(model.state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.callout.weight(.medium))
                    selectionBadge(model.status, color: workerResourceStateColor(model.state))
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func modelText(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectionBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    /// Leading state glyph. Only the active (checkmark) and pending (clock)
    /// rows carry a mark — unselected rows render an invisible placeholder so
    /// model names stay aligned without an empty-circle affordance.
    @ViewBuilder
    private func selectionGlyph(isActive: Bool, isPending: Bool) -> some View {
        if isActive {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if isPending {
            Image(systemName: "clock")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .hidden()
        }
    }

    @ViewBuilder
    private func readinessPill(_ readiness: GenerationReadiness) -> some View {
        Text(readiness.label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(generationReadinessColor(readiness.kind).opacity(0.12))
            .foregroundStyle(generationReadinessColor(readiness.kind))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func hardwareStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var recommendationPair: ModelRecommendationPair {
        ModelManager.recommendedPair(for: hardware)
    }

    private var selectedGenerationMode: GenerationModelMode {
        ModelManager.selectedGenerationModelMode()
    }

    private var pendingGenerationMode: GenerationModelMode? {
        ModelManager.pendingGenerationModelMode()
            ?? GenerationModelMode(rawValue: pendingGenerationModeRaw)
    }

    private var retrievalModelPresentations: [RetrievalModelPresentation] {
        [
            RetrievalModelPresentation(
                id: BGE3ModelDownloader.tokenizerRepoID,
                name: "BGE-M3",
                detail: BGE3ModelDownloader.tokenizerRepoID,
                status: bge3StatusLabel,
                state: bge3ResourceState
            ),
            RetrievalModelPresentation(
                id: CrossEncoderDownloader.tokenizerRepoID,
                name: "BGE Reranker v2 M3",
                detail: CrossEncoderDownloader.tokenizerRepoID,
                status: crossEncoderStatusLabel,
                state: crossEncoderResourceState
            ),
        ]
    }

    private var bge3ResourceState: WorkerFleetResourceState {
        guard let appServices else { return .waiting }
        switch appServices.bge3RuntimeState {
        case .ready:
            return .full
        case .downloading, .loading:
            return .loading
        case .failed:
            return .failed
        case .unavailable:
            return appServices.bge3Downloader.isAvailable ? .full : .unavailable
        }
    }

    private var bge3StatusLabel: String {
        guard let appServices else { return "Waiting" }
        switch appServices.bge3RuntimeState {
        case .ready:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .loading:
            return "Loading"
        case .failed:
            return "Failed"
        case .unavailable:
            return appServices.bge3Downloader.isAvailable ? "Cached" : "Missing"
        }
    }

    private var crossEncoderResourceState: WorkerFleetResourceState {
        guard let appServices else { return .waiting }
        if appServices.crossEncoderReranker != nil {
            return .full
        }
        return appServices.crossEncoderDownloader.isAvailable ? .full : .unavailable
    }

    private var crossEncoderStatusLabel: String {
        guard let appServices else { return "Waiting" }
        if appServices.crossEncoderReranker != nil {
            return "Ready"
        }
        return appServices.crossEncoderDownloader.isAvailable ? "Cached" : "Missing"
    }

    /// Tab options: the two recommended tiers, plus an "Ultra" tab only when a
    /// memory-compatible opt-in model exists for this Mac.
    private var generationSegments: [GenerationSegment] {
        var segments: [GenerationSegment] = GenerationModelMode.allCases.map(GenerationSegment.mode)
        if !recommendationPair.optInModels.isEmpty {
            segments.append(.ultra)
        }
        return segments
    }

    private func segmentTitle(_ segment: GenerationSegment) -> String {
        switch segment {
        case .mode(let mode):
            return mode.displayName
        case .ultra:
            return "Ultra"
        }
    }

    private var optInModelIDs: Set<String> {
        Set(ModelManager.optInModels.map(\.modelId))
    }

    /// Which tab is lit. Driven by the effective model id (pending wins over
    /// active) so selecting the opt-in model lights the "Ultra" tab even
    /// though its persisted mode falls back to `.quality`.
    ///
    /// The `.ultra` tab is only offered when this Mac has a memory-compatible
    /// opt-in model, so we only resolve to it under the same condition — a
    /// migrated/cross-machine opt-in selection on a low-memory Mac falls back
    /// to a mode tab rather than lighting a tab that isn't shown.
    private func currentSegment(loader: ModelLoadingService?) -> GenerationSegment {
        let effectiveID = loader?.pendingModel?.modelId
            ?? pendingGenerationModel?.modelId
            ?? selectedGenerationModel.modelId
        if !recommendationPair.optInModels.isEmpty, optInModelIDs.contains(effectiveID) {
            return .ultra
        }
        if let mode = recommendationPair.mode(for: effectiveID) {
            return .mode(mode)
        }
        return .mode(pendingGenerationMode ?? selectedGenerationMode)
    }

    private func segmentSelectionBinding(loader: ModelLoadingService?) -> Binding<GenerationSegment> {
        Binding(
            get: { currentSegment(loader: loader) },
            set: { segment in
                // A confirmation is already pending — ignore further taps until
                // the dialog resolves (the picker is modal behind it anyway).
                guard modelPendingDownload == nil else { return }
                guard segment != currentSegment(loader: loader) else { return }
                switch segment {
                case .mode(let mode):
                    let model = recommendationPair.model(for: mode)
                    requestGenerationModelSelection(model, mode: mode, loader: loader)
                case .ultra:
                    // The single "Ultra" tab targets the primary (first)
                    // compatible opt-in model — the largest tier this Mac can
                    // hold. The remaining tiers render below with their own
                    // "Use" affordance in `ultraRow`.
                    guard let model = recommendationPair.optInModels.first else { return }
                    requestGenerationModelSelection(model, mode: .quality, loader: loader)
                }
            }
        )
    }

    /// Gate for tab-driven model switches. If the target model is already on
    /// disk, switching only re-activates it (no fetch) so we proceed silently.
    /// Otherwise we park the choice in `modelPendingDownload` and let the
    /// confirmation dialog decide — the tab does not move until the user
    /// confirms, because `currentSegment` still resolves to the old model.
    private func requestGenerationModelSelection(
        _ model: ModelInfo,
        mode: GenerationModelMode?,
        loader: ModelLoadingService?
    ) {
        if downloadedGenerationModelIDs.contains(model.modelId) {
            selectAndPrepareGenerationModel(model, loader: loader, mode: mode)
        } else {
            modelPendingDownload = PendingDownloadConfirmation(model: model, mode: mode)
        }
    }

    private var downloadConfirmTitle: String {
        guard let pending = modelPendingDownload else { return "Download model" }
        return "Download \(pending.model.displayName)?"
    }

    private func downloadConfirmMessage(for model: ModelInfo) -> String {
        String(
            format: "This downloads about %.1f GB. Your current model stays active until the new one finishes loading.",
            model.estimatedDownloadGB
        )
    }

    private func readinessForOption(
        _ model: ModelInfo,
        isActive: Bool,
        isPending: Bool,
        loader: ModelLoadingService?,
        workerStatus: WorkerStatusPresentationSnapshot?
    ) -> GenerationReadiness {
        if isPending {
            let readiness: GenerationReadiness
            if let loader {
                readiness = generationReadiness(loader.state)
            } else {
                readiness = generationReadiness(for: model, workerStatus: workerStatus)
            }
            return pendingSwitchReadiness(from: readiness)
        }

        if isActive {
            if pendingGenerationModel != nil,
               downloadedGenerationModelIDs.contains(model.modelId) {
                return GenerationReadiness(
                    kind: .ready,
                    label: "Ready",
                    detail: "Current active model remains available while the pending model is prepared.",
                    progress: nil
                )
            }
            if let loader {
                return generationReadiness(loader.state)
            }
            return generationReadiness(for: model, workerStatus: workerStatus)
        }

        if downloadedGenerationModelIDs.contains(model.modelId) {
            return GenerationReadiness(
                kind: .downloaded,
                label: "Downloaded",
                detail: "Downloaded locally.",
                progress: nil
            )
        }

        return GenerationReadiness(
            kind: .missing,
            label: "Not downloaded",
            detail: nil,
            progress: nil
        )
    }

    private func pendingSwitchReadiness(
        from readiness: GenerationReadiness
    ) -> GenerationReadiness {
        guard readiness.kind == .downloaded else { return readiness }
        return GenerationReadiness(
            kind: .waiting,
            label: "Waiting to switch",
            detail: "Download complete. The current request will finish before Ohia loads this model.",
            progress: nil
        )
    }

    private func modelNotation(for model: ModelInfo) -> String {
        String(format: "%.1f GB download · %.0f GB memory tier", model.estimatedDownloadGB, model.requiredMemoryGB)
    }

    private func downloadActionTitle(for readiness: GenerationReadiness) -> String {
        switch readiness.kind {
        case .failed:
            return "Retry Download"
        case .paused:
            return "Resume Download"
        case .downloaded, .ready:
            return "Reload"
        default:
            return "Download"
        }
    }

    private func downloadActionIcon(for readiness: GenerationReadiness) -> String {
        switch readiness.kind {
        case .failed:
            return "arrow.clockwise"
        case .paused:
            return "play.circle"
        case .downloaded, .ready:
            return "arrow.triangle.2.circlepath"
        default:
            return "arrow.down.circle"
        }
    }

    private var selectedGenerationModel: ModelInfo {
        let fallback = recommendationPair.model(for: selectedGenerationMode)
        let storedModelID = ModelManager.selectedGenerationModelID()
        let modelID = storedModelID ?? (selectedGenerationModelID.isEmpty ? fallback.modelId : selectedGenerationModelID)
        guard let model = ModelManager.allModels.first(where: { $0.modelId == modelID }),
              ModelManager.compatibleModels(memoryGB: hardware.memoryGB).contains(where: { $0.modelId == model.modelId })
        else {
            return fallback
        }
        return model
    }

    private var pendingGenerationModel: ModelInfo? {
        guard let modelID = ModelManager.pendingGenerationModelID(),
              let model = ModelManager.allModels.first(where: { $0.modelId == modelID }),
              ModelManager.compatibleModels(memoryGB: hardware.memoryGB).contains(where: { $0.modelId == model.modelId })
        else {
            return nil
        }
        return model
    }

    private var downloadedGenerationModelIDs: Set<String> {
        Set(storageStats?.models.filter(\.isComplete).map(\.id) ?? [])
    }

    private func selectAndPrepareGenerationModel(
        _ model: ModelInfo,
        loader: ModelLoadingService?,
        mode: GenerationModelMode? = nil
    ) {
        let resolvedMode = mode ?? recommendationPair.mode(for: model.modelId)
        let isActiveSelection = selectedGenerationModel.modelId == model.modelId
        if isActiveSelection {
            ModelManager.clearPendingGenerationModel()
            pendingGenerationModelID = ""
            pendingGenerationModeRaw = ""
            stoppedGenerationModelID = ""
            if let resolvedMode {
                ModelManager.setSelectedGenerationModelMode(resolvedMode)
                selectedGenerationModeRaw = resolvedMode.rawValue
            }
            ModelManager.setSelectedGenerationModelID(model.modelId)
            selectedGenerationModelID = model.modelId
            loader?.setModel(model)
        } else {
            ModelManager.setPendingGenerationModelID(model.modelId, mode: resolvedMode)
            pendingGenerationModelID = model.modelId
            pendingGenerationModeRaw = resolvedMode?.rawValue ?? ""
            stoppedGenerationModelID = ""
            loader?.prepareModelSwitch(to: model)
        }

        if let workerSupervisor {
            workerSupervisor.requestGenerativeModelSelection(model.modelId)
        } else {
            AppCommand.selectGenerationModel(model.modelId)
        }

        storageStatusMessage = downloadedGenerationModelIDs.contains(model.modelId)
            ? "\(isActiveSelection ? "Selected" : "Queued") \(model.displayName)."
            : "\(isActiveSelection ? "Selected" : "Queued") \(model.displayName). Download starting."
        storageStatusIsError = false
        Task { await refreshStorageStats() }
    }

    private func stopGenerationModelDownload(
        _ model: ModelInfo,
        loader: ModelLoadingService?
    ) {
        ModelManager.setGenerationModelDownloadStopped(true, modelID: model.modelId)
        stoppedGenerationModelID = model.modelId
        loader?.pauseDownload()

        if let workerSupervisor {
            workerSupervisor.requestGenerativeModelPreparationCancellation(model.modelId)
        } else {
            AppCommand.cancelGenerationModelPreparation(model.modelId)
        }

        storageStatusMessage = "Stopped \(model.displayName). Resume Download to continue."
        storageStatusIsError = false
        Task { await refreshStorageStats() }
    }

    private var storageRefreshKey: String {
        let pendingComponent = pendingGenerationModel?.modelId ?? "none"
        if let modelState = workerStatuses?.snapshot(for: .qwen).worker.model?.state {
            return "pending-\(pendingComponent)-stopped-\(stoppedGenerationModelID)-worker-\(storageStateKey(modelState))"
        }
        if let loaderState = modelLoader?.state {
            return "pending-\(pendingComponent)-stopped-\(stoppedGenerationModelID)-loader-\(storageStateKey(loaderState))"
        }
        return "pending-\(pendingComponent)-stopped-\(stoppedGenerationModelID)-none"
    }

    private func generationReadiness(_ state: ModelLoadState) -> GenerationReadiness {
        switch state {
        case .idle:
            return GenerationReadiness(
                kind: .missing,
                label: "Missing",
                detail: "Ohia starts downloading this model on the onboarding Ready screen.",
                progress: nil
            )
        case .downloading(let fraction):
            let progress = clampedProgress(fraction)
            return GenerationReadiness(
                kind: .downloading,
                label: "Downloading",
                detail: "Background download in progress.",
                progress: progress
            )
        case .downloaded:
            return GenerationReadiness(
                kind: .downloaded,
                label: "Downloaded",
                detail: "Downloaded locally; Ohia will load it for Ask and summaries.",
                progress: nil
            )
        case .loading:
            return GenerationReadiness(
                kind: .loading,
                label: "Loading",
                detail: "Loading weights into memory.",
                progress: nil
            )
        case .paused(let message):
            return GenerationReadiness(
                kind: .paused,
                label: "Stopped",
                detail: message ?? "Download stopped. Select Resume Download to continue.",
                progress: nil
            )
        case .ready:
            return GenerationReadiness(
                kind: .ready,
                label: "Ready",
                detail: "Available for summaries, drafting, and training.",
                progress: nil
            )
        case .failed(let message):
            return GenerationReadiness(
                kind: .failed,
                label: "Failed",
                detail: message,
                progress: nil
            )
        }
    }

    private func generationReadiness(
        for model: ModelInfo,
        workerStatus: WorkerStatusPresentationSnapshot?
    ) -> GenerationReadiness {
        if downloadedGenerationModelIDs.contains(model.modelId) {
            return GenerationReadiness(
                kind: .downloaded,
                label: "Downloaded",
                detail: "Selected and downloaded locally; Ohia will load it for Ask and summaries.",
                progress: nil
            )
        }

        if ModelManager.isGenerationModelDownloadStopped(for: model.modelId) {
            return GenerationReadiness(
                kind: .paused,
                label: "Stopped",
                detail: "Download stopped. Select Resume Download to continue.",
                progress: nil
            )
        }

        if let workerStatus,
           workerStatus.processState == .running,
           let workerModel = workerStatus.worker.model,
           modelID(forDisplayName: workerModel.name) == model.modelId {
            return generationReadiness(workerStatus: workerStatus, recommended: model)
        }

        if let workerStatus, workerStatus.processState == .running {
            return GenerationReadiness(
                kind: .starting,
                label: "Starting download",
                detail: "The download request was sent. The current model remains active.",
                progress: nil
            )
        }

        return GenerationReadiness(
            kind: .missing,
            label: "Missing",
            detail: "Select Download to fetch this model into Ohia's Application Support folder.",
            progress: nil
        )
    }

    private func generationReadiness(
        workerStatus: WorkerStatusPresentationSnapshot?,
        recommended: ModelInfo
    ) -> GenerationReadiness {
        guard let workerStatus else {
            return GenerationReadiness(
                kind: .missing,
                label: "Missing",
                detail: "Ohia starts downloading this model on the onboarding Ready screen.",
                progress: nil
            )
        }

        if let model = workerStatus.worker.model {
            switch model.state {
            case .unavailable:
                return GenerationReadiness(
                    kind: .missing,
                    label: "Missing",
                    detail: model.message ?? "Ohia starts downloading this model on the onboarding Ready screen.",
                    progress: nil
                )
            case .downloading(let fraction):
                let progress = model.download?.fraction ?? clampedProgress(fraction)
                return GenerationReadiness(
                    kind: .downloading,
                    label: "Downloading",
                    detail: generationDownloadDetail(
                        from: model.download,
                        fallback: model.message ?? "Background download in progress."
                    ),
                    progress: progress
                )
            case .downloaded:
                return GenerationReadiness(
                    kind: .downloaded,
                    label: "Downloaded",
                    detail: model.message ?? "Downloaded locally; waiting to load.",
                    progress: nil
                )
            case .loading:
                return GenerationReadiness(
                    kind: .loading,
                    label: "Loading",
                    detail: model.message ?? "Loading weights into memory.",
                    progress: nil
                )
            case .paused(let message):
                return GenerationReadiness(
                    kind: .paused,
                    label: "Stopped",
                    detail: model.message ?? message ?? "Download stopped. Select Resume Download to continue.",
                    progress: nil
                )
            case .ready:
                return GenerationReadiness(
                    kind: .ready,
                    label: "Ready",
                    detail: "Available for summaries, drafting, and training.",
                    progress: nil
                )
            case .failed(let message):
                return GenerationReadiness(
                    kind: .failed,
                    label: "Failed",
                    detail: model.message ?? message,
                    progress: nil
                )
            }
        }

        switch workerStatus.resourceState {
        case .full:
            return GenerationReadiness(
                kind: .ready,
                label: "Ready",
                detail: "Available for summaries, drafting, and training.",
                progress: nil
            )
        case .loading:
            return GenerationReadiness(
                kind: .loading,
                label: "Loading",
                detail: workerStatus.detail ?? "Preparing \(recommended.displayName).",
                progress: nil
            )
        case .waiting:
            return GenerationReadiness(
                kind: .waiting,
                label: "Waiting",
                detail: workerStatus.detail ?? "Waiting to download or load the generation model.",
                progress: nil
            )
        case .paused, .throttled:
            return GenerationReadiness(
                kind: .paused,
                label: workerStatus.resourceState.displayLabel.capitalized,
                detail: workerStatus.detail,
                progress: nil
            )
        case .unavailable:
            return GenerationReadiness(
                kind: .missing,
                label: "Missing",
                detail: "Ohia starts downloading this model on the onboarding Ready screen.",
                progress: nil
            )
        case .failed:
            return GenerationReadiness(
                kind: .failed,
                label: "Failed",
                detail: workerStatus.detail,
                progress: nil
            )
        }
    }

    private func generationDownloadDetail(
        from snapshot: WorkerModelDownloadSnapshot?,
        fallback: String?
    ) -> String? {
        guard let snapshot else { return fallback }
        let downloaded = ByteCountFormatter.string(
            fromByteCount: snapshot.downloadedBytes,
            countStyle: .file
        )
        if let totalBytes = snapshot.totalBytes {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            if let fraction = snapshot.fraction {
                let percent = Int((fraction * 100).rounded())
                return "\(downloaded) of \(total) downloaded · \(percent)%"
            }
            return "\(downloaded) of \(total) downloaded"
        }
        guard snapshot.downloadedBytes > 0 else { return fallback }
        return "\(downloaded) downloaded"
    }

    private func downloadProgressText(
        for readiness: GenerationReadiness,
        model: ModelInfo
    ) -> String {
        if let detail = readiness.detail,
           detail.contains(" downloaded"),
           detail.contains("%") {
            return detail
        }

        let progress = readiness.progress.map(clampedProgress) ?? 0
        let totalBytes = Int64((model.estimatedDownloadGB * 1_000_000_000).rounded())
        let downloadedBytes = Int64((Double(totalBytes) * progress).rounded())
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let percent = Int((progress * 100).rounded())
        return "\(downloaded) of about \(total) downloaded · \(percent)%"
    }

    private func generationReadinessColor(_ kind: GenerationReadinessKind) -> Color {
        switch kind {
        case .ready, .downloaded:
            return .green
        case .starting, .downloading, .loading, .waiting:
            return .orange
        case .missing, .paused:
            return .secondary
        case .failed:
            return .red
        }
    }

    private func displayName(forModelID modelID: String) -> String {
        ModelManager.allModels.first { $0.modelId == modelID }?.displayName
            ?? fallbackDisplayName(forModelID: modelID)
    }

    private func fallbackDisplayName(forModelID modelID: String) -> String {
        let repoName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        if repoName.contains("OptiQ") {
            return repoName
                .replacingOccurrences(of: "-OptiQ-", with: " OptiQ ")
                .replacingOccurrences(of: "-9B", with: " 9B")
                .replacingOccurrences(of: "-27B", with: " 27B")
                .replacingOccurrences(of: "-4bit", with: " (4-bit)")
                .replacingOccurrences(of: "4bit", with: "(4-bit)")
        }
        return repoName
    }

    private func storageIdentifier(forModelID modelID: String) -> String {
        let repoName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        if repoName.contains("OptiQ") {
            return repoName
        }
        return modelID
    }

    private func modelID(forDisplayName displayName: String) -> String? {
        ModelManager.allModels.first { $0.displayName == displayName }?.modelId
    }

    private func clampedProgress(_ fraction: Double) -> Double {
        min(1, max(0, fraction))
    }

    private func storageStateKey(_ state: WorkerModelLoadState) -> String {
        switch state {
        case .unavailable:
            return "unavailable"
        case .downloading(let fraction):
            return "downloading-\(fraction)"
        case .downloaded:
            return "downloaded"
        case .loading:
            return "loading"
        case .paused:
            return "paused"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    private func storageStateKey(_ state: ModelLoadState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .downloading(let fraction):
            return "downloading-\(fraction)"
        case .downloaded:
            return "downloaded"
        case .loading:
            return "loading"
        case .paused:
            return "paused"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 110, alignment: .leading)
            Text(value)
        }
        .font(.callout)
    }

    private func workerResourceStateColor(_ state: WorkerFleetResourceState) -> Color {
        switch state {
        case .full:
            return .green
        case .loading, .waiting:
            return .orange
        case .paused, .throttled:
            return .secondary
        case .unavailable, .failed:
            return .red
        }
    }

    private func workerResourceStateImage(_ state: WorkerFleetResourceState) -> Image {
        switch state {
        case .full:
            return Image(systemName: "checkmark.circle.fill")
        case .failed, .unavailable:
            return Image(systemName: "exclamationmark.circle.fill")
        case .loading, .paused, .throttled, .waiting:
            return Image(systemName: "clock.fill")
        }
    }
}

private struct DownloadActivityIndicator: View {
    let progress: Double

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let fillWidth = max(CGFloat(12), width * CGFloat(clampedProgress))
                    let shimmerPhase = CGFloat(phase)
                    Capsule()
                        .fill(Color.yellow.opacity(0.9))
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            Color.white.opacity(0.65),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 34)
                                .offset(x: max(CGFloat(-34), (fillWidth + 34) * shimmerPhase - 34))
                                .blendMode(.screen)
                        }
                        .clipShape(Capsule())
                }

                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.yellow.opacity(dotOpacity(index: index, phase: phase)))
                            .frame(width: 3, height: 3)
                    }
                }
                .padding(.leading, 8)
            }
            .frame(width: 132, height: 8)
        }
        .frame(width: 132, height: 8)
    }

    private func dotOpacity(index: Int, phase: Double) -> Double {
        let shifted = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
        return shifted < 0.35 ? 1 : 0.35
    }
}
