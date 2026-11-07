// Ohia/Settings/RemoteImageAllowlistSection.swift
// Settings affordance for reviewing and revoking the per-sender "remote
// images" trust allowlist. Remote images are blocked by default for privacy
// (a remote load leaks open-time and IP to the sender); a sender the user has
// trusted via "Always from this sender" appears here and can be revoked.
//
// Backed by `RemoteImageSenderAllowlist.shared` (a `@MainActor @Observable`
// singleton). Reading `.allowedSenders` inside `body` auto-tracks, so calling
// `disallow` removes the row live without any explicit state mirror.

import SwiftUI

/// The "Remote images" settings card: an explanatory caption, one row per
/// trusted sender (sorted alphabetically) with a revoke control, and a muted
/// empty state when nothing is trusted yet.
struct RemoteImageAllowlistSection: View {
    /// Collapsed by default — the allowlist can grow long, so it sits behind a
    /// disclosure matching the Identity / History pulldowns in account settings.
    @State private var isExpanded = false

    private var allowlist: RemoteImageSenderAllowlist { .shared }

    private var sortedSenders: [String] {
        allowlist.allowedSenders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        // Compute once per render (the set is read three ways below).
        let senders = sortedSenders
        OhiaSettingsCard("Remote images") {
            SettingsCaption("Remote images are blocked by default for privacy. Senders you trust to load them automatically are listed below.")
            SettingsRowDivider()
            SettingsBlock {
                DisclosureGroup(isExpanded: $isExpanded) {
                    if senders.isEmpty {
                        Text("No trusted senders yet.")
                            .font(.callout)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(senders, id: \.self) { sender in
                                senderRow(sender)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.leading, 4)
                    }
                } label: {
                    // Pulldown label with a count once any sender is trusted
                    // (mirrors the "Identities (N)" pattern).
                    Text(senders.isEmpty ? "Trusted senders" : "Trusted senders (\(senders.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func senderRow(_ sender: String) -> some View {
        HStack(spacing: 10) {
            Text(sender)
                .font(.callout)
                .foregroundStyle(OhiaColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            RemoteImageRevokeButton {
                allowlist.disallow(sender)
            }
        }
    }
}

/// Icon-only revoke control matching the file-local `MemoryEmblemButton`
/// idiom — a destructive trash glyph inside emblem framing. Uses
/// `.buttonStyle(.plain)` (per the row-action precedent in MemoriesSettingsView)
/// rather than `.buttonStyle(.emblem)` so the framing is drawn at icon-button
/// scale rather than a label pill.
private struct RemoteImageRevokeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaRed)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.buttonBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Stop trusting — block this sender's remote images again")
        .accessibilityLabel("Stop trusting")
    }
}
