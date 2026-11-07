// Ohia/Settings/Signatures/SignatureStudioSheet.swift
// The design studio sheet: contact form (me-card prefilled, editable) with
// optional image → one design box with a segmented tier chooser →
// hand-edit + save.

import OhiaCore
import OhiaML
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SignatureStudioSheet: View {
    @Bindable var model: SignatureStudioModel
    let dismiss: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)

            switch model.phase {
            case .fields:
                SignatureContactFormStage(model: model)
            case .cards:
                SignatureTierCardsStage(model: model)
            case .editing:
                SignatureEditingStage(model: model) {
                    if model.save(context: modelContext) {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 760, height: 580)
        .modifier(SignatureStudioPresentationStyle(
            usesNebulaCanvas: model.phase != .editing
        ))
        .tint(OhiaColors.chipActiveForeground)
        .onAppear {
            if model.phase == .fields {
                model.loadMeCard()
            }
        }
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text(model.account.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // The app's own close affordance (Search/Ask, Withheld) rather
            // than a worded Cancel pill: dismissing a sheet is chrome, and
            // §3.7's emblem pill is the vocabulary for actions.
            SidebarCloseButton(label: "Close without saving this signature") {
                model.cancelSession()
                dismiss()
            }
        }
        .padding(16)
    }

    private var headerTitle: String {
        switch model.phase {
        case .fields:  "New Signature — Your Details"
        case .cards:   "New Signature — Designs"
        case .editing: model.editingSlot == nil ? "New Signature — Edit & Save" : "Edit Signature"
        }
    }
}

/// The signature studio follows the Settings dark-mode composition directly:
/// controls sit on the shared night sky and two-colour nebula instead of an
/// opaque black sheet. Individual editing surfaces opt back into black.
private struct SignatureStudioPresentationStyle: ViewModifier {
    let usesNebulaCanvas: Bool
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark, usesNebulaCanvas {
            let shape = RoundedRectangle(cornerRadius: 10)

            // No perimeter stroke: the sheet's rounded edge reads on its own
            // against the desktop, and an outer border competed with the
            // horizontal hairlines that separate header / body / footer and
            // the preview box's own outline. The clip still rounds the corner.
            content
                .background { ComposerNightSkyBackdrop() }
                .compositingGroup()
                .clipShape(shape)
                .padding(10)
                .background { ComposerNightSkyBackdrop() }
        } else {
            content.composerPresentationFrame()
        }
    }
}

// MARK: - Stage 1: contact form + image + format

private struct SignatureContactFormStage: View {
    @Bindable var model: SignatureStudioModel
    @Environment(\.colorScheme) private var colorScheme
    /// Which row's text field holds focus — set when a row is added so the
    /// new line is immediately typable.
    @FocusState private var focus: RowFocus?
    /// The row currently being dragged, shared with every row's drop
    /// delegate so reordering can preview live under the pointer.
    @State private var draggingLineID: UUID?

    enum RowFocus: Hashable {
        case label(UUID)
        case value(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isLoadingMeCard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading your card from Contacts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let status = model.meCardStatusLine {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    contactFields
                }
                .padding(16)
            }

            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                // Format and Image share the fixed lower section with the
                // action they configure, while only contact details scroll.
                // The spacer holds Image to the right edge.
                HStack(alignment: .top, spacing: 28) {
                    formatSection
                    Spacer(minLength: 28)
                    imageSection
                }

                HStack {
                    // The one thing worth saying down here: why Generate
                    // Designs is dimmed. Gated on the image being absent —
                    // with one chosen, asking for an image would be a lie.
                    if model.format == .htmlWithImages, model.imageAsset == nil {
                        Text("Add an image to design with it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        model.generateCards()
                    } label: {
                        Label("Generate Designs", systemImage: "signature")
                    }
                    .buttonStyle(.emblem)
                    .font(OhiaTypography.button)
                    .disabled(!model.canGenerate)
                    .help(model.canGenerate
                        ? "Generate the three detail tiers"
                        : "Name is required; the HTML + Image format needs an image")
                }
            }
            .padding(16)
        }
    }

    private var contactFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contact details")
                .font(.headline)

            ForEach(model.contact.lines) { line in
                row(for: line)
            }

            addLineControl
        }
        // Row delegates only fire on rows; this catches a drag released in
        // the section's empty space so the drag state cannot strand.
        .onDrop(
            of: [.text],
            delegate: SignatureLineDragCancelDelegate(draggingLineID: $draggingLineID)
        )
    }

    @ViewBuilder
    private func row(for line: SignatureContactLine) -> some View {
        // Name anchors the signature: it is neither draggable nor a drop
        // target, and `moveLine` clamps anything dropped past it below.
        if line.kind == .name {
            rowContent(for: line, isName: true)
        } else {
            rowContent(for: line, isName: false)
                .onDrag {
                    draggingLineID = line.id
                    return NSItemProvider(object: line.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: SignatureLineDropDelegate(
                        targetID: line.id,
                        model: model,
                        draggingLineID: $draggingLineID
                    )
                )
        }
    }

    private func rowContent(for line: SignatureContactLine, isName: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(isName ? .clear : .secondary)
                .frame(width: 12)
                .help(isName ? "" : "Drag to reorder")
                .accessibilityHidden(isName)

            label(for: line)

            TextField(placeholder(for: line.kind), text: Binding(
                get: { line.value },
                set: { model.contact.setValue($0, for: line.id) }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($focus, equals: .value(line.id))
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

            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    model.contact.removeLine(id: line.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
            .help("Remove this line")
            .opacity(isName ? 0 : 1)
            .disabled(isName)
            .accessibilityHidden(isName)
        }
        .opacity(draggingLineID == line.id ? 0.4 : 1)
    }

    @ViewBuilder
    private func label(for line: SignatureContactLine) -> some View {
        if line.kind == .custom {
            TextField("Label", text: Binding(
                get: { line.customLabel ?? "" },
                set: { model.contact.setCustomLabel($0, for: line.id) }
            ))
            .textFieldStyle(.plain)
            .font(.caption)
            .multilineTextAlignment(.trailing)
            .focused($focus, equals: .label(line.id))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                colorScheme == .dark
                    ? OhiaColors.settingsCard
                    : OhiaColors.surface(0.05)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(width: 110)
            .help("Type the label this line shows")
        } else {
            Text(line.displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    private var addLineControl: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 12)
            Spacer().frame(width: 110)
            Menu {
                ForEach(SignatureFieldCategory.allCases, id: \.self) { category in
                    let kinds = model.contact.availableKinds.filter {
                        $0.category == category && $0 != .custom
                    }
                    if !kinds.isEmpty {
                        Section(category.displayName) {
                            ForEach(kinds, id: \.self) { kind in
                                Button(kind.displayName) { add(kind: kind) }
                            }
                        }
                    }
                }
                Divider()
                Button("Custom label…") { add(kind: .custom) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("Add line")
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add another line to this signature")

            Spacer()
        }
    }

    private func add(kind: SignatureFieldKind) {
        guard let id = model.contact.addLine(kind: kind) else { return }
        focus = kind == .custom ? .label(id) : .value(id)
    }

    /// Hints that say what shape the value takes, so a social row does not
    /// leave the user guessing between a handle and a URL.
    private func placeholder(for kind: SignatureFieldKind) -> String {
        switch kind {
        case .phone, .mobile, .office, .fax: "Separate multiple numbers with commas"
        case .x, .instagram, .linkedIn, .bluesky, .github, .youtube,
             .facebook, .threads, .tiktok, .telegram:
            "@handle or full URL"
        case .mastodon: "@user@server"
        case .website, .schedulingLink: "example.org"
        default: ""
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image (optional)")
                .font(.headline)
            SignatureImageDropWell(model: model)
            if let error = model.imageImportError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.ohiaRed)
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format & language")
                .font(.headline)
            Picker("Format", selection: $model.format) {
                ForEach(SignatureFormat.allCases, id: \.self) { format in
                    Text(format.displayName)
                        .tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            // The picker renders its own label, exactly as Format's does, so
            // the two read as the pair they are. A hand-built Text label
            // beside a `labelsHidden()` picker had drifted to caption weight
            // and secondary color, making Language look subordinate to a
            // control it sits alongside.
            Picker("Language", selection: $model.languageID) {
                ForEach(model.languageOptions, id: \.self) { id in
                    Text(model.languageDisplayName(id)).tag(id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("The language for the complete signature — this account's drafting languages (or your content languages when the account has none) from Language Settings")
        }
    }
}

// MARK: - Row reordering

/// Live reorder while dragging: the row moves under the pointer on
/// `dropEntered` rather than only on release, so the list previews the
/// result. The payload is the dragged row's id, but the id is read from
/// `draggingLineID` — the item provider only exists to make the row
/// draggable at all.
private struct SignatureLineDropDelegate: DropDelegate {
    let targetID: UUID
    let model: SignatureStudioModel
    @Binding var draggingLineID: UUID?

    /// Only a live drag of one of our own rows may reorder. Without this,
    /// any external text dragged over a row would reorder whichever row a
    /// previously abandoned drag left behind in `draggingLineID`.
    func validateDrop(info: DropInfo) -> Bool {
        guard let draggingLineID else { return false }
        return model.contact.lines.contains { $0.id == draggingLineID }
    }

    func dropEntered(info: DropInfo) {
        guard let draggingLineID, draggingLineID != targetID else { return }
        let lines = model.contact.lines
        guard let from = lines.firstIndex(where: { $0.id == draggingLineID }),
              let to = lines.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            // `moveLine` takes an onMove-style destination index into the
            // pre-move array, so a downward move targets the slot *after*
            // the row being passed.
            model.contact.moveLine(id: draggingLineID, toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingLineID = nil
        return true
    }

    // Deliberately empty: the pointer leaves a row constantly during a
    // normal drag, and clearing here would cancel the live preview. A drag
    // abandoned outside every row is caught by the form's own drop catcher.
    func dropExited(info: DropInfo) {}
}

/// Catches a drag released anywhere in the form but not on a row — the
/// "Add line" menu, the section header, the gaps between rows. Without it
/// `draggingLineID` stays set, stranding the dragged row at reduced opacity
/// and leaving a stale id primed for the next drag that wanders past.
private struct SignatureLineDragCancelDelegate: DropDelegate {
    @Binding var draggingLineID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggingLineID = nil
        return false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }
}

// MARK: - Image drop well

private struct SignatureImageDropWell: View {
    @Bindable var model: SignatureStudioModel
    @State private var isDropTargeted = false
    @State private var showsFileImporter = false

    var body: some View {
        // Details stack under the well rather than beside it: this section
        // now shares a row with Format, and a horizontal arrangement was
        // too wide for the column.
        VStack(alignment: .leading, spacing: 8) {
            dropTarget
            if model.imageAsset != nil {
                imageDetails
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            importImage(at: url)
        }
    }

    private var dropTarget: some View {
        Button {
            showsFileImporter = true
        } label: {
            VStack(spacing: 4) {
                if model.isImportingImage {
                    ProgressView().controlSize(.small)
                    Text("Reading image")
                        .font(.caption2)
                } else {
                    Image(systemName: "photo.badge.plus")
                    Text(model.imageAsset == nil ? "Drop or choose an image" : "Replace image")
                        .font(.caption2)
                }
            }
            .frame(width: 170, height: 58)
        }
        .buttonStyle(.emblem)
        .disabled(model.isImportingImage)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? OhiaColors.chipActiveForeground : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    importImage(at: url)
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var imageDetails: some View {
        if let asset = model.imageAsset {
            VStack(alignment: .leading, spacing: 6) {
                // "Detected:" leads its own line rather than the picker's:
                // side by side they needed ~306pt, which no longer fits now
                // that this column sits beside Format.
                Text("Detected:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { asset.imageType },
                    set: { model.overrideImageType($0) }
                )) {
                    ForEach(SignatureImageType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                if let suggestion = model.imageSuggestion {
                    Text(suggestion.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Wraps inside the column instead of widening it.
                        .frame(width: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Remove Image") { model.removeImage() }
                    .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                    .font(.caption2)
            }
        }
    }

    private func importImage(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return
        }
        model.importImage(data: data, fileName: url.lastPathComponent)
    }
}
