import Dispatch
import Foundation
import OhiaCore

public enum MeaningLensDemandPolicy {
    public static func isEnabled(
        displayedFrameRawValues: String
    ) -> Bool {
        displayedFrameRawValues
            .split(separator: ",")
            .contains(Substring(FrameKey.meaning.rawValue))
    }

    public static func isActive(
        activeFrame: FrameKey,
        displayedFrameRawValues: String
    ) -> Bool {
        guard activeFrame.spatialLens == .meaning else { return false }
        return isEnabled(displayedFrameRawValues: displayedFrameRawValues)
    }
}

public struct AppActivitySnapshot: Codable, Equatable, Sendable {
    public let isAppFrontmost: Bool
    public let lastOhiaInteractionAt: Date?
    public let isConstellationActive: Bool
    /// True while Meaning remains in the Constellation Top Bar Scopes. This
    /// controls whether membership participates in the ingestion tail at all.
    public let isMeaningLensEnabled: Bool
    /// True only while Meaning is both enabled and selected. This grants the
    /// on-demand membership path its ordinary idle-gate bypass.
    public let isMeaningLensActive: Bool
    /// True while the Composer (reply-drafting surface) is the mounted shell
    /// mode in the app process. The generative worker reads this to grant
    /// `.generateDraft` foreground priority access to the model.
    public let isComposerActive: Bool
    /// True only while the first-ingestion witness panel is mounted. This is
    /// presentation context; it does not exempt model work from foreground
    /// resource throttling.
    public let isOnboardingWitnessActive: Bool
    /// The message whose reply is open in the Composer, while one is. The
    /// editor holds unsaved text no store read can see, so background passes
    /// must never replace that draft's body. Nil when no reply is open.
    public let composerOpenReplyMessageID: UUID?
    public let updatedAt: Date

    public init(
        isAppFrontmost: Bool = false,
        lastOhiaInteractionAt: Date? = nil,
        isConstellationActive: Bool = false,
        isMeaningLensEnabled: Bool = false,
        isMeaningLensActive: Bool = false,
        isComposerActive: Bool = false,
        isOnboardingWitnessActive: Bool = false,
        composerOpenReplyMessageID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.isAppFrontmost = isAppFrontmost
        self.lastOhiaInteractionAt = lastOhiaInteractionAt
        self.isConstellationActive = isConstellationActive
        self.isMeaningLensEnabled = isMeaningLensEnabled
        self.isMeaningLensActive = isMeaningLensActive
        self.isComposerActive = isComposerActive
        self.isOnboardingWitnessActive = isOnboardingWitnessActive
        self.composerOpenReplyMessageID = composerOpenReplyMessageID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case isAppFrontmost
        case lastOhiaInteractionAt
        case isConstellationActive
        case isMeaningLensEnabled
        case isMeaningLensActive
        case isComposerActive
        case isOnboardingWitnessActive
        case composerOpenReplyMessageID
        case updatedAt
    }

    /// Tolerates snapshot files written before newer activity flags existed —
    /// the app and the worker processes upgrade independently, so a missing
    /// key must decode as false rather than failing the whole snapshot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isAppFrontmost = try container.decode(Bool.self, forKey: .isAppFrontmost)
        self.lastOhiaInteractionAt = try container.decodeIfPresent(Date.self, forKey: .lastOhiaInteractionAt)
        self.isConstellationActive = try container.decode(Bool.self, forKey: .isConstellationActive)
        self.isMeaningLensEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isMeaningLensEnabled
        ) ?? false
        self.isMeaningLensActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .isMeaningLensActive
        ) ?? false
        self.isComposerActive = try container.decodeIfPresent(Bool.self, forKey: .isComposerActive) ?? false
        self.isOnboardingWitnessActive = try container.decodeIfPresent(Bool.self, forKey: .isOnboardingWitnessActive) ?? false
        self.composerOpenReplyMessageID = try container.decodeIfPresent(
            UUID.self,
            forKey: .composerOpenReplyMessageID
        )
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func isFresh(now: Date = Date(), maxAge: TimeInterval = 30) -> Bool {
        now.timeIntervalSince(updatedAt) <= maxAge
    }

    public func hasRecentOhiaInteraction(now: Date = Date(), within interval: TimeInterval) -> Bool {
        guard let lastOhiaInteractionAt else { return false }
        return now.timeIntervalSince(lastOhiaInteractionAt) < interval
    }
}

/// File transport is kept separate from event recording: neither encoding nor
/// filesystem access belongs in the application's input-event callback.
struct AppActivitySnapshotPersistence: Sendable {
    let read: @Sendable () -> AppActivitySnapshot?
    let write: @Sendable (AppActivitySnapshot) throws -> Void

    static func file(at url: URL) -> Self {
        Self(
            read: {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(AppActivitySnapshot.self, from: data)
            },
            write: { snapshot in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic])
            }
        )
    }
}

public final class SharedAppActivityMonitor: @unchecked Sendable {
    private let persistence: AppActivitySnapshotPersistence?
    private let persistenceQueue = DispatchQueue(
        label: "org.jgkarlin.Ohia.appActivityPersistence",
        qos: .utility
    )
    private let lock = NSLock()
    private var current: AppActivitySnapshot
    private var lastInteractionWriteAt: Date?
    private var hasLocalUpdates = false
    private var pendingSnapshot: AppActivitySnapshot?
    private var writerIsScheduled = false

    public convenience init(
        snapshotURL: URL? = nil,
        initialSnapshot: AppActivitySnapshot = AppActivitySnapshot()
    ) {
        self.init(
            persistence: snapshotURL.map(AppActivitySnapshotPersistence.file),
            initialSnapshot: initialSnapshot
        )
    }

    init(
        persistence: AppActivitySnapshotPersistence?,
        initialSnapshot: AppActivitySnapshot = AppActivitySnapshot()
    ) {
        self.persistence = persistence
        self.current = persistence?.read() ?? initialSnapshot
    }

    public static func snapshotURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("app_activity.json")
    }

    public func snapshot() -> AppActivitySnapshot {
        lock.lock()
        if hasLocalUpdates {
            let snapshot = current
            lock.unlock()
            return snapshot
        }
        lock.unlock()

        // Worker-process monitors are readers. The app's writing monitor is
        // authoritative in memory, even while its latest write is queued.
        let stored = persistence?.read()
        lock.lock()
        defer { lock.unlock() }
        if !hasLocalUpdates, let stored { current = stored }
        return current
    }

    public func recordAppFrontmost(_ isFrontmost: Bool, now: Date = Date()) {
        update(now: now) { snapshot in
            AppActivitySnapshot(
                isAppFrontmost: isFrontmost,
                lastOhiaInteractionAt: snapshot.lastOhiaInteractionAt,
                isConstellationActive: snapshot.isConstellationActive,
                isMeaningLensEnabled: snapshot.isMeaningLensEnabled,
                isMeaningLensActive: snapshot.isMeaningLensActive,
                isComposerActive: snapshot.isComposerActive,
                isOnboardingWitnessActive: snapshot.isOnboardingWitnessActive,
                composerOpenReplyMessageID: snapshot.composerOpenReplyMessageID,
                updatedAt: now
            )
        }
    }

    public func recordInteraction(now: Date = Date()) {
        lock.lock()
        let shouldWrite = lastInteractionWriteAt.map { now.timeIntervalSince($0) >= 1.0 } ?? true
        if shouldWrite {
            lastInteractionWriteAt = now
        }
        lock.unlock()
        guard shouldWrite else { return }

        update(now: now) { snapshot in
            AppActivitySnapshot(
                isAppFrontmost: snapshot.isAppFrontmost,
                lastOhiaInteractionAt: now,
                isConstellationActive: snapshot.isConstellationActive,
                isMeaningLensEnabled: snapshot.isMeaningLensEnabled,
                isMeaningLensActive: snapshot.isMeaningLensActive,
                isComposerActive: snapshot.isComposerActive,
                isOnboardingWitnessActive: snapshot.isOnboardingWitnessActive,
                composerOpenReplyMessageID: snapshot.composerOpenReplyMessageID,
                updatedAt: now
            )
        }
    }

    public func recordConstellationActive(_ isActive: Bool, now: Date = Date()) {
        update(now: now) { snapshot in
            AppActivitySnapshot(
                isAppFrontmost: snapshot.isAppFrontmost,
                lastOhiaInteractionAt: snapshot.lastOhiaInteractionAt,
                isConstellationActive: isActive,
                isMeaningLensEnabled: snapshot.isMeaningLensEnabled,
                isMeaningLensActive: snapshot.isMeaningLensActive,
                isComposerActive: snapshot.isComposerActive,
                isOnboardingWitnessActive: snapshot.isOnboardingWitnessActive,
                composerOpenReplyMessageID: snapshot.composerOpenReplyMessageID,
                updatedAt: now
            )
        }
    }

    public func recordHeartbeat(
        isAppFrontmost: Bool? = nil,
        isConstellationActive: Bool? = nil,
        isMeaningLensEnabled: Bool? = nil,
        isMeaningLensActive: Bool? = nil,
        isComposerActive: Bool? = nil,
        isOnboardingWitnessActive: Bool? = nil,
        now: Date = Date()
    ) {
        update(now: now) { snapshot in
            AppActivitySnapshot(
                isAppFrontmost: isAppFrontmost ?? snapshot.isAppFrontmost,
                lastOhiaInteractionAt: snapshot.lastOhiaInteractionAt,
                isConstellationActive: isConstellationActive ?? snapshot.isConstellationActive,
                isMeaningLensEnabled: isMeaningLensEnabled
                    ?? snapshot.isMeaningLensEnabled,
                isMeaningLensActive: isMeaningLensActive
                    ?? snapshot.isMeaningLensActive,
                isComposerActive: isComposerActive ?? snapshot.isComposerActive,
                isOnboardingWitnessActive: isOnboardingWitnessActive ?? snapshot.isOnboardingWitnessActive,
                composerOpenReplyMessageID: snapshot.composerOpenReplyMessageID,
                updatedAt: now
            )
        }
    }

    public func recordComposerOpenReply(_ messageID: UUID?, now: Date = Date()) {
        update(now: now) { snapshot in
            AppActivitySnapshot(
                isAppFrontmost: snapshot.isAppFrontmost,
                lastOhiaInteractionAt: snapshot.lastOhiaInteractionAt,
                isConstellationActive: snapshot.isConstellationActive,
                isMeaningLensEnabled: snapshot.isMeaningLensEnabled,
                isMeaningLensActive: snapshot.isMeaningLensActive,
                isComposerActive: snapshot.isComposerActive,
                isOnboardingWitnessActive: snapshot.isOnboardingWitnessActive,
                composerOpenReplyMessageID: messageID,
                updatedAt: now
            )
        }
    }

    private func update(now: Date, transform: (AppActivitySnapshot) -> AppActivitySnapshot) {
        lock.lock()
        current = transform(current)
        hasLocalUpdates = true
        if persistence != nil { pendingSnapshot = current }
        let shouldSchedule = pendingSnapshot != nil && !writerIsScheduled
        if shouldSchedule { writerIsScheduled = true }
        lock.unlock()
        if shouldSchedule {
            // Retain the monitor until its final queued visibility update has
            // drained, including when the owning view is being torn down.
            persistenceQueue.async { self.drainPendingSnapshots() }
        }
    }

    private func drainPendingSnapshots() {
        while true {
            lock.lock()
            guard let snapshot = pendingSnapshot else {
                writerIsScheduled = false
                lock.unlock()
                return
            }
            pendingSnapshot = nil
            lock.unlock()

            do {
                try persistence?.write(snapshot)
            } catch {
                // A subsequent event or heartbeat retries using current
                // state; a failed write never rolls back local visibility.
                print("[Ohia] app activity snapshot write failed: \(String(reflecting: type(of: error)))")
            }
        }
    }
}
