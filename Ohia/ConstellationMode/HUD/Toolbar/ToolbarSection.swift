import SwiftUI

private struct ConstellationToolbarCompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ConstellationToolbarShowsAccessorsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var constellationToolbarCompactLayout: Bool {
        get { self[ConstellationToolbarCompactLayoutKey.self] }
        set { self[ConstellationToolbarCompactLayoutKey.self] = newValue }
    }

    var constellationToolbarShowsAccessors: Bool {
        get { self[ConstellationToolbarShowsAccessorsKey.self] }
        set { self[ConstellationToolbarShowsAccessorsKey.self] = newValue }
    }
}

/// One named section in the Constellation toolbar.
///
/// Header is a Mail.app-style icon-pill plus a normal-case section name and
/// (optionally) a small uppercase journalistic accessor (where / when / who
/// / what / why / how) tail. The pill comes in two variants:
///
/// - **Passive** (default init) — the SF Symbol sits in a 22×20 squircle
///   and is purely chrome.
/// - **Menu** (init with `menu:`) — the pill widens to host an internal
///   hairline divider and a chevron, NSPopUpButton-shaped, and clicking it
///   opens the supplied `Menu` content.
///
/// Content is laid out via `ChipFlowLayout` so that pressed (active-filter)
/// chips ALWAYS render, while unpressed chips overflow into a trailing
/// `+N` chip that opens a popover with the hidden chips. The menu-pill
/// variant gives sections a separate curated-display surface; the in-bar
/// `+N` overflow remains as a fallback for when the user has displayed
/// more chips than fit at the current width.
struct ToolbarSection<Content: View, MenuContent: View>: View {
    let title: String
    let symbolName: String
    let accessor: String?
    let helpText: String
    var alignment: HorizontalAlignment = .leading
    let horizontalPadding: CGFloat
    /// When `true`, the chip strip uses `OverflowChipFlowLayout` (which
    /// collapses chips from word → icon → folded). When `false`, the
    /// classic `ChipFlowLayout` runs (drops unpressed chips into the
    /// trailing `+N` popover). Curated sections opt in via the menu init.
    let useOverflowFlow: Bool
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let content: () -> Content

    @Environment(\.constellationToolbarCompactLayout)
    private var compactLayout
    @Environment(\.constellationToolbarShowsAccessors)
    private var showsAccessors

    @State private var hiddenCount: Int = 0
    /// Drives the popover that hosts the menu rows. We use a manual
    /// Button + popover instead of SwiftUI's `Menu` because macOS
    /// strips the custom backdrop, internal hairline, and chevron from
    /// a Menu's label (`Menu { } label: { … }` only renders the first
    /// leading element of a complex label, regardless of menuStyle).
    @State private var menuPresented: Bool = false

    /// Passive variant — the icon-pill is chrome. Existing call sites use
    /// this init unchanged. `MenuContent` is bound to `EmptyView` so the
    /// body's type-equality check skips the Menu wrapper.
    init(
        title: String,
        symbolName: String,
        accessor: String?,
        helpText: String,
        alignment: HorizontalAlignment = .leading,
        horizontalPadding: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) where MenuContent == EmptyView {
        self.title = title
        self.symbolName = symbolName
        self.accessor = accessor
        self.helpText = helpText
        self.alignment = alignment
        self.horizontalPadding = horizontalPadding
        self.useOverflowFlow = false
        self.menuContent = { EmptyView() }
        self.content = content
    }

    /// Menu variant — the icon-pill becomes an NSPopUpButton-shaped pull
    /// down. Pass `useOverflowFlow: true` to switch the chip strip to the
    /// word→icon→folded `OverflowChipFlowLayout` (the section's chips
    /// must use `AdaptiveChip` for that to work).
    init(
        title: String,
        symbolName: String,
        accessor: String?,
        helpText: String,
        alignment: HorizontalAlignment = .leading,
        horizontalPadding: CGFloat = 12,
        hasOverflow _: Bool,
        useOverflowFlow: Bool = false,
        @ViewBuilder menu: @escaping () -> MenuContent,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.symbolName = symbolName
        self.accessor = accessor
        self.helpText = helpText
        self.alignment = alignment
        self.horizontalPadding = horizontalPadding
        self.useOverflowFlow = useOverflowFlow
        self.menuContent = menu
        self.content = content
    }

    var body: some View {
        let effectiveHorizontalPadding = compactLayout
            ? min(horizontalPadding, 8)
            : horizontalPadding

        VStack(alignment: alignment, spacing: 6) {
            header

            HStack(spacing: 4) {
                if useOverflowFlow {
                    // Curated sections: chips collapse word → icon → folded.
                    OverflowChipFlowLayout(spacing: 4, hiddenCount: $hiddenCount) {
                        content()
                    }
                } else {
                    // Passive sections (Moments / Voices / Intents / Frame /
                    // View) — a single composite control. ChipFlowLayout's
                    // single-subview pass-through behaviour is fine here;
                    // hiddenCount stays 0 because every subview fits.
                    ChipFlowLayout(spacing: 4, hiddenCount: $hiddenCount) {
                        content()
                    }
                }
            }
        }
        .padding(.horizontal, effectiveHorizontalPadding)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityFullLabel)
        .accessibilityHint(helpText)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            iconPill
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
            if let accessor, showsAccessors {
                Text(accessor.uppercased())
                    .font(.system(size: 9))
                    .tracking(1.0)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private var iconPill: some View {
        if MenuContent.self == EmptyView.self {
            passivePill
        } else {
            Button {
                menuPresented.toggle()
            } label: {
                menuPill
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: $menuPresented,
                arrowEdge: .bottom
            ) {
                // Each call site supplies its own `MenuPopoverContent`
                // (header + checkbox rows + optional footer); we don't
                // wrap it here so the popover chrome stays exactly as
                // drawn in the design preview.
                menuContent()
            }
        }
    }

    private var passivePill: some View {
        Image(systemName: symbolName)
            .font(.system(size: 12))
            .foregroundStyle(OhiaColors.iconPillForeground)
            .frame(width: 22, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OhiaColors.iconPillBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 0.5)
            }
    }

    private var menuPill: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.iconPillForeground)
            // Internal hairline at ~0.20 alpha — distinctly stronger
            // than the pill's outer border, matching the HTML preview's
            // NSPopUpButton-shape vocabulary so the chevron reads as a
            // separate affordance rather than melting into the pill.
            Rectangle()
                .fill(OhiaColors.surface(0.20))
                .frame(width: 1, height: 12)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(OhiaColors.iconPillForeground)
                .opacity(0.85)
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(OhiaColors.iconPillBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.surface(0.18), lineWidth: 0.5)
        }
    }

    private var accessibilityFullLabel: String {
        if let accessor { return "\(title), \(accessor)" }
        return title
    }
}
