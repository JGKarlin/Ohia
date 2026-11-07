import SwiftUI
import OhiaCore

public struct AccountFilterChips: View {
    @Binding public var accountIds: Set<UUID>?
    public let accounts: [Account]
    /// Subset of `accounts` IDs the user has chosen to render in the bar.
    /// Owned by `ConstellationTopBar` (persisted via @AppStorage as the
    /// inverse "hidden" set, so newly-added accounts default to displayed).
    /// Cases not in this set are absent from the bar but still listed
    /// (unchecked) in the section's icon-pulldown menu.
    public let displayed: Set<UUID>
    /// Per-account total message counts shown in parens after the display
    /// name. Intentionally unaffected by `filter.accountIds` (or any other
    /// filter) — the chip reports the account's overall population so the
    /// user can see the magnitude even when the account is toggled off.
    public let accountTotals: [UUID: Int]

    public init(
        accountIds: Binding<Set<UUID>?>,
        accounts: [Account],
        displayed: Set<UUID>,
        accountTotals: [UUID: Int] = [:]
    ) {
        _accountIds = accountIds
        self.accounts = accounts
        self.displayed = displayed
        self.accountTotals = accountTotals
    }

    public var body: some View {
        ForEach(accounts.filter { displayed.contains($0.id) }) { acct in
            let isOn = accountIds?.contains(acct.id) ?? true
            let style = AccountIcon.style(for: acct)
            let label = labelText(for: acct)
            // Word width = label text (11pt) + chrome. Chrome breakdown:
            //   8 padding + 12 glyph + 5 gap + … + 8 padding
            // = 33pt. `chipWordWidth` already adds 16pt of its own
            // padding chrome; the additional Account-chip-specific
            // chrome on top is 33 − 16 = 17pt. Round up to 20 so a
            // semibold-pressed name with a wider glyph never truncates.
            let wordWidth =
                label.chipWordWidth(bold: isOn)
                + 20
            Button(action: { toggle(acct.id) }) {
                AdaptiveChip(
                    wordWidth: wordWidth,
                    isPressed: isOn,
                    tooltipLabel: acct.displayName,
                    tooltipDescription: "Messages from this account",
                    word: { wordChip(account: acct, style: style, isOn: isOn, label: label) },
                    icon: { iconChip(account: acct, style: style, isOn: isOn) }
                )
            }
            .buttonStyle(.plain)
            .chipMetrics(wordWidth: wordWidth, isPressed: isOn)
        }
    }

    /// Display name plus the account's overall message total, e.g.
    /// `"Gmail (1,234)"`. The suffix is suppressed when no totals have been
    /// computed yet (cold launch) so the chip never shows a misleading
    /// `(0)` before the first snapshot lands.
    private func labelText(for account: Account) -> String {
        guard !accountTotals.isEmpty else { return account.displayName }
        let count = accountTotals[account.id] ?? 0
        return "\(account.displayName) (\(count.formatted(.number)))"
    }

    /// Word-mode chip: brand glyph + display name. Matches the universal
    /// chip vocabulary — height 22, corner 4, horizontal padding 8, 11pt
    /// text — so accounts read as the same kind of chip as Forms / Traces
    /// / Layers. The chip's own accent border and bolded label already
    /// carry the on/off cue, so no extra square mark is rendered.
    @ViewBuilder
    private func wordChip(
        account: Account,
        style: AccountIcon.Style,
        isOn: Bool,
        label: String
    ) -> some View {
        HStack(spacing: 5) {
            // Brand glyph rendered in the account's AccountColor (its
            // stellar identity in the Constellation scene) when active so
            // the toolbar carries the same per-account hue users see in
            // the spatial view; the text stays on the chip's normal
            // active-foreground so the account name reads cleanly.
            AccountGlyphImage(glyph: style.glyph, size: 11)
                .foregroundStyle(isOn ? account.accountColor.swiftUIColor : .secondary)
            Text(label)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? OhiaColors.chipActiveForeground : .secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isOn ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                    lineWidth: 1
                )
        }
    }

    /// Icon-mode chip: just the brand glyph, sized to fit the standard
    /// 24pt icon-chip frame. The provider's identity is the glyph itself
    /// — no SF Symbol substitution is needed for accounts.
    @ViewBuilder
    private func iconChip(
        account: Account,
        style: AccountIcon.Style,
        isOn: Bool
    ) -> some View {
        AccountGlyphImage(glyph: style.glyph, size: 12)
            .foregroundStyle(isOn
                ? account.accountColor.swiftUIColor
                : OhiaColors.textSecondary)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn
                        ? OhiaColors.chipActiveBackground
                        : OhiaColors.chipRestBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isOn
                        ? OhiaColors.chipActiveBorder
                        : OhiaColors.chipRestBorder, lineWidth: 1)
            }
    }

    private func toggle(_ id: UUID) {
        var active = accountIds ?? Set(accounts.map(\.id))
        if active.contains(id) { active.remove(id) } else { active.insert(id) }
        // nil means "all" — collapse to nil when user re-enables every account.
        accountIds = active == Set(accounts.map(\.id)) ? nil : active
    }
}
