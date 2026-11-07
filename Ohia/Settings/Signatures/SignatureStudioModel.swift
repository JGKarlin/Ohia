// Ohia/Settings/Signatures/SignatureStudioModel.swift
// State machine for the signature design studio (Settings → Signatures →
// New Signature): contact form → tier cards → hand-edit → saved slot.

import AppKit
import Contacts
import Foundation
import OhiaCore
import OhiaML
import SwiftData
import SwiftUI

@Observable
@MainActor
final class SignatureStudioModel {

    enum Phase: Equatable {
        case fields
        case cards
        case editing
    }

    struct TierCard: Identifiable {
        var tier: SignatureTier
        var candidate: SignatureCandidate
        /// Rendered preview document (data: image URLs), computed once per
        /// candidate change — never per view evaluation. Nil = plain text.
        var previewHTML: String?
        /// True while a generate/regenerate/revise call for this tier runs.
        var isBusy = false
        /// True once the local model (not the deterministic template)
        /// produced the current candidate.
        var isModelDesigned = false
        var revisionText = ""
        var lastError: String?
        var attempt = 1
        /// Advances for every successfully returned model candidate, even
        /// when its bytes match the previous result, so the editable copy can
        /// distinguish a new result from an unchanged model value.
        var candidateRevision = 0

        var id: SignatureTier { tier }
    }

    // MARK: - Session state

    let account: Account
    /// Slot being edited in place, nil when designing a new signature.
    private(set) var editingSlot: SignatureSlot?
    /// Owner id for staged image files and `ohia-sig://` tokens until the
    /// session promotes them into a slot.
    let sessionID = UUID()

    private(set) var phase: Phase = .fields

    // Fields stage.
    var contact = SignatureContactFields()
    var format: SignatureFormat = .html
    var languageID: String
    private(set) var meCardAvailability: MeCardReader.Availability?
    private(set) var isLoadingMeCard = false

    // Image stage (lives on the fields step).
    private(set) var imageAsset: SignatureImageAsset?
    /// Additional images inserted directly into design-card editors. They
    /// remain staged together, but save-time attachment inspection selects
    /// only the assets referenced by the chosen tier.
    private(set) var editorImageAssets: [SignatureImageAsset] = []
    private(set) var imageSuggestion: SignatureImageClassifier.Suggestion?
    private(set) var imageImportError: String?
    private(set) var isImportingImage = false

    // Cards stage.
    private(set) var cards: [TierCard] = []
    private(set) var isGeneratingPass = false
    private(set) var generationStatusMessage: String?

    /// True while any generation is in flight — the opening pass, a
    /// regenerate, or a revision. Derived from the cards rather than tracked
    /// as its own flag, so it cannot fall out of step with them: every path
    /// that generates already marks its card busy and clears it in
    /// `applyOutcome`, success or failure.
    var isDesigning: Bool {
        isGeneratingPass || cards.contains(where: \.isBusy)
    }

    // Editing stage.
    var editorContent = NSAttributedString(string: "")
    var editorFormat: ComposerMessageFormat = .richText
    var slotName = ""
    var makeDefault = false
    private(set) var chosenTier: SignatureTier?
    private(set) var saveError: String?

    private let service: SignatureGenerationService?
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let assetStore = SignatureAssetStore()
    /// Designs the model has already produced this session, newest last.
    /// Fed back into every later generation so the variation engine avoids
    /// repeating an archetype. Bounded: the prompt suffix carries this, and
    /// an unbounded list would grow every regenerate until it crowded out
    /// the design grammar itself.
    private var designHistory: [SignatureDesignHistoryEntry] = []
    private static let designHistoryLimit = 6
    /// Every in-flight generation call's cancellation token.
    private var activeCancellations: [GenerationCancellation] = []
    /// Bumped whenever the cards rebuild or invalidate (Generate Designs,
    /// Back to Details); outcomes from an older epoch are dropped so a
    /// stale in-flight call can never write onto fresh cards.
    private var generationEpoch = 0

    /// True when the generation model can serve requests right now. The
    /// studio still works without it — cards fall back to the
    /// deterministic template composer; regenerate/revise are disabled.
    var isModelAvailable: Bool { service?.isAvailable ?? false }

    init(account: Account, services: AppServices?) {
        self.account = account
        self.service = services?.signatureGenerationService
        self.modelActivityStatusPublisher = services?.modelActivityStatusPublisher
        self.languageID = Self.defaultLanguageID(for: account)
    }

    /// Opens an existing slot directly in the editing pane (hand-edit,
    /// rename, re-preview; the generation context of its original session
    /// is gone, so revise/regenerate stay in the design flow).
    init(editing slot: SignatureSlot, account: Account, services: AppServices?) {
        self.account = account
        self.editingSlot = slot
        self.service = services?.signatureGenerationService
        self.modelActivityStatusPublisher = services?.modelActivityStatusPublisher
        self.languageID = Self.defaultLanguageID(for: account)
        self.phase = .editing
        self.slotName = slot.name
        self.makeDefault = account.defaultSignatureSlotID == slot.id
        self.format = slot.format
        self.editorFormat = slot.format == .plainText ? .plainText : .richText
        if slot.isRich, let html = slot.html {
            self.editorContent = SignatureHTMLImageCoding.attributedContent(
                html: html,
                ownerID: slot.id,
                assets: slot.images,
                store: assetStore
            )
        } else {
            self.editorContent = NSAttributedString(string: slot.plainText)
        }
        scheduleEditingPreviewRefresh(debounce: false)
    }

    /// Apple signature generation runs in-process rather than through the
    /// Qwen worker, so publish its live execution explicitly. Qwen already
    /// reports its own worker activity and must not be double-counted here.
    nonisolated static func withSignatureModelActivity<T>(
        engine: SignatureGenerationEngineKind,
        publisher: ModelActivityStatusPublisher?,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        let token: ModelActivityStatusPublisher.Token?
        if engine == .appleIntelligence {
            token = publisher?.begin(.designing, source: "apple-signature")
        } else {
            token = nil
        }
        defer {
            if let token {
                publisher?.end(token)
            }
        }
        return try await operation()
    }

    // MARK: - Language

    /// The languages the studio's Language picker offers: the account's
    /// drafting languages from Language Settings, or — matching that
    /// screen's inheritance rule — the global content languages when the
    /// account has no explicit list. The current selection is always
    /// included so an id from an older session can't strand the picker.
    var languageOptions: [String] {
        Self.languageOptions(
            draftLanguages: account.draftLanguages,
            contentLanguagesData: OhiaSharedDefaults.store.data(
                forKey: ContentLanguagesStore.defaultsKey
            ),
            currentLanguageID: languageID
        )
    }

    /// Full language name for a canonical id ("ja" → "Japanese"); an id
    /// outside the model-supported set falls back to the locale's own
    /// naming, then to the raw id.
    func languageDisplayName(_ id: String) -> String {
        LocalModelLanguageSupport.displayName(for: id)
            ?? Locale.current.localizedString(forLanguageCode: id)
            ?? id
    }

    static func languageOptions(
        draftLanguages: [String],
        contentLanguagesData: Data?,
        currentLanguageID: String
    ) -> [String] {
        var options = draftLanguages
        if options.isEmpty {
            options = ContentLanguagesStore.modelSupportedIDs(from: contentLanguagesData)
        }
        if !currentLanguageID.isEmpty, !options.contains(currentLanguageID) {
            options.append(currentLanguageID)
        }
        return options
    }

    /// First drafting language, else first inherited content language,
    /// else the system locale (canonicalized — the picker only offers
    /// model-supported languages), else English.
    static func defaultLanguageID(
        draftLanguages: [String],
        contentLanguagesData: Data?,
        localeLanguageID: String?
    ) -> String {
        if let first = draftLanguages.first { return first }
        if let inherited = ContentLanguagesStore.modelSupportedIDs(from: contentLanguagesData).first {
            return inherited
        }
        return localeLanguageID.flatMap { LocalModelLanguageSupport.canonicalLanguageID(for: $0) }
            ?? "en"
    }

    private static func defaultLanguageID(for account: Account) -> String {
        defaultLanguageID(
            draftLanguages: account.draftLanguages,
            contentLanguagesData: OhiaSharedDefaults.store.data(
                forKey: ContentLanguagesStore.defaultsKey
            ),
            localeLanguageID: Locale.current.language.languageCode?.identifier
        )
    }

    // MARK: - Me card

    func loadMeCard() {
        guard !isLoadingMeCard, meCardAvailability == nil else { return }
        isLoadingMeCard = true
        let fallbackName = account.primaryIdentity?.displayName ?? account.displayName
        // The address this signature's own account sends from — preferred
        // over anything the me card lists, since that is the address the
        // signature will actually accompany.
        let accountEmail = account.primaryIdentity?.address ?? account.emailAddress
        Task { [weak self] in
            if MeCardReader.authorizationStatus == .notDetermined {
                _ = await MeCardReader.requestAccess()
            }
            let result = await Task.detached(priority: .userInitiated) {
                MeCardReader.read(
                    fallbackName: fallbackName,
                    accountEmail: accountEmail
                )
            }.value
            await MainActor.run {
                guard let self else { return }
                self.contact = result.fields
                self.meCardAvailability = result.availability
                self.isLoadingMeCard = false
            }
        }
    }

    var meCardStatusLine: String? {
        switch meCardAvailability {
        case .available, nil:
            return nil
        case .noMeCard:
            return "No My Card is set in Contacts — prefilled from the account identity instead."
        case .accessDenied:
            return "Contacts access is off for Ohia — prefilled from the account identity instead."
        case .accessNotDetermined:
            return "Contacts access was not granted — prefilled from the account identity instead."
        }
    }

    // MARK: - Image

    func importImage(data: Data, fileName: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let (asset, suggestion) = try? await self.stageImage(
                data: data,
                fileName: fileName
            ) else { return }
            if let previous = self.imageAsset {
                self.discardSessionAsset(previous)
            }
            self.imageAsset = asset
            self.imageSuggestion = suggestion
            if self.format == .html { self.format = .htmlWithImages }
        }
    }

    /// Imports an image and returns its staged asset so the rich-text editor
    /// can insert it at the current caret. Unlike the fields-stage image,
    /// editor imports are additive: another tier may still reference an
    /// earlier image while the user compares designs.
    func importImageForEditing(
        data: Data,
        fileName: String
    ) async throws -> SignatureImageAsset {
        let (asset, _) = try await stageImage(data: data, fileName: fileName)
        editorImageAssets.append(asset)
        return asset
    }

    private func stageImage(
        data: Data,
        fileName: String
    ) async throws -> (SignatureImageAsset, SignatureImageClassifier.Suggestion) {
        guard !isImportingImage else { throw ImageImportError.alreadyInProgress }
        imageImportError = nil
        isImportingImage = true
        defer { isImportingImage = false }
        let store = assetStore
        let sessionID = sessionID

        // Vision (first-call model load included) and file I/O run off the
        // main actor — an image choice must never beachball Settings.
        let outcome: Swift.Result<(SignatureImageAsset, SignatureImageClassifier.Suggestion), Error> =
            await Task.detached(priority: .userInitiated) {
                Swift.Result {
                    let suggestion = try SignatureImageClassifier.suggestType(for: data)
                    let asset = try store.importImage(
                        data: data,
                        sourceFileName: fileName,
                        imageType: suggestion.type,
                        ownerID: sessionID
                    )
                    return (asset, suggestion)
                }
            }.value

        if Task.isCancelled {
            if case .success(let (asset, _)) = outcome {
                discardSessionAsset(asset)
            }
            throw CancellationError()
        }

        switch outcome {
        case .success(let (asset, suggestion)):
            return (asset, suggestion)
        case .failure(let error):
            imageImportError = "Could not use this image: \(error.localizedDescription)"
            throw error
        }
    }

    private enum ImageImportError: LocalizedError {
        case alreadyInProgress

        var errorDescription: String? {
            switch self {
            case .alreadyInProgress:
                "Another signature image is still being imported."
            }
        }
    }

    func overrideImageType(_ type: SignatureImageType) {
        guard var asset = imageAsset else { return }
        asset.imageTypeRaw = type.rawValue
        imageAsset = asset
    }

    func removeImage() {
        if let imageAsset {
            discardSessionAsset(imageAsset)
        }
        imageAsset = nil
        imageSuggestion = nil
        if format == .htmlWithImages { format = .html }
    }

    func discardEditorImage(_ asset: SignatureImageAsset) {
        guard editorImageAssets.contains(where: { $0.id == asset.id }) else { return }
        editorImageAssets.removeAll(where: { $0.id == asset.id })
        discardSessionAsset(asset)
    }

    private func discardSessionAsset(_ asset: SignatureImageAsset) {
        let fileManager = FileManager.default
        let fileURL = assetStore.fileURL(forOwner: sessionID, asset: asset)
        try? fileManager.removeItem(at: fileURL)
        let directory = assetStore.directory(forOwner: sessionID)
        if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
           contents.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }

    private var stagedImageAssets: [SignatureImageAsset] {
        var seen = Set<UUID>()
        return ([imageAsset].compactMap { $0 } + editorImageAssets).filter {
            seen.insert($0.id).inserted
        }
    }

    // MARK: - Generation pass

    private var designRequest: SignatureDesignRequest {
        SignatureDesignRequest(
            format: format,
            contact: contact,
            image: (format == .htmlWithImages ? imageAsset : nil).map {
                SignatureDesignRequest.ImageContext(asset: $0, ownerID: sessionID)
            },
            languageID: languageID,
            accountID: account.id
        )
    }

    var canGenerate: Bool {
        contact.value(for: .name) != nil && !(format == .htmlWithImages && imageAsset == nil)
    }

    /// Fields → cards. Every card seeds instantly from the deterministic
    /// template; when the model is available a sequential tier pass then
    /// replaces each card as its generation lands.
    func generateCards() {
        guard canGenerate else { return }
        invalidateGenerations()
        let request = designRequest
        cards = SignatureTier.allCases.map { tier in
            let candidate = SignatureTemplateComposer.compose(tier: tier, request: request)
            return TierCard(
                tier: tier,
                candidate: candidate,
                previewHTML: cardPreviewHTML(for: candidate)
            )
        }
        phase = .cards
        generationStatusMessage = nil
        guard let service, service.isAvailable else {
            generationStatusMessage = "The selected signature model is not ready — showing built-in designs. Regenerate and revisions need the model."
            return
        }
        runModelPass(request: request)
    }

    private func runModelPass(request: SignatureDesignRequest) {
        let epoch = generationEpoch
        let cancellation = GenerationCancellation()
        let activityPublisher = modelActivityStatusPublisher
        activeCancellations.append(cancellation)
        isGeneratingPass = true
        for index in cards.indices { cards[index].isBusy = true }

        let service = service
        Task { [weak self] in
            // History accumulates across the pass so each tier sees what the
            // earlier tiers chose and picks a different archetype. Read from
            // the model on the main actor between calls rather than kept in
            // a local, so a regenerate racing the pass is also accounted for.
            for tier in SignatureTier.allCases {
                if cancellation.isCancelled { break }
                let history = await MainActor.run { self?.designHistory ?? [] }
                let selectedEngine = SignatureGenerationEngineKind.selected()
                let outcome: Swift.Result<SignatureCandidate, Error> = await Task.detached(
                    priority: .userInitiated
                ) {
                    guard let service else {
                        return .failure(
                            TrainingEngineError.modelUnavailable("No generation engine.")
                        )
                    }
                    do {
                        return .success(try await Self.withSignatureModelActivity(
                            engine: selectedEngine,
                            publisher: activityPublisher
                        ) {
                            try await service.generateTier(
                                tier: tier,
                                request: request,
                                attempt: 1,
                                history: history,
                                cancellation: cancellation
                            )
                        })
                    } catch {
                        return .failure(error)
                    }
                }.value
                await MainActor.run {
                    self?.applyOutcome(outcome, tier: tier, epoch: epoch)
                }
            }
            await MainActor.run {
                guard let self, epoch == self.generationEpoch else { return }
                self.isGeneratingPass = false
                for index in self.cards.indices { self.cards[index].isBusy = false }
            }
        }
    }

    /// Drops outcomes from an older card generation (Generate Designs or
    /// Back to Details ran since the call started).
    private func applyOutcome(
        _ outcome: Swift.Result<SignatureCandidate, Error>,
        tier: SignatureTier,
        epoch: Int
    ) {
        guard epoch == generationEpoch,
              let index = cards.firstIndex(where: { $0.tier == tier }) else { return }
        switch outcome {
        case .success(let candidate):
            cards[index].candidate = candidate
            cards[index].candidateRevision += 1
            cards[index].previewHTML = cardPreviewHTML(for: candidate)
            cards[index].isModelDesigned = true
            cards[index].lastError = nil
            record(candidate)
        case .failure(let error):
            cards[index].lastError = Self.displayMessage(for: error)
        }
        cards[index].isBusy = false
    }

    /// Adds a landed design to the session history the variation engine
    /// reads. Duplicate fingerprints collapse — re-listing the same design
    /// would spend prompt budget saying one thing twice.
    private func record(_ candidate: SignatureCandidate) {
        guard let entry = candidate.historyEntry else { return }
        designHistory.removeAll { $0.fingerprint == entry.fingerprint }
        designHistory.append(entry)
        if designHistory.count > Self.designHistoryLimit {
            designHistory.removeFirst(designHistory.count - Self.designHistoryLimit)
        }
    }

    func regenerate(tier: SignatureTier) {
        guard let service, service.isAvailable,
              let index = cards.firstIndex(where: { $0.tier == tier }),
              !cards[index].isBusy else { return }
        let epoch = generationEpoch
        let request = designRequest
        let attempt = cards[index].attempt + 1
        let history = designHistory
        let selectedEngine = SignatureGenerationEngineKind.selected()
        let activityPublisher = modelActivityStatusPublisher
        cards[index].attempt = attempt
        cards[index].isBusy = true
        let cancellation = GenerationCancellation()
        activeCancellations.append(cancellation)
        Task { [weak self] in
            let outcome: Swift.Result<SignatureCandidate, Error> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return .success(try await Self.withSignatureModelActivity(
                        engine: selectedEngine,
                        publisher: activityPublisher
                    ) {
                        try await service.regenerate(
                            tier: tier,
                            request: request,
                            attempt: attempt,
                            history: history,
                            cancellation: cancellation
                        )
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                self?.applyOutcome(outcome, tier: tier, epoch: epoch)
            }
        }
    }

    func setRevisionText(_ text: String, for tier: SignatureTier) {
        guard let index = cards.firstIndex(where: { $0.tier == tier }) else { return }
        cards[index].revisionText = text
    }

    func revise(tier: SignatureTier, currentContent: NSAttributedString) {
        guard let service, service.isAvailable,
              let index = cards.firstIndex(where: { $0.tier == tier }),
              !cards[index].isBusy else { return }
        let instruction = cards[index].revisionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let epoch = generationEpoch
        let request = designRequest
        let current = revisionCandidate(
            from: cards[index].candidate,
            content: currentContent
        )
        let selectedEngine = SignatureGenerationEngineKind.selected()
        let activityPublisher = modelActivityStatusPublisher
        cards[index].isBusy = true
        let cancellation = GenerationCancellation()
        activeCancellations.append(cancellation)
        Task { [weak self] in
            let outcome: Swift.Result<SignatureCandidate, Error> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return .success(try await Self.withSignatureModelActivity(
                        engine: selectedEngine,
                        publisher: activityPublisher
                    ) {
                        try await service.revise(
                            tier: tier,
                            request: request,
                            currentOutput: current,
                            instruction: instruction,
                            cancellation: cancellation
                        )
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                guard let self else { return }
                self.applyOutcome(outcome, tier: tier, epoch: epoch)
                if case .success = outcome, epoch == self.generationEpoch,
                   let index = self.cards.firstIndex(where: { $0.tier == tier }) {
                    self.cards[index].revisionText = ""
                }
            }
        }
    }

    /// Builds the revision input from the text currently visible in the card
    /// editor. Metadata stays attached for design-history continuity, while
    /// the HTML/text bodies reflect the user's direct edits.
    func revisionCandidate(
        from candidate: SignatureCandidate,
        content: NSAttributedString
    ) -> SignatureCandidate {
        var result = candidate
        result.plainText = content.string.replacingOccurrences(of: "\u{fffc}", with: "")
        if format == .plainText {
            result.html = nil
        } else {
            result.html = SignatureHTMLImageCoding.exportFragmentHTML(
                content,
                ownerID: sessionID,
                assets: stagedImageAssets,
                linkPolicy: linkPolicy
            )
        }
        return result
    }

    // MARK: - Phase transitions

    private func invalidateGenerations() {
        generationEpoch += 1
        for cancellation in activeCancellations { cancellation.cancel() }
        activeCancellations.removeAll()
        isGeneratingPass = false
        // The history describes designs for the previous facts; carrying it
        // into a fresh pass would push the model away from archetypes the
        // user has not actually seen for these facts.
        designHistory.removeAll()
    }

    func backToFields() {
        invalidateGenerations()
        phase = .fields
    }

    func choose(tier: SignatureTier) {
        guard let card = cards.first(where: { $0.tier == tier }) else { return }
        chosenTier = tier
        editorFormat = format == .plainText ? .plainText : .richText
        if format != .plainText, let html = card.candidate.html {
            editorContent = SignatureHTMLImageCoding.attributedContent(
                html: html,
                ownerID: sessionID,
                assets: imageAsset.map { [$0] } ?? [],
                store: assetStore
            )
        } else {
            editorContent = NSAttributedString(string: card.candidate.plainText)
        }
        if slotName.isEmpty {
            slotName = defaultSlotName(tier: tier)
        }
        phase = .editing
        scheduleEditingPreviewRefresh(debounce: false)
    }

    func backToCards() {
        guard editingSlot == nil else { return }
        phase = .cards
    }

    // MARK: - Preview

    /// Send-fidelity preview of the current editor content, recomputed on
    /// a debounce (a full Cocoa export + image base64 per keystroke would
    /// churn); the editor view schedules refreshes on content changes.
    private(set) var editingPreviewHTML: String?
    private var previewRefreshTask: Task<Void, Never>?

    func scheduleEditingPreviewRefresh(debounce: Bool = true) {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self?.editingPreviewHTML = self?.computeEditingPreviewHTML()
        }
    }

    private func computeEditingPreviewHTML() -> String? {
        guard editorFormat == .richText else { return nil }
        let ownerID = editingSlot?.id ?? sessionID
        let assets = editingSlot?.images ?? stagedImageAssets
        guard let fragment = SignatureHTMLImageCoding.exportFragmentHTML(
            editorContent,
            ownerID: ownerID,
            assets: assets,
            linkPolicy: linkPolicy
        ) else { return nil }
        return SignatureInlineImageEncoder.encodeForPreview(
            html: fragment, ownerID: ownerID, assets: assets, store: assetStore
        )
    }

    private func cardPreviewHTML(for candidate: SignatureCandidate) -> String? {
        guard let html = candidate.html else { return nil }
        return SignatureInlineImageEncoder.encodeForPreview(
            html: html,
            ownerID: sessionID,
            assets: imageAsset.map { [$0] } ?? [],
            store: assetStore
        )
    }

    /// Every URL the vetted contact lines justify — the website plus each
    /// social handle's derived profile URL. Hand-edits in the studio editor
    /// are sanitized against this too, so a link pasted into the editor
    /// survives only if a contact line backs it.
    ///
    /// Unscoped by tier on purpose: by this point the user has chosen a
    /// design and is editing it directly, so their own facts are all fair
    /// game. Tier scoping belongs to generation, where the model is the one
    /// being held to the tier.
    private var linkPolicy: SignatureHTMLSanitizer.LinkPolicy {
        SignatureHTMLSanitizer.LinkPolicy(allowedHTTPURLs: contact.allowedLinkURLs(in: .detailed))
    }

    // MARK: - Save

    /// Persists the edited signature into a slot (new, or the slot being
    /// edited). Returns true on success so the sheet can dismiss.
    func save(context: ModelContext) -> Bool {
        saveError = nil
        let name = slotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            saveError = "Give the signature a name."
            return false
        }

        do {
            if let slot = editingSlot {
                try update(slot: slot, name: name, context: context)
            } else {
                try createSlot(name: name, context: context)
            }
            return true
        } catch {
            saveError = "Could not save the signature: \(error.localizedDescription)"
            return false
        }
    }

    private func createSlot(name: String, context: ModelContext) throws {
        let slot = SignatureSlot(
            name: name,
            format: format,
            plainText: "",
            tier: chosenTier,
            sortOrder: (account.signatureSlots.map(\.sortOrder).max() ?? -1) + 1
        )
        slot.account = account
        let candidates = stagedImageAssets
        let assets = Self.referencedImageAssets(in: editorContent, candidates: candidates)
        if assets.isEmpty {
            assetStore.deleteAssets(ownerID: sessionID)
        } else {
            let referencedIDs = Set(assets.map(\.id))
            for asset in candidates where !referencedIDs.contains(asset.id) {
                discardSessionAsset(asset)
            }
            try assetStore.promote(sessionID: sessionID, toSlot: slot.id)
        }
        slot.images = assets
        applyEditorContent(to: slot, assets: assets)
        context.insert(slot)
        if makeDefault {
            account.defaultSignatureSlotID = slot.id
        }
        try context.save()
    }

    private func update(slot: SignatureSlot, name: String, context: ModelContext) throws {
        slot.name = name
        let assets = Self.referencedImageAssets(in: editorContent, candidates: slot.images)
        slot.images = assets
        applyEditorContent(to: slot, assets: assets)
        slot.updatedAt = Date()
        if makeDefault {
            account.defaultSignatureSlotID = slot.id
        } else if account.defaultSignatureSlotID == slot.id {
            account.defaultSignatureSlotID = nil
        }
        try context.save()
    }

    static func referencedImageAssets(
        in content: NSAttributedString,
        candidates: [SignatureImageAsset]
    ) -> [SignatureImageAsset] {
        guard content.length > 0, !candidates.isEmpty else { return [] }
        var referencedIDs = Set<UUID>()
        content.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: content.length)
        ) { value, range, _ in
            guard value is NSTextAttachment,
                  let rawID = content.attribute(
                      .ohiaSignatureAssetID,
                      at: range.location,
                      effectiveRange: nil
                  ) as? String,
                  let id = UUID(uuidString: rawID)
            else { return }
            referencedIDs.insert(id)
        }
        return candidates.filter { referencedIDs.contains($0.id) }
    }

    /// Editor → canonical stored forms. The fragment exporter sanitizes,
    /// so the stored HTML is already byte-stable under further edits.
    private func applyEditorContent(to slot: SignatureSlot, assets: [SignatureImageAsset]) {
        if editorFormat == .richText {
            slot.html = SignatureHTMLImageCoding.exportFragmentHTML(
                editorContent,
                ownerID: slot.id,
                assets: assets,
                linkPolicy: linkPolicy
            )
            slot.format = assets.isEmpty ? .html : .htmlWithImages
        } else {
            slot.html = nil
            slot.format = .plainText
        }
        // NSTextAttachment renders as U+FFFC in `.string` — image
        // placeholders have no plain-text equivalent and must not leak
        // into the text/plain alternative.
        slot.plainText = editorContent.string
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discards the staged session (files included) unless it was promoted.
    func cancelSession() {
        invalidateGenerations()
        previewRefreshTask?.cancel()
        guard editingSlot == nil else { return }
        assetStore.deleteAssets(ownerID: sessionID)
    }

    private func defaultSlotName(tier: SignatureTier) -> String {
        "\(format.displayName) — \(tier.displayName)"
    }

    private static func displayMessage(for error: Error) -> String {
        if error is CancellationError {
            return "Generation was cancelled."
        }
        // A TrainingEngineError already reads as a finished sentence — its
        // own description carries "Generation failed: …" — so prefixing it
        // again produced "Generation failed: Generation failed: …".
        if let engineError = error as? TrainingEngineError {
            return engineError.localizedDescription
        }
        return "Generation failed: \(error.localizedDescription)"
    }
}
