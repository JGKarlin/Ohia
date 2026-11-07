import Foundation
import OhiaCore

/// What the user's pointer is currently hovering over inside the Timeline
/// workspace. Drives hover tooltips, cursor changes, and the optional
/// hairline glow on adjacent UI (chapter labels, gutter rows).
public enum TimelineHoverTarget: Hashable, Sendable {
    case clip(threadID: UUID)
    case event(messageID: UUID)
    /// Faded per-row context pip under the pointer — click navigates to
    /// that message at its date on the shared time axis.
    case contextTick(messageID: UUID, row: TimelineMultitrackRow)
    case attachment(attachmentID: UUID, parentMessageID: UUID)
    case correspondentChip(email: String)
    case densityBand(purpose: MailPurpose, range: ClosedRange<Date>)
    case chapterLabel(chapterID: UUID)
    case ruler(date: Date)
}

/// Discriminated hit-test result used by `TimelineHitTester` to translate
/// a `(track, x)` point into a concrete target the workspace state can act
/// on. Mirrors `TimelineHoverTarget` but kept distinct so click handlers
/// can switch exhaustively without sharing a vocabulary with hover.
public enum TimelineHitTarget: Hashable, Sendable {
    case clip(threadID: UUID, anchorMessageID: UUID, anchorDate: Date)
    case event(messageID: UUID, date: Date)
    case attachment(attachmentID: UUID, parentMessageID: UUID, date: Date)
    case correspondentChip(email: String)
    case densityBand(purpose: MailPurpose, range: ClosedRange<Date>)
    case chapter(chapterID: UUID, snapDate: Date)
    case empty
}
