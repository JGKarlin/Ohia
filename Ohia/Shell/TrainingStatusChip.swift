// Ohia/Shell/TrainingStatusChip.swift
// Activity-strip chip for training status. Reads TrainingStatusPublisher
// from the environment; label truth-table mirrors the design spec §7.

import SwiftUI
import OhiaML

struct TrainingStatusChip: View {
    let onTap: () -> Void

    @Environment(TrainingStatusPublisher.self) private var publisher: TrainingStatusPublisher?

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(OhiaTypography.mono)
                .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contextMenu { chipContextMenu }
    }

    private var label: String {
        guard let pub = publisher else { return "training · —" }
        if pub.isPaused { return "training · paused" }
        if case .idle = pub.phase, pub.lastError != nil {
            // The strip chip states the condition; the full error text
            // lives untruncated in the tooltip (no dots-truncation in
            // displayed text, per house rule).
            return "training · error"
        }
        switch pub.phase {
        case .preparing:
            return "training · preparing"
        case .training:
            return "training · incorporated \(pub.incorporatedTargetCount)/\(pub.runTargetCount)"
        case .checkpointing(let step):
            return "training · checkpoint @ \(step)"
        case .resetting:
            return "training · resetting"
        case .idle:
            if let wait = pub.resourceWaitReason {
                return "training · waiting · \(wait)"
            }
            guard let last = pub.lastRunAt else { return "training · no runs yet" }
            let hoursAgo = Date().timeIntervalSince(last) / 3600.0
            if hoursAgo > 24 * 7 {
                let days = Int(hoursAgo / 24)
                return "training · stale · \(days)d"
            }
            return "training · idle · updated \(relativeLabel(hoursAgo))"
        }
    }

    private var foreground: Color {
        guard let pub = publisher else { return OhiaColors.textSecondary }
        if case .idle = pub.phase, pub.lastError != nil { return OhiaColors.frameUrgencyHigh }
        if pub.isPaused { return OhiaColors.textTertiary }
        return OhiaColors.textSecondary
    }

    private var tooltip: String {
        guard let pub = publisher else { return "training status" }
        var bits: [String] = []
        bits.append("phase: \(phaseDescription(pub.phase))")
        bits.append("pending evidence revisions: \(pub.pendingTrainingTargetCount)")
        bits.append("attempted: \(pub.attemptedTargetCount)/\(pub.runTargetCount)")
        bits.append("incorporated: \(pub.incorporatedTargetCount)/\(pub.runTargetCount)")
        if let wait = pub.resourceWaitReason { bits.append("waiting: \(wait)") }
        if let step = pub.adapterStep { bits.append("adapter step: \(step)") }
        if let err = pub.lastError { bits.append("last error: \(err)") }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private var chipContextMenu: some View {
        Button("Train Now") { AppCommand.trainingTrainNow() }
        Button(publisher?.isPaused == true ? "Resume Training" : "Pause Training") {
            AppCommand.trainingTogglePause()
        }
        Divider()
        Button("Open Training Settings") { AppCommand.openTrainingSettings() }
    }

    private func phaseDescription(_ phase: TrainingStatusPublisher.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .training(let s, let t, let l): "training \(s)/\(t) loss \(String(format: "%.3f", l))"
        case .checkpointing(let s): "checkpointing @ \(s)"
        case .resetting: "resetting"
        }
    }

    private func relativeLabel(_ hoursAgo: Double) -> String {
        if hoursAgo < 1 {
            let minutes = max(1, Int(hoursAgo * 60))
            return "\(minutes)m ago"
        }
        if hoursAgo < 24 { return "\(Int(hoursAgo))h ago" }
        return "\(Int(hoursAgo / 24))d ago"
    }
}
