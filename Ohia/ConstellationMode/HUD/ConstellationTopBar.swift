import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

public struct ConstellationTopBar: View {
    private static let compactToolbarWidth: CGFloat = 1600

    @Query private var mailingLists: [MailingList]

    @Binding public var activeFrame: FrameKey
    @Binding public var selectedTimeRange: TimeRangePreset
    @Binding public var customTimeRange: ClosedRange<Date>?
    @Binding public var filter: VectorFilter
    public let accounts: [Account]
    public let correspondentSuggestions: [CorrespondentFilterSuggestion]
    /// Per-purpose message counts surfaced after each category-filter row.
    /// Counts reflect messages that would render if the category were the only
    /// category restriction (every other active filter applied), so unchecked
    /// rows still surface their population.
    public let purposeCounts: [MailPurpose: Int]
    public let mailingListCount: Int
    /// Per-custom-category counterpart of `topicCategoryCounts`, keyed by
    /// `custom.<slug>`.
    public let customCategoryCounts: [String: Int]
    /// Live custom-category catalog (collecting + active) for the Category
    /// pulldown rows, ratio-bar total, creation field, and remove buttons.
    public let customCategoryCatalog: [CustomMailCategoryDescriptor]
    public let onCreateCustomCategory: (String) -> Void
    public let onRemoveCustomCategory: (String) -> Void
    /// Per-account overall message totals shown in parens after each
    /// account's display name in the Territory chip strip and the Territory
    /// pulldown. Intentionally independent of every filter — the chip
    /// reports the account's overall population regardless of toggle state.
    public let accountMessageTotals: [UUID: Int]
    /// Per-time-range hypothetical counts shown after each Moments preset
    /// label and in the trigger pill. Counts are populated only after the
    /// first scene compute; before that the menu renders plain titles so
    /// nothing flashes `(0)` at cold launch.
    public let timeRangeCounts: [TimeRangePreset: Int]
    /// In-scope message counts for the Voices autocomplete rows, keyed by
    /// trimmed, lowercased address. nil until the first computation, so rows
    /// show no count rather than a placeholder zero.
    public let voicesAddressCounts: [String: Int]?
    /// The Voices Lists rows' counterpart, keyed by account and then list
    /// identity, because picking a list also selects its account.
    public let voicesListCounts: [UUID: [String: Int]]?
    public let onSelectFrame: (FrameKey) -> Void
    public let onSelectTimePreset: (TimeRangePreset) -> Void
    /// Width reserved at the leading edge for the macOS traffic-light
    /// controls. Default 84 (the historic value) covers the case where the
    /// toolbar sits flush with the window's leading edge. When the sidebar
    /// occupies the leading edge, callers pass a small visual margin
    /// (e.g. 12) instead — the stoplights live above the sidebar and the
    /// toolbar no longer needs to leave room for them.
    public let leadingInset: CGFloat

    // Per-section displayed-toggle sets, persisted via @AppStorage as a
    // CSV of raw values. Default = all cases displayed, so existing users
    // see the bar unchanged on first launch.
    //
    // Display vs Toggle (see Section icon as pull-down docs):
    //   Display = "this chip appears in the bar at all" (controlled here).
    //   Toggle  = "this chip's filter is on or off" (controlled by clicking
    //             the chip; persisted on the matching `VectorFilter` field).
    // Coupling rule: un-displaying clears the corresponding toggle so a
    // hidden chip can't keep filtering the view invisibly.
    /// Default seed = all Action cases displayed. Replaces the
    /// retired `constellationFormsDisplayed` key (which CSV'd
    /// `MessageType.allCases`); the old key persists in user defaults but
    /// is no longer read — macOS doesn't garbage-collect AppStorage so
    /// it'll sit harmless until the user resets the app.
    @AppStorage("constellationHeadlineDisplayed")
    private var headlineDisplayedRaw: String =
        HeadlineToggle.allCases.map(\.rawValue).sorted().joined(separator: ",")
    @AppStorage("constellationResolvedHeadlineChipPreferenceInitialized")
    private var resolvedHeadlineChipPreferenceInitialized = false

    /// Inverse persistence for Territory because accounts are dynamic
    /// (a newly-added Gmail mailbox should default to displayed). We store
    /// the CSV of UUIDs the user has un-checked; newly-encountered UUIDs
    /// are absent from the set so they render automatically.
    @AppStorage("constellationTerritoryHidden")
    private var territoryHiddenRaw: String = ""

    /// Default seed = every Traces toggle. The `V2` key suffix is a
    /// one-time reseed: an earlier persisted value under
    /// `constellationTracesDisplayed` sometimes omitted newer cases
    /// (`received`, `replied`, `hasAttachments`, `flagged`) because
    /// they were added to `TraceToggle` after that key was first set.
    /// Bumping the key gives every install a fresh default that
    /// includes all current cases; the user can still un-display any
    /// of them via the Traces menu if they want.
    @AppStorage("constellationTracesDisplayedV2")
    private var tracesDisplayedRaw: String =
        TraceToggle.allCases
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")

    /// Default seed = every visible spatial frame. The Frame section
    /// gained icon-pulldown curation in 2026-05; before then every frame
    /// rendered unconditionally. Existing users see all visible chips on
    /// first launch and can un-display individual frames from the menu.
    ///
    /// Note on stored tokens: `.meaning` persists as the raw value
    /// `"default"` (its rawValue per `FrameKey.defaultFrame`). The
    /// `frameDisplayed` getter filters unknown or retired tokens against
    /// `visibleSpatialFrames` so stale rawValues from older or forked
    /// installs can't accumulate.
    @AppStorage("constellationFrameDisplayed")
    private var frameDisplayedRaw: String =
        FrameKey.visibleSpatialFrames
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")

    /// People-lens Voices scope toggle: when off (default), the correspondent
    /// query renders only the matched person's hub — "filter to Sam = show
    /// Sam." When on, the lens expands to the matched person plus every
    /// co-recipient on their shared messages (the ego-network read). Shared
    /// with `ConstellationModeView` via the same AppStorage key so the
    /// toolbar UI and the layout builder stay in sync.
    @AppStorage("constellationPeopleVoicesExpandsToOneHop")
    private var peopleVoicesExpandsToOneHop: Bool = false

    public init(
        activeFrame: Binding<FrameKey>,
        selectedTimeRange: Binding<TimeRangePreset>,
        customTimeRange: Binding<ClosedRange<Date>?>,
        filter: Binding<VectorFilter>,
        accounts: [Account],
        correspondentSuggestions: [CorrespondentFilterSuggestion] = [],
        purposeCounts: [MailPurpose: Int] = [:],
        mailingListCount: Int = 0,
        customCategoryCounts: [String: Int] = [:],
        customCategoryCatalog: [CustomMailCategoryDescriptor] = [],
        accountMessageTotals: [UUID: Int] = [:],
        timeRangeCounts: [TimeRangePreset: Int] = [:],
        voicesAddressCounts: [String: Int]? = nil,
        voicesListCounts: [UUID: [String: Int]]? = nil,
        leadingInset: CGFloat = 84,
        onSelectFrame: @escaping (FrameKey) -> Void,
        onSelectTimePreset: @escaping (TimeRangePreset) -> Void,
        onCreateCustomCategory: @escaping (String) -> Void = { _ in },
        onRemoveCustomCategory: @escaping (String) -> Void = { _ in }
    ) {
        self._activeFrame = activeFrame
        self._selectedTimeRange = selectedTimeRange
        self._customTimeRange = customTimeRange
        self._filter = filter
        self.accounts = accounts
        self.correspondentSuggestions = correspondentSuggestions
        self.purposeCounts = purposeCounts
        self.mailingListCount = mailingListCount
        self.customCategoryCounts = customCategoryCounts
        self.customCategoryCatalog = customCategoryCatalog
        self.accountMessageTotals = accountMessageTotals
        self.timeRangeCounts = timeRangeCounts
        self.voicesAddressCounts = voicesAddressCounts
        self.voicesListCounts = voicesListCounts
        self.leadingInset = leadingInset
        self.onSelectFrame = onSelectFrame
        self.onSelectTimePreset = onSelectTimePreset
        self.onCreateCustomCategory = onCreateCustomCategory
        self.onRemoveCustomCategory = onRemoveCustomCategory
    }

    public var body: some View {
        GeometryReader { proxy in
            let compactLayout = proxy.size.width < Self.compactToolbarWidth

            toolbarContent
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .leading
                )
                .environment(\.constellationToolbarCompactLayout, compactLayout)
                .environment(\.constellationToolbarShowsAccessors, !compactLayout)
        }
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: 78)
        .background(OhiaColors.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(OhiaColors.glassBorder)
        }
        .onChange(
            of: VoicesMailingListFilter.normalizationFingerprint(for: filter),
            initial: true
        ) { _, _ in
            let normalized = VoicesMailingListFilter.normalizingListScope(in: filter)
            if normalized != filter {
                filter = normalized
            }
        }
    }

    private var hidesStatusDirectionPair: Bool {
        activeFrame.spatialLens == .frontPage
    }

    private var mailingListOptions: [VoicesMailingListOption] {
        VoicesMailingListFilter.options(lists: mailingLists, accounts: accounts)
    }

    private var voicesQueryBinding: Binding<String> {
        let options = mailingListOptions
        let activeAddress = VoicesMailingListFilter.activeDisplayValue(
            for: filter,
            options: options
        )

        return Binding(
            get: {
                VoicesMailingListFilter.displayedQuery(for: filter, options: options)
            },
            set: { query in
                filter = VoicesMailingListFilter.updatingDisplayedQuery(
                    query,
                    activeListAddress: activeAddress,
                    in: filter
                )
            }
        )
    }

    private var toolbarContent: some View {
        HStack(spacing: 0) {
            // Leading inset. When the toolbar sits flush with the window's
            // leading edge (no leading sidebar) this clears the macOS
            // traffic-light controls; when a leading sidebar already covers
            // the stoplights, callers pass a small visual margin instead.
            Color.clear.frame(width: leadingInset)

            // CONTENT FILTERS — journalistic order. Section dividers
            // sit BETWEEN sections (HTML pattern: `.section + .section`)
            // rather than as a trailing overlay on every section, so two
            // adjacent sections never paint a doubled-up 2pt line.

            ToolbarSection(
                title: "Destination",
                symbolName: "tray.full",
                accessor: "where",
                helpText: "Where — which mailbox-territory",
                alignment: .center,
                hasOverflow: false,
                useOverflowFlow: true,
                menu: {
                    MenuPopoverContent(
                        headerLabel: "Display as toggles"
                    ) {
                        ForEach(accounts, id: \.id) { acct in
                            MenuRow(
                                name: accountMenuLabel(for: acct),
                                isChecked: territoryDisplayed.contains(acct.id),
                                action: { toggleTerritoryDisplay(acct.id) }
                            ) {
                                AccountGlyphImage(
                                    glyph: AccountIcon.style(for: acct).glyph,
                                    size: 12
                                )
                                .foregroundStyle(acct.accountColor.swiftUIColor)
                            }
                        }
                    }
                }
            ) {
                AccountFilterChips(
                    accountIds: $filter.accountIds,
                    accounts: accounts,
                    displayed: territoryDisplayed,
                    accountTotals: accountMessageTotals
                )
            }
            .layoutPriority(1)

            sectionDivider()

            ToolbarSection(
                title: "Moments",
                symbolName: "clock",
                accessor: "when",
                helpText: "When — time range",
                alignment: .center
            ) {
                TimeRangeMenu(
                    selected: $selectedTimeRange,
                    customRange: $customTimeRange,
                    counts: timeRangeCounts,
                    onSelect: onSelectTimePreset
                )
            }
            .fixedSize(horizontal: true, vertical: false)

            sectionDivider()

            ToolbarSection(
                title: "Voices",
                symbolName: "person.and.background.dotted",
                accessor: "who",
                helpText: "Who — correspondents (From / To / Cc / Bcc)",
                hasOverflow: false,
                menu: {
                    // Independent header-role checkboxes for the search field.
                    // Their combined state also appears in the field's
                    // placeholder so this filter never narrows invisibly.
                    MenuPopoverContent(headerLabel: "Search roles") {
                        ForEach(CorrespondentScope.allCases, id: \.self) { option in
                            MenuRow(
                                name: voicesScopeMenuLabel(for: option),
                                symbolName: voicesScopeMenuSymbol(for: option),
                                isChecked: filter.correspondentScopes.contains(option),
                                action: { toggleCorrespondentScope(option) }
                            )
                            .accessibilityValue(
                                filter.correspondentScopes.contains(option) ? "Checked" : "Unchecked"
                            )
                        }
                        if !mailingListOptions.isEmpty {
                            Divider()
                                .overlay(OhiaColors.glassBorder)
                                .padding(.vertical, 4)

                            Text("Lists")
                                .font(.system(size: 9.5))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(OhiaColors.textTertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 6)

                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(mailingListOptions) { option in
                                        VoicesMailingListRow(
                                            option: option,
                                            inScopeCount: voicesListCounts.map {
                                                $0[option.accountID]?[option.listId] ?? 0
                                            }
                                        ) {
                                            filter = VoicesMailingListFilter.selecting(
                                                option,
                                                in: filter
                                            )
                                        }
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(mailingListOptions.count) * 32, 192))
                        }
                        // People-lens-only toggle: expand the filter to the
                        // matched correspondent's ego network (co-recipients
                        // on shared threads) instead of the strict match.
                        // Hidden outside the People lens because the toggle
                        // has no effect there.
                        if activeFrame.spatialLens == .people {
                            Divider().padding(.vertical, 4)
                            MenuRow(
                                name: "Show network",
                                symbolName: "person.2.wave.2",
                                isChecked: peopleVoicesExpandsToOneHop,
                                action: { peopleVoicesExpandsToOneHop.toggle() }
                            )
                        }
                    }
                }
            ) {
                CorrespondentFilterField(
                    query: voicesQueryBinding,
                    scopes: $filter.correspondentScopes,
                    suggestions: correspondentSuggestions,
                    inScopeCounts: voicesAddressCounts
                )
            }
            .fixedSize(horizontal: true, vertical: false)

            sectionDivider()

            ToolbarSection(
                title: "Action",
                symbolName: "envelope.and.arrow.trianglehead.branch",
                accessor: "why",
                helpText: "Why — reply, confirmation, and resolved states",
                hasOverflow: false,  // ToolbarSection ORs this with its
                                     // internal hiddenCount when in
                                     // overflow flow mode, so the menu-pill
                                     // dot lights automatically.
                useOverflowFlow: true,
                menu: {
                    MenuPopoverContent(
                        headerLabel: "Display as toggles"
                    ) {
                        ForEach(HeadlineToggle.allCases, id: \.self) { toggle in
                            MenuRow(
                                name: headlineMenuLabel(for: toggle),
                                symbolName: ToggleIconography.symbolName(for: toggle),
                                isChecked: headlineDisplayed.contains(toggle),
                                action: { toggleHeadlineDisplay(toggle) }
                            )
                        }
                    }
                }
            ) {
                HeadlineFilterChips(
                    replyNeededCriterion: $filter.replyNeededCriterion,
                    confirmationNeededCriterion: $filter.confirmationNeededCriterion,
                    resolvedCriterion: resolvedCriterionBinding,
                    displayed: headlineDisplayed
                )
            }
            .layoutPriority(1)

            sectionDivider()

            ToolbarSection(
                title: "Category",
                symbolName: "mail.stack.fill",
                accessor: "what",
                helpText: "What — shared categories, Lists, and custom categories",
                alignment: .center,
                hasOverflow: false,
                useOverflowFlow: true,
                menu: {
                    MenuPopoverContent(headerLabel: "Category filter") {
                        TopicsFilterMenuRows(
                            purposes: $filter.purposes,
                            mailingListCategoryIncluded: $filter.mailingListCategoryIncluded,
                            customCategoryKeys: $filter.customCategoryKeys,
                            purposeCounts: purposeCounts,
                            mailingListCount: purposeCounts.isEmpty ? nil : mailingListCount,
                            customCategoryCounts: customCategoryCounts,
                            customCatalog: customCategoryCatalog,
                            onCreateCustomCategory: onCreateCustomCategory,
                            onRemoveCustomCategory: onRemoveCustomCategory
                        )
                    }
                }
            ) {
                TopicsFilterChips(
                    purposes: $filter.purposes,
                    mailingListCategoryIncluded: $filter.mailingListCategoryIncluded,
                    customCategoryKeys: $filter.customCategoryKeys,
                    customCatalog: customCategoryCatalog
                )
            }
            .layoutPriority(1)

            sectionDivider()

            ToolbarSection(
                title: "Status",
                symbolName: "tray.and.arrow.down",
                accessor: "which",
                helpText: "Which — handling state (read / replied / flagged / attached)",
                horizontalPadding: 8,
                hasOverflow: false,
                useOverflowFlow: true,
                menu: {
                    MenuPopoverContent(
                        headerLabel: "Display as toggles"
                    ) {
                        // Co-dependent pairs collapse into one menu row
                        // so the chip strip can never end up with a
                        // half-pair (e.g. only `received` displayed,
                        // which would imply a sent/received toggle that
                        // can no longer be flipped). Standalone trace
                        // toggles (`flagged`, `hasAttachments`) keep
                        // their per-chip rows.
                        if !hidesStatusDirectionPair {
                            tracePairRow(left: .received, right: .sent)
                        }
                        tracePairRow(left: .read, right: .unread)
                        tracePairRow(left: .replied, right: .unreplied)
                        MenuRow(
                            name: "Flagged",
                            symbolName: ToggleIconography.symbolName(for: .flagged),
                            isChecked: tracesDisplayed.contains(.flagged),
                            action: { toggleTracesDisplay(.flagged) }
                        )
                        MenuRow(
                            name: "Has attachments",
                            symbolName: ToggleIconography.symbolName(for: .hasAttachments),
                            isChecked: tracesDisplayed.contains(.hasAttachments),
                            action: { toggleTracesDisplay(.hasAttachments) }
                        )
                    }
                }
            ) {
                StatusFilterChips(
                    readStates: $filter.readStates,
                    repliedStates: $filter.repliedStates,
                    sentStates: $filter.sentStates,
                    flaggedOnly: $filter.flaggedOnly,
                    hasAttachmentsOnly: $filter.hasAttachmentsOnly,
                    displayed: tracesDisplayed,
                    hidesDirectionPair: hidesStatusDirectionPair
                )
            }
            .layoutPriority(1)

            // DISPLAY CONTROLS cluster. The HTML keeps the bar one flat
            // surface and demarcates the cluster with a single, slightly
            // stronger leading divider — no background tint.
            sectionDivider(strong: true, horizontalPadding: 4)

            ToolbarSection(
                title: "Scope",
                symbolName: "point.3.connected.trianglepath.dotted",
                accessor: "how",
                helpText: "How — spatial scope for reading constellation relationships",
                hasOverflow: false,
                useOverflowFlow: true,
                menu: {
                    MenuPopoverContent(
                        headerLabel: "Display as chips"
                    ) {
                        ForEach(FrameSelectorBar.allFrames, id: \.key) { f in
                            MenuRow(
                                name: f.title,
                                symbolName: ToggleIconography.symbolName(for: f.key),
                                isChecked: frameDisplayed.contains(f.key),
                                action: { toggleFrameDisplay(f.key) }
                            )
                        }
                    }
                }
            ) {
                FrameSelectorBar(
                    activeFrame: $activeFrame,
                    displayed: frameDisplayed,
                    onSelect: onSelectFrame
                )
            }

            Spacer(minLength: 0)

        }
    }

    // MARK: - Section divider

    /// 1pt vertical hairline drawn between adjacent toolbar sections.
    /// Inset 16pt top and bottom so the line doesn't run the full bar
    /// height (matches HTML `top: 16px; bottom: 16px`). The `strong`
    /// variant is used as the boundary into the display cluster — same
    /// pattern as the HTML's `--L-divider-2` distinction.
    @ViewBuilder
    private func sectionDivider(strong: Bool = false, horizontalPadding: CGFloat = 6) -> some View {
        // 1pt line pinned to 46pt height (toolbar 78 − 16pt top/bottom
        // inset). Horizontal padding gives 6pt of breathing room on
        // each side so the line doesn't visually crowd the chip borders.
        Rectangle()
            .frame(width: 1, height: 46)
            .foregroundStyle(strong
                ? OhiaColors.glassBorderBright
                : OhiaColors.glassBorder)
            .padding(.horizontal, horizontalPadding)
    }

    // MARK: - Headline section: display-set persistence

    /// CSV-backed displayed-set decoded into a typed `Set<HeadlineToggle>`.
    /// Unknown raw values are silently dropped; missing-from-persistence
    /// falls back to the empty set, but the @AppStorage default seeds with
    /// all cases on first launch. Existing Reply/Confirm customization is
    /// retained while Resolve is introduced once as displayed by default.
    private var headlineDisplayed: Set<HeadlineToggle> {
        var displayed = Set(headlineDisplayedRaw.split(separator: ",").compactMap {
            HeadlineToggle(rawValue: String($0))
        })
        if !resolvedHeadlineChipPreferenceInitialized {
            displayed.insert(.resolved)
        }
        return ActionChipDisplayPolicy.displayed(
            configured: displayed,
            lens: activeFrame
        )
    }

    /// Title-case label for a Headline toggle as it should appear in a
    /// menu row. Mirrors `HeadlineFilterChips` wording so the
    /// menu and the chip strip read as the same vocabulary.
    private func headlineMenuLabel(for toggle: HeadlineToggle) -> String {
        toggle.actionDisplayLabel
    }

    private var resolvedCriterionBinding: Binding<AttentionFilterCriterion> {
        Binding(
            get: {
                ResolvedActionFilterPolicy.criterion(
                    stored: filter.resolvedCriterion,
                    lens: activeFrame
                )
            },
            set: { filter.resolvedCriterion = $0 }
        )
    }

    /// Toggles whether `toggle` appears as an inline chip in Headline.
    /// Per the display-vs-toggle coupling rule: hiding a chip also
    /// clears its filter contribution so a hidden chip can't keep
    /// filtering the view invisibly.
    private func toggleHeadlineDisplay(_ toggle: HeadlineToggle) {
        var displayed = headlineDisplayed
        resolvedHeadlineChipPreferenceInitialized = true
        if displayed.contains(toggle) {
            displayed.remove(toggle)
            switch toggle {
            case .actionable: filter.replyNeededCriterion = .any
            case .confirm:    filter.confirmationNeededCriterion = .any
            case .resolved:   filter.resolvedCriterion = .any
            }
        } else {
            displayed.insert(toggle)
        }
        headlineDisplayedRaw = displayed
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    /// Territory pulldown row label — `Display Name (1,234)` when totals
    /// have been computed, plain `Display Name` otherwise so the menu
    /// never flashes a misleading `(0)` before the first snapshot lands.
    private func accountMenuLabel(for account: Account) -> String {
        guard !accountMessageTotals.isEmpty else { return account.displayName }
        let count = accountMessageTotals[account.id] ?? 0
        return "\(account.displayName) (\(count.formatted(.number)))"
    }

    // MARK: - Territory section: display-set persistence (inverse / hidden)

    /// Decoded set of account UUIDs the user has un-checked. Future
    /// accounts are absent from this set, so they default to displayed.
    private var territoryHidden: Set<UUID> {
        Set(territoryHiddenRaw.split(separator: ",").compactMap {
            UUID(uuidString: String($0))
        })
    }

    /// Account IDs currently displayed in the bar — every known account
    /// minus the hidden set. Computed from the live `accounts` array so
    /// removed accounts naturally drop out (their UUIDs may persist in
    /// `territoryHiddenRaw`, but they'll never resurface as chips because
    /// `accounts.filter` won't yield them).
    private var territoryDisplayed: Set<UUID> {
        let hidden = territoryHidden
        return Set(accounts.map(\.id).filter { !hidden.contains($0) })
    }

    /// Toggles whether `accountId` appears as an inline chip in Territory.
    /// Coupling rule: un-checking display also clears the account's filter
    /// contribution (so a hidden chip can't keep filtering invisibly).
    private func toggleTerritoryDisplay(_ accountId: UUID) {
        var hidden = territoryHidden
        if hidden.contains(accountId) {
            hidden.remove(accountId)
        } else {
            hidden.insert(accountId)
            // Clear the filter for the un-displayed account. `accountIds
            // == nil` means "all match"; switch to an explicit set minus
            // the un-displayed account so the filter no longer matches it.
            var current = filter.accountIds ?? Set(accounts.map(\.id))
            current.remove(accountId)
            filter.accountIds =
                current == Set(accounts.map(\.id)) ? nil : current
        }
        territoryHiddenRaw = hidden
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }

    // MARK: - Traces section: display-set persistence

    /// Decoded set of `TraceToggle` cases currently displayed as Traces
    /// chips. Default seed = every case except `.flagged` (see comment on
    /// `tracesDisplayedRaw`).
    private var tracesDisplayed: Set<TraceToggle> {
        Set(tracesDisplayedRaw.split(separator: ",").compactMap {
            TraceToggle(rawValue: String($0))
        })
    }

    /// Menu row for a co-dependent trace pair (received/sent, read/unread,
    /// replied/unreplied). The two halves are always displayed together so
    /// the chip strip can never end up with a half-pair. Each half's SF
    /// symbol sits immediately before its own label so the row reads as
    /// "icon word & icon word" — same icon-then-word vocabulary as the
    /// standalone Flagged / Has-attachments rows.
    private func tracePairRow(
        left: TraceToggle,
        right: TraceToggle
    ) -> some View {
        MenuPairRow(
            leftSymbol: ToggleIconography.symbolName(for: left),
            leftLabel: traceShortLabel(for: left),
            rightSymbol: ToggleIconography.symbolName(for: right),
            rightLabel: traceShortLabel(for: right),
            isChecked: tracesDisplayed.contains(left)
                || tracesDisplayed.contains(right),
            action: { toggleTracesPair(left, right) }
        )
    }

    /// User-facing label for a correspondent search role as it appears in
    /// the Voices icon-pulldown menu.
    private func voicesScopeMenuLabel(for scope: CorrespondentScope) -> String {
        switch scope {
        case .from:    return "From"
        case .to:      return "To"
        case .cc:      return "Cc"
        case .bcc:     return "Bcc"
        }
    }

    /// SF Symbol for a correspondent search role. From/To mirror the
    /// received/sent chip glyphs; Cc uses the shared-recipient glyph.
    private func voicesScopeMenuSymbol(for scope: CorrespondentScope) -> String {
        switch scope {
        case .from:    return "tray.and.arrow.down"
        case .to:      return "paperplane.fill"
        case .cc:      return "person.2"
        case .bcc:     return "eye.slash"
        }
    }

    private func toggleCorrespondentScope(_ scope: CorrespondentScope) {
        if filter.correspondentScopes.contains(scope) {
            filter.correspondentScopes.remove(scope)
        } else {
            filter.correspondentScopes.insert(scope)
        }
    }

    /// Title-case label for a trace toggle as it should appear in a menu
    /// row. Mirrors the chip strip so menus and inline status chips use
    /// the same casing.
    private func traceShortLabel(for trace: TraceToggle) -> String {
        switch trace {
        case .received:        return "Received"
        case .sent:            return "Sent"
        case .read:            return "Read"
        case .unread:          return "Unread"
        case .replied:         return "Replied"
        case .unreplied:       return "Unreplied"
        case .hasAttachments:  return "Has attachments"
        case .flagged:         return "Flagged"
        }
    }

    /// Toggles whether the chip for `trace` appears in Traces. Coupling
    /// rule: un-checking display also clears the corresponding toggle so
    /// the filter stops excluding messages on the basis of a hidden chip.
    /// Used for the standalone trace toggles (`flagged`, `hasAttachments`);
    /// co-dependent pairs go through `toggleTracesPair`.
    private func toggleTracesDisplay(_ trace: TraceToggle) {
        var displayed = tracesDisplayed
        if displayed.contains(trace) {
            displayed.remove(trace)
            clearTraceToggle(trace)
        } else {
            displayed.insert(trace)
        }
        tracesDisplayedRaw = displayed
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    /// Toggles whether a co-dependent trace pair (received/sent etc.)
    /// appears in Traces. Both halves move together: the pair is "shown"
    /// if either half is in the displayed set, and toggling either adds
    /// or removes both. Hiding the pair clears each half's filter
    /// contribution via `clearTraceToggle` so the filter stops excluding
    /// messages on the basis of a hidden chip.
    private func toggleTracesPair(
        _ left: TraceToggle,
        _ right: TraceToggle
    ) {
        var displayed = tracesDisplayed
        let isShown = displayed.contains(left) || displayed.contains(right)
        if isShown {
            displayed.remove(left)
            displayed.remove(right)
            clearTraceToggle(left)
            clearTraceToggle(right)
        } else {
            displayed.insert(left)
            displayed.insert(right)
        }
        tracesDisplayedRaw = displayed
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    /// Reset the filter contribution of a trace toggle so the un-displayed
    /// chip can no longer keep the view filtered.
    private func clearTraceToggle(_ trace: TraceToggle) {
        switch trace {
        case .received:        ensureTriState(value: false, in: &filter.sentStates)
        case .sent:            ensureTriState(value: true,  in: &filter.sentStates)
        case .unread:          ensureTriState(value: false, in: &filter.readStates)
        case .read:            ensureTriState(value: true,  in: &filter.readStates)
        case .replied:         ensureTriState(value: true,  in: &filter.repliedStates)
        case .unreplied:       ensureTriState(value: false, in: &filter.repliedStates)
        case .hasAttachments:  filter.hasAttachmentsOnly = false
        case .flagged:         filter.flaggedOnly = false
        }
    }

    /// Helper for tri-state filters (`Set<Bool>?`). Ensures the given
    /// value is in the active set so the corresponding direction is no
    /// longer being filtered out. Mirrors `triBinding` in
    /// `StatusFilterChips` for the "include this state" half of the
    /// chip's behaviour.
    private func ensureTriState(value: Bool, in states: inout Set<Bool>?) {
        var active = states ?? Set([true, false])
        active.insert(value)
        states = active == Set([true, false]) ? nil : active
    }

    // MARK: - Frame section: display-set persistence

    /// Decoded set of `FrameKey` values currently displayed as Frame
    /// chips. Default seed = every case in `FrameKey.visibleSpatialFrames`
    /// so users see the full chip strip on first launch. Tokens that
    /// don't match a known visible frame are dropped (FrameKey is a
    /// non-failable struct, so we need an explicit allowlist filter to
    /// keep stale or forked rawValues from accumulating in the CSV).
    private var frameDisplayed: Set<FrameKey> {
        let known: Set<FrameKey> = Set(FrameKey.visibleSpatialFrames)
        var result: Set<FrameKey> = []
        for token in frameDisplayedRaw.split(separator: ",") {
            let key = FrameKey(rawValue: String(token))
            if known.contains(key) {
                result.insert(key)
            }
        }
        return result
    }

    /// Toggles whether the chip for `frame` appears in the Frame strip.
    /// Frame is a radio (one active at a time), not an independent
    /// toggle, so the coupling rule differs from Headline/Traces: if the
    /// user un-displays the currently-active frame, the active selection
    /// shifts to the first remaining displayed frame (in canonical order)
    /// so the chip strip always reflects the active lens when any chip is
    /// visible. With zero chips displayed the active frame stays as-is —
    /// the renderer keeps its lens, and the user can re-display chips
    /// from the menu to bring it back into view.
    private func toggleFrameDisplay(_ frame: FrameKey) {
        var displayed = frameDisplayed
        if displayed.contains(frame) {
            displayed.remove(frame)
            if frame.spatialLens == activeFrame.spatialLens,
               let next = FrameKey.visibleSpatialFrames.first(where: {
                   displayed.contains($0)
               }) {
                onSelectFrame(next)
            }
        } else {
            displayed.insert(frame)
        }
        frameDisplayedRaw = displayed
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }
}

struct VoicesMailingListOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountID: UUID
    let listId: String
    let address: String
}

enum VoicesMailingListFilter {
    struct NormalizationFingerprint: Equatable, Sendable {
        let listIds: Set<String>?
        let correspondentQuery: String
    }

    static func options(
        lists: [MailingList],
        accounts: [Account]
    ) -> [VoicesMailingListOption] {
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

        return lists
            .sorted { lhs, rhs in
                if lhs.messagesPerWeek != rhs.messagesPerWeek {
                    return lhs.messagesPerWeek > rhs.messagesPerWeek
                }
                return lhs.lastReceivedAt > rhs.lastReceivedAt
            }
            .map { list in
                VoicesMailingListOption(
                    id: list.id,
                    accountID: list.accountID,
                    listId: list.listId,
                    address: listLabel(list, account: accountsByID[list.accountID])
                )
            }
    }

    static func activeOption(
        for filter: VectorFilter,
        options: [VoicesMailingListOption]
    ) -> VoicesMailingListOption? {
        guard let listIds = filter.listIds, listIds.count == 1,
              let listId = listIds.first else {
            return nil
        }
        return options.first { option in
            option.listId == listId
                && (filter.accountIds?.contains(option.accountID) ?? true)
        }
    }

    static func selecting(
        _ option: VoicesMailingListOption,
        in filter: VectorFilter
    ) -> VectorFilter {
        var updated = filter
        updated.listIds = [option.listId]
        updated.accountIds = [option.accountID]
        updated.correspondentQuery = ""
        return updated
    }

    static func displayedQuery(
        for filter: VectorFilter,
        options: [VoicesMailingListOption]
    ) -> String {
        activeDisplayValue(for: filter, options: options) ?? filter.correspondentQuery
    }

    static func activeDisplayValue(
        for filter: VectorFilter,
        options: [VoicesMailingListOption]
    ) -> String? {
        guard let listIds = filter.listIds, listIds.count == 1,
              let listId = listIds.first else {
            return nil
        }
        return activeOption(for: filter, options: options)?.address ?? listId
    }

    static func normalizationFingerprint(
        for filter: VectorFilter
    ) -> NormalizationFingerprint {
        NormalizationFingerprint(
            listIds: filter.listIds,
            correspondentQuery: filter.correspondentQuery
        )
    }

    static func normalizingListScope(in filter: VectorFilter) -> VectorFilter {
        guard filter.listIds != nil, !filter.correspondentQuery.isEmpty else { return filter }

        var updated = filter
        updated.correspondentQuery = ""
        return updated
    }

    static func updatingDisplayedQuery(
        _ query: String,
        activeListAddress: String?,
        in filter: VectorFilter
    ) -> VectorFilter {
        guard query != activeListAddress else { return filter }

        var updated = filter
        updated.listIds = nil
        updated.correspondentQuery = query
        return updated
    }

    private static func listLabel(_ list: MailingList, account: Account?) -> String {
        if let address = list.listAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }

        let token = list.listId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return list.lastFromAddress }
        if token.contains("@") { return token }
        if let account, let address = accountDomainListAddress(for: token, account: account) {
            return address
        }
        return token
    }

    private static func accountDomainListAddress(for token: String, account: Account) -> String? {
        let domains = Set(account.ownedEmailAddresses.compactMap(addressDomain))
        for domain in domains.sorted(by: { $0.count > $1.count }) {
            let suffix = ".\(domain)"
            guard token.hasSuffix(suffix) else { continue }
            let local = String(token.dropLast(suffix.count))
            guard !local.isEmpty, !local.contains(".") else { continue }
            return "\(local)@\(domain)"
        }
        return nil
    }

    nonisolated private static func addressDomain(_ address: String) -> String? {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = normalized.firstIndex(of: "@"),
              normalized.index(after: at) < normalized.endIndex else {
            return nil
        }
        let domain = String(normalized[normalized.index(after: at)...])
        return domain.contains(".") ? domain : nil
    }
}

private struct VoicesMailingListRow: View {
    let option: VoicesMailingListOption
    /// Messages in the current scope; nil when counts are not computed yet.
    let inScopeCount: Int?
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(option.address)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let inScopeCount {
                    Text(inScopeCount.formatted(.number))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "Filter by mailing list \(option.address)"
        if let inScopeCount {
            label += ", " + VoicesInScopeCountLabel.text(inScopeCount)
        }
        return label
    }
}
