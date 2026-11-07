import SwiftUI

/// Surface-agnostic view model for one inline `[N]` citation. The same
/// struct backs both the locked-overlay context paragraph (sourced from
/// `ContextOrientationCitation`) and the Ask answer (sourced from a
/// retrieved `VectorRecord`), so both surfaces share one chip idiom.
struct InlineCitationSource: Identifiable, Equatable {
    /// 1-based position in the prompt's numbered source list. Renders as
    /// `[N]` inside the chip.
    let index: Int
    let symbolName: String
    let tint: Color
    /// Human-readable label of the citation's pane kind — e.g. "reply",
    /// "attachment", "from same person". Surfaced as the popover's
    /// header chip so the reader knows which evidence pane the citation
    /// leads to before reading From/To/Subject.
    let kindLabel: String
    /// Human-readable title for the cited evidence. For message-backed
    /// citations this usually mirrors the subject; for memory-backed
    /// citations it names the stored memory note.
    let titleLine: String?
    /// Short excerpt from the cited evidence. Nil when the source has no
    /// preview text.
    let excerptLine: String?
    /// Underlying message's `From:` line (display name, optionally with
    /// address). Nil when the source has no sender concept (e.g. an Ask
    /// citation that resolves to an entity vector).
    let fromLine: String?
    /// Underlying message's `To:` line — comma-joined recipient list.
    /// Nil when no recipients are known.
    let toLine: String?
    /// Underlying message's subject. Nil when there's no real subject
    /// (e.g. attachment-only citation with a missing parent).
    let subjectLine: String?
    /// Absolute date plus, when an anchor is available, a relative
    /// "n days earlier/later" tail describing the source's distance
    /// from the locked email. Nil when no date is known.
    let dateLine: String?
    /// Tap action — fly to the source node, or open the matching annotation
    /// pane in the locked overlay.
    let onClick: () -> Void
    /// Hover lifecycle hook — emits non-nil while pointer is over the chip,
    /// nil when it leaves. Surfaces use it to flash the corresponding star.
    let onHover: (Bool) -> Void

    var id: Int { index }

    static func == (lhs: InlineCitationSource, rhs: InlineCitationSource) -> Bool {
        lhs.index == rhs.index
            && lhs.symbolName == rhs.symbolName
            && lhs.kindLabel == rhs.kindLabel
            && lhs.titleLine == rhs.titleLine
            && lhs.excerptLine == rhs.excerptLine
            && lhs.fromLine == rhs.fromLine
            && lhs.toLine == rhs.toLine
            && lhs.subjectLine == rhs.subjectLine
            && lhs.dateLine == rhs.dateLine
            && lhs.tint.description == rhs.tint.description
    }
}
