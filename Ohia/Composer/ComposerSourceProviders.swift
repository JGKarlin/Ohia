// Ohia/Composer/ComposerSourceProviders.swift
// Backend readers for the user-added Composer sources that reach outside the
// mailbox: Calendar (EventKit), Contacts, Apple Notes (AppleScript), Website
// (shared WebRAGCrawler ingestion), and Screenshot (interactive capture → the
// same Vision evidence extraction the app runs on image attachments).
//
// Each reader returns Sendable value types; the non-Sendable system objects
// (EKEventStore, CNContactStore, NSAppleScript) never cross an isolation
// boundary. The two stores that must stay on one actor are pinned to
// @MainActor; AppleScript / URLSession / screencapture work runs off-main and
// only hands back Strings/Data.

import Foundation
import AppKit
import EventKit
import Contacts
import ScreenCaptureKit
import OhiaIngest
import OhiaML

// MARK: - Shared HTML → plain text

/// NSAttributedString's HTML importer is documented main-thread-only (it spins
/// up a WebKit parser), so every HTML→text conversion routes through here on
/// the MainActor. Used by the Apple Notes reader, whose bodies are HTML.
@MainActor
enum ComposerHTMLText {
    static func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        return plainText(fromHTMLData: data) ?? html
    }

    static func plainText(fromHTMLData data: Data) -> String? {
        try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ).string
    }
}

// MARK: - Calendar (EventKit)

/// Lists the user's calendars and pulls events within a date range as labeled
/// lines. `EKEventStore` / `EKEvent` / `EKCalendar` are not Sendable, so the
/// reader is pinned to the MainActor and only ever returns value types.
@MainActor
enum CalendarSourceReader {
    private static let store = EKEventStore()

    struct CalendarChoice: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let sourceTitle: String
        /// sRGB components (0–1) for the calendar's dot, when resolvable.
        let colorComponents: [Double]?
    }

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    /// Requests full calendar access if not already granted. Returns whether
    /// access is usable afterward.
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    static func calendars() -> [CalendarChoice] {
        store.calendars(for: .event)
            .map { calendar in
                CalendarChoice(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    colorComponents: components(from: calendar.cgColor)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sourceTitle != rhs.sourceTitle {
                    return lhs.sourceTitle.localizedStandardCompare(rhs.sourceTitle) == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// Formatted event lines for one calendar within `[from, to]`, soonest
    /// first. Empty when access is missing, the calendar is gone, or the window
    /// holds no events.
    static func eventLines(calendarID: String, from: Date, to: Date) -> [String] {
        guard isAuthorized,
              from <= to,
              let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map(line(for:))
    }

    private static func line(for event: EKEvent) -> String {
        let title = (event.title?.isEmpty == false) ? event.title! : "(no title)"
        // `startDate`/`endDate` are implicitly-unwrapped optionals in EventKit
        // and can be nil for malformed events — passing nil to the formatter
        // would crash, so guard before formatting.
        guard let start = event.startDate else { return title }
        let when: String
        if event.isAllDay {
            when = "\(dayFormatter.string(from: start)) (all day)"
        } else {
            let end = event.endDate ?? start
            when = "\(dayTimeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
        }
        var text = "\(when)  \(title)"
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            text += " @ \(location)"
        }
        return text
    }

    private static func components(from cgColor: CGColor?) -> [Double]? {
        guard let cgColor else { return nil }
        let target = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let converted = cgColor.converted(to: target, intent: .defaultIntent, options: nil) ?? cgColor
        guard let comps = converted.components, comps.count >= 3 else { return nil }
        return comps.prefix(3).map { Double($0) }
    }

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d  HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

// MARK: - Contacts

/// Lists Contacts and renders a selected contact's entire card as text.
/// `CNContactStore` fetches are thread-safe, so the reader is nonisolated and
/// the (potentially large) enumeration runs off-main; only Sendable value
/// types leave. The card deliberately omits the note field, which requires the
/// `com.apple.developer.contacts.notes` entitlement the app does not carry —
/// requesting it would make the fetch throw.
enum ContactSourceReader {

    struct ContactChoice: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let detail: String
    }

    nonisolated static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Both a full grant and a macOS 15+ limited (partial-access) grant can read
    /// the contacts they cover, so both count as usable. Treating only
    /// `.authorized` as usable was why a limited grant showed no contacts.
    nonisolated static var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .limited: return true
        default: return false
        }
    }

    nonisolated static var isDenied: Bool {
        switch authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let store = CNContactStore()
        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static var listKeys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
    }

    /// Every accessible contact as a lightweight choice, sorted by name. Run
    /// from a detached task — enumeration can take a moment on large address
    /// books. The sheet filters this list in memory.
    nonisolated static func allContacts(limit: Int = 5000) -> [ContactChoice] {
        guard isAuthorized else { return [] }
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: listKeys)
        request.sortOrder = .userDefault
        var out: [ContactChoice] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                out.append(choice(from: contact))
                if out.count >= limit { stop.pointee = true }
            }
        } catch {
            return []
        }
        return out.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    nonisolated private static func choice(from contact: CNContact) -> ContactChoice {
        let name = CNContactFormatter.string(from: contact, style: .fullName)
            ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        let detail = !contact.organizationName.isEmpty
            ? contact.organizationName
            : (contact.emailAddresses.first.map { $0.value as String } ?? "")
        return ContactChoice(
            id: contact.identifier,
            displayName: name.isEmpty ? "(no name)" : name,
            detail: detail
        )
    }

    private static var cardKeys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
        ]
    }

    /// The full contact card as labeled text, plus a short display label.
    /// `nil` when the contact can't be fetched.
    nonisolated static func fullCard(id: String) -> (label: String, text: String)? {
        guard isAuthorized else { return nil }
        let store = CNContactStore()
        guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: cardKeys) else {
            return nil
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none
        let name = CNContactFormatter.string(from: contact, style: .fullName)
            ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        var lines: [String] = []

        if !name.isEmpty { lines.append("Name: \(name)") }
        if !contact.nickname.isEmpty { lines.append("Nickname: \(contact.nickname)") }

        var orgParts: [String] = []
        if !contact.jobTitle.isEmpty { orgParts.append(contact.jobTitle) }
        if !contact.departmentName.isEmpty { orgParts.append(contact.departmentName) }
        if !contact.organizationName.isEmpty { orgParts.append(contact.organizationName) }
        if !orgParts.isEmpty { lines.append("Organization: \(orgParts.joined(separator: ", "))") }

        appendLabeled(contact.emailAddresses, heading: "Emails", to: &lines) { $0 as String }
        appendLabeled(contact.phoneNumbers, heading: "Phones", to: &lines) { $0.stringValue }
        appendLabeled(contact.postalAddresses, heading: "Addresses", to: &lines) {
            CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
        }
        appendLabeled(contact.urlAddresses, heading: "URLs", to: &lines) { $0 as String }
        appendLabeled(contact.socialProfiles, heading: "Social", to: &lines) {
            [$0.service, $0.username].filter { !$0.isEmpty }.joined(separator: " ")
        }
        appendLabeled(contact.instantMessageAddresses, heading: "Messaging", to: &lines) {
            [$0.service, $0.username].filter { !$0.isEmpty }.joined(separator: " ")
        }

        if let birthday = contact.birthday, let date = Calendar.current.date(from: birthday) {
            lines.append("Birthday: \(dateFormatter.string(from: date))")
        }
        for dated in contact.dates {
            guard let date = Calendar.current.date(from: dated.value as DateComponents) else { continue }
            let label = localizedLabel(dated.label)
            lines.append("\(label.isEmpty ? "Date" : label): \(dateFormatter.string(from: date))")
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (label: name.isEmpty ? "Contact" : name, text: text)
    }

    nonisolated private static func appendLabeled<Value: NSCopying & NSSecureCoding>(
        _ values: [CNLabeledValue<Value>],
        heading: String,
        to lines: inout [String],
        render: (Value) -> String
    ) {
        let rendered = values.compactMap { labeled -> String? in
            let value = render(labeled.value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let label = localizedLabel(labeled.label)
            return label.isEmpty ? "  \(value)" : "  \(label): \(value)"
        }
        guard !rendered.isEmpty else { return }
        lines.append("\(heading):")
        lines.append(contentsOf: rendered)
    }

    nonisolated private static func localizedLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}

// MARK: - Apple Notes (AppleScript)

/// Reads the user's Apple Notes via AppleScript: an enumeration of note
/// id/title/folder, and the HTML body of a chosen note. Mirrors the codebase's
/// existing NSAppleScript executor pattern (MailAppSMTPReader): the script runs
/// synchronously off the MainActor and only a `String` ever leaves the call, so
/// the non-Sendable NSAppleScript instance never crosses an isolation boundary.
enum AppleNotesSourceReader {
    struct NoteRef: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let folder: String
    }

    enum NotesError: LocalizedError {
        case scriptUnavailable
        case execution(String)

        var errorDescription: String? {
            switch self {
            case .scriptUnavailable: return "Could not build the Notes query."
            case .execution(let message): return message
            }
        }
    }

    // The three parallel id/title/folder blocks are separated by this record
    // separator; within each block the list items are linefeed-joined (note
    // titles and folder names never contain newlines). Internal (not private)
    // so the pure `parse` can be unit-tested.
    static let recordSeparator = "\u{1E}"
    static let lineSeparator = "\n"

    /// Every note as id/title/folder. Uses bulk property access — three Apple
    /// Events fetch parallel lists for the whole library and join them natively
    /// via `text item delimiters` — instead of per-note property access inside a
    /// `repeat`, which would issue ~3 Apple Events per note (orders of magnitude
    /// slower). Call from a detached task.
    nonisolated static func listNotes() throws -> [NoteRef] {
        let source = """
        tell application "Notes"
            set recordSep to (ASCII character 30)
            set theIDs to id of every note
            set theNames to name of every note
            set theFolders to name of container of every note
            set savedDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to (ASCII character 10)
            set idBlock to theIDs as text
            set nameBlock to theNames as text
            set folderBlock to theFolders as text
            set AppleScript's text item delimiters to savedDelimiters
            return idBlock & recordSep & nameBlock & recordSep & folderBlock
        end tell
        """
        return parse(try run(source))
    }

    /// The selected note's body, as HTML (caller strips to text on the
    /// MainActor via `ComposerHTMLText`).
    nonisolated static func noteBodyHTML(id: String) throws -> String {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Notes"
            return body of note id "\(escaped)"
        end tell
        """
        return try run(source)
    }

    nonisolated private static func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.scriptUnavailable
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? (errorInfo["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "Notes automation was blocked or failed."
            throw NotesError.execution(message)
        }
        return descriptor.stringValue ?? ""
    }

    // Internal (not private) so the index-zip edge cases can be unit-tested
    // without driving AppleScript.
    nonisolated static func parse(_ raw: String) -> [NoteRef] {
        let blocks = raw.components(separatedBy: recordSeparator)
        guard blocks.count == 3 else { return [] }
        let ids = blocks[0].components(separatedBy: lineSeparator)
        let names = blocks[1].components(separatedBy: lineSeparator)
        let folders = blocks[2].components(separatedBy: lineSeparator)

        var result: [NoteRef] = []
        result.reserveCapacity(ids.count)
        for (index, rawID) in ids.enumerated() {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let title = index < names.count
                ? names[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let folder = index < folders.count
                ? folders[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            result.append(NoteRef(
                id: id,
                title: title.isEmpty ? "(untitled note)" : title,
                folder: folder
            ))
        }
        return result
    }
}

// MARK: - Website

/// Fetches a pasted URL through the shared WebRAG crawler and returns a
/// Markdown-backed Composer source. The default path crawls only the supplied
/// page; the sheet can opt into one directly linked level.
enum WebsiteSourceFetcher {
    static func fetch(
        _ input: String,
        includeLinkedPages: Bool = false
    ) async throws -> ComposerSource {
        let config: WebRAGConfig = includeLinkedPages
            ? .composerManualLinkedPages
            : .composerManualSinglePage
        let document = try await WebRAGCrawler().crawl(input: input, config: config)
        return ComposerSource.website(from: document, isUserAdded: true)
    }
}

// MARK: - Screenshot (ScreenCaptureKit)

/// Lists capturable screens and windows and captures a chosen one whole — no
/// interactive region drag — then runs the image through the same Vision text
/// extraction the app applies to image attachments. The image itself is never
/// attached to the email; only its recognized content becomes draft context.
/// Pinned to the MainActor because the ScreenCaptureKit objects and AppKit
/// helpers (NSScreen / NSRunningApplication / NSBitmapImageRep) are not Sendable
/// — only value types (Sendable `Target`s, `Data`, `String`) leave.
@MainActor
enum ScreenCaptureService {

    struct DisplayTarget: Identifiable, Hashable, Sendable {
        let displayID: CGDirectDisplayID
        let name: String
        var id: CGDirectDisplayID { displayID }
    }

    struct WindowTarget: Identifiable, Hashable, Sendable {
        let windowID: CGWindowID
        let title: String
        let appName: String
        let iconPNG: Data?
        var id: CGWindowID { windowID }
    }

    struct Targets: Sendable {
        var displays: [DisplayTarget]
        var windows: [WindowTarget]
    }

    enum CaptureError: LocalizedError {
        case notAuthorized
        case targetUnavailable
        case captureFailed(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Screen Recording permission is needed to list and capture screens and windows."
            case .targetUnavailable:
                return "That screen or window is no longer available."
            case .captureFailed(let message):
                return message
            case .noContent:
                return "No text or recognizable content was found in the screenshot."
            }
        }
    }

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording access the first time. After a grant macOS
    /// may not surface capture to the already-running process until relaunch, so
    /// callers should still handle a subsequent `.notAuthorized`.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func enumerateTargets() async throws -> Targets {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notAuthorized }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.notAuthorized
        }

        let displays = content.displays.map { display in
            DisplayTarget(displayID: display.displayID, name: Self.displayName(for: display.displayID))
        }

        // Exclude Ohia's own windows — capturing the picker sheet (or the
        // Composer hosting it) would just screenshot Ohia's own chrome and leak
        // its UI text into the draft. The user captures other apps / the desktop.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows
            .filter { window in
                window.isOnScreen
                    && window.windowLayer == 0
                    && (window.title?.isEmpty == false)
                    && window.frame.width >= 80
                    && window.frame.height >= 80
                    && window.owningApplication?.processID != ownPID
            }
            .compactMap { window -> WindowTarget? in
                guard let title = window.title, !title.isEmpty else { return nil }
                let app = window.owningApplication
                return WindowTarget(
                    windowID: window.windowID,
                    title: title,
                    appName: app?.applicationName ?? "",
                    iconPNG: app.flatMap { Self.appIconPNG(pid: $0.processID) }
                )
            }
            .sorted { lhs, rhs in
                if lhs.appName != rhs.appName {
                    return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        return Targets(displays: displays, windows: windows)
    }

    /// Captures the given window whole and returns its recognized text.
    static func captureWindowText(windowID: CGWindowID) async throws -> String {
        let data = try await capturePNG { content in
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.targetUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        return try await recognizeText(in: data)
    }

    /// Captures the given display whole and returns its recognized text.
    static func captureDisplayText(displayID: CGDirectDisplayID) async throws -> String {
        let data = try await capturePNG { content in
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetUnavailable
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }
        return try await recognizeText(in: data)
    }

    private static func capturePNG(
        _ makeFilter: (SCShareableContent) throws -> SCContentFilter
    ) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notAuthorized }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try makeFilter(content)

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
        guard let data = Self.pngData(from: cgImage) else {
            throw CaptureError.captureFailed("The screenshot could not be encoded.")
        }
        return data
    }

    private static func recognizeText(in pngData: Data) async throws -> String {
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            ((try? AttachmentExtractor.extractText(
                data: pngData,
                mimeType: "image/png",
                filename: "screenshot.png"
            )) ?? nil) ?? ""
        }.value
        let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { throw CaptureError.noContent }
        return String(snippet.prefix(4000))
    }

    // MARK: - Helpers

    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return "Display"
    }

    private static func appIconPNG(pid: pid_t) -> Data? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon,
              let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
