import SwiftUI
import OhiaCore

/// Lane label column on the left side of the multitrack area. One row per
/// `TimelineMultitrackRow` — sender, receiver, attachments, Purpose,
/// thread, account, status. Each row carries an SF Symbol + display label
/// + the row-scoped solo/mute toggles. Solo overrides mute; both flow
/// through `TimelineWorkspaceState.toggleSolo` / `toggleMute(_:)`.
struct TimelineRowGutter: View {

    @Bindable var workspace: TimelineWorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            ForEach(TimelineMultitrackRow.allCases, id: \.self) { row in
                gutterRow(for: row)
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(height: 1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func gutterRow(for row: TimelineMultitrackRow) -> some View {
        // Neutral icon + label — `textSecondary` (faint) so the gutter
        // reads as quiet metadata labels rather than competing with the
        // canvas content. Per-row accent colors are still applied to
        // the canvas chips (see `TimelineMultitrackRowPalette.accent(for:)`);
        // the gutter stays chromatically AND tonally quiet.
        HStack(spacing: 6) {
            Image(systemName: row.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.textSecondary)
                .frame(width: 14)
            Text(row.displayLabel)
                .font(.system(size: 11, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(OhiaColors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .help(helpText(for: row))
    }

    private func helpText(for row: TimelineMultitrackRow) -> String {
        switch row {
        case .sender:      return "Who sent the focused email"
        case .receiver:    return "Who received the focused email (To / Cc / Bcc)"
        case .attachments: return "Attachments on the focused email"
        case .purpose:     return "Category of the focused email"
        case .thread:      return "Thread span containing the focused email"
        case .account:     return "Mailbox the focused email lives in"
        }
    }
}
