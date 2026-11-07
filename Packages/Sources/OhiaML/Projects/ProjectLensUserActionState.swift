import Foundation

/// Message-level actions shared across Projects, Front Page, Timeline, and
/// other message surfaces. First-class `MailProject` rows own project name,
/// pinning, ordering, explicit resolution, and membership.
public struct ProjectLensSharedMessageActionState: Sendable, Hashable {
    public var resolvedMessageIDs: Set<UUID>
    public var replyNeededMessageIDs: Set<UUID>
    public var repliedMessageIDs: Set<UUID>
    public var confirmationNeededMessageIDs: Set<UUID>
    public var confirmedMessageIDs: Set<UUID>

    public init(
        resolvedMessageIDs: Set<UUID> = [],
        replyNeededMessageIDs: Set<UUID> = [],
        repliedMessageIDs: Set<UUID> = [],
        confirmationNeededMessageIDs: Set<UUID> = [],
        confirmedMessageIDs: Set<UUID> = []
    ) {
        self.resolvedMessageIDs = resolvedMessageIDs
        self.replyNeededMessageIDs = replyNeededMessageIDs
        self.repliedMessageIDs = repliedMessageIDs
        self.confirmationNeededMessageIDs = confirmationNeededMessageIDs
        self.confirmedMessageIDs = confirmedMessageIDs
    }

    public static let empty = ProjectLensSharedMessageActionState()

    /// Source-compatible projection for message surfaces that previously
    /// received the broader Projects action state.
    public var sharedMessageActions: ProjectLensSharedMessageActionState { self }
}

/// Temporary source-compatible name for non-Projects consumers being moved to
/// the explicit shared-message type. It contains no project state or APIs.
public typealias ProjectLensUserActionState = ProjectLensSharedMessageActionState
