import SwiftUI

/// Body of the menu-pill popover. Renders the design preview's
/// checkbox-row vocabulary instead of the macOS system menu rows that
/// SwiftUI's `Menu` would default to:
///
///   ┌──────────────────────────────┐
///   │ DISPLAY AS TOGGLES           │  ← `headerLabel`, uppercase tracked
///   │ ☑ [icon]  Finance            │  ← MenuRow (checked, with SF symbol)
///   │ ☑ [icon]  Receipt            │
///   │ ☐ [icon]  Promo              │
///   │ ──────────────────────────── │
///   │ Display only — checking …    │  ← optional `footer` explainer
///   └──────────────────────────────┘
///
/// Lives in the app target because it composes the existing
/// `OhiaColors` tokens; does not depend on any specific item type so
/// every section's pulldown reuses one widget.
struct MenuPopoverContent<Content: View>: View {
    let headerLabel: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerLabel)
                .font(.system(size: 9.5))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(OhiaColors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            content()
            if let footer {
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(height: 1)
                    .padding(.top, 4)
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 4)
        .frame(width: 220)
    }
}

/// One row inside a `MenuPopoverContent`. Mirrors the design's `.mp-row`
/// HTML — checkbox + icon + name, full-width hover affordance, click
/// anywhere on the row toggles `isChecked`. The icon is generic over
/// `View` so each section can pass whatever shape fits — an SF Symbol
/// for Forms / Traces / Layers, a brand-glyph asset for accounts.
struct MenuRow<Icon: View>: View {
    let name: String
    let isChecked: Bool
    let action: () -> Void
    let iconWidth: CGFloat
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                checkbox
                icon()
                    .frame(width: iconWidth, height: 16)
                Text(name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OhiaColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Convenience initializer for the common SF-symbol case so call
    /// sites that just want a system symbol don't have to spell out the
    /// closure.
    init(
        name: String,
        symbolName: String,
        isChecked: Bool,
        action: @escaping () -> Void
    ) where Icon == AnyView {
        self.name = name
        self.isChecked = isChecked
        self.action = action
        self.iconWidth = 16
        self.icon = {
            AnyView(
                Image(systemName: symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.iconPillForeground)
            )
        }
    }

    /// Generic initializer for callers passing a custom icon view (e.g.
    /// `AccountGlyphImage` for the Territory popover, or a paired-symbol
    /// glyph for Traces co-dependent pair rows). `iconWidth` widens the
    /// icon column when a single 16pt slot is too narrow — pair rows pass
    /// 26pt so two SF symbols sit side-by-side without crowding.
    init(
        name: String,
        isChecked: Bool,
        iconWidth: CGFloat = 16,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.name = name
        self.isChecked = isChecked
        self.iconWidth = iconWidth
        self.action = action
        self.icon = icon
    }

    @ViewBuilder
    private var checkbox: some View {
        MenuRowCheckbox(isChecked: isChecked)
    }
}

/// Square chip-accent checkbox used by every menu row variant. Extracted so
/// `MenuRow` and `MenuPairRow` paint identical chrome without one type
/// having to expose its private checkbox view.
struct MenuRowCheckbox: View {
    let isChecked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isChecked
                    ? OhiaColors.chipActiveForeground
                    : OhiaColors.surface(0.06))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    isChecked
                        ? OhiaColors.chipActiveForeground
                        : OhiaColors.surface(0.35),
                    lineWidth: 1
                )
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(OhiaColors.toolbarBackground)
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// Two-toggle variant of `MenuRow` for co-dependent trace pairs. Renders
/// each half's SF symbol immediately before its label so the row reads as
/// "icon word & icon word" instead of clustering both glyphs at the start
/// of the line. Single click toggles both halves through `action` (the
/// caller writes the pair-as-unit logic).
struct MenuPairRow: View {
    let leftSymbol: String
    let leftLabel: String
    let rightSymbol: String
    let rightLabel: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                MenuRowCheckbox(isChecked: isChecked)
                HStack(spacing: 5) {
                    halfIcon(leftSymbol)
                    halfLabel(leftLabel)
                    Text("/")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OhiaColors.textTertiary)
                    halfIcon(rightSymbol)
                    halfLabel(rightLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func halfIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(OhiaColors.iconPillForeground)
            .frame(width: 16, height: 16)
    }

    private func halfLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(OhiaColors.textPrimary)
    }
}
