import Foundation
import OhiaCore
import OhiaML

/// Identity of a Front Page snapshot for cache lookup. Two snapshots are
/// interchangeable when the normalized filter scope, the unread-only toggle,
/// the visible message-status state, and the exact set of candidate message IDs
/// all match. Rolling Moments presets are fingerprinted by preset, not by the
/// literal timestamp range captured when the user selected the preset.
struct FrontPageSnapshotSignature: Hashable, Sendable {
    let filterFingerprint: String
    let unreadOnly: Bool
    let actionFingerprint: String
    let freshStartPolicyFingerprint: String
    let statusFingerprint: String
    let deadlineFingerprint: String
    let messageIDsFingerprint: String
}

/// Immutable UI snapshot the Front Page workspace renders. The `composition`
/// carries the newspaper structure (lead / features / sections with priority
/// + layout tiers); `articlesByID` resolves each composed entry to a
/// display-ready `FrontPageArticle`. The view walks the composition for
/// structure and resolves articles by id, so there is one source of truth for
/// ordering.
nonisolated struct FrontPageSnapshot: Sendable {
    let signature: FrontPageSnapshotSignature
    let builtAt: Date
    let composition: FrontPageComposition
    let articlesByID: [UUID: FrontPageArticle]
    /// Per-message filter rows, keyed by `id.uuidString`. Retained so the
    /// on-demand summary channel can resolve a row for a hovered card whose
    /// `bodySummary` has not been generated yet (the Metal scene's
    /// `currentMessageIndex` is not populated for this lens).
    let messageFilterRows: [String: MessageFilterRow]
    /// Immutable indexes keep pointer/selection changes from rescanning every
    /// section, including thousands of articles behind collapsed sections.
    let composedArticlesByID: [UUID: FrontPageComposedArticle]
    let threadsByArticleID: [UUID: FrontPageThreadInfo]
    let threadMemberIDsByArticleID: [UUID: Set<UUID>]

    init(
        signature: FrontPageSnapshotSignature,
        builtAt: Date,
        composition: FrontPageComposition,
        articlesByID: [UUID: FrontPageArticle],
        messageFilterRows: [String: MessageFilterRow]
    ) {
        self.signature = signature
        self.builtAt = builtAt
        self.composition = composition
        self.articlesByID = articlesByID
        self.messageFilterRows = messageFilterRows

        var composed: [UUID: FrontPageComposedArticle] = [:]
        var threads: [UUID: FrontPageThreadInfo] = [:]
        var memberIDs: [UUID: Set<UUID>] = [:]
        func index(_ article: FrontPageComposedArticle) {
            if let thread = article.thread {
                threads[article.id] = thread
                memberIDs[article.id] = Set(thread.members.map(\.id))
                for member in thread.members { composed[member.id] = member }
            }
            // The representative resolves to its package, not the leaf member.
            composed[article.id] = article
        }
        if let lead = composition.lead { index(lead) }
        for article in composition.features { index(article) }
        for section in composition.sections {
            for article in section.articles { index(article) }
        }
        composedArticlesByID = composed
        threadsByArticleID = threads
        threadMemberIDsByArticleID = memberIDs
    }

    var isEmpty: Bool { composition.isEmpty }

    func article(_ composed: FrontPageComposedArticle) -> FrontPageArticle? {
        articlesByID[composed.id]
    }

    var lead: FrontPageArticle? {
        composition.lead.flatMap { articlesByID[$0.id] }
    }

    func article(id: UUID) -> FrontPageArticle? {
        articlesByID[id]
    }
}
