// Ohia/Composer/ComposerSourcePickerSheets.swift
// Picker sheets for the user-added Composer sources that reach outside the
// mailbox: Apple Notes, Calendar, Contact, and Website. Each presents a small
// selection UI, runs the matching reader in `ComposerSourceProviders`, and
// hands the finished `ComposerSource` back through `onAdd` for the section to
// persist. Styling mirrors `SourceEmailSearchSheet` / `SourceNoteSheet`.

import SwiftUI
import AppKit
import OhiaML

// MARK: - Shared chrome

/// A consistent sheet header: title on the left, a "Done" pill on the right.
private struct SourceSheetHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(OhiaTypography.cardTitle)
                .foregroundStyle(OhiaColors.textPrimary)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
        }
    }
}

/// A centered permission / empty / error message with an optional action.
private struct SourceSheetNotice: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(message)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

enum PrivacySettings {
    static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Apple Notes

struct SourceNotesPickerSheet: View {
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var notes: [AppleNotesSourceReader.NoteRef] = []
    @State private var query = ""
    @State private var addingID: String?

    private struct FolderGroup: Identifiable {
        let id: String
        let folder: String
        let notes: [AppleNotesSourceReader.NoteRef]
    }

    private var filtered: [AppleNotesSourceReader.NoteRef] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.folder.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Filtered notes grouped under their folder, folders sorted alphabetically
    /// and notes sorted by title within each.
    private var groupedFiltered: [FolderGroup] {
        Dictionary(grouping: filtered) { $0.folder.isEmpty ? "Notes" : $0.folder }
            .map { key, value in
                FolderGroup(
                    id: key,
                    folder: key,
                    notes: value.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Apple Notes") { dismiss() }

            switch phase {
            case .loading:
                ProgressView("Reading your notes…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                SourceSheetNotice(
                    symbol: "lock.trianglebadge.exclamationmark",
                    message: "Ohia couldn't read your Notes.\n\(message)",
                    actionTitle: "Try Again",
                    action: { Task { await load() } }
                )
            case .ready:
                TextField("Filter notes by title or folder", text: $query)
                    .textFieldStyle(.plain)
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(8)
                    .background(OhiaColors.surface(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if filtered.isEmpty {
                    SourceSheetNotice(
                        symbol: "note.text",
                        message: notes.isEmpty ? "No notes found in Apple Notes." : "No notes match your filter."
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedFiltered) { group in
                                Section {
                                    ForEach(group.notes) { note in
                                        noteRow(note)
                                    }
                                } header: {
                                    folderHeader(group.folder, count: group.notes.count)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .task { await load() }
    }

    private func folderHeader(_ folder: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(folder)
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
            Text("\(count)")
                .font(OhiaTypography.cardSignal.monospacedDigit())
                .foregroundStyle(OhiaColors.textDim)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OhiaColors.composerPanelBackground)
    }

    private func noteRow(_ note: AppleNotesSourceReader.NoteRef) -> some View {
        Button {
            add(note)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .frame(width: 16)
                Text(note.title)
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if addingID == note.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
            }
            .padding(8)
            .background(OhiaColors.chipRestBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingID != nil)
    }

    private func load() async {
        phase = .loading
        do {
            let fetched = try await Task.detached(priority: .userInitiated) {
                try AppleNotesSourceReader.listNotes()
            }.value
            notes = fetched.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func add(_ note: AppleNotesSourceReader.NoteRef) {
        addingID = note.id
        Task {
            defer { addingID = nil }
            do {
                let html = try await Task.detached(priority: .userInitiated) {
                    try AppleNotesSourceReader.noteBodyHTML(id: note.id)
                }.value
                let text = ComposerHTMLText.plainText(fromHTML: html)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = text.isEmpty ? "(this note has no text)" : String(text.prefix(4000))
                let added = onAdd(ComposerSource(
                    kind: .notesApp,
                    label: note.title,
                    snippet: snippet,
                    isUserAdded: true
                ))
                if added { dismiss() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Calendar

struct SourceCalendarPickerSheet: View {
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        case denied
    }

    private struct PreviewKey: Equatable {
        let id: String
        let start: Date
        let end: Date
    }

    @State private var phase: Phase = .loading
    @State private var calendars: [CalendarSourceReader.CalendarChoice] = []
    @State private var selectedID: String = ""
    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Calendar.current.date(
        byAdding: .day, value: 14, to: Calendar.current.startOfDay(for: Date())
    ) ?? Date()
    @State private var previewLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Calendar") { dismiss() }

            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                SourceSheetNotice(
                    symbol: "calendar.badge.exclamationmark",
                    message: "Calendar access isn't granted. Enable it in System Settings ▸ Privacy & Security ▸ Calendars.",
                    actionTitle: "Open System Settings",
                    action: { PrivacySettings.open("Privacy_Calendars") }
                )
            case .ready:
                readyBody
            }
        }
        .padding(16)
        .frame(width: 470, height: 500)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .task { await load() }
        .onChange(of: PreviewKey(id: selectedID, start: startDate, end: endDate)) { _, _ in
            refreshPreview()
        }
    }

    @ViewBuilder
    private var readyBody: some View {
        if calendars.isEmpty {
            SourceSheetNotice(symbol: "calendar", message: "No calendars were found.")
        } else {
            Picker("Calendar", selection: $selectedID) {
                ForEach(calendars) { calendar in
                    Text(calendar.sourceTitle.isEmpty
                         ? calendar.title
                         : "\(calendar.title) — \(calendar.sourceTitle)")
                        .tag(calendar.id)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            .datePickerStyle(.field)
            .font(OhiaTypography.cardDetail)
            .foregroundStyle(OhiaColors.textSecondary)

            Text(previewLines.isEmpty
                 ? "No events scheduled in this range."
                 : "\(previewLines.count) event\(previewLines.count == 1 ? "" : "s") in range")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(OhiaTypography.cardDetail.monospacedDigit())
                            .foregroundStyle(OhiaColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Add to Sources") { add() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
                    .disabled(selectedID.isEmpty)
            }
        }
    }

    private func load() async {
        phase = .loading
        guard await CalendarSourceReader.requestAccess() else {
            phase = .denied
            return
        }
        calendars = CalendarSourceReader.calendars()
        selectedID = calendars.first?.id ?? ""
        phase = .ready
        refreshPreview()
    }

    private func refreshPreview() {
        guard phase == .ready, !selectedID.isEmpty, startDate <= endDate else {
            previewLines = []
            return
        }
        previewLines = CalendarSourceReader.eventLines(
            calendarID: selectedID,
            from: Calendar.current.startOfDay(for: startDate),
            to: endOfDay(endDate)
        )
    }

    private func add() {
        guard let calendar = calendars.first(where: { $0.id == selectedID }) else { return }
        let range = rangeLabel(startDate, endDate)
        let body = previewLines.isEmpty
            ? "No events scheduled in this range."
            : previewLines.joined(separator: "\n")
        let snippet = "Calendar: \(calendar.title)\nRange: \(range)\n\n\(body)"
        let added = onAdd(ComposerSource(
            kind: .calendar,
            label: "\(calendar.title) · \(range)",
            snippet: snippet,
            isUserAdded: true
        ))
        if added { dismiss() }
    }

    private func endOfDay(_ date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    private func rangeLabel(_ start: Date, _ end: Date) -> String {
        "\(Self.rangeFormatter.string(from: start)) → \(Self.rangeFormatter.string(from: end))"
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Contact

struct SourceContactPickerSheet: View {
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        case denied
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var contacts: [ContactSourceReader.ContactChoice] = []
    @State private var query = ""
    @State private var addingID: String?

    private var filtered: [ContactSourceReader.ContactChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Contacts") { dismiss() }

            switch phase {
            case .loading:
                ProgressView("Reading your contacts…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                SourceSheetNotice(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    message: "Contacts access isn't granted. Enable it in System Settings ▸ Privacy & Security ▸ Contacts, then reopen this.",
                    actionTitle: "Open System Settings",
                    action: { PrivacySettings.open("Privacy_Contacts") }
                )
            case .failed(let message):
                SourceSheetNotice(
                    symbol: "exclamationmark.triangle",
                    message: message,
                    actionTitle: "Try Again",
                    action: { Task { await load() } }
                )
            case .ready:
                readyBody
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .task { await load() }
    }

    @ViewBuilder
    private var readyBody: some View {
        TextField("Filter contacts by name, organization, or email", text: $query)
            .textFieldStyle(.plain)
            .font(OhiaTypography.cardBody)
            .foregroundStyle(OhiaColors.textPrimary)
            .padding(8)
            .background(OhiaColors.surface(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        if filtered.isEmpty {
            SourceSheetNotice(
                symbol: "person.crop.rectangle",
                message: contacts.isEmpty
                    ? "No contacts were found in Contacts."
                    : "No contacts match your filter."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
    }

    private func contactRow(_ contact: ContactSourceReader.ContactChoice) -> some View {
        Button {
            add(contact)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                    if !contact.detail.isEmpty {
                        Text(contact.detail)
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if addingID == contact.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
            }
            .padding(8)
            .background(OhiaColors.chipRestBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingID != nil)
    }

    private func load() async {
        phase = .loading
        guard await ContactSourceReader.requestAccess() else {
            phase = .denied
            return
        }
        contacts = await Task.detached(priority: .userInitiated) {
            ContactSourceReader.allContacts()
        }.value
        phase = .ready
    }

    private func add(_ choice: ContactSourceReader.ContactChoice) {
        addingID = choice.id
        Task {
            defer { addingID = nil }
            let card = await Task.detached(priority: .userInitiated) {
                ContactSourceReader.fullCard(id: choice.id)
            }.value
            guard let card else { return }
            let added = onAdd(ComposerSource(
                kind: .contact,
                label: card.label,
                snippet: card.text,
                isUserAdded: true
            ))
            if added { dismiss() }
        }
    }
}

// MARK: - Messages

/// Resolves the draft's correspondent through Contacts to a 1:1 Messages
/// chat and previews its recent transcript before adding. Defaults straight
/// to that correspondent's preview when `defaultAddress` resolves to one;
/// otherwise (or via "Change"), a searchable contact list — reusing
/// `ContactSourceReader.allContacts()`, the same list `SourceContactPickerSheet`
/// shows — lets the user pick a different contact by hand.
struct SourceMessagesPickerSheet: View {
    let defaultAddress: String?
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.messagesTranscriptBroker) private var messagesTranscriptBroker

    private enum Phase: Equatable {
        case loading
        case deniedContacts
        case deniedFullDiskAccess
        case picking
        case preview
    }

    /// Which broker entry point `refreshPreview` re-runs when
    /// the window controls change — the default-address path never acquired
    /// a Contacts identifier, and the picked-contact path has no address.
    private enum ResolutionSource: Equatable, Sendable {
        case address(String)
        case contactID(String)
    }

    @State private var phase: Phase = .loading
    @State private var contacts: [ContactSourceReader.ContactChoice] = []
    @State private var query = ""
    @State private var resolutionSource: ResolutionSource?
    @State private var selectedName: String?
    @State private var resolution: AutomaticMessagesTranscript?
    @State private var isResolvingPreview = false
    @State private var messageLimit = 200
    @State private var windowDays = 365
    /// Invalidates a stale in-flight resolution: the Steppers can fire
    /// `refreshPreview` again for the *same* contact before an earlier
    /// request finishes, and detached-task completion order isn't
    /// guaranteed to match dispatch order.
    @State private var resolveToken = 0

    private var filtered: [ContactSourceReader.ContactChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Messages") { dismiss() }

            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .deniedContacts:
                SourceSheetNotice(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    message: "Contacts access isn't granted. Ohia matches the correspondent's address to a contact before it can find their Messages chat. Enable it in System Settings ▸ Privacy & Security ▸ Contacts — this updates automatically once granted.",
                    actionTitle: "Open System Settings",
                    action: { PrivacySettings.open("Privacy_Contacts") }
                )
            case .deniedFullDiskAccess:
                SourceSheetNotice(
                    symbol: "lock.trianglebadge.exclamationmark",
                    message: "Full Disk Access isn't granted, so Ohia can't read Messages history. Enable Ohia in System Settings ▸ Privacy & Security ▸ Full Disk Access — this updates automatically once granted.",
                    actionTitle: "Open System Settings",
                    action: { PrivacySettings.open("Privacy_AllFiles") }
                )
            case .picking:
                pickingBody
            case .preview:
                previewBody
            }
        }
        .padding(16)
        .frame(width: 480, height: 500)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .task { await load() }
        .onChange(of: messageLimit) { _, _ in refreshPreview() }
        .onChange(of: windowDays) { _, _ in refreshPreview() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Returning from System Settings after a grant unblocks the
            // sheet automatically rather than requiring a manual close and
            // reopen — but only while actually stuck on a denied state, so
            // an ordinary app-switch doesn't reset an in-progress selection.
            guard phase == .deniedContacts || phase == .deniedFullDiskAccess else { return }
            Task { await load() }
        }
    }

    // MARK: Picking

    @ViewBuilder
    private var pickingBody: some View {
        TextField("Filter contacts by name, organization, or email", text: $query)
            .textFieldStyle(.plain)
            .font(OhiaTypography.cardBody)
            .foregroundStyle(OhiaColors.textPrimary)
            .padding(8)
            .background(OhiaColors.surface(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        if filtered.isEmpty {
            SourceSheetNotice(
                symbol: "person.crop.rectangle",
                message: contacts.isEmpty
                    ? "No contacts were found in Contacts."
                    : "No contacts match your filter."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
    }

    private func contactRow(_ contact: ContactSourceReader.ContactChoice) -> some View {
        Button {
            select(contactID: contact.id, name: contact.displayName)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName)
                        .font(OhiaTypography.cardBody)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                    if !contact.detail.isEmpty {
                        Text(contact.detail)
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(OhiaColors.chipRestBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Preview

    @ViewBuilder
    private var previewBody: some View {
        HStack {
            Text(selectedName ?? "")
                .font(OhiaTypography.cardBody.weight(.semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Change") {
                phase = .picking
                resolution = nil
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
        }

        Stepper("Up to \(messageLimit) messages", value: $messageLimit, in: 10...200, step: 10)
            .font(OhiaTypography.cardDetail)
            .foregroundStyle(OhiaColors.textSecondary)
        Stepper("From the last \(windowDays) days", value: $windowDays, in: 7...365, step: 7)
            .font(OhiaTypography.cardDetail)
            .foregroundStyle(OhiaColors.textSecondary)

        if isResolvingPreview {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let resolution, !resolution.lines.isEmpty {
            Text("\(resolution.lines.count) message\(resolution.lines.count == 1 ? "" : "s") with \(resolution.correspondentName)")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(resolution.formattedLines().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(OhiaTypography.cardDetail)
                            .foregroundStyle(OhiaColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            SourceSheetNotice(
                symbol: "message",
                message: "No Messages chat was found for \(selectedName ?? "this contact") in this window."
            )
        }

        HStack {
            Spacer()
            Button("Add to Sources") { add() }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
                .disabled(resolution?.lines.isEmpty ?? true)
        }
    }

    // MARK: Actions

    private func select(contactID: String, name: String) {
        selectedName = name
        resolutionSource = .contactID(contactID)
        phase = .preview
        refreshPreview()
    }

    private func refreshPreview() {
        guard let resolutionSource else { return }
        isResolvingPreview = true
        resolveToken += 1
        let token = resolveToken
        let limit = messageLimit
        let maxAge = TimeInterval(windowDays) * 24 * 60 * 60
        Task {
            let result: AutomaticMessagesResult
            if let messagesTranscriptBroker {
                switch resolutionSource {
                case .address(let address):
                    result = await messagesTranscriptBroker.transcript(
                        forAddress: address,
                        limit: limit,
                        maxAge: maxAge
                    )
                case .contactID(let contactID):
                    result = await messagesTranscriptBroker.transcript(
                        forContactID: contactID,
                        limit: limit,
                        maxAge: maxAge
                    )
                }
            } else {
                result = .unavailable
            }
            // Discards this result if a newer refreshPreview call (a
            // different contact, or the same contact with different Stepper
            // values) has since started — not just a changed contact, since
            // detached-task completion order doesn't track dispatch order.
            guard token == resolveToken else { return }
            if case .found(let transcript) = result {
                resolution = transcript
                selectedName = transcript.correspondentName
            } else {
                resolution = nil
                if result == .contactResolvedDatabaseUnavailable || result == .unavailable {
                    phase = .deniedFullDiskAccess
                }
            }
            isResolvingPreview = false
        }
    }

    private func add() {
        guard let resolution, !resolution.lines.isEmpty else { return }
        let added = onAdd(ComposerSource(
            kind: .messages,
            label: "Messages with \(resolution.correspondentName)",
            snippet: resolution.formattedTranscript(),
            isUserAdded: true
        ))
        if added { dismiss() }
    }

    private func load() async {
        phase = .loading
        guard await ContactSourceReader.requestAccess() else {
            phase = .deniedContacts
            return
        }
        guard let messagesTranscriptBroker,
              await messagesTranscriptBroker.accessStatus() else {
            phase = .deniedFullDiskAccess
            return
        }
        contacts = await Task.detached(priority: .userInitiated) {
            ContactSourceReader.allContacts()
        }.value

        if let defaultAddress, !defaultAddress.isEmpty {
            resolutionSource = .address(defaultAddress)
            selectedName = nil
            phase = .preview
            refreshPreview()
        } else {
            phase = .picking
        }
    }
}

// MARK: - Website

struct SourceWebsitePasteSheet: View {
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var includeLinkedPages = false
    @State private var isFetching = false
    @State private var errorText: String?
    @State private var addedTitles: [String] = []

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Website") { dismiss() }

            Text("Paste a link. Ohia fetches and cleans the page before adding it as a source.")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://example.com/article", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(8)
                    .background(OhiaColors.surface(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit { fetch() }
                    .disabled(isFetching)
                Button("Add") { fetch() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
                    .disabled(isFetching || trimmedURL.isEmpty)
            }

            Toggle("Include directly linked pages", isOn: $includeLinkedPages)
                .toggleStyle(.checkbox)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
                .disabled(isFetching)

            if isFetching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(includeLinkedPages ? "Crawling pages" : "Fetching page")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !addedTitles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Added")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textTertiary)
                    ForEach(Array(addedTitles.enumerated()), id: \.offset) { _, title in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(OhiaColors.chipActiveForeground)
                            Text(title)
                                .font(OhiaTypography.cardDetail)
                                .foregroundStyle(OhiaColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 480, height: 360)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
    }

    private func fetch() {
        let input = trimmedURL
        guard !input.isEmpty, !isFetching else { return }
        isFetching = true
        errorText = nil
        Task {
            defer { isFetching = false }
            do {
                let source = try await WebsiteSourceFetcher.fetch(
                    input,
                    includeLinkedPages: includeLinkedPages
                )
                if onAdd(source) {
                    addedTitles.append(source.label)
                    urlText = ""
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Screenshot

struct SourceScreenshotPickerSheet: View {
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        case denied
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var targets = ScreenCaptureService.Targets(displays: [], windows: [])
    @State private var capturingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: "Screenshot") { dismiss() }

            switch phase {
            case .loading:
                ProgressView("Finding screens & windows…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                deniedView
            case .failed(let message):
                SourceSheetNotice(
                    symbol: "exclamationmark.triangle",
                    message: message,
                    actionTitle: "Try Again",
                    action: { Task { await load() } }
                )
            case .ready:
                readyBody
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .task { await load() }
    }

    @ViewBuilder
    private var readyBody: some View {
        if targets.displays.isEmpty && targets.windows.isEmpty {
            SourceSheetNotice(
                symbol: "rectangle.on.rectangle",
                message: "No capturable screens or windows were found."
            )
        } else {
            Text("Capture an entire screen or window — its on-screen text is recognized and added as context.")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    if !targets.displays.isEmpty {
                        Section {
                            ForEach(targets.displays) { displayRow($0) }
                        } header: {
                            sectionHeader("Screens")
                        }
                    }
                    if !targets.windows.isEmpty {
                        Section {
                            ForEach(targets.windows) { windowRow($0) }
                        } header: {
                            sectionHeader("Windows")
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(OhiaColors.textTertiary)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OhiaColors.composerPanelBackground)
    }

    private func displayRow(_ target: ScreenCaptureService.DisplayTarget) -> some View {
        let rowID = "d:\(target.displayID)"
        return Button {
            performCapture(rowID: rowID, label: "Screenshot · \(target.name)") {
                try await ScreenCaptureService.captureDisplayText(displayID: target.displayID)
            }
        } label: {
            rowContent(icon: Image(systemName: "display"), tintIcon: true, title: target.name, rowID: rowID)
        }
        .buttonStyle(.plain)
        .disabled(capturingID != nil)
    }

    private func windowRow(_ target: ScreenCaptureService.WindowTarget) -> some View {
        let rowID = "w:\(target.windowID)"
        let icon: Image
        let tint: Bool
        if let data = target.iconPNG, let nsImage = NSImage(data: data) {
            icon = Image(nsImage: nsImage)
            tint = false
        } else {
            icon = Image(systemName: "macwindow")
            tint = true
        }
        return Button {
            performCapture(rowID: rowID, label: "Screenshot · \(target.title)") {
                try await ScreenCaptureService.captureWindowText(windowID: target.windowID)
            }
        } label: {
            rowContent(icon: icon, tintIcon: tint, title: target.title, rowID: rowID)
        }
        .buttonStyle(.plain)
        .disabled(capturingID != nil)
    }

    private func rowContent(icon: Image, tintIcon: Bool, title: String, rowID: String) -> some View {
        HStack(spacing: 8) {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .foregroundStyle(tintIcon ? OhiaColors.iconPillForeground : Color.primary)
            Text(title)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(1)
            Spacer()
            if capturingID == rowID {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "camera")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(OhiaColors.textTertiary)
            Text("Ohia needs Screen Recording permission to list and capture your screens and windows. Grant it in System Settings, then reopen this — macOS may require relaunching Ohia for the change to take effect.")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Request Access") {
                    _ = ScreenCaptureService.requestAccess()
                    Task { await load() }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
                Button("Open System Settings") {
                    PrivacySettings.open("Privacy_ScreenCapture")
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func load() async {
        phase = .loading
        guard ScreenCaptureService.isAuthorized else {
            phase = .denied
            return
        }
        do {
            targets = try await ScreenCaptureService.enumerateTargets()
            phase = .ready
        } catch ScreenCaptureService.CaptureError.notAuthorized {
            phase = .denied
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func performCapture(
        rowID: String,
        label: String,
        _ op: @escaping () async throws -> String
    ) {
        guard capturingID == nil else { return }
        capturingID = rowID
        Task {
            defer { capturingID = nil }
            do {
                let text = try await op()
                let added = onAdd(ComposerSource(
                    kind: .screenshot,
                    label: label,
                    snippet: text,
                    isUserAdded: true
                ))
                if added { dismiss() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - MCP server tools

/// Generic picker for one configured MCP server: connects lazily, lists the
/// server's tools, renders a form from the chosen tool's schema (primitive
/// parameters only), runs it, and offers the text result as a source. Works
/// identically for preconfigured connectors and user-added custom servers.
struct SourceMCPPickerSheet: View {
    let server: MCPConfiguredServer
    let onAdd: (ComposerSource) -> Bool

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case connecting
        case failed(String)
        case tools
        case form(MCPToolDescriptor)
        case running(MCPToolDescriptor)
        case result(MCPToolDescriptor, String)
    }

    @State private var phase: Phase = .connecting
    @State private var tools: [MCPToolDescriptor] = []
    /// Invalidates in-flight run completions after a cancel.
    @State private var runToken = 0
    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var formError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceSheetHeader(title: server.displayName) { dismiss() }
            content
        }
        .padding(16)
        .frame(width: 480, height: 500)
        .composerPresentationFrame()
        .tint(OhiaColors.chipActiveForeground)
        .task { await connect() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .connecting:
            ProgressView("Connecting to \(server.displayName)…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            SourceSheetNotice(
                symbol: "server.rack",
                message: "Ohia couldn't reach this MCP server.\n\(message)",
                actionTitle: "Try Again",
                action: {
                    phase = .connecting
                    Task {
                        await MCPSessionManager.shared.invalidate(id: server.id)
                        await connect()
                    }
                }
            )
        case .tools:
            toolList
        case .form(let tool):
            toolForm(tool)
        case .running(let tool):
            VStack(spacing: 12) {
                ProgressView("Running \(tool.displayName)…")
                    .controlSize(.small)
                Button("Cancel") {
                    // Drop the in-flight completion and disconnect the
                    // session; the next run reconnects fresh.
                    runToken += 1
                    let id = server.id
                    Task { await MCPSessionManager.shared.invalidate(id: id) }
                    formError = nil
                    phase = .form(tool)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .result(let tool, let text):
            resultView(tool: tool, text: text)
        }
    }

    // MARK: Tool list

    @ViewBuilder
    private var toolList: some View {
        if tools.isEmpty {
            SourceSheetNotice(
                symbol: "wrench.and.screwdriver",
                message: "The server connected but offers no tools."
            )
        } else {
            Text("Pick a tool; its result becomes a source the reply can draw on.")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textTertiary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { tool in
                        toolRow(tool)
                    }
                }
            }
        }
    }

    private func toolRow(_ tool: MCPToolDescriptor) -> some View {
        Button {
            prepareForm(for: tool)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.displayName)
                        .font(OhiaTypography.cardBody.weight(.semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                    if tool.isReadOnly {
                        Text("read-only")
                            .font(OhiaTypography.cardSignal)
                            .foregroundStyle(OhiaColors.chipActiveForeground)
                    }
                    Spacer()
                }
                if let detail = tool.detail, !detail.isEmpty {
                    Text(detail)
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .lineLimit(2)
                }
                if tool.hasUnsupportedRequiredParameters {
                    Text("Needs structured input Ohia can't collect yet")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OhiaColors.surface(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(tool.hasUnsupportedRequiredParameters)
        .opacity(tool.hasUnsupportedRequiredParameters ? 0.5 : 1)
    }

    // MARK: Form

    private func prepareForm(for tool: MCPToolDescriptor) {
        textValues = [:]
        boolValues = [:]
        formError = nil
        for parameter in tool.parameters where parameter.kind == .boolean {
            boolValues[parameter.name] = false
        }
        phase = .form(tool)
    }

    private func toolForm(_ tool: MCPToolDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if tool.parameters.isEmpty {
                Text("\(tool.displayName) takes no input.")
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tool.parameters) { parameter in
                            parameterField(parameter)
                        }
                    }
                }
            }

            if let formError {
                Text(formError)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back") { phase = .tools }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                Spacer()
                Button("Run") { run(tool) }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 4))
                    .disabled(!requiredFieldsFilled(tool))
            }
        }
    }

    private func parameterField(_ parameter: MCPToolParameter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(parameter.name)
                    .font(OhiaTypography.cardDetail.weight(.semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                if parameter.isRequired {
                    Text("required")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            if let detail = parameter.detail, !detail.isEmpty {
                Text(detail)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(2)
            }
            switch parameter.kind {
            case .boolean:
                Toggle(parameter.name, isOn: Binding(
                    get: { boolValues[parameter.name] ?? false },
                    set: { boolValues[parameter.name] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            case .string, .number, .integer:
                TextField(placeholder(for: parameter), text: Binding(
                    get: { textValues[parameter.name] ?? "" },
                    set: { textValues[parameter.name] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(6)
                .background(OhiaColors.surface(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func placeholder(for parameter: MCPToolParameter) -> String {
        switch parameter.kind {
        case .number:  return "A number"
        case .integer: return "A whole number"
        default:       return "Text"
        }
    }

    private func requiredFieldsFilled(_ tool: MCPToolDescriptor) -> Bool {
        tool.parameters.filter(\.isRequired).allSatisfy { parameter in
            switch parameter.kind {
            case .boolean:
                return true
            default:
                return !(textValues[parameter.name] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    // MARK: Run

    private func run(_ tool: MCPToolDescriptor) {
        guard let arguments = buildArguments(for: tool) else { return }
        formError = nil
        phase = .running(tool)
        runToken += 1
        let token = runToken
        Task {
            do {
                let session = try await Self.session(for: server)
                let text = try await session.callTool(name: tool.name, arguments: arguments)
                guard token == runToken else { return }
                if text.isEmpty {
                    formError = "The tool returned no content."
                    phase = .form(tool)
                } else {
                    phase = .result(tool, text)
                }
            } catch {
                guard token == runToken else { return }
                formError = error.localizedDescription
                phase = .form(tool)
            }
        }
    }

    /// The manager returns the live session, or a fresh one after an edit,
    /// credential rotation, or cancel-invalidation.
    private static func session(
        for server: MCPConfiguredServer
    ) async throws -> any MCPToolCalling {
        let environment: [String: String]
        if server.usesHostedOAuth {
            environment = try await HostedMCPAuth.resolvedMCPEnvironment(
                serverID: server.id,
                service: server.service
            )
        } else {
            environment = (try? KeychainMCPServerSecretsStore()
                .environment(for: server.id)) ?? [:]
        }
        return await MCPSessionManager.shared.session(for: server, environment: environment)
    }

    private func buildArguments(for tool: MCPToolDescriptor) -> [String: MCPToolArgument]? {
        var arguments: [String: MCPToolArgument] = [:]
        for parameter in tool.parameters {
            switch parameter.kind {
            case .boolean:
                arguments[parameter.name] = .boolean(boolValues[parameter.name] ?? false)
            case .string:
                let text = (textValues[parameter.name] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { arguments[parameter.name] = .string(text) }
            case .number:
                let text = (textValues[parameter.name] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let value = Double(text) else {
                    formError = "\(parameter.name) needs a number."
                    return nil
                }
                arguments[parameter.name] = .number(value)
            case .integer:
                let text = (textValues[parameter.name] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let value = Int(text) else {
                    formError = "\(parameter.name) needs a whole number."
                    return nil
                }
                arguments[parameter.name] = .integer(value)
            }
        }
        return arguments
    }

    // MARK: Result

    private func resultView(tool: MCPToolDescriptor, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(tool.displayName) result")
                .font(OhiaTypography.cardDetail.weight(.semibold))
                .foregroundStyle(OhiaColors.textPrimary)
            ScrollView {
                Text(text)
                    .font(OhiaTypography.cardBody)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(OhiaColors.surface(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Back") { phase = .form(tool) }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                Spacer()
                Button("Add Source") {
                    let added = onAdd(ComposerSource(
                        kind: .mcp,
                        label: "\(server.displayName) · \(tool.displayName)",
                        snippet: String(text.prefix(4000)),
                        isUserAdded: true
                    ))
                    if added { dismiss() }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 4))
            }
        }
    }

    // MARK: Connect

    private func connect() async {
        do {
            let liveSession = try await Self.session(for: server)
            let discovered = try await liveSession.availableTools()
            tools = discovered.sorted { $0.displayName < $1.displayName }
            phase = .tools
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
