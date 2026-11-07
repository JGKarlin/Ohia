import Foundation
import Observation
import OhiaCore
import OhiaMail

@Observable
@MainActor
final class RemoteHistoryEstimateController {
    typealias Estimator = @Sendable (
        _ configuration: IMAPConnectionConfiguration,
        _ lowerBound: Date?
    ) async throws -> IMAPHistoryEstimate
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    enum State: Sendable, Equatable {
        case idle
        case loading
        case available(count: Int, accuracy: IMAPHistoryEstimate.Accuracy)
        case unavailable
    }

    struct RequestFingerprint: Hashable {
        fileprivate let accountID: UUID
        fileprivate let presetID: String
        fileprivate let lowerBound: Date?
        fileprivate let configuration: Int
    }

    private struct CacheScope: Hashable {
        let accountID: UUID
        let lowerBound: Date?
    }

    private struct CacheKey: Hashable {
        let scope: CacheScope
        let folderSnapshotFingerprint: String
    }

    private struct CacheRecord {
        let estimate: IMAPHistoryEstimate
        let configurationFingerprint: Int
    }

    private(set) var state: State = .idle

    var advisoryText: String? {
        state == .unavailable ? "Count unavailable" : nil
    }

    @ObservationIgnored
    private let estimator: Estimator
    @ObservationIgnored
    private let debounceSleep: Sleep
    @ObservationIgnored
    private let timeoutSleep: Sleep
    @ObservationIgnored
    private var activeRequestID: UUID?
    @ObservationIgnored
    private var activeFingerprint: RequestFingerprint?
    @ObservationIgnored
    private var activeEstimateTask: Task<EstimateRace.Outcome, Never>?
    @ObservationIgnored
    private var activeEstimateRequestID: UUID?
    @ObservationIgnored
    private var stateAccountID: UUID?
    @ObservationIgnored
    private var currentEstimate: IMAPHistoryEstimate?
    @ObservationIgnored
    private var currentEstimateFingerprint: RequestFingerprint?
    @ObservationIgnored
    private var cache: [CacheKey: CacheRecord] = [:]
    @ObservationIgnored
    private var latestCacheKeyByScope: [CacheScope: CacheKey] = [:]

    init(
        estimator: @escaping Estimator = { configuration, lowerBound in
            try await IMAPHistoryEstimator().estimate(
                configuration: configuration,
                lowerBound: lowerBound
            )
        },
        debounceSleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        timeoutSleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.estimator = estimator
        self.debounceSleep = debounceSleep
        self.timeoutSleep = timeoutSleep
    }

    func requestFingerprint(
        selection: HistoryIngestionPreset,
        authenticatedAccountID: UUID,
        configuration: IMAPConnectionConfiguration,
        configuredAt: Date
    ) -> RequestFingerprint {
        RequestFingerprint(
            accountID: authenticatedAccountID,
            presetID: selection.id,
            lowerBound: selection.lowerBound(anchoredAt: configuredAt),
            configuration: Self.configurationFingerprint(configuration)
        )
    }

    func refresh(
        selection: HistoryIngestionPreset,
        authenticatedAccountID: UUID,
        configuration: IMAPConnectionConfiguration,
        configuredAt: Date
    ) async {
        let fingerprint = requestFingerprint(
            selection: selection,
            authenticatedAccountID: authenticatedAccountID,
            configuration: configuration,
            configuredAt: configuredAt
        )
        let scope = CacheScope(
            accountID: authenticatedAccountID,
            lowerBound: fingerprint.lowerBound
        )
        let requestID = UUID()
        activeEstimateTask?.cancel()
        activeEstimateTask = nil
        activeEstimateRequestID = nil
        activeRequestID = requestID
        activeFingerprint = fingerprint
        stateAccountID = authenticatedAccountID
        currentEstimate = nil
        currentEstimateFingerprint = nil

        if let cached = cachedEstimate(
            for: scope,
            configurationFingerprint: fingerprint.configuration
        ) {
            publish(cached, requestID: requestID, fingerprint: fingerprint)
            return
        }

        state = .loading

        do {
            try await debounceSleep(.milliseconds(300))
            try ensureCurrent(requestID: requestID, fingerprint: fingerprint)
        } catch {
            finishCancellationIfCurrent(requestID: requestID, fingerprint: fingerprint)
            return
        }

        let estimateTask = Task {
            await racedEstimate(
                configuration: configuration,
                lowerBound: fingerprint.lowerBound
            )
        }
        activeEstimateTask = estimateTask
        activeEstimateRequestID = requestID
        let outcome = await withTaskCancellationHandler {
            await estimateTask.value
        } onCancel: {
            estimateTask.cancel()
        }
        if activeEstimateRequestID == requestID {
            activeEstimateTask = nil
            activeEstimateRequestID = nil
        }
        guard isCurrent(requestID: requestID, fingerprint: fingerprint) else { return }

        switch outcome {
        case .success(let estimate):
            let snapshotFingerprint = Self.folderSnapshotFingerprint(estimate.folderWork)
            let key = CacheKey(
                scope: scope,
                folderSnapshotFingerprint: snapshotFingerprint
            )
            cache[key] = CacheRecord(
                estimate: estimate,
                configurationFingerprint: fingerprint.configuration
            )
            latestCacheKeyByScope[scope] = key
            publish(estimate, requestID: requestID, fingerprint: fingerprint)

        case .unavailable, .timedOut:
            state = .unavailable
            currentEstimate = nil
            currentEstimateFingerprint = nil
            finish(requestID: requestID, fingerprint: fingerprint)

        case .cancelled:
            finishCancellationIfCurrent(requestID: requestID, fingerprint: fingerprint)
        }
    }

    /// Authentication retry makes every completed estimate for that account
    /// ineligible for reuse. Other accounts remain cached.
    func invalidateCachedEstimates(forAuthenticatedAccountID accountID: UUID) {
        let scopes = latestCacheKeyByScope.keys.filter { $0.accountID == accountID }
        for scope in scopes {
            if let key = latestCacheKeyByScope.removeValue(forKey: scope) {
                cache.removeValue(forKey: key)
            }
        }

        let otherKeysForAccount = cache.keys.filter { $0.scope.accountID == accountID }
        for key in otherKeysForAccount {
            cache.removeValue(forKey: key)
        }

        if activeFingerprint?.accountID == accountID {
            activeEstimateTask?.cancel()
            activeEstimateTask = nil
            activeEstimateRequestID = nil
            activeRequestID = nil
            activeFingerprint = nil
        }
        if stateAccountID == accountID {
            state = .idle
            stateAccountID = nil
        }
        if currentEstimateFingerprint?.accountID == accountID {
            currentEstimate = nil
            currentEstimateFingerprint = nil
        }
    }

    /// Returns the full estimate only when it was produced for the exact
    /// authenticated account, connection configuration, anchored window, and
    /// preset currently being persisted. Presentation counts are never used to
    /// reconstruct acquisition work.
    func validatedEstimate(
        selection: HistoryIngestionPreset,
        authenticatedAccountID: UUID,
        configuration: IMAPConnectionConfiguration,
        configuredAt: Date
    ) -> IMAPHistoryEstimate? {
        let fingerprint = requestFingerprint(
            selection: selection,
            authenticatedAccountID: authenticatedAccountID,
            configuration: configuration,
            configuredAt: configuredAt
        )
        guard currentEstimateFingerprint == fingerprint else { return nil }
        return currentEstimate
    }

    private func cachedEstimate(
        for scope: CacheScope,
        configurationFingerprint: Int
    ) -> IMAPHistoryEstimate? {
        guard let key = latestCacheKeyByScope[scope] else { return nil }
        guard let record = cache[key],
              record.configurationFingerprint == configurationFingerprint else {
            return nil
        }
        return record.estimate
    }

    private func publish(
        _ estimate: IMAPHistoryEstimate,
        requestID: UUID,
        fingerprint: RequestFingerprint
    ) {
        guard isCurrent(requestID: requestID, fingerprint: fingerprint) else { return }
        currentEstimate = estimate
        currentEstimateFingerprint = fingerprint
        state = .available(
            count: estimate.displayedMessageCount,
            accuracy: estimate.accuracy
        )
        finish(requestID: requestID, fingerprint: fingerprint)
    }

    private func racedEstimate(
        configuration: IMAPConnectionConfiguration,
        lowerBound: Date?
    ) async -> EstimateRace.Outcome {
        let race = EstimateRace()
        let estimator = self.estimator
        let timeoutSleep = self.timeoutSleep

        let estimateTask = Task {
            do {
                let estimate = try await estimator(configuration, lowerBound)
                await race.resolve(.success(estimate))
            } catch is CancellationError {
                await race.resolve(.cancelled)
            } catch {
                await race.resolve(.unavailable)
            }
        }
        let timeoutTask = Task {
            do {
                try await timeoutSleep(.seconds(15))
                await race.resolve(.timedOut)
            } catch {
                // The winning estimate cancels this deadline task.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            estimateTask.cancel()
            timeoutTask.cancel()
            Task { await race.resolve(.cancelled) }
        }

        estimateTask.cancel()
        timeoutTask.cancel()
        return outcome
    }

    private func ensureCurrent(
        requestID: UUID,
        fingerprint: RequestFingerprint
    ) throws {
        try Task.checkCancellation()
        guard isCurrent(requestID: requestID, fingerprint: fingerprint) else {
            throw CancellationError()
        }
    }

    private func isCurrent(
        requestID: UUID,
        fingerprint: RequestFingerprint
    ) -> Bool {
        activeRequestID == requestID && activeFingerprint == fingerprint
    }

    private func finish(requestID: UUID, fingerprint: RequestFingerprint) {
        guard isCurrent(requestID: requestID, fingerprint: fingerprint) else { return }
        activeRequestID = nil
        activeFingerprint = nil
    }

    private func finishCancellationIfCurrent(
        requestID: UUID,
        fingerprint: RequestFingerprint
    ) {
        guard isCurrent(requestID: requestID, fingerprint: fingerprint) else { return }
        state = .idle
        stateAccountID = nil
        currentEstimate = nil
        currentEstimateFingerprint = nil
        finish(requestID: requestID, fingerprint: fingerprint)
    }

    private static func configurationFingerprint(
        _ configuration: IMAPConnectionConfiguration
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(configuration.host)
        hasher.combine(configuration.port)
        hasher.combine(configuration.security.rawValue)
        hasher.combine(configuration.pinnedCertSHA256)
        switch configuration.auth {
        case .password(let username, let password):
            hasher.combine(0)
            hasher.combine(username)
            hasher.combine(password)
        case .xoauth2(let username, let initialToken, _):
            hasher.combine(1)
            hasher.combine(username)
            hasher.combine(initialToken)
        }
        return hasher.finalize()
    }

    /// Length-prefixed fields avoid delimiter ambiguity while keeping the
    /// snapshot deterministic across launches. Folder order is preserved;
    /// each folder's attributes are normalized independently.
    private static func folderSnapshotFingerprint(
        _ folders: [IMAPFolderWorkEstimate]
    ) -> String {
        folders.map { folder in
            [
                encoded(folder.folderName),
                encoded(folder.attributes.sorted().map(encoded).joined()),
                String(folder.uidValidity),
                String(folder.uidNext),
                String(folder.candidateUIDCount),
            ].map(encoded).joined()
        }.map(encoded).joined()
    }

    private static func encoded(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

private actor EstimateRace {
    enum Outcome: Sendable {
        case success(IMAPHistoryEstimate)
        case unavailable
        case timedOut
        case cancelled
    }

    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}
