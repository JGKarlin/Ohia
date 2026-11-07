// Ohia/Shell/OutboxChipView.swift
import SwiftUI
import OhiaCore

struct OutboxChipView: View {
    let snapshot: OutboxActivitySnapshotStore
    var showsActivityCells = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if showsActivityCells {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(cellColor(index: i))
                            .frame(width: 6, height: 6)
                    }
                }
                Text(label)
                    .font(OhiaTypography.mono)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private var label: String {
        let b = snapshot.breakdown
        if b.failed > 0 { return "outbox: \(b.failed) failed" }
        if b.sending > 0 { return "outbox: sending" }
        if b.queued > 0 { return "outbox: \(b.queued) queued" }
        if b.sentToday > 0 { return "outbox: \(b.sentToday) sent today" }
        return "outbox: idle"
    }

    private var tooltip: String {
        let b = snapshot.breakdown
        return "queued: \(b.queued) · sending: \(b.sending) · failed: \(b.failed) · sent today: \(b.sentToday)"
    }

    private func cellColor(index: Int) -> Color {
        guard index < snapshot.recentItems.count else {
            return OhiaColors.textDim.opacity(0.2)
        }
        switch snapshot.recentItems[index].status {
        case .queued:    return OhiaColors.textTertiary
        case .sending:   return OhiaColors.accentBlue
        case .sent:      return OhiaColors.statusReady.opacity(0.6)
        case .failed:    return OhiaColors.frameUrgencyHigh
        case .cancelled: return OhiaColors.textDim.opacity(0.3)
        }
    }
}
