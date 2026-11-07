import SwiftUI
import OhiaCore

public struct CorrespondentFilterSuggestion: Identifiable, Hashable, Sendable {
    public let value: String
    public let title: String
    public let subtitle: String?
    public let frequency: Int
    public let lastSeen: Date?
    /// Autocomplete forms of `title`, `value`, and `subtitle`, and the words
    /// matched by prefix, folded once here (the catalog is built off the
    /// main actor) so matching never refolds the whole catalog per
    /// keystroke.
    let normalizedTitle: String
    let normalizedValue: String
    let normalizedSubtitle: String
    let normalizedWords: [String]

    nonisolated public var id: String {
        normalizedValue
    }

    nonisolated public init(
        value: String,
        title: String,
        subtitle: String? = nil,
        frequency: Int,
        lastSeen: Date?
    ) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.frequency = frequency
        self.lastSeen = lastSeen
        let normalizedTitle = title.normalizedForCorrespondentAutocomplete
        let normalizedValue = value.normalizedForCorrespondentAutocomplete
        self.normalizedTitle = normalizedTitle
        self.normalizedValue = normalizedValue
        self.normalizedSubtitle = (subtitle ?? "").normalizedForCorrespondentAutocomplete
        self.normalizedWords = (normalizedTitle.split(separator: " ") + normalizedValue.split(separator: "@"))
            .map(String.init)
    }

    // Identity is the displayed suggestion; the normalized forms derive
    // from it and stay out of equality and hashing.
    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.frequency == rhs.frequency
            && lhs.lastSeen == rhs.lastSeen
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(frequency)
        hasher.combine(lastSeen)
    }
}

/// Voices section control: a search field whose header roles are set externally
/// via the Voices icon-pulldown (`ConstellationTopBar`). The active roles ride
/// in the placeholder text so the user can read the checkbox state without
/// re-opening the pulldown. See `VectorFilter.correspondentScopes` and
/// `ConstellationMessageFilter`.
public struct CorrespondentFilterField: View {
    @Binding public var query: String
    @Binding public var scopes: Set<CorrespondentScope>
    public let suggestions: [CorrespondentFilterSuggestion]
    /// In-scope message counts keyed by trimmed, lowercased address, shown
    /// at the trailing edge of each suggestion row. nil shows no counts.
    public let inScopeCounts: [String: Int]?

    /// Local draft of the search field. The committed `query` binding is
    /// only updated when the user presses Return — every keystroke would
    /// otherwise reissue the filter pipeline (vector retrieval + scene
    /// rebuild), which is too expensive to run per character.
    @State private var draft: String = ""
    @State private var suppressSuggestions = false
    @State private var highlightedSuggestionId: String?
    @SwiftUI.FocusState private var fieldFocused: Bool

    public init(
        query: Binding<String>,
        scopes: Binding<Set<CorrespondentScope>>,
        suggestions: [CorrespondentFilterSuggestion] = [],
        inScopeCounts: [String: Int]? = nil
    ) {
        _query = query
        _scopes = scopes
        self.suggestions = suggestions
        self.inScopeCounts = inScopeCounts
    }

    public var body: some View {
        // Search field — chip-vocabulary chrome (height 22, corner 4,
        // 1pt border) so it reads as part of the bar rather than a
        // foreign control. The placeholder lists the active header roles so
        // the user can read the checkbox state without re-opening the Voices
        // icon-pulldown. When the
        // user has typed a query, the field tints to the Ohia accent
        // (green light / amber dark) to signal that it's an active
        // filter — same convention as the Moments pill.
        HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: queryActive ? .semibold : .regular))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: queryActive ? .semibold : .regular))
                    .foregroundStyle(queryActive ? OhiaColors.chipActiveForeground : OhiaColors.textPrimary)
                    .frame(width: 130)
                    .overlay(alignment: .leading) {
                        if draft.isEmpty {
                            placeholderText(for: scopes)
                                .font(.system(size: 11, weight: .regular))
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Correspondent search")
                    .accessibilityHint("Active roles: \(activeRolesSummary(for: scopes))")
                    .focused($fieldFocused)
                    .onSubmit { commitDraft() }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.return) { acceptHighlightedSuggestionOrCommitDraft() }
                    .onKeyPress(.escape) { handleEscape() }
                    .onAppear { draft = query }
                    .onChange(of: query) { _, newValue in
                        // Sync external resets (e.g. "Clear filters" elsewhere)
                        // back into the draft so the field doesn't keep showing
                        // a stale typed value.
                        if newValue != draft { draft = newValue }
                    }
                    .onChange(of: draft) { _, _ in
                        suppressSuggestions = false
                        highlightedSuggestionId = nil
                    }
                    .onChange(of: scopes) { _, _ in
                        suppressSuggestions = false
                        highlightedSuggestionId = nil
                    }
                if clearButtonVisible {
                    Button(action: clearQuery) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(queryActive ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
                            .opacity(0.75)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Clear correspondent filter")
                    .accessibilityLabel("Clear correspondent filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(queryActive ? OhiaColors.chipActiveBackground : OhiaColors.iconPillBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        queryActive ? OhiaColors.chipActiveBorder : OhiaColors.iconPillBorder,
                        lineWidth: 1
                    )
            }
            .popover(isPresented: suggestionPopoverBinding, arrowEdge: .top) {
                let visibleSuggestions = matchingSuggestions()
                CorrespondentSuggestionList(
                    suggestions: visibleSuggestions,
                    highlightedId: highlightedId(in: visibleSuggestions),
                    inScopeCounts: inScopeCounts,
                    onSelect: selectSuggestion(_:)
                )
            }
    }

    private var queryActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var clearButtonVisible: Bool {
        queryActive || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var shouldShowSuggestions: Bool {
        fieldFocused
            && !suppressSuggestions
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !matchingSuggestions().isEmpty
    }

    private var suggestionPopoverBinding: Binding<Bool> {
        Binding(
            get: { shouldShowSuggestions },
            set: { isPresented in
                if !isPresented { suppressSuggestions = true }
            }
        )
    }

    private func clearQuery() {
        draft = ""
        query = ""
        suppressSuggestions = true
        highlightedSuggestionId = nil
    }

    private func handleEscape() -> KeyPress.Result {
        // First Escape: dismiss the suggestion popover if it's open.
        // Second Escape (or no popover open): clear the draft and committed query.
        if shouldShowSuggestions {
            suppressSuggestions = true
            highlightedSuggestionId = nil
            return .handled
        }
        if clearButtonVisible {
            clearQuery()
            return .handled
        }
        return .ignored
    }

    private func commitDraft() {
        query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        suppressSuggestions = true
        highlightedSuggestionId = nil
    }

    private func selectSuggestion(_ suggestion: CorrespondentFilterSuggestion) {
        draft = suggestion.value
        query = suggestion.value
        suppressSuggestions = true
        highlightedSuggestionId = nil
        fieldFocused = false
    }

    private func acceptHighlightedSuggestionOrCommitDraft() -> KeyPress.Result {
        let visibleSuggestions = matchingSuggestions()
        if shouldShowSuggestions,
           let suggestion = highlightedSuggestion(in: visibleSuggestions) {
            selectSuggestion(suggestion)
            return .handled
        }
        commitDraft()
        return .handled
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let visibleSuggestions = matchingSuggestions()
        guard shouldShowSuggestions, !visibleSuggestions.isEmpty else { return .ignored }

        let currentId = highlightedId(in: visibleSuggestions)
        let currentIndex = currentId.flatMap { id in
            visibleSuggestions.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = (currentIndex + delta + visibleSuggestions.count) % visibleSuggestions.count
        highlightedSuggestionId = visibleSuggestions[nextIndex].id
        return .handled
    }

    private func highlightedSuggestion(in visibleSuggestions: [CorrespondentFilterSuggestion]) -> CorrespondentFilterSuggestion? {
        guard let id = highlightedId(in: visibleSuggestions) else { return nil }
        return visibleSuggestions.first { $0.id == id }
    }

    private func highlightedId(in visibleSuggestions: [CorrespondentFilterSuggestion]) -> String? {
        guard !visibleSuggestions.isEmpty else { return nil }
        if let highlightedSuggestionId,
           visibleSuggestions.contains(where: { $0.id == highlightedSuggestionId }) {
            return highlightedSuggestionId
        }
        return visibleSuggestions.first?.id
    }

    private func matchingSuggestions(limit: Int = 7) -> [CorrespondentFilterSuggestion] {
        Self.matchingSuggestions(suggestions, draft: draft, limit: limit)
    }

    /// Ranked autocomplete matches for `draft`: title prefix, then address
    /// prefix, then any word prefix, then substring anywhere; ties by
    /// frequency, recency, and title.
    nonisolated static func matchingSuggestions(
        _ suggestions: [CorrespondentFilterSuggestion],
        draft: String,
        limit: Int = 7
    ) -> [CorrespondentFilterSuggestion] {
        let needle = draft.normalizedForCorrespondentAutocomplete
        guard !needle.isEmpty else { return [] }

        return suggestions
            .compactMap { suggestion -> (CorrespondentFilterSuggestion, Int)? in
                let title = suggestion.normalizedTitle
                let value = suggestion.normalizedValue

                let rank: Int
                if title.hasPrefix(needle) {
                    rank = 0
                } else if value.hasPrefix(needle) {
                    rank = 1
                } else if suggestion.normalizedWords.contains(where: { $0.hasPrefix(needle) }) {
                    rank = 2
                } else if title.contains(needle)
                            || value.contains(needle)
                            || suggestion.normalizedSubtitle.contains(needle) {
                    rank = 3
                } else {
                    return nil
                }
                return (suggestion, rank)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.frequency != rhs.0.frequency { return lhs.0.frequency > rhs.0.frequency }
                let leftSeen = lhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                let rightSeen = rhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                if leftSeen != rightSeen { return leftSeen > rightSeen }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Shared role-label list, stable From → To → Cc → Bcc order mirroring the
    /// checkbox menu, that both the on-screen placeholder and the VoiceOver
    /// summary build from.
    private func activeRoleLabels(for scopes: Set<CorrespondentScope>) -> [String] {
        CorrespondentScope.allCases.compactMap { scope in
            guard scopes.contains(scope) else { return nil }
            switch scope {
            case .from: return "From"
            case .to:   return "To"
            case .cc:   return "Cc"
            case .bcc:  return "Bcc"
            }
        }
    }

    /// Plain-text role summary for VoiceOver, e.g. "From, To, Cc, Bcc" — kept
    /// comma-separated rather than mirroring the on-screen "•" glyphs, which
    /// read poorly when spoken.
    private func activeRolesSummary(for scopes: Set<CorrespondentScope>) -> String {
        let labels = activeRoleLabels(for: scopes)
        return labels.isEmpty ? "No roles selected" : labels.joined(separator: ", ")
    }

    /// On-screen placeholder shown when the field is empty, with "•"
    /// separators in the Ohia accent color (green light / yellow dark) so the
    /// active role list reads as structured chrome rather than plain
    /// instructional text.
    private func placeholderText(for scopes: Set<CorrespondentScope>) -> Text {
        let labels = activeRoleLabels(for: scopes)
        guard let first = labels.first else {
            return Text("No roles selected").foregroundStyle(OhiaColors.textSecondary)
        }
        let separator = Text(" • ").foregroundStyle(OhiaColors.chipActiveForeground)
        return labels.dropFirst().reduce(Text(first).foregroundStyle(OhiaColors.textSecondary)) { text, label in
            text + separator + Text(label).foregroundStyle(OhiaColors.textSecondary)
        }
    }
}

private struct CorrespondentSuggestionList: View {
    let suggestions: [CorrespondentFilterSuggestion]
    let highlightedId: String?
    let inScopeCounts: [String: Int]?
    let onSelect: (CorrespondentFilterSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions) { suggestion in
                CorrespondentSuggestionRow(
                    suggestion: suggestion,
                    isHighlighted: suggestion.id == highlightedId,
                    inScopeCount: inScopeCounts.map {
                        $0[ConstellationMessageFilter.voicesAddressKey(suggestion.value), default: 0]
                    },
                    onSelect: { onSelect(suggestion) }
                )
            }
        }
        .padding(6)
        .frame(width: 292)
    }
}

private struct CorrespondentSuggestionRow: View {
    let suggestion: CorrespondentFilterSuggestion
    let isHighlighted: Bool
    /// Messages in the current scope; nil when counts are not computed yet.
    let inScopeCount: Int?
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .frame(width: 16)

                // Wrap rather than truncate: the trailing count narrows the
                // column, and truncation would end the name in dots.
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = suggestion.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((isHighlighted || isHovering) ? OhiaColors.surface(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityHint("Completes the correspondent filter")
    }

    private var accessibilityLabel: String {
        var label = suggestion.title
        if let subtitle = suggestion.subtitle {
            label += ", \(subtitle)"
        }
        if let inScopeCount {
            label += ", " + VoicesInScopeCountLabel.text(inScopeCount)
        }
        return label
    }
}

/// Spoken form of a Voices row's in-scope count.
enum VoicesInScopeCountLabel {
    static func text(_ count: Int) -> String {
        count == 1 ? "1 message in scope" : "\(count.formatted(.number)) messages in scope"
    }
}

extension String {
    nonisolated var normalizedForCorrespondentAutocomplete: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
