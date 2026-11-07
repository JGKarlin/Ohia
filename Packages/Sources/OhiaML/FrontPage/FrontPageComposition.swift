import Foundation
import OhiaCore

/// Action-first priority tier. Lower raw value = higher priority. Tier
/// membership comes from the language-robust signals plus the email date;
/// see `FrontPageComposer`.
public enum FrontPagePriorityTier: Int, Sendable, Equatable, Comparable, CaseIterable {
    case requiresAction = 1
    case requiresConfirmation = 2
    case today = 3
    case yesterday = 4
    case thisWeek = 5
    case older = 6

    public static func < (lhs: FrontPagePriorityTier, rhs: FrontPagePriorityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Newspaper layout role assigned to an article by the composer.
public enum FrontPageLayoutTier: String, Sendable, Equatable {
    /// The single dominant story above the fold.
    case lead
    /// Large secondary stories beside / under the lead.
    case feature
    /// Full modular card inside a Purpose section.
    case standard
    /// Abbreviated headline-only card; hover-expandable.
    case brief
}

/// A Front Page grouping/badge value. Resolved Purpose values remain the only
/// semantic sections; pending and complete-but-unresolved classifications get
/// explicit UI states instead of being collapsed into Purpose `other`.
public enum FrontPagePurposePresentation: Sendable, Equatable, Hashable {
    case purpose(MailPurpose)
    case mailingList
    case pending
    case uncertain

    public init(
        classification: MailClassification?,
        isMailingList: Bool = false,
        isDirectToUser: Bool = false
    ) {
        let purpose = classification?.purpose
        if isMailingList,
           purpose == nil || (purpose == .correspondence && isDirectToUser == false) {
            self = .mailingList
            return
        }
        guard let classification else {
            self = .pending
            return
        }
        if let purpose = classification.purpose {
            self = .purpose(purpose)
        } else {
            self = .uncertain
        }
    }

    public var id: String {
        switch self {
        case .purpose(let purpose): "purpose.\(purpose.rawValue)"
        case .mailingList: "mailingList"
        case .pending: "pending"
        case .uncertain: "uncertain"
        }
    }

    public var displayLabel: String {
        switch self {
        case .purpose(let purpose): purpose.displayLabel
        case .mailingList: "Lists"
        case .pending: "Pending"
        case .uncertain: "Uncertain"
        }
    }

    public var systemImageName: String {
        switch self {
        case .purpose(let purpose): purpose.systemImageName
        case .mailingList: "list.bullet.rectangle"
        case .pending: "hourglass"
        case .uncertain: "questionmark.circle"
        }
    }

    var sortKey: String { id }
}

/// Thread metadata attached to a composed article that represents a **package**
/// — a conversation with 2+ still-open (in-feed) messages collapsed into one
/// card. `nil` on a singleton. The representative is the composed article's own
/// `input` (the action-first member); `members` carries every in-feed sibling
/// as its own composed article (newest → oldest, including the representative)
/// so the grid can expand the package in place. `replyCount` / `confirmCount`
/// roll up the obligations still open across the siblings.
public struct FrontPageThreadInfo: Sendable, Equatable {
    public let threadID: UUID
    /// The conversation's Re:/Fwd:-stripped subject, used as the package
    /// headline.
    public let subjectRoot: String
    /// In-feed siblings, newest → oldest, each a leaf composed article
    /// (`thread == nil`). Includes the representative.
    public let members: [FrontPageComposedArticle]
    public let replyCount: Int
    public let confirmCount: Int

    public var count: Int { members.count }

    public init(
        threadID: UUID,
        subjectRoot: String,
        members: [FrontPageComposedArticle],
        replyCount: Int,
        confirmCount: Int
    ) {
        self.threadID = threadID
        self.subjectRoot = subjectRoot
        self.members = members
        self.replyCount = replyCount
        self.confirmCount = confirmCount
    }
}

/// One article placed by the composer. Carries its source input plus the
/// resolved priority + layout roles. The app layer derives display fields
/// (`FrontPageArticle`) from `input`. When `thread != nil` the article stands in
/// for a whole conversation (a package); otherwise it is a lone message.
public struct FrontPageComposedArticle: Sendable, Identifiable, Equatable {
    public let input: FrontPageArticleInput
    public let priorityTier: FrontPagePriorityTier
    public let layoutTier: FrontPageLayoutTier
    /// Thread payload when this article represents a 2+-message package; `nil`
    /// for a singleton.
    public let thread: FrontPageThreadInfo?

    public var id: UUID { input.id }

    /// True when this composed article represents a multi-message package.
    public var isThreadPackage: Bool { thread != nil }

    public init(
        input: FrontPageArticleInput,
        priorityTier: FrontPagePriorityTier,
        layoutTier: FrontPageLayoutTier,
        thread: FrontPageThreadInfo? = nil
    ) {
        self.input = input
        self.priorityTier = priorityTier
        self.layoutTier = layoutTier
        self.thread = thread
    }
}

/// A Purpose section below the headline band. `articles` holds every article
/// of this Purpose (or explicit non-Purpose presentation state) within the
/// Moments window that was not promoted
/// to the headline band, ordered by priority. `shownCount` is how many are
/// visible by default (budget-limited); the rest are revealed by the
/// section's **expand** affordance, so expansion is a pure view operation.
public struct FrontPageSection: Sendable, Identifiable, Equatable {
    public let purposePresentation: FrontPagePurposePresentation
    public let articles: [FrontPageComposedArticle]
    public let shownCount: Int

    public var id: String { purposePresentation.id }
    public var displayLabel: String { purposePresentation.displayLabel }
    public var availableInMomentsWindow: Int { articles.count }
    public var hasMore: Bool { shownCount < articles.count }

    public init(
        purposePresentation: FrontPagePurposePresentation,
        articles: [FrontPageComposedArticle],
        shownCount: Int
    ) {
        self.purposePresentation = purposePresentation
        self.articles = articles
        self.shownCount = min(max(0, shownCount), articles.count)
    }

    /// Articles shown by default.
    public var shownArticles: ArraySlice<FrontPageComposedArticle> {
        articles.prefix(shownCount)
    }
}

/// Immutable output of `FrontPageComposer.compose`. The headline band is
/// `lead` + `features`; Purpose sections recede below it.
public struct FrontPageComposition: Sendable, Equatable {
    public let lead: FrontPageComposedArticle?
    public let features: [FrontPageComposedArticle]
    public let sections: [FrontPageSection]
    /// The window the page actually resolved to (intersection of the Moments
    /// window and what the budget reached). Drives the masthead "as of" line.
    /// Nil when the composition is empty.
    public let effectiveWindow: ClosedRange<Date>?
    public let totalCount: Int
    public let unreadCount: Int
    public let replyNeededCount: Int
    public let confirmationNeededCount: Int
    public let deadlineInWindowCount: Int

    public init(
        lead: FrontPageComposedArticle?,
        features: [FrontPageComposedArticle],
        sections: [FrontPageSection],
        effectiveWindow: ClosedRange<Date>?,
        totalCount: Int,
        unreadCount: Int,
        replyNeededCount: Int = 0,
        confirmationNeededCount: Int = 0,
        deadlineInWindowCount: Int = 0
    ) {
        self.lead = lead
        self.features = features
        self.sections = sections
        self.effectiveWindow = effectiveWindow
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.replyNeededCount = replyNeededCount
        self.confirmationNeededCount = confirmationNeededCount
        self.deadlineInWindowCount = deadlineInWindowCount
    }

    public static let empty = FrontPageComposition(
        lead: nil,
        features: [],
        sections: [],
        effectiveWindow: nil,
        totalCount: 0,
        unreadCount: 0,
        replyNeededCount: 0,
        confirmationNeededCount: 0,
        deadlineInWindowCount: 0
    )

    public var isEmpty: Bool {
        lead == nil && features.isEmpty && sections.isEmpty
    }
}

/// Weighted slot budget that defines the "finite page." Lead / feature cards
/// cost more slots than abbreviated ones; the composer fills top-down by
/// priority until the budget is spent, so high volume pushes older / lower
/// priority mail past the budget into expansion-only overflow — the
/// mechanism that contracts the effective time frame under load.
public struct FrontPageBudget: Sendable, Equatable {
    /// Maximum number of feature cards in the headline band.
    public var maxFeatureCount: Int
    /// Total weighted slots available for the default page.
    public var totalSlots: Int
    public var leadSlots: Int
    public var featureSlots: Int
    public var standardSlots: Int
    public var briefSlots: Int
    /// Below this many candidates, the page collapses into the headline band
    /// only (no Purpose sections) and the "few items ⇒ bigger" adaptation
    /// applies.
    public var headlineBandOnlyThreshold: Int

    public init(
        maxFeatureCount: Int = 4,
        totalSlots: Int = 44,
        leadSlots: Int = 6,
        featureSlots: Int = 3,
        standardSlots: Int = 2,
        briefSlots: Int = 1,
        headlineBandOnlyThreshold: Int = 5
    ) {
        self.maxFeatureCount = max(0, maxFeatureCount)
        self.totalSlots = max(1, totalSlots)
        self.leadSlots = max(1, leadSlots)
        self.featureSlots = max(1, featureSlots)
        self.standardSlots = max(1, standardSlots)
        self.briefSlots = max(1, briefSlots)
        self.headlineBandOnlyThreshold = max(1, headlineBandOnlyThreshold)
    }

    public static let standard = FrontPageBudget()
}
