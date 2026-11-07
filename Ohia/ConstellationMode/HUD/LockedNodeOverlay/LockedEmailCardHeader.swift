import SwiftUI
import OhiaCore

struct LockedEmailCardHeader: View {
    let content: LockedEmailCardContent
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onRelease: () -> Void
    /// Meanings lens exposes release at the scene corner; other lenses keep
    /// the header xmark on the top chrome row.
    var showsReleaseButton: Bool = true
    /// Meanings lens omits the short accent rule preceding the direction pill.
    var showsHeaderAccentRule: Bool = true
    /// Called with the complete canonical classification and independent
    /// custom-key overlay after any picker edit.
    let onClassificationChanged: (MailClassification?, Set<String>) -> Void
    /// Live custom-category catalog so the picker can list user-defined
    /// categories (with collecting progress) alongside shared purposes.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []
    /// Whether the locked email's sender is currently pinned as an
    /// "always major" correspondent. Drives the right-click context-menu
    /// label and checkmark on the sender row.
    let isSenderPinned: Bool
    /// Flip the sender's pinned state. The host overlay translates this
    /// into a SwiftData insert / delete of a `PinnedCorrespondent` row.
    let onToggleSenderPinned: () -> Void
    @Bindable var translation: EmailTranslationModel
    let onTranslate: () -> Void

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var categoryPickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                annotationMark
                Spacer(minLength: 0)
                Button(action: onToggleCollapse) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OhiaColors.textSecondary)
                .help(collapsed ? "Expand locked email" : "Collapse locked email")
                .accessibilityLabel(collapsed ? "Expand locked email" : "Collapse locked email")

                if showsReleaseButton {
                    Button(action: onRelease) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .help("Release lock")
                    .accessibilityLabel("Release lock")
                }
            }

            Text(content.displaySubject)
                .font(readingTextSize.font(base: 14, weight: .semibold, maximumScale: 1.35))
                .foregroundStyle(
                    content.row.subject.isEmpty ? OhiaColors.textTertiary : OhiaColors.textPrimary
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !content.fromLine.isEmpty {
                Text(content.fromLine)
                    .font(readingTextSize.font(base: 12, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu {
                        Button(
                            isSenderPinned ? "Unpin correspondent" : "Pin correspondent",
                            systemImage: isSenderPinned ? "pin.slash" : "pin",
                            action: onToggleSenderPinned
                        )
                    }
            }

            ForEach(content.recipientHeaderLines) { recipientLine in
                Text(recipientLine.attributedText)
                    .font(readingTextSize.font(base: 12, maximumScale: 1.35))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(recipientLine.plainText)
            }

            statusStrip
            categoryActionRow
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var annotationMark: some View {
        HStack(spacing: 7) {
            if showsHeaderAccentRule {
                Rectangle()
                    .fill(OhiaColors.chipActiveBorder)
                    .frame(width: 18, height: 1)
            }
            HStack(spacing: 6) {
                Image(systemName: content.directionSymbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .accessibilityHidden(true)
                Text(content.directionLabel)
                    .font(OhiaTypography.coordReadout)
                    .tracking(0.6)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OhiaColors.annotationMarkBackground)
            )
        }
    }

    // MARK: - Load remote images

    /// Sender address used to key the per-sender remote-image allowlist.
    /// Derived once on `content` so the header chip and the body's
    /// image-loading can't drift apart (see `remoteImageSenderAddress`).
    private var senderAddress: String? {
        content.remoteImageSenderAddress
    }

    /// Whether this sender's remote images already load. Reading the shared
    /// allowlist here registers observation, so trusting the sender both hides
    /// this chip and live-loads the body's images in the same transaction.
    private var loadsRemoteImages: Bool {
        RemoteImageSenderAllowlist.shared.isAllowed(senderAddress)
    }

    /// Show the unblock chip only for an untrusted sender whose loaded HTML
    /// body actually references blocked remote images. Placing it on the header
    /// (rather than over the body) keeps it from reading as part of the email.
    /// Hidden while the body is collapsed — the chip would otherwise imply
    /// blocked images in a body the user can't see.
    private var showsLoadRemoteImagesChip: Bool {
        guard !collapsed else { return false }
        guard !loadsRemoteImages else { return false }
        guard case .loaded(let body) = content.bodyState,
              let htmlDocument = body.htmlDocument,
              !body.isEmpty else { return false }
        return RemoteImageBlocking.containsRemoteImages(in: htmlDocument.html)
    }

    /// Emblem chip that trusts the sender's remote images and reloads the body
    /// with them. Sits at the header's bottom-right, trailing the category row.
    private func loadRemoteImagesChip(labelVisibility: EmailTranslationControl.LabelVisibility) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                RemoteImageSenderAllowlist.shared.allow(senderAddress)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                if labelVisibility == .textAndIcon {
                    Text("Load images")
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.emblem)
        .fixedSize(horizontal: true, vertical: false)
        .help("Load remote images and trust this sender")
        .accessibilityLabel("Load remote images from this sender")
        .transition(.opacity)
    }

    // MARK: - Header action row

    private var showsTranslationControl: Bool {
        !collapsed && translation.canOffer
    }

    private var showsHeaderActionStrip: Bool {
        showsLoadRemoteImagesChip || showsTranslationControl
    }

    private var categoryActionRow: some View {
        ViewThatFits(in: .horizontal) {
            categoryActionRow(labelVisibility: .textAndIcon)
            categoryActionRow(labelVisibility: .iconOnly)
        }
    }

    private func categoryActionRow(
        labelVisibility: EmailTranslationControl.LabelVisibility
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            classificationChip(customKeys: assignedCustomKeys)
            if showsHeaderActionStrip {
                Spacer(minLength: 8)
                headerActionStrip(labelVisibility: labelVisibility)
                    .layoutPriority(1)
            }
        }
    }

    private func headerActionStrip(
        labelVisibility: EmailTranslationControl.LabelVisibility
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if showsLoadRemoteImagesChip {
                loadRemoteImagesChip(labelVisibility: labelVisibility)
            }
            if showsTranslationControl {
                EmailTranslationControl(
                    model: translation,
                    mode: .pane,
                    labelVisibility: labelVisibility,
                    onTranslate: onTranslate
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusStrip: some View {
        MessageStatusMark(
            descriptor: content.statusDescriptor,
            size: 12,
            showsTextGloss: true,
            showsAmbientSharedEvidence: true,
            glossFont: .system(size: 10, weight: .semibold)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mirrors the toolbar's NSPopUpButton-shaped icon-pill (see
    /// `ToolbarSection.menuPill`) so the lock-overlay's classification pulldown
    /// reads as the same control vocabulary as the Forms / Traces / Layers
    /// pulldowns up in the top bar. The pill is the trigger only — every
    /// assigned category renders as its own `FilterChipLabel` to the right
    /// so a multi-category message ("work" + "receipt") shows both labels
    /// the way the toolbar's chip strip surfaces every displayed chip.
    /// Custom keys assigned to the message, restricted to the live catalog
    /// so tokens of removed categories never render as chips.
    private var assignedCustomKeys: Set<String> {
        content.customCategoryKeys.intersection(Set(customCategoryCatalog.map(\.key)))
    }

    private func classificationChip(customKeys: Set<String>) -> some View {
        HStack(spacing: 6) {
            Button {
                categoryPickerShown.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(content.classification == nil && customKeys.isEmpty ? "Set classification" : "Change classification")
            .accessibilityLabel(classificationAccessibilityLabel(customKeys: customKeys))
            .popover(isPresented: $categoryPickerShown, arrowEdge: .bottom) {
                categoryPicker
            }

            if content.classification == nil && customKeys.isEmpty {
                FilterChipLabel(text: "Unclassified", isOn: false)
            } else {
                if let purpose = content.purpose {
                    FilterChipLabel(text: purpose.displayLabel, isOn: true)
                }
                ForEach(customCategoryCatalog.filter { customKeys.contains($0.key) }) { descriptor in
                    FilterChipLabel(text: descriptor.displayName, isOn: true)
                }
            }
        }
    }

    private func classificationAccessibilityLabel(customKeys: Set<String>) -> String {
        guard content.classification != nil || customKeys.isEmpty == false else {
            return "Unclassified. Set classification."
        }
        var categoryLabels: [String] = []
        if let purpose = content.purpose { categoryLabels.append(purpose.displayLabel) }
        let customLabels = customCategoryCatalog
            .filter { customKeys.contains($0.key) }
            .map(\.displayName)
        return "Category: \((categoryLabels + customLabels).joined(separator: ", ")). Change."
    }

    /// Reuses `MenuPopoverContent` + `MenuRow` so the popover's header,
    /// fonts, checkbox glyph, and row paddings match every other curated
    /// pulldown in the constellation toolbar exactly. Each row toggles
    /// membership of its own category in the assigned set. User-defined
    /// categories follow the shared categories;
    /// toggling a collecting one tags this message as a training example
    /// and the row label shows progress toward activation.
    private var categoryPicker: some View {
        MenuPopoverContent(headerLabel: "Category") {
            ForEach(MailPurpose.allCases, id: \.self) { purpose in
                MenuRow(
                    name: purpose.displayLabel,
                    symbolName: ToggleIconography.symbolName(for: purpose),
                    isChecked: content.purpose == purpose,
                    action: {
                        let next = MailClassification.userAssigned(purpose: purpose)
                        onClassificationChanged(next, assignedCustomKeys)
                    }
                )
            }
            ForEach(customCategoryCatalog) { descriptor in
                MenuRow(
                    name: CustomCategoryStore.menuLabel(for: descriptor),
                    symbolName: ToggleIconography.customCategorySymbolName,
                    isChecked: assignedCustomKeys.contains(descriptor.key),
                    action: {
                        var nextCustom = assignedCustomKeys
                        if nextCustom.contains(descriptor.key) {
                            nextCustom.remove(descriptor.key)
                        } else {
                            nextCustom.insert(descriptor.key)
                        }
                        onClassificationChanged(content.classification, nextCustom)
                    }
                )
            }
        }
    }

}
