import SwiftUI
import OhiaCore

/// Compact account identity mark shared by Front Page cards and the reader
/// masthead. The hue is the same `AccountColorPalette` value used by the
/// Constellation account chips and message nodes.
struct FrontPageAccountIndicator: View {
    let accountName: String
    let accountEmailAddress: String
    let accountColor: AccountColor
    var size: CGFloat = 11

    private var resolvedAccountName: String {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown account" : trimmed
    }

    private var glyph: AccountIcon.Glyph {
        AccountIcon.style(forEmail: accountEmailAddress).glyph
    }

    var body: some View {
        AccountGlyphImage(glyph: glyph, size: size)
            .foregroundStyle(accountColor.swiftUIColor)
            .frame(width: size + 2, height: size + 2)
            .help("Account: \(resolvedAccountName)")
            .accessibilityLabel(Text("Account \(resolvedAccountName)"))
    }
}
