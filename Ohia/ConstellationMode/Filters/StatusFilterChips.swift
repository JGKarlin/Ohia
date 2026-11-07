import SwiftUI
import OhiaCore

public struct StatusFilterChips: View {
    @Binding public var readStates: Set<Bool>?
    @Binding public var repliedStates: Set<Bool>?
    @Binding public var sentStates: Set<Bool>?
    @Binding public var flaggedOnly: Bool
    @Binding public var hasAttachmentsOnly: Bool
    /// Subset of `TraceToggle` cases the user has chosen to render in the
    /// bar. Owned by `ConstellationTopBar` (persisted via @AppStorage).
    /// Cases not in this set are absent from the bar but still listed
    /// (unchecked) in the section's icon-pulldown menu.
    public let displayed: Set<TraceToggle>
    /// Lens-scoped hiding for the direction pair. This is intentionally
    /// separate from `displayed`: the user's Traces display preference should
    /// survive leaving a lens whose product contract makes direction fixed.
    public let hidesDirectionPair: Bool

    public init(
        readStates: Binding<Set<Bool>?>,
        repliedStates: Binding<Set<Bool>?>,
        sentStates: Binding<Set<Bool>?>,
        flaggedOnly: Binding<Bool>,
        hasAttachmentsOnly: Binding<Bool>,
        displayed: Set<TraceToggle>,
        hidesDirectionPair: Bool = false
    ) {
        _readStates = readStates
        _repliedStates = repliedStates
        _sentStates = sentStates
        _flaggedOnly = flaggedOnly
        _hasAttachmentsOnly = hasAttachmentsOnly
        self.displayed = displayed
        self.hidesDirectionPair = hidesDirectionPair
    }

    public var body: some View {
        // Each chip is an individual top-level subview so
        // `OverflowChipFlowLayout` can size and prioritize each one. The
        // three co-dependent pairs (received/sent, unread/read,
        // replied/unreplied) render as visually grouped pairs separated
        // by short vertical hairlines; the standalone tail (flagged,
        // has-attachments) sits after the last pair without an inter-tail
        // hairline.
        //
        // `OverflowChipOrdering` picks a single mode for the whole row
        // (every chip at word OR every chip at icon), so the two halves
        // of a pair always collapse together as the bar narrows. The
        // pair-as-unit display contract is enforced upstream by
        // `ConstellationTopBar.toggleTracesPair`, so a pair is rendered
        // whenever either half appears in `displayed` — this defends
        // against any legacy persisted state where only one half might
        // remain in the set.
        let pair1 = !hidesDirectionPair && (displayed.contains(.received) || displayed.contains(.sent))
        let pair2 = displayed.contains(.unread) || displayed.contains(.read)
        let pair3 = displayed.contains(.replied) || displayed.contains(.unreplied)
        let tail = displayed.contains(.flagged)
            || displayed.contains(.hasAttachments)

        if pair1 {
            adaptiveChip(
                "Received", trace: .received,
                isOn: triBinding(for: false, bind: $sentStates),
                help: "Mail others sent to you"
            )
            adaptiveChip(
                "Sent", trace: .sent,
                isOn: triBinding(for: true, bind: $sentStates),
                help: "Your outgoing mail"
            )
            if pair2 || pair3 || tail { groupSeparator() }
        }
        if pair2 {
            adaptiveChip(
                "Read", trace: .read,
                isOn: triBinding(for: true, bind: $readStates),
                help: "Messages you've already opened"
            )
            adaptiveChip(
                "Unread", trace: .unread,
                isOn: triBinding(for: false, bind: $readStates),
                help: "Messages you haven't opened yet"
            )
            if pair3 || tail { groupSeparator() }
        }
        if pair3 {
            adaptiveChip(
                "Replied", trace: .replied,
                isOn: triBinding(for: true, bind: $repliedStates),
                help: "Threads you've responded to"
            )
            adaptiveChip(
                "Unreplied", trace: .unreplied,
                isOn: triBinding(for: false, bind: $repliedStates),
                help: "Awaiting your response"
            )
            if tail { groupSeparator() }
        }
        if displayed.contains(.flagged) {
            adaptiveChip(
                "Flagged", trace: .flagged,
                isOn: $flaggedOnly,
                help: "Starred or flagged messages"
            )
        }
        if displayed.contains(.hasAttachments) {
            adaptiveChip(
                "Attachments", trace: .hasAttachments,
                isOn: $hasAttachmentsOnly,
                help: "Messages with files attached"
            )
        }
    }

    /// Short vertical hairline that fences off co-dependent pair groups.
    /// Same color as the bar's `sectionDivider` but pinned to the chip
    /// row (~16pt of visible line) so it reads as nested inside a
    /// section rather than a peer of the inter-section dividers.
    /// Registered as a chip subview with matching word/icon widths and
    /// `isPressed: true` so the overflow layout never folds it away when
    /// the bar narrows.
    private func groupSeparator() -> some View {
        let totalWidth: CGFloat = 9
        return Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 1, height: 16)
            .frame(width: totalWidth, height: 22)
            .chipMetrics(
                wordWidth: totalWidth,
                iconWidth: totalWidth,
                isPressed: true
            )
    }

    private func adaptiveChip(
        _ label: String,
        trace: TraceToggle,
        isOn: Binding<Bool>,
        help: String
    ) -> some View {
        let pressed = isOn.wrappedValue
        let wordWidth = label.chipWordWidth(bold: pressed)
        return Button(action: { isOn.wrappedValue.toggle() }) {
            AdaptiveChip(
                wordWidth: wordWidth,
                isPressed: pressed,
                tooltipLabel: label,
                tooltipDescription: help,
                word: { FilterChipLabel(text: label, isOn: pressed) },
                icon: {
                    chipIcon(
                        systemName: ToggleIconography.symbolName(for: trace),
                        isOn: pressed
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .chipMetrics(wordWidth: wordWidth, isPressed: pressed)
    }

    /// Tri-state helper: nil = both active. Removing both → nil (avoid an empty set that filters everything out).
    private func triBinding(
        for value: Bool,
        bind: Binding<Set<Bool>?>
    ) -> Binding<Bool> {
        Binding(
            get: { (bind.wrappedValue ?? Set([true, false])).contains(value) },
            set: { newVal in
                var active = bind.wrappedValue ?? Set([true, false])
                if newVal { active.insert(value) } else { active.remove(value) }
                bind.wrappedValue = active == Set([true, false]) ? nil : (active.isEmpty ? nil : active)
            }
        )
    }
}
