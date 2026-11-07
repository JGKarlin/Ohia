// Ohia/Settings/NotesAutomationPermission.swift
// Automation (Apple Events) permission for reading Apple Notes, surfaced in
// Settings → Sources. `AppleNotesSourceReader` drives Notes via AppleScript;
// macOS gates that behind a per-target Automation consent this helper queries
// (`AEDeterminePermissionToAutomateTarget`, macOS 10.14+) and requests.
//
// The determination API needs the target process running: when Notes is not
// running the status is `.notesNotRunning` (indeterminate), and a request
// launches Notes in the background first so the consent prompt has a target.

import AppKit
import CoreServices
import Foundation

enum NotesAutomationPermission {

    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        /// Notes isn't running, so macOS can't report the consent state.
        case notesNotRunning
    }

    static let notesBundleID = "com.apple.Notes"

    // MacErrors.h codes `AEDeterminePermissionToAutomateTarget` returns.
    private static let errEventNotPermitted: OSStatus = -1743
    private static let errWouldRequireConsent: OSStatus = -1744
    private static let errProcNotFound: OSStatus = -600

    /// Current consent state, without prompting.
    static func status() -> Status {
        status(askingIfNeeded: false)
    }

    /// Requests consent: launches Notes in the background when needed, then
    /// asks macOS to put up the Automation prompt. Returns the final state.
    @MainActor
    static func requestAccess() async -> Status {
        if !isNotesRunning {
            guard await launchNotesInBackground() else { return .notesNotRunning }
        }
        // The consent prompt blocks the calling thread until answered —
        // keep it off the main actor.
        return await Task.detached(priority: .userInitiated) {
            status(askingIfNeeded: true)
        }.value
    }

    /// Reveals the Automation pane so a denied grant can be flipped by hand.
    @MainActor
    static func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private static func status(askingIfNeeded: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
        // `aeDesc` is only valid while the descriptor lives; without the
        // extended lifetime ARC may release `target` before (or during) the
        // C call, which can block for minutes on the consent dialog.
        let code = withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                askingIfNeeded
            )
        }
        switch code {
        case noErr:
            return .granted
        case errEventNotPermitted:
            return .denied
        case errWouldRequireConsent:
            return .notDetermined
        case errProcNotFound:
            return .notesNotRunning
        default:
            // Unexpected AE plumbing failure — treat as unasked rather than
            // claiming a grant or denial that macOS didn't report.
            return .notDetermined
        }
    }

    private static var isNotesRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty
    }

    @MainActor
    private static func launchNotesInBackground() async -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: notesBundleID
        ) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
