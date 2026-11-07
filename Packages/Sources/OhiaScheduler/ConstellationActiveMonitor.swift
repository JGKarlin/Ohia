import Foundation
import Observation

/// Reference-counted flag indicating whether Constellation mode is currently
/// on screen. The `BackgroundScheduler` reads `isActive` to decide the
/// behavior of the `.refine` simulation job, deferring node movement while the
/// user is watching.
///
/// The refcount lets nested or overlapping enter/leave pairs compose without
/// flipping the flag off prematurely — e.g. a secondary window also showing
/// Constellation, or a SwiftUI view transition that briefly double-enters.
/// `leave()` is saturated at zero to keep the flag robust against bookkeeping
/// errors.
@Observable @MainActor
public final class ConstellationActiveMonitor {
    private var refcount: Int = 0
    private let activityMonitor: SharedAppActivityMonitor?
    public private(set) var isActive: Bool = false

    public init(activityMonitor: SharedAppActivityMonitor? = nil) {
        self.activityMonitor = activityMonitor
    }

    public func enter() {
        refcount += 1
        isActive = refcount > 0
        activityMonitor?.recordConstellationActive(isActive)
    }

    public func leave() {
        refcount = max(0, refcount - 1)
        isActive = refcount > 0
        activityMonitor?.recordConstellationActive(isActive)
    }
}
