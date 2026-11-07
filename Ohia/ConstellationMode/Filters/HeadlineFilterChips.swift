import SwiftUI
import OhiaCore

/// Three-chip strip for the Action section: Reply + Confirm + Resolve.
/// Each chip shares the same tri-state language: grey shows both states,
/// yellow shows mail still needing the action, and red excludes mail where
/// the action is complete.
///
/// Mirrors `MessageTypeFilterChips` in shape: `AdaptiveChip` per chip so
/// `OverflowChipFlowLayout` can collapse word→icon→folded as the bar
/// narrows; the icon-mode tooltip prefixes the description with the full
/// label so the collapsed control remains identifiable.
extension HeadlineToggle {
    var actionDisplayLabel: String {
        switch self {
        case .actionable: return "Reply"
        case .confirm:    return "Confirm"
        case .resolved:   return "Resolve"
        }
    }
}

enum ActionChipDisplayPolicy {
    nonisolated static func displayed(
        configured: Set<HeadlineToggle>,
        lens: FrameKey
    ) -> Set<HeadlineToggle> {
        lens.spatialLens == .frontPage
            ? Set(HeadlineToggle.allCases)
            : configured
    }
}

public struct HeadlineFilterChips: View {
    @Binding public var replyNeededCriterion: AttentionFilterCriterion
    @Binding public var confirmationNeededCriterion: AttentionFilterCriterion
    @Binding public var resolvedCriterion: AttentionFilterCriterion
    /// Subset of `HeadlineToggle.allCases` the user has chosen to render
    /// in the bar. Owned by `ConstellationTopBar` (persisted via
    /// @AppStorage). Cases not in this set are absent from the bar but
    /// still listed (unchecked) in the section's icon-pulldown menu.
    public let displayed: Set<HeadlineToggle>

    public init(
        replyNeededCriterion: Binding<AttentionFilterCriterion>,
        confirmationNeededCriterion: Binding<AttentionFilterCriterion>,
        resolvedCriterion: Binding<AttentionFilterCriterion>,
        displayed: Set<HeadlineToggle>
    ) {
        _replyNeededCriterion = replyNeededCriterion
        _confirmationNeededCriterion = confirmationNeededCriterion
        _resolvedCriterion = resolvedCriterion
        self.displayed = displayed
    }

    public var body: some View {
        // Stable left-to-right order matches `HeadlineToggle.allCases`
        // (actionable, confirm, resolved). Each chip renders only when it's in the
        // displayed set.
        ForEach(HeadlineToggle.allCases.filter { displayed.contains($0) }, id: \.self) { toggle in
            adaptiveChip(for: toggle)
        }
    }

    @ViewBuilder
    private func adaptiveChip(for toggle: HeadlineToggle) -> some View {
        let label = toggle.actionDisplayLabel
        let criterion = criterionBinding(for: toggle).wrappedValue
        let isActive = criterion.isActive
        let wordWidth = label.chipWordWidth(bold: isActive)
        Button(action: { advanceCriterion(for: toggle) }) {
            AdaptiveChip(
                wordWidth: wordWidth,
                iconWidth: 26,
                isPressed: isActive,
                tooltipLabel: label,
                tooltipDescription: helpText(for: toggle, criterion: criterion),
                word: {
                    criterionChipLabel(
                        text: label,
                        criterion: criterion
                    )
                },
                icon: {
                    criterionChipIcon(
                        systemName: ToggleIconography.symbolName(for: toggle),
                        criterion: criterion
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .chipMetrics(wordWidth: wordWidth, iconWidth: 26, isPressed: isActive)
    }

    private func criterionBinding(for toggle: HeadlineToggle) -> Binding<AttentionFilterCriterion> {
        switch toggle {
        case .actionable: return $replyNeededCriterion
        case .confirm:    return $confirmationNeededCriterion
        case .resolved:   return $resolvedCriterion
        }
    }

    private func advanceCriterion(for toggle: HeadlineToggle) {
        let binding = criterionBinding(for: toggle)
        switch binding.wrappedValue {
        case .any:
            binding.wrappedValue = .required
        case .required:
            binding.wrappedValue = .excluded
        case .excluded:
            binding.wrappedValue = .any
        }
    }

    private func helpText(
        for toggle: HeadlineToggle,
        criterion: AttentionFilterCriterion
    ) -> String {
        switch toggle {
        case .actionable:
            switch criterion {
            case .any:
                return "Showing all mail regardless of reply state. Click to show only mail that needs a reply"
            case .required:
                return "Showing only mail that needs a reply. Click to exclude mail already replied to"
            case .excluded:
                return "Excluding mail already replied to. Click to show all mail regardless of reply state"
            }
        case .confirm:
            switch criterion {
            case .any:
                return "Showing all mail regardless of confirmation state. Click to show only mail that needs confirmation"
            case .required:
                return "Showing only mail that needs confirmation. Click to exclude mail already confirmed"
            case .excluded:
                return "Excluding mail already confirmed. Click to show all mail regardless of confirmation state"
            }
        case .resolved:
            switch criterion {
            case .any:
                return "Showing all mail regardless of resolution state. Click to show only mail that needs resolution"
            case .required:
                return "Showing only mail that needs resolution. Click to exclude resolved mail"
            case .excluded:
                return "Excluding resolved mail. Click to show all mail regardless of resolution state"
            }
        }
    }

    private func criterionChipLabel(
        text: String,
        criterion: AttentionFilterCriterion
    ) -> some View {
        Text(text)
            .font(.system(size: 11, weight: criterion.isActive ? .semibold : .regular))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground(for: criterion))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(background(for: criterion))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(border(for: criterion), lineWidth: 1)
            }
    }

    private func criterionChipIcon(
        systemName: String,
        criterion: AttentionFilterCriterion
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: criterion.isActive ? .semibold : .regular))
                .foregroundStyle(foreground(for: criterion))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(background(for: criterion))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(border(for: criterion), lineWidth: 1)
                }

            if criterion == .excluded {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 26, height: 22)
    }

    private func foreground(for criterion: AttentionFilterCriterion) -> Color {
        switch criterion {
        case .any:
            return OhiaColors.textSecondary
        case .required:
            return OhiaColors.chipActiveForeground
        case .excluded:
            return OhiaColors.ohiaRed
        }
    }

    private func background(for criterion: AttentionFilterCriterion) -> Color {
        switch criterion {
        case .any, .excluded:
            return OhiaColors.chipRestBackground
        case .required:
            return OhiaColors.chipActiveBackground
        }
    }

    private func border(for criterion: AttentionFilterCriterion) -> Color {
        switch criterion {
        case .any:
            return OhiaColors.chipRestBorder
        case .required:
            return OhiaColors.chipActiveBorder
        case .excluded:
            return OhiaColors.ohiaRed.opacity(0.65)
        }
    }
}

enum ResolvedActionFilterPolicy {
    nonisolated static func criterion(
        stored: AttentionFilterCriterion?,
        lens: FrameKey
    ) -> AttentionFilterCriterion {
        stored ?? (lens.spatialLens == .frontPage ? .excluded : .any)
    }
}
