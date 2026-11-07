import Foundation
import OhiaCore

/// Stable identity for each chip in the Action section. Reply and Confirm
/// mirror the booleans on `TriageVerdict`; Resolved mirrors the explicit
/// per-message user action.
public enum HeadlineToggle: String, CaseIterable, Hashable, Sendable, Codable {
    case actionable
    case confirm
    case resolved
}

/// Stable identity for each toggle in the Traces section. Exists because
/// `StatusFilterChips` currently binds to ad-hoc Bool tri-states on
/// `VectorFilter` (`readStates`, `repliedStates`, `sentStates`,
/// `flaggedOnly`, `hasAttachmentsOnly`) without a single enum that names
/// each toggle. The toggle-curation feature in step 6 needs that name to
/// persist a per-section displayed-set; the iconography table needs it to
/// pair each toggle with an SF Symbol.
public enum TraceToggle: String, CaseIterable, Hashable, Sendable, Codable {
    case received
    case sent
    case unread
    case read
    case replied
    case unreplied
    case hasAttachments
    /// Reserved for when `Message` gains a `flagged` field. The chip is
    /// hidden today (see the HACK comment in `ConstellationModeView`); the
    /// case is here so downstream code (icon table, persistence) is ready
    /// the moment that field lands.
    case flagged
}

/// SF Symbol pairings for every toolbar toggle. Lives at the UI layer
/// because OhiaCore deliberately doesn't import SwiftUI/AppKit; callers
/// render with `Image(systemName: ToggleIconography.symbolName(for: x))`.
///
/// New toggles are a one-line addition here. The fallback branches on each
/// method ensure unknown / open-coded cases (e.g. a custom `FrameKey`
/// installed by a fork) still get a sensible icon rather than crashing.
public enum ToggleIconography {

    // MARK: - Headline (HeadlineToggle)
    //
    // Reply reuses the exclamation-bubble glyph that the
    // retired Forms `actionable` chip used (vocabulary continuity for
    // returning users). Confirm uses the seal-checkmark — same symbol the
    // retired `confirmation` chip used, so existing muscle memory survives
    // the section relabel.

    public static func symbolName(for headline: HeadlineToggle) -> String {
        switch headline {
        case .actionable: return "exclamationmark.bubble"
        case .confirm:    return "checkmark.seal"
        case .resolved:   return "checkmark.circle"
        }
    }

    // MARK: - Forms (MessageType)

    public static func symbolName(for type: MessageType) -> String {
        switch type {
        case .actionable:    return "exclamationmark.bubble"
        case .report:        return "chart.bar.doc.horizontal"
        case .subscription:  return "newspaper"
        case .receipt:       return "doc.text"
        case .confirmation:  return "checkmark.seal"
        case .unclassified:  return "questionmark.circle"
        }
    }

    // MARK: - Layers (VectorCollection)

    public static func symbolName(for collection: VectorCollection) -> String {
        switch collection {
        case .context:    return "text.alignleft"
        case .style:      return "pencil.tip"
        case .attachment: return "paperclip"
        case .entity:     return "person.2.fill"
        }
    }

    // MARK: - Traces (TraceToggle)

    public static func symbolName(for trace: TraceToggle) -> String {
        switch trace {
        case .received:        return "tray.and.arrow.down"
        case .sent:            return "paperplane.fill"
        case .unread:          return "circle.fill"
        case .read:            return "circle"
        case .replied:         return "arrowshape.turn.up.left"
        // `unreplied` semantically means "this message still needs a
        // response" — `envelope.badge` reads as "message with pending
        // status" and pairs visually with .replied's action-arrow without
        // looking like its inverse (which we tried via
        // `arrowshape.turn.up.left.slash` — that symbol does not exist
        // in the system catalog).
        case .unreplied:       return "envelope.badge"
        case .hasAttachments:  return "paperclip"
        case .flagged:         return "flag.fill"
        }
    }

    // MARK: - Frame (FrameKey)
    //
    // FrameKey is an open string-typed struct so forks can register custom
    // frames without editing OhiaCore. The fallback branch returns a
    // generic graph-node symbol so a custom frame still has an icon.

    public static func symbolName(for frame: FrameKey) -> String {
        switch frame.spatialLens {
        case .frontPage:     return "newspaper"
        case .meaning:       return "circle.grid.2x2"
        case .people:        return "person.2"
        case .timeline:      return "calendar.day.timeline.leading"
        case .projects:      return "folder"
        default:             return "point.3.connected.trianglepath.dotted"
        }
    }

    // MARK: - Lock-overlay purpose
    //
    // The locked-node overlay's category pulldown reuses the toolbar's
    // `MenuPopoverContent` + `MenuRow` vocabulary, so each category needs
    // its own glyph the same way every Forms / Traces / Layers row does.

    public static func symbolName(for purpose: MailPurpose) -> String {
        purpose.systemImageName
    }

    // MARK: - User-defined categories
    //
    // Custom categories share one glyph: the plain tag. The fixed taxonomy
    // owns the domain-specific symbols; user categories are visually unified
    // so a glance distinguishes "system category" from "my category".

    public static let customCategorySymbolName = "tag"
}
