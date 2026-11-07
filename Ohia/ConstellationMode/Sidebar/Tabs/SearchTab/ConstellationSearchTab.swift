import SwiftUI
import OhiaCore
import OhiaML

/// Exact-biased literal finder for the Constellation. Distinct from Ask
/// (semantic retrieval → synthesized answer): Search drives the FTS5 trigram
/// index directly, surfaces literal hits BM25-ranked, and is honest when a
/// term is absent. The sidebar shows two things — the *shape* of the match
/// (per-term / per-field counts, distribution) and a *match navigator* for
/// choosing a literal hit. The explicit Warp action moves the scene to the
/// chosen hit. No message body text appears here;
/// content is inspected spatially in the scene's locked-node overlay.
public struct ConstellationSearchTab: View {

    @Binding public var searchQuery: String
    public let model: ConstellationSearchModel
    public let matchIndex: Int
    public let onSubmit: () -> Void
    public let onSelectLane: (LexicalSearchLane) -> Void
    /// Absolute match index to select. The host clamps / wraps.
    public let onSelectMatch: (Int) -> Void
    /// Absolute match index to select and warp to. The host clamps / wraps.
    public let onWarpMatch: (Int) -> Void

    public init(
        searchQuery: Binding<String>,
        model: ConstellationSearchModel,
        matchIndex: Int,
        onSubmit: @escaping () -> Void,
        onSelectLane: @escaping (LexicalSearchLane) -> Void,
        onSelectMatch: @escaping (Int) -> Void,
        onWarpMatch: @escaping (Int) -> Void
    ) {
        self._searchQuery = searchQuery
        self.model = model
        self.matchIndex = matchIndex
        self.onSubmit = onSubmit
        self.onSelectLane = onSelectLane
        self.onSelectMatch = onSelectMatch
        self.onWarpMatch = onWarpMatch
    }

    private var clampedIndex: Int {
        guard !model.matches.isEmpty else { return 0 }
        return min(max(matchIndex, 0), model.matches.count - 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                if model.hasQuery {
                    classificationRow
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if model.hasQuery {
                Divider().background(OhiaColors.glassBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailBody
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
                Spacer(minLength: 0)
                Divider().background(OhiaColors.glassBorder)
                navigator
            } else {
                idleHint
            }

        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OhiaColors.textSecondary)
            TextField("Find a word, phrase, or number", text: $searchQuery)
                .textFieldStyle(.plain)
                .tint(OhiaColors.chipActiveForeground)
                .onSubmit { onSubmit() }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.surface(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.5), lineWidth: 1)
        )
    }

    /// Centered idle state mirroring the Ask tab's empty-state idiom: a glyph,
    /// a short heading, and one concise line of guidance.
    private var idleHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(OhiaColors.textTertiary.opacity(0.5))
            Text("Exact and nearby matches")
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
            Text("Finds literal text hits and semantically related results. Wrap a phrase in quotes to match it exactly.")
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textTertiary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Classification — EXACT vs NEARBY

    private var classificationRow: some View {
        HStack(spacing: 8) {
            laneChip(.exact, title: "EXACT")
            laneChip(.semantic, title: "NEARBY")
        }
    }

    private func laneChip(_ lane: LexicalSearchLane, title: String) -> some View {
        let selected = model.selectedLane == lane
        let enabled = model.laneIsSelectable(lane)
        let pending = lane == .semantic && model.semanticSearchPending
        let foreground = selected ? OhiaColors.chipActiveForeground : OhiaColors.ohiaGreen
        let valueForeground = selected ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary
        let captionForeground = selected ? OhiaColors.textSecondary : OhiaColors.textTertiary
        let background = selected ? OhiaColors.chipActiveBackground : OhiaColors.buttonBackground
        let border = selected ? OhiaColors.chipActiveBorder : OhiaColors.ohiaYellow

        return Button {
            guard enabled else { return }
            onSelectLane(lane)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(foreground)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if pending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(OhiaColors.ohiaGreen)
                            .scaleEffect(0.58)
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    } else {
                        Text(laneValue(lane))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundStyle(valueForeground)
                    }
                    Text(laneCaption(lane))
                        .font(.system(size: 9))
                        .foregroundStyle(captionForeground)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || pending ? 1 : 0.45)
        .accessibilityLabel(Text(title == "EXACT" ? "Exact results" : "Nearby results"))
        .accessibilityValue(Text(laneCaption(lane)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func laneValue(_ lane: LexicalSearchLane) -> String {
        switch lane {
        case .exact:
            return model.exactCount > 0 ? "\(model.exactCount)" : "none"
        case .semantic:
            guard model.semanticLaneAvailable else { return "—" }
            return model.semanticCount > 0 ? "\(model.semanticCount)" : "none"
        }
    }

    private func laneCaption(_ lane: LexicalSearchLane) -> String {
        switch lane {
        case .exact:
            if model.exactCount > 0, model.exactMatchCount == 0 { return "not placed" }
            return model.exactCount == 1 ? "literal hit" : "literal hits"
        case .semantic:
            if model.semanticSearchPending { return "checking" }
            guard model.semanticLaneAvailable else { return "preparing" }
            guard model.semanticCount > 0 else { return "neighbors" }
            return model.weakSemantic ? "weak · \(model.topScoreText)" : "neighbors"
        }
    }

    // MARK: - Sections — SHAPE

    @ViewBuilder
    private var detailBody: some View {
        if !model.hasAnyLaneResults {
            if model.semanticSearchPending {
                nearbyPendingState
            } else {
                emptySearchState
            }
        } else if model.selectedLane == .exact, model.semanticSearchPending {
            termSection
            fieldSection
            distributionSection
            nearbyPendingStatus
        } else {
            switch model.selectedLane {
            case .exact:
                termSection
                fieldSection
                distributionSection
            case .semantic:
                semanticFallbackSection
            case nil:
                emptySearchState
            }
        }
    }

    private var nearbyPendingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            nearbyPendingHeader
            Text("Nearby meanings are still being checked.")
                .font(.system(size: 10.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(OhiaColors.glassPanel))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
    }

    private var nearbyPendingStatus: some View {
        section("NEARBY") {
            nearbyPendingHeader
        }
    }

    private var nearbyPendingHeader: some View {
        HStack(spacing: 7) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(OhiaColors.ohiaGreen)
                .scaleEffect(0.62)
                .frame(width: 16, height: 16)
            Text("Checking nearby meanings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
        }
    }

    private var emptySearchState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Text("No matches in current scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
            }
            Text("Try another search or broaden the active filters.")
                .font(.system(size: 10.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(OhiaColors.glassPanel))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var termSection: some View {
        if !model.terms.isEmpty || model.phrase != nil {
            section("TERMS") {
                ForEach(Array(model.terms.enumerated()), id: \.offset) { _, term in
                    countBar(label: term.label, count: term.count, max: model.maxTermCount, tint: OhiaColors.chipActiveForeground)
                }
                if let phrase = model.phrase {
                    countBar(label: "\"\(phrase.label)\"", count: phrase.count, max: model.maxTermCount, tint: OhiaColors.chipActiveForeground, accentLabel: true)
                }
            }
        }
    }

    private var fieldSection: some View {
            section("WHERE IT MATCHED") {
                countBar(label: "subject", count: model.fieldSubject, max: model.maxFieldCount, tint: OhiaColors.chipActiveForeground)
                countBar(label: "body", count: model.fieldBody, max: model.maxFieldCount, tint: OhiaColors.chipActiveForeground)
                countBar(label: "attachment", count: model.fieldAttachment, max: model.maxFieldCount, tint: OhiaColors.chipActiveForeground)
                countBar(label: "sender", count: model.fieldSender, max: model.maxFieldCount, tint: OhiaColors.chipActiveForeground)
            }
        }

    @ViewBuilder
    private var distributionSection: some View {
        if model.span != nil || model.topCluster != nil || model.topSender != nil {
            section("DISTRIBUTION") {
                if let span = model.span {
                    statRow("Span", value: Self.formatSpan(span))
                }
                if let cluster = model.topCluster {
                    statRow("Top cluster", value: "\"\(cluster.label)\" (\(cluster.count))")
                }
                if let sender = model.topSender {
                    statRow("Top sender", value: "\(sender.label) (\(sender.count))")
                }
            }
        }
    }

    private var semanticFallbackSection: some View {
        section("NEAREST MEANINGS") {
            statRow("Neighbors", value: "\(model.semanticCount)")
            if model.topSemanticScore != nil {
                statRow("Top score", value: model.topScoreText)
                statRow("Strength", value: model.weakSemantic ? "weak" : "moderate")
            }
        }
    }

    // MARK: - Match navigator

    @ViewBuilder
    private var navigator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MATCH")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(OhiaColors.textTertiary)

            if model.matches.isEmpty {
                if model.semanticSearchPending {
                    nearbyPendingHeader
                } else {
                    Text("No matches to step through.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let match = model.matches[clampedIndex]
                let laneLabel = model.selectedLane == .semantic ? "nearby" : "match"
                HStack(spacing: 10) {
                    stepButton(symbol: "chevron.left", shift: true) { stepMatch(by: -1) }
                    VStack(spacing: 1) {
                        Text("\(laneLabel) \(clampedIndex + 1) / \(model.matches.count)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(OhiaColors.textPrimary)
                        if model.selectedLane == .exact && model.activeTotalCount > model.matches.count {
                            // The reachable set can be smaller than the literal
                            // count — either capped, or some matched messages
                            // aren't placed as nodes in this frame yet.
                            Text("\(model.matches.count) reachable of \(model.activeTotalCount)")
                                .font(.system(size: 8.5))
                                .foregroundStyle(OhiaColors.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    stepButton(symbol: "chevron.right", shift: false) { stepMatch(by: 1) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    matchMetaRow(
                        symbol: model.selectedLane == .semantic ? "point.3.connected.trianglepath.dotted" : "doc.text.magnifyingglass",
                        text: match.fieldsLabel
                    )
                    if let subject = match.subjectLine {
                        matchMetaRow(symbol: "envelope", text: "subject: \(subject)")
                    }
                    if !match.attachmentFilenames.isEmpty {
                        matchMetaRow(symbol: "paperclip", text: match.attachmentEvidenceLabel)
                        if let snippet = match.attachmentSnippet {
                            matchMetaRow(symbol: "quote.bubble", text: snippet)
                        }
                    }
                    matchMetaRow(symbol: "person.crop.circle", text: "\(match.sender) · \(match.dateLabel)")
                    if let cluster = match.clusterLabel {
                        matchMetaRow(symbol: "circle.hexagongrid", text: "cluster \"\(cluster)\"")
                    }
                }

                warpButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func matchMetaRow(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepMatch(by direction: Int) {
        let target = clampedIndex + direction
        onSelectMatch(target)
    }

    // Emblem-style stepper (ʻōhiʻa green glyph, yellow stroke, faint fill).
    // ⌘G / ⇧⌘G step forward / backward.
    private func stepButton(symbol: String, shift: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaGreen)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.buttonBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("g", modifiers: shift ? [.command, .shift] : .command)
    }

    // Emblem-style primary affordance.
    private var warpButton: some View {
        Button(action: { onWarpMatch(clampedIndex) }) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                Text("Go!")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(OhiaColors.ohiaGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.buttonBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reusable

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(OhiaColors.textTertiary)
            content()
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(OhiaColors.textPrimary)
        }
    }

    /// Count row with a proportional rarity bar behind the label, so a rare
    /// term reads differently from a common one at a glance.
    private func countBar(label: String, count: Int, max: Int, tint: Color, accentLabel: Bool = false) -> some View {
        let fraction = max > 0 ? Double(count) / Double(max) : 0
        return ZStack(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.16))
                    .frame(width: geo.size.width * fraction)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: accentLabel ? .medium : .regular))
                    .foregroundStyle(accentLabel ? tint : OhiaColors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(OhiaColors.textPrimary)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 20)
    }

    // MARK: - Formatting

    private static let spanDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func formatSpan(_ range: ClosedRange<Date>) -> String {
        let days = Calendar.current.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
        let lower = spanDayFormatter.string(from: range.lowerBound)
        let upper = spanDayFormatter.string(from: range.upperBound)
        if lower == upper { return "\(lower) · \(days)d" }
        return "\(lower) → \(upper) · \(days)d"
    }

    private static func attachmentFilenameLabel(_ filenames: [String]) -> String {
        let decoded = filenames.map(MIMEHeaderDecoder.decodeEncodedWords)
        let visible = decoded.prefix(2).joined(separator: ", ")
        let extra = filenames.count - 2
        guard extra > 0 else { return visible }
        return "\(visible) +\(extra)"
    }
}

// MARK: - View model

/// App-layer view model for the Search tab, assembled from a
/// `LexicalSearchResult` plus cluster labels and sender display names that
/// live in the app target.
public struct ConstellationSearchModel: Equatable {

    public struct Match: Equatable {
        public let vectorId: Int64
        public let fieldsLabel: String
        public let subjectLine: String?
        public let attachmentFilenames: [String]
        public let attachmentEvidenceLabel: String
        public let attachmentSnippet: String?
        public let sender: String
        public let dateLabel: String
        public let clusterLabel: String?

        public init(
            vectorId: Int64,
            fieldsLabel: String,
            subjectLine: String? = nil,
            attachmentFilenames: [String] = [],
            attachmentEvidenceLabel: String? = nil,
            attachmentSnippet: String? = nil,
            sender: String,
            dateLabel: String,
            clusterLabel: String?
        ) {
            self.vectorId = vectorId
            self.fieldsLabel = fieldsLabel
            self.subjectLine = Self.cleanOptionalLine(subjectLine)
            let decodedAttachmentFilenames = attachmentFilenames.map(MIMEHeaderDecoder.decodeEncodedWords)
            self.attachmentFilenames = decodedAttachmentFilenames
            self.attachmentEvidenceLabel = attachmentEvidenceLabel
                .map(MIMEHeaderDecoder.decodeEncodedWords)
                ?? Self.filenameLabel(decodedAttachmentFilenames)
            self.attachmentSnippet = Self.displayAttachmentSnippet(attachmentSnippet)
            self.sender = sender
            self.dateLabel = dateLabel
            self.clusterLabel = clusterLabel
        }

        private static func filenameLabel(_ filenames: [String]) -> String {
            let decoded = filenames.map(MIMEHeaderDecoder.decodeEncodedWords)
            let visible = decoded.prefix(2).joined(separator: ", ")
            let extra = filenames.count - 2
            guard extra > 0 else { return visible }
            return "\(visible) +\(extra)"
        }

        private static func cleanOptionalLine(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        private static func displayAttachmentSnippet(_ value: String?) -> String? {
            guard let snippet = cleanOptionalLine(value) else { return nil }
            let markers: [String] = [
                "VISUAL_ATTACHMENT:",
                "VISUAL_SUMMARY:",
                "VISUAL_KIND:",
                "VISION_LABELS:",
                "VISION_OBJECTS:",
                "OCR_TEXT:"
            ]
            var pieces: [String] = []
            var index = snippet.startIndex

            while index < snippet.endIndex {
                let remainder = snippet[index...]
                guard let marker = markers.first(where: { remainder.hasPrefix($0) }) else {
                    pieces.append(String(snippet[index]))
                    index = snippet.index(after: index)
                    continue
                }

                let valueStart = snippet.index(index, offsetBy: marker.count)
                let nextMarkerRange = markers
                    .compactMap { next in snippet.range(of: next, range: valueStart..<snippet.endIndex) }
                    .min { $0.lowerBound < $1.lowerBound }

                if marker == "OCR_TEXT:" {
                    let valueEnd = nextMarkerRange?.lowerBound ?? snippet.endIndex
                    let ocrText = snippet[valueStart..<valueEnd]
                    pieces.append(String(ocrText))
                }

                index = nextMarkerRange?.lowerBound ?? snippet.endIndex
            }

            return cleanOptionalLine(pieces.joined())
        }
    }

    public struct LabeledCount: Equatable {
        public let label: String
        public let count: Int
        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public struct TermCount: Equatable {
        public let label: String
        public let count: Int
        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public let query: String
    public let hasQuery: Bool
    public let isPhrase: Bool
    public let selectedLane: LexicalSearchLane?
    public let exactCount: Int
    public let exactMatchCount: Int
    public let semanticCount: Int
    public let semanticLaneAvailable: Bool
    public let semanticSearchPending: Bool
    public let topSemanticScore: Float?
    public let weakSemantic: Bool
    public let terms: [TermCount]
    public let phrase: TermCount?
    public let fieldSubject: Int
    public let fieldBody: Int
    public let fieldSender: Int
    public let fieldAttachment: Int
    public let span: ClosedRange<Date>?
    public let topCluster: LabeledCount?
    public let topSender: LabeledCount?
    public let activeTotalCount: Int
    public let matches: [Match]

    public init(
        query: String,
        hasQuery: Bool,
        isPhrase: Bool,
        selectedLane: LexicalSearchLane?,
        exactCount: Int,
        exactMatchCount: Int,
        semanticCount: Int,
        semanticLaneAvailable: Bool,
        semanticSearchPending: Bool = false,
        topSemanticScore: Float?,
        weakSemantic: Bool,
        terms: [TermCount],
        phrase: TermCount?,
        fieldSubject: Int,
        fieldBody: Int,
        fieldSender: Int,
        fieldAttachment: Int,
        span: ClosedRange<Date>?,
        topCluster: LabeledCount?,
        topSender: LabeledCount?,
        activeTotalCount: Int,
        matches: [Match]
    ) {
        self.query = query
        self.hasQuery = hasQuery
        self.isPhrase = isPhrase
        self.selectedLane = selectedLane
        self.exactCount = exactCount
        self.exactMatchCount = exactMatchCount
        self.semanticCount = semanticCount
        self.semanticLaneAvailable = semanticLaneAvailable
        self.semanticSearchPending = semanticSearchPending
        self.topSemanticScore = topSemanticScore
        self.weakSemantic = weakSemantic
        self.terms = terms
        self.phrase = phrase
        self.fieldSubject = fieldSubject
        self.fieldBody = fieldBody
        self.fieldSender = fieldSender
        self.fieldAttachment = fieldAttachment
        self.span = span
        self.topCluster = topCluster
        self.topSender = topSender
        self.activeTotalCount = activeTotalCount
        self.matches = matches
    }

    public var hasAnyLaneResults: Bool {
        exactMatchCount > 0 || semanticCount > 0
    }

    public func laneIsSelectable(_ lane: LexicalSearchLane) -> Bool {
        switch lane {
        case .exact:
            return exactMatchCount > 0
        case .semantic:
            return semanticLaneAvailable && semanticCount > 0
        }
    }

    public var maxTermCount: Int {
        let termMax = terms.map(\.count).max() ?? 0
        return Swift.max(termMax, phrase?.count ?? 0, 1)
    }

    public var maxFieldCount: Int {
        Swift.max(fieldSubject, fieldBody, fieldSender, fieldAttachment, 1)
    }

    public var topScoreText: String {
        guard let score = topSemanticScore else { return "—" }
        return score.formatted(.number.precision(.fractionLength(2)))
    }

    public static let empty = ConstellationSearchModel(
        query: "",
        hasQuery: false,
        isPhrase: false,
        selectedLane: nil,
        exactCount: 0,
        exactMatchCount: 0,
        semanticCount: 0,
        semanticLaneAvailable: false,
        semanticSearchPending: false,
        topSemanticScore: nil,
        weakSemantic: false,
        terms: [],
        phrase: nil,
        fieldSubject: 0,
        fieldBody: 0,
        fieldSender: 0,
        fieldAttachment: 0,
        span: nil,
        topCluster: nil,
        topSender: nil,
        activeTotalCount: 0,
        matches: []
    )
}
