import Foundation
import SwiftData
import OhiaCore

struct DeadlineAgendaDisposition: Equatable, Sendable {
    let isPinned: Bool
    let isHidden: Bool

    static let rest = DeadlineAgendaDisposition(isPinned: false, isHidden: false)
}

/// SwiftData accessor for `DeadlineGuideState` — agenda disposition, guide
/// step ticks, and the last-re-read stamp. Keyed by the tracker's stable
/// deadline id, mirroring `DeadlineCalendarSync`'s use of `DeadlineReminder`.
@MainActor
struct DeadlineGuideStateStore {
    let modelContext: ModelContext
    private let saveContext: (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.saveContext = saveContext
    }

    /// Completed step ids for one deadline. Step ids are the content-derived
    /// `DeadlineActionItem.id` values, so ticks survive re-distillation.
    func completedStepIDs(entryID: String) -> Set<String> {
        fetch(entryID: entryID)?.completedStepIDs ?? []
    }

    func setStep(_ stepID: String, completed: Bool, entryID: String) {
        let state = fetchOrCreate(entryID: entryID)
        var ids = state.completedStepIDs
        if completed {
            ids.insert(stepID)
        } else {
            ids.remove(stepID)
        }
        state.completedStepIDs = ids
        state.updatedAt = .now
        try? modelContext.save()
    }

    /// When (and why) the guide was last re-distilled after the deadline's
    /// file set changed. `nil` until the first change.
    func lastRead(entryID: String) -> (at: Date, reason: String)? {
        guard let state = fetch(entryID: entryID),
              let at = state.guideLastReadAt,
              let reason = state.guideLastReadReason else {
            return nil
        }
        return (at, reason)
    }

    func setLastRead(at: Date, reason: String, entryID: String) {
        let state = fetchOrCreate(entryID: entryID)
        state.guideLastReadAt = at
        state.guideLastReadReason = reason
        state.updatedAt = .now
        try? modelContext.save()
    }

    // MARK: - Agenda disposition

    func disposition(entryID: String) -> DeadlineAgendaDisposition {
        guard let state = fetch(entryID: entryID) else { return .rest }
        return DeadlineAgendaDisposition(
            isPinned: state.isPinned ?? false,
            isHidden: state.isHidden ?? false
        )
    }

    func dispositions(entryIDs: Set<String>) -> [String: DeadlineAgendaDisposition] {
        guard entryIDs.isEmpty == false else { return [:] }
        let descriptor = FetchDescriptor<DeadlineGuideState>()
        guard let states = try? modelContext.fetch(descriptor) else { return [:] }
        return states.reduce(into: [:]) { result, state in
            guard entryIDs.contains(state.entryID) else { return }
            result[state.entryID] = DeadlineAgendaDisposition(
                isPinned: state.isPinned ?? false,
                isHidden: state.isHidden ?? false
            )
        }
    }

    func setPinned(_ isPinned: Bool, entryID: String) throws {
        let state = fetchOrCreate(entryID: entryID)
        state.isPinned = isPinned
        state.updatedAt = .now
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func setHidden(_ isHidden: Bool, entryID: String) throws {
        let state = fetchOrCreate(entryID: entryID)
        state.isHidden = isHidden
        state.updatedAt = .now
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Fetch

    private func fetch(entryID: String) -> DeadlineGuideState? {
        var descriptor = FetchDescriptor<DeadlineGuideState>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchOrCreate(entryID: String) -> DeadlineGuideState {
        if let existing = fetch(entryID: entryID) {
            return existing
        }
        let state = DeadlineGuideState(entryID: entryID)
        modelContext.insert(state)
        return state
    }
}
