import AppKit
import Darwin
import Foundation
import OhiaUninstallKit
import os
import Synchronization

/// Moves the uninstaller out of the folders it deletes. Started from Ohia's
/// menu it runs from Ohia.app/Contents/Helpers, which the uninstall removes,
/// so before any window appears it copies itself into a fresh folder in its
/// own temporary directory (outside every deletion target), clears the
/// copy's quarantine, opens the copy and exits. If the copy fails, or Launch
/// Services refuses to open it, it keeps running in place; if Launch Services
/// never answers, it exits anyway, since the copy may still start.
enum UninstallerRelauncher {
    static let openTimeout: DispatchTimeInterval = .seconds(60)

    // Logs carry error domains and codes only: no paths (which name the home
    // folder) and no error descriptions.
    private static let logger = Logger(subsystem: OhiaUninstallCatalog.uninstallerBundleID, category: "relaunch")

    /// Returns only when the uninstaller keeps running in this process.
    static func relaunchIfNeeded(
        bundleURL: URL = Bundle.main.bundleURL,
        arguments: [String] = CommandLine.arguments
    ) {
        let isOnReadOnlyVolume = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly == true
        guard UninstallerRelaunchDecision.shouldRelaunch(
            bundleURL: bundleURL, arguments: arguments, isOnReadOnlyVolume: isOnReadOnlyVolume)
        else { return }

        let copy: URL
        do {
            copy = try makeCopy(of: bundleURL)
        } catch {
            let nsError = error as NSError
            logger.error("Running in place: copying the uninstaller failed (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public))")
            return
        }

        // The outer Ohia.app was approved when first opened; the nested
        // uninstaller's files keep an unapproved quarantine that the copy
        // would inherit. The signature doesn't cover extended attributes.
        let quarantineFailures = QuarantineAttribute.removeRecursively(from: copy)
        if let first = quarantineFailures.first {
            logger.error("Relaunching with quarantine left on \(quarantineFailures.count, privacy: .public) entries of the copy (errno \(first.errorNumber, privacy: .public))")
        }

        let outcome = open(copy, arguments: UninstallerRelaunchDecision.copyArguments(from: arguments))
        if UninstallerRelaunchDecision.runsInPlace(after: outcome) {
            return
        }
        if outcome == .unanswered {
            logger.error("Exiting: Launch Services did not answer within the open timeout and may still start the copy")
        }
        exit(outcome == .opened ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// Starts this same bundle again as a fresh process, with the current
    /// arguments plus the access marker: macOS applies a granted data-access
    /// permission only to processes started after the grant. A copy keeps its
    /// copy marker, so it never copies itself again. True once the new
    /// process runs, so the caller can quit this one; false when Launch
    /// Services refused.
    static func relaunchForAccess(
        bundleURL: URL = Bundle.main.bundleURL,
        arguments: [String] = CommandLine.arguments
    ) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = UninstallerAccessGate.relaunchArguments(from: arguments)
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            return true
        } catch {
            let nsError = error as NSError
            logger.error("Staying: Launch Services could not start the uninstaller again (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public))")
            return false
        }
    }

    /// Copies the bundle into a new `OhiaUninstaller-<UUID>` folder in the
    /// unsandboxed process's temporary directory, outside ~/Library and Ohia.app.
    private static func makeCopy(of bundle: URL) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appending(path: "OhiaUninstaller-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        let copy = folder.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: bundle, to: copy)
        } catch {
            // Only the folder created above, so no partial copy is left behind.
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return copy
    }

    /// Opens the copy and waits for Launch Services to answer. AppKit calls
    /// the completion on a concurrent queue, so waiting here on the main
    /// thread cannot block it.
    private static func open(
        _ copy: URL,
        arguments: [String]
    ) -> UninstallerRelaunchDecision.CopyOpenOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = arguments
        let answer = OpenAnswer()
        let answered = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: copy, configuration: configuration) { app, error in
            let nsError = error.map { $0 as NSError }
            answer.value.withLock {
                $0 = app != nil
                    ? .opened
                    : .failed(domain: nsError?.domain ?? "none", code: nsError?.code ?? 0)
            }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + openTimeout) == .success else { return .unanswered }
        // The semaphore is signalled only after the answer is stored.
        switch answer.value.withLock({ $0 }) {
        case .opened:
            return .opened
        case .failed(let domain, let code):
            logger.error("Running in place: Launch Services could not open the copy (\(domain, privacy: .public) \(code, privacy: .public))")
            return .failed
        }
    }

    private enum Answer: Sendable {
        case opened
        case failed(domain: String, code: Int)
    }

    private final class OpenAnswer: Sendable {
        let value = Mutex<Answer>(.failed(domain: "none", code: 0))
    }
}
