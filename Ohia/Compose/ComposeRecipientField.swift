// Ohia/Compose/ComposeRecipientField.swift
// Recipient input for the in-Composer compose surface: chip-based To/Cc/Bcc
// with autocomplete sourced from ingested correspondents (the WHO / Voices
// set). Type freely; commit on comma/Return, or pick a contact from the
// suggestion popover. Mirrors the chip vocabulary of `ComposeAddressField`
// and the autocomplete idiom of `CorrespondentFilterField`.

import SwiftUI
import OhiaCore

/// One autocomplete candidate, projected from a `Correspondent` row.
struct ComposeRecipientSuggestion: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case correspondent
        case list
    }

    let name: String
    let address: String
    let organization: String?
    let frequency: Int
    let lastSeen: Date?
    let kind: Kind

    var id: String { address }
    var displayTitle: String { name.isEmpty ? address : name }

    init(
        name: String,
        address: String,
        organization: String?,
        frequency: Int,
        lastSeen: Date?,
        kind: Kind = .correspondent
    ) {
        self.name = name
        self.address = address
        self.organization = organization
        self.frequency = frequency
        self.lastSeen = lastSeen
        self.kind = kind
    }
}

struct ComposeRecipientField: View {
    enum Kind: Equatable {
        case to, cc, bcc
        var label: String {
            switch self {
            case .to: "TO"
            case .cc: "CC"
            case .bcc: "BCC"
            }
        }
    }

    let kind: Kind
    @Binding var input: String
    let chips: [ComposeAddressEncoding.ParsedAddress]
    let invalidPieces: [String]
    let suggestions: [ComposeRecipientSuggestion]
    /// Addresses already present in any recipient field — filtered out of the
    /// suggestion list so the user can't add a duplicate.
    let alreadyAdded: Set<String>
    let onCommit: () -> Void
    let onRemove: (Int) -> Void
    let onSelect: (ComposeRecipientSuggestion) -> Void

    @State private var suppress = false
    @State private var highlightedId: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.label)
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
                .textCase(.uppercase)

            AddressFlowLayout(spacing: 4) {
                ForEach(chips, id: \.asciiAddress) { addr in
                    chipView(addr) {
                        if let i = chips.firstIndex(where: { $0.asciiAddress == addr.asciiAddress }) {
                            onRemove(i)
                        }
                    }
                }
                TextField("", text: $input, prompt: Text(chips.isEmpty ? "name@example.com" : "+ add"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .frame(minWidth: 140)
                    .focused($focused)
                    .onSubmit { acceptHighlightedOrCommit() }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onChange(of: input) { _, newValue in
                        suppress = false
                        highlightedId = nil
                        if newValue.contains(",") { onCommit() }
                    }
            }
            .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
                suggestionList
            }

            if !invalidPieces.isEmpty {
                Text(invalidPieces.joined(separator: ", "))
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.frameUrgencyHigh)
                    .underline()
            }
        }
    }

    // MARK: - Chips

    private func chipView(_ addr: ComposeAddressEncoding.ParsedAddress, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(addr.displayName.map { "\($0)" } ?? addr.asciiAddress)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .help(addr.asciiAddress)
            Button(action: onRemove) {
                Label("Remove \(addr.asciiAddress)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(OhiaColors.chipActiveBackground)
        .overlay(Capsule().strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1))
        .clipShape(Capsule())
    }

    // MARK: - Suggestions

    private var matching: [ComposeRecipientSuggestion] {
        let needle = input.normalizedForCorrespondentAutocomplete
        guard !needle.isEmpty else { return [] }
        return suggestions
            .filter { !alreadyAdded.contains($0.address.lowercased()) }
            .compactMap { suggestion -> (ComposeRecipientSuggestion, Int)? in
                let title = suggestion.displayTitle.normalizedForCorrespondentAutocomplete
                let value = suggestion.address.normalizedForCorrespondentAutocomplete
                let words = title.split(separator: " ") + value.split(separator: "@")
                let rank: Int
                if title.hasPrefix(needle) { rank = 0 }
                else if value.hasPrefix(needle) { rank = 1 }
                else if words.contains(where: { $0.hasPrefix(needle) }) { rank = 2 }
                else if title.contains(needle) || value.contains(needle) { rank = 3 }
                else { return nil }
                return (suggestion, rank)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.frequency != rhs.0.frequency { return lhs.0.frequency > rhs.0.frequency }
                let l = lhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                let r = rhs.0.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                return l > r
            }
            .prefix(7)
            .map(\.0)
    }

    private var shouldShow: Bool {
        focused && !suppress && !matching.isEmpty
    }

    private var popoverBinding: Binding<Bool> {
        Binding(get: { shouldShow }, set: { if !$0 { suppress = true } })
    }

    private var suggestionList: some View {
        let visible = matching
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(visible) { suggestion in
                Button {
                    onSelect(suggestion)
                    suppress = true
                    highlightedId = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OhiaColors.textPrimary)
                                .lineLimit(1)
                            Text(subtitle(for: suggestion))
                                .font(.system(size: 10.5))
                                .foregroundStyle(OhiaColors.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(suggestion.id == highlightedId ? OhiaColors.surface(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
        .composerPresentationFrame(inset: 8, cornerRadius: 8)
    }

    private func subtitle(for suggestion: ComposeRecipientSuggestion) -> String {
        if suggestion.name.isEmpty { return suggestion.address }
        if let org = suggestion.organization, !org.isEmpty {
            return "\(suggestion.address) · \(org)"
        }
        return suggestion.address
    }

    // MARK: - Keyboard

    private func acceptHighlightedOrCommit() {
        let visible = matching
        if shouldShow, let id = highlightedId ?? visible.first?.id,
           let suggestion = visible.first(where: { $0.id == id }) {
            onSelect(suggestion)
            suppress = true
            highlightedId = nil
        } else {
            onCommit()
        }
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let visible = matching
        guard shouldShow, !visible.isEmpty else { return .ignored }
        let currentIndex = highlightedId
            .flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        let next = (currentIndex + delta + visible.count) % visible.count
        highlightedId = visible[next].id
        return .handled
    }
}
