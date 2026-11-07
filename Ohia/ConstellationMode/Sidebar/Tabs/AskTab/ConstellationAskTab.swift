// Ohia/ConstellationMode/Sidebar/Tabs/AskTab/ConstellationAskTab.swift
import AppKit
import SwiftUI
import OhiaCore
import OhiaML

/// Identifies the focused control within the Ask tab. The editor and each
/// history row share a single Tab / Shift+Tab focus chain.
enum AskFocus: Hashable {
    case editor
    case row(UUID)
}

/// Ask-tab body inside the permanent sidebar. Layout (top → bottom):
///   1. Input area (text editor + voice + Ask)
///   2. Divider
///   3. Scrollable history of past Q&A rounds (accordion: one expanded)
///
/// History rows collapse to their question line; the newest entry auto-expands
/// on submit. Tab / Shift+Tab cycles the editor and each row; Space toggles
/// the focused row's expansion. Tapping its question header toggles it too.
///
/// No overlay chrome — the sidebar owns the structural border.
public struct ConstellationAskTab: View {

    @Bindable public var viewModel: QAViewModel
    // `@MainActor` (no `@Sendable`): these closures run only on the main
    // actor — they read main-actor-bound view state. `@Sendable` here was
    // tripping a Swift 6 strict-concurrency conversion warning when
    // forwarding them to `AskInputArea`. `@MainActor`-isolated closures
    // are already safe to capture and pass between main-actor contexts
    // without `@Sendable`.
    public let activeFilter: @MainActor () async -> FilterSpec
    public let threadContextProvider: @MainActor ([RetrievalResult]) async -> AskThreadExpansion
    public let sourceLookup: (Int64) -> VectorRecord?
    public let onCitationHover: (Int64?) -> Void
    public let onCitationClick: (Int64) -> Void

    @State private var dictation = VoiceDictation()
    @SwiftUI.FocusState private var focus: AskFocus?

    public init(
        viewModel: QAViewModel,
        activeFilter: @escaping @MainActor () async -> FilterSpec,
        threadContextProvider: @escaping @MainActor ([RetrievalResult]) async -> AskThreadExpansion = { _ in .empty },
        sourceLookup: @escaping (Int64) -> VectorRecord?,
        onCitationHover: @escaping (Int64?) -> Void,
        onCitationClick: @escaping (Int64) -> Void
    ) {
        self.viewModel = viewModel
        self.activeFilter = activeFilter
        self.threadContextProvider = threadContextProvider
        self.sourceLookup = sourceLookup
        self.onCitationHover = onCitationHover
        self.onCitationClick = onCitationClick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wrap each forwarded closure in a `@MainActor @Sendable`
            // closure literal so the Sendable attribution is explicit at
            // the conversion site. Reading `self.activeFilter` directly
            // from within `body` was shedding the `@Sendable` attribute
            // under Swift 6 strict concurrency, which `AskInputArea`'s
            // `Task { … }` capture requires.
            let filter = activeFilter
            let provider = threadContextProvider
            AskInputArea(
                viewModel: viewModel,
                dictation: dictation,
                activeFilter: { @MainActor @Sendable in await filter() },
                threadContextProvider: { @MainActor @Sendable records in await provider(records) },
                focus: $focus,
                onTabForward: { focusFirstRow() }
            )
            .padding(12)
            Divider().background(OhiaColors.glassBorder)
            historyList
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        if viewModel.history.isEmpty {
            OhiaEmptyPaneStateView(
                systemName: "bubble.left.and.bubble.right",
                title: "No questions yet",
                detail: "Answers cite messages in the active filter scope. Hover a citation to read the source."
            )
        } else {
            ScrollView {
                // Eager VStack (not LazyVStack): Ask histories stay under a
                // few dozen entries, and lazy recycling would silently drop
                // .focused() state on off-screen rows, breaking the Tab
                // focus chain at scroll boundaries.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(viewModel.history.enumerated()), id: \.element.id) { index, entry in
                        AskEntryRow(
                            entry: entry,
                            isExpanded: viewModel.expandedEntryId == entry.id,
                            focus: $focus,
                            onToggle: { viewModel.toggleExpansion(entry.id) },
                            onTabForward: { advanceFocus(from: index, forward: true) },
                            onTabBackward: { advanceFocus(from: index, forward: false) },
                            sourceLookup: sourceLookup,
                            onCitationHover: onCitationHover,
                            onCitationClick: onCitationClick
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Focus chain

    /// Move focus into the first (newest) history row. Called when Tab is
    /// pressed in the editor.
    private func focusFirstRow() {
        guard let first = viewModel.history.first else { return }
        focus = .row(first.id)
    }

    /// Step focus forward / backward through the editor → row₀ → row₁ → …
    /// chain. Stepping back from row₀ returns to the editor; stepping forward
    /// from the last row also wraps back to the editor (one round-trip cycle).
    private func advanceFocus(from index: Int, forward: Bool) {
        let history = viewModel.history
        if forward {
            let next = index + 1
            focus = next < history.count ? .row(history[next].id) : .editor
        } else {
            let prev = index - 1
            focus = prev >= 0 ? .row(history[prev].id) : .editor
        }
    }
}

// MARK: - AskEntryRow

private struct AskEntryRow: View {
    let entry: QAEntry
    let isExpanded: Bool
    var focus: SwiftUI.FocusState<AskFocus?>.Binding
    let onToggle: () -> Void
    let onTabForward: () -> Void
    let onTabBackward: () -> Void
    let sourceLookup: (Int64) -> VectorRecord?
    let onCitationHover: (Int64?) -> Void
    let onCitationClick: (Int64) -> Void

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            questionRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                .focusable(true)
                .focused(focus, equals: .row(entry.id))
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    onToggle()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        onTabBackward()
                    } else {
                        onTabForward()
                    }
                    return .handled
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("Question: \(entry.question)"))
                .accessibilityHint(Text(isExpanded ? "Press Space to collapse" : "Press Space to expand"))
            if isExpanded {
                HStack(alignment: .top, spacing: 6) {
                    Text("A")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(OhiaColors.ohiaGreen)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(OhiaColors.ohiaGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    answerView
                }
                if entry.status == .answered, let routingSummary = entry.routingSummary {
                    Text(routingSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(10)
        .background(OhiaColors.surface(isExpanded ? 0.06 : 0.04))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isFocused ? OhiaColors.ohiaYellow : OhiaColors.glassBorder,
                    lineWidth: isFocused ? 1.5 : 1
                )
                // The border is decoration; citations beneath it own hover and clicks.
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var isFocused: Bool {
        focus.wrappedValue == .row(entry.id)
    }

    private var questionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Q")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(OhiaColors.ohiaYellow)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(OhiaColors.ohiaYellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(entry.question)
                .font(readingTextSize.font(base: 12, weight: .medium, maximumScale: 1.35))
                .foregroundStyle(OhiaColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if (entry.status == .running || entry.status == .idle) && !isExpanded {
                ProgressView()
                    .controlSize(.mini)
                    .labelsHidden()
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 10)
        }
    }

    @ViewBuilder
    private var answerView: some View {
        switch entry.status {
        case .running, .idle:
            ProgressView()
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Working")
        case .answered:
            let citationDisplay = AskCitationDisplayMapper.remap(
                paragraph: entry.answerText,
                sourceVectorIdsByRank: entry.sourceVectorIdsByRank,
                sourceCitationMetadataByRank: entry.sourceCitationMetadataByRank
            )
            let sources = askInlineSources(
                sourceVectorIdsByDisplayIndex: citationDisplay.sourceVectorIdsByDisplayIndex,
                sourceMetadataByDisplayIndex: citationDisplay.sourceMetadataByDisplayIndex,
                sourceLookup: sourceLookup,
                onCitationClick: onCitationClick,
                onCitationHover: onCitationHover
            )
            AskSelectableAnswer(
                paragraph: citationDisplay.paragraph,
                sources: sources,
                pointSize: readingTextSize.pointSize(base: 12)
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(readingTextSize.font(base: 11))
                .foregroundStyle(OhiaColors.frameUrgencyHigh)
        }
    }

}

private struct AskSelectableAnswer: NSViewRepresentable {
    let paragraph: String
    let sources: [InlineCitationSource]
    let pointSize: CGFloat

    func makeNSView(context: Context) -> AskCitationTextView {
        AskCitationTextView(frame: .zero, textContainer: nil)
    }

    func updateNSView(_ view: AskCitationTextView, context: Context) {
        view.setAnswer(paragraph, sources: sources, pointSize: pointSize)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AskCitationTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.answerSize(width: width)
    }

    static func dismantleNSView(_ view: AskCitationTextView, coordinator: ()) {
        view.setHoveredCitation(nil)
    }
}

/// Native selection and link dispatch share one text storage. Hover and clicks
/// call the source directly instead of relying on SwiftUI Text's URL routing.
final class AskCitationTextView: NSTextView, NSTextViewDelegate {
    private let answerTextStorage = NSTextStorage()
    private let answerLayoutManager = NSLayoutManager()
    private var sourcesByIndex: [Int: InlineCitationSource] = [:]
    private var citationTrackingArea: NSTrackingArea?
    private var hoveredCitation: Int?
    private var renderedAnswer: NSAttributedString?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let container = container ?? NSTextContainer(size: .zero)
        answerLayoutManager.addTextContainer(container)
        answerTextStorage.addLayoutManager(answerLayoutManager)
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAnswer(_ paragraph: String, sources: [InlineCitationSource], pointSize: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize),
            .foregroundColor: NSColor(OhiaColors.textPrimary),
            .paragraphStyle: style
        ]
        let result = NSMutableAttributedString(string: "")
        let newSources = Dictionary(sources.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        for token in InlineCitationParser.parse(paragraph, sourceCount: sources.count) {
            switch token {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: base))
            case .citation(let index):
                var attributes = base
                if let source = newSources[index] {
                    attributes[.link] = URL(string: "ohia-ask-source://citation/\(index)")
                    attributes[.foregroundColor] = NSColor(source.tint)
                    attributes[.backgroundColor] = NSColor(source.tint.opacity(0.12))
                    attributes[.font] = NSFont.systemFont(ofSize: 10, weight: .semibold)
                    attributes[.toolTip] = source.subjectLine ?? source.titleLine ?? "Source \(index)"
                }
                result.append(NSAttributedString(string: "[\(index)]", attributes: attributes))
            }
        }
        // TextKit normalizes storage attributes. Compare our input snapshot,
        // not that mutable storage, so scene updates preserve the selection.
        if renderedAnswer?.isEqual(to: result) != true {
            setHoveredCitation(nil)
            renderedAnswer = NSAttributedString(attributedString: result)
            textStorage?.setAttributedString(result)
            invalidateIntrinsicContentSize()
        }
        sourcesByIndex = newSources
    }

    func answerSize(width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 1) }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return CGSize(width: width, height: max(1, ceil(layoutManager.usedRect(for: textContainer).height)))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL,
              let index = Int(url.lastPathComponent),
              let source = sourcesByIndex[index] else { return true }
        setHoveredCitation(nil)
        source.onClick()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard citationTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        citationTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let index = citationIndex(at: convert(event.locationInWindow, from: nil))
        setHoveredCitation(index)
        (index == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredCitation(nil)
        super.mouseExited(with: event)
    }

    func citationIndex(at point: CGPoint) -> Int? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let location = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(location) else {
            return nil
        }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard let url = textStorage.attribute(.link, at: character, effectiveRange: nil) as? URL else { return nil }
        return Int(url.lastPathComponent)
    }

    func setHoveredCitation(_ index: Int?) {
        guard index != hoveredCitation else { return }
        if let previous = hoveredCitation { sourcesByIndex[previous]?.onHover(false) }
        hoveredCitation = index
        if let index { sourcesByIndex[index]?.onHover(true) }
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        if let index, let source = sourcesByIndex[index] {
            textStorage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
                if let url = value as? URL, Int(url.lastPathComponent) == index {
                    layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(source.tint.opacity(0.3)), forCharacterRange: range)
                }
            }
        }
    }
}

// MARK: - Inline source mapping

/// Builds the inline source list for an Ask answer. One entry per display
/// index after `AskCitationDisplayMapper` compacts the prompt's sparse source
/// ranks. Records that fall outside the currently rendered set still produce
/// a chip instead of silently dropping the marker.
@MainActor
private func askInlineSources(
    sourceVectorIdsByDisplayIndex: [Int64],
    sourceMetadataByDisplayIndex: [AskSourceCitationMetadata],
    sourceLookup: @escaping (Int64) -> VectorRecord?,
    onCitationClick: @escaping (Int64) -> Void,
    onCitationHover: @escaping (Int64?) -> Void
) -> [InlineCitationSource] {
    sourceVectorIdsByDisplayIndex.enumerated().map { i, vectorId in
        let rec = sourceLookup(vectorId)
        let metadata = i < sourceMetadataByDisplayIndex.count
            ? sourceMetadataByDisplayIndex[i]
            : .empty
        return InlineCitationSource(
            index: i + 1,
            symbolName: askSourceSymbol(rec, metadata: metadata),
            tint: askSourceTint(rec, metadata: metadata),
            kindLabel: askSourceKindLabel(rec, metadata: metadata),
            titleLine: askSourceTitle(rec, metadata: metadata),
            excerptLine: nil,
            fromLine: nil,
            toLine: nil,
            subjectLine: askSourceTitle(rec, metadata: metadata),
            dateLine: askSourceDateLine(rec),
            onClick: { onCitationClick(vectorId) },
            onHover: { hovering in
                onCitationHover(hovering ? vectorId : nil)
            }
        )
    }
}

private func askSourceKindLabel(_ rec: VectorRecord?, metadata: AskSourceCitationMetadata = .empty) -> String {
    if let label = askVisualMetadataKindLabel(metadata) {
        return label
    }
    guard let rec else { return "source" }
    if rec.collection == .attachment {
        return askAttachmentProvenance(rec) ?? "attachment"
    }
    guard rec.collection == .entity else { return "body text" }
    switch rec.entityKind {
    case .correspondent: return "contact"
    case .attachment: return "attachment"
    case nil: return "mention"
    }
}

private let askSourceDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

private func askSourceDateLine(_ rec: VectorRecord?) -> String? {
    guard let rec, let received = rec.messageReceivedAt else { return nil }
    return askSourceDateFormatter.string(from: Date(timeIntervalSince1970: received))
}

private func askSourceTint(_ rec: VectorRecord?, metadata: AskSourceCitationMetadata = .empty) -> Color {
    if metadata.isUseful { return OhiaColors.accentBlueGlow }
    guard let rec else { return OhiaColors.textTertiary }
    if rec.collection == .attachment { return OhiaColors.accentBlueGlow }
    guard rec.collection == .entity else { return OhiaColors.accentTeal }
    switch rec.entityKind {
    case .correspondent: return .orange
    case .attachment: return .blue.opacity(0.85)
    case nil: return OhiaColors.textSecondary
    }
}

private func askSourceSymbol(_ rec: VectorRecord?, metadata: AskSourceCitationMetadata = .empty) -> String {
    if metadata.isUseful { return "paperclip" }
    guard let rec else { return "questionmark.circle" }
    if rec.collection == .attachment { return "paperclip" }
    guard rec.collection == .entity else { return "envelope.fill" }
    switch rec.entityKind {
    case .correspondent: return "person.crop.circle.fill"
    case .attachment: return "doc.text.fill"
    case nil: return "circle.fill"
    }
}

private func askSourceTitle(_ rec: VectorRecord?, metadata: AskSourceCitationMetadata = .empty) -> String {
    if let title = metadata.title {
        return MIMEHeaderDecoder.decodeEncodedWords(title)
    }
    if let filename = metadata.filename,
       let label = askVisualMetadataKindLabel(metadata) {
        return "\(MIMEHeaderDecoder.decodeEncodedWords(filename)) · \(label)"
    }
    guard let rec else { return "Source" }
    if rec.collection == .attachment {
        return askAttachmentTitle(rec) ?? "Source attachment"
    }
    guard rec.collection == .entity else { return "Source message body" }
    switch rec.entityKind {
    case .correspondent: return "Source correspondent"
    case .attachment: return "Source attachment"
    case nil: return "Source mention"
    }
}

private func askVisualMetadataKindLabel(_ metadata: AskSourceCitationMetadata) -> String? {
    if let kindLabel = metadata.kindLabel {
        return kindLabel
    }
    let provenance = metadata.provenanceLabels.joined(separator: ", ")
    return provenance.isEmpty ? nil : provenance
}

private func askAttachmentMetadata(_ rec: VectorRecord?) -> AttachmentVectorMetadata? {
    guard let rec,
          rec.collection == .attachment,
          let data = rec.metadataJSON.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(AttachmentVectorMetadata.self, from: data)
}

private func askAttachmentProvenance(_ rec: VectorRecord?) -> String? {
    guard let metadata = askAttachmentMetadata(rec) else { return nil }
    return AttachmentEvidenceModality(rawValue: metadata.modality)?.displayLabel
        ?? metadata.modality.replacingOccurrences(of: "-", with: " ")
}

private func askAttachmentTitle(_ rec: VectorRecord?) -> String? {
    guard let metadata = askAttachmentMetadata(rec) else { return nil }
    let provenance = AttachmentEvidenceModality(rawValue: metadata.modality)?.displayLabel ?? "attachment evidence"
    return "\(MIMEHeaderDecoder.decodeEncodedWords(metadata.filename)) · \(provenance)"
}
