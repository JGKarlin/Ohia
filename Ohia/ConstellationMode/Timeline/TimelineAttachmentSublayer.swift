import SwiftUI
import OhiaCore

/// Per-track attachment subtrack rendering helpers. When
/// `attachmentSubtracksVisible` is on and the user has expanded a track's
/// attachment subtrack, the canvas reserves vertical space below the
/// track's centerline and draws per-attachment dots tinted by kind.
///
/// Initial scaffold — full subtrack rendering lands in a follow-up.
enum TimelineAttachmentSublayer {
    static let standardSubtrackHeight: CGFloat = 8

    static func tint(for kind: TimelineAttachmentKind) -> Color {
        switch kind {
        case .pdf:          return OhiaColors.accentOrange
        case .spreadsheet:  return OhiaColors.accentGreen
        case .presentation: return OhiaColors.accentPink
        case .document:     return OhiaColors.accentBlue
        case .image:        return OhiaColors.accentTeal
        case .archive:      return OhiaColors.textSecondary
        case .audio, .video, .code, .other:
                            return OhiaColors.textSecondary
        }
    }

    /// SF Symbol name used to ornament an attachment chip / hover. Chosen to
    /// read as the file type at small sizes — `doc.fill` for prose-like
    /// formats, `tablecells.fill` for spreadsheets, etc.
    static func symbolName(for kind: TimelineAttachmentKind) -> String {
        switch kind {
        case .pdf:          return "doc.fill"
        case .spreadsheet:  return "tablecells.fill"
        case .presentation: return "rectangle.stack.fill"
        case .document:     return "doc.text.fill"
        case .image:        return "photo.fill"
        case .archive:      return "archivebox.fill"
        case .audio:        return "waveform"
        case .video:        return "film.fill"
        case .code:         return "chevron.left.forwardslash.chevron.right"
        case .other:        return "paperclip"
        }
    }
}
