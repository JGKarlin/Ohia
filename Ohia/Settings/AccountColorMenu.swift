// Ohia/Settings/AccountColorMenu.swift
// Per-account color picker shown in Settings → Accounts. Renders the
// account's stellar swatch and a Menu of the full palette; entries
// already used by other accounts are disabled so two accounts cannot
// share the same color. Selecting a color updates `Account.colorIndex`
// and posts `.ohiaAccountColorChanged` so the constellation invalidates
// its cached snapshot.

import AppKit
import SwiftUI
import SwiftData
import OhiaCore

struct AccountColorMenu: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Query private var allAccounts: [Account]

    private var currentColor: AccountColor {
        AccountColorPalette.color(forIndex: account.colorIndex)
    }

    /// Indices already taken by *other* accounts. The current account's own
    /// index is allowed (so the menu shows it as the selected entry).
    private var indicesUsedByOthers: Set<Int> {
        Set(allAccounts
            .filter { $0.id != account.id }
            .compactMap { $0.colorIndex })
    }

    var body: some View {
        HStack(spacing: 8) {
            swatch(for: currentColor)
            Menu {
                ForEach(AccountColorPalette.all) { color in
                    let inUse = indicesUsedByOthers.contains(color.id)
                    let isSelected = account.colorIndex == color.id
                    Button {
                        select(color)
                    } label: {
                        HStack(spacing: 8) {
                            swatch(for: color)
                            Text(color.name)
                            if isSelected {
                                Image(systemName: "checkmark")
                            }
                            if inUse && !isSelected {
                                Text("· in use")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(inUse && !isSelected)
                }
            } label: {
                Text(currentColor.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .help("Color used to render this account's nodes in the Constellation view.")
    }

    @ViewBuilder
    private func swatch(for color: AccountColor) -> some View {
        // SwiftUI Menu bridges to NSMenuItem; SF Symbol images get treated as
        // template images and coerced to the menu's text color, which strips
        // any `.foregroundStyle` tint. A non-template NSImage with the color
        // baked in survives that bridge intact, so we draw the swatch into
        // an NSImage and hand SwiftUI an Image(nsImage:) instead.
        Image(nsImage: Self.swatchImage(for: color))
    }

    private static func swatchImage(for color: AccountColor) -> NSImage {
        let rgb = AccountColorPalette.rgb(for: color, brightness: 1.0)
        let nsColor = NSColor(
            srgbRed: CGFloat(rgb.x),
            green: CGFloat(rgb.y),
            blue: CGFloat(rgb.z),
            alpha: 1.0
        )
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func select(_ color: AccountColor) {
        guard account.colorIndex != color.id else { return }
        account.colorIndex = color.id
        try? modelContext.save()
        NotificationCenter.default.post(
            name: .ohiaAccountColorChanged,
            object: account.id
        )
    }
}

