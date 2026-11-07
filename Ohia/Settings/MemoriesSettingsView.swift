import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

struct MemoriesSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Account.emailAddress) private var accounts: [Account]
    @Query(sort: \AccountMemory.updatedAt, order: .reverse) private var memories: [AccountMemory]
    @Query(sort: \AccountMemoryRefreshState.updatedAt, order: .reverse) private var refreshStates: [AccountMemoryRefreshState]
    @Query(sort: \TranslationGlossaryPair.updatedAt, order: .reverse) private var glossaryPairs: [TranslationGlossaryPair]
    @Query(sort: \TranslationGlossaryEvidence.observedAt, order: .reverse) private var glossaryEvidence: [TranslationGlossaryEvidence]

    @State private var selectedAccountRaw = "all"
    @State private var selectedDimension = AccountMemoryDimension.account
    @State private var selectedDimensionValue = "all"
    @State private var expandedMemoryID: UUID?
    @State private var editingMemory: AccountMemory?
    @State private var editingText = ""
    @State private var evidenceMemory: AccountMemory?
    @State private var showHidden = false
    @State private var memoryActionError: String?
    @State private var showAddPairSheet = false
    @State private var selectedGlossaryLanguagePairID = "all"
    @State private var editingGlossaryPair: TranslationGlossaryPair?
    @State private var glossaryEvidencePair: TranslationGlossaryPair?
    @State private var glossaryActionError: String?

    var body: some View {
        // Controls (account scope, dimension tabs, value picker) sit directly
        // on the night sky; the status strip is a black card; each memory row
        // floats as its own card below. Matches the General/Sources idiom of
        // headers-on-sky over black cards with nebula in the gutters.
        VStack(alignment: .leading, spacing: 12) {
            topBar
            dimensionTabs
            if selectedDimension != AccountMemoryDimension.account,
               selectedDimension != AccountMemoryDimension.translation {
                dimensionValuePicker
            }
            statusStrip
            memoryList
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .sheet(item: $editingMemory) { memory in
            editSheet(memory)
        }
        .sheet(item: $evidenceMemory) { memory in
            MemoryEvidenceSheet(memory: memory)
                .frame(minWidth: 560, minHeight: 420)
        }
        .sheet(item: $editingGlossaryPair) { pair in
            GlossaryPairEditorSheet(
                languageOptions: TranslationGlossarySettingsModel.supportedLanguages,
                editing: pair,
                onSave: { language1, term1, language2, term2 in
                    editGlossaryPair(
                        pair,
                        language1: language1, term1: term1,
                        language2: language2, term2: term2
                    )
                }
            )
        }
        .sheet(item: $glossaryEvidencePair) { pair in
            TranslationGlossaryEvidenceSheet(
                pair: pair,
                groups: TranslationGlossarySettingsModel.evidenceGroups(
                    for: pair.id,
                    evidence: glossaryEvidence
                ),
                accountLabels: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.emailAddress) })
            )
            .frame(minWidth: 640, minHeight: 460)
        }
        .sheet(isPresented: $showAddPairSheet) {
            GlossaryPairEditorSheet(
                languageOptions: TranslationGlossarySettingsModel.supportedLanguages,
                editing: nil,
                onSave: { language1, term1, language2, term2 in
                    addGlossaryPair(
                        language1: language1, term1: term1,
                        language2: language2, term2: term2
                    )
                }
            )
        }
        .alert("Memory action failed", isPresented: Binding(
            get: { memoryActionError != nil },
            set: { if $0 == false { memoryActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(memoryActionError ?? "")
        }
        .alert("Glossary action failed", isPresented: Binding(
            get: { glossaryActionError != nil },
            set: { if $0 == false { glossaryActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(glossaryActionError ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if selectedDimension == AccountMemoryDimension.translation {
                Toggle("Show deleted", isOn: $showHidden)
                    .toggleStyle(.checkbox)
            } else {
                Picker("Account", selection: $selectedAccountRaw) {
                    Text("All accounts").tag("all")
                    ForEach(accounts) { account in
                        Text(account.emailAddress).tag(account.id.uuidString)
                    }
                }
                .frame(width: 260)
                .onChange(of: selectedAccountRaw) {
                    selectedDimensionValue = "all"
                }

                Toggle("Show rejected and deleted", isOn: $showHidden)
                    .toggleStyle(.checkbox)
            }

            Spacer()

            if selectedDimension != AccountMemoryDimension.translation {
                Button {
                    exportSelectedAccount()
                } label: {
                    Label("Export Memories…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                .disabled(selectedAccountID == nil)
                .help(
                    selectedAccountID == nil
                        ? "Select one account to export."
                        : "Export the selected account’s memories as Markdown."
                )
            }
        }
    }

    /// The four dossier dimensions the dreaming pipeline projects into. A
    /// custom full-width segmented control (rather than a native `.segmented`
    /// Picker, which on macOS can't render icon + label per segment nor force
    /// equal-width distribution): four equal segments span the window width,
    /// each an icon + label, with the active segment in the §18 selection
    /// accent (`chipActive*`) shared with the top Settings tab strip.
    private var dimensionTabs: some View {
        DimensionSegmentedControl(selection: $selectedDimension) {
            selectedDimensionValue = "all"
            expandedMemoryID = nil
        }
    }

    /// Narrows People / Categories / Projects to one dossier value. Options
    /// are the values that actually have projected memories in the current
    /// account scope, so the picker never offers an empty dossier.
    private var dimensionValuePicker: some View {
        HStack(spacing: 12) {
            Picker(valuePickerLabel, selection: $selectedDimensionValue) {
                Text(allValuesLabel).tag("all")
                ForEach(dimensionValueOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            Spacer()
        }
    }

    private var valuePickerLabel: String {
        switch selectedDimension {
        case AccountMemoryDimension.correspondent: return "Person"
        case AccountMemoryDimension.classification: return "Classification"
        case AccountMemoryDimension.project: return "Project"
        case AccountMemoryDimension.translation: return "Language"
        default: return "Value"
        }
    }

    private var allValuesLabel: String {
        switch selectedDimension {
        case AccountMemoryDimension.correspondent: return "All people"
        case AccountMemoryDimension.classification: return "All classification facets"
        case AccountMemoryDimension.project: return "All projects"
        case AccountMemoryDimension.translation: return "All languages"
        default: return "All"
        }
    }

    private struct DimensionValueOption {
        let value: String
        let label: String
    }

    private var dimensionValueOptions: [DimensionValueOption] {
        let scoped = accountScopedMemories.filter { $0.dimensionKind == selectedDimension }
        var labelByValue: [String: String] = [:]
        var countByValue: [String: Int] = [:]
        for memory in scoped {
            let value = memory.resolvedDimensionValue
            guard value.isEmpty == false else { continue }
            countByValue[value, default: 0] += 1
            if labelByValue[value] == nil {
                labelByValue[value] = memory.resolvedDimensionDisplayName
            }
        }
        return labelByValue
            .map { value, label -> DimensionValueOption in
                let count = countByValue[value] ?? 0
                let display: String
                if label.caseInsensitiveCompare(value) == .orderedSame {
                    display = "\(label) — \(count)"
                } else if selectedDimension == AccountMemoryDimension.correspondent {
                    display = "\(label) <\(value)> — \(count)"
                } else {
                    display = "\(label) — \(count)"
                }
                return DimensionValueOption(value: value, label: display)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                statusMetric("Last dream", lastDreamLabel)
                statusDivider
                statusMetric("Last revised", lastRevisedLabel)
                statusDivider
                statusColumn
                statusDivider
                statusMetric("Memories", "\(visibleMemories.count)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(OhiaColors.settingsCard))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 1, height: 28)
            .padding(.horizontal, 12)
    }

    /// Lifecycle of the dreaming worker, with one stable meaning regardless
    /// of state. A failed run renders in the state-of-message red and exposes
    /// `lastError` on hover — otherwise a failure is indistinguishable from a
    /// success in this strip.
    private var statusColumn: some View {
        metricColumn("Status") {
            if isDreamRunning {
                RunningDreamIndicator()
            } else {
                Text(statusLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isDreamFailed ? OhiaColors.ohiaRed : OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(statusHelp ?? "")
            }
        }
    }

    private var statusLabel: String {
        guard let state = latestState else { return "Idle" }
        switch state.lastStatusRaw {
        case AccountMemoryRefreshStatus.running:  return "Running"
        case AccountMemoryRefreshStatus.deferred: return "Waiting"
        case AccountMemoryRefreshStatus.failed:   return "Failed"
        default:                                  return "Idle"   // idle, succeeded
        }
    }

    private var isDreamFailed: Bool {
        latestState?.lastStatusRaw == AccountMemoryRefreshStatus.failed
    }

    /// Tooltip for the Status column: the captured error when failed,
    /// otherwise nil (an empty `.help` shows nothing).
    private var statusHelp: String? {
        guard isDreamFailed, let error = latestState?.lastError, error.isEmpty == false else { return nil }
        return error
    }

    private func statusMetric(_ label: String, _ value: String) -> some View {
        metricColumn(label) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricColumn<Value: View>(
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(OhiaColors.textTertiary)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isDreamRunning: Bool {
        latestState?.lastStatusRaw == AccountMemoryRefreshStatus.running
    }

    private var memoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selectedDimension == AccountMemoryDimension.translation {
                    translationList
                } else {
                    standardList
                }
            }
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var standardList: some View {
        memorySection("Active", memoriesIn(statuses: [
            AccountMemoryProjectedStatus.confirmed,
            AccountMemoryProjectedStatus.active
        ]))
        memorySection("Needs review", memoriesIn(statuses: [
            AccountMemoryProjectedStatus.needsReview,
            AccountMemoryProjectedStatus.contested,
            AccountMemoryProjectedStatus.inferred,
            AccountMemoryProjectedStatus.affirmed,
            AccountMemoryProjectedStatus.weakened,
            AccountMemoryProjectedStatus.stale
        ]))
        if showHidden {
            memorySection("Rejected and deleted", memoriesIn(statuses: [
                AccountMemoryProjectedStatus.superseded,
                AccountMemoryProjectedStatus.rejected,
                AccountMemoryProjectedStatus.deleted
            ]))
        }
    }

    /// Canonical glossary dyads are user-wide and language-pair scoped. Style
    /// rules remain the existing account + target-language dossier below.
    @ViewBuilder
    private var translationList: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Glossary")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OhiaColors.textPrimary)
            Text("Established renderings of names and terms, applied to both translation directions")
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
            Spacer()
            Button {
                showAddPairSheet = true
            } label: {
                Label("Add Pair…", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.emblem)
            .help("Add a term pair by hand — saved as one confirmed canonical pair")
        }

        HStack(spacing: 12) {
            Picker("Language Pair", selection: $selectedGlossaryLanguagePairID) {
                Text("All language pairs").tag("all")
                ForEach(TranslationGlossarySettingsModel.languagePairs) { pair in
                    Text(pair.label).tag(pair.id)
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            Spacer()
        }

        glossarySection

        VStack(alignment: .leading, spacing: 8) {
            Text("Style rules")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OhiaColors.textPrimary)

            HStack(spacing: 12) {
                Picker("Account", selection: $selectedAccountRaw) {
                    Text("All accounts").tag("all")
                    ForEach(accounts) { account in
                        Text(account.emailAddress).tag(account.id.uuidString)
                    }
                }
                .frame(width: 260)
                .onChange(of: selectedAccountRaw) {
                    selectedDimensionValue = "all"
                }

                Picker("Target language", selection: $selectedDimensionValue) {
                    Text("All target languages").tag("all")
                    ForEach(dimensionValueOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
                Spacer()
            }
        }
        .padding(.top, 8)

        memorySection(
            "Active",
            translationStyleRules(statuses: [
                AccountMemoryProjectedStatus.affirmed,
                AccountMemoryProjectedStatus.inferred
            ]),
            emptyText: "No style rules yet. Durable translation rules are distilled from your authored correspondence and Composer corrections during the next dream."
        )
        memorySection(
            "Weakened and stale",
            translationStyleRules(statuses: [
                AccountMemoryProjectedStatus.weakened,
                AccountMemoryProjectedStatus.stale
            ]),
            emptyText: "No weakened or stale rules."
        )
        if showHidden {
            memorySection(
                "Rejected and deleted",
                translationStyleRules(statuses: [
                    AccountMemoryProjectedStatus.rejected,
                    AccountMemoryProjectedStatus.deleted
                ]),
                emptyText: "No rejected or deleted rules."
            )
        }
    }

    @ViewBuilder
    private var glossarySection: some View {
        if glossaryRows.isEmpty {
            Text("No glossary pairs yet. Pairs come from authored correspondence and Composer corrections, or you can add a confirmed pair by hand.")
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        } else {
            ForEach(glossaryRows) { row in
                TranslationGlossaryRow(
                    row: row,
                    onConfirm: row.actions.contains(.confirm) ? { confirmGlossaryPair(row.id) } : nil,
                    onEdit: { editingGlossaryPair = glossaryPair(id: row.id) },
                    onDelete: row.actions.contains(.delete) ? { deleteGlossaryPair(row.id) } : nil,
                    onEvidence: { glossaryEvidencePair = glossaryPair(id: row.id) }
                )
            }
        }
    }

    private var selectedGlossaryLanguagePair: TranslationGlossarySettingsLanguagePair? {
        TranslationGlossarySettingsModel.languagePairs.first { $0.id == selectedGlossaryLanguagePairID }
    }

    private var glossaryRows: [TranslationGlossarySettingsRow] {
        TranslationGlossarySettingsModel.rows(
            pairs: glossaryPairs,
            evidence: glossaryEvidence,
            selectedLanguagePair: selectedGlossaryLanguagePair,
            showDeleted: showHidden
        )
    }

    private func memorySection(
        _ title: String,
        _ items: [AccountMemory],
        emptyText explicitEmptyText: String? = nil
    ) -> some View {
        Section {
            if items.isEmpty {
                Text(explicitEmptyText ?? emptyText(for: title))
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(items) { memory in
                    ExpandableMemoryRow(
                        memory: memory,
                        isExpanded: expandedMemoryID == memory.id,
                        dimensionTag: rowDimensionTag(for: memory),
                        updatedText: updatedLabel(for: memory),
                        onTap: { toggleExpansion(memory.id) },
                        onAffirm: memory.hasCompleteDurableContractFields
                            && memory.contradictionStateRaw == "clean"
                            && memory.supersededByMemoryKey == nil
                            ? { apply(.confirm, status: AccountMemoryProjectedStatus.confirmed, to: memory) }
                            : nil,
                        onWeaken: { apply(.weaken, status: AccountMemoryProjectedStatus.needsReview, to: memory) },
                        onEdit: { beginEdit(memory) },
                        onDelete: { apply(.markObsolete, status: AccountMemoryProjectedStatus.deleted, to: memory) },
                        onEvidence: { evidenceMemory = memory }
                    )
                }
            }
        } header: {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OhiaColors.textTertiary)
                .padding(.bottom, 2)
        }
    }

    /// Legacy AccountMemory rows now hold free-form style rules only.
    private func translationStyleRules(statuses: Set<String>) -> [AccountMemory] {
        return memoriesIn(statuses: statuses).filter(TranslationStyleRuleWriter.isStyleRule)
    }

    private func glossaryPair(id: UUID) -> TranslationGlossaryPair? {
        glossaryPairs.first { $0.id == id }
    }

    private func addGlossaryPair(
        language1: String,
        term1: String,
        language2: String,
        term2: String
    ) -> String? {
        do {
            try TranslationGlossarySettingsModel.add(
                language1: language1, term1: term1,
                language2: language2, term2: term2,
                in: modelContext,
                now: .now
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func editGlossaryPair(
        _ pair: TranslationGlossaryPair,
        language1: String,
        term1: String,
        language2: String,
        term2: String
    ) -> String? {
        do {
            try TranslationGlossarySettingsModel.edit(
                pairID: pair.id,
                language1: language1, term1: term1,
                language2: language2, term2: term2,
                in: modelContext,
                now: .now
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func confirmGlossaryPair(_ pairID: UUID) {
        do {
            try TranslationGlossarySettingsModel.confirm(pairID: pairID, in: modelContext, now: .now)
        } catch {
            glossaryActionError = error.localizedDescription
        }
    }

    private func deleteGlossaryPair(_ pairID: UUID) {
        do {
            try TranslationGlossarySettingsModel.delete(pairID: pairID, in: modelContext, now: .now)
        } catch {
            glossaryActionError = error.localizedDescription
        }
    }

    private func editSheet(_ memory: AccountMemory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit memory")
                .font(.system(size: 16, weight: .semibold))
            TextEditor(text: $editingText)
                .font(.system(size: 13))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { editingMemory = nil }
                Button("Save") {
                    saveEdit(memory)
                    editingMemory = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 280)
    }

    private func toggleExpansion(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.16)) {
            expandedMemoryID = (expandedMemoryID == id) ? nil : id
        }
    }

    private var selectedAccountID: UUID? {
        selectedAccountRaw == "all" ? nil : UUID(uuidString: selectedAccountRaw)
    }

    /// Account scope + hidden filter, before any dimension narrowing —
    /// feeds both the value picker options and the visible list.
    private var accountScopedMemories: [AccountMemory] {
        let base: [AccountMemory]
        if let selectedAccountID {
            base = memories.filter { $0.accountID == selectedAccountID }
        } else {
            base = memories
        }
        return base.filter { showHidden || $0.isHiddenByDefault == false }
    }

    private var visibleMemories: [AccountMemory] {
        accountScopedMemories.filter { memory in
            memory.dimensionKind == selectedDimension
                && (selectedDimensionValue == "all"
                    || memory.resolvedDimensionValue == selectedDimensionValue)
        }
    }

    private func memoriesIn(statuses: Set<String>) -> [AccountMemory] {
        visibleMemories
            .filter { statuses.contains($0.statusRaw) }
            .sorted { left, right in
                if left.statusRaw != right.statusRaw {
                    return statusRank(left.statusRaw) < statusRank(right.statusRaw)
                }
                if left.weight != right.weight { return left.weight > right.weight }
                return left.displayText.localizedStandardCompare(right.displayText) == .orderedAscending
            }
    }

    private var relevantStates: [AccountMemoryRefreshState] {
        guard let selectedAccountID else { return refreshStates }
        return refreshStates.filter { $0.accountID == selectedAccountID }
    }

    private var latestState: AccountMemoryRefreshState? {
        relevantStates.sorted { left, right in
            let leftDate = left.lastRunCompletedAt ?? left.lastRunStartedAt ?? left.updatedAt
            let rightDate = right.lastRunCompletedAt ?? right.lastRunStartedAt ?? right.updatedAt
            return leftDate > rightDate
        }.first
    }

    /// "Last dream" is purely temporal now — the live running state lives in
    /// the Status column. During an in-flight run this shows the *previous*
    /// completion (when it last finished), or "Queued" before any first run.
    private var lastDreamLabel: String {
        guard let state = latestState else { return "Never" }
        guard let date = state.lastRunCompletedAt ?? state.lastSuccessfulRunAt else {
            return "Queued"
        }
        return shortDate(date)
    }

    private var lastRevisedLabel: String {
        guard let latest = visibleMemories.map(\.updatedAt).max() else { return "Never" }
        return shortDate(latest)
    }

    private func updatedLabel(for memory: AccountMemory) -> String {
        "updated \(shortDate(memory.updatedAt))"
    }

    private func beginEdit(_ memory: AccountMemory) {
        editingText = memory.displayText
        editingMemory = memory
    }

    private func saveEdit(_ memory: AccountMemory) {
        memory.applyUserEdit(editingText)
        do {
            try modelContext.save()
        } catch {
            memoryActionError = error.localizedDescription
        }
    }

    private func apply(
        _ action: ConversationCurationAction.ActionValue,
        status: String,
        to memory: AccountMemory
    ) {
        // Collapse the acted row before the status change re-buckets it
        // into another section — otherwise the expanded detail animates
        // against the section it is leaving and jumps mid-transition.
        if expandedMemoryID == memory.id { expandedMemoryID = nil }
        let writer = ConversationCurationActionWriter(modelContext: modelContext)
        writer.write(components: curationComponents(for: memory), action: action)
        memory.statusRaw = status
        // Affirmation must leave a timestamp, not just a status: version
        // migration cleanup passes
        // treat `lastAffirmedAt` as user-curation evidence.
        if status == AccountMemoryProjectedStatus.confirmed
            || status == AccountMemoryProjectedStatus.affirmed {
            memory.lastAffirmedAt = Date()
        }
        memory.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            memoryActionError = error.localizedDescription
        }
    }

    private func curationComponents(for memory: AccountMemory) -> CurationKeyComponents {
        let scope = memory.decodedScope().compactMap { reference -> ScopeHint? in
            guard let kind = ScopeKind(rawValue: reference.kindRaw) else { return nil }
            return ScopeHint(kind: kind, value: reference.value)
        }
        return CurationKeyComponents(
            targetKey: memory.memoryKey,
            normalizedClaimText: memory.normalizedText,
            targetKind: ConversationCurationAction.TargetKind(rawValue: memory.targetKindRaw) ?? .claim,
            scopeFingerprint: ConversationCurationKey.makeDurableClaimScopeFingerprint(
                scope: scope,
                kindRaw: memory.targetKindRaw,
                subjectText: memory.subjectText,
                conditionsText: memory.conditionsText,
                futureUseText: memory.futureUseText,
                formationBasisRaw: memory.formationBasisRaw,
                usePolicyRaw: memory.usePolicyRaw
            ),
            extractionVersion: memory.extractionVersion,
            supportingFingerprint: memory.supportingFingerprint
        )
    }

    private func exportSelectedAccount() {
        guard let accountID = selectedAccountID else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Memories"
        panel.message = "Choose a folder for this one-time Markdown export."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let didStartAccessing = destination.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                destination.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try exportAccount(accountID, to: destination)
        } catch {
            memoryActionError = error.localizedDescription
        }
    }

    private func exportAccount(_ accountID: UUID, to destination: URL) throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        // Fetch from the context rather than the @Query array: rows inserted
        // earlier in this same event turn (e.g. a just-added glossary pair)
        // are visible to a fetch but not yet to the query snapshot.
        let accountMemories = try modelContext.fetch(FetchDescriptor<AccountMemory>(
            predicate: #Predicate { $0.accountID == accountID }
        ))
        _ = try MemoryManualExporter.export(
            account: account,
            memories: accountMemories,
            to: destination
        )
    }

    /// When browsing the whole dimension ("All people"), each row names its
    /// dossier so memories from different people / categories / projects
    /// stay distinguishable. Hidden once a specific value is selected.
    private func rowDimensionTag(for memory: AccountMemory) -> String? {
        guard selectedDimension != AccountMemoryDimension.account,
              selectedDimensionValue == "all" else { return nil }
        let name = memory.resolvedDimensionDisplayName
        return name.isEmpty ? nil : name
    }

    private func emptyText(for title: String) -> String {
        switch title {
        case "Active":
            switch selectedDimension {
            case AccountMemoryDimension.correspondent:
                return "No durable guidance has been learned for these people yet."
            case AccountMemoryDimension.classification:
                return "No durable guidance has been learned for this category scope yet."
            case AccountMemoryDimension.project:
                return "No durable guidance has been learned for this project scope yet."
            default:
                return "No durable guidance has been learned for this account scope yet."
            }
        case "Needs review":
            return "No durable guidance needs review."
        default:
            return "No rejected or deleted memories."
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case AccountMemoryProjectedStatus.confirmed: return 0
        case AccountMemoryProjectedStatus.active: return 1
        case AccountMemoryProjectedStatus.needsReview: return 2
        case AccountMemoryProjectedStatus.contested: return 3
        case AccountMemoryProjectedStatus.superseded: return 4
        default: return 5
        }
    }

    private func shortDate(_ date: Date) -> String {
        MemoryDateFormatters.mediumShort.string(from: date)
    }
}

@MainActor
enum MemoryManualExporter {
    @discardableResult
    static func export(
        account: Account,
        memories: [AccountMemory],
        to destination: URL,
        generatedAt: Date = .now
    ) throws -> URL {
        try AccountMemoryMarkdownStore(rootDirectory: destination).export(
            accountID: account.id,
            accountDisplayName: account.displayName,
            accountEmailAddress: account.emailAddress,
            memories: memories,
            generatedAt: generatedAt
        )
    }
}

/// Cached formatters — `DateFormatter` construction is expensive and these
/// are hit once per row (plus per evidence line) inside lazy lists. Safe to
/// share: `DateFormatter` is thread-safe for formatting once configured.
private enum MemoryDateFormatters {
    static let mediumShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    static let shortShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Translation glossary

private struct GlossaryPairEditorSheet: View {
    let languageOptions: [TranslationGlossarySettingsLanguage]
    let editing: TranslationGlossaryPair?
    let onSave: (_ language1: String, _ term1: String, _ language2: String, _ term2: String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var language1: String
    @State private var language2: String
    @State private var term1: String
    @State private var term2: String
    @State private var saveError: String?

    init(
        languageOptions: [TranslationGlossarySettingsLanguage],
        editing: TranslationGlossaryPair?,
        onSave: @escaping (_ language1: String, _ term1: String, _ language2: String, _ term2: String) -> String?
    ) {
        self.languageOptions = languageOptions
        self.editing = editing
        self.onSave = onSave
        _language1 = State(initialValue: editing?.canonicalLanguageB ?? languageOptions.first?.code ?? "")
        _language2 = State(initialValue: editing?.canonicalLanguageA ?? languageOptions.dropFirst().first?.code ?? "")
        _term1 = State(initialValue: editing?.termB ?? "")
        _term2 = State(initialValue: editing?.termA ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Add glossary pair" : "Edit glossary pair")
                .font(.system(size: 16, weight: .semibold))
            Text("Set the authored form in each language. Saving confirms the one bidirectional pair.")
                .font(.system(size: 11.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("First term")
                        .font(.system(size: 12, weight: .semibold))
                        .gridColumnAlignment(.trailing)
                    TextField("", text: $term1)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    languagePicker(selection: $language1)
                }
                GridRow {
                    Text("Second term")
                        .font(.system(size: 12, weight: .semibold))
                        .gridColumnAlignment(.trailing)
                    TextField("", text: $term2)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    languagePicker(selection: $language2)
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Text("Glossary pair was not saved: \(saveError)")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.emblem)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saveError = onSave(
                        language1,
                        term1.trimmingCharacters(in: .whitespacesAndNewlines),
                        language2,
                        term2.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if saveError == nil { dismiss() }
                }
                .buttonStyle(.emblem)
                .keyboardShortcut(.defaultAction)
                .disabled(canSave == false)
            }
        }
        .padding()
        .frame(minWidth: 520)
    }

    private func languagePicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(languageOptions) { option in
                Text(option.label).tag(option.code)
            }
        }
        .labelsHidden()
        .frame(width: 150)
    }

    private var validationMessage: String? {
        TranslationGlossarySettingsModel.validationMessage(
            language1: language1,
            term1: term1,
            language2: language2,
            term2: term2,
            editing: editing
        )
    }

    private var canSave: Bool {
        validationMessage == nil
    }
}

private struct TranslationGlossaryRow: View {
    let row: TranslationGlossarySettingsRow
    let onConfirm: (() -> Void)?
    let onEdit: () -> Void
    let onDelete: (() -> Void)?
    let onEvidence: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(row.displayText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Text(row.status.rawValue.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text("Confidence \(Int((min(1, max(0, row.confidence)) * 100).rounded()))%")
                Text("\(row.evidenceCount) \(row.evidenceCount == 1 ? "citation" : "citations")")
                Text("Updated \(MemoryDateFormatters.mediumShort.string(from: row.updatedAt))")
                Spacer()

                if let onConfirm {
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(.emblem)
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(.emblem)
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.emblem)
                }
                Button("Evidence", action: onEvidence)
                    .buttonStyle(.emblem)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(OhiaColors.textTertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(OhiaColors.settingsCard))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch row.status {
        case .inferred: OhiaColors.textSecondary
        case .confirmed: OhiaColors.ohiaGreen
        case .deleted: OhiaColors.textTertiary
        }
    }
}

private struct TranslationGlossaryEvidenceSheet: View {
    let pair: TranslationGlossaryPair
    let groups: [TranslationGlossarySettingsEvidenceGroup]
    let accountLabels: [UUID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glossary evidence")
                .font(.system(size: 17, weight: .semibold))
            Text("\(TranslationGlossarySettingsModel.languageName(pair.canonicalLanguageB)): \(pair.termB) ↔ \(TranslationGlossarySettingsModel.languageName(pair.canonicalLanguageA)): \(pair.termA)")
                .font(.system(size: 13))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            if groups.isEmpty {
                Text("No authored evidence is attached to this pair.")
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            evidenceGroup(group)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func evidenceGroup(_ group: TranslationGlossarySettingsEvidenceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.polarity == .supporting ? "SUPPORTING" : "CONTRADICTORY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(group.polarity == .supporting ? OhiaColors.ohiaGreen : OhiaColors.ohiaYellow)

            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(evidenceKindLabel(item.kind))
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(item.observedTermB) ↔ \(item.observedTermA)")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.textPrimary)
                    Text(provenanceLabel(item))
                        .font(.system(size: 10))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .textSelection(.enabled)
                    if let excerpt = item.excerpt, excerpt.isEmpty == false {
                        Text(excerpt)
                            .font(.system(size: 11))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.glassPanel))
            }
        }
    }

    private func provenanceLabel(_ item: TranslationGlossarySettingsEvidenceItem) -> String {
        var fields = [MemoryDateFormatters.mediumShort.string(from: item.observedAt)]
        if let accountID = item.sourceAccountID {
            fields.append("Account \(accountLabels[accountID] ?? accountID.uuidString)")
        }
        if let author = item.sourceAuthorAddress, author.isEmpty == false { fields.append(author) }
        if let messageID = item.sourceMessageID { fields.append("Message \(messageID.uuidString)") }
        if let draftID = item.sourceDraftID { fields.append("Draft \(draftID.uuidString)") }
        return fields.joined(separator: " · ")
    }

    private func evidenceKindLabel(_ kind: TranslationGlossaryEvidenceKind) -> String {
        switch kind {
        case .composerCorrection: "Composer correction"
        case .explicitBilingualNotation: "Explicit bilingual notation"
        case .trustedIdentityDeclaration: "Trusted identity declaration"
        case .correspondentIdentity: "Correspondent identity"
        case .linkedCorrespondence: "Linked correspondence"
        case .manual: "Manual entry"
        case .modelRendering: "Model rendering"
        }
    }
}

// MARK: - Expand-on-select memory row

private struct ExpandableMemoryRow: View {
    let memory: AccountMemory
    let isExpanded: Bool
    let dimensionTag: String?
    let updatedText: String
    let onTap: () -> Void
    let onAffirm: (() -> Void)?
    let onWeaken: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onEvidence: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedHeader
            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 10 : 8)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// A floating card over the night sky: opaque black base (the list sits
    /// directly on the starfield, so a translucent fill would wash out), with
    /// the previous hover / expanded tints layered on top of it.
    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(OhiaColors.settingsCard)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isExpanded
                            ? OhiaColors.buttonBackground
                            : (isHovered ? OhiaColors.glassPanel.opacity(0.4) : Color.clear)
                    )
            )
    }

    private var collapsedHeader: some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 10) {
            headerText
                .frame(maxWidth: .infinity, alignment: .leading)
            MemoryMetadataChip(text: kindLabel)
            MemoryMetadataChip(text: scopeLabel)
            MemoryStatusBadge(statusRaw: memory.statusRaw, showLabel: true)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 14)
                .padding(.top, isExpanded ? 3 : 0)
        }
        .frame(minHeight: 34)
    }

    /// The memory text on the header line. Collapsed: a single fade-clipped
    /// line. Expanded: the full text, wrapping — never truncated.
    @ViewBuilder
    private var headerText: some View {
        if memory.isSensitiveAndUnaffirmed {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: isExpanded ? 12 : 9.5, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.85))
                if isExpanded {
                    Text("Sensitive — affirm to reveal. Evidence stays inspectable below.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Sensitive — affirm to reveal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .lineLimit(1)
                }
            }
        } else if isExpanded {
            Text(memory.displayText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            FadeClippedText(
                text: memory.displayText.trimmingCharacters(in: .whitespacesAndNewlines),
                font: .system(size: 12, weight: .medium),
                color: OhiaColors.textPrimary
            )
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Text(provenanceBreadth)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(OhiaColors.textTertiary)
                Spacer(minLength: 4)
                Text(updatedText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            guidanceField(title: "WHY REMEMBERED", value: formationBasisLabel)
            guidanceField(
                title: "FUTURE USE",
                value: memory.futureUseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Not recorded — this memory cannot guide drafts until reviewed."
            )
            scopeRow
            evidencePreview
            HStack(spacing: 5) {
                Spacer()
                if let onAffirm {
                    MemoryEmblemButton(label: "Confirm", help: "Confirm this durable guidance", symbol: "checkmark", action: onAffirm)
                }
                MemoryEmblemButton(label: "Review", help: "Move this guidance to Needs Review", symbol: "questionmark", action: onWeaken)
                MemoryEmblemButton(label: "Edit", help: "Edit the memory text", symbol: "pencil", action: onEdit)
                MemoryEmblemButton(label: "Delete", help: "Delete — remove this memory; it won't be regenerated", symbol: "trash", action: onDelete)
                MemoryEmblemButton(label: "Evidence", help: "Evidence — view the source messages behind this memory", symbol: "list.bullet.rectangle", action: onEvidence)
            }
        }
        .padding(.top, 8)
    }

    private func guidanceField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var kindLabel: String {
        switch memory.targetKindRaw {
        case AccountMemoryKind.preference: return "Preference"
        case AccountMemoryKind.relationship: return "Relationship"
        case AccountMemoryKind.roleResponsibility: return "Role"
        case AccountMemoryKind.norm: return "Norm"
        case AccountMemoryKind.ruleConstraint: return "Rule"
        case AccountMemoryKind.procedure: return "Procedure"
        case AccountMemoryKind.convention: return "Convention"
        case AccountMemoryKind.orientation: return "Orientation"
        case AccountMemoryKind.learnedLesson: return "Learned lesson"
        default: return "Needs review"
        }
    }

    private var scopeLabel: String {
        let value = dimensionTag ?? memory.resolvedDimensionDisplayName
        switch memory.dimensionKind {
        case AccountMemoryDimension.correspondent:
            return value.isEmpty ? "People" : "Person · \(value)"
        case AccountMemoryDimension.classification:
            return value.isEmpty ? "Category" : "Category · \(value)"
        case AccountMemoryDimension.project:
            return value.isEmpty ? "Project" : "Project · \(value)"
        case AccountMemoryDimension.translation:
            return value.isEmpty ? "Translation" : "Translation · \(value)"
        default:
            return "Account"
        }
    }

    private var formationBasisLabel: String {
        switch memory.formationBasisRaw {
        case AccountMemoryFormationBasis.explicitStanding:
            return "Explicit standing guidance in correspondence"
        case AccountMemoryFormationBasis.explicitCorrection:
            return "Explicit reusable correction"
        case AccountMemoryFormationBasis.repeatedPattern:
            return "Consistent pattern across independent threads"
        case AccountMemoryFormationBasis.userCurated:
            return "Written or materially edited by the user"
        default:
            return "Formation basis needs review"
        }
    }

    private var provenanceBreadth: String {
        let evidence = memory.decodedEvidence()
        let messageCount = Set(evidence.map(\.messageID)).count
        let threadCount = Set(evidence.compactMap(\.threadID)).count
        let messageUnit = messageCount == 1 ? "message" : "messages"
        let threadUnit = threadCount == 1 ? "thread" : "threads"
        return "\(messageCount) \(messageUnit) · \(threadCount) \(threadUnit)"
    }

    private var scopeRow: some View {
        let scope = memory.decodedScope()
        return HStack(spacing: 8) {
            ForEach(Array(scope.prefix(5)), id: \.self) { item in
                Text("#\(item.value)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            if scope.count > 5 {
                Text("+\(scope.count - 5)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var evidencePreview: some View {
        let evidence = memory.decodedEvidence()
        if evidence.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("TOP EVIDENCE")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(OhiaColors.textTertiary)
                ForEach(Array(evidence.prefix(2)), id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "envelope")
                            .font(.system(size: 9))
                            .foregroundStyle(OhiaColors.textTertiary)
                        FadeClippedText(
                            text: "\(item.subject) · \(item.senderAddress) · \(shortDate(item.timestamp))",
                            font: .system(size: 10.5),
                            color: OhiaColors.textSecondary
                        )
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.glassPanel.opacity(0.5)))
        }
    }

    private func shortDate(_ date: Date) -> String {
        MemoryDateFormatters.shortShort.string(from: date)
    }
}

/// Animated "Last dream · Running" readout — a live spinner beside a
/// softly breathing moon so the strip shows the worker is actively
/// dreaming rather than printing a static word.
private struct RunningDreamIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaGreen)
                .opacity(pulsing ? 1.0 : 0.45)
                .scaleEffect(pulsing ? 1.0 : 0.88)
            Text("Running")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityLabel("Dreaming in progress")
    }
}

// MARK: - Dimension segmented control

/// Full-width segmented sub-tab control for the four memory dossier
/// dimensions. Four equal-width segments fill the available width; each
/// renders its icon beside its label, and the selected segment lifts into
/// the active-filter accent (`chipActive*`) — the same selection register as
/// the Settings sidebar (`SettingsSidebarRow`).
private struct DimensionSegmentedControl: View {
    @Binding var selection: String
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AccountMemoryDimension.all, id: \.self) { dimension in
                DimensionSegment(
                    title: Self.title(for: dimension),
                    systemImage: Self.icon(for: dimension),
                    isSelected: selection == dimension
                ) {
                    guard selection != dimension else { return }
                    selection = dimension
                    onChange()
                }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.settingsCard))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
    }

    private static func title(for dimension: String) -> String {
        if dimension == AccountMemoryDimension.classification {
            return "Category"
        }
        return AccountMemoryDimension.displayLabel(dimension)
    }

    private static func icon(for dimension: String) -> String {
        switch dimension {
        case AccountMemoryDimension.account:       return "at"
        case AccountMemoryDimension.correspondent: return "person.2"
        case AccountMemoryDimension.classification: return "tag"
        case AccountMemoryDimension.project:       return "folder"
        case AccountMemoryDimension.translation:   return "character.bubble"
        default:                                   return "circle"
        }
    }
}

/// One segment of `DimensionSegmentedControl`: icon + label centered, equal
/// width via `maxWidth: .infinity`, hover-lift and selection-accent matching
/// the top tab strip's register.
private struct DimensionSegment: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 6).fill(backgroundFill))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var foreground: Color {
        if isSelected { return OhiaColors.chipActiveForeground }
        if isHovering { return OhiaColors.textPrimary }
        return OhiaColors.textSecondary
    }

    private var backgroundFill: Color {
        if isSelected { return OhiaColors.chipActiveBackground }
        if isHovering { return OhiaColors.surface(0.06) }
        return Color.clear
    }
}

// MARK: - Shared building blocks

private struct MemoryStatusStyle {
    let glyph: String
    let tint: Color
    let label: String

    static func resolve(_ raw: String) -> MemoryStatusStyle {
        switch raw {
        case AccountMemoryProjectedStatus.confirmed:
            return MemoryStatusStyle(glyph: "checkmark", tint: OhiaColors.ohiaGreen, label: "Confirmed")
        case AccountMemoryProjectedStatus.active:
            return MemoryStatusStyle(glyph: "circle.fill", tint: OhiaColors.textSecondary, label: "Active")
        case AccountMemoryProjectedStatus.needsReview:
            return MemoryStatusStyle(glyph: "questionmark", tint: OhiaColors.ohiaYellow, label: "Needs review")
        case AccountMemoryProjectedStatus.contested:
            return MemoryStatusStyle(glyph: "exclamationmark.triangle", tint: OhiaColors.ohiaYellow, label: "Contested")
        case AccountMemoryProjectedStatus.superseded:
            return MemoryStatusStyle(glyph: "arrow.right", tint: OhiaColors.textTertiary, label: "Superseded")
        case AccountMemoryProjectedStatus.affirmed:
            return MemoryStatusStyle(glyph: "checkmark", tint: OhiaColors.ohiaGreen, label: "Legacy affirmed")
        case AccountMemoryProjectedStatus.inferred:
            return MemoryStatusStyle(glyph: "circle.dotted", tint: OhiaColors.textSecondary, label: "Legacy inferred")
        case AccountMemoryProjectedStatus.weakened:
            return MemoryStatusStyle(glyph: "arrow.down", tint: OhiaColors.ohiaYellow, label: "weakened")
        case AccountMemoryProjectedStatus.stale:
            return MemoryStatusStyle(glyph: "clock", tint: OhiaColors.textTertiary, label: "stale")
        case AccountMemoryProjectedStatus.rejected:
            return MemoryStatusStyle(glyph: "xmark", tint: OhiaColors.textTertiary, label: "rejected")
        case AccountMemoryProjectedStatus.deleted:
            return MemoryStatusStyle(glyph: "trash", tint: OhiaColors.textTertiary, label: "deleted")
        default:
            return MemoryStatusStyle(glyph: "circle.dotted", tint: OhiaColors.textSecondary, label: raw)
        }
    }
}

/// Glyph + color status badge. Scannable replacement for a plain-text chip.
private struct MemoryStatusBadge: View {
    let statusRaw: String
    let showLabel: Bool

    var body: some View {
        let style = MemoryStatusStyle.resolve(statusRaw)
        if showLabel {
            HStack(spacing: 4) {
                Image(systemName: style.glyph)
                    .font(.system(size: 9, weight: .bold))
                Text(style.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(style.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(style.tint.opacity(0.14)))
        } else {
            Image(systemName: style.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.tint)
                .frame(width: 14, height: 14)
                .help(style.label)
        }
    }
}

private struct MemoryMetadataChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(OhiaColors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(OhiaColors.chipRestBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            )
    }
}

private struct MemoryEmblemButton: View {
    let label: String
    let help: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaGreen)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.buttonBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Clips overflowing single-line text and fades the trailing edge to
/// transparent — a layout solution to overflow rather than an ellipsis.
private struct FadeClippedText: View {
    /// Long learned memories can contain entire quoted exchanges. Bound the
    /// text before asking SwiftUI for an intrinsic single-line width so a
    /// collapsed row cannot allocate layout for an arbitrarily long string.
    private static let maximumRenderedCharacterCount = 256

    let text: String
    let font: Font
    let color: Color

    private var boundedText: String {
        String(text.prefix(Self.maximumRenderedCharacterCount))
    }

    var body: some View {
        // The visible line is an overlay over an invisible sizing ghost, so
        // its intrinsic single-line width can never enter layout. The previous
        // shape — fixedSize text inside `.frame(maxWidth: .infinity)` — never
        // clipped at all: a flexible frame with no explicit minimum adopts its
        // child's width, so a long memory inflated the whole row past the pane
        // edge and both the clip and the fade landed off-window.
        Text(boundedText)
            .font(font)
            .foregroundStyle(.clear)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(boundedText)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // The ghost announces the text; without this the row
                    // reads twice under VoiceOver.
                    .accessibilityHidden(true)
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

private struct MemoryEvidenceSheet: View {
    let memory: AccountMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence")
                .font(.system(size: 17, weight: .semibold))
            Text(memory.displayText)
                .font(.system(size: 13))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(memory.decodedEvidence(), id: \.self) { evidence in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(evidence.subject)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(evidence.senderAddress) · \(dateLabel(evidence.timestamp))")
                                .font(.system(size: 11))
                                .foregroundStyle(OhiaColors.textTertiary)
                            if let senderName = evidence.senderName, senderName.isEmpty == false {
                                Text(senderName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(OhiaColors.textTertiary)
                            }
                            if let span = evidence.spanText, span.isEmpty == false {
                                Text(span)
                                    .font(.system(size: 12))
                                    .foregroundStyle(OhiaColors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let summary = evidence.summary, summary.isEmpty == false {
                                Text(summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(OhiaColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Confidence \(Int((min(1, max(0, evidence.confidence)) * 100).rounded()))% · \(evidence.fieldSourceRaw) · \(evidence.messageID.uuidString)")
                                .font(.system(size: 10))
                                .foregroundStyle(OhiaColors.textTertiary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(OhiaColors.glassPanel))
                    }
                }
            }
        }
        .padding()
    }

    private func dateLabel(_ date: Date) -> String {
        MemoryDateFormatters.mediumShort.string(from: date)
    }
}
