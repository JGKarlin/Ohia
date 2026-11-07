import Combine
import Foundation
import OhiaCore


/// Process-scoped bridge for deletion notifications that retires matching
/// Beacon arrivals and lets the active lens purge stale messages from caches
/// and interaction state.
///
/// Holds a Combine subject only — no `@Observable` / `@Published` state. Views
/// consume the stream with `.onReceive`; the shared instance stays alive when
/// the main window is closed so background server reconciliation cannot strand
/// a Dock or Beacon badge.
@MainActor
public final class ConstellationDeletionEventBridge {

    public struct Deletion: Sendable, Equatable {
        public let vectorIDs: [Int64]
        public let messageIDs: [String]
    }

    static let shared = ConstellationDeletionEventBridge()

    public let deletions = PassthroughSubject<Deletion, Never>()

    private let notificationCenter: NotificationCenter
    private let arrivalLedger: NewMailArrivalLedger
    private var deletionObserver: NSObjectProtocol?

    public convenience init() {
        self.init(
            notificationCenter: .default,
            arrivalLedger: .shared
        )
    }

    init(
        notificationCenter: NotificationCenter,
        arrivalLedger: NewMailArrivalLedger
    ) {
        self.notificationCenter = notificationCenter
        self.arrivalLedger = arrivalLedger
        // NotificationCenter takes an `@Sendable` closure, so the body can't
        // touch this @MainActor class's isolated state synchronously even
        // when `queue: .main` is set — the static checker doesn't equate
        // OperationQueue.main with MainActor's executor. We extract the
        // Sendable payload here and hop to MainActor via a Task to do the
        // actor-isolated mutations.
        self.deletionObserver = notificationCenter.addObserver(
            forName: .ohiaDeletionApplied,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let vectorIDs = notification.userInfo?["vectorIds"] as? [Int64] ?? []
            let messageIDs = notification.userInfo?["messageIds"] as? [String] ?? []
            guard !vectorIDs.isEmpty || !messageIDs.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.applyDeletion(vectorIDs: vectorIDs, messageIDs: messageIDs)
            }
        }
    }

    deinit {
        if let deletionObserver {
            notificationCenter.removeObserver(deletionObserver)
        }
    }

    /// Retire the deleted messages from arrival badges and publish both forms
    /// of identity for active-lens cache cleanup. Called from the observer's
    /// MainActor hop.
    private func applyDeletion(vectorIDs: [Int64], messageIDs: [String]) {
        arrivalLedger.removeArrivals(messageIds: Set(messageIDs))
        deletions.send(Deletion(vectorIDs: vectorIDs, messageIDs: messageIDs))
    }

}
