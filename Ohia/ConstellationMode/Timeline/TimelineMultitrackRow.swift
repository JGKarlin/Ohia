import Foundation
import SwiftUI
import OhiaCore

/// Fixed semantic rows of the NLE-style multitrack. Each row exposes one
/// attribute of the playhead-focused email as an NLE-style clip; other
/// emails in the visible window render as faded context ticks across every
/// row at their respective x-positions.
///
/// Purpose appears as a chip within the `.purpose` row; Context and Delivery
/// remain independent facets and never impersonate Purpose.
public enum TimelineMultitrackRow: String, CaseIterable, Sendable, Codable, Hashable {
    case sender
    case receiver
    case attachments
    case purpose
    case thread
    case account

    public var displayLabel: String {
        switch self {
        case .sender:      return "Sender"
        case .receiver:    return "Receiver"
        case .attachments: return "Attachments"
        case .purpose:     return "Category"
        case .thread:      return "Thread"
        case .account:     return "Account"
        }
    }

    public var symbolName: String {
        switch self {
        case .sender:      return "person.crop.circle"
        case .receiver:    return "person.2.circle"
        case .attachments: return "paperclip.circle"
        case .purpose:     return "mail.stack.fill"
        case .thread:      return "bubble.left.and.bubble.right"
        case .account:     return "envelope.circle"
        }
    }
}

enum TimelineMultitrackRowPalette {
    /// Chip accent. The sender / receiver rows carry a send-direction
    /// identity that mirrors the minimap's diverging density histogram —
    /// sender (the "sent" axis) in leaf-green `ohiaGreen`, receiver (the
    /// "received" axis) in stamen-yellow `ohiaYellow`. Every other row
    /// stays a single neutral tone (`OhiaColors.textSecondary`) so the
    /// rest of the multitrack reads as a chromatically quiet inspector,
    /// with row identity carried by the gutter icon + label.
    static func accent(for row: TimelineMultitrackRow) -> Color {
        switch row {
        case .sender:   return OhiaColors.ohiaGreen
        case .receiver: return OhiaColors.ohiaYellow
        default:        return OhiaColors.textSecondary
        }
    }
}
