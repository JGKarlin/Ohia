import Foundation
import SwiftData
import Observation
import OhiaCore
import OhiaScheduler

/// MainActor-observable snapshot of the `CustomMailCategory` catalog plus
/// every user-facing mutation: create, remove, and example tagging. One
/// instance lives on `ConstellationModeView` and is threaded to each
/// surface that lists categories (topics popover, locked-card picker,
/// node context menu); the menu-bar Commands scene reads the
/// defaults-mirrored JSON instead because it has no SwiftData environment.
@MainActor
@Observable
final class CustomCategoryStore {

    private(set) var descriptors: [CustomMailCategoryDescriptor] = []

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    /// Invoked on the main actor when a reload observes one or more
    /// categories transitioning from `.collecting` to `.active` — i.e. the
    /// background definition job finished and the category now steers
    /// interpretation. Activation happens out-of-band (a `JobQueue` worker,
    /// not a user gesture), so this is the only seam where the UI can learn
    /// about it at the moment it happens. Not fired for categories that are
    /// already active when the store first attaches.
    @ObservationIgnored var onCategoriesActivated: (([CustomMailCategoryDescriptor]) -> Void)?

    init() {}

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    /// Wire the store to the live model context. Idempotent — repeated
    /// calls (SwiftUI `.task` re-runs) just refresh the snapshot.
    func attach(_ context: ModelContext) {
        modelContext = context
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .ohiaCustomCategoriesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            }
        }
        reload()
    }

    /// Every known custom key — collecting and active. This is the set the
    /// row-decode seams intersect raw CSV tokens against, so keys of
    /// removed categories vanish everywhere immediately.
    var allKeys: Set<String> {
        Set(descriptors.map(\.key))
    }

    var activeKeys: Set<String> {
        Set(descriptors.filter(\.isActive).map(\.key))
    }

    var isEmpty: Bool { descriptors.isEmpty }

    func descriptor(forKey key: String) -> CustomMailCategoryDescriptor? {
        descriptors.first { $0.key == key }
    }

    func displayName(forKey key: String) -> String {
        descriptor(forKey: key)?.displayName ?? key
    }

    /// Row label used by pickers and menus: the display name, with
    /// collecting-progress appended while the category is gathering
    /// examples (e.g. "Surf Trips (3 of 5 examples)").
    func menuLabel(forKey key: String) -> String {
        guard let descriptor = descriptor(forKey: key) else { return key }
        return Self.menuLabel(for: descriptor)
    }

    static func menuLabel(for descriptor: CustomMailCategoryDescriptor) -> String {
        guard descriptor.status == .collecting else { return descriptor.displayName }
        let threshold = CustomMailCategory.activationExampleThreshold
        let count = min(descriptor.exampleCount, threshold)
        if count >= threshold, descriptor.hasSenderDiversity == false {
            return "\(descriptor.displayName) (\(threshold) of \(threshold) examples, needs a 2nd correspondent)"
        }
        return "\(descriptor.displayName) (\(count) of \(threshold) examples)"
    }

    func reload() {
        guard let modelContext else { return }
        let previous = descriptors
        descriptors = CustomMailCategoryCatalog.descriptors(in: modelContext)
        mirrorToDefaults()
        let activated = Self.newlyActivated(previous: previous, current: descriptors)
        if !activated.isEmpty {
            onCategoriesActivated?(activated)
        }
    }

    /// Categories that were `.collecting` in the previous snapshot and are
    /// `.active` in the current one. Keys absent from the previous snapshot
    /// don't count — a category that's already active at first attach (or
    /// created active by a future path) never fires an activation event.
    static func newlyActivated(
        previous: [CustomMailCategoryDescriptor],
        current: [CustomMailCategoryDescriptor]
    ) -> [CustomMailCategoryDescriptor] {
        let previouslyCollecting = Set(
            previous.filter { $0.status == .collecting }.map(\.key)
        )
        guard !previouslyCollecting.isEmpty else { return [] }
        return current.filter { $0.isActive && previouslyCollecting.contains($0.key) }
    }

    // MARK: - Mutations

    /// Creates a new collecting category from a user-typed name. Returns
    /// nil (without inserting) for empty names or names that already exist
    /// case-insensitively — the caller surfaces that as a no-op.
    @discardableResult
    func createCategory(named rawName: String) -> CustomMailCategoryDescriptor? {
        guard let modelContext else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }
        let loweredName = name.lowercased()
        guard descriptors.contains(where: { $0.displayName.lowercased() == loweredName }) == false else {
            return nil
        }
        let key = CustomMailCategory.canonicalKey(
            forDisplayName: name,
            existingKeys: allKeys
        )
        let category = CustomMailCategory(displayName: name, key: key)
        modelContext.insert(category)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            print("[CustomCategories] create failed errorKind=\(String(reflecting: type(of: error)))")
            return nil
        }
        reload()
        NotificationCenter.default.post(name: .ohiaCustomCategoriesDidChange, object: nil)
        return descriptor(forKey: key)
    }

    /// Removes a custom category. Fixed categories are not representable
    /// here, so they can never be removed through this path. Messages whose
    /// classification overlay still carries the key keep the inert token; every decode
    /// seam intersects against the live catalog so the key disappears from
    /// chips, filters, prompts, and memories immediately.
    func removeCategory(key: String) {
        guard let modelContext,
              CustomCategoryKeysJSON.canonicalKeys([key]).first == key else { return }
        let descriptor = FetchDescriptor<CustomMailCategory>(
            predicate: #Predicate<CustomMailCategory> { $0.key == key }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        modelContext.delete(row)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            print("[CustomCategories] remove failed errorKind=\(String(reflecting: type(of: error)))")
            return
        }
        reload()
        NotificationCenter.default.post(name: .ohiaCustomCategoriesDidChange, object: nil)
    }

    /// Outcome of one `setExample` call. `reachedThresholdWithoutDiversity`
    /// tells the caller to surface a notice: this tag reached (or already
    /// met) the example-count threshold, but the tagged examples still
    /// don't span a second correspondent, so the category did not activate.
    enum ExampleTagResult: Equatable {
        case noChange
        case updated(reachedThresholdWithoutDiversity: Bool)
    }

    /// Records (or withdraws) one message as a tagged example of a
    /// collecting category, and enqueues the definition-generation job once
    /// the activation threshold is reached *and* the tagged examples span
    /// at least `CustomMailCategoryCatalog.activationMinimumDistinctSenders`
    /// distinct correspondents — a category tagged entirely from one sender
    /// stays in `.collecting` (visible via `menuLabel`) until a second
    /// correspondent is tagged. Active categories skip the bookkeeping —
    /// tagging them is plain assignment, which the caller already persisted
    /// on the message row.
    @discardableResult
    func setExample(_ tagged: Bool, messageID: UUID, key: String) -> ExampleTagResult {
        guard let modelContext else { return .noChange }
        let descriptor = FetchDescriptor<CustomMailCategory>(
            predicate: #Predicate<CustomMailCategory> { $0.key == key }
        )
        guard let row = try? modelContext.fetch(descriptor).first,
              row.status == .collecting else { return .noChange }
        let changed = tagged ? row.addExample(messageID) : row.removeExample(messageID)
        guard changed else { return .noChange }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            print("[CustomCategories] example update failed errorKind=\(String(reflecting: type(of: error)))")
            return .noChange
        }
        let eligible = CustomMailCategoryCatalog.isEligibleForActivation(row, context: modelContext)
        if eligible {
            enqueueDefinitionJobIfNeeded(context: modelContext)
        }
        reload()
        NotificationCenter.default.post(name: .ohiaCustomCategoriesDidChange, object: nil)
        let reachedThresholdWithoutDiversity = tagged && row.hasReachedActivationThreshold && !eligible
        return .updated(reachedThresholdWithoutDiversity: reachedThresholdWithoutDiversity)
    }

    private func enqueueDefinitionJobIfNeeded(context: ModelContext) {
        let alreadyQueued = ((try? JobFetch.active(context: context)) ?? []).contains {
            $0.type == .customCategoryDefinition
                && ($0.status == .pending || $0.status == .running)
        }
        guard alreadyQueued == false else { return }
        do {
            try JobQueue().enqueue(type: .customCategoryDefinition, priority: 6, context: context)
        } catch {
            // The scheduler's ensurePipelineJobsExist reseed covers this
            // failure on the next tick; log and move on.
            print("[CustomCategories] definition job enqueue failed: \(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - Defaults mirror (menu-bar Commands scene)

    private func mirrorToDefaults() {
        guard let data = try? JSONEncoder().encode(descriptors),
              let json = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.removeObject(forKey: ConstellationDefaultsKey.customCategoryCatalogJSON)
            return
        }
        UserDefaults.standard.set(json, forKey: ConstellationDefaultsKey.customCategoryCatalogJSON)
    }

    /// Decode the defaults-mirrored catalog. Used by the Commands scene,
    /// which observes the key via `@AppStorage`.
    static func decodeMirroredCatalog(_ json: String) -> [CustomMailCategoryDescriptor] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CustomMailCategoryDescriptor].self, from: data) else {
            return []
        }
        return decoded
    }
}
