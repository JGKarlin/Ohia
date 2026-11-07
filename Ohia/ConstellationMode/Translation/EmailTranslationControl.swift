import SwiftUI

/// The Translate affordance shown next to an email body. It mirrors the
/// "Load images" emblem chip before generation, swaps to the summarization
/// loading animation's vocabulary while generating, and resolves to either a
/// two-language toggle (pane lenses) or a Hide/Show emblem (two-column reading
/// surfaces) once a translation exists.
struct EmailTranslationControl: View {
    @Bindable var model: EmailTranslationModel
    let mode: Mode
    var labelVisibility: LabelVisibility = .textAndIcon
    /// Called when the user asks to (re)generate; the host performs the actual
    /// service call so the model stays free of the environment.
    let onTranslate: () -> Void

    enum Mode {
        /// Locked-overlay pane lenses: a two-state Original / Translation toggle.
        case pane
        /// Front Page reader and Timeline viewport: a Hide / Show translation
        /// emblem that drives the second column.
        case columns
    }

    enum LabelVisibility {
        case textAndIcon
        case iconOnly
    }

    var body: some View {
        switch model.phase {
        case .idle:
            if model.canOffer { triggerButton(label: "Translate") }
        case .failed(let message):
            if model.canOffer {
                triggerButton(label: "Translate")
                    .help("Translation failed: \(message). Click to retry.")
            }
        case .needsDownload(let message):
            if model.canOffer { downloadButton(message: message) }
        case .preparingLanguages:
            preparingChip
        case .translating:
            translatingChip
        case .translated:
            switch mode {
            case .pane: paneToggle
            case .columns: hideShowButton
            }
        }
    }

    // MARK: - Trigger

    private func triggerButton(label: String) -> some View {
        Button(action: onTranslate) {
            HStack(spacing: 4) {
                Image(systemName: "translate")
                if labelVisibility == .textAndIcon {
                    Text(label)
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.emblem)
        .fixedSize(horizontal: true, vertical: false)
        .help("Translate into \(model.targetLanguageAutonym)")
        .accessibilityLabel("Translate this message into \(model.targetLanguageAutonym)")
        .transition(.opacity)
    }

    // MARK: - Language download

    private func downloadButton(message: String) -> some View {
        Button(action: { model.requestLanguageDownload() }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                if labelVisibility == .textAndIcon {
                    Text("Download \(model.targetLanguageAutonym)")
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.emblem)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(message.prefix(1).uppercased() + message.dropFirst()) Download the on-device languages to translate into \(model.targetLanguageAutonym).")
        .accessibilityLabel("Download translation languages for \(model.targetLanguageAutonym)")
        .transition(.opacity)
    }

    private var preparingChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle")
            if labelVisibility == .textAndIcon {
                Text("Preparing languages")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(OhiaColors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OhiaColors.buttonBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.ohiaYellow.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel("Preparing translation languages")
        .fixedSize(horizontal: true, vertical: false)
        .transition(.opacity)
    }

    // MARK: - In-flight

    private var translatingChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "translate")
            if labelVisibility == .textAndIcon {
                Text("Translating")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(OhiaColors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OhiaColors.buttonBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.ohiaYellow.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel("Translating")
        .fixedSize(horizontal: true, vertical: false)
        .transition(.opacity)
    }

    // MARK: - Pane toggle

    @ViewBuilder
    private var paneToggle: some View {
        if labelVisibility == .iconOnly {
            HStack(spacing: 0) {
                compactSegment(title: "Original", systemImage: "doc.text", active: model.isShowingTranslation == false) {
                    if model.isShowingTranslation { model.toggle() }
                }
                compactSegment(title: "Translation", systemImage: "translate", active: model.isShowingTranslation) {
                    if model.isShowingTranslation == false { model.toggle() }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OhiaColors.chipRestBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show original or translation")
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity)
        } else {
            HStack(spacing: 0) {
                segment(title: "Original", active: model.isShowingTranslation == false) {
                    if model.isShowingTranslation { model.toggle() }
                }
                segment(title: "Translation", active: model.isShowingTranslation) {
                    if model.isShowingTranslation == false { model.toggle() }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OhiaColors.chipRestBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show original or translation")
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity)
        }
    }

    private func segment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? OhiaColors.chipActiveBackground : Color.clear)
                .foregroundStyle(active ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func compactSegment(
        title: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(active ? OhiaColors.chipActiveBackground : Color.clear)
                .foregroundStyle(active ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: - Columns hide/show

    private var hideShowButton: some View {
        Button(action: { model.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "translate")
                if labelVisibility == .textAndIcon {
                    Text(model.isShowingTranslation ? "Hide translation" : "Show translation")
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.emblem)
        .fixedSize(horizontal: true, vertical: false)
        .help(model.isShowingTranslation
              ? "Hide the \(model.targetLanguageAutonym) translation"
              : "Show the \(model.targetLanguageAutonym) translation")
        .accessibilityLabel(model.isShowingTranslation ? "Hide translation" : "Show translation")
        .transition(.opacity)
    }
}
