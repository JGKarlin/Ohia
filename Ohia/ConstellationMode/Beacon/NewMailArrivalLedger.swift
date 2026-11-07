// NewMailArrivalLedger.swift
// Single source of truth for the live-mail "arrival moment".
//
// A live inbound message passes through three ledger states:
//
//   embargoed  — detected after durable arrival tracking began
//                (`Message.liveDetectedAt` set) but the
//                pipeline has not completed. Every visual surface
//                (Metal constellation packets, Front Page, Timeline, Projects)
//                must hide the message while it is embargoed.
//   staged     — pipeline-ready and released to the active lens, but not yet
//                announced. The lens must acknowledge that the exact message
//                is installed before any user notification or badge can fire.
//   announced  — the unified arrival fired: starburst badge, dock badge,
//                new-mail sound, and the system notification all trigger in
//                the same main-actor turn, after lens acknowledgement.
//
// The app-level live-inbound reconciler (`RootView` in OhiaApp.swift) owns
// the transitions; views only read. The durable tracking boundary and
// announced-ID set survive process restarts so an unannounced message cannot
// become visible merely because the app relaunched.

import Foundation
import Observation

extension Notification.Name {
    static let ohiaNewMailUnvisitedArrivalsChanged = Notification.Name("ohia.newMail.unvisitedArrivalsChanged")
    static let ohiaNewMailArrivalVisibilityChanged = Notification.Name("ohia.newMail.arrivalVisibilityChanged")
    static let ohiaLiveInboundReadyForLensPresentation = Notification.Name(
        "ohia.liveInbound.readyForLensPresentation"
    )
    static let ohiaLiveInboundDidRenderInActiveLens = Notification.Name(
        "ohia.liveInbound.didRenderInActiveLens"
    )
}

struct NewMailArrivalVisibilityGate: Sendable, Equatable {
    let sessionStartedAt: Date?
    let trackingStartedAt: Date?
    let announcedMessageIds: Set<String>
    let stagedMessageIds: Set<String>
    let embargoedMessageIds: Set<String>

    nonisolated func isEmbargoed(messageID: String, liveDetectedAt: Date?) -> Bool {
        if announcedMessageIds.contains(messageID) { return false }
        if stagedMessageIds.contains(messageID) { return false }
        if embargoedMessageIds.contains(messageID) { return true }
        guard sessionStartedAt != nil,
              let liveDetectedAt,
              let trackingStartedAt else { return false }
        return liveDetectedAt >= trackingStartedAt
    }

    /// `index` without the rows this gate embargoes.
    nonisolated func visibleMessageIndex(
        _ index: [String: MessageFilterRow]
    ) -> [String: MessageFilterRow] {
        index.filter { messageID, row in
            isEmbargoed(messageID: messageID, liveDetectedAt: row.liveDetectedAt) == false
        }
    }
}

@Observable @MainActor
final class NewMailArrivalLedger {
    static let shared = NewMailArrivalLedger(persistence: .standard)

    private enum PersistenceKey {
        static let trackingStartedAt = "NewMailArrivalLedger.trackingStartedAt.v1"
        static let announcedMessageIds = "NewMailArrivalLedger.announcedMessageIds.v1"
    }

    /// Message UUID strings currently held back from every visual surface.
    private(set) var embargoedMessageIds: Set<String> = []
    /// Exact IDs registered synchronously by the IMAP detection path. They
    /// remain embargoed until staging or announcement even if the next store
    /// reconcile has not observed the newly inserted row yet.
    private var registeredDetectedMessageIds: Set<String> = []

    /// Pipeline-ready message UUID strings released to visual surfaces but not
    /// yet announced. Staging never changes badges; it exists solely so the
    /// active lens can install the message before acknowledging presentation.
    private(set) var stagedMessageIds: Set<String> = []

    /// Arrivals genuinely announced during this session. Unlike the visit
    /// queue, opening the starburst or reader does not clear this set. Front
    /// Page combines it with the message's live unread state so the border
    /// glisten survives every interaction until the read mutation succeeds.
    private(set) var newArrivalMessageIds: Set<String> = []

    /// THE one account of new mail: message UUID strings whose arrival was
    /// announced (sound, notification) but which the user has not visited
    /// yet, in announcement order. The dock badge and every starburst badge
    /// render `unvisitedCount` — never a derived or per-window count — so
    /// the two can never disagree. Tracked rows stay invisible until the
    /// unified alert actually fires.
    private(set) var unvisitedArrivalIds: [String] = []

    var unvisitedCount: Int { unvisitedArrivalIds.count }

    var pendingArrivalMessageIDs: Set<UUID> {
        Set(
            embargoedMessageIds
                .union(stagedMessageIds)
                .compactMap(UUID.init(uuidString:))
        )
    }

    /// Arrival rows that are known to have been committed to the message
    /// store and still carry user-facing state. The worker-status reconciler
    /// checks this small set against the authoritative active-row index so a
    /// missed or evicted deletion completion cannot strand a Beacon badge.
    var deletionReconciliationMessageIDs: Set<UUID> {
        Set(
            stagedMessageIds
                .union(newArrivalMessageIds)
                .union(unvisitedArrivalIds)
                .compactMap(UUID.init(uuidString:))
        )
    }

    /// Retires committed arrival state whose authoritative Message row is no
    /// longer active. Returns the exact UUID strings so the caller can decide
    /// whether a broad lens refresh is required.
    @discardableResult
    func removeArrivalsMissingFromActiveStore(
        activeMessageIDs: Set<UUID>
    ) -> Set<String> {
        let missing = Set(
            deletionReconciliationMessageIDs
                .subtracting(activeMessageIDs)
                .map(\.uuidString)
        )
        removeArrivals(messageIds: missing)
        return missing
    }

    private var announcedMessageIds: Set<String> = []
    /// Announcements whose complete user-facing delivery sequence reached
    /// `commitAnnouncementDelivery`. Unlike `announcedMessageIds`, this never
    /// contains the mutable pre-commit state created by `announce`.
    private var durablyAnnouncedMessageIds: Set<String> = []
    private(set) var sessionStartedAt: Date?
    private(set) var trackingStartedAt: Date?
    private var needsFullRecoverySweep = false
    private var unresolvedDetectionFloor: Date?

    /// Pushes the unvisited count onto the macOS Dock tile whenever it
    /// changes. The ledger owning the mirror (rather than call sites
    /// incrementing the tile ad hoc) is what guarantees dock and starburst
    /// always show the same number. Injectable so tests don't touch the
    /// test host's real Dock tile.
    private let dockBadgeMirror: @MainActor (Int) -> Void
    private let persistence: UserDefaults?

    init(
        dockBadgeMirror: @escaping @MainActor (Int) -> Void = { NewStarDockBadge.update(count: $0) },
        persistence: UserDefaults? = nil
    ) {
        self.dockBadgeMirror = dockBadgeMirror
        self.persistence = persistence
    }

    /// Starts a reconciler session, clearing all prior state. Runs once per
    /// process in production (the reconciler task is process-scoped and is
    /// only stopped at termination); callable repeatedly from tests.
    func beginSession(at date: Date) {
        sessionStartedAt = date
        if let persistence {
            if let storedTrackingStart = persistence.object(
                forKey: PersistenceKey.trackingStartedAt
            ) as? Date {
                trackingStartedAt = storedTrackingStart
            } else {
                let trackingStart = date.addingTimeInterval(-1)
                trackingStartedAt = trackingStart
                persistence.set(trackingStart, forKey: PersistenceKey.trackingStartedAt)
            }
            durablyAnnouncedMessageIds = Set(
                persistence.stringArray(forKey: PersistenceKey.announcedMessageIds) ?? []
            )
            announcedMessageIds = durablyAnnouncedMessageIds
        } else {
            if trackingStartedAt == nil {
                trackingStartedAt = date.addingTimeInterval(-1)
            }
            durablyAnnouncedMessageIds.removeAll()
            announcedMessageIds.removeAll()
        }
        needsFullRecoverySweep = true
        unresolvedDetectionFloor = nil
        registeredDetectedMessageIds.removeAll()
        stagedMessageIds.removeAll()
        newArrivalMessageIds.removeAll()
        if embargoedMessageIds.isEmpty == false {
            embargoedMessageIds.removeAll()
            publishArrivalVisibilityChange()
        }
        clearUnvisited()
    }

    func endSession() {
        sessionStartedAt = nil
        announcedMessageIds.removeAll()
        needsFullRecoverySweep = false
        unresolvedDetectionFloor = nil
        registeredDetectedMessageIds.removeAll()
        stagedMessageIds.removeAll()
        newArrivalMessageIds.removeAll()
        if embargoedMessageIds.isEmpty == false {
            embargoedMessageIds.removeAll()
            publishArrivalVisibilityChange()
        }
        clearUnvisited()
    }

    /// The user inspected this arrival (starburst navigation, Front Page
    /// reader, Projects link, node click). Removes it from the canonical
    /// unvisited account and mirrors the dock badge.
    func markVisited(messageId: String) {
        guard let index = unvisitedArrivalIds.firstIndex(of: messageId) else { return }
        unvisitedArrivalIds.remove(at: index)
        dockBadgeMirror(unvisitedArrivalIds.count)
        publishUnvisitedChange()
    }

    /// The user cleared these arrivals from the Beacon without opening them.
    /// Like a visit, this drops them from the unvisited account but keeps
    /// their new-arrival treatment until the message is read. The dock
    /// mirror and change notification fire once for the whole batch.
    func markVisited(messageIds: Set<String>) {
        guard messageIds.isEmpty == false else { return }
        let remaining = unvisitedArrivalIds.filter { messageIds.contains($0) == false }
        guard remaining.count != unvisitedArrivalIds.count else { return }
        unvisitedArrivalIds = remaining
        dockBadgeMirror(unvisitedArrivalIds.count)
        publishUnvisitedChange()
    }

    /// Deletion purge: deleted messages owe no visit.
    func removeArrivals(messageIds: Set<String>) {
        guard messageIds.isEmpty == false else { return }
        let visibilityChanged =
            embargoedMessageIds.isDisjoint(with: messageIds) == false
            || stagedMessageIds.isDisjoint(with: messageIds) == false
        registeredDetectedMessageIds.subtract(messageIds)
        embargoedMessageIds.subtract(messageIds)
        stagedMessageIds.subtract(messageIds)
        newArrivalMessageIds.subtract(messageIds)
        if visibilityChanged {
            publishArrivalVisibilityChange()
        }
        let before = unvisitedArrivalIds.count
        unvisitedArrivalIds.removeAll { messageIds.contains($0) }
        if unvisitedArrivalIds.count != before {
            dockBadgeMirror(unvisitedArrivalIds.count)
            publishUnvisitedChange()
        }
    }

    private func clearUnvisited() {
        let hadEntries = unvisitedArrivalIds.isEmpty == false
        unvisitedArrivalIds.removeAll()
        if hadEntries {
            dockBadgeMirror(0)
            publishUnvisitedChange()
        }
    }

    /// Replaces the reconciler's set-based view of detected-but-not-yet-ready
    /// rows. The full visibility gate also consults `liveDetectedAt`, so a
    /// current-session row that falls out of the reconcile lookback still
    /// stays hidden until it is staged for lens presentation.
    func updateEmbargo(holding messageIds: Set<UUID>) {
        let next = Set(messageIds.map(\.uuidString))
            .union(registeredDetectedMessageIds)
            .subtracting(announcedMessageIds)
            .subtracting(stagedMessageIds)
        if next != embargoedMessageIds {
            embargoedMessageIds = next
            publishArrivalVisibilityChange()
        }
    }

    /// Registers exact IMAP detections synchronously, closing the interval
    /// before the store reconciler sees the inserted rows. Set membership is
    /// replayable by remounted lens controls and idempotent across duplicate
    /// session callbacks.
    func registerDetected(_ messageIds: [UUID]) {
        let detected = Set(messageIds.map(\.uuidString))
            .subtracting(announcedMessageIds)
            .subtracting(stagedMessageIds)
        guard detected.isEmpty == false else { return }
        registeredDetectedMessageIds.formUnion(detected)
        let next = embargoedMessageIds.union(detected)
        if next != embargoedMessageIds {
            embargoedMessageIds = next
            publishArrivalVisibilityChange()
        }
    }

    /// Releases pipeline-ready messages for lens construction without
    /// announcing, badging, sounding, or posting a system notification.
    /// Returns only newly staged IDs; callers may safely retry every reconcile
    /// tick while waiting for a lens acknowledgement.
    @discardableResult
    func stageForLensPresentation(_ messageIds: [UUID]) -> [UUID] {
        let fresh = messageIds.filter { messageID in
            let id = messageID.uuidString
            guard announcedMessageIds.contains(id) == false else { return false }
            return stagedMessageIds.insert(id).inserted
        }
        guard fresh.isEmpty == false else { return [] }
        let freshStrings = Set(fresh.map(\.uuidString))
        registeredDetectedMessageIds.subtract(freshStrings)
        embargoedMessageIds.subtract(freshStrings)
        publishArrivalVisibilityChange()
        return fresh
    }

    /// Marks messages announced, lifts their embargo, and adds them to the
    /// unvisited account (badging the dock in the same turn). Returns only
    /// the IDs that were not already announced — the caller fires the
    /// unified alert for exactly that subset, so a message can never alert
    /// or badge twice.
    @discardableResult
    func announce(_ messageIds: [UUID]) -> [UUID] {
        let fresh = recordAnnounced(messageIds)
        guard fresh.isEmpty == false else { return [] }
        let freshStrings = fresh.map(\.uuidString)
        newArrivalMessageIds.formUnion(freshStrings)
        unvisitedArrivalIds.append(contentsOf: freshStrings)
        dockBadgeMirror(unvisitedArrivalIds.count)
        publishUnvisitedChange()
        return fresh
    }

    /// Releases messages the user already read in another mail client to
    /// every lens and records them announced, with no alert, badge or
    /// unvisited mark. Returns only the IDs not already announced.
    @discardableResult
    func releaseWithoutAlert(_ messageIds: [UUID]) -> [UUID] {
        let fresh = recordAnnounced(messageIds)
        guard fresh.isEmpty == false else { return [] }
        commitAnnouncementDelivery(fresh)
        return fresh
    }

    private func publishUnvisitedChange() {
        NotificationCenter.default.post(
            name: .ohiaNewMailUnvisitedArrivalsChanged,
            object: self
        )
    }

    private func publishArrivalVisibilityChange() {
        NotificationCenter.default.post(
            name: .ohiaNewMailArrivalVisibilityChanged,
            object: self
        )
    }

    private func recordAnnounced(_ messageIds: [UUID]) -> [UUID] {
        let fresh = messageIds.filter { announcedMessageIds.insert($0.uuidString).inserted }
        guard fresh.isEmpty == false else { return [] }
        let freshStrings = Set(fresh.map(\.uuidString))
        registeredDetectedMessageIds.subtract(freshStrings)
        stagedMessageIds.subtract(freshStrings)
        if embargoedMessageIds.isDisjoint(with: freshStrings) == false {
            embargoedMessageIds.subtract(freshStrings)
        }
        publishArrivalVisibilityChange()
        return fresh
    }

    /// Durably records only announcements whose user-facing delivery sequence
    /// completed. A process exit before this commit leaves the IDs absent from
    /// persistence, so the next launch re-embargoes and retries them.
    func commitAnnouncementDelivery(_ messageIds: [UUID]) {
        guard messageIds.isEmpty == false else { return }
        let deliveredIds = Set(messageIds.map(\.uuidString))
        guard deliveredIds.isSubset(of: announcedMessageIds) else {
            assertionFailure("Cannot commit an arrival that was not announced in memory")
            return
        }
        durablyAnnouncedMessageIds.formUnion(deliveredIds)
        persistDurablyAnnouncedMessageIds()
    }

    func durablyAnnouncedMessageIDs() -> Set<UUID> {
        Set(durablyAnnouncedMessageIds.compactMap(UUID.init(uuidString:)))
    }

    private func persistDurablyAnnouncedMessageIds() {
        persistence?.set(
            durablyAnnouncedMessageIds.sorted(),
            forKey: PersistenceKey.announcedMessageIds
        )
    }

    /// The first pass of each process recovers every tracked live detection so
    /// a staged-but-unannounced row from an earlier process cannot be skipped.
    /// Later passes retain only the ordinary recent/session window plus the
    /// earliest unresolved row observed during the recovery pass.
    func reconciliationStartDate(recentCutoff: Date) -> Date? {
        guard let sessionStartedAt else { return nil }
        if needsFullRecoverySweep, let trackingStartedAt {
            return trackingStartedAt
        }
        var start = min(recentCutoff, sessionStartedAt.addingTimeInterval(-1))
        if let unresolvedDetectionFloor {
            start = min(start, unresolvedDetectionFloor)
        }
        return start
    }

    /// Completes one successful store sweep and preserves the oldest row that
    /// still owes an announcement as the floor for subsequent polling.
    func finishReconciliation(unresolvedDetectionDates: [Date]) {
        needsFullRecoverySweep = false
        unresolvedDetectionFloor = unresolvedDetectionDates.min()?.addingTimeInterval(-1)
    }

    func isAnnounced(messageID: UUID) -> Bool {
        announcedMessageIds.contains(messageID.uuidString)
    }

    func isStagedForLensPresentation(messageID: UUID) -> Bool {
        stagedMessageIds.contains(messageID.uuidString)
    }

    func isUnvisitedArrival(messageID: UUID) -> Bool {
        unvisitedArrivalIds.contains(messageID.uuidString)
    }

    func isNewArrival(messageID: UUID) -> Bool {
        newArrivalMessageIds.contains(messageID.uuidString)
    }

    /// Ends both new-arrival treatments after authoritative state becomes
    /// read: the persistent Front Page shimmer and the unvisited badge. A
    /// failed read mutation never calls this, and marking the message unread
    /// later cannot resurrect either treatment.
    func retireReadArrivals(messageIds: Set<String>) {
        guard messageIds.isEmpty == false else { return }
        if newArrivalMessageIds.isDisjoint(with: messageIds) == false {
            newArrivalMessageIds.subtract(messageIds)
        }
        // A read card reports its state whenever it mounts. Mutating an
        // observed collection even when nothing is removed invalidates every
        // dependent card and can turn navigation into a full-grid update.
        let remaining = unvisitedArrivalIds.filter { messageIds.contains($0) == false }
        guard remaining.count != unvisitedArrivalIds.count else { return }
        unvisitedArrivalIds = remaining
        dockBadgeMirror(unvisitedArrivalIds.count)
        publishUnvisitedChange()
    }

    /// Precise embargo test for surfaces that hold the `Message` row itself
    /// (Front Page, Timeline, Projects gathers). Unlike the set-based
    /// `embargoedMessageIds` — which lags detection by up to one reconcile
    /// tick — this is race-free: any message live-detected after durable
    /// tracking began is hidden until announced, even if the reconciler has not
    /// polled since the detection write.
    func isEmbargoed(messageID: UUID, liveDetectedAt: Date?) -> Bool {
        visibilityGate().isEmbargoed(
            messageID: messageID.uuidString,
            liveDetectedAt: liveDetectedAt
        )
    }

    /// Sendable snapshot of the visibility gate for detached snapshot builds.
    /// Mirrors `isEmbargoed`: set membership handles reconciler truth, while
    /// `liveDetectedAt` closes the tiny before-the-first-poll race.
    func visibilityGate() -> NewMailArrivalVisibilityGate {
        NewMailArrivalVisibilityGate(
            sessionStartedAt: sessionStartedAt,
            trackingStartedAt: trackingStartedAt,
            announcedMessageIds: announcedMessageIds,
            stagedMessageIds: stagedMessageIds,
            embargoedMessageIds: embargoedMessageIds
        )
    }

    /// Sendable snapshot of everything a detached lens gather consults: the
    /// embargo gate plus unvisited-arrival membership. Captured on the main
    /// actor at gather start so the off-main pipeline never touches the ledger.
    struct GatherSnapshot: Sendable {
        let gate: NewMailArrivalVisibilityGate
        let unvisitedArrivalIds: Set<String>

        nonisolated func isEmbargoed(messageID: UUID, liveDetectedAt: Date?) -> Bool {
            gate.isEmbargoed(messageID: messageID.uuidString, liveDetectedAt: liveDetectedAt)
        }

        nonisolated func isUnvisitedArrival(messageID: UUID) -> Bool {
            unvisitedArrivalIds.contains(messageID.uuidString)
        }
    }

    func gatherSnapshot() -> GatherSnapshot {
        GatherSnapshot(
            gate: visibilityGate(),
            unvisitedArrivalIds: Set(unvisitedArrivalIds)
        )
    }

    /// Filters a `MessageFilterRow` index through the full visibility gate,
    /// including the race-free `liveDetectedAt` fallback. This is stricter
    /// than set-only filtering and protects stale cached snapshots after a row
    /// leaves the reconcile lookback.
    func filteredMessageIndex(_ index: [String: MessageFilterRow]) -> [String: MessageFilterRow] {
        visibilityGate().visibleMessageIndex(index)
    }

    /// Returns `index` with every embargoed message removed. Cheap when no
    /// embargo is active (the overwhelmingly common case).
    func filteredMessageIndex<Row>(_ index: [String: Row]) -> [String: Row] {
        guard embargoedMessageIds.isEmpty == false else { return index }
        var filtered = index
        for id in embargoedMessageIds {
            filtered.removeValue(forKey: id)
        }
        return filtered
    }
}
