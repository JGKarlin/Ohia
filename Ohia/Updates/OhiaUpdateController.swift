import Foundation
import Observation
import Sparkle

/// Owns Sparkle's standard updater and mirrors the properties the menu item
/// and Settings card read. Created only for a normal launch whose Info.plist
/// carries a real feed and key.
@MainActor
@Observable
final class OhiaUpdateController {
    private(set) var canCheckForUpdates: Bool
    private(set) var lastUpdateCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    @ObservationIgnored private let standardController: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private var updater: SPUUpdater { standardController.updater }

    /// The configuration is taken so the controller cannot exist for a build
    /// without a feed; Sparkle itself reads `SUFeedURL` and `SUPublicEDKey`
    /// from the same Info.plist.
    init(configuration: OhiaUpdateConfiguration) {
        _ = configuration
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        standardController = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
        observeUpdater(controller.updater)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// KVO can post a change on any thread, so each handler hops to the main
    /// actor and reads the updater's current value there.
    private func observeUpdater(_ updater: SPUUpdater) {
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    canCheckForUpdates = self.updater.canCheckForUpdates
                }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    lastUpdateCheckDate = self.updater.lastUpdateCheckDate
                }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.noteExternalChange(\.automaticallyChecksForUpdates)
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.noteExternalChange(\.automaticallyDownloadsUpdates)
                }
            },
        ]
    }

    /// Sparkle can change these itself (for example after its permission
    /// prompt); invalidate observers so views re-read the updater.
    private func noteExternalChange(_ keyPath: KeyPath<OhiaUpdateController, Bool>) {
        withMutation(keyPath: keyPath) {}
    }
}
