import SwiftUI
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

/// Per-row at-rest obligation indicator. Mounted as a SwiftUI overlay on
/// top of the Projects time canvas inside the same ScrollView so it scrolls
/// with the underlying activity rows.
///
/// Signal: presence + count + kind via a vertical pip column on the trailing
/// edge — yellow pip per pending-reply obligation, green pip per confirmation,
/// "+n" overflow chip when the total exceeds the visible cap.
struct ProjectsObligationOverlay: View {
    let entries: [ProjectsTimeDisplayEntry]
    let layout: ProjectsTimeEntryLayout

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .section, .draft:
                    Color.clear
                        .frame(height: layout.height(for: entry))
                        .allowsHitTesting(false)
                case .row(let row):
                    ProjectsObligationRow(row: row)
                        .opacity(Self.isDormantLifecycleRow(row) ? 0.38 : 1)
                        .frame(height: layout.height(for: entry))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hit testing intentionally left enabled so the trailing-edge pip
        // column can receive hover for its tooltip. Empty row areas (the
        // leading Spacer) and the trailing VStack Spacer carry no hit
        // shape, so canvas hovers/clicks underneath still pass through —
        // only the pip column's contentShape becomes hit-testable.
    }

    private static func isDormantLifecycleRow(_ row: ProjectRow) -> Bool {
        row.status == .resolved
            || row.status == .quiet
            || row.lifecycleAssessment.state == .inactive
    }
}

private struct ProjectsObligationRow: View {
    let row: ProjectRow

    var body: some View {
        let pending = row.obligationLoad.pendingReplyCount
        let confirms = row.obligationLoad.confirmationCount
        let deadlines = row.deadlineTicks.count

        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if pending > 0 || confirms > 0 || deadlines > 0 {
                ProjectsObligationPipColumn(
                    pendingCount: pending,
                    confirmationCount: confirms,
                    deadlineCount: deadlines
                )
                .padding(.trailing, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct ProjectsObligationPipColumn: View {
    let pendingCount: Int
    let confirmationCount: Int
    let deadlineCount: Int

    private let pipWidth: CGFloat = 14
    private let pipHeight: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxVisible: Int = 6

    /// Hover summary using the same noun phrases as the legend's pip
    /// section (pending replies / confirmations / deadlines), with
    /// singular/plural agreement. Joined by `, ` when multiple groups
    /// are present so the bubble reads as a short sentence fragment.
    private var tooltipText: String {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending \(pendingCount == 1 ? "reply" : "replies")")
        }
        if confirmationCount > 0 {
            parts.append("\(confirmationCount) confirmation\(confirmationCount == 1 ? "" : "s")")
        }
        if deadlineCount > 0 {
            parts.append("\(deadlineCount) deadline\(deadlineCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        // Allocation order: pending → confirmation → deadline. Pending claims first,
        // deadline takes whatever visible slots remain. Total visible pips across the
        // three groups never exceeds `maxVisible`; the rest spills into "+n".
        let total = pendingCount + confirmationCount + deadlineCount
        let overflow = max(0, total - maxVisible)
        let pendingShown = min(pendingCount, maxVisible)
        let confirmShown = min(confirmationCount, max(0, maxVisible - pendingShown))
        let deadlineShown = min(deadlineCount, max(0, maxVisible - pendingShown - confirmShown))

        VStack(alignment: .trailing, spacing: spacing) {
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ObligationKindColor.pendingReply)
                    .frame(height: 10)
            }
            ForEach(0..<pendingShown, id: \.self) { _ in
                Capsule()
                    .fill(ObligationKindColor.pendingReply)
                    .frame(width: pipWidth, height: pipHeight)
            }
            if pendingShown > 0 && confirmShown > 0 {
                Rectangle()
                    .fill(OhiaColors.glassBorder.opacity(0.6))
                    .frame(width: pipWidth, height: 0.6)
            }
            ForEach(0..<confirmShown, id: \.self) { _ in
                Capsule()
                    .fill(ObligationKindColor.confirmation)
                    .frame(width: pipWidth, height: pipHeight)
            }
            if confirmShown > 0 && deadlineShown > 0 {
                Rectangle()
                    .fill(OhiaColors.glassBorder.opacity(0.6))
                    .frame(width: pipWidth, height: 0.6)
            }
            ForEach(0..<deadlineShown, id: \.self) { _ in
                Capsule()
                    .fill(ObligationKindColor.deadline)
                    .frame(width: pipWidth, height: pipHeight)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .tooltip(tooltipText, anchor: .trailingSide)
    }
}
