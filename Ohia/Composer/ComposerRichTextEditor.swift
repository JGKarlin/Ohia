// Shared reply/new-message editor with Mail-style rich-text controls.

import AppKit
import CoreText
import SwiftUI
import OhiaCore
import UniformTypeIdentifiers

struct ComposerEditorImageImport {
    let content: NSAttributedString
    let rollback: @MainActor () -> Void
}

struct ComposerRichTextEditor: View {
    @Binding var content: NSAttributedString
    @Binding var format: ComposerMessageFormat
    let isEnabled: Bool
    var inlinePhotoOwnerID: UUID? = nil
    var inlinePhotos: Binding<[ComposerInlinePhotoAsset]>? = nil
    var beginInlinePhotoImport: (() -> ComposerAttachmentImport?)? = nil
    var validateInlinePhotoImport: ((ComposerAttachmentImport) -> Bool)? = nil
    var finishInlinePhotoImport: ((ComposerAttachmentImport) -> Void)? = nil
    var onAddAttachment: (() -> Void)? = nil
    var onDropAttachments: (([URL]) -> Void)? = nil
    /// Optional non-draft image importer used by signature editing. The
    /// caller owns storage and returns editor-ready attributed content;
    /// this shared editor only inserts it at the current selection.
    var importEditorImage: (@MainActor (URL) async throws -> ComposerEditorImageImport)? = nil
    /// Whether the header offers the rich-text/plain-text switch. The
    /// composer owns its format and shows it; the signature studio settles
    /// format on its first step and passes a constant binding here, where a
    /// picker would be a control that silently does nothing.
    var showsFormatPicker: Bool = true
    /// Moves utility actions out of the long formatting strip and onto the
    /// header row so they remain visible at narrower editor widths.
    var placesUtilityActionsInHeader: Bool = false
    /// Content drawn directly over the live text view, in its own
    /// coordinate space (not the header/formatting-bar chrome above it) —
    /// the Composer's word-morph revision overlay is the only caller today.
    /// `nil` for every other host (e.g. the signature studio), which has
    /// no equivalent effect.
    var revisionOverlay: ((ComposerRichTextController) -> AnyView)? = nil

    @State private var controller = ComposerRichTextController()
    @State private var showsFormattingBar = true
    @State private var showsInlinePhotoImporter = false
    @State private var inlinePhotoImportState = ComposerInlinePhotoImportState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            formatHeader

            if format == .richText && showsFormattingBar {
                ComposerFormattingBar(
                    controller: controller,
                    canInsertPhoto: canInsertPhoto,
                    isImportingPhoto: inlinePhotoImportState.isImporting,
                    showsUtilityActions: !placesUtilityActionsInHeader,
                    onInsertPhoto: { showsInlinePhotoImporter = true }
                )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }

            ComposerRichTextView(
                content: $content,
                format: format,
                isEditable: isEnabled,
                controller: controller,
                inlinePhotos: inlinePhotos?.wrappedValue ?? [],
                onDropFiles: handleDroppedFiles
            )
            .background(OhiaColors.composerPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
            }
            .overlay {
                // Applied here, not on the outer VStack, so its coordinate
                // space matches exactly what `documentGlyphRects` measures
                // against — the header row and formatting bar above sit
                // outside this frame entirely.
                if let revisionOverlay {
                    revisionOverlay(controller)
                }
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: .infinity)
        }
        .tint(OhiaColors.chipActiveForeground)
        .background {
            if format == .richText {
                ComposerFormattingShortcuts(controller: controller)
            }
        }
        .fileImporter(
            isPresented: $showsInlinePhotoImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importInlinePhoto
        )
        .fileDialogMessage(
            importEditorImage == nil
                ? "Choose a photo to insert into the email body"
                : "Choose an image to insert into the signature"
        )
        .fileDialogConfirmationLabel(
            importEditorImage == nil ? "Insert Photo" : "Insert Image"
        )
        .alert(
            importEditorImage == nil ? "Could Not Insert Photo" : "Could Not Insert Image",
            isPresented: Binding(
                get: { inlinePhotoImportState.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { inlinePhotoImportState.dismissError() }
                }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(inlinePhotoImportState.errorMessage ?? "")
        }
        .onDisappear { inlinePhotoImportState.cancel() }
    }

    @ViewBuilder
    private var formatHeader: some View {
        if format == .richText,
           placesUtilityActionsInHeader,
           onAddAttachment != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headerFormattingControls
                    composerHeaderActions
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 6) {
                    compactComposerHeaderActions
                    headerFormattingControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                headerFormattingControls

                if let onAddAttachment {
                    attachmentButton(action: onAddAttachment, compact: false)
                }

                Spacer(minLength: 0)

                if format == .richText,
                   showsFormattingBar,
                   placesUtilityActionsInHeader {
                    headerUtilityActions
                }
            }
        }
    }

    private var headerFormattingControls: some View {
        HStack(spacing: 8) {
            if showsFormatPicker {
                formatPickerMenu
            }

            if format == .richText {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        showsFormattingBar.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paintbrush")
                        Text(showsFormattingBar ? "Hide Formatting" : "Show Formatting")
                        Image(systemName: showsFormattingBar ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(OhiaTypography.cardDetail)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 5))
                .accessibilityHint("Shows or hides the rich-text formatting controls")
            }
        }
    }

    private var composerHeaderActions: some View {
        HStack(spacing: 6) {
            if let onAddAttachment {
                attachmentButton(action: onAddAttachment, compact: false)
            }
            headerUtilityActions
            if controller.selectedInlinePhotoSize != nil {
                ComposerPhotoSizeMenu(controller: controller)
            }
        }
    }

    private var compactComposerHeaderActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let onAddAttachment {
                    attachmentButton(action: onAddAttachment, compact: true)
                }
                headerUtilityActions
            }
            if controller.selectedInlinePhotoSize != nil {
                ComposerPhotoSizeMenu(controller: controller)
            }
        }
    }

    private func attachmentButton(
        action: @escaping () -> Void,
        compact: Bool
    ) -> some View {
        Button(action: action) {
            if compact {
                Label("Attach", systemImage: "paperclip")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Label("Attach", systemImage: "paperclip")
                    .font(OhiaTypography.cardDetail)
            }
        }
        .buttonStyle(EmblemButtonStyle(
            horizontalPadding: compact ? 6 : 8,
            verticalPadding: 5
        ))
        .help("Attach Files")
        .accessibilityLabel("Attach Files")
    }

    private var canInsertPhoto: Bool {
        guard isEnabled else { return false }
        if importEditorImage != nil { return true }
        return inlinePhotoOwnerID != nil
            && inlinePhotos != nil
            && beginInlinePhotoImport != nil
            && validateInlinePhotoImport != nil
            && finishInlinePhotoImport != nil
    }

    private var headerUtilityActions: some View {
        HStack(spacing: 6) {
            headerActionButton("textformat", help: "Clear Formatting") {
                controller.clearFormatting()
            }
            headerActionButton("face.smiling", help: "Emoji and Symbols") {
                controller.showEmojiAndSymbols()
            }
            if canInsertPhoto {
                headerActionButton("photo.badge.plus", help: inlinePhotoActionLabel) {
                    showsInlinePhotoImporter = true
                }
                .disabled(!controller.canEdit || inlinePhotoImportState.isImporting)
            }
        }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private var inlinePhotoActionLabel: String {
        importEditorImage == nil ? "Insert Photo" : "Insert Image"
    }

    private func headerActionButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(help, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 6, verticalPadding: 5))
        .help(help)
        .accessibilityLabel(help)
    }

    private var formatPickerMenu: some View {
        Menu {
            ForEach(ComposerMessageFormat.allCases) { option in
                Button {
                    setFormat(option)
                } label: {
                    if option == format {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
                HStack(spacing: 5) {
                    Image(systemName: format == .richText ? "textformat" : "text.alignleft")
                    Text(format.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.iconPillForeground)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(OhiaColors.iconPillBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Message format")
        .accessibilityValue(format.label)
    }

    private func setFormat(_ newFormat: ComposerMessageFormat) {
        guard newFormat != format else { return }
        format = newFormat
        if newFormat == .plainText {
            content = NSAttributedString(
                string: ComposerRichTextCodec.plainBodyProjection(of: content)
            )
        }
        controller.setRichTextEnabled(newFormat == .richText)
    }

    private func importInlinePhoto(_ result: Result<[URL], any Error>) {
        let urls: [URL]
        do {
            urls = try result.get()
            guard !urls.isEmpty else {
                presentInlinePhotoError("No photo was selected.")
                return
            }
        } catch {
            let cocoaError = error as NSError
            if error is CancellationError
                || (cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == NSUserCancelledError) {
                return
            }
            presentInlinePhotoError(error.localizedDescription)
            return
        }

        let securityScopedURLs = urls.filter {
            $0.startAccessingSecurityScopedResource()
        }
        importInlinePhotos(
            at: urls,
            securityScopedURLsToRelease: securityScopedURLs
        )
    }

    private func handleDroppedFiles(_ urls: [URL]) -> Bool {
        guard isEnabled, !urls.isEmpty, let onDropAttachments else { return false }
        let routing = ComposerFileDropRouting.route(
            urls,
            insertsImagesInline: format == .richText && canInsertPhoto
        )

        if !routing.inlinePhotos.isEmpty {
            if inlinePhotoImportState.isImporting {
                presentInlinePhotoError(
                    "Wait for the current photo import to finish before dropping another photo."
                )
            } else {
                let securityScopedURLs = routing.inlinePhotos.filter {
                    $0.startAccessingSecurityScopedResource()
                }
                importInlinePhotos(
                    at: routing.inlinePhotos,
                    securityScopedURLsToRelease: securityScopedURLs
                )
            }
        }
        if !routing.attachments.isEmpty {
            onDropAttachments(routing.attachments)
        }
        return true
    }

    private func importInlinePhotos(
        at urls: [URL],
        securityScopedURLsToRelease: [URL]
    ) {
        guard !urls.isEmpty else { return }

        if let importEditorImage {
            let task = inlinePhotoImportState.start {
                defer {
                    securityScopedURLsToRelease.forEach {
                        $0.stopAccessingSecurityScopedResource()
                    }
                }
                for (index, url) in urls.enumerated() {
                    var importedImage: ComposerEditorImageImport?
                    do {
                        let imported = try await importEditorImage(url)
                        importedImage = imported
                        try Task.checkCancellation()
                        guard controller.insertAttributedContent(
                            imported.content,
                            actionName: "Insert Image"
                        ) else {
                            throw ComposerInlinePhotoInsertionError.editorUnavailable
                        }
                        if index < urls.count - 1 {
                            controller.moveInsertionPointAfterSelection()
                        }
                    } catch {
                        importedImage?.rollback()
                        throw error
                    }
                }
            }
            if task == nil {
                securityScopedURLsToRelease.forEach {
                    $0.stopAccessingSecurityScopedResource()
                }
            }
            return
        }

        guard let ownerID = inlinePhotoOwnerID,
              let inlinePhotos,
              let beginInlinePhotoImport,
              let validateInlinePhotoImport,
              let finishInlinePhotoImport,
              let draftAssetImport = beginInlinePhotoImport()
        else {
            securityScopedURLsToRelease.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
            presentInlinePhotoError("The draft is no longer available for photo insertion.")
            return
        }

        guard draftAssetImport.ownerID == ownerID else {
            finishInlinePhotoImport(draftAssetImport)
            securityScopedURLsToRelease.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
            presentInlinePhotoError("The draft changed before the photo import could begin.")
            return
        }

        let store = ComposerInlinePhotoStore()
        let task = inlinePhotoImportState.start {
            defer {
                securityScopedURLsToRelease.forEach {
                    $0.stopAccessingSecurityScopedResource()
                }
            }
            defer { finishInlinePhotoImport(draftAssetImport) }

            for (index, url) in urls.enumerated() {
                let asset = try await store.importPhoto(
                    from: url,
                    sourceFileName: url.lastPathComponent,
                    ownerID: ownerID
                )
                do {
                    try Task.checkCancellation()
                    guard validateInlinePhotoImport(draftAssetImport) else {
                        throw ComposerInlinePhotoInsertionError.draftUnavailable
                    }
                    let previousPhotos = inlinePhotos.wrappedValue
                    inlinePhotos.wrappedValue = previousPhotos + [asset]
                    controller.configureInlinePhotos(inlinePhotos.wrappedValue)
                    guard controller.insertInlinePhoto(
                        asset: asset,
                        ownerID: ownerID,
                        store: store,
                        size: .medium
                    ) else {
                        inlinePhotos.wrappedValue = previousPhotos
                        controller.configureInlinePhotos(previousPhotos)
                        throw ComposerInlinePhotoInsertionError.editorUnavailable
                    }
                    if index < urls.count - 1 {
                        controller.moveInsertionPointAfterSelection()
                    }
                } catch {
                    await store.discardImportedPhoto(ownerID: ownerID, asset: asset)
                    throw error
                }
            }
        }
        if task == nil {
            finishInlinePhotoImport(draftAssetImport)
            securityScopedURLsToRelease.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func presentInlinePhotoError(_ message: String) {
        inlinePhotoImportState.presentError(message)
    }
}

private enum ComposerInlinePhotoInsertionError: LocalizedError {
    case editorUnavailable
    case draftUnavailable

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            "The editor is not available for image insertion."
        case .draftUnavailable:
            "The draft is no longer available for photo insertion."
        }
    }
}

@Observable
@MainActor
final class ComposerInlinePhotoImportState {
    @ObservationIgnored private var importTask: Task<Void, Never>?

    private(set) var isImporting = false
    private(set) var errorMessage: String?

    @discardableResult
    func start(
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never>? {
        guard importTask == nil else { return nil }
        errorMessage = nil
        isImporting = true
        let task = Task { [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                // Cancellation is an expected lifecycle event, not an alert.
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }
            self?.isImporting = false
            self?.importTask = nil
        }
        importTask = task
        return task
    }

    func cancel() {
        importTask?.cancel()
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    func dismissError() {
        errorMessage = nil
    }
}

private struct ComposerFormattingBar: View {
    @Bindable var controller: ComposerRichTextController
    let canInsertPhoto: Bool
    let isImportingPhoto: Bool
    let showsUtilityActions: Bool
    let onInsertPhoto: () -> Void

    private let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                fontFamilyMenu
                fontFaceMenu
                fontSizeMenu

                Divider().frame(height: 22)

                HStack(spacing: 8) {
                    foregroundColorPicker
                    backgroundColorPicker
                }
                .fixedSize()
                formatToggle("B", help: "Bold — Command-B", isOn: controller.isBold) {
                    controller.toggleBold()
                }
                formatToggle("I", help: "Italic — Command-I", isOn: controller.isItalic) {
                    controller.toggleItalic()
                }
                formatToggle("U", help: "Underline — Command-U", isOn: controller.isUnderlined) {
                    controller.toggleUnderline()
                }
                formatToggle("S", help: "Strikethrough", isOn: controller.isStruckThrough) {
                    controller.toggleStrikethrough()
                }

                Divider().frame(height: 22)

                alignmentButton("text.alignleft", help: "Align Left", alignment: .left)
                alignmentButton("text.aligncenter", help: "Align Center", alignment: .center)
                alignmentButton("text.alignright", help: "Align Right", alignment: .right)
                listMenu
                actionButton("decrease.indent", help: "Decrease Indent") {
                    controller.changeIndent(by: -18)
                }
                actionButton("increase.indent", help: "Increase Indent") {
                    controller.changeIndent(by: 18)
                }

                if showsUtilityActions {
                    Divider().frame(height: 22)
                    actionButton("textformat", help: "Clear Formatting") {
                        controller.clearFormatting()
                    }
                    actionButton("face.smiling", help: "Emoji and Symbols") {
                        controller.showEmojiAndSymbols()
                    }

                    if canInsertPhoto {
                        Divider().frame(height: 22)
                        actionButton("photo.badge.plus", help: "Insert Photo") {
                            onInsertPhoto()
                        }
                        .disabled(!controller.canEdit || isImportingPhoto)
                        if controller.selectedInlinePhotoSize != nil {
                            ComposerPhotoSizeMenu(controller: controller)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .background(OhiaColors.composerRaisedPanelBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting controls")
    }

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(controller.availableFontFamilies, id: \.self) { family in
                Button(ComposerRichTextController.displayName(forFontFamily: family)) {
                    controller.setFontFamily(family)
                }
            }
        } label: {
            formatMenuLabel(controller.fontFamilyDisplayName, width: 126)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Font family")
        .accessibilityValue(controller.fontFamilyDisplayName)
    }

    private var fontFaceMenu: some View {
        Menu {
            ForEach(controller.availableFontFaces) { face in
                Button(face.label) { controller.setFontFace(face.postScriptName) }
            }
        } label: {
            formatMenuLabel(controller.fontFace, width: 92)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Font style")
        .accessibilityValue(controller.fontFace)
    }

    private var fontSizeMenu: some View {
        Menu {
            ForEach(fontSizes, id: \.self) { size in
                Button(String(Int(size))) {
                    controller.setFontSize(size)
                }
            }
        } label: {
            formatMenuLabel(
                String(Int(controller.fontSize.rounded())),
                width: 42
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Font size")
        .accessibilityValue(String(Int(controller.fontSize.rounded())))
    }

    private var foregroundColorPicker: some View {
        ColorPicker(
            "Text Color",
            selection: Binding(
                get: { Color(nsColor: controller.foregroundColor) },
                set: { controller.setForegroundColor(NSColor($0)) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 24)
        .help("Text Color")
    }

    private var backgroundColorPicker: some View {
        ColorPicker(
            "Text Background Color",
            selection: Binding(
                get: { Color(nsColor: controller.backgroundColor) },
                set: { controller.setBackgroundColor(NSColor($0)) }
            ),
            supportsOpacity: true
        )
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 24)
        .help("Text Background Color")
    }

    private var listMenu: some View {
        Menu {
            Button("Bulleted List") { controller.setList(.bulleted) }
            Button("Numbered List") { controller.setList(.numbered) }
            Divider()
            Button("Remove List") { controller.setList(.none) }
        } label: {
            Label("List Style", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.iconPillForeground)
                .frame(width: 25, height: 24)
                .background(OhiaColors.iconPillBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("List style")
    }

    private func formatMenuLabel(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
        }
        .font(OhiaTypography.cardDetail)
        .foregroundStyle(OhiaColors.iconPillForeground)
        .frame(minWidth: width)
        .frame(height: 24)
        .fixedSize(horizontal: true, vertical: false)
        .background(OhiaColors.iconPillBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatToggle(
        _ title: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: title == "B" ? .bold : .regular))
                .italic(title == "I")
                .underline(title == "U")
                .strikethrough(title == "S")
                .foregroundStyle(isOn ? OhiaColors.chipActiveForeground : OhiaColors.iconPillForeground)
                .frame(width: 25, height: 24)
                .background(isOn ? OhiaColors.chipActiveBackground : OhiaColors.iconPillBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isOn ? OhiaColors.chipActiveBorder : OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func alignmentButton(
        _ symbol: String,
        help: String,
        alignment: NSTextAlignment
    ) -> some View {
        let isOn = controller.alignment == alignment
        return Button { controller.setAlignment(alignment) } label: {
            Label(help, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? OhiaColors.chipActiveForeground : OhiaColors.iconPillForeground)
                .frame(width: 25, height: 24)
                .background(isOn ? OhiaColors.chipActiveBackground : OhiaColors.iconPillBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isOn ? OhiaColors.chipActiveBorder : OhiaColors.iconPillBorder, lineWidth: 1)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(help, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 6, verticalPadding: 5))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ComposerPhotoSizeMenu: View {
    @Bindable var controller: ComposerRichTextController

    var body: some View {
        Menu {
            ForEach(ComposerInlinePhotoSize.allCases) { size in
                Button {
                    controller.resizeSelectedInlinePhoto(to: size)
                } label: {
                    if size == controller.selectedInlinePhotoSize {
                        Label(size.label, systemImage: "checkmark")
                    } else {
                        Text(size.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                Text(controller.selectedInlinePhotoSize?.label ?? "Photo Size")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(OhiaTypography.cardDetail)
            .foregroundStyle(OhiaColors.ohiaGreen)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(OhiaColors.buttonBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Photo Size")
        .accessibilityLabel("Photo size")
        .accessibilityValue(controller.selectedInlinePhotoSize?.label ?? "")
    }
}

/// Keeps standard rich-text key equivalents installed even when the visible
/// formatting bar is collapsed.
private struct ComposerFormattingShortcuts: View {
    let controller: ComposerRichTextController

    var body: some View {
        Group {
            Button("Bold") { controller.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { controller.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Underline") { controller.toggleUnderline() }
                .keyboardShortcut("u", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class ComposerDroppingTextView: NSTextView {
    var onDropFiles: (([URL]) -> Bool)?

    override func dragOperation(
        for dragInfo: NSDraggingInfo,
        type: NSPasteboard.PasteboardType
    ) -> NSDragOperation {
        let standardOperation = super.dragOperation(for: dragInfo, type: type)
        guard type == .fileURL,
              isEditable,
              onDropFiles != nil,
              !Self.fileURLs(from: dragInfo.draggingPasteboard).isEmpty
        else { return standardOperation }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        let localPoint = convert(sender.draggingLocation, from: nil)
        guard handleFileDrop(urls, at: localPoint) else {
            return super.performDragOperation(sender)
        }
        return true
    }

    func handleFileDrop(_ urls: [URL], at localPoint: NSPoint) -> Bool {
        guard !urls.isEmpty, let onDropFiles else { return false }
        let insertionIndex = min(characterIndexForInsertion(at: localPoint), string.utf16.count)
        setSelectedRange(NSRange(location: insertionIndex, length: 0))
        window?.makeFirstResponder(self)
        return onDropFiles(urls)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []).compactMap { object in
            guard let url = object as? URL, url.isFileURL else { return nil }
            return url
        }
    }
}

private struct ComposerRichTextView: NSViewRepresentable {
    @Binding var content: NSAttributedString
    let format: ComposerMessageFormat
    let isEditable: Bool
    let controller: ComposerRichTextController
    let inlinePhotos: [ComposerInlinePhotoAsset]
    let onDropFiles: (([URL]) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let initialSize = NSSize(width: 320, height: 240)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: initialSize))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerDroppingTextView(
            frame: NSRect(origin: .zero, size: initialSize)
        )
        textView.delegate = context.coordinator
        textView.onDropFiles = onDropFiles
        textView.isRichText = format == .richText
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = NSFont.systemFont(
            ofSize: ComposerRichTextController.defaultFontSize
        )
        textView.textColor = .textColor
        textView.textStorage?.setAttributedString(content)

        scrollView.documentView = textView
        controller.attach(textView)
        controller.configureInlinePhotos(inlinePhotos)
        return scrollView
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        // An NSTextView inside an NSScrollView has a content-driven AppKit
        // fitting size. Letting SwiftUI query that while surrounding stacks
        // also offer unbounded height can create a perpetual layout pass when
        // generated text lands. Resolve the representable to the finite space
        // proposed by the Composer, with stable fallbacks during first layout.
        CGSize(
            width: finiteDimension(proposal.width, fallback: 320),
            height: finiteDimension(proposal.height, fallback: 240)
        )
    }

    private func finiteDimension(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        textView.isRichText = format == .richText
        (textView as? ComposerDroppingTextView)?.onDropFiles = onDropFiles
        controller.attach(textView)
        controller.configureInlinePhotos(inlinePhotos)

        // NSTextView normalizes imported HTML attributes (fonts, paragraph
        // styles, colors) after assignment. Comparing that normalized value
        // back to the original binding makes every SwiftUI update look like
        // a new external edit, repeatedly resets the text storage, and feeds
        // selection/controller mutations back into another graph update.
        // Track the last *bound* value instead so each real external change
        // is applied once while AppKit remains free to normalize its view.
        if context.coordinator.boundContentTracker.needsApply(content) {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(content)
            let safeLocation = min(selection.location, content.length)
            let safeLength = min(selection.length, content.length - safeLocation)
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            controller.refreshState()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerRichTextView
        var boundContentTracker: ComposerRichTextBoundContentTracker

        init(parent: ComposerRichTextView) {
            self.parent = parent
            self.boundContentTracker = ComposerRichTextBoundContentTracker(
                initialContent: parent.content
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let editedContent = NSAttributedString(attributedString: textView.attributedString())
            _ = boundContentTracker.needsApply(editedContent)
            parent.content = editedContent
            parent.controller.refreshState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.refreshState()
        }
    }
}

struct ComposerFileDropRouting {
    struct Result: Equatable {
        let inlinePhotos: [URL]
        let attachments: [URL]
    }

    static func route(
        _ urls: [URL],
        insertsImagesInline: Bool
    ) -> Result {
        guard insertsImagesInline else {
            return Result(inlinePhotos: [], attachments: urls)
        }

        var inlinePhotos: [URL] = []
        var attachments: [URL] = []
        for url in urls {
            if isImage(url) {
                inlinePhotos.append(url)
            } else {
                attachments.append(url)
            }
        }
        return Result(inlinePhotos: inlinePhotos, attachments: attachments)
    }

    private static func isImage(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .image)
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// Distinguishes a real binding change from AppKit's internal normalization
/// of the attributed string already applied to the text view.
struct ComposerRichTextBoundContentTracker {
    private var lastContent: NSAttributedString

    init(initialContent: NSAttributedString) {
        self.lastContent = NSAttributedString(attributedString: initialContent)
    }

    mutating func needsApply(_ content: NSAttributedString) -> Bool {
        guard !lastContent.isEqual(to: content) else { return false }
        lastContent = NSAttributedString(attributedString: content)
        return true
    }
}

@Observable
@MainActor
final class ComposerRichTextController {
    nonisolated static let defaultFontSize: CGFloat = 15

    struct FontFace: Identifiable {
        let postScriptName: String
        let label: String
        var id: String { postScriptName }
    }

    enum ListStyle {
        case none
        case bulleted
        case numbered
    }

    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var inlinePhotoAssets: [UUID: ComposerInlinePhotoAsset] = [:]

    private(set) var fontFamily = "Helvetica"
    private(set) var fontFace = "Regular"
    private(set) var fontSize = ComposerRichTextController.defaultFontSize
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var isStruckThrough = false
    private(set) var alignment: NSTextAlignment = .left
    private(set) var foregroundColor: NSColor = .textColor
    private(set) var backgroundColor: NSColor = .clear
    private(set) var selectedInlinePhotoSize: ComposerInlinePhotoSize?

    private(set) var canEdit = false

    let availableFontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var fontFamilyDisplayName: String {
        Self.displayName(forFontFamily: fontFamily)
    }

    nonisolated static func displayName(forFontFamily family: String) -> String {
        family == ".AppleSystemUIFont" ? "System Font" : family
    }

    var availableFontFaces: [FontFace] {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: fontFamily) else {
            return []
        }
        return members.compactMap { member in
            guard member.count >= 2,
                  let postScriptName = member[0] as? String,
                  let label = member[1] as? String else { return nil }
            return FontFace(postScriptName: postScriptName, label: label)
        }
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        refreshState()
    }

    /// Bounding rects for `range`, in the document's own flipped coordinate
    /// space (stable regardless of current scroll position) — several rects
    /// if the range wraps multiple lines. Empty if the range is out of
    /// bounds or no text view is attached. Callers positioning an overlay
    /// against the *visible* viewport should subtract `visibleOrigin`.
    func documentGlyphRects(forCharacterRange range: NSRange) -> [CGRect] {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              range.location != NSNotFound,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0)
        else { return [] }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
        }
        return rects
    }

    /// Top-left of the currently visible scroll viewport, in the same
    /// document-flipped coordinate space as `documentGlyphRects`. Subtract
    /// this from a document rect to place it relative to the visible
    /// overlay's own frame; re-read every frame so overlay content tracks
    /// live scrolling rather than the scroll offset at some earlier moment.
    var visibleOrigin: CGPoint {
        textView?.enclosingScrollView?.documentVisibleRect.origin ?? .zero
    }

    /// The live text view's raw string — unlike
    /// `ComposerRichTextCodec.plainBodyProjection`, this keeps inline-photo
    /// placeholder characters (`\u{fffc}`) in place, so character offsets
    /// computed against it line up exactly with `documentGlyphRects`, which
    /// indexes this same text storage. Callers that need offsets to match
    /// real glyph positions must diff this, not a stripped projection.
    var rawText: String {
        textView?.string ?? ""
    }

    /// Temporarily hides the real glyphs in `range` — foreground,
    /// underline, strikethrough, and background all cleared via
    /// `NSLayoutManager` *temporary* attributes, which never touch the
    /// real `NSTextStorage` (no undo entry, no dirty flag, no
    /// `textDidChange`) — so an overlay can draw an animated replica in
    /// their place without disturbing the actual document. Every call
    /// MUST be paired with `unhideGlyphs(in:)` for the same range,
    /// including on overlay teardown, or the real text stays invisible.
    func hideGlyphs(in range: NSRange) {
        guard let textView, let layoutManager = textView.layoutManager,
              range.location != NSNotFound,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0)
        else { return }
        layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.underlineColor, value: NSColor.clear, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.strikethroughColor, value: NSColor.clear, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.clear, forCharacterRange: range)
    }

    /// Reverses `hideGlyphs(in:)`, restoring the real glyphs' normal display.
    func unhideGlyphs(in range: NSRange) {
        guard let textView, let layoutManager = textView.layoutManager,
              range.location != NSNotFound,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0)
        else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.strikethroughColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }

    /// The real text and a SwiftUI `Font` faithfully reproducing `range`'s
    /// `NSFont` (family, size, bold/italic baked in via the CTFont bridge)
    /// — for drawing an animated replica in place of its (temporarily
    /// hidden) real glyphs, rather than a plain system font that would
    /// drift from what the user actually sees. `nil` if the range is out
    /// of bounds or empty.
    func attributedRun(forCharacterRange range: NSRange) -> (text: String, font: Font)? {
        guard let textView, let storage = textView.textStorage else { return nil }
        return Self.attributedRun(forCharacterRange: range, in: storage, fallbackFont: textView.font)
    }

    /// Same lookup as the instance method above, against an arbitrary
    /// `NSAttributedString` rather than the live text view's storage — for
    /// content that hasn't been applied to the real document yet (e.g. the
    /// pending body of an in-flight instruction revision, still held back
    /// while its word-morph overlay animates).
    static func attributedRun(
        forCharacterRange range: NSRange, in attributedString: NSAttributedString, fallbackFont: NSFont? = nil
    ) -> (text: String, font: Font)? {
        guard range.location != NSNotFound,
              NSMaxRange(range) <= attributedString.length, range.length > 0
        else { return nil }
        let text = attributedString.attributedSubstring(from: range).string
        let nsFont = (attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            ?? fallbackFont ?? NSFont.systemFont(ofSize: Self.defaultFontSize)
        return (text, Font(nsFont as CTFont))
    }

    func configureInlinePhotos(_ photos: [ComposerInlinePhotoAsset]) {
        inlinePhotoAssets = Dictionary(
            photos.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        refreshInlinePhotoSelection()
    }

    func setRichTextEnabled(_ enabled: Bool) {
        textView?.isRichText = enabled
        refreshState()
    }

    func refreshState() {
        guard let textView else { return }
        let editable = textView.isEditable && textView.isRichText
        if canEdit != editable { canEdit = editable }
        refreshInlinePhotoSelection()
        guard let font = selectedFont(in: textView) else { return }
        let manager = NSFontManager.shared
        let traits = manager.traits(of: font)
        let selectedFamily = font.familyName ?? "Helvetica"
        var selectedFace = (font.displayName ?? font.familyName ?? "Regular")
            .replacingOccurrences(of: selectedFamily, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedFace.isEmpty { selectedFace = "Regular" }

        let attributes = selectedAttributes(in: textView)
        let selectedUnderline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        let selectedStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        let selectedBold = traits.contains(.boldFontMask)
        let selectedItalic = traits.contains(.italicFontMask)
        let selectedForeground = (attributes[.foregroundColor] as? NSColor) ?? .textColor
        let selectedBackground = (attributes[.backgroundColor] as? NSColor) ?? .clear
        let selectedAlignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left

        if fontFamily != selectedFamily { fontFamily = selectedFamily }
        if fontFace != selectedFace { fontFace = selectedFace }
        if fontSize != font.pointSize { fontSize = font.pointSize }
        if isBold != selectedBold { isBold = selectedBold }
        if isItalic != selectedItalic { isItalic = selectedItalic }
        if isUnderlined != selectedUnderline { isUnderlined = selectedUnderline }
        if isStruckThrough != selectedStrikethrough { isStruckThrough = selectedStrikethrough }
        if foregroundColor != selectedForeground { foregroundColor = selectedForeground }
        if backgroundColor != selectedBackground { backgroundColor = selectedBackground }
        if alignment != selectedAlignment { alignment = selectedAlignment }
    }

    func setFontFamily(_ family: String) {
        transformFonts(actionName: "Change Font") {
            NSFontManager.shared.convert($0, toFamily: family)
        }
    }

    func setFontFace(_ postScriptName: String) {
        transformFonts(actionName: "Change Font") {
            NSFont(name: postScriptName, size: $0.pointSize) ?? $0
        }
    }

    func setFontSize(_ size: CGFloat) {
        transformFonts(actionName: "Change Font Size") {
            NSFontManager.shared.convert($0, toSize: size)
        }
    }

    func toggleBold() {
        let target = !isBold
        transformFonts(actionName: "Bold") {
            target
                ? NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert($0, toNotHaveTrait: .boldFontMask)
        }
    }

    func toggleItalic() {
        let target = !isItalic
        transformFonts(actionName: "Italic") {
            target
                ? NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask)
                : NSFontManager.shared.convert($0, toNotHaveTrait: .italicFontMask)
        }
    }

    func toggleUnderline() {
        setAttribute(
            .underlineStyle,
            value: isUnderlined ? nil : NSUnderlineStyle.single.rawValue,
            actionName: "Underline"
        )
    }

    func toggleStrikethrough() {
        setAttribute(
            .strikethroughStyle,
            value: isStruckThrough ? nil : NSUnderlineStyle.single.rawValue,
            actionName: "Strikethrough"
        )
    }

    func setForegroundColor(_ color: NSColor) {
        setAttribute(.foregroundColor, value: color, actionName: "Text Color")
    }

    func setBackgroundColor(_ color: NSColor) {
        setAttribute(.backgroundColor, value: color, actionName: "Text Background Color")
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        transformParagraphs(actionName: "Text Alignment") { paragraph in
            paragraph.alignment = alignment
        }
    }

    func setList(_ style: ListStyle) {
        transformParagraphs(actionName: "List Style") { paragraph in
            switch style {
            case .none:
                paragraph.textLists = []
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 0
            case .bulleted:
                paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = max(paragraph.headIndent, 18)
            case .numbered:
                paragraph.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = max(paragraph.headIndent, 24)
            }
        }
    }

    func changeIndent(by amount: CGFloat) {
        transformParagraphs(actionName: amount > 0 ? "Increase Indent" : "Decrease Indent") { paragraph in
            paragraph.headIndent = max(0, paragraph.headIndent + amount)
            paragraph.firstLineHeadIndent = max(0, paragraph.firstLineHeadIndent + amount)
        }
    }

    func clearFormatting() {
        guard let textView else { return }
        performEdit(actionName: "Clear Formatting") {
            let range = textView.selectedRange()
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Self.defaultFontSize),
                .foregroundColor: NSColor.textColor
            ]
            if range.length == 0 {
                textView.typingAttributes = base
            } else {
                textView.textStorage?.setAttributes(base, range: range)
            }
        }
    }

    func showEmojiAndSymbols() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @discardableResult
    func insertAttributedContent(
        _ content: NSAttributedString,
        actionName: String
    ) -> Bool {
        guard let textView, canEdit, let storage = textView.textStorage else { return false }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(
            in: range,
            replacementString: content.string
        ) else { return false }
        performEdit(actionName: actionName) {
            storage.replaceCharacters(in: range, with: content)
            textView.setSelectedRange(NSRange(location: range.location, length: content.length))
        }
        return true
    }

    @discardableResult
    func insertInlinePhoto(
        asset: ComposerInlinePhotoAsset,
        ownerID: UUID,
        store: ComposerInlinePhotoStore,
        size: ComposerInlinePhotoSize
    ) -> Bool {
        let photo = ComposerInlinePhotoCoding.attachmentContent(
            asset: asset,
            ownerID: ownerID,
            store: store,
            size: size
        )
        guard insertAttributedContent(photo, actionName: "Insert Photo") else { return false }
        inlinePhotoAssets[asset.id] = asset
        return true
    }

    func moveInsertionPointAfterSelection() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        textView.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
    }

    func resizeSelectedInlinePhoto(to size: ComposerInlinePhotoSize) {
        guard let textView,
              let selected = selectedInlinePhoto(in: textView),
              let asset = inlinePhotoAssets[selected.assetID],
              let storage = textView.textStorage,
              let attachment = storage.attribute(
                  .attachment,
                  at: selected.range.location,
                  effectiveRange: nil
              ) as? NSTextAttachment,
              textView.shouldChangeText(
                  in: selected.range,
                  replacementString: "\u{fffc}"
              )
        else { return }
        performEdit(actionName: "Resize Photo") {
            let resizedAttachment = NSTextAttachment()
            resizedAttachment.fileWrapper = attachment.fileWrapper
            resizedAttachment.image = attachment.image?.copy() as? NSImage
            ComposerInlinePhotoCoding.updateBounds(
                of: resizedAttachment,
                asset: asset,
                size: size
            )
            var attributes = storage.attributes(
                at: selected.range.location,
                effectiveRange: nil
            )
            attributes.removeValue(forKey: .attachment)
            attributes[.ohiaInlinePhotoSize] = size.rawValue
            let replacement = NSMutableAttributedString(attachment: resizedAttachment)
            replacement.addAttributes(
                attributes,
                range: NSRange(location: 0, length: replacement.length)
            )
            storage.replaceCharacters(in: selected.range, with: replacement)
            textView.setSelectedRange(selected.range)
        }
    }

    private func transformFonts(actionName: String, transform: @escaping (NSFont) -> NSFont) {
        guard let textView else { return }
        performEdit(actionName: actionName) {
            let range = textView.selectedRange()
            if range.length == 0 {
                var attributes = textView.typingAttributes
                let current = (attributes[.font] as? NSFont)
                    ?? NSFont.systemFont(ofSize: Self.defaultFontSize)
                attributes[.font] = transform(current)
                textView.typingAttributes = attributes
                return
            }

            guard let storage = textView.textStorage else { return }
            var replacements: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = (value as? NSFont)
                    ?? NSFont.systemFont(ofSize: Self.defaultFontSize)
                replacements.append((subrange, transform(current)))
            }
            for (subrange, font) in replacements {
                storage.addAttribute(.font, value: font, range: subrange)
            }
        }
    }

    private func setAttribute(
        _ key: NSAttributedString.Key,
        value: Any?,
        actionName: String
    ) {
        guard let textView else { return }
        performEdit(actionName: actionName) {
            let range = textView.selectedRange()
            if range.length == 0 {
                var attributes = textView.typingAttributes
                attributes[key] = value
                textView.typingAttributes = attributes
            } else if let value {
                textView.textStorage?.addAttribute(key, value: value, range: range)
            } else {
                textView.textStorage?.removeAttribute(key, range: range)
            }
        }
    }

    private func transformParagraphs(
        actionName: String,
        transform: @escaping (NSMutableParagraphStyle) -> Void
    ) {
        guard let textView else { return }
        performEdit(actionName: actionName) {
            let selectedRange = textView.selectedRange()
            if textView.string.isEmpty {
                var attributes = textView.typingAttributes
                let paragraph = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                transform(paragraph)
                attributes[.paragraphStyle] = paragraph
                textView.typingAttributes = attributes
                return
            }

            let paragraphRange = (textView.string as NSString).paragraphRange(for: selectedRange)
            guard let storage = textView.textStorage else { return }
            var replacements: [(NSRange, NSMutableParagraphStyle)] = []
            storage.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
                let paragraph = ((value as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                transform(paragraph)
                replacements.append((subrange, paragraph))
            }
            if replacements.isEmpty {
                let paragraph = NSMutableParagraphStyle()
                transform(paragraph)
                replacements.append((paragraphRange, paragraph))
            }
            for (subrange, paragraph) in replacements {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
            }
        }
    }

    private func performEdit(actionName: String, mutation: () -> Void) {
        guard let textView else { return }
        let before = NSAttributedString(attributedString: textView.attributedString())
        let beforeSelection = textView.selectedRange()
        mutation()
        registerUndo(before, selection: beforeSelection, actionName: actionName)
        textView.didChangeText()
        refreshState()
    }

    private func registerUndo(
        _ content: NSAttributedString,
        selection: NSRange,
        actionName: String
    ) {
        textView?.undoManager?.registerUndo(withTarget: self) { target in
            target.restore(content, selection: selection, actionName: actionName)
        }
        textView?.undoManager?.setActionName(actionName)
    }

    private func restore(
        _ content: NSAttributedString,
        selection: NSRange,
        actionName: String
    ) {
        guard let textView else { return }
        let current = NSAttributedString(attributedString: textView.attributedString())
        let currentSelection = textView.selectedRange()
        registerUndo(current, selection: currentSelection, actionName: actionName)
        textView.textStorage?.setAttributedString(content)
        textView.setSelectedRange(selection)
        textView.didChangeText()
        refreshState()
    }

    private func selectedFont(in textView: NSTextView) -> NSFont? {
        let attributes = selectedAttributes(in: textView)
        return (attributes[.font] as? NSFont)
            ?? textView.font
            ?? NSFont.systemFont(ofSize: Self.defaultFontSize)
    }

    private func selectedAttributes(in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        let range = textView.selectedRange()
        if range.length == 0 || textView.string.isEmpty {
            return textView.typingAttributes
        }
        let location = min(range.location, max(0, textView.attributedString().length - 1))
        return textView.attributedString().attributes(at: location, effectiveRange: nil)
    }

    private func refreshInlinePhotoSelection() {
        guard let textView, let selected = selectedInlinePhoto(in: textView) else {
            if selectedInlinePhotoSize != nil { selectedInlinePhotoSize = nil }
            return
        }
        let rawSize = textView.attributedString().attribute(
            .ohiaInlinePhotoSize,
            at: selected.range.location,
            effectiveRange: nil
        ) as? String
        let size = ComposerInlinePhotoSize(rawValue: rawSize ?? "") ?? .medium
        if selectedInlinePhotoSize != size { selectedInlinePhotoSize = size }
    }

    private func selectedInlinePhoto(
        in textView: NSTextView
    ) -> (assetID: UUID, range: NSRange)? {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0,
              selectedRange.location < textView.attributedString().length
        else { return nil }
        var match: (UUID, NSRange)?
        textView.attributedString().enumerateAttribute(
            .ohiaInlinePhotoAssetID,
            in: selectedRange
        ) { value, range, stop in
            guard let rawID = value as? String, let id = UUID(uuidString: rawID) else { return }
            match = (id, range)
            stop.pointee = true
        }
        return match
    }
}
