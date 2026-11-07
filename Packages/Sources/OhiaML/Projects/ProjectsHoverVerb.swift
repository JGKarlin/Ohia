import Foundation

/// Pure derivation of the obligation verb / icon / tint shown in the
/// Projects-lens hover pane header.
///
/// Decoupled from SwiftUI so the cascade (pending → confirmation →
/// deadline → outgoing → incoming) is unit-testable headlessly. The
/// rendering layer (`ProjectsHoverPopup`) maps `tint` and `directionTint`
/// to `Color` and `symbolName` to an `Image(systemName:)`.
public enum ProjectsHoverVerb: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case pendingReply
        case confirmation
        case deadline
        /// Neutral: routine sent/received message with no open obligation
        /// or evidence-backed deadline.
        case neutral
    }

    case replyNeeded
    case confirmationPending
    case deadline
    case sentReply
    case received

    /// Human label rendered next to the SF Symbol in the header.
    public var label: String {
        switch self {
        case .replyNeeded: return "Reply needed"
        case .confirmationPending: return "Confirmation pending"
        case .deadline: return "Deadline"
        case .sentReply: return "Sent reply"
        case .received: return "Received"
        }
    }

    /// SF Symbol name rendered before the verb label.
    public var symbolName: String {
        switch self {
        case .replyNeeded: return "arrowshape.turn.up.left.fill"
        case .confirmationPending: return "checkmark.seal.fill"
        case .deadline: return "calendar"
        case .sentReply: return "paperplane.fill"
        case .received: return "tray.and.arrow.down.fill"
        }
    }

    /// Tint applied to the icon + verb label in the header AND to the
    /// trailing "DAYS" age counter. Mirrors the row's pip column so the
    /// pane and the at-rest indicator carry the same color signal.
    public var tint: Tint {
        switch self {
        case .replyNeeded: return .pendingReply
        case .confirmationPending: return .confirmation
        case .deadline: return .deadline
        case .sentReply, .received: return .neutral
        }
    }

    /// Cascade resolution.
    ///
    /// Order matches the pip column's pending-before-confirmation rule
    /// in `ProjectsObligationOverlay`: when a message carries both
    /// `pendingReply` and `confirmation`, pending wins for both icon and
    /// tint. Deadline is a strictly weaker signal than an open
    /// obligation, and falls back further to the direction-only verb
    /// when no obligation/deadline is present.
    public static func resolve(
        obligationKinds: Set<ProjectOpenObligation.Kind>,
        hasDeadline: Bool,
        isOutgoing: Bool
    ) -> ProjectsHoverVerb {
        if obligationKinds.contains(.pendingReply) { return .replyNeeded }
        if obligationKinds.contains(.confirmation) { return .confirmationPending }
        if hasDeadline { return .deadline }
        return isOutgoing ? .sentReply : .received
    }
}
