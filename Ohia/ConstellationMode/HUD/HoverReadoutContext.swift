// HoverReadoutContext.swift
// Value-type bundle of everything the hover popup needs to render. Built
// once per cursor-over-node event by the parent (ConstellationModeView)
// from the hovered VectorRecord, the cached MessageFilterRow, and the
// on-demand summary state. The view itself is pure presentation — every
// visible glyph or string is a field on this struct, so the readout has
// nothing to derive at render time.

import Foundation
import OhiaCore
import OhiaML

public struct HoverAccountContext: Sendable, Equatable {
    public let displayName: String
    public let emailAddress: String
    public let colorIndex: Int

    public init(displayName: String, emailAddress: String, colorIndex: Int) {
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.colorIndex = colorIndex
    }

    public var accountColor: AccountColor {
        AccountColorPalette.color(forIndex: colorIndex)
    }

    public var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown account" : trimmed
    }
}

public struct HoverReadoutContext: Sendable, Equatable {
    public static let defaultNeighborThreshold: Float = 0.60

    public let messageId: String
    public let account: HoverAccountContext?
    public let subject: String
    public let fromName: String?
    public let fromAddress: String
    public let receivedAt: Date?
    /// The line shown in italics under the subject. This is the generated
    /// `bodySummary` only; pending summaries are represented by
    /// `summaryIsLoading` rather than substitute body text.
    public let summary: String?
    /// `true` if `summary` came from the generated `bodySummary`.
    public let summaryIsActual: Bool
    /// `true` while a hover-triggered summary request is expected but has
    /// not yet produced a generated summary.
    public let summaryIsLoading: Bool
    /// Short user-visible failure/retry reason when Qwen cannot produce a
    /// hover summary. `nil` while loading, when a summary exists, or when no
    /// summary is expected.
    public let summaryUnavailableReason: String?
    /// Resolved Purpose stored alongside the generated summary. `nil` when
    /// classification is pending or abstained.
    public let summaryPurpose: MailPurpose?
    /// Triage headline flags extracted from the generated verdict. These
    /// are intentionally rendered separately from classification facets.
    public let isActionable: Bool?
    public let requiresConfirmation: Bool?
    /// Up to two top canonical tags by score.
    public let topTags: [String]
    /// Pre-formatted deadline tag string (e.g. "Deadline (June 24, 2026)") or `nil`.
    public let deadlineLabel: String?
    public let isReplied: Bool
    public let isFlagged: Bool
    public let hasAttachments: Bool
    public let isSentByUser: Bool
    /// People-lens ring tier the hovered email lands on for the
    /// currently-focused correspondent — drives the hover popup's top
    /// line so the label matches which ring the satellite sits on
    /// (e.g. "received cc'd" instead of the generic "received" when
    /// the focused correspondent was Cc'd on an inbound third-party
    /// message). `nil` outside People focus and
    /// for non-People rows; the hover then falls back to the binary
    /// sent/received label keyed off `isSentByUser`.
    public let peopleRingTier: PersonRingInstance.Tier?

    public init(
        messageId: String,
        account: HoverAccountContext? = nil,
        subject: String,
        fromName: String?,
        fromAddress: String,
        receivedAt: Date?,
        summary: String?,
        summaryIsActual: Bool,
        summaryIsLoading: Bool,
        summaryUnavailableReason: String?,
        summaryPurpose: MailPurpose?,
        isActionable: Bool?,
        requiresConfirmation: Bool?,
        topTags: [String],
        deadlineLabel: String?,
        isReplied: Bool,
        isFlagged: Bool,
        hasAttachments: Bool,
        isSentByUser: Bool,
        peopleRingTier: PersonRingInstance.Tier? = nil
    ) {
        self.messageId = messageId
        self.account = account
        self.subject = subject
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.receivedAt = receivedAt
        self.summary = summary
        self.summaryIsActual = summaryIsActual
        self.summaryIsLoading = summaryIsLoading
        self.summaryUnavailableReason = summaryUnavailableReason
        self.summaryPurpose = summaryPurpose
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.topTags = topTags
        self.deadlineLabel = deadlineLabel
        self.isReplied = isReplied
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.isSentByUser = isSentByUser
        self.peopleRingTier = peopleRingTier
    }
}

public extension HoverReadoutContext {
    /// Builds a context from a `MessageFilterRow` and an optional live
    /// summary override. The hover readout displays generated summaries
    /// only; while no generated summary is available, `summaryIsLoading`
    /// controls the animated placeholder slot.
    init(
        messageId: String,
        row: MessageFilterRow,
        summaryOverride: String? = nil,
        classificationOverride: MailClassification? = nil,
        summaryUnavailableReason: String? = nil,
        summaryIsRegenerating: Bool = false,
        summaryIsLoading: Bool,
        account: HoverAccountContext? = nil,
        /// When supplied and non-nil, the hover popup labels the
        /// hovered email by its People-lens ring tier relative to
        /// this focused correspondent (e.g. "received cc'd"
        /// when this person was just Cc'd on a third-party inbound
        /// message). Use the locked correspondent's email when in
        /// People focus; leave `nil` outside People focus so the
        /// hover falls back to the binary sent/received label.
        peopleFocusEmail: String? = nil
    ) {
        let override = summaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let classification = classificationOverride ?? row.mailClassification
        let actual: String? = {
            guard !summaryIsRegenerating else { return nil }
            if override?.isEmpty == false {
                return override
            }
            if stored?.isEmpty == false, classification != nil {
                return stored
            }
            return nil
        }()

        let tags: [String] = {
            guard let dims = row.dimensions else { return [] }
            return SemanticTagProjectionPresentation.topDisplayLabels(in: dims, limit: 2)
        }()

        let deadline: String? = {
            guard let dims = row.dimensions else { return nil }
            // Prefer hard, then soft. Skip conditional for the chip — too noisy.
            let candidates = dims.deadlines.filter { $0.type == "hard" || $0.type == "soft" }
            guard let raw = candidates.compactMap(\.displayText).first else { return nil }
            return "Deadline (\(raw))"
        }()

        // Resolve the People-lens ring tier for the hovered email
        // relative to the focused correspondent. The canonical
        // classifier in OhiaCore is the same one PeopleGraphBuilder
        // uses to place the satellite on a ring band — so the hover
        // label can never disagree with which ring the dot is on.
        let tier: PersonRingInstance.Tier? = peopleFocusEmail.flatMap { hub in
            PersonRingInstance.Tier.classify(
                isSentByUser: row.isSentByUser,
                fromAddress: row.fromAddress,
                toAddresses: row.toAddresses,
                recipientAddresses: row.recipientAddresses,
                hubEmail: hub
            )
        }

        self.init(
            messageId: messageId,
            account: account,
            subject: row.subject,
            fromName: row.fromName,
            fromAddress: row.fromAddress,
            receivedAt: row.receivedAt,
            summary: actual,
            summaryIsActual: actual?.isEmpty == false,
            summaryIsLoading: summaryIsRegenerating || (actual?.isEmpty != false && summaryIsLoading),
            summaryUnavailableReason: actual?.isEmpty == false || summaryIsRegenerating ? nil : summaryUnavailableReason,
            summaryPurpose: actual?.isEmpty == false ? classification?.purpose : nil,
            isActionable: row.isActionable,
            requiresConfirmation: row.requiresConfirmation,
            topTags: tags,
            deadlineLabel: deadline,
            isReplied: row.isReplied,
            isFlagged: row.flagged,
            hasAttachments: row.hasAttachments,
            isSentByUser: row.isSentByUser,
            peopleRingTier: tier
        )
    }
}
