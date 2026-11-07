import AppKit
import SwiftUI
import OhiaCore

struct ComposeFromPicker: View {
    let identities: [Identity]
    @Binding var selected: Identity?
    let showsLabel: Bool
    let showsPrimaryTagInSelection: Bool

    init(
        identities: [Identity],
        selected: Binding<Identity?>,
        showsLabel: Bool = true,
        showsPrimaryTagInSelection: Bool = true
    ) {
        self.identities = identities
        self._selected = selected
        self.showsLabel = showsLabel
        self.showsPrimaryTagInSelection = showsPrimaryTagInSelection
    }

    var body: some View {
        if identities.count <= 1 {
            if let only = identities.first {
                row(label: "FROM") {
                    Text(renderLabel(only, includesPrimaryTag: showsPrimaryTagInSelection))
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        } else {
            row(label: "FROM") {
                // `Picker(.menu)` backs onto NSPopUpButton on macOS, whose
                // displayed title is drawn by AppKit's own cell and doesn't
                // reliably honor SwiftUI's `.font()`. A `Menu` with a fully
                // custom label renders the current value as a plain `Text`,
                // so the font actually applies.
                let currentIdentity = selected ?? identities.first
                Menu {
                    ForEach(identities, id: \.id) { ident in
                        Button {
                            selected = ident
                        } label: {
                            addressMenuItem(
                                name: renderLabel(ident),
                                isSelected: currentIdentity?.id == ident.id
                            )
                        }
                    }
                } label: {
                    Text(currentIdentity.map {
                        renderLabel($0, includesPrimaryTag: showsPrimaryTagInSelection)
                    } ?? "")
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.leading, 40)
                .padding(.trailing, 28)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(OhiaColors.iconPillBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                )
                .overlay(alignment: .leading) {
                    Image(systemName: "envelope")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OhiaColors.ohiaYellow)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OhiaColors.ohiaYellow)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("From")
                .accessibilityValue(currentIdentity.map { renderLabel($0) } ?? "")
            }
        }
    }

    private func renderLabel(
        _ ident: Identity,
        includesPrimaryTag: Bool = true
    ) -> String {
        let primaryTag = includesPrimaryTag && ident.isPrimary ? " (primary)" : ""
        if let name = ident.displayName, !name.isEmpty {
            return "\(name) <\(ident.address)>\(primaryTag)"
        }
        return "\(ident.address)\(primaryTag)"
    }

    @ViewBuilder
    private func addressMenuItem(name: String, isSelected: Bool) -> some View {
        if isSelected {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: Self.yellowCheckmarkImage)
            }
        } else {
            Text(name)
        }
    }

    private static let yellowCheckmarkImage: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let checkmark = NSBezierPath()
            checkmark.move(to: NSPoint(x: 1.5, y: 6.0))
            checkmark.line(to: NSPoint(x: 4.5, y: 3.0))
            checkmark.line(to: NSPoint(x: 10.5, y: 10.0))
            checkmark.lineWidth = 1.6
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            NSColor(
                srgbRed: 248 / 255,
                green: 248 / 255,
                blue: 56 / 255,
                alpha: 1
            ).setStroke()
            checkmark.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }()

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabel {
                Text(label)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .textCase(.uppercase)
            }
            content()
        }
    }
}
