import Foundation

/// Documented Timeline keybindings. The actual handlers live on
/// `TimelinePlayheadInput`; this file exists so a single place lists every
/// chord and what it does, for AGENTS.md regression tests.
///
/// - `←` / `→`: prev / next message (chapter-overflow in conv mode)
/// - `shift-←` / `shift-→`: ±1 day in clock time
/// - `opt-←` / `opt-→`: ±1 week in clock time
/// - `cmd-←` / `cmd-→`: skip prev / next chapter (both modes)
/// - `[` / `]`: set bracket start / end (follow-up; not yet wired)
/// - `0`: reset zoom (follow-up)
enum TimelineKeybinding: String {
    case stepBackward
    case stepForward
    case dayBack
    case dayForward
    case weekBack
    case weekForward
    case chapterPrev
    case chapterNext
    case bracketStart
    case bracketEnd
    case resetZoom
}
