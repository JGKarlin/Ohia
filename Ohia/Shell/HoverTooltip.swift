// Ohia/Shell/HoverTooltip.swift
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// `.tooltip("...")` shows a SwiftUI overlay near the element after a short
/// hover delay. We don't use the system `.help(...)` modifier because its
/// underlying `NSToolTipManager` has a long, unreliable delay (≈1.5s) and
/// is sensitive to cursor micro-movements between chips. This implementation
/// uses `.onHover` + a cancellable `Task.sleep` so the tooltip appears
/// promptly and disappears the instant the cursor leaves.
public extension View {
    func tooltip(_ text: String, anchor: TooltipAnchor = .leading) -> some View {
        modifier(HoverTooltipModifier(text: text.tooltipWithoutTerminalPunctuation, anchor: anchor, delay: .short))
    }

    /// Shows the tooltip the instant the cursor lands on the source — no
    /// hover delay. Used by the category hash strip, where sweeping across
    /// many tiny hashes should read each label immediately. Stays on the
    /// custom tooltip (not `.help`) so it isn't subject to NSToolTipManager's
    /// long delay.
    func tooltipImmediate(_ text: String, anchor: TooltipAnchor = .leading) -> some View {
        modifier(HoverTooltipModifier(text: text.tooltipWithoutTerminalPunctuation, anchor: anchor, delay: .immediate))
    }
}

/// Where the tooltip bubble sits relative to the source view.
///
/// - `.leading` / `.trailing`: bubble appears **below** the source,
///   anchored to that horizontal edge. The default reads-down
///   placement used by chips and toolbar buttons.
/// - `.leadingSide` / `.trailingSide`: bubble appears **beside** the
///   source, vertically centered on its row, with the bubble's near
///   edge sitting just outside the source's far edge. Used when the
///   source is a tall row whose vertical center is the visual anchor
///   (e.g. the Projects pip column, where below-anchoring would
///   shift the tooltip off the row it describes).
public enum TooltipAnchor {
    case leading
    case trailing
    case leadingSide
    case trailingSide
}

/// User-overridable preference. Default ON so first-launch users see
/// guidance; can be turned off in Settings → General.
public enum OhiaTooltipPreference {
    public static let storageKey = "ohiaShowTooltips"
}

/// How long the cursor must rest before the tooltip appears.
private enum TooltipDelay {
    /// Prompt but debounced — avoids flicker when sweeping across a row of
    /// controls. The default for chips and toolbar buttons.
    case `short`
    /// No delay — shows the moment the cursor lands. For dense readouts (the
    /// category hash strip) where immediate feedback is the point.
    case immediate

    var nanoseconds: UInt64 {
        switch self {
        case .short: return 600_000_000      // 0.6s
        case .immediate: return 0
        }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let anchor: TooltipAnchor
    let delay: TooltipDelay
    @AppStorage(OhiaTooltipPreference.storageKey) private var enabled: Bool = true
    @State private var showTooltip: Bool = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                guard enabled else { showTooltip = false; return }
                if hovering {
                    if delay == .immediate {
                        withAnimation(.easeOut(duration: 0.08)) {
                            showTooltip = true
                        }
                    } else {
                        hoverTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: delay.nanoseconds)
                            if !Task.isCancelled {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showTooltip = true
                                }
                            }
                        }
                    }
                } else {
                    showTooltip = false
                }
            }
            .accessibilityHint(text)
            .overlay(alignment: overlayAlignment) {
                if showTooltip && enabled && !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(textAlignment)
                        .lineSpacing(2)
                        .lineLimit(nil)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: tooltipWidth, alignment: frameAlignment)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.regularMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.35), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                        // Position depends on anchor variant:
                        //   .leading / .trailing → bubble below source,
                        //     hanging from its leading or trailing
                        //     edge (the default reads-down placement).
                        //   .leadingSide / .trailingSide → bubble
                        //     beside source, vertically centered, with
                        //     the near edge tucked just outside the
                        //     source's far edge. Used by tall rows
                        //     where below-anchoring would visually
                        //     drift onto the next row.
                        .offset(x: bubbleOffsetX, y: bubbleOffsetY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(10_000)
                }
            }
    }

    private var overlayAlignment: Alignment {
        switch anchor {
        case .leading: return .topLeading
        case .trailing: return .topTrailing
        // Side variants center vertically on the source so the
        // bubble sits exactly beside the row it describes.
        case .leadingSide: return .trailing
        case .trailingSide: return .leading
        }
    }

    private var frameAlignment: Alignment {
        switch anchor {
        case .leading, .leadingSide: return .leading
        case .trailing, .trailingSide: return .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch anchor {
        case .leading, .leadingSide: return .leading
        case .trailing, .trailingSide: return .trailing
        }
    }

    private var bubbleOffsetX: CGFloat {
        switch anchor {
        case .leading, .trailing:
            return 0
        case .leadingSide:
            // Anchored at source's trailing edge; push the bubble's
            // full width plus an 8pt gap to the right so it sits
            // entirely outside the source on the right side.
            return tooltipWidth + 8
        case .trailingSide:
            // Anchored at source's leading edge; push left by the
            // bubble's width + 8pt gap so it sits outside on the
            // left side.
            return -(tooltipWidth + 8)
        }
    }

    private var bubbleOffsetY: CGFloat {
        switch anchor {
        case .leading, .trailing: return 26
        case .leadingSide, .trailingSide: return 0
        }
    }

    private var tooltipWidth: CGFloat {
        // 36pt floor is just enough room for the 20pt of horizontal
        // padding plus a 2-letter glyph; below that the bubble reads
        // like a stray pill rather than a tooltip. Without this
        // floor (or with the previous 80pt floor), short single-
        // word tooltips like "Pin" or "Today" inherit a much wider
        // frame than they need — and because side-anchored variants
        // right- or left-align text inside that frame, the bubble
        // ends up with a large empty band beside the word.
        min(280, max(36, measuredTextWidth + 20))
    }

    private var measuredTextWidth: CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: 12)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        #else
        return CGFloat(text.count * 7)
        #endif
    }
}

private extension String {
    var tooltipWithoutTerminalPunctuation: String {
        var cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, ".!?".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}
