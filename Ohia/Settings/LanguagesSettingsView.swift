// Ohia/Settings/LanguagesSettingsView.swift
// Add and remove active languages used for interpretation and drafting, plus the
// per-account drafting languages the Composer's language menu offers.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaIngest

struct LanguagesSettingsView: View {
    @AppStorage(ContentLanguagesStore.defaultsKey, store: OhiaSharedDefaults.store)
    private var activeLanguagesData: Data = Data()
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguage: String = ""
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var active: Set<String> = []

    var body: some View {
        // Card stack over the night sky, matching General/Sources: the pane
        // title and card headers sit on the sky, content lives in black cards,
        // and the nebula shows in the gutters between them.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Languages")
                        .font(.title2)
                    Text("Tell Ohia which languages your mail may contain, and which language generated summaries and on-demand translations should use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OhiaSettingsCard("Summaries & translation") {
                    SettingsBlock {
                        Picker("Language:", selection: $summaryOutputLanguage) {
                            Text("Follow content languages").tag("")
                            ForEach(alphabetizedLanguages) { language in
                                Text(language.displayName).tag(language.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
                        Text("Generated summaries use this language. When a message's main text is in a different language, Ohia offers to translate it into this language on demand.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                OhiaSettingsCard("Content languages") {
                    SettingsBlock {
                        LazyVGrid(
                            columns: languageGridColumns,
                            spacing: 8
                        ) {
                            ForEach(alphabetizedLanguages) { language in
                                chip(language)
                            }
                        }
                        .padding(.vertical, 4)

                        if active.isEmpty {
                            Text("At least one language is recommended.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if !accounts.isEmpty {
                    draftingLanguagesSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .onAppear { loadActive() }
    }

    // MARK: - Per-account drafting languages

    /// The languages the user writes in from each account. The Composer's
    /// language menu offers these per account; the first is the fallback
    /// default when a message's language can't be detected. An account with
    /// no explicit choice inherits the content languages above.
    private var draftingLanguagesSection: some View {
        OhiaSettingsCard("Drafting languages") {
            SettingsCaption("The languages you write in from each account. The Composer offers these when drafting; a reply still defaults to the incoming message's language.")
            SettingsRowDivider()
            SettingsBlock {
                ForEach(accounts) { account in
                    accountLanguageBlock(account)
                }
            }
        }
    }

    private func accountLanguageBlock(_ account: Account) -> some View {
        let chosen = account.draftLanguages
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.displayName.isEmpty ? account.emailAddress : account.displayName)
                    .font(.callout.weight(.semibold))
                Text(account.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: languageGridColumns, spacing: 8) {
                ForEach(alphabetizedLanguages) { language in
                    accountChip(language, account: account, chosen: chosen)
                }
            }
            if chosen.isEmpty {
                Text("Using your content languages until you choose languages for this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func accountChip(_ language: ContentLanguageOption, account: Account, chosen: [String]) -> some View {
        let isActive = chosen.isEmpty
            ? active.contains(language.id)
            : chosen.contains(language.id)
        return Button {
            toggleAccountLanguage(account, id: language.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                Text(language.displayName)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? OhiaColors.chipSelectedBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? OhiaColors.chipSelectedBorder : OhiaColors.chipRestBorder, lineWidth: 1)
            )
            .foregroundStyle(isActive ? OhiaColors.chipSelected : OhiaColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    /// Toggles a language on the account's drafting list. An account still
    /// inheriting the content languages materializes that inherited set
    /// first, so removing a language from it behaves as expected.
    private func toggleAccountLanguage(_ account: Account, id: String) {
        var list = account.draftLanguages
        if list.isEmpty {
            list = Self.orderedActiveLanguageIDs(from: active)
        }
        if let index = list.firstIndex(of: id) {
            list.remove(at: index)
        } else {
            list.append(id)
        }
        account.draftLanguages = list
        try? modelContext.save()
    }

    private var alphabetizedLanguages: [ContentLanguageOption] {
        ContentLanguageOption.supported.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var languageGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 120), spacing: 8),
            count: 4
        )
    }

    private func chip(_ language: ContentLanguageOption) -> some View {
        let isActive = active.contains(language.id)
        return Button {
            toggle(language.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                Text(language.displayName)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? OhiaColors.chipSelectedBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? OhiaColors.chipSelectedBorder : OhiaColors.chipRestBorder, lineWidth: 1)
            )
            .foregroundStyle(isActive ? OhiaColors.chipSelected : OhiaColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        if active.contains(id) {
            active.remove(id)
        } else {
            active.insert(id)
        }
        saveActive()
    }

    private func loadActive() {
        let decoded = ContentLanguagesStore.decode(activeLanguagesData)
        if !decoded.isEmpty {
            let normalized = Self.normalizedActiveLanguageIDs(from: decoded)
            active = normalized
            if Self.orderedActiveLanguageIDs(from: normalized) != decoded {
                saveActive()
            }
        }
        sanitizeSummaryLanguage()
    }

    private func saveActive() {
        if let data = ContentLanguagesStore.encode(Self.orderedActiveLanguageIDs(from: active)) {
            activeLanguagesData = data
        }
    }

    private func sanitizeSummaryLanguage() {
        let normalized = Self.normalizedSummaryLanguageID(summaryOutputLanguage)
        if summaryOutputLanguage != normalized {
            summaryOutputLanguage = normalized
        }
    }

    static func normalizedActiveLanguageIDs(from decoded: [String]) -> Set<String> {
        Set(decoded.compactMap { ContentLanguageOption.supportedID(for: $0) })
    }

    static func orderedActiveLanguageIDs(from ids: Set<String>) -> [String] {
        ContentLanguageOption.supported
            .map(\.id)
            .filter { ids.contains($0) }
    }

    static func normalizedSummaryLanguageID(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        return ContentLanguageOption.supportedID(for: trimmed) ?? ""
    }
}
