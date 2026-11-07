// Ohia/Shell/DeletionSyncChip.swift
import SwiftUI
import OhiaCore
import OhiaML

/// Activity-strip chip reporting server-side deletion sync state. Mirrors
/// the steady-state idiom of `OutboxChipView` and `TrainingStatusChip`:
/// the label shows the highest-priority concern (aborts → pending →
/// recent-this-session → idle), with a tooltip carrying the full snapshot.
///
/// Reads the publisher off `AppServices` directly rather than via a
/// dedicated `@Environment(DeletionSyncStatusPublisher.self)` injection,
/// so it works the same way regardless of whether OhiaApp wires that
/// extra env entry. AppServices is already injected app-wide.
struct DeletionSyncChip: View {
    var showsDot = true

    @Environment(AppServices.self) private var appServices: AppServices?

    private var publisher: DeletionSyncStatusPublisher? {
        appServices?.deletionSyncStatusPublisher
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(OhiaTypography.mono)
                .foregroundStyle(foreground)
        }
        .help(tooltip)
    }

    private var label: String {
        guard let snap = publisher?.snapshot else { return "deletions · —" }
        if snap.aborts > 0 { return "deletions · \(snap.aborts) abort\(snap.aborts == 1 ? "" : "s")" }
        if snap.pendingDeletionCount > 0 { return "deletions · \(snap.pendingDeletionCount) pending" }
        if snap.sessionRemovals > 0 { return "deletions · \(snap.sessionRemovals) this session" }
        return "deletions · idle"
    }

    private var foreground: Color {
        guard let snap = publisher?.snapshot else { return OhiaColors.textSecondary }
        if snap.aborts > 0 { return OhiaColors.frameUrgencyHigh }
        return OhiaColors.textSecondary
    }

    private var dotColor: Color {
        guard let snap = publisher?.snapshot else { return OhiaColors.textTertiary }
        if snap.aborts > 0 { return OhiaColors.frameUrgencyHigh }
        if snap.pendingDeletionCount > 0 { return OhiaColors.accentOrange }
        if snap.sessionRemovals > 0 { return OhiaColors.accentTeal }
        return OhiaColors.textTertiary
    }

    private var tooltip: String {
        guard let snap = publisher?.snapshot else { return "deletion sync status" }
        var bits: [String] = []
        if let last = snap.lastSyncAt {
            let secs = max(0, Int(-last.timeIntervalSinceNow))
            let folder = snap.lastFolder ?? "?"
            bits.append("last sync: \(secs)s ago (\(folder))")
        } else {
            bits.append("last sync: never")
        }
        bits.append("capability: \(capabilityLabel(snap.lastSyncCapability))")
        bits.append("session: \(snap.sessionRemovals)")
        bits.append("lifetime: \(snap.lifetimeRemovals)")
        bits.append("pending: \(snap.pendingDeletionCount)")
        bits.append("aborts: \(snap.aborts)")
        return bits.joined(separator: " · ")
    }

    private func capabilityLabel(_ cap: DeletionSyncStatusPublisher.Capability) -> String {
        switch cap {
        case .qresync:            "QRESYNC"
        case .fallbackUIDSearch:  "UID SEARCH"
        case .unknown:            "—"
        }
    }
}
