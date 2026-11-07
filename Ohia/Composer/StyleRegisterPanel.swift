// Ohia/Composer/StyleRegisterPanel.swift
// The Composer's Style panel, top to bottom in causal order: the draft
// language (which scopes everything below), the style register card — the
// named, described voice steering the draft, with its training extent and
// provenance — the trained-influence strip, and the plain-language read of
// the incoming message whose signals calibrated the voice. The card's name
// row is a picker over every style *for the selected language* (styles span
// accounts);
// choosing one restyles the current body (or sets the voice for a compose
// that has not generated yet). Switching language re-resolves the style and
// regenerates a generated body in the new language. No email rows:
// exemplars surface only as counts, never as a message list.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

// MARK: - Panel models

enum StyleRegisterPresentationKind: Equatable {
    case savedCustom
    case learned

    var symbolName: String {
        switch self {
        case .savedCustom: "slider.horizontal.3"
        case .learned: "checkmark.seal.fill"
        }
    }

    var helpText: String {
        switch self {
        case .savedCustom:
            "Saved custom style — created from your slider settings"
        case .learned:
            "Learned style — supported by your sent correspondence"
        }
    }
}

/// One selectable register in the picker.
struct StyleRegisterChoice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let summary: String
    let exemplarCount: Int
    let kind: StyleRegisterPresentationKind
    let canDelete: Bool

    init(
        id: UUID,
        name: String,
        summary: String,
        exemplarCount: Int,
        kind: StyleRegisterPresentationKind = .learned,
        canDelete: Bool = true
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.exemplarCount = exemplarCount
        self.kind = kind
        self.canDelete = canDelete
    }
}

/// One selectable draft language in the language menu.
struct DraftLanguageChoice: Identifiable, Equatable {
    /// Canonical language family id ("en", "ja").
    let id: String
    let name: String
    /// True for the one-off entry derived from the message or recipient
    /// (shown even when the account's language list doesn't include it).
    let isDetected: Bool
}

/// The active register's card contents.
struct StyleRegisterCardModel: Equatable {
    let id: UUID
    let name: String
    let summary: String
    /// The style's slider defaults: the centroid of its member emails'
    /// measured axes, or a saved style's own values.
    let styleAxes: StyleAxisValues?
    let revision: Int
    let exemplarCount: Int
    let correspondentCount: Int
    let trainedPairCount: Int
    let preferenceEventCount: Int
    let kind: StyleRegisterPresentationKind
    /// True when the user picked this register (pending or stamped); false
    /// when the resolver chose it.
    let isExplicit: Bool
    /// The rule that chose an automatically selected style.
    let resolutionReason: StyleResolutionReason?

    init(
        id: UUID,
        name: String,
        summary: String,
        styleAxes: StyleAxisValues? = nil,
        revision: Int = 1,
        exemplarCount: Int,
        correspondentCount: Int,
        trainedPairCount: Int,
        preferenceEventCount: Int = 0,
        kind: StyleRegisterPresentationKind = .learned,
        isExplicit: Bool,
        resolutionReason: StyleResolutionReason? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.styleAxes = styleAxes
        self.revision = revision
        self.exemplarCount = exemplarCount
        self.correspondentCount = correspondentCount
        self.trainedPairCount = trainedPairCount
        self.preferenceEventCount = preferenceEventCount
        self.kind = kind
        self.isExplicit = isExplicit
        self.resolutionReason = resolutionReason
    }
}

/// Everything the Style panel renders, computed by the hosting lane.
struct StyleRegisterPanelModel: Equatable {
    var card: StyleRegisterCardModel?
    /// Full cards for the language-scoped picker inventory. The live panel
    /// renders only `card`; version history uses this cache to project the
    /// register and calculated defaults that shaped an older body without a
    /// new store fetch from inside the view.
    var registerCards: [StyleRegisterCardModel] = []
    /// Registers offered by the picker — only ones covering the selected
    /// language; styles are language-scoped.
    var choices: [StyleRegisterChoice]
    /// A register switch is queued and a body exists — the worker owes a
    /// restyled version.
    var isRestylePending: Bool
    /// Current slider readings: pending selection, applied selection, or the
    /// calculated defaults, in that authority order.
    var selectedStyleAxes: StyleAxisValues?
    /// True after a slider move and until a successful Regenerate/restyle
    /// applies that exact selection.
    var isStyleAdjustmentPending: Bool
    /// True while Regenerate is actively applying the pending slider profile.
    var isApplyingStyleAdjustment: Bool = false
    /// The selected snapshot came from a typed revision. This remains Custom
    /// even when its effective values happen to equal the named defaults.
    var isInstructionDerivedCustomStyle: Bool = false
    /// The language menu's entries: the detected/default language first when
    /// it isn't in the account's list, then the account's languages.
    var languageChoices: [DraftLanguageChoice]
    /// The draft's resolved language (picker choice, else detected).
    var selectedLanguageID: String?
    /// Whether any active style exists at all — distinguishes "no style for
    /// this language" from no styles yet.
    var hasAnyRegisters: Bool

    var showsStyleAdjustmentPrompt: Bool {
        isStyleAdjustmentPending && !isApplyingStyleAdjustment
    }

    static let empty = StyleRegisterPanelModel(
        card: nil,
        registerCards: [],
        choices: [],
        isRestylePending: false,
        selectedStyleAxes: nil,
        isStyleAdjustmentPending: false,
        languageChoices: [],
        selectedLanguageID: nil,
        hasAnyRegisters: false
    )

    /// Builds the panel model for a reply draft: the explicit choice
    /// (pending switch, then stamped register) wins when it covers the
    /// draft's language; otherwise the resolver preview shows the voice
    /// generation would pick for this message in that language.
    @MainActor
    static func forReply(message: Message, context: ModelContext) -> StyleRegisterPanelModel {
        let draft = message.draft
        let languageID = DraftLanguage.resolvedID(for: message)
        let explicitID = draft?.pendingStyleRegisterID ?? draft?.styleRegisterID
        let explicit = explicitID
            .flatMap {
                StyleRegisterResolver.register(withID: $0, language: languageID, context: context)
            }
        let resolution = explicit == nil
            ? StyleRegisterResolver.resolution(forIncoming: message, language: languageID, context: context)
            : nil
        let active = explicit ?? resolution?.register
        // A restyle is owed only against a generated body (≥1 revision) —
        // the same gate the generation orchestrator drains on.
        let hasGeneratedBody = (draft?.revisions ?? []).isEmpty == false
        let isStyleAdjustmentPending = active.map {
            draft?.pendingStyleControlSnapshot?.registerID == $0.id
        } ?? false
        return build(
            active: active,
            isExplicit: explicit != nil,
            resolutionReason: resolution?.reason,
            account: message.account,
            isRestylePending: draft?.pendingStyleRegisterID != nil && hasGeneratedBody,
            selectedStyleAxes: selectedStyleAxes(
                draft: draft,
                activeRegisterID: active?.id,
                defaults: active?.styleAxes
            ),
            isStyleAdjustmentPending: isStyleAdjustmentPending,
            isApplyingStyleAdjustment:
                ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                    pendingInstruction: draft?.pendingInstruction,
                    hasPendingStyleAdjustment: isStyleAdjustmentPending,
                    isGenerationBlocked: draft.map {
                        ComposerGenerationTaskPresentation.isGenerationBlocked($0)
                    } ?? false
                ),
            isInstructionDerivedCustomStyle: selectedStyleControlSnapshot(
                draft: draft,
                activeRegisterID: active?.id
            )?.decisionSource?.includesRevisionInstruction == true,
            selectedLanguageID: languageID,
            detectedLanguageID: DraftLanguage.familyID(for: message.languageDetected),
            context: context
        )
    }

    /// Builds the panel model for a compose draft, keyed off the first
    /// recipient (nil recipient → picker only, no resolved card). The
    /// default language is the recipient's dominant language preference.
    @MainActor
    static func forCompose(draft: Draft, recipient: String?, context: ModelContext) -> StyleRegisterPanelModel {
        let recipientLanguage = recipient.flatMap {
            RecipientDraftLanguageResolver.preferredLanguage(
                accountID: draft.composeFromAccountID,
                correspondentAddress: $0,
                context: context
            )
        }
        let languageID = DraftLanguage.familyID(for: draft.languageID) ?? recipientLanguage
        let explicitID = draft.pendingStyleRegisterID ?? draft.styleRegisterID
        let explicit = explicitID
            .flatMap {
                StyleRegisterResolver.register(withID: $0, language: languageID, context: context)
            }
        let resolution: StyleResolution?
        if explicit == nil, let recipient, !recipient.isEmpty {
            resolution = StyleRegisterResolver.resolution(
                forComposeRecipient: recipient,
                language: languageID,
                context: context
            )
        } else {
            resolution = nil
        }
        let resolved = explicit ?? resolution?.register
        let hasGeneratedBody = (draft.revisions ?? []).isEmpty == false
        let isStyleAdjustmentPending = resolved.map {
            draft.pendingStyleControlSnapshot?.registerID == $0.id
        } ?? false
        return build(
            active: resolved,
            isExplicit: explicit != nil,
            resolutionReason: resolution?.reason,
            account: fetchAccount(id: draft.composeFromAccountID, context: context),
            isRestylePending: draft.pendingStyleRegisterID != nil && hasGeneratedBody,
            selectedStyleAxes: selectedStyleAxes(
                draft: draft,
                activeRegisterID: resolved?.id,
                defaults: resolved?.styleAxes
            ),
            isStyleAdjustmentPending: isStyleAdjustmentPending,
            isApplyingStyleAdjustment:
                ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
                    pendingInstruction: draft.pendingInstruction,
                    hasPendingStyleAdjustment: isStyleAdjustmentPending,
                    isGenerationBlocked:
                        ComposerGenerationTaskPresentation.isGenerationBlocked(draft),
                    isRegeneratingExistingDraft:
                        draft.resolvedStage == DraftStage.generating
                            && !draft.orderedRevisions.isEmpty
                ),
            isInstructionDerivedCustomStyle: selectedStyleControlSnapshot(
                draft: draft,
                activeRegisterID: resolved?.id
            )?.decisionSource?.includesRevisionInstruction == true,
            selectedLanguageID: languageID,
            detectedLanguageID: recipientLanguage,
            context: context
        )
    }

    @MainActor
    private static func build(
        active: StyleRegister?,
        isExplicit: Bool,
        resolutionReason: StyleResolutionReason?,
        account: Account?,
        isRestylePending: Bool,
        selectedStyleAxes: StyleAxisValues?,
        isStyleAdjustmentPending: Bool,
        isApplyingStyleAdjustment: Bool,
        isInstructionDerivedCustomStyle: Bool,
        selectedLanguageID: String?,
        detectedLanguageID: String?,
        context: ModelContext
    ) -> StyleRegisterPanelModel {
        let allStoredRegisters = StyleRegisterResolver.allRegisters(context: context)
        let allActiveRegisters = allStoredRegisters.filter(\.isActive)
        let scoped = allActiveRegisters.filter {
            StyleRegisterResolver.covers($0, language: selectedLanguageID)
        }
        let choices = scoped.map {
            StyleRegisterChoice(
                id: $0.id,
                name: $0.name,
                summary: $0.summary,
                exemplarCount: $0.exemplarCount,
                kind: $0.isSavedCustomStyle ? .savedCustom : .learned,
                canDelete: scoped.count > 1
            )
        }
        func cardModel(_ register: StyleRegister, isExplicit: Bool,
                       resolutionReason: StyleResolutionReason? = nil) -> StyleRegisterCardModel {
            StyleRegisterCardModel(
                id: register.id,
                name: register.name,
                summary: register.summary,
                styleAxes: register.styleAxes,
                revision: register.revision,
                exemplarCount: register.exemplarCount,
                correspondentCount: register.correspondents.count,
                trainedPairCount: register.trainedPairCount,
                preferenceEventCount: register.resolvedPreferenceEventCount,
                kind: register.isSavedCustomStyle ? .savedCustom : .learned,
                isExplicit: isExplicit,
                resolutionReason: resolutionReason
            )
        }
        let card = active.map { cardModel($0, isExplicit: isExplicit, resolutionReason: resolutionReason) }
        let registerCards = allStoredRegisters
            .filter { StyleRegisterResolver.covers($0, language: selectedLanguageID) }
            .map { cardModel($0, isExplicit: true) }
        return StyleRegisterPanelModel(
            card: card,
            registerCards: registerCards,
            choices: choices,
            isRestylePending: isRestylePending,
            selectedStyleAxes: selectedStyleAxes,
            isStyleAdjustmentPending: isStyleAdjustmentPending,
            isApplyingStyleAdjustment: isApplyingStyleAdjustment,
            isInstructionDerivedCustomStyle: isInstructionDerivedCustomStyle,
            languageChoices: languageChoices(
                account: account,
                selectedID: selectedLanguageID,
                detectedID: detectedLanguageID
            ),
            selectedLanguageID: selectedLanguageID,
            hasAnyRegisters: !allActiveRegisters.isEmpty
        )
    }

    /// Projects an immutable generated version's style provenance over the
    /// live draft model. A nil override means that version used its register's
    /// calculated defaults. Pending live-draft adjustments never bleed into
    /// version history.
    func displayingVersion(
        styleRegisterID: UUID?,
        styleControlSnapshot: StyleControlSnapshot?
    ) -> StyleRegisterPanelModel {
        var projected = self
        let historicalRegisterID = styleControlSnapshot?.registerID ?? styleRegisterID
        projected.card = historicalRegisterID.flatMap { id in
            registerCards.first(where: { $0.id == id })
        }
        if let card = projected.card, let snapshot = styleControlSnapshot {
            projected.card = StyleRegisterCardModel(
                id: card.id,
                name: card.name,
                summary: card.summary,
                styleAxes: snapshot.baseAxes,
                revision: snapshot.registerRevision ?? card.revision,
                exemplarCount: card.exemplarCount,
                correspondentCount: card.correspondentCount,
                trainedPairCount: card.trainedPairCount,
                preferenceEventCount: card.preferenceEventCount,
                kind: card.kind,
                isExplicit: card.isExplicit,
                resolutionReason: card.resolutionReason
            )
        }
        projected.selectedStyleAxes = styleControlSnapshot?.effectiveAxes
        projected.isRestylePending = false
        projected.isStyleAdjustmentPending = false
        projected.isApplyingStyleAdjustment = false
        projected.isInstructionDerivedCustomStyle =
            styleControlSnapshot?.decisionSource?.includesRevisionInstruction == true
        return projected
    }

    var usesCustomStyle: Bool {
        if isInstructionDerivedCustomStyle { return true }
        guard let defaults = card?.styleAxes,
              let selected = selectedStyleAxes else { return false }
        return selected.differs(from: defaults, tolerance: 0.0051)
    }

    private static func selectedStyleControlSnapshot(
        draft: Draft?,
        activeRegisterID: UUID?
    ) -> StyleControlSnapshot? {
        guard let draft, let activeRegisterID else { return nil }
        if let pending = draft.pendingStyleControlSnapshot,
           pending.registerID == activeRegisterID {
            return pending
        }
        if let applied = draft.styleControlSnapshot,
           applied.registerID == activeRegisterID {
            return applied
        }
        return nil
    }

    private static func selectedStyleAxes(
        draft: Draft?,
        activeRegisterID: UUID?,
        defaults: StyleAxisValues?
    ) -> StyleAxisValues? {
        guard let draft, let activeRegisterID else { return defaults }
        if let pending = draft.pendingStyleControlSnapshot,
           pending.registerID == activeRegisterID {
            return pending.effectiveAxes ?? defaults
        }
        if let applied = draft.styleControlSnapshot,
           applied.registerID == activeRegisterID {
            return applied.effectiveAxes ?? defaults
        }
        return defaults
    }

    /// The language menu's entries: the account's draft languages (falling
    /// back to the app-global content languages until the user chooses
    /// account languages), with the detected/default language prepended as a
    /// one-off entry when the list doesn't include it. The selected id is
    /// always present so a persisted pick never disappears from its menu.
    private static func languageChoices(
        account: Account?,
        selectedID: String?,
        detectedID: String?
    ) -> [DraftLanguageChoice] {
        var ids = account?.draftLanguages ?? []
        if ids.isEmpty { ids = globalContentLanguageIDs() }

        var seen = Set<String>()
        var choices: [DraftLanguageChoice] = []
        for id in ids {
            guard let family = DraftLanguage.familyID(for: id),
                  seen.insert(family).inserted else { continue }
            choices.append(DraftLanguageChoice(
                id: family,
                name: DraftLanguage.displayName(for: family),
                isDetected: false
            ))
        }
        if let detectedID, !seen.contains(detectedID) {
            seen.insert(detectedID)
            choices.insert(DraftLanguageChoice(
                id: detectedID,
                name: DraftLanguage.displayName(for: detectedID),
                isDetected: true
            ), at: 0)
        }
        if let selectedID, !seen.contains(selectedID) {
            choices.insert(DraftLanguageChoice(
                id: selectedID,
                name: DraftLanguage.displayName(for: selectedID),
                isDetected: false
            ), at: 0)
        }
        return choices
    }

    /// The app-global content-language list (Settings → Languages) — the
    /// fallback inventory until the account has its own draft languages.
    private static func globalContentLanguageIDs() -> [String] {
        ContentLanguagesStore.modelSupportedIDs(
            from: OhiaSharedDefaults.store.data(forKey: ContentLanguagesStore.defaultsKey)
        )
    }

    @MainActor
    private static func fetchAccount(id: UUID?, context: ModelContext) -> Account? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

/// Plain-language content for the Style pane's dossier. It keeps three facts
/// distinct: why this register is active, what corpus established it, and
/// whether the trained adapter actually shaped this draft.
struct StyleDossierPresentation: Equatable {
    let provenance: String
    let styleReplyEvidence: String
    let correspondentEvidence: String
    let recipientEvidence: String?
    let personalizationState: String
    let overallTrainingEvidence: String

    init(card: StyleRegisterCardModel, personalization: PersonalizationDisplay) {
        if card.kind == .savedCustom {
            provenance = "Saved by you"
            let accepted = min(
                card.preferenceEventCount,
                StyleRegisterLifecycle.savedStylePromotionSends
            )
            styleReplyEvidence = "\(accepted) of \(StyleRegisterLifecycle.savedStylePromotionSends) accepted sends recorded toward learned status"
            correspondentEvidence = "Your slider settings define this style"
        } else {
            if card.isExplicit {
                provenance = "Chosen by you"
            } else {
                switch card.resolutionReason {
                case .lastChoice: provenance = "Your last choice for this correspondent"
                case .habit: provenance = "Your most-used style in this language"
                case .correspondence, nil: provenance = "Matched from your email with this correspondent"
                }
            }

            let emailNoun = card.exemplarCount == 1 ? "sent email" : "sent emails"
            styleReplyEvidence = "\(card.trainedPairCount) of \(card.exemplarCount) matching \(emailNoun) incorporated into training"

            let correspondentNoun = card.correspondentCount == 1 ? "correspondent" : "correspondents"
            correspondentEvidence = "\(card.correspondentCount) \(correspondentNoun) shaped this style"
        }

        switch personalization {
        case .base:
            recipientEvidence = nil
            personalizationState = "Base model for this draft"
            overallTrainingEvidence = "Personalization was not active"
        case let .personalized(_, totalPairs, correspondentReplies, correspondentName):
            let trimmedName = correspondentName.trimmingCharacters(in: .whitespacesAndNewlines)
            if correspondentReplies > 0, !trimmedName.isEmpty {
                let previousNoun = correspondentReplies == 1 ? "reply" : "replies"
                recipientEvidence = "\(correspondentReplies) previous \(previousNoun) to \(trimmedName)"
            } else {
                recipientEvidence = nil
            }
            personalizationState = "Active for this draft"
            let overallNoun = totalPairs == 1 ? "sent email" : "sent emails"
            overallTrainingEvidence = "Trained on \(totalPairs) \(overallNoun) overall"
        }
    }
}

enum StyleAxisControl: String, CaseIterable, Identifiable {
    static let displayRange = 1.0...10.0
    static let displayStep = 1.0

    case detail
    case formality
    case urgency
    case technicality
    case warmth
    case seriousness

    var id: String { rawValue }

    var label: String {
        switch self {
        case .detail: "Length"
        case .formality: "Formality"
        case .urgency: "Urgency"
        case .technicality: "Technicality"
        case .warmth: "Warmth"
        case .seriousness: "Seriousness"
        }
    }

    var lowLabel: String {
        switch self {
        case .detail: "Concise"
        case .formality: "Casual / direct"
        case .urgency: "Relaxed"
        case .technicality: "Plain"
        case .warmth: "Reserved"
        case .seriousness: "Humorous"
        }
    }

    var highLabel: String {
        switch self {
        case .detail: "Detailed"
        case .formality: "Formal / polite"
        case .urgency: "Urgent"
        case .technicality: "Technical / dense"
        case .warmth: "Warm / emotional"
        case .seriousness: "Serious"
        }
    }

    /// The control's icon on the closed Style column's rail.
    var symbolName: String {
        switch self {
        case .detail: "text.alignleft"
        case .formality: "building.columns"
        case .urgency: "timer"
        case .technicality: "gearshape.2"
        case .warmth: "heart"
        case .seriousness: "theatermasks"
        }
    }

    func value(in axes: StyleAxisValues) -> Double {
        switch self {
        case .detail: axes.detail
        case .formality: axes.formality
        case .urgency: axes.urgency
        case .technicality: axes.technicality
        case .warmth: axes.warmth
        case .seriousness: axes.seriousness
        }
    }

    func replacingValue(in axes: StyleAxisValues, with value: Double) -> StyleAxisValues {
        StyleAxisValues(
            detail: self == .detail ? value : axes.detail,
            formality: self == .formality ? value : axes.formality,
            urgency: self == .urgency ? value : axes.urgency,
            technicality: self == .technicality ? value : axes.technicality,
            warmth: self == .warmth ? value : axes.warmth,
            seriousness: self == .seriousness ? value : axes.seriousness
        )
    }

    func displayReading(in axes: StyleAxisValues) -> Int {
        displayReading(for: value(in: axes))
    }

    /// The 1–10 reading `delta` steps away from the current one, held to
    /// the slider's range; nil when the step would not move it.
    func steppedReading(_ delta: Int, in axes: StyleAxisValues) -> Int? {
        let current = displayReading(in: axes)
        let range = Int(Self.displayRange.lowerBound)...Int(Self.displayRange.upperBound)
        let stepped = min(range.upperBound, max(range.lowerBound, current + delta))
        return stepped == current ? nil : stepped
    }

    func normalizedValue(forDisplayValue displayValue: Double) -> Double {
        let point = min(10, max(1, Int(displayValue.rounded())))
        return Double(point - 1) / 9.0
    }

    private func displayReading(for value: Double) -> Int {
        min(10, max(1, Int((value * 9.0).rounded()) + 1))
    }

    /// Returns nil when the adjusted profile is at the calculated defaults
    /// as displayed by the ten-position controls. Distiller readings are not
    /// guaranteed to land exactly on a slider position (for example 0.723),
    /// so selecting the same visible position restores the exact calculated
    /// value instead of leaving an invisible override pending.
    func adjustedSelection(
        in axes: StyleAxisValues,
        value: Double,
        defaults: StyleAxisValues
    ) -> StyleAxisValues? {
        let defaultValue = self.value(in: defaults)
        let adjustedValue = displayReading(for: value) == displayReading(for: defaultValue)
            ? defaultValue
            : value
        let updated = replacingValue(in: axes, with: adjustedValue)
        return updated.differs(from: defaults) ? updated : nil
    }
}

// MARK: - Panel view

struct StyleRegisterPanel: View {
    let model: StyleRegisterPanelModel
    let personalization: PersonalizationDisplay
    /// The user picked a register from the picker.
    let onSelect: (UUID) -> Void
    /// The user saved the currently displayed unsaved Custom profile.
    let onSave: (String, StyleAxisValues) -> Void
    /// The user renamed a register (id, new name).
    let onRename: (UUID, String) -> Void
    /// The user confirmed deletion of an active register.
    let onDelete: (UUID) -> Void
    /// The user picked a draft language (canonical family id).
    let onSelectLanguage: (String) -> Void
    /// A draft-local slider profile, or nil when the user returned every
    /// control to this style's calculated defaults.
    let onStyleAxesChange: (StyleAxisValues?) -> Void
    /// Open state, toggle, and close chevron for the Composer's Style column.
    var columnControl: ComposerColumnControl? = nil

    @State private var renameTargetID: UUID?
    @State private var renameText: String = ""
    @State private var saveAxes: StyleAxisValues?
    @State private var saveText: String = ""
    @State private var deleteTarget: StyleRegisterChoice?

    var body: some View {
        GlassPane(
            accentColor: OhiaColors.chipActiveForeground,
            isForeground: false,
            horizontalPadding: columnControl?.isOpen == false
                ? ComposerColumn.railHorizontalPadding
                : ComposerColumn.openPanePadding
        ) {
            if let columnControl {
                ComposerColumnSlide(control: columnControl) {
                    openContent
                } rail: {
                    StyleRegisterRail(
                        model: model,
                        control: columnControl,
                        onSelect: onSelect,
                        onStyleAxesChange: onStyleAxesChange
                    )
                }
            } else {
                openContent
            }
        }
        .alert("Rename Style", isPresented: renameAlertBinding) {
            TextField("Style name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renameTargetID, !trimmed.isEmpty {
                    onRename(id, trimmed)
                }
                renameTargetID = nil
            }
            .disabled(!renameIsValid)
            Button("Cancel", role: .cancel) { renameTargetID = nil }
        } message: {
            Text("Use up to \(StyleRegisterDistiller.maxGeneratedNameCharacters) characters. Style discovery keeps this name while it still finds the style in your sent email.")
        }
        .alert("Save Custom Style", isPresented: saveAlertBinding) {
            TextField("Style name", text: $saveText)
            Button("Save") {
                let trimmed = saveText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let axes = saveAxes, !trimmed.isEmpty {
                    onSave(trimmed, axes)
                }
                saveAxes = nil
            }
            .disabled(!saveIsValid)
            Button("Cancel", role: .cancel) { saveAxes = nil }
        } message: {
            Text("Use up to \(StyleRegisterDistiller.maxGeneratedNameCharacters) characters. This style will be available for the selected language in every account.")
        }
        .alert("Delete Style", isPresented: deleteAlertBinding) {
            Button("Delete Style", role: .destructive) {
                if let id = deleteTarget?.id {
                    onDelete(id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pinned above the scroll so it stays on the header line the
            // other Composer columns share.
            ComposerColumnHeader(control: columnControl, columnTitle: "Style") {
                ComposerSectionHeader(title: "Style", symbolName: "signature", titleWeight: .bold)
            }
            // The title keeps the instrument's extra left inset; the chevron
            // sits at the pane inset like the other column headers.
            .padding(.leading, 8)

            // The column scrolls when the window is shorter than its controls,
            // so it never stretches the Composer row past the window and hides
            // the Decisions footer (Draft, Re-check sources) on a laptop display.
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Voice selectors share one aligned label column.
                if !model.languageChoices.isEmpty {
                    selectorRow(label: "Language") { languageMenu }
                }
                if let card = model.card {
                    selectorRow(label: "Style") { styleMenu }
                        .help(currentStyleHelp(card: card))
                } else {
                    selectorRow(label: "Style") { styleMenu }
                }

                voiceDescription

                if model.isRestylePending {
                    restylePendingRow
                }

                if let card = model.card {
                    StyleDossierSection(
                        presentation: StyleDossierPresentation(
                            card: card,
                            personalization: personalization
                        ),
                        defaults: card.styleAxes,
                        selected: model.selectedStyleAxes,
                        isAdjustmentPending: model.showsStyleAdjustmentPrompt,
                        onChange: onStyleAxesChange,
                        isPersonalized: isPersonalized
                    )
                } else {
                    StylePersonalizationSection(
                        state: basePersonalizationState,
                        evidence: basePersonalizationEvidence,
                        isPersonalized: isPersonalized
                    )
                }

                Spacer(minLength: 0)
            }
            // A touch more breathing room on the left/right than the pane's
            // own inset gives the instrument.
            .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Voice selectors

    /// One aligned selector row: a fixed-width label column plus a full-width
    /// emblem pulldown. Language and Style both use it so the two controls
    /// share a label column and a control width.
    private func selectorRow<MenuContent: View>(
        label: String,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 52, alignment: .leading)
            menu()
        }
    }

    /// The draft-language menu. The language scopes the style: registers,
    /// exemplars, and the generated text all follow it.
    private var languageMenu: some View {
        Menu {
            ForEach(model.languageChoices) { choice in
                Button {
                    onSelectLanguage(choice.id)
                } label: {
                    if choice.id == model.selectedLanguageID {
                        Label(languageMenuLabel(choice), systemImage: "checkmark")
                    } else {
                        Text(languageMenuLabel(choice))
                    }
                }
            }
        } label: {
            pulldownLabel(text: selectedLanguageName, size: 10)
        }
        .menuStyle(.button)
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 9, verticalPadding: 5))
        .menuIndicator(.hidden)
        .accessibilityLabel("Draft language")
        .accessibilityValue(selectedLanguageName)
    }

    /// The register picker, doubling as the Style selector. The active name
    /// never truncates — long style names wrap instead.
    private var styleMenu: some View {
        Menu {
            ForEach(model.choices) { choice in
                Button {
                    if choice.id == model.card?.id {
                        onStyleAxesChange(nil)
                    }
                    onSelect(choice.id)
                } label: {
                    HStack {
                        Label(choiceLabel(choice), systemImage: choice.kind.symbolName)
                        if !usesCustomStyle && choice.id == model.card?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .help(choice.kind.helpText)
            }

            if usesCustomStyle || model.card != nil {
                Divider()
            }
            if usesCustomStyle, let selectedStyleAxes = model.selectedStyleAxes {
                Button {
                    saveText = ""
                    saveAxes = selectedStyleAxes
                } label: {
                    Label("Save Custom Style…", systemImage: "slider.horizontal.3")
                }
                .help("Name and save these slider settings for this language")
            } else if let card = model.card, currentChoice != nil {
                Button {
                    renameText = card.name
                    renameTargetID = card.id
                } label: {
                    Label("Rename Style…", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteTarget = currentChoice
                } label: {
                    Label("Delete Style…", systemImage: "trash")
                }
                .disabled(currentChoice?.canDelete != true)
                .help(deleteStyleHelp)
            }
        } label: {
            pulldownLabel(
                text: displayedStyleName,
                size: 11,
                symbolName: displayedStyleSymbolName
            )
        }
        .menuStyle(.button)
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 9, verticalPadding: 5))
        .menuIndicator(.hidden)
        .disabled(model.choices.isEmpty)
        .accessibilityLabel("Writing style")
        .accessibilityValue(displayedStyleName)
    }

    private var usesCustomStyle: Bool {
        model.usesCustomStyle
    }

    private var displayedStyleName: String {
        usesCustomStyle ? "Custom" : model.card?.name ?? "Choose a style"
    }

    /// A full-width emblem pulldown label: generated and user-entered names are
    /// constrained to the two-line character budget before reaching this view.
    private func pulldownLabel(
        text: String,
        size: CGFloat,
        symbolName: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .allowsTightening(true)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedLanguageName: String {
        guard let id = model.selectedLanguageID else { return "Choose" }
        return model.languageChoices.first(where: { $0.id == id })?.name
            ?? DraftLanguage.displayName(for: id)
    }

    private func languageMenuLabel(_ choice: DraftLanguageChoice) -> String {
        choice.isDetected ? "\(choice.name) — detected" : choice.name
    }

    private func choiceLabel(_ choice: StyleRegisterChoice) -> String {
        if choice.kind == .savedCustom {
            return "\(choice.name) — saved custom"
        }
        return "\(choice.name) (\(choice.exemplarCount) sent \(choice.exemplarCount == 1 ? "email" : "emails"))"
    }

    // MARK: - Voice description

    /// Empty-state guidance when no style is resolved. A resolved style's
    /// description lives in the selector's hover help instead.
    @ViewBuilder
    private var voiceDescription: some View {
        if model.card == nil {
            if !model.choices.isEmpty {
                emptyStateText("No matched style for this message. Pick the voice to write in above.")
            } else if model.hasAnyRegisters {
                emptyStateText("No \(selectedLanguageName) style is available yet. Drafts in \(selectedLanguageName) use your base voice until a style is saved or learned.")
            } else {
                emptyStateText("No styles yet. Save a custom slider profile or send enough email for Ohia to learn one.")
            }
        }
    }

    private func emptyStateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(OhiaColors.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Personalization

    private var basePersonalizationState: String {
        switch personalization {
        case .personalized: "Active for this draft"
        case .base: "Base model for this draft"
        }
    }

    private var basePersonalizationEvidence: String {
        switch personalization {
        case let .personalized(_, totalPairs, _, _):
            let noun = totalPairs == 1 ? "sent email" : "sent emails"
            return "Trained on \(totalPairs) \(noun) overall"
        case .base:
            return "Personalization was not active"
        }
    }

    private var isPersonalized: Bool {
        if case .personalized = personalization { return true }
        return false
    }

    private var restylePendingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Rewriting in this style")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textSecondary)
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )
    }

    private var saveAlertBinding: Binding<Bool> {
        Binding(
            get: { saveAxes != nil },
            set: { if !$0 { saveAxes = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var renameIsValid: Bool {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= StyleRegisterDistiller.maxGeneratedNameCharacters
    }

    private var saveIsValid: Bool {
        let trimmed = saveText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= StyleRegisterDistiller.maxGeneratedNameCharacters
    }

    private var currentChoice: StyleRegisterChoice? {
        guard let id = model.card?.id else { return nil }
        return model.choices.first(where: { $0.id == id })
    }

    private var displayedStyleSymbolName: String? {
        if usesCustomStyle { return "slider.horizontal.3" }
        return model.card?.kind.symbolName
    }

    private func currentStyleHelp(card: StyleRegisterCardModel) -> String {
        if usesCustomStyle {
            return "Unsaved custom style — adjusted from \(card.name)"
        }
        return "\(card.kind.helpText)\n\n\(card.summary)"
    }

    private var deleteStyleHelp: String {
        guard currentChoice?.canDelete == true else {
            return "At least one style is required for \(selectedLanguageName)"
        }
        return "Remove this style from \(selectedLanguageName)"
    }

    private var deleteConfirmationMessage: String {
        guard let target = deleteTarget else { return "" }
        let scope = "your \(selectedLanguageName) style choices"
        switch target.kind {
        case .learned:
            return "\(target.name) is an active learned style based on your sent correspondence. Deleting it removes it from \(scope). Existing drafts keep their style history."
        case .savedCustom:
            return "\(target.name) is a saved custom style. Deleting it removes it from \(scope). Existing drafts keep their style history."
        }
    }
}

private struct StyleDossierSection: View {
    let presentation: StyleDossierPresentation
    let defaults: StyleAxisValues?
    let selected: StyleAxisValues?
    let isAdjustmentPending: Bool
    let onChange: (StyleAxisValues?) -> Void
    let isPersonalized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(presentation.provenance)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            StyleDossierDivider()
            StyleDossierHeading(text: "Style controls")
            if let defaults, let selected {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(StyleAxisControl.allCases) { axis in
                        StyleAxisSliderRow(
                            axis: axis,
                            defaults: defaults,
                            selected: selected,
                            onChange: { newValue in
                                onChange(axis.adjustedSelection(
                                    in: selected,
                                    value: newValue,
                                    defaults: defaults
                                ))
                            }
                        )
                    }
                }
                if isAdjustmentPending {
                    Label {
                        Text(selected.differs(from: defaults, tolerance: 0.0051)
                            ? "Regenerate to apply adjustments"
                            : "Regenerate to restore style defaults")
                            .font(OhiaTypography.cardDetail)
                            .fontWeight(.regular)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(OhiaColors.ohiaRed)
                }
            } else {
                Text("Calculating style defaults")
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.textTertiary)
            }

            StyleDossierDivider()
            StyleDossierHeading(text: "Evidence")
            VStack(alignment: .leading, spacing: 5) {
                StyleEvidenceLine(text: presentation.styleReplyEvidence)
                StyleEvidenceLine(text: presentation.correspondentEvidence)
                if let recipientEvidence = presentation.recipientEvidence {
                    StyleEvidenceLine(text: recipientEvidence)
                }
            }

            StylePersonalizationSection(
                state: presentation.personalizationState,
                evidence: presentation.overallTrainingEvidence,
                isPersonalized: isPersonalized
            )
        }
    }
}

private struct StyleAxisSliderRow: View {
    let axis: StyleAxisControl
    let defaults: StyleAxisValues
    let selected: StyleAxisValues
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(axis.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(OhiaColors.textSecondary)
                Spacer(minLength: 4)
                Text("\(reading)")
                    .foregroundStyle(OhiaColors.ohiaYellow)
                    .font(OhiaTypography.cardSignal)
            }
            Slider(
                value: Binding(
                    get: { Double(axis.displayReading(in: selected)) },
                    set: { onChange(axis.normalizedValue(forDisplayValue: $0)) }
                ),
                in: StyleAxisControl.displayRange,
                step: StyleAxisControl.displayStep
            )
            .controlSize(.mini)
            .tint(OhiaColors.chipActiveForeground)
            .accessibilityLabel(axis.label)
            .accessibilityValue("\(reading) out of 10; style default \(defaultReading)")
            HStack {
                Text(axis.lowLabel)
                Spacer(minLength: 4)
                Text(axis.highLabel)
            }
            .font(.system(size: 9))
            .foregroundStyle(OhiaColors.textDim)
        }
    }

    private var reading: Int {
        axis.displayReading(in: selected)
    }

    private var defaultReading: Int {
        axis.displayReading(in: defaults)
    }
}

private struct StylePersonalizationSection: View {
    let state: String
    let evidence: String
    let isPersonalized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            StyleDossierDivider()
            HStack {
                StyleDossierHeading(text: "Personalization")
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isPersonalized
                                     ? OhiaColors.chipActiveForeground
                                     : OhiaColors.textDim)
                    .accessibilityHidden(true)
            }
            Text(state)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPersonalized
                                 ? OhiaColors.chipActiveForeground
                                 : OhiaColors.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text(evidence)
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .help(isPersonalized
              ? "Personalized — a trained adapter shaped this draft"
              : "Base model — personalization did not shape this draft")
    }
}

private struct StyleDossierHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundStyle(OhiaColors.textTertiary)
    }
}

private struct StyleEvidenceLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(OhiaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StyleDossierDivider: View {
    var body: some View {
        Rectangle()
            .fill(OhiaColors.iconPillBorder)
            .frame(height: 0.5)
    }
}

// MARK: - Rail

/// The closed Style column: a monogram for each style in the draft's
/// language, the current one lit (marked with the sliders glyph while its
/// controls are adjusted away from its defaults); clicking a tile restyles
/// exactly as the Style menu does. Below, each style control as its icon and
/// 1–10 reading: click raises it, ⌥-click lowers it, scrolling over it steps
/// it, all the same change as moving the open column's slider. Nothing above
/// the controls changes size as they are adjusted, so a control never moves
/// out from under the pointer; the restyle spinner and the Regenerate mark
/// sit below them.
struct StyleRegisterRail: View {
    let model: StyleRegisterPanelModel
    let control: ComposerColumnControl
    let onSelect: (UUID) -> Void
    let onStyleAxesChange: (StyleAxisValues?) -> Void

    var body: some View {
        ComposerColumnRailBody(control: control, title: "Style", symbolName: "signature") {
            if !model.choices.isEmpty {
                tileList
            }

            if let defaults = model.card?.styleAxes, let selected = model.selectedStyleAxes {
                ComposerRailDivider()
                VStack(spacing: 6) {
                    ForEach(StyleAxisControl.allCases) { axis in
                        StyleAxisRailItem(
                            axis: axis,
                            defaults: defaults,
                            selected: selected,
                            onChange: onStyleAxesChange
                        )
                    }
                }
                if model.showsStyleAdjustmentPrompt {
                    ComposerRailAttentionMark(
                        notice: selected.differs(from: defaults, tolerance: 0.0051)
                            ? "Regenerate to apply adjustments"
                            : "Regenerate to restore style defaults"
                    )
                }
            }

            if model.isRestylePending {
                ComposerRailSpinner(tint: OhiaColors.iconPillForeground)
                    .frame(width: 12, height: 12)
                    .help("Rewriting in this style")
            }
        }
    }

    /// Tiles shown before the style list scrolls.
    static let visibleTileLimit = 5

    private var tileList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.choices) { choice in
                    styleTile(choice)
                }
            }
            // Room for the kind mark riding the top tile's corner.
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        // The style list scrolls on its own past `visibleTileLimit` tiles,
        // and is the part that gives way on a short window, so the controls
        // below always keep their place and their full size.
        .frame(minHeight: 0, maxHeight: Self.tileListHeight(tileCount: model.choices.count))
    }

    /// The style list's height at full size: its tiles up to
    /// `visibleTileLimit`, the gaps between them, and its vertical padding.
    /// It depends only on how many styles there are, never on whether the
    /// controls are adjusted.
    static func tileListHeight(tileCount: Int) -> CGFloat {
        let rows = min(tileCount, visibleTileLimit)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * StyleRegisterMonogramTile.height + CGFloat(rows - 1) * 8 + 8
    }

    private func styleTile(_ choice: StyleRegisterChoice) -> some View {
        let isCurrent = choice.id == model.card?.id
        let isAdjusted = isCurrent && model.usesCustomStyle
        return Button {
            // The same choice the Style menu makes: picking the style the
            // custom profile came from returns the controls to its defaults.
            if choice.id == model.card?.id {
                onStyleAxesChange(nil)
            }
            onSelect(choice.id)
        } label: {
            StyleRegisterMonogramTile(
                letters: StyleRegisterMonogram.letters(for: choice.name),
                kindSymbol: isAdjusted ? "slider.horizontal.3" : choice.kind.symbolName,
                isCurrent: isCurrent
            )
        }
        .buttonStyle(.plain)
        .help(isAdjusted
            ? "Unsaved custom style — adjusted from \(choice.name)\nClick to return to its settings"
            : Self.helpText(for: choice))
        .accessibilityLabel(choice.name)
        .accessibilityValue(isAdjusted ? "Current style, adjusted" : (isCurrent ? "Current style" : ""))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// A style's name, kind and summary, for its tile's tooltip.
    static func helpText(for choice: StyleRegisterChoice) -> String {
        [choice.name, choice.kind.helpText, choice.summary]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// The letters a style's rail tile shows: the first letters of its first two
/// words ("Warm Direct" reads "WD"), or the first two characters of a
/// one-word name ("Formal" reads "Fo", "丁寧" reads "丁寧").
enum StyleRegisterMonogram {
    static func letters(for name: String) -> String {
        let words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "·" }
        if words.count >= 2 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
        guard let word = words.first else { return "" }
        let pair = String(word.prefix(2))
        return pair.prefix(1).uppercased() + pair.dropFirst()
    }
}

/// A rounded-square tile on the Style rail: a style's monogram, lit when it
/// is the current style, with a mark in its corner — the style's kind, or
/// the sliders glyph while its controls are adjusted.
struct StyleRegisterMonogramTile: View {
    static let height: CGFloat = 30

    let letters: String
    let kindSymbol: String
    let isCurrent: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isCurrent ? OhiaColors.chipActiveForeground : OhiaColors.chipRestBorder,
                        lineWidth: isCurrent ? 1.5 : 1
                    )
                Text(letters)
                    .font(.system(size: 10.5, weight: .semibold))
                    .minimumScaleFactor(0.62)
                    .foregroundStyle(isCurrent ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
                    .padding(.horizontal, 3)
            }
            .frame(width: 34, height: 26)

            Image(systemName: kindSymbol)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(isCurrent ? OhiaColors.chipActiveForeground : OhiaColors.iconPillForeground)
                .padding(2)
                .background(Circle().fill(OhiaColors.composerPanelBackground))
                .offset(x: 5, y: -5)
        }
        .frame(width: ComposerColumn.railContentWidth, height: Self.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }
}

/// One style control on the Style rail: its icon over its 1–10 reading.
/// Click raises it one step, ⌥-click lowers it, scrolling over it steps it.
private struct StyleAxisRailItem: View {
    let axis: StyleAxisControl
    let defaults: StyleAxisValues
    let selected: StyleAxisValues
    let onChange: (StyleAxisValues?) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: axis.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.iconPillForeground)
                .frame(height: 15)
            Text("\(reading)")
                .font(OhiaTypography.cardSignal.monospacedDigit())
                .foregroundStyle(OhiaColors.ohiaYellow)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? OhiaColors.chipRestBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .gesture(TapGesture().modifiers(.option).onEnded { step(-1) })
        .onTapGesture { step(1) }
        .onHover { isHovering = $0 }
        .modifier(ScrollWheelStepping { step($0) })
        .help("\(axis.label) \(reading) of 10 · \(axis.lowLabel) to \(axis.highLabel)\nClick to raise, ⌥-click to lower, or scroll")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axis.label)
        .accessibilityValue("\(reading) out of 10; style default \(axis.displayReading(in: defaults))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var reading: Int {
        axis.displayReading(in: selected)
    }

    private func step(_ delta: Int) {
        guard let stepped = axis.steppedReading(delta, in: selected) else { return }
        onChange(axis.adjustedSelection(
            in: selected,
            value: axis.normalizedValue(forDisplayValue: Double(stepped)),
            defaults: defaults
        ))
    }
}

/// Turns scroll-wheel and trackpad scrolling over a view into whole steps.
/// SwiftUI has no scroll-wheel event, so a local event monitor watches
/// scrolls while the view is on screen and consumes only those whose pointer
/// is inside the view's own bounds; everything else passes through. The
/// action runs from the view's current state on the next update. Momentum
/// after a trackpad flick is swallowed, never stepped, so a flick moves a
/// value only as far as the fingers did.
private struct ScrollWheelStepping: ViewModifier {
    let onStep: (Int) -> Void
    @State private var source = ScrollWheelStepSource()

    func body(content: Content) -> some View {
        content
            .background(ScrollWheelStepAnchor(source: source))
            .onAppear { source.start() }
            .onDisappear { source.stop() }
            .onChange(of: source.tick) {
                let steps = source.takePendingSteps()
                if steps != 0 { onStep(steps) }
            }
    }
}

/// Marks the stepping view's bounds for the scroll monitor; never takes a
/// click or a scroll itself.
private struct ScrollWheelStepAnchor: NSViewRepresentable {
    let source: ScrollWheelStepSource

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        source.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        source.anchor = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@Observable
private final class ScrollWheelStepSource {
    private(set) var tick = 0
    @ObservationIgnored weak var anchor: NSView?
    @ObservationIgnored private var pendingSteps = 0
    @ObservationIgnored private var accumulator = ScrollWheelStepAccumulator()
    // Read by `deinit` as a last resort, should the view go without its
    // disappear callback; every other access is on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isOverAnchor(event) else { return event }
            guard event.momentumPhase.isEmpty else { return nil }
            if event.phase == .began {
                self.accumulator = ScrollWheelStepAccumulator()
            }
            guard let steps = self.accumulator.steps(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                isDirectionInverted: event.isDirectionInvertedFromDevice
            ) else { return event }
            if steps != 0 {
                self.pendingSteps += steps
                self.tick &+= 1
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        accumulator = ScrollWheelStepAccumulator()
        pendingSteps = 0
    }

    func takePendingSteps() -> Int {
        defer { pendingSteps = 0 }
        return pendingSteps
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func isOverAnchor(_ event: NSEvent) -> Bool {
        guard let anchor, let window = anchor.window, event.window === window else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }
}

/// Converts scroll deltas into whole steps: a wheel click is one step, and
/// trackpad travel steps once per `preciseDistance` points, starting afresh
/// when the fingers reverse. Up — the wheel rolled away, or fingers moved up
/// with natural scrolling on — is positive.
struct ScrollWheelStepAccumulator: Equatable {
    static let preciseDistance: CGFloat = 16

    private var travel: CGFloat = 0

    /// The steps one scroll event makes, or nil for a sideways scroll, which
    /// is left to the views behind.
    mutating func steps(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool, isDirectionInverted: Bool) -> Int? {
        guard abs(deltaY) >= abs(deltaX), deltaY != 0 else {
            return deltaX == 0 ? 0 : nil
        }
        let up = isDirectionInverted ? -deltaY : deltaY
        guard isPrecise else { return up > 0 ? 1 : -1 }
        if travel != 0, (travel > 0) != (up > 0) {
            travel = 0
        }
        travel += up
        let steps = Int((travel / Self.preciseDistance).rounded(.towardZero))
        travel -= CGFloat(steps) * Self.preciseDistance
        return steps
    }
}
