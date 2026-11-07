import Foundation
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ProjectsSnapshotSignature: Hashable, Sendable {
    var projectsSourceEpoch: UInt64 = 0
    var deadlinesSourceEpoch: UInt64 = 0
    let displayFilterFingerprint: String
    let deadlineDisplayFilterFingerprint: String
    let filteredMessageProjectionFingerprint: String
    let projectRevisionFingerprint: String
    let membershipRevisionFingerprint: String
    let projectMessageSourceFingerprint: String
    var userAddressesFingerprint: String = "not-loaded"
    let sharedMessageActionFingerprint: String
    let deadlineInputFingerprint: String
}

struct ProjectsSnapshot: Sendable {
    let signature: ProjectsSnapshotSignature
    let builtAt: Date
    let rowsSnapshot: ProjectRowsSnapshot
    /// Structural rows computed from every persisted manual project and every
    /// valid committed membership, independent of the display filter.
    /// `rowsSnapshot` retains those rows while projecting their visible marks;
    /// focused workrooms use this full definition as their stable anchor.
    var projectDefinitionRowsSnapshot: ProjectRowsSnapshot? = nil
    let messageFilterRows: [String: MessageFilterRow]
    /// Lowercased addresses belonging to the local user (every
    /// `Account.emailAddress` + `Identity.address`), resolved at gather
    /// time. Hover readouts use it to tell "addressed to me" apart from
    /// "cc'd to me" when rendering the routing line.
    var userAddresses: Set<String> = []
    /// Resolved, dated deadline observations for the current filter scope —
    /// the raw material for the Deadlines tracker. Kept unclassified so the
    /// tracker can re-derive Upcoming / Past status against the live clock
    /// without a full data refresh.
    var deadlineObservations: [DeadlineObservation] = []

    /// The classified, sorted deadline sections. Built against `now` at read
    /// time so a deadline crossing its due moment moves Upcoming → Past on the
    /// next render, not only on the next data refresh.
    func deadlineTracker(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        dateOverrides: [String: DeadlineDateOverride] = [:]
    ) -> DeadlineTrackerSnapshot {
        DeadlineTracker.build(
            observations: deadlineObservations,
            now: now,
            calendar: calendar,
            dateOverrides: dateOverrides
        )
    }

    var rows: [ProjectRow] {
        rowsSnapshot.rows
    }

    var visibleRows: [ProjectRow] {
        rowsSnapshot.visibleRows
    }

    /// Rendering-ready row list — every project row in the snapshot. (This once
    /// filtered a user-hidden set; the Projects Hide feature was removed, so it
    /// is now a plain passthrough to `visibleRows`.)
    func displayedRows() -> [ProjectRow] {
        rowsSnapshot.visibleRows
    }

    var links: [CrossProjectLink] {
        rowsSnapshot.links
    }

    var projectDefinitionVisibleRows: [ProjectRow] {
        projectDefinitionRowsSnapshot?.visibleRows ?? visibleRows
    }

    var projectDefinitionLinks: [CrossProjectLink] {
        projectDefinitionRowsSnapshot?.links ?? links
    }

    var allowedMessageIDs: [String] {
        Array(Set(rowsSnapshot.allowedMessageIDs.map(\.uuidString))).sorted()
    }

    func allowedMessageIDs(selectedProjectKeys: Set<String>) -> [String] {
        let selected = Set(selectedProjectKeys.map { $0.lowercased() })
        guard selected.isEmpty == false else {
            return allowedMessageIDs
        }
        let selectedRows = visibleRows.filter { selected.contains($0.projectKey) }
        return Array(Set(selectedRows.flatMap(\.messageIDs).map(\.uuidString))).sorted()
    }

    func row(containing messageID: UUID, preferredProjectKey: String? = nil) -> ProjectRow? {
        if let preferredProjectKey,
           let row = visibleRows.first(where: { $0.projectKey == preferredProjectKey && $0.messageIDs.contains(messageID) }) {
            return row
        }
        return visibleRows.first { $0.messageIDs.contains(messageID) }
    }

    func projectDefinitionRow(for projectKey: String) -> ProjectRow? {
        let key = projectKey.lowercased()
        return projectDefinitionVisibleRows.first { $0.projectKey == key }
            ?? visibleRows.first { $0.projectKey == key }
    }

    /// Project identity comes from persisted project and membership rows; the
    /// refreshed message-filter rows decide which of its email cards remain in
    /// the current top-bar scope.
    func filteredMarks(in row: ProjectRow) -> [ProjectMessageMark] {
        row.marks.filter { messageFilterRows[$0.messageID.uuidString] != nil }
    }
}
