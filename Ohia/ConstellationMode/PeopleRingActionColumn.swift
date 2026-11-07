import SwiftUI
import OhiaCore

/// Vertical action-disc group for a selected People-lens ring node — an email
/// satellite orbiting the locked correspondent's Saturn. Renders the same disc
/// vocabulary as the Meaning lens locked-email rail (`MeaningRightControlColumn`
/// `actionGroup`): read/unread, reply, send-to-Composer, confirmation,
/// mark-resolved, flag, delete — but targets the single ring email the user
/// clicked rather than the locked main email.
///
/// Mounted inside `peopleFocusCloseButtonColumn` below the legend disc; the
/// host gates it on a resolved `target`, so this view assumes a non-nil target.
/// Disc chrome (38pt disc, surface fill, `chipActiveBorder` ring, tint rules)
/// matches the close / legend discs in the same column.
struct RingNodeActionDiscGroup: View {
    let target: MessageActionDiscTarget
    let actions: FrontPageMessageActionHandlers
    /// Invoked after a destructive delete so the host can clear the ring
    /// selection — the satellite is about to disappear from the scene.
    let onAfterDelete: () -> Void

    private var ids: [UUID] { [target.messageID] }
    private var status: MessageStatusDescriptor { target.statusDescriptor }

    /// Reply disc flips to "mark replied" once the email is in the pending-reply
    /// state, mirroring the Meaning rail's two-state reply affordance.
    private var replyMarksReplied: Bool { status.needsReply }
    /// The reply disc shows its "done" glyph (reply arrow + check) and lights only
    /// when the email is actually replied; every other state shows the bare arrow.
    private var replyIsDone: Bool { status.isReplied }
    private var readMarksRead: Bool { !status.isRead }
    private var showsComposerDisc: Bool {
        !status.isSentByUser && !target.isInComposerQueue
    }

    private var confirmationMode: ConfirmationMode {
        if status.needsConfirmation { return .confirm }
        if status.isConfirmed { return .confirmed }
        return .markNeeded
    }

    var body: some View {
        VStack(spacing: 14) {
            // Dispatch group: compose · resolve · delete.
            if showsComposerDisc {
                // ⌥ still fronts the Composer when the setting calls for it.
                LensComposeDisc(
                    isActive: false,
                    restAccessibility: "Send to Composer",
                    action: { actions.sendToComposer(ids) }
                )
            }

            disc(
                glyph: .native(status.isResolved ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"),
                label: "Resolved",
                help: status.isResolved ? "Reopen" : "Resolved",
                isActive: status.isResolved,
                tint: MessageStatusColors.resolved
            ) {
                actions.setResolved(ids, !status.isResolved)
            }

            disc(
                glyph: .native("xmark.bin.circle.fill"),
                label: "Delete",
                help: "Delete",
                isActive: false,
                destructive: true
            ) {
                actions.delete(ids)
                onAfterDelete()
            }

            Rectangle()
                .fill(OhiaColors.glassBorder.opacity(0.6))
                .frame(height: 1)
                .padding(.horizontal, 14)

            // Status-mark group: confirmation · reply · flag · read. The confirm
            // and reply discs keep a fixed label and swap their glyph to reflect
            // the email's current state — bare seal vs. seal-with-check, plain
            // reply arrow vs. reply-with-check — lit only once confirmed / replied.
            disc(
                glyph: confirmationMode.glyph,
                label: confirmationMode.label,
                help: confirmationMode.help,
                isActive: confirmationMode.isActive,
                tint: MessageStatusColors.confirmation
            ) {
                switch confirmationMode {
                case .confirm: actions.setConfirmed(ids, true)
                case .confirmed: actions.setConfirmed(ids, false)
                case .markNeeded: actions.setConfirmationNeeded(ids, true)
                }
            }

            disc(
                glyph: replyIsDone ? .markReplied : .native("arrowshape.turn.up.left.circle.fill"),
                label: "Replied",
                help: replyMarksReplied ? "Mark replied" : "Mark reply needed",
                isActive: replyIsDone,
                tint: MessageStatusColors.pendingReply
            ) {
                if replyMarksReplied {
                    actions.setReplied(ids, true)
                } else {
                    actions.setReplyNeeded(ids, true)
                }
            }

            disc(
                glyph: status.isFlagged ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
                label: status.isFlagged ? "Unflag" : "Flag",
                help: status.isFlagged ? "Unflag" : "Flag",
                isActive: status.isFlagged,
                tint: MessageStatusColors.flagged
            ) {
                actions.setFlagged(ids, !status.isFlagged)
            }

            disc(
                glyph: readMarksRead ? .knockout("envelope.open.fill") : .native("envelope.circle.fill"),
                label: readMarksRead ? "Read" : "Unread",
                help: readMarksRead ? "Mark read" : "Mark unread",
                isActive: status.isRead == false,
                tint: MessageReadStateMarkStyle.unreadGloss
            ) {
                actions.setRead(ids, readMarksRead)
            }

            if target.isListIgnoreEligible {
                disc(
                    glyph: .native("eye.slash.circle.fill"),
                    label: "Ignore",
                    help: "Ignore",
                    isActive: false,
                    tint: OhiaColors.ohiaYellow
                ) {
                    actions.ignore(target.messageID)
                }
            }
        }
    }

    // MARK: - Disc rendering (mirrors MeaningRightControlColumn.controlDisc)

    private func disc(
        glyph: ActionDiscGlyph,
        label: String,
        help: String,
        isActive: Bool,
        tint: Color? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        LensActionDisc(
            glyph: glyph,
            label: label,
            accessibility: help,
            isActive: isActive,
            tint: tint,
            destructive: destructive,
            action: action
        )
    }

    private enum ConfirmationMode {
        case confirm
        case confirmed
        case markNeeded

        /// The confirmation state reads through the seal: the check appears only
        /// once the email is confirmed; the pending / mark-needed states show the
        /// bare seal. The dedicated Resolve disc owns the circle-check.
        var glyph: ActionDiscGlyph {
            switch self {
            case .confirmed: return .knockout("checkmark.seal.fill")
            case .confirm, .markNeeded: return .knockout("seal.fill")
            }
        }

        /// Fixed label across every state — the disc names the confirmation axis
        /// and the glyph carries the state.
        var label: String { "Confirmed" }

        var help: String {
            switch self {
            case .confirm: return "Mark confirmed"
            case .confirmed: return "Mark unconfirmed"
            case .markNeeded: return "Mark confirmation needed"
            }
        }

        var isActive: Bool {
            switch self {
            case .confirmed: return true
            case .confirm, .markNeeded: return false
            }
        }
    }
}
