import SwiftUI
import AppKit
import OhiaCore

/// Provider-specific glyph + brand tint for an `Account`. SF Symbols ships
/// no brand-recognizable icons (Gmail / Outlook / Yahoo are not in Apple's
/// catalog), so for known providers we use Pictogrammers' Material Design
/// Icons (Apache 2.0) bundled in `Assets.xcassets/Brands/`. Each MDI SVG
/// is a single template-rendered glyph; we tint at the call site to apply
/// each brand's signature color.
///
/// Domain detection mirrors `MailProviderRegistry` from OhiaMail rather
/// than importing it — this view-layer helper has no business pulling in
/// the mail-transport package, and the domain list is short enough that
/// duplication is cheaper than the cross-target wiring.
///
/// Trademark posture: glyphs are licensed under Apache 2.0 from MDI; their
/// underlying brands remain trademarked by their respective owners. The
/// chip identifies the user's authenticated account (nominative use); see
/// the discussion thread on this file's commit history for the risk
/// analysis. If an owner ever objects, swap that one entry to `.generic`.
public enum AccountIcon {
    public enum Glyph {
        /// Asset-catalog image name from `Brands/`. Rendered as `.template`
        /// so SwiftUI's `foregroundStyle` applies the brand tint.
        case asset(String)
        /// SF Symbol name used when no bundled provider glyph applies.
        case sfSymbol(String)
    }

    public struct Style {
        public let glyph: Glyph
        public let tint: Color
    }

    public static func style(for account: Account) -> Style {
        // A recognized provider brand is the most useful differentiator when
        // many accounts are listed side-by-side.
        return style(forEmail: account.emailAddress)
    }

    /// Variant for callers that don't yet have a persisted `Account` —
    /// onboarding works with `DiscoveredAccount` and manual-entry strings,
    /// but the brand cue should be identical to the post-onboarding UI.
    public static func style(forEmail email: String) -> Style {
        if let branded = providerStyle(forEmail: email) {
            return branded
        }
        // Unrecognized domain — user-entered or custom IMAP. Single
        // generic glyph, gray tint.
        return Self.generic
    }

    // MARK: - Brand catalog

    private static let gmail = Style(
        glyph: .asset("gmail"),
        tint: Color(red: 234/255, green: 67/255, blue: 53/255)        // #EA4335
    )
    private static let outlook = Style(
        glyph: .asset("outlook"),
        tint: Color(red: 0/255,   green: 120/255, blue: 212/255)      // #0078D4
    )
    private static let icloud = Style(
        glyph: .asset("icloud"),
        tint: Color(red: 0/255,   green: 122/255, blue: 255/255)      // Apple system blue
    )
    private static let yahoo = Style(
        glyph: .asset("yahoo"),
        tint: Color(red: 96/255,  green: 1/255,   blue: 210/255)      // #6001D2
    )
    private static let generic = Style(
        glyph: .asset("email-generic"),
        tint: .gray
    )

    private static let providers: [String: Style] = [
        "gmail.com":      gmail,
        "googlemail.com": gmail,
        "icloud.com":     icloud,
        "me.com":         icloud,
        "mac.com":        icloud,
        "outlook.com":    outlook,
        "hotmail.com":    outlook,
        "live.com":       outlook,
        "msn.com":        outlook,
        "yahoo.com":      yahoo,
        "ymail.com":      yahoo,
    ]

    private static func providerStyle(forEmail email: String) -> Style? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...]).lowercased()
        return providers[domain]
    }
}

/// SwiftUI bridge for `AccountColor`. Renders the palette entry's
/// hue/saturation at full brightness so brand glyphs in the toolbar and
/// menus carry the account's stellar identity directly. Mirrors the
/// `srgbRed/green/blue` swatch path used by `AccountColorMenu`.
public extension AccountColor {
    var swiftUIColor: Color {
        let rgb = AccountColorPalette.rgb(for: self, brightness: 1.0)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// Theme-adaptive constellation tint for this account hue, matching the
    /// Meaning-lens node treatment (`AccountColorPalette.meaningLensRGB`):
    /// bright/pale against the dark backdrop, deeper + more saturated against
    /// the light one — so even the palest palette entries (Sirius White,
    /// Procyon Pale) stay legible on a light field. Used to colour the
    /// send-to-Composer comet across every lens.
    var constellationTint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil
            let rgb = AccountColorPalette.meaningLensRGB(
                forAccountColorIndex: id,
                isDarkAppearance: isDark
            )
            return NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        })
    }
}

public extension Account {
    /// Convenience accessor — resolves this account's stored `colorIndex`
    /// to its `AccountColor` palette entry. Out-of-range or nil indices
    /// fall back to the palette default.
    var accountColor: AccountColor {
        AccountColorPalette.color(forIndex: colorIndex)
    }
}

/// View helper — renders an `AccountIcon.Glyph` with a single call site,
/// mapping the asset / SF Symbol cases to the right SwiftUI `Image`. Keeps
/// the chip's body free of `switch`/`case` noise and ensures consistent
/// rendering options (template intent for assets, plain for SF Symbols
/// which Apple already templatizes).
public struct AccountGlyphImage: View {
    public let glyph: AccountIcon.Glyph
    public let size: CGFloat

    public init(glyph: AccountIcon.Glyph, size: CGFloat = 12) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        switch glyph {
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        }
    }
}
