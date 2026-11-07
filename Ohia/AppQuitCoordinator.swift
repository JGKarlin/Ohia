import AppKit
import Foundation
import OhiaCore

/// Save-first, structured shutdown ordering used by the app and exercised
/// independently from AppKit's termination handshake.
@MainActor
struct AppTerminationSequence {
    typealias Action = @MainActor () -> Void
    typealias Save = @MainActor () throws -> Void
    typealias StopWorkers = @MainActor () async -> Set<WorkerRole>
    typealias ShutdownIMAP = @MainActor () async -> Void
    typealias HasChanges = @MainActor () -> Bool
    typealias Log = @MainActor (String) -> Void

    private let quiesce: Action
    private let initialSave: Save
    private let stopWorkers: StopWorkers
    private let shutdownIMAP: ShutdownIMAP
    private let hasChanges: HasChanges
    private let finalSave: Save
    private let log: Log

    init(
        quiesce: @escaping Action,
        initialSave: @escaping Save,
        stopWorkers: @escaping StopWorkers,
        shutdownIMAP: @escaping ShutdownIMAP,
        hasChanges: @escaping HasChanges,
        finalSave: @escaping Save,
        log: @escaping Log
    ) {
        self.quiesce = quiesce
        self.initialSave = initialSave
        self.stopWorkers = stopWorkers
        self.shutdownIMAP = shutdownIMAP
        self.hasChanges = hasChanges
        self.finalSave = finalSave
        self.log = log
    }

    @discardableResult
    func run() async -> Set<WorkerRole> {
        quiesce()
        do {
            try initialSave()
        } catch {
            log("[Ohia] Quit initial save failed: \(String(reflecting: type(of: error)))")
        }

        async let pendingWorkerRoles = stopWorkers()
        async let imapShutdown: Void = shutdownIMAP()
        let pendingRoles = await pendingWorkerRoles
        await imapShutdown

        if hasChanges() {
            do {
                try finalSave()
            } catch {
                log("[Ohia] Quit final save failed: \(String(reflecting: type(of: error)))")
            }
        }
        return pendingRoles
    }
}

@MainActor
final class AppTerminationPreparation {
    private(set) var failureMessages: [String] = []

    /// Called synchronously by editor flush observers. The request belongs
    /// to one Quit attempt, so a successful retry starts without stale errors.
    func reportFailure(_ error: Error) {
        failureMessages.append(error.localizedDescription)
    }
}

@MainActor
final class AppQuitCoordinator {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Reply = @MainActor (Bool) -> Void
    typealias PostWillPrepare = @MainActor (AppTerminationPreparation) -> Void
    typealias TimeoutDiagnostics = @MainActor () -> Set<WorkerRole>

    static let shared = AppQuitCoordinator()

    private let timeout: Duration
    private let sleep: Sleep
    private let reply: Reply
    private let postWillPrepare: PostWillPrepare

    private var cleanup: (@MainActor () async -> Void)?
    private var timeoutDiagnostics: TimeoutDiagnostics = { [] }
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var terminationInProgress = false
    private var terminationReplySent = false

    init(
        timeout: Duration = .seconds(8),
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        reply: @escaping Reply = { shouldTerminate in
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        },
        postWillPrepare: @escaping PostWillPrepare = { preparation in
            NotificationCenter.default.post(
                name: .ohiaWillPrepareForTermination,
                object: preparation
            )
        }
    ) {
        self.timeout = timeout
        self.sleep = sleep
        self.reply = reply
        self.postWillPrepare = postWillPrepare
    }

    func registerCleanup(
        _ cleanup: @escaping @MainActor () async -> Void,
        timeoutDiagnostics: @escaping TimeoutDiagnostics = { [] }
    ) {
        self.cleanup = cleanup
        self.timeoutDiagnostics = timeoutDiagnostics
    }

    func unregisterCleanup() {
        cleanup = nil
        timeoutDiagnostics = { [] }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard !terminationInProgress else {
            return .terminateLater
        }

        terminationInProgress = true
        let preparation = AppTerminationPreparation()
        postWillPrepare(preparation)
        guard preparation.failureMessages.isEmpty else {
            // No cleanup or deadline exists yet: cancelling here leaves
            // editor buffers, workers and IMAP available for a save retry.
            terminationInProgress = false
            print("[Ohia] Quit cancelled because an editor could not save")
            return .terminateCancel
        }
        guard let cleanup else {
            terminationInProgress = false
            return .terminateNow
        }
        print("[Ohia] Quit requested — draining pipeline before termination")

        cleanupTask = Task { @MainActor [weak self] in
            await cleanup()
            self?.finishTermination(timedOut: false)
        }

        let timeout = timeout
        let sleep = sleep
        deadlineTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await sleep(timeout)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            self?.finishTermination(timedOut: true)
        }

        return .terminateLater
    }

    private func finishTermination(timedOut: Bool) {
        guard !terminationReplySent else {
            return
        }
        terminationReplySent = true

        if timedOut {
            cleanupTask?.cancel()
            print(Self.timeoutDiagnosticMessage(for: timeoutDiagnostics()))
        } else {
            deadlineTask?.cancel()
            print("[Ohia] Quit cleanup acknowledged — terminating")
        }

        cleanupTask = nil
        deadlineTask = nil
        reply(true)
    }

    static func timeoutDiagnosticMessage(for pendingRoles: Set<WorkerRole>) -> String {
        guard !pendingRoles.isEmpty else {
            return "[Ohia] Quit cleanup timed out with no workers running — terminating with restart recovery enabled"
        }
        let processNames = pendingRoles.map(\.processName).sorted().joined(separator: ", ")
        return "[Ohia] Quit cleanup timed out with workers still running: \(processNames) — terminating with restart recovery enabled"
    }
}
