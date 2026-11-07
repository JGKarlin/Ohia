import SwiftUI
import SwiftData
import OhiaCore
import OhiaScheduler

@MainActor
@Observable
final class ActivityLogModel {
    static let shared = ActivityLogModel()
    private(set) var records: [SessionActivityRecord] = []
    private(set) var active: [SessionActivityEvent] = []
    private(set) var error: String?
    private(set) var actionError: String?
    private(set) var latestCleanupEvents: [UUID: UUID] = [:]
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var activityState = SessionActivityState()

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var batch: [SessionActivityRecord]
            repeat {
                let after = cursor
                batch = try await Task.detached(priority: .utility) {
                    try SessionActivityLog.shared.read(after: after)
                }.value
                guard !batch.isEmpty else { break }
                records.append(contentsOf: batch)
                records.sort {
                    $0.event.timestamp == $1.event.timestamp ? $0.sequence < $1.sequence : $0.event.timestamp < $1.event.timestamp
                }
                cursor = batch.last!.sequence
                for record in batch {
                    activityState.consume(record.event).forEach { SessionActivityLog.shared.record($0) }
                    if record.event.operation == "Deleting Draft", record.event.phase != .state {
                        latestCleanupEvents[record.event.operationID] = record.event.id
                    }
                }
                let updated = activityState.active.values.sorted { $0.timestamp > $1.timestamp }
                if active != updated { active = updated }
            } while batch.count == 1000 && !Task.isCancelled
            error = nil
        } catch {
            self.error = "Activity log could not be read: \(error.localizedDescription)"
        }
    }

    func currentDetail(operation label: String, accountID: UUID?, accountNames: [UUID: String]) -> String? {
        let operation = switch label {
        case "digesting": "Summarize Attachments"
        case "compiling": "Prepare Reply Sources"
        default: label.capitalized
        }
        guard error == nil else { return nil }
        _ = active // Observe changes while the reducer itself remains unobserved.
        return activityState.details(operation: operation, accountID: accountID, accountNames: accountNames)
    }

    func retryCleanup(_ event: SessionActivityEvent, container: ModelContainer) {
        do {
            let context = ModelContext(container)
            guard try ComposerDraftSyncWorker.retryCleanup(draftID: event.operationID, context: context) else {
                latestCleanupEvents[event.operationID] = nil
                return
            }
            latestCleanupEvents[event.operationID] = nil
            SessionActivityLog.shared.record(event.ending(.retryScheduled, detail: "Manual cleanup retry requested."))
            actionError = nil
        } catch {
            actionError = "Cleanup retry could not be queued: \(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class ActivityStripPopoverState {
    var detail: String?
    var hoverOwner: UUID?
    var showsHistory = false
    /// Whether the hovered source presents help from its own popover, so the
    /// arrow points at that source, instead of from the state label's shared
    /// popover.
    private(set) var hoverOwnerAnchorsOwnPopover = false
    private var sourceHovered = false
    private var popupHovered = false
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    /// The state label's popover: the Activity Log, or the label's own help.
    var isShowingSharedPopover: Bool {
        showsHistory || (detail != nil && !hoverOwnerAnchorsOwnPopover)
    }

    /// Whether `owner`'s own popover should show its help right now.
    func isShowingHelp(anchoredAt owner: UUID) -> Bool {
        !showsHistory && detail != nil && hoverOwnerAnchorsOwnPopover && hoverOwner == owner
    }

    func dismiss() {
        dismissal?.cancel()
        detail = nil
        hoverOwner = nil
        hoverOwnerAnchorsOwnPopover = false
        showsHistory = false
        sourceHovered = false
        popupHovered = false
    }

    func hoverSource(_ owner: UUID, text: String, hovering: Bool, anchorsOwnPopover: Bool) {
        if hovering {
            dismissal?.cancel()
            hoverOwner = owner
            hoverOwnerAnchorsOwnPopover = anchorsOwnPopover
            detail = text
            sourceHovered = true
        } else if hoverOwner == owner {
            sourceHovered = false
            scheduleDismissal()
        }
    }

    func hoverPopup(_ hovering: Bool) {
        popupHovered = hovering
        if hovering { dismissal?.cancel() } else { scheduleDismissal() }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        guard !showsHistory else { return }
        // Entry is immediate. This exit grace only bridges the gap to the popup.
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !sourceHovered, !popupHovered, !showsHistory else { return }
            dismiss()
        }
    }
}

struct ActivityLogView: View {
    let model: ActivityLogModel
    let accountNames: [UUID: String]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity Log").font(.headline)
                Spacer()
                Text("Since launch · \(model.records.count) events")
                    .font(.caption).foregroundStyle(OhiaColors.textSecondary)
            }
            if let error = model.actionError ?? model.error {
                Text(error).font(.callout).foregroundStyle(OhiaColors.ohiaRed)
            }
            HStack(alignment: .top, spacing: 14) {
                Text("Time").frame(width: 120, alignment: .leading)
                Text("Operation / status").frame(width: 175, alignment: .leading)
                Text("Message / details").frame(maxWidth: .infinity, alignment: .leading)
                Text("Account").frame(width: 110, alignment: .leading)
            }
            .font(.caption).foregroundStyle(OhiaColors.textSecondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.records.reversed()) { record in
                        logRow(record.event)
                        Divider()
                    }
                }
            }
            .overlay {
                if model.records.isEmpty && model.error == nil {
                    Text("No activity recorded yet").foregroundStyle(OhiaColors.textSecondary)
                }
            }
            Text("Newest first · Updates live · History clears when Ohia launches")
                .font(.caption).foregroundStyle(OhiaColors.textSecondary)
        }
        .padding(18)
        .frame(width: 760, height: 500)
        .foregroundStyle(OhiaColors.textPrimary)
        .background(OhiaColors.toolbarBackground)
        .textSelection(.enabled)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func logRow(_ event: SessionActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(event.timestamp, format: .dateTime.month().day().hour().minute().second())
                .monospacedDigit().frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.operation).fontWeight(.medium)
                if event.phase != .state {
                    Text(event.phase == .finished ? "Success" :
                        event.phase == .retryScheduled ? "Retry scheduled" : event.phase.rawValue.capitalized)
                        .foregroundStyle(
                            event.phase == .finished ? OhiaColors.ohiaGreen :
                                event.phase == .failed || event.phase == .blocked ? OhiaColors.ohiaRed :
                                event.phase == .retryScheduled ? OhiaColors.ohiaYellow : OhiaColors.textSecondary
                        )
                }
                if event.phase == .blocked, event.operation == "Deleting Draft",
                   model.latestCleanupEvents[event.operationID] == event.id {
                    Button("Retry cleanup") {
                        model.retryCleanup(event, container: modelContext.container)
                    }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 4))
                }
            }
            .frame(width: 175, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let subject = event.subject {
                    Text(subject.isEmpty ? "No subject" : subject)
                }
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail).foregroundStyle(OhiaColors.textSecondary)
                }
                if event.subject == nil && (event.detail ?? "").isEmpty {
                    Text("—").foregroundStyle(OhiaColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(event.accountName ?? event.accountID.flatMap { accountNames[$0] ?? $0.uuidString } ?? "—")
                .frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 12))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
    }
}
