import Foundation
import OhiaCore

/// Pure, deterministic ranking + budget + grouping engine for the Front Page
/// lens. Given the candidate articles in scope and the Moments window, it
/// produces a newspaper composition: one lead, a handful of features, and
/// Purpose sections that recede down the page.
///
/// The three forces, in order:
///   1. **Recency** — newest first. Attention, read state, and imagery remain
///      presentation metadata and never promote older mail.
///   2. **Budget** — a finite weighted slot budget filled top-down by
///      recency, so high volume contracts the effective window.
///   3. **Moments ceiling** — nothing outside the Moments window is ever
///      admitted; a narrow window caps the whole page.
///
/// **Threading.** Before ranking, candidates that share a `threadID` and have
/// 2+ in-feed members are collapsed into a single **package unit** represented
/// by the newest inbound sibling. A package ranks and spends budget as one card —
/// so a long conversation no longer floods the page — and carries its siblings
/// (`FrontPageThreadInfo.members`) so the grid can expand it in place. Per-
/// message counts (unread / needs-reply / …) are computed over the *full*
/// candidate set, so the masthead totals are unaffected by grouping.
public enum FrontPageComposer {

    public static func compose(
        inputs: [FrontPageArticleInput],
        momentsWindow: ClosedRange<Date>?,
        now: Date,
        budget: FrontPageBudget = .standard,
        calendar: Calendar = .current
    ) -> FrontPageComposition {
        // 1. Moments ceiling: drop anything outside the window up front.
        let candidates = inputs.filter { input in
            guard let momentsWindow else { return true }
            return momentsWindow.contains(input.date)
        }
        guard candidates.isEmpty == false else { return .empty }

        // Per-message counts + window are computed over ALL candidates so
        // grouping never changes the masthead totals or the "as of" window.
        let counts = summaryCounts(candidates)
        let effectiveWindow = windowSpanning(candidates.map(\.date))

        // 2. Collapse threads into package units, then rank the units.
        let units = buildUnits(candidates, now: now, calendar: calendar)
        let ranked = units.sorted { lhs, rhs in
            chronologicalKey(for: lhs.input) < chronologicalKey(for: rhs.input)
        }

        let headlineEligible = ranked.filter { !isSectionOnly($0.input) }

        guard headlineEligible.isEmpty == false else {
            let sections = buildSections(
                units: ranked,
                slotsRemaining: budget.totalSlots,
                budget: budget,
                now: now,
                calendar: calendar
            )
            return FrontPageComposition(
                lead: nil,
                features: [],
                sections: sections,
                effectiveWindow: effectiveWindow,
                totalCount: counts.total,
                unreadCount: counts.unread,
                replyNeededCount: counts.replyNeeded,
                confirmationNeededCount: counts.confirmationNeeded,
                deadlineInWindowCount: counts.deadlineInWindow
            )
        }

        // 3. Lead selection (image breaks a near-tie).
        let leadIndex = selectLeadIndex(ranked: headlineEligible)
        let leadEntry = headlineEligible[leadIndex]
        let lead = composedArticle(for: leadEntry, layoutTier: .lead, now: now, calendar: calendar)
        var headlineRemainder = headlineEligible
        headlineRemainder.remove(at: leadIndex)
        var headlineBandIDs: Set<UUID> = [lead.id]

        // 4. Few-items adaptation: a single eligible item dominates as a
        //    lone lead; a handful collapses into the headline band while
        //    section-only group mail remains below.
        if headlineEligible.count <= budget.headlineBandOnlyThreshold {
            let features = headlineRemainder.map {
                composedArticle(for: $0, layoutTier: .feature, now: now, calendar: calendar)
            }
            headlineBandIDs.formUnion(features.map(\.id))
            let sectionUnits = ranked.filter { !headlineBandIDs.contains($0.input.id) }
            let slotsRemaining = max(
                0,
                budget.totalSlots - budget.leadSlots - (features.count * budget.featureSlots)
            )
            return FrontPageComposition(
                lead: lead,
                features: features,
                sections: buildSections(
                    units: sectionUnits,
                    slotsRemaining: slotsRemaining,
                    budget: budget,
                    now: now,
                    calendar: calendar
                ),
                effectiveWindow: effectiveWindow,
                totalCount: counts.total,
                unreadCount: counts.unread,
                replyNeededCount: counts.replyNeeded,
                confirmationNeededCount: counts.confirmationNeeded,
                deadlineInWindowCount: counts.deadlineInWindow
            )
        }

        // 5. Features: the next slice, capped by count and by budget.
        var slotsRemaining = budget.totalSlots - budget.leadSlots
        var features: [FrontPageComposedArticle] = []
        var index = 0
        while index < headlineRemainder.count,
              features.count < budget.maxFeatureCount,
              slotsRemaining >= budget.featureSlots {
            let entry = headlineRemainder[index]
            features.append(
                composedArticle(for: entry, layoutTier: .feature, now: now, calendar: calendar)
            )
            headlineBandIDs.insert(entry.input.id)
            slotsRemaining -= budget.featureSlots
            index += 1
        }

        // 6. Remaining units → Purpose sections, ordered by salience.
        let bandRemainder = ranked.filter { !headlineBandIDs.contains($0.input.id) }
        let sections = buildSections(
            units: bandRemainder,
            slotsRemaining: slotsRemaining,
            budget: budget,
            now: now,
            calendar: calendar
        )

        return FrontPageComposition(
            lead: lead,
            features: features,
            sections: sections,
            effectiveWindow: effectiveWindow,
            totalCount: counts.total,
            unreadCount: counts.unread,
            replyNeededCount: counts.replyNeeded,
            confirmationNeededCount: counts.confirmationNeeded,
            deadlineInWindowCount: counts.deadlineInWindow
        )
    }

    // MARK: - Units (threads collapsed to one representative)

    /// A placement unit: either a lone message (`memberInputs == nil`) or a
    /// package — a thread's in-feed siblings represented by the newest inbound
    /// member.
    private struct Unit {
        let input: FrontPageArticleInput
        let tier: FrontPagePriorityTier
        /// In-feed siblings (all, unordered) when this is a package; `nil` for a
        /// singleton.
        let memberInputs: [FrontPageArticleInput]?
    }

    /// Groups candidates sharing a `threadID` (2+ in-feed members) into one
    /// package unit; everything else stays a singleton unit. Emission follows
    /// candidate order (ranking re-sorts), and the ranking is deterministic, so
    /// the result is stable for the same input.
    private static func buildUnits(
        _ candidates: [FrontPageArticleInput],
        now: Date,
        calendar: Calendar
    ) -> [Unit] {
        var byThread: [UUID: [FrontPageArticleInput]] = [:]
        for input in candidates {
            guard let threadID = input.threadID else { continue }
            byThread[threadID, default: []].append(input)
        }

        var units: [Unit] = []
        var consumed = Set<UUID>()
        for input in candidates {
            if let threadID = input.threadID,
               let members = byThread[threadID],
               members.count >= 2 {
                // First sibling emits the package; later siblings are folded in.
                guard consumed.insert(threadID).inserted else { continue }
                let rep = representative(of: members)
                units.append(Unit(
                    input: rep,
                    tier: priorityTier(for: rep, now: now, calendar: calendar),
                    memberInputs: members
                ))
            } else {
                units.append(Unit(
                    input: input,
                    tier: priorityTier(for: input, now: now, calendar: calendar),
                    memberInputs: nil
                ))
            }
        }
        return units
    }

    /// The newest sibling that stands in for the package. Sent mail is
    /// never actionable, so a non-sent member is always preferred as the face of
    /// the thread; only an all-sent group falls back to the newest sent member.
    private static func representative(
        of members: [FrontPageArticleInput]
    ) -> FrontPageArticleInput {
        let nonSent = members.filter { !$0.isSentByUser }
        let pool = nonSent.isEmpty ? members : nonSent
        return pool.min { lhs, rhs in
            chronologicalKey(for: lhs) < chronologicalKey(for: rhs)
        } ?? members[0]
    }

    /// Builds the composed article for a unit at a resolved layout tier,
    /// attaching thread info (with the siblings materialized as leaf composed
    /// articles, newest → oldest) when the unit is a package.
    private static func composedArticle(
        for unit: Unit,
        layoutTier: FrontPageLayoutTier,
        now: Date,
        calendar: Calendar
    ) -> FrontPageComposedArticle {
        guard let memberInputs = unit.memberInputs,
              let threadID = unit.input.threadID,
              memberInputs.count >= 2 else {
            return FrontPageComposedArticle(
                input: unit.input,
                priorityTier: unit.tier,
                layoutTier: layoutTier
            )
        }
        let newestFirst = memberInputs.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let members = newestFirst.map { member in
            FrontPageComposedArticle(
                input: member,
                priorityTier: priorityTier(for: member, now: now, calendar: calendar),
                layoutTier: layoutTier
            )
        }
        let info = FrontPageThreadInfo(
            threadID: threadID,
            subjectRoot: displaySubjectRoot(for: memberInputs),
            members: members,
            replyCount: memberInputs.filter { $0.isActionable && !$0.isSentByUser }.count,
            confirmCount: memberInputs.filter { $0.requiresConfirmation && !$0.isSentByUser }.count
        )
        return FrontPageComposedArticle(
            input: unit.input,
            priorityTier: unit.tier,
            layoutTier: layoutTier,
            thread: info
        )
    }

    /// The conversation's display headline: the earliest member's subject with
    /// reply/forward prefixes stripped, **preserving case** (unlike
    /// `MessageThread.subjectRoot`, which is lowercased for matching).
    private static func displaySubjectRoot(for members: [FrontPageArticleInput]) -> String {
        let oldest = members.min { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return strippedReplyPrefixes(oldest?.subject ?? members.first?.subject ?? "")
    }

    private static func strippedReplyPrefixes(_ subject: String) -> String {
        var value = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for prefix in ["re:", "fwd:", "fw:"] where value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return value.isEmpty ? subject : value
    }

    private struct SummaryCounts {
        let total: Int
        let unread: Int
        let replyNeeded: Int
        let confirmationNeeded: Int
        let deadlineInWindow: Int
    }

    private static func summaryCounts(_ inputs: [FrontPageArticleInput]) -> SummaryCounts {
        SummaryCounts(
            total: inputs.count,
            unread: inputs.filter { !$0.isRead }.count,
            replyNeeded: inputs.filter(\.isActionable).count,
            confirmationNeeded: inputs.filter(\.requiresConfirmation).count,
            deadlineInWindow: inputs.filter(\.hasDeadline).count
        )
    }

    // MARK: - Priority

    static func priorityTier(
        for input: FrontPageArticleInput,
        now: Date,
        calendar: Calendar
    ) -> FrontPagePriorityTier {
        if input.requiresAction { return .requiresAction }
        if input.isConfirmationActive { return .requiresConfirmation }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfArticleDay = calendar.startOfDay(for: input.date)
        let dayDelta = calendar.dateComponents([.day], from: startOfArticleDay, to: startOfToday).day ?? Int.max
        switch dayDelta {
        case ..<0, 0: return .today          // today (or a clock-skewed future date)
        case 1: return .yesterday
        case 2...6: return .thisWeek
        default: return .older
        }
    }

    /// Ascending-sortable key: lower sorts first (newest first).
    private static func chronologicalKey(for input: FrontPageArticleInput) -> ChronologicalKey {
        ChronologicalKey(
            recency: -input.date.timeIntervalSince1970,
            idTie: input.id.uuidString
        )
    }

    private struct ChronologicalKey: Comparable {
        let recency: TimeInterval
        let idTie: String

        static func < (lhs: ChronologicalKey, rhs: ChronologicalKey) -> Bool {
            if lhs.recency != rhs.recency { return lhs.recency < rhs.recency }
            return lhs.idTie < rhs.idTie
        }
    }

    private static func isSectionOnly(_ input: FrontPageArticleInput) -> Bool {
        input.isMailingList
    }

    // MARK: - Lead selection

    /// The lead is the newest unit. An image may break only an exact timestamp
    /// tie, so it can never promote older mail.
    private static func selectLeadIndex(ranked: [Unit]) -> Int {
        guard let first = ranked.first else { return 0 }
        if first.input.hasImage { return 0 }
        for (offset, entry) in ranked.enumerated() {
            guard entry.input.date == first.input.date else {
                break
            }
            if entry.input.hasImage { return offset }
        }
        return 0
    }

    // MARK: - Sections

    private static func buildSections(
        units: [Unit],
        slotsRemaining: Int,
        budget: FrontPageBudget,
        now: Date,
        calendar: Calendar
    ) -> [FrontPageSection] {
        guard units.isEmpty == false else { return [] }

        // First pass: assign a layout tier + shown/overflow flag to each unit in
        // global newest-first order, spending budget standard-first then brief,
        // so the newest remainder gets the richer card.
        var slots = slotsRemaining
        var placed: [(article: FrontPageComposedArticle, shown: Bool)] = []
        placed.reserveCapacity(units.count)
        for unit in units {
            let layoutTier: FrontPageLayoutTier
            let shown: Bool
            if slots >= budget.standardSlots {
                layoutTier = .standard
                shown = true
                slots -= budget.standardSlots
            } else if slots >= budget.briefSlots {
                layoutTier = .brief
                shown = true
                slots -= budget.briefSlots
            } else {
                layoutTier = .brief
                shown = false
            }
            placed.append((
                composedArticle(for: unit, layoutTier: layoutTier, now: now, calendar: calendar),
                shown
            ))
        }

        // Second pass: group only by resolved Purpose, preserving newest-first
        // order. Pending and uncertain remain explicit non-Purpose groups.
        var order: [FrontPagePurposePresentation] = []
        var byPurpose: [FrontPagePurposePresentation: [(article: FrontPageComposedArticle, shown: Bool)]] = [:]
        for item in placed {
            let purposePresentation = item.article.input.purposePresentation
            if byPurpose[purposePresentation] == nil {
                byPurpose[purposePresentation] = []
                order.append(purposePresentation)
            }
            byPurpose[purposePresentation]?.append(item)
        }

        let sections = order.map { purposePresentation -> FrontPageSection in
            let items = byPurpose[purposePresentation] ?? []
            let shownCount = items.filter(\.shown).count
            return FrontPageSection(
                purposePresentation: purposePresentation,
                articles: items.map(\.article),
                shownCount: shownCount
            )
        }

        // Section order follows the newest article in each category, then
        // larger volume, then a stable label tie-break.
        return sections.sorted { lhs, rhs in
            let lhsNewest = lhs.articles.first?.input.date ?? .distantPast
            let rhsNewest = rhs.articles.first?.input.date ?? .distantPast
            if lhsNewest != rhsNewest { return lhsNewest > rhsNewest }
            if lhs.articles.count != rhs.articles.count { return lhs.articles.count > rhs.articles.count }
            return lhs.purposePresentation.sortKey < rhs.purposePresentation.sortKey
        }
    }

    // MARK: - Window

    private static func windowSpanning(_ dates: [Date]) -> ClosedRange<Date>? {
        guard let lower = dates.min(), let upper = dates.max() else { return nil }
        return lower...upper
    }
}
