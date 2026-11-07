// Ohia/Settings/Signatures/SignatureTierCardsView.swift
// Stage 2 of the studio: one large design box with a tier chip selector
// above it — the chosen tier's rendered preview, Regenerate, and a free-text
// revision prompt. All three tiers keep generating in the background; the
// chips switch which one the box shows.

import OhiaCore
import OhiaML
import SwiftUI

enum SignatureDesignProgressPresentation: Equatable {
    case designing
    case regenerating
    case reworking

    static func resolve(
        isOpeningPass: Bool,
        requestedOperation: Self?,
        isModelDesigned: Bool
    ) -> Self {
        if isOpeningPass { return .designing }
        if let requestedOperation { return requestedOperation }
        return isModelDesigned ? .reworking : .designing
    }

    var title: String {
        switch self {
        case .designing: "Designing your signature"
        case .regenerating: "Regenerating your signature"
        case .reworking: "Reworking this design"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .designing: "Designing signature"
        case .regenerating: "Regenerating signature"
        case .reworking: "Reworking signature design"
        }
    }
}

struct SignatureTierCardsStage: View {
    @Bindable var model: SignatureStudioModel
    @State private var selectedTier: SignatureTier = .standard
    @State private var editedContent: [SignatureTier: NSAttributedString] = [:]
    @State private var loadedCandidateFingerprints: [SignatureTier: String] = [:]
    private let assetStore = SignatureAssetStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let status = model.generationStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                tierPicker

                if let card = model.cards.first(where: { $0.tier == selectedTier }) {
                    SignatureTierCardView(
                        model: model,
                        card: card,
                        editedContent: contentBinding(for: card)
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { loadCandidateIfNeeded(card) }
                        .onChange(of: candidateFingerprint(card)) {
                            loadCandidateIfNeeded(card)
                        }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            HStack {
                Button { model.backToFields() } label: {
                    Label("Back to Details", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .frame(width: 38, height: 38)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    OhiaColors.chipActiveForeground,
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back to Details")
                .accessibilityLabel("Back to Details")
                Spacer()
            }
            .padding(12)
        }
    }

    private var tierPicker: some View {
        HStack(spacing: 6) {
            ForEach(SignatureTier.allCases, id: \.self) { tier in
                Button {
                    selectedTier = tier
                } label: {
                    FilterChipLabel(
                        text: tier.displayName,
                        isOn: tier == selectedTier,
                        size: 14,
                        height: 32,
                        horizontalPadding: 14
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tier.displayName)
                .accessibilityAddTraits(tier == selectedTier ? [.isSelected] : [])
            }
        }
        .accessibilityLabel("Detail tier")
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func contentBinding(
        for card: SignatureStudioModel.TierCard
    ) -> Binding<NSAttributedString> {
        Binding(
            get: { editedContent[card.tier] ?? NSAttributedString(string: "") },
            set: { editedContent[card.tier] = $0 }
        )
    }

    /// One observer covers every model-result change. Manual editor changes do
    /// not touch this fingerprint, so they persist while switching tiers; a
    /// regenerate or revision landing replaces only that tier's editable copy.
    private func candidateFingerprint(_ card: SignatureStudioModel.TierCard) -> String {
        [
            card.candidate.html ?? "",
            card.candidate.plainText,
            card.isModelDesigned ? "model" : "built-in",
            String(card.candidateRevision),
            model.isGeneratingPass ? "opening-pass" : "ready"
        ].joined(separator: "\u{1F}")
    }

    private func loadCandidateIfNeeded(_ card: SignatureStudioModel.TierCard) {
        guard !card.isBusy, !model.isGeneratingPass else { return }
        let fingerprint = candidateFingerprint(card)
        guard loadedCandidateFingerprints[card.tier] != fingerprint else { return }
        editedContent[card.tier] = attributedContent(for: card)
        loadedCandidateFingerprints[card.tier] = fingerprint
    }

    private func attributedContent(
        for card: SignatureStudioModel.TierCard
    ) -> NSAttributedString {
        if let html = card.candidate.html {
            return SignatureHTMLImageCoding.attributedContent(
                html: html,
                ownerID: model.sessionID,
                assets: model.imageAsset.map { [$0] } ?? [],
                store: assetStore
            )
        }
        return NSAttributedString(string: card.candidate.plainText)
    }
}

private struct SignatureTierCardView: View {
    @Bindable var model: SignatureStudioModel
    let card: SignatureStudioModel.TierCard
    @Binding var editedContent: NSAttributedString
    @Environment(\.colorScheme) private var colorScheme
    @State private var requestedProgressByTier: [
        SignatureTier: SignatureDesignProgressPresentation
    ] = [:]
    private let assetStore = SignatureAssetStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The tier chip selector above already names the active tier.
            // Only surface the exceptional fallback state here; normal
            // model-designed cards need no repeated title or instruction.
            if !card.isBusy && !model.isGeneratingPass && !card.isModelDesigned {
                Text("Built-in design")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if card.isBusy || model.isGeneratingPass {
                progressBanner
            }

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    colorScheme == .dark
                        ? OhiaColors.settingsCard
                        : OhiaColors.surface(0.04)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            card.isBusy || model.isGeneratingPass
                                ? OhiaColors.ohiaYellow
                                : OhiaColors.glassBorder,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let error = card.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    regenerate()
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.emblem)
                .font(OhiaTypography.button)
                .disabled(!model.isModelAvailable || card.isBusy || model.isGeneratingPass)
                Spacer()
                Button {
                    model.choose(tier: card.tier)
                    model.editorContent = editedContent
                    model.scheduleEditingPreviewRefresh(debounce: false)
                } label: {
                    Label("Use This Design", systemImage: "checkmark")
                }
                .buttonStyle(.emblem)
                .font(OhiaTypography.button)
                .disabled(card.isBusy || model.isGeneratingPass)
            }

            HStack(spacing: 6) {
                TextField(
                    "Describe how to revise this design",
                    text: revisionBinding
                )
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    colorScheme == .dark
                        ? OhiaColors.settingsCard
                        : OhiaColors.surface(0.05)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onSubmit {
                    revise()
                }
                .disabled(!model.isModelAvailable || card.isBusy || model.isGeneratingPass)

                Button {
                    revise()
                } label: {
                    Label("Apply", systemImage: "paperplane")
                }
                .buttonStyle(.emblem)
                .font(OhiaTypography.button)
                .disabled(
                    !model.isModelAvailable || card.isBusy || model.isGeneratingPass
                        || card.revisionText.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(12)
        .onChange(of: card.isBusy) { _, isBusy in
            if !isBusy {
                requestedProgressByTier.removeValue(forKey: card.tier)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if card.isBusy || model.isGeneratingPass {
            AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 520, slotHeight: 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        } else if card.candidate.html != nil {
            ComposerRichTextEditor(
                content: $editedContent,
                format: .constant(.richText),
                isEnabled: true,
                importEditorImage: importSignatureImage,
                showsFormatPicker: false,
                placesUtilityActionsInHeader: true
            )
            .padding(10)
        } else {
            TextEditor(text: Binding(
                get: { editedContent.string },
                set: { editedContent = NSAttributedString(string: $0) }
            ))
            .font(.callout)
            .foregroundStyle(OhiaColors.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(10)
        }
    }

    private var progressBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(progressPresentation.title)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressPresentation.accessibilityLabel)
    }

    private var progressPresentation: SignatureDesignProgressPresentation {
        .resolve(
            isOpeningPass: model.isGeneratingPass,
            requestedOperation: requestedProgressByTier[card.tier],
            isModelDesigned: card.isModelDesigned
        )
    }

    private func regenerate() {
        requestedProgressByTier.removeValue(forKey: card.tier)
        model.regenerate(tier: card.tier)
        if model.cards.first(where: { $0.tier == card.tier })?.isBusy == true {
            requestedProgressByTier[card.tier] = .regenerating
        }
    }

    private func revise() {
        requestedProgressByTier.removeValue(forKey: card.tier)
        model.revise(tier: card.tier, currentContent: editedContent)
        if model.cards.first(where: { $0.tier == card.tier })?.isBusy == true {
            requestedProgressByTier[card.tier] = .reworking
        }
    }

    private var revisionBinding: Binding<String> {
        Binding(
            get: {
                model.cards.first(where: { $0.tier == card.tier })?.revisionText ?? ""
            },
            set: { newValue in
                model.setRevisionText(newValue, for: card.tier)
            }
        )
    }

    private func importSignatureImage(at url: URL) async throws -> ComposerEditorImageImport {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        try Task.checkCancellation()
        let asset = try await model.importImageForEditing(
            data: data,
            fileName: url.lastPathComponent
        )
        let token = SignatureImageToken.url(
            ownerID: model.sessionID,
            assetID: asset.id
        )
        let content = SignatureHTMLImageCoding.attributedContent(
            html: "<img src=\"\(token)\">",
            ownerID: model.sessionID,
            assets: [asset],
            store: assetStore
        )
        return ComposerEditorImageImport(content: content) {
            model.discardEditorImage(asset)
        }
    }
}
