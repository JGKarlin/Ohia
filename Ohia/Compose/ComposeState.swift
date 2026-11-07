import SwiftUI
import SwiftData
import Foundation
import OhiaCore
import OhiaML
import OhiaScheduler

struct ComposeDraftCreationSeed: Equatable {
    let subject: String
    let to: [ComposeAddressEncoding.ParsedAddress]
    let cc: [ComposeAddressEncoding.ParsedAddress]
    let bcc: [ComposeAddressEncoding.ParsedAddress]
    let identityID: UUID?
    let signatureSlotID: UUID?
}

typealias ComposeAutomaticSourcePreviewCompiler = @Sendable (
    _ recipientAddress: String,
    _ accountID: UUID?,
    _ container: ModelContainer
) -> [ComposerSource]

/// Resolves a new message's output language before any model work begins.
/// Explicit per-draft intent wins; automatic evidence then narrows from the
/// correspondent to the sending account, global content settings, and only
/// finally the Mac's preferred languages.
enum ComposeDraftLanguageDefault {
    static func resolve(
        explicitLanguageID: String?,
        recipientLanguageID: String?,
        accountLanguageIDs: [String],
        globalLanguageIDs: [String],
        systemLanguageIDs: [String]
    ) -> String? {
        if let explicit = DraftLanguage.familyID(for: explicitLanguageID) {
            return explicit
        }
        if let recipient = DraftLanguage.familyID(for: recipientLanguageID) {
            return recipient
        }
        if let account = accountLanguageIDs.lazy.compactMap(
            LocalModelLanguageSupport.canonicalLanguageID(for:)
        ).first {
            return account
        }
        if let global = globalLanguageIDs.lazy.compactMap(
            LocalModelLanguageSupport.canonicalLanguageID(for:)
        ).first {
            return global
        }
        return systemLanguageIDs.lazy.compactMap(
            LocalModelLanguageSupport.canonicalLanguageID(for:)
        ).first
    }
}

/// View model for one compose draft. Owns the in-flight Draft row and the
/// transient editing state (raw text in the address input box, the AI
/// instruction box, in-progress question answers). Autosave fires ~750ms
/// after the last edit; AI requests save immediately and enqueue a
/// `.generateDraft` job so the generative worker writes the body back.
@Observable
@MainActor
final class ComposeState {
    /// The persisted draft this window is editing. Re-fetched on init by
    /// draftID so window restoration works after app relaunch.
    private(set) var draft: Draft?

    private var activeAttachmentImports: Set<ComposerAttachmentImport> = []
    private var hasPersistedDiscard = false

    var isImportingAttachments: Bool { !activeAttachmentImports.isEmpty }

    var inlinePhotoOwnerID: UUID? { draft?.id }

    var inlinePhotos: [ComposerInlinePhotoAsset] {
        ComposerInlinePhotoAssetCoding.decode(draft?.inlinePhotosJSON)
    }

    /// Shared rich-editor projection. The Draft continues to persist both a
    /// plain fallback and optional HTML; these fields preserve AppKit text
    /// attributes and prevent the polling reload from clobbering local edits.
    var editorText = NSAttributedString(string: "")
    var messageFormat: ComposerMessageFormat = .defaultNewMessageFormat
    private var projectedReplyText = ""
    private var projectedBodyHTML: String?
    private var projectedMessageFormat: ComposerMessageFormat = .defaultNewMessageFormat
    private var projectedEditorContent = NSAttributedString(string: "")
    private var hasUnsavedEditorChanges = false

    /// Revision metadata shared with the reply draft editor.
    private(set) var versions: [ComposerDraftVersion] = []
    var viewingVersionIndex: Int?
    private var liveEditorSnapshot: NSAttributedString?
    private var liveStylePanel: StyleRegisterPanelModel = .empty

    /// Raw text currently in the To address input (between commits to chips).
    var toInput: String = ""
    var ccInput: String = ""
    var bccInput: String = ""

    /// Parsed chips. Mirrors the JSON in `draft.composeToJSON` etc.
    var toChips: [ComposeAddressEncoding.ParsedAddress] = []
    var ccChips: [ComposeAddressEncoding.ParsedAddress] = []
    var bccChips: [ComposeAddressEncoding.ParsedAddress] = []

    /// Pieces in `*Input` that failed to parse — rendered with red underline.
    var invalidTo: [String] = []
    var invalidCc: [String] = []
    var invalidBcc: [String] = []

    /// All accounts available for the From picker. Loaded once at init.
    private(set) var availableAccounts: [Account] = []

    /// All identities across all accounts, flattened in account order.
    /// Source of truth for the From picker (identities, not accounts,
    /// drive the `From` header now).
    var availableIdentities: [Identity] {
        availableAccounts.flatMap { $0.identities }
    }

    /// Selected From account.
    var fromAccount: Account?

    /// Resolved `Identity` for the draft's `fromIdentityID`, if any.
    var fromIdentity: Identity? {
        guard let id = draft?.fromIdentityID else { return nil }
        return availableIdentities.first(where: { $0.id == id })
    }

    /// The saved slot the draft's signature tail carries, resolved
    /// against the current From account. Nil means unsigned.
    var resolvedSignatureSlot: SignatureSlot? {
        guard let draft else { return nil }
        return SignatureSlotResolver.slot(for: draft, account: fromAccount)
    }

    /// Slots offered by the composer's signature picker for the current
    /// From account.
    var availableSignatureSlots: [SignatureSlot] {
        fromAccount?.orderedSignatureSlots ?? []
    }

    private let context: ModelContext
    private let dispatcher: SendDispatcher
    @ObservationIgnored private var saveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveRevision: UInt64 = 0
    @ObservationIgnored private let autosaveDelay: @MainActor () async throws -> Void
    var hasPendingAutosave: Bool { saveDebounceTask != nil }
    private(set) var persistenceError: String?

    /// Leaving a read-only historical preview needs no save. Actual editor,
    /// header, asset and recipient-buffer changes must survive a failed flush.
    var hasPendingChangesToSave: Bool {
        hasUnsavedEditorChanges || hasPendingAutosave || context.hasChanges
            || !toInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bccInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !invalidTo.isEmpty || !invalidCc.isEmpty || !invalidBcc.isEmpty
    }
    /// The in-flight off-main automatic-source preview compile, if any. See
    /// `refreshAutomaticSourcePreview`.
    private var sourcePreviewTask: Task<Void, Never>?
    private var sourcePreviewCompileTask: Task<[ComposerSource], Never>?
    private let automaticSourcePreviewCompiler: ComposeAutomaticSourcePreviewCompiler

    init(
        draftID: UUID,
        context: ModelContext,
        automaticSourcePreviewCompiler: @escaping ComposeAutomaticSourcePreviewCompiler = {
            recipientAddress,
            accountID,
            container in
            let backgroundContext = ModelContext(container)
            return ComposeSourceCompiler.correspondenceSources(
                recipientAddress: recipientAddress,
                accountID: accountID,
                context: backgroundContext
            )
        },
        autosaveDelay: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(750))
        }
    ) {
        self.context = context
        self.dispatcher = SendDispatcher(context: context, jobQueue: JobQueue())
        self.automaticSourcePreviewCompiler = automaticSourcePreviewCompiler
        self.autosaveDelay = autosaveDelay

        // Load draft.
        let predicate = #Predicate<Draft> { $0.id == draftID }
        if let d = try? context.fetch(FetchDescriptor<Draft>(predicate: predicate)).first {
            self.draft = d
        }

        // Load accounts.
        self.availableAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []

        // Hydrate chip arrays from the persisted draft.
        if let d = self.draft {
            reconcileInlinePhotosOnFirstHydration(d)
            self.projectEditor(from: d)
            self.projectVersions(from: d)
            self.toChips = ComposeAddressEncoding.decode(d.composeToJSON).map {
                ComposeAddressEncoding.ParsedAddress(displayName: nil, asciiAddress: $0)
            }
            self.ccChips = ComposeAddressEncoding.decode(d.composeCcJSON).map {
                ComposeAddressEncoding.ParsedAddress(displayName: nil, asciiAddress: $0)
            }
            self.bccChips = ComposeAddressEncoding.decode(d.composeBccJSON).map {
                ComposeAddressEncoding.ParsedAddress(displayName: nil, asciiAddress: $0)
            }
            if let id = d.composeFromAccountID {
                self.fromAccount = availableAccounts.first(where: { $0.id == id })
            }
            // A recipient can be removed while the worker still owns an
            // automatic-source pass. If its later cross-process write restores
            // `pending` (with or without the `collectingSources` stage), the
            // orchestrator cannot run that pass because source determination
            // requires recipient + subject. The polling refresh constructs a
            // new ComposeState, making hydration the authoritative seam for
            // returning that stale state to address preparation.
            let hasSubject = d.composeSubject?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            if d.isAutomaticSourceResearchPending,
               (toChips.isEmpty || !hasSubject) {
                resetInitialSourcePreparation(on: d)
                try? context.save()
            }
            // Project any curated sources for immediate display.
            self.sources = ComposerSourceCoding.decode(d.sourcesJSON)
            self.interviewState = ComposerInterviewStateCoding.decode(d.interviewStateJSON)
            self.draftingInstructionText = d.composeInstruction ?? ""
            // Present every unfinished pre-draft state in Decisions, including
            // a newly materialized subject-only or recipient-only message that
            // still owes initial source preparation. Without this, direct
            // promotion can strand that gate behind the blank draft editor.
            switch d.resolvedStage {
            case DraftStage.drafted where !hasGeneratedDraft,
                 DraftStage.collectingSources,
                 DraftStage.evaluatingSources,
                 DraftStage.collectingAnswers:
                self.step = .decisions
            default:
                break
            }
            // A window can open or restore after the worker already owns
            // source research, without this instance ever seeing the button
            // tap that started it. Kick the UI-only preview for that case too.
            // ComposerView deliberately polls this phase in place so a
            // compile longer than one poll interval can still land.
            if d.isAutomaticSourceResearchPending,
               d.sourcesCuratedAt == nil,
               d.resolvedStage == DraftStage.collectingSources {
                refreshAutomaticSourcePreview(for: d)
            }
        }
        refreshStylePanel()
    }

    isolated deinit {
        saveDebounceTask?.cancel()
        // Detached tasks do not inherit cancellation from their waiter. Mark
        // both task handles when this editing state actually goes away; the
        // handler below remains a second propagation path for waiter-only
        // cancellation.
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
    }

    private func reconcileInlinePhotosOnFirstHydration(_ draft: Draft) {
        let decoded = ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON)
        let referenced = ComposerInlinePhotoEncoder.referencedAssets(
            html: draft.bodyHTML,
            ownerID: draft.id,
            assets: decoded
        )
        let previousJSON = draft.inlinePhotosJSON
        let reconciledJSON = ComposerInlinePhotoAssetCoding.encode(referenced)
        if reconciledJSON != previousJSON {
            draft.inlinePhotosJSON = reconciledJSON
            do {
                try context.save()
            } catch {
                draft.inlinePhotosJSON = previousJSON
                return
            }
        }
        ComposerInlinePhotoStore().prunePhotos(
            ownerID: draft.id,
            keeping: Set(referenced.map(\.id))
        )
    }

    // MARK: Factory

    /// Creates a blank user-compose Draft, persists it, and returns it.
    /// When `seed` is supplied, committed header values are applied before
    /// the first save and provider-sync enqueue. Saving here is load-bearing:
    /// the draft ID is the WindowGroup key, so a crash before the first
    /// autosave would otherwise leave an orphan window pointer.
    ///
    /// The draft is stamped with the resolved account's `primaryIdentity`
    /// and the identity's signature is materialized into `replyText` at
    /// creation time (Mail.app-style WYSIWYG) — the user sees the sig the
    /// moment the window opens, not after their first identity switch.
    static func createBlankDraft(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        draftID: UUID = UUID(),
        seed: ComposeDraftCreationSeed? = nil
    ) -> Draft {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let initialID = ComposeAddressEncoding.resolveInitialFromAccount(
            availableAccountIDs: accounts.map(\.id), defaults: defaults
        )
        let seededIdentity = seed?.identityID.flatMap { identityID in
            accounts.lazy.flatMap(\.identities).first(where: { $0.id == identityID })
        }
        let initialAccount = seededIdentity?.account
            ?? accounts.first(where: { $0.id == initialID })
        let identity = seededIdentity ?? initialAccount?.primaryIdentity
        let draft = Draft.userCompose(
            fromAccountID: initialAccount?.id,
            identityID: identity?.id
        )
        // A provisional header keeps this ID when its first commit persists
        // the draft, preserving the input view's identity and focus.
        draft.id = draftID
        draft.messageFormatRaw = ComposerMessageFormat.storedNewMessageFormat(in: defaults).rawValue
        // Stamp the account's default signature slot and materialize its
        // plain text; a rich slot's tail upgrades to attributed content at
        // the first editor mount (`projectEditor`).
        let signatureSlot = if let seed {
            initialAccount?.orderedSignatureSlots.first(where: { $0.id == seed.signatureSlotID })
        } else {
            initialAccount?.defaultSignatureSlot
        }
        if let signatureSlot {
            draft.signatureSlotID = signatureSlot.id
            if !signatureSlot.plainText.isEmpty {
                draft.replyText = SignatureSwapper.swap(in: "", newSignature: signatureSlot.plainText)
            }
        }
        if let seed {
            draft.composeSubject = seed.subject.isEmpty ? nil : seed.subject
            draft.composeToJSON = ComposeAddressEncoding.encode(seed.to.map(\.asciiAddress))
            draft.composeCcJSON = ComposeAddressEncoding.encode(seed.cc.map(\.asciiAddress))
            draft.composeBccJSON = ComposeAddressEncoding.encode(seed.bcc.map(\.asciiAddress))
        }
        // Stamp an explicit stage so a blank compose owes no generation. Without
        // it, `Draft.resolvedStage`'s reply-oriented "empty body ⇒ generating"
        // default would, on a signature-less account, make the compose pass try
        // to draft (and loop on the missing brief/recipient) and the editor open
        // in a disabled "writing…" state. The brief, captured at "Draft now",
        // is what flips the draft into `.generating`.
        draft.stageRaw = DraftStage.drafted
        context.insert(draft)
        try? context.save()
        try? ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)
        return draft
    }

    // MARK: Mutations

    func setBody(_ content: NSAttributedString) {
        // Defense in depth with the shared editor's disabled state:
        // while the generative worker owes this draft a body (first draft or a
        // pending revision), ignore stray editor writes so a cross-process
        // generation can't be clobbered by — or clobber — the editor binding.
        guard !isAwaitingModel else { return }
        guard let draft else { return }
        adoptViewedVersionIfNeeded(on: draft)
        editorText = NSAttributedString(attributedString: content)
        // Keep the keystroke path in memory. AppKit HTML export walks the
        // entire document, so project once when the debounce settles or an
        // explicit save/send/navigation boundary needs a durable body.
        hasUnsavedEditorChanges = true
        scheduleAutosave()
    }

    func updateInlinePhotos(_ photos: [ComposerInlinePhotoAsset]) {
        guard let draft else { return }
        draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(photos)
        hasUnsavedEditorChanges = true
        scheduleAutosave()
    }

    func setMessageFormat(_ format: ComposerMessageFormat) {
        guard !isAwaitingModel, format != messageFormat, let draft else { return }
        adoptViewedVersionIfNeeded(on: draft)
        messageFormat = format
        if format == .plainText {
            editorText = NSAttributedString(
                string: ComposerRichTextCodec.plainBodyProjection(of: editorText)
            )
        }
        hasUnsavedEditorChanges = true
        do {
            try projectPendingEditorChanges(on: draft)
        } catch {
            recordPersistenceFailure(error)
        }
        scheduleAutosave()
    }

    func setSubject(_ text: String) {
        guard let draft else { return }
        let subject = text.isEmpty ? nil : text
        guard draft.composeSubject != subject else { return }
        draft.composeSubject = subject
        if hasGeneratedDraft {
            clearInterviewState(on: draft)
        } else {
            resetInitialSourcePreparation(on: draft)
        }
        scheduleAutosave()
    }

    func setFromAccount(_ account: Account) {
        if let primary = account.primaryIdentity {
            setIdentity(primary)
        } else {
            let previousAccountID = draft?.composeFromAccountID
            self.fromAccount = account
            draft?.composeFromAccountID = account.id
            if previousAccountID != account.id, let draft {
                clearPendingStyleSelectionForAccountChange(on: draft)
            }
            refreshRecipientGroundingIfNeeded(
                previousPrimary: primaryRecipientAddress,
                force: previousAccountID != account.id
            )
            scheduleAutosave()
        }
    }

    /// Switches the draft's identity, updating the From account and the
    /// persisted `fromIdentityID`. Signatures are account-scoped: picking
    /// another identity on the same account keeps the tail untouched
    /// (preserving cursor/scroll state); crossing to another account
    /// re-stamps that account's default slot and swaps the tail.
    func setIdentity(_ new: Identity) {
        guard let draft else { return }
        let previousAccountID = draft.composeFromAccountID
        draft.fromIdentityID = new.id
        if let acct = new.account {
            draft.composeFromAccountID = acct.id
            self.fromAccount = acct
        }
        if draft.composeFromAccountID != previousAccountID {
            clearPendingStyleSelectionForAccountChange(on: draft)
            let slot = fromAccount?.defaultSignatureSlot
            draft.signatureSlotID = slot?.id
            applySignatureTail(attributedSignature(for: slot))
        }
        refreshRecipientGroundingIfNeeded(
            previousPrimary: primaryRecipientAddress,
            force: previousAccountID != draft.composeFromAccountID
        )
        scheduleAutosave()
    }

    /// A pending style/slider decision belongs to the account under which it
    /// was made. Keep the applied snapshot as truthful body provenance, but
    /// never carry an ungenerated choice across a From-account switch.
    private func clearPendingStyleSelectionForAccountChange(on draft: Draft) {
        draft.pendingStyleRegisterID = nil
        draft.pendingStyleControlSnapshot = nil
        refreshStylePanel()
    }

    /// Picker mutation: re-stamps the draft's slot (nil = "No Signature")
    /// and swaps the signature tail in place.
    func setSignatureSlot(_ slot: SignatureSlot?) {
        guard !isAwaitingModel, let draft else { return }
        guard draft.signatureSlotID != slot?.id else { return }
        draft.signatureSlotID = slot?.id
        applySignatureTail(attributedSignature(for: slot))
        scheduleAutosave()
    }

    // MARK: Signature tail plumbing

    /// The slot's signature as editor content: rich slots import their
    /// canonical HTML (image attachments included) when the draft is rich;
    /// plain slots and plain-format drafts use the plain text.
    private func attributedSignature(for slot: SignatureSlot?) -> NSAttributedString? {
        guard let slot else { return nil }
        if messageFormat == .richText, slot.isRich, let html = slot.html {
            return SignatureHTMLImageCoding.attributedContent(
                html: html,
                ownerID: slot.id,
                assets: slot.images,
                store: SignatureAssetStore()
            )
        }
        return slot.plainText.isEmpty ? nil : NSAttributedString(string: slot.plainText)
    }

    private func applySignatureTail(_ signature: NSAttributedString?) {
        guard let draft else { return }
        adoptViewedVersionIfNeeded(on: draft)
        editorText = ComposerRichTextCodec.swappingSignature(
            in: editorText,
            newAttributedSignature: signature
        )
        hasUnsavedEditorChanges = true
        do {
            try projectPendingEditorChanges(on: draft)
        } catch {
            recordPersistenceFailure(error)
        }
    }

    /// Sentinel-aware import: signature image attachments survive the trip
    /// into the editor when the resolved slot owns images.
    private func importEditorContent(
        plainText: String,
        html: String?,
        format: ComposerMessageFormat
    ) -> NSAttributedString {
        let slot = resolvedSignatureSlot
        return SignatureHTMLImageCoding.composerContent(
            plainText: plainText,
            html: html,
            format: format,
            ownerID: slot?.id ?? UUID(),
            assets: slot?.images ?? [],
            store: SignatureAssetStore(),
            inlinePhotoOwnerID: inlinePhotoOwnerID,
            inlinePhotos: inlinePhotos,
            inlinePhotoStore: ComposerInlinePhotoStore()
        )
    }

    /// Sentinel-aware export: signature image attachments become
    /// `ohia-sig://` tokens in the persisted HTML.
    private func exportEditorHTML(format: ComposerMessageFormat) -> String? {
        let slot = resolvedSignatureSlot
        return SignatureHTMLImageCoding.exportComposerBodyHTML(
            editorText,
            format: format,
            ownerID: slot?.id ?? UUID(),
            assets: slot?.images ?? [],
            inlinePhotoOwnerID: inlinePhotoOwnerID,
            inlinePhotos: inlinePhotos
        )
    }

    func commitTo() {
        let previousPrimary = primaryRecipientAddress
        let previousCount = toChips.count
        commit(input: &toInput, chips: &toChips, invalid: &invalidTo, persistTo: \.composeToJSON)
        if toChips.count != previousCount, let draft {
            clearInterviewState(on: draft)
        }
        refreshRecipientGroundingIfNeeded(previousPrimary: previousPrimary)
    }
    func commitCc() {
        let previousCount = ccChips.count
        commit(input: &ccInput, chips: &ccChips, invalid: &invalidCc, persistTo: \.composeCcJSON)
        if ccChips.count != previousCount {
            resetInitialSourcePreparationIfNeeded()
        }
    }
    func commitBcc() {
        let previousCount = bccChips.count
        commit(input: &bccInput, chips: &bccChips, invalid: &invalidBcc, persistTo: \.composeBccJSON)
        if bccChips.count != previousCount {
            resetInitialSourcePreparationIfNeeded()
        }
    }

    func removeToChip(at index: Int) {
        guard index < toChips.count else { return }
        let previousPrimary = primaryRecipientAddress
        toChips.remove(at: index)
        draft?.composeToJSON = ComposeAddressEncoding.encode(toChips.map(\.asciiAddress))
        if let draft { clearInterviewState(on: draft) }
        refreshRecipientGroundingIfNeeded(previousPrimary: previousPrimary)
        scheduleAutosave()
    }
    func removeCcChip(at index: Int) {
        guard index < ccChips.count else { return }
        ccChips.remove(at: index)
        draft?.composeCcJSON = ComposeAddressEncoding.encode(ccChips.map(\.asciiAddress))
        resetInitialSourcePreparationIfNeeded()
        scheduleAutosave()
    }
    func removeBccChip(at index: Int) {
        guard index < bccChips.count else { return }
        bccChips.remove(at: index)
        draft?.composeBccJSON = ComposeAddressEncoding.encode(bccChips.map(\.asciiAddress))
        resetInitialSourcePreparationIfNeeded()
        scheduleAutosave()
    }

    @discardableResult
    func addAttachmentPaths(_ paths: [String]) -> Bool {
        guard let draft, isLivePendingDraft(ownerID: draft.id) else { return false }
        guard !paths.isEmpty else { return true }
        var existing = ComposeAddressEncoding.decode(draft.deliverablesJSON)
        existing.append(contentsOf: paths)
        draft.deliverablesJSON = ComposeAddressEncoding.encode(existing)
        cancelPendingAutosave()
        do {
            try projectPendingEditorChanges(on: draft)
            try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
            try context.save()
            acceptCurrentEditorAsProjected()
            return true
        } catch {
            context.rollback()
            recordPersistenceFailure(error)
            return false
        }
    }

    func beginAttachmentImport() -> ComposerAttachmentImport? {
        guard let draft, isLivePendingDraft(ownerID: draft.id) else { return nil }
        let attachmentImport = ComposerAttachmentImport(ownerID: draft.id)
        activeAttachmentImports.insert(attachmentImport)
        return attachmentImport
    }

    func finishAttachmentImport(_ attachmentImport: ComposerAttachmentImport) {
        activeAttachmentImports.remove(attachmentImport)
    }

    func isDraftAssetImportValid(_ draftAssetImport: ComposerAttachmentImport) -> Bool {
        activeAttachmentImports.contains(draftAssetImport)
            && isLivePendingDraft(ownerID: draftAssetImport.ownerID)
    }

    @discardableResult
    func acceptImportedAttachmentPaths(
        _ paths: [String],
        for attachmentImport: ComposerAttachmentImport
    ) -> Bool {
        guard !Task.isCancelled,
              isDraftAssetImportValid(attachmentImport)
        else { return false }
        return addAttachmentPaths(paths)
    }

    /// An import owner is live only while the draft is pending in both this
    /// state's context (a confirm or discard already applied here but not yet
    /// saved) and the persisted store (a terminal transition saved elsewhere).
    private func isLivePendingDraft(ownerID: UUID) -> Bool {
        guard !hasPersistedDiscard, let draft, draft.id == ownerID, draft.status == .pending,
              !AccountDisconnectionRequest.isPending else { return false }
        let predicate = #Predicate<Draft> { $0.id == ownerID }
        let authoritativeContext = ModelContext(context.container)
        guard let stored = try? authoritativeContext.fetch(FetchDescriptor<Draft>(predicate: predicate)).first else {
            return false
        }
        return stored.status == .pending
    }

    @discardableResult
    func removeAttachment(at index: Int) -> Bool {
        guard let draft else { return false }
        var existing = ComposeAddressEncoding.decode(draft.deliverablesJSON)
        guard existing.indices.contains(index) else { return false }
        let removedPath = existing.remove(at: index)
        draft.deliverablesJSON = ComposeAddressEncoding.encode(existing)
        cancelPendingAutosave()
        do {
            try projectPendingEditorChanges(on: draft)
            try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
            try context.save()
            acceptCurrentEditorAsProjected()
            ComposerAttachmentStore().deleteAttachment(
                atOwnedPath: removedPath,
                ownerID: draft.id
            )
            return true
        } catch {
            context.rollback()
            recordPersistenceFailure(error)
            return false
        }
    }

    var attachmentPaths: [String] {
        ComposeAddressEncoding.decode(draft?.deliverablesJSON)
    }

    var canSend: Bool {
        fromAccount != nil
            && !toChips.isEmpty
            && invalidTo.isEmpty && invalidCc.isEmpty && invalidBcc.isEmpty
            && draft?.hasPendingStyleControlDecision != true
    }

    /// True when the draft has no recipients, no subject, no body, or
    /// attachments — safe to hard-delete on Discard with no confirmation.
    /// The body comes from the editor because its latest keystrokes may not
    /// have reached the Draft projection yet.
    var isEmpty: Bool {
        guard let draft else { return editorText.length == 0 }
        return draft.kind == .userCompose
            && plainEditorText.isEmpty
            && !ComposerInlinePhotoCoding.containsPhoto(in: editorText)
            && (draft.composeSubject?.isEmpty ?? true)
            && ComposeAddressEncoding.decode(draft.composeToJSON).isEmpty
            && ComposeAddressEncoding.decode(draft.composeCcJSON).isEmpty
            && ComposeAddressEncoding.decode(draft.composeBccJSON).isEmpty
            && ComposeAddressEncoding.decode(draft.deliverablesJSON).isEmpty
    }

    /// Drives `SendDispatcher.enqueueCompose`. UI gates this behind `canSend`,
    /// so the silent return for a missing draft / account is defensive only —
    /// callers should not see it under normal flow. Returns the new
    /// OutboxItem's id so a caller can track this specific send through to
    /// its later confirmation; nil only in the defensive no-op case above.
    @discardableResult
    func send() throws -> UUID? {
        guard let draft, let account = fromAccount else { return nil }
        guard let identity = account.resolveIdentity(for: draft.fromIdentityID) else {
            throw SendDispatcher.Error.noIdentity
        }
        try saveEditorNow()
        return try dispatcher.enqueueCompose(draft: draft, account: account, identity: identity)
    }

    @discardableResult
    func discardHard(
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore(),
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore(),
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) -> Bool {
        guard let draft else { return false }
        cancelPendingAutosave()
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
        let discarded = Self.discardDraft(
            draft,
            hardDeleteLocalDraft: true,
            context: context,
            attachmentStore: attachmentStore,
            inlinePhotoStore: inlinePhotoStore,
            stageDraftSync: stageDraftSync,
            saveContext: saveContext
        )
        if discarded {
            hasPersistedDiscard = true
            interviewState = nil
        } else {
            scheduleAutosave()
        }
        return discarded
    }

    @discardableResult
    func discardSoft(
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore(),
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore(),
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) -> Bool {
        guard let draft else { return false }
        cancelPendingAutosave()
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
        let discarded = Self.discardDraft(
            draft,
            hardDeleteLocalDraft: false,
            context: context,
            attachmentStore: attachmentStore,
            inlinePhotoStore: inlinePhotoStore,
            stageDraftSync: stageDraftSync,
            saveContext: saveContext
        )
        if discarded {
            hasPersistedDiscard = true
            interviewState = nil
        } else {
            scheduleAutosave()
        }
        return discarded
    }

    @discardableResult
    static func discardDraft(
        _ draft: Draft,
        hardDeleteLocalDraft: Bool,
        context: ModelContext,
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore(),
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore(),
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) -> Bool {
        let ownerID = draft.id
        let mutationSnapshot = DiscardMutationSnapshot(draft: draft)
        let preexistingInsertedSyncJobIDs = ComposerDiscardTransaction.insertedSyncJobIDs(
            in: context
        )
        let hasProviderLocation = draft.mailboxDraftFolderPath != nil
            && (draft.mailboxDraftUID != nil || draft.mailboxDraftMessageIDHeader != nil)
        do {
            if hardDeleteLocalDraft && !hasProviderLocation {
                context.delete(draft)
            } else {
                draft.status = .discarded
                draft.interviewStateJSON = nil
                draft.decisionResearchOverlayJSON = nil
                try stageDraftSync(draft, context)
            }
            try saveContext(context)
        } catch {
            mutationSnapshot.restore(context: context)
            ComposerDiscardTransaction.removeSyncJobsInserted(
                after: preexistingInsertedSyncJobIDs,
                context: context
            )
            return false
        }
        ComposerDraftAssetCleanup.deleteAll(
            ownerID: ownerID,
            attachmentStore: attachmentStore,
            inlinePhotoStore: inlinePhotoStore
        )
        return true
    }

    private struct DiscardMutationSnapshot {
        let draft: Draft
        let status: DraftStatus
        let interviewStateJSON: String?
        let decisionResearchOverlayJSON: String?
        let revisions: [DraftRevision]

        init(draft: Draft) {
            self.draft = draft
            status = draft.status
            interviewStateJSON = draft.interviewStateJSON
            decisionResearchOverlayJSON = draft.decisionResearchOverlayJSON
            revisions = draft.orderedRevisions
        }

        func restore(context: ModelContext) {
            ComposerDiscardTransaction.reinsertIfDeleted(draft, context: context)
            for revision in revisions {
                ComposerDiscardTransaction.reinsertIfDeleted(revision, context: context)
            }
            draft.status = status
            draft.interviewStateJSON = interviewStateJSON
            draft.decisionResearchOverlayJSON = decisionResearchOverlayJSON
            draft.revisions = revisions
            for revision in revisions {
                revision.draft = draft
            }
        }
    }

    // MARK: AI drafting

    /// Shared Decisions → Draft step used by replies and new messages.
    var step: ComposerStep = .draft
    private(set) var userSelectedStep: ComposerStep?

    /// Records an explicit rail selection so store polling cannot replace the
    /// surface the user chose. Workflow actions clear this intent when they
    /// deliberately advance the interview or draft lifecycle.
    func selectStep(_ selectedStep: ComposerStep) {
        if selectedStep != .draft, hasUnsavedEditorChanges {
            do { try saveEditorNow(adoptingViewedVersion: false) }
            catch { return }
        }
        userSelectedStep = selectedStep
        step = selectedStep
    }

    /// Makes a saved Decisions evaluation the live drafting basis. Body
    /// revisions remain untouched; if their inputs now differ, Regenerate
    /// becomes available through the existing body-baseline comparison.
    @discardableResult
    func restoreDecisionVersion(_ version: ComposerDecisionVersion) -> Bool {
        guard let draft, !isAwaitingModel else { return false }
        do { try saveEditorNow(adoptingViewedVersion: false) }
        catch { return false }
        if activeDecisionVersionID == version.id,
           !hasPendingDecisionInputChanges {
            selectStep(.decisions)
            return true
        }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        ComposerDecisionHistoryPersistence.restore(version, on: draft)
        do {
            try ComposerSourceContextMeasurementScheduler.stageMeasurement(
                draft: draft,
                context: context
            )
            try context.save()
        } catch {
            context.rollback()
            reloadFromStore()
            return false
        }
        interviewState = nil
        selectStep(.decisions)
        reloadFromStore()
        return true
    }

    private func transitionToWorkflowStep(_ nextStep: ComposerStep) {
        userSelectedStep = nil
        step = nextStep
    }

    /// Revision instruction shown beneath an existing generated draft.
    var instructionText: String = ""

    /// The current question's typed or picked answer, not yet submitted.
    var pendingAnswerDraft = ComposerPendingAnswerDraft()
    /// Asynchronous source additions still running (see `ComposerSourceHost`).
    var inFlightSourceAdditionCount = 0
    /// The writer-window overflow measurement already warned about.
    var warnedWriterOverflowFingerprint: String?

    /// First-draft guidance shown in the shared Decisions step.
    var draftingInstructionText: String = "" {
        didSet {
            let trimmed = draftingInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = trimmed.isEmpty ? nil : trimmed
            guard draft?.composeInstruction != instruction else { return }
            if let draft {
                if hasUnsavedEditorChanges {
                    do { try saveEditorNow(adoptingViewedVersion: false) }
                    catch { return }
                }
                let hadInterviewState = draft.interviewStateJSON != nil
                // Freeze the evaluated basis before changing its guidance;
                // otherwise the old graph would be recorded against the new
                // instruction and Re-check would appear unnecessary.
                clearInterviewState(on: draft)
                draft.composeInstruction = instruction
                if hadInterviewState {
                    draft.stageRaw = DraftStage.collectingSources
                    transitionToWorkflowStep(.decisions)
                }
            }
            scheduleAutosave()
        }
    }

    /// The complete persisted conditional interview. Current node, transcript,
    /// repair status, and completion are deterministic projections.
    private(set) var interviewState: ComposerInterviewState?
    /// The current reading language, refreshed on every store reload.
    /// Unanswered Draft Questions planned in another language wait for a
    /// Re-check.
    private(set) var readingLanguageIdentifier = ComposerQuestionLanguage.current().identifier

    /// The grounding evidence list, decoded from `Draft.sourcesJSON`. The
    /// compose auto-sources (recipient history) are compiled when the user
    /// enters the sources step; user-added entries are appended by the shared
    /// `ComposerSourcesSection`, which writes the Draft row and reloads.
    private(set) var sources: [ComposerSource] = []

    /// True once a backing Draft row exists (always, for compose — the row is
    /// created up front), satisfying `ComposerSourceHost`.
    var hasDraftRow: Bool { draft != nil }

    /// Recipient autocomplete catalog, sourced from ingested `Correspondent`
    /// rows (the WHO / Voices set), most-familiar first.
    private(set) var recipientSuggestions: [ComposeRecipientSuggestion] = []

    /// True while the generative worker owes this draft text (a first draft
    /// is generating, a revision instruction is pending, or a style switch
    /// awaits its restyled version).
    var isAwaitingModel: Bool {
        guard let draft, !isGenerationBlocked else { return false }
        if draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if isRestylePending { return true }
        return (draft.resolvedStage == DraftStage.generating && !isGenerationBlocked)
            || draft.resolvedStage == DraftStage.evaluatingSources
            || draft.isAutomaticSourceResearchPending
    }

    /// True specifically while a typed Revise instruction is pending — the
    /// narrower reason `ComposerDraftStep` uses to choose the word-morph
    /// revision overlay over the generic dot-on-a-line loader (which covers
    /// every other awaiting reason: first generation, Regenerate, restyle,
    /// source evaluation/research).
    var isAwaitingInstructionRevision: Bool {
        guard let draft else { return false }
        return draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A register switch is queued against an existing body. Before first
    /// generation a pending switch merely steers that pass, so it doesn't
    /// count as awaiting.
    var isRestylePending: Bool {
        guard let draft else { return false }
        return draft.pendingStyleRegisterID != nil && hasGeneratedDraft
    }

    var hasPendingStyleRegeneration: Bool {
        draft?.hasPendingStyleControlDecision == true
    }

    var awaitingReason: String {
        guard let draft else { return "" }
        if ComposerGenerationTaskPresentation.isApplyingStyleAdjustments(
            pendingInstruction: draft.pendingInstruction,
            hasPendingStyleAdjustment: draft.hasPendingStyleControlDecision,
            isGenerationBlocked: isGenerationBlocked,
            isRegeneratingExistingDraft:
                draft.resolvedStage == DraftStage.generating && hasGeneratedDraft
        ) {
            return ComposerGenerationTaskPresentation.applyingStyleAdjustments
        }
        if draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "applying your instruction"
        }
        if isRestylePending { return "rewriting in the chosen style" }
        if draft.isAutomaticSourceResearchPending { return "researching sources" }
        if draft.resolvedStage == DraftStage.evaluatingSources {
            return interviewProjection?.pendingRepairAnswer == nil
                ? "checking what your sources settle"
                : "deciding what else is needed"
        }
        if draft.resolvedStage == DraftStage.generating { return "writing your email" }
        return ""
    }

    var isGenerationBlocked: Bool {
        guard let draft else { return false }
        let now = Date()
        return DraftGenerationOrchestrator.hasContextPackWaitTimedOut(draft, now: now)
            || (draft.generationFailureCount != nil
                && (draft.nextGenerationAttemptAt ?? .distantPast) > now)
    }

    var generationBlockedReason: String {
        guard let draft else { return "" }
        return ComposerGenerationTaskPresentation.generationBlockedReason(draft)
    }

    /// The Style panel's register card + picker for this compose, keyed off
    /// the first committed recipient. Recomputed on the store poll and after
    /// style actions; equality-guarded against churn.
    private(set) var stylePanel: StyleRegisterPanelModel = .empty

    /// Training-influence readout for the Style panel, decoded from the
    /// generation-time snapshot (base until a first draft lands).
    var personalizationDisplay: PersonalizationDisplay {
        let snapshot = ComposerSession.decodePersonalization(
            draft?.personalizationJSON,
            decoder: JSONDecoder()
        )
        let recipient = toChips.first.map { $0.displayName ?? $0.asciiAddress } ?? "them"
        return PersonalizationDisplay.from(snapshot: snapshot, correspondentName: recipient)
    }

    func refreshStylePanel() {
        let liveModel: StyleRegisterPanelModel
        if let draft {
            liveModel = StyleRegisterPanelModel.forCompose(
                draft: draft,
                recipient: toChips.first?.asciiAddress,
                context: context
            )
        } else {
            liveModel = .empty
        }
        liveStylePanel = liveModel
        let model = versions
            .first(where: { $0.index == viewingVersionIndex })
            .map {
                liveModel.displayingVersion(
                    styleRegisterID: $0.styleRegisterID,
                    styleControlSnapshot: $0.styleControlSnapshot
                )
            }
            ?? liveModel
        if model != stylePanel {
            stylePanel = model
        }
    }

    /// Style picker: stamp the pending register switch. With a generated
    /// body the worker owes a restyled version; before first generation the
    /// choice steers the initial pass.
    func selectStyleRegister(_ id: UUID) {
        guard let draft, draft.status == .pending else { return }
        guard StyleRegisterResolver.register(
            withID: id,
            language: liveStylePanel.selectedLanguageID,
            context: context
        ) != nil else { return }
        adoptViewedVersionIfNeeded(on: draft)
        let activeID = draft.pendingStyleRegisterID ?? draft.styleRegisterID
        guard id != activeID else {
            // Re-picking the style already shown affirms it as the choice.
            if draft.chosenStyleRegisterID != id {
                draft.chosenStyleRegisterID = id
                try? context.save()
            }
            return
        }
        draft.pendingStyleRegisterID = id
        draft.chosenStyleRegisterID = id
        resetStyleAxesForNewDefault(on: draft)
        draft.clearGenerationBackoff()
        if hasGeneratedDraft {
            enqueueGenerate()
        } else {
            try? context.save()
        }
        refreshStylePanel()
    }

    /// Language picker: stamp the compose's output language. Styles are
    /// language-scoped, so a pending register pick is drained — promoted to
    /// the stamped choice when it covers the new language, dropped when it
    /// can't (leaving it pending would trigger a restyle-revision of the
    /// old-language body instead of the owed regeneration). With a generated
    /// body the worker owes a fresh pass from the brief in the new language;
    /// before first generation the choice steers the initial pass.
    func selectDraftLanguage(_ id: String) {
        guard let draft, draft.status == .pending else { return }
        adoptViewedVersionIfNeeded(on: draft)
        // Compare against the *effective* selection — the stamped choice or
        // the recipient-preference default the menu shows as checked — so
        // re-picking the checked entry never burns a regeneration.
        let current = DraftLanguage.familyID(for: draft.languageID)
            ?? toChips.first.flatMap {
                RecipientDraftLanguageResolver.preferredLanguage(
                    accountID: draft.composeFromAccountID,
                    correspondentAddress: $0.asciiAddress,
                    context: context
                )
            }
        guard let newID = DraftLanguage.familyID(for: id), newID != current else { return }
        draft.languageID = newID
        if let pendingID = draft.pendingStyleRegisterID {
            if StyleRegisterResolver.register(
                withID: pendingID,
                language: newID,
                context: context
            ) != nil {
                draft.styleRegisterID = pendingID
            }
            draft.pendingStyleRegisterID = nil
        }
        draft.clearGenerationBackoff()
        if hasGeneratedDraft {
            // Preserve authored guidance when changing only the language.
            draft.stageRaw = DraftStage.generating
            enqueueGenerate()
        } else {
            try? context.save()
        }
        refreshStylePanel()
    }

    func selectStyleAxes(_ axes: StyleAxisValues?) {
        guard let draft, draft.status == .pending else { return }
        adoptViewedVersionIfNeeded(on: draft)
        guard let card = liveStylePanel.card,
              let defaults = card.styleAxes else { return }
        draft.stageStyleControlDecision(
            effectiveAxes: axes,
            registerID: card.id,
            registerRevision: card.revision,
            defaults: defaults
        )
        do {
            try saveEditorNow()
        } catch {
            return
        }
        refreshStylePanel()
    }

    private func resetStyleAxesForNewDefault(on draft: Draft) {
        draft.pendingStyleControlSnapshot = nil
    }

    /// Saves the current slider profile as a named style for this draft's
    /// language, then selects it through the normal restyle path.
    func saveCustomStyle(name: String, axes: StyleAxisValues) throws {
        guard let draft else {
            throw StyleRegisterCatalog.CatalogError.styleNotFound
        }
        let register = try StyleRegisterCatalog.saveCustomStyle(
            name: name,
            axes: axes,
            languageID: liveStylePanel.selectedLanguageID,
            context: context
        )
        selectStyleRegister(register.id)
    }

    /// Rename a style in place. The catalog pins the name against future
    /// distillation and bumps the conditioning revision.
    func renameStyleRegister(id: UUID, newName: String) throws {
        try StyleRegisterCatalog.renameStyle(
            id: id,
            newName: newName,
            context: context
        )
        refreshStylePanel()
    }

    /// Soft-retires a style while preserving historical provenance. If it is
    /// selected, immediately move this draft to the required remaining style
    /// for the same language.
    func deleteStyleRegister(id: UUID) throws {
        guard let draft else {
            throw StyleRegisterCatalog.CatalogError.styleNotFound
        }
        let activeID = draft.pendingStyleRegisterID ?? draft.styleRegisterID
        let replacement = try StyleRegisterCatalog.deleteStyle(
            id: id,
            languageID: liveStylePanel.selectedLanguageID,
            context: context
        )
        if activeID == id {
            selectStyleRegister(replacement.id)
        } else {
            refreshStylePanel()
        }
    }

    /// Which face of the compose decisions/sources step is on screen.
    var decisionsPhase: ComposerDecisionsPhase {
        guard let draft else { return .curatingSources }
        if needsInitialSourcePreparation { return .curatingSources }
        if draft.isAutomaticSourceResearchPending { return .evaluating }
        switch draft.resolvedStage {
        case DraftStage.collectingSources: return .curatingSources
        case DraftStage.evaluatingSources:
            return interviewProjection?.pendingRepairAnswer == nil ? .evaluating : .decidingNext
        case DraftStage.collectingAnswers:
            if interviewState?.planningOutcome == .invalid { return .invalid }
            return interviewProjection?.currentNode == nil ? .readyToDraft : .answering
        default: return .drafting
        }
    }

    /// A model-written body exists (at least one generation produced a
    /// revision). Flips the instruction box from "what to draft" to "how to
    /// revise" and reveals Regenerate.
    var hasGeneratedDraft: Bool {
        !versions.isEmpty
    }

    var hasDraftVersions: Bool { hasGeneratedDraft }
    var draftVersionCount: Int { versions.count }
    var draftNoun: String { "email" }
    var needsInitialSourcePreparation: Bool {
        guard let draft else { return false }
        return !hasGeneratedDraft && draft.resolvedStage == DraftStage.drafted
    }
    var isDeterminingInitialSources: Bool {
        guard let draft else { return false }
        return !hasGeneratedDraft
            && draft.resolvedStage == DraftStage.collectingSources
            && draft.isAutomaticSourceResearchPending
    }
    var showsDraftGuidanceWhileCurating: Bool { !needsInitialSourcePreparation }

    var decisionsStepSubtitle: String {
        if needsInitialSourcePreparation { return "set recipients and subject" }
        if isDeterminingInitialSources { return "determining sources" }
        switch decisionsPhase {
        case .curatingSources: return "review sources"
        case .evaluating: return "checking sources"
        case .decidingNext: return "deciding what's next"
        case .answering: return "\(resolvedAnswerCount) decided"
        case .invalid: return "questions unavailable"
        case .readyToDraft: return "ready to draft"
        case .drafting: return "\(resolvedAnswerCount) decided"
        }
    }

    /// The first Continue requires the addressed message frame; after sources
    /// are determined, the second Continue additionally requires guidance.
    var canAdvanceFromSources: Bool {
        guard fromAccount != nil, !toChips.isEmpty else { return false }
        if needsInitialSourcePreparation {
            return draft?.composeSubject?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        return !draftingInstructionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func captureDraftGuidance(on draft: Draft) -> String? {
        let brief = draftingInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, !toChips.isEmpty, fromAccount != nil else { return nil }
        draft.composeInstruction = brief
        return brief
    }

    /// Sources step "Continue" / "Re-check sources": submit the curated
    /// sources for a fresh one-call conditional interview.
    func submitSourcesAndEvaluate() {
        guard let draft else { return }
        guard !draft.isAutomaticSourceResearchPending else { return }
        if needsInitialSourcePreparation {
            prepareInitialSources(on: draft)
            return
        }
        guard captureDraftGuidance(on: draft) != nil else { return }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        if resetAutomaticResearchIfInputChanged(draft: draft) {
            draft.beginAutomaticSourceResearchIfNeeded()
            draft.stageRaw = DraftStage.collectingSources
            draft.clearGenerationBackoff()
            transitionToWorkflowStep(.decisions)
            enqueueGenerate()
            return
        }
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        interviewState = nil
        draft.sourcesCuratedAt = draft.sourcesCuratedAt ?? Date()
        draft.stageRaw = DraftStage.evaluatingSources
        draft.clearGenerationBackoff()
        transitionToWorkflowStep(.decisions)
        enqueueGenerate()
    }

    /// Commit the current node. Closed options and skips advance without a
    /// model call; nonempty free text schedules its one repair pass.
    func commitInterviewAnswer(
        node: ComposerInterviewNode,
        selectedOptionID: String?,
        freeText: String?,
        skipped: Bool
    ) {
        guard let draft else { return }
        guard draft.resolvedStage == DraftStage.collectingAnswers
                || draft.resolvedStage == DraftStage.drafted else { return }
        do { try saveEditorNow(adoptingViewedVersion: false) }
        catch { return }
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              let updated = try? ComposerInterviewExecutor.commit(
                  nodeID: node.id,
                  selectedOptionID: selectedOptionID,
                  freeText: freeText,
                  skipped: skipped,
                  in: state
              ) else { return }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(updated)
        draft.decisionResearchOverlayJSON = nil
        ComposerSourceContextMeasurementScheduler.requestAfterDecisionChange(draft: draft, context: context)
        interviewState = updated
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        if ComposerInterviewExecutor.project(updated).pendingRepairAnswer != nil {
            draft.stageRaw = DraftStage.evaluatingSources
            draft.clearGenerationBackoff()
            transitionToWorkflowStep(.decisions)
            enqueueGenerate()
        } else {
            draft.stageRaw = DraftStage.collectingAnswers
            try? context.save()
            try? ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)
        }
    }

    /// Reopen a transcript entry and deterministically prune downstream state.
    func changeAnswer(nodeID: String) {
        guard let draft else { return }
        guard draft.resolvedStage == DraftStage.collectingAnswers
                || draft.resolvedStage == DraftStage.drafted,
              let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              let reopened = try? ComposerInterviewExecutor.reopen(
                  nodeID: nodeID,
                  in: state,
                  researchOverlay: ComposerDecisionResearchOverlayCoding.decode(
                      draft.decisionResearchOverlayJSON
                  )
              ) else { return }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(reopened.state)
        draft.decisionResearchOverlayJSON = ComposerDecisionResearchOverlayCoding.encode(
            reopened.researchOverlay
        )
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        ComposerSourceContextMeasurementScheduler.requestAfterDecisionChange(draft: draft, context: context)
        draft.stageRaw = DraftStage.collectingAnswers
        interviewState = reopened.state
        transitionToWorkflowStep(.decisions)
        try? context.save()
    }

    /// Decisions step CTA: persist answers and generate from the brief.
    func submitAnswersAndGenerate() {
        guard let draft else { return }
        guard !draft.isAutomaticSourceResearchPending else { return }
        guard captureDraftGuidance(on: draft) != nil else { return }
        if resetAutomaticResearchIfInputChanged(draft: draft) {
            draft.beginAutomaticSourceResearchIfNeeded()
        }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        draft.stageRaw = DraftStage.generating
        draft.clearGenerationBackoff()
        transitionToWorkflowStep(.draft)
        enqueueGenerate()
    }

    /// Instruction box after a draft exists: queue an AI revision.
    func submitRevision(_ instruction: String? = nil) {
        guard let draft, hasGeneratedDraft else { return }
        let text = (instruction ?? instructionText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        adoptViewedVersionIfNeeded(on: draft)
        draft.pendingInstruction = text
        draft.clearGenerationBackoff()
        instructionText = ""
        enqueueGenerate()
    }

    /// Fresh full pass over the same brief + decisions.
    func regenerate() {
        let isRetry = isGenerationBlocked
        guard let draft, isRetry || (hasGeneratedDraft && hasPendingRegenerationInputs) else { return }
        if isRetry, viewingVersionIndex != nil { showLiveDraft() }
        adoptViewedVersionIfNeeded(on: draft)
        if !isRetry {
            draft.stageRaw = DraftStage.generating
        }
        draft.clearGenerationBackoff()
        enqueueGenerate()
        refreshStylePanel()
    }

    @discardableResult
    private func resetAutomaticResearchIfInputChanged(draft: Draft) -> Bool {
        // The first pass runs before guidance and therefore fingerprints an
        // empty brief. Once guidance is captured, it becomes part of the
        // research identity so guidance-only tags trigger a fresh source pass.
        let fingerprint = ComposerResearchInputFingerprint.value(
            for: draft,
            brief: draft.composeInstruction ?? ""
        )
        guard draft.automaticSourceResearchInputFingerprint != fingerprint else { return false }
        // Drop the previous recipient's automatic sources now (cheap — no
        // I/O) so nothing addressed to the old recipient lingers even for
        // the moment before the fresh compile below lands; user-added
        // sources ride through untouched.
        let userAdded = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
        draft.sourcesJSON = userAdded.isEmpty ? nil : ComposerSourceCoding.encode(userAdded)
        draft.automaticSourceResearchStateRaw = nil
        draft.automaticSourceResearchInputFingerprint = fingerprint
        draft.sourcesCuratedAt = nil
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        interviewState = nil
        sources = userAdded
        refreshAutomaticSourcePreview(for: draft)
        return true
    }

    /// External removal must win over unsaved editor state and in-flight imports.
    @discardableResult
    func invalidateIfRemovedFromStore() -> Bool {
        guard let id = draft?.id else { return true }
        let authoritativeContext = ModelContext(context.container)
        let predicate = #Predicate<Draft> { $0.id == id }
        guard let count = try? authoritativeContext.fetchCount(FetchDescriptor<Draft>(predicate: predicate)),
              count == 0 else { return false }
        cancelPendingAutosave()
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
        activeAttachmentImports.removeAll()
        draft = nil
        return true
    }

    /// Re-projects question/stage and rich-editor state from the store so the
    /// worker's writes (questions seeded, body generated) land in the UI.
    func reloadFromStore() {
        guard !invalidateIfRemovedFromStore() else { return }
        let readingLanguage = ComposerQuestionLanguage.current().identifier
        if readingLanguage != readingLanguageIdentifier {
            readingLanguageIdentifier = readingLanguage
        }
        guard let id = draft?.id else { return }
        let predicate = #Predicate<Draft> { $0.id == id }
        guard let fresh = try? context.fetch(FetchDescriptor<Draft>(predicate: predicate)).first else {
            cancelPendingAutosave()
            draft = nil
            return
        }

        // During initial source research Composer deliberately keeps this
        // state alive so its detached preview can outlast a poll interval.
        // Always reconcile that pending/completed, uncurated phase through a
        // fresh context: cross-process SwiftData writes do not reliably
        // invalidate this context's already-registered Draft.
        if fresh.sourcesCuratedAt == nil,
           (fresh.isAutomaticSourceResearchPending
                || fresh.hasCompletedAutomaticSourceResearch) {
            let authoritativeContext = ModelContext(context.container)
            if let authoritative = try? authoritativeContext.fetch(
                FetchDescriptor<Draft>(predicate: predicate)
            ).first,
               authoritative.sourcesCuratedAt == nil,
               authoritative.automaticSourceResearchInputFingerprint
                    == fresh.automaticSourceResearchInputFingerprint {
                fresh.sourcesJSON = authoritative.sourcesJSON
                fresh.stageRaw = authoritative.stageRaw
                fresh.automaticSourceResearchStateRaw =
                    authoritative.automaticSourceResearchStateRaw
                fresh.sourceContextTokenCount = authoritative.sourceContextTokenCount
                fresh.sourceContextTokenLimit = authoritative.sourceContextTokenLimit
                fresh.sourceContextFitJSON = authoritative.sourceContextFitJSON
                fresh.sourceContextMeasurementRequestedAt =
                    authoritative.sourceContextMeasurementRequestedAt
                fresh.generationFailureCount = authoritative.generationFailureCount
                fresh.nextGenerationAttemptAt = authoritative.nextGenerationAttemptAt
                if authoritative.hasCompletedAutomaticSourceResearch {
                    sourcePreviewTask?.cancel()
                    sourcePreviewCompileTask?.cancel()
                }
            }
        }
        ComposerSourceContextMeasurementScheduler.requestIfNeeded(
            draft: fresh,
            context: context
        )
        draft = fresh

        let freshFormat = fresh.resolvedMessageFormat
        if fresh.replyText != projectedReplyText
            || fresh.bodyHTML != projectedBodyHTML
            || freshFormat != projectedMessageFormat {
            if !hasUnsavedEditorChanges {
                projectEditor(from: fresh)
            }
        }
        projectVersions(from: fresh)

        let decodedInterviewState = ComposerInterviewStateCoding.decode(
            fresh.interviewStateJSON
        )
        if decodedInterviewState != interviewState {
            interviewState = decodedInterviewState
        }

        // Equality-guarded so the poll tick doesn't churn the shared Sources
        // section when nothing changed.
        let decodedSources = ComposerSourceCoding.decode(fresh.sourcesJSON)
        let projectedSources: [ComposerSource]
        if fresh.isAutomaticSourceResearchPending,
           decodedSources.allSatisfy(\.isUserAdded) {
            // A same-state poll must not erase the UI-only correspondence
            // preview merely because the worker has not persisted its own
            // automatic selection yet. Always take the current manual rows
            // from the store, while retaining only this instance's automatic
            // preview until the authoritative pass supplies one.
            projectedSources = sources.filter { !$0.isUserAdded } + decodedSources
        } else {
            projectedSources = decodedSources
        }
        if projectedSources != sources {
            sources = projectedSources
        }

        // Surface seeded questions and return to the editor once a draft lands,
        // unless the user explicitly chose which side of the Composer to view.
        if userSelectedStep == nil {
            if fresh.resolvedStage == DraftStage.collectingAnswers,
               interviewState != nil, step == .draft, !hasGeneratedDraft {
                step = .decisions
            }
            if fresh.resolvedStage == DraftStage.drafted,
               step == .decisions,
               hasGeneratedDraft {
                step = .draft
            }
        }

        refreshStylePanel()
    }

    /// Loads the shared recipient autocomplete catalog. Recent message
    /// participants fill the gap while first-class Correspondent promotion is
    /// still pending, matching the reply Composer surface.
    func loadRecipientSuggestions() {
        recipientSuggestions = ComposerSession.recipientSuggestionCatalog(context: context)
    }

    /// A worker refresh replaces the Draft context, not the recipient
    /// catalog. Preserve this immutable projection instead of rebuilding and
    /// comparing thousands of suggestions on every store poll.
    func reuseRecipientSuggestions(from state: ComposeState) {
        recipientSuggestions = state.recipientSuggestions
    }

    /// Adds a recipient chosen from the autocomplete suggestions to the given
    /// field and persists it.
    func addRecipient(
        _ suggestion: ComposeRecipientSuggestion,
        to field: ComposeRecipientField.Kind,
        context: ModelContext
    ) {
        let parsed = ComposeAddressEncoding.ParsedAddress(displayName: suggestion.name, asciiAddress: suggestion.address)
        switch field {
        case .to:
            guard !toChips.contains(where: {
                $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame
            }) else { return }
            toChips.append(parsed)
            toInput = ""
            draft?.composeToJSON = ComposeAddressEncoding.encode(toChips.map(\.asciiAddress))
        case .cc:
            guard !ccChips.contains(where: {
                $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame
            }) else { return }
            ccChips.append(parsed)
            ccInput = ""
            draft?.composeCcJSON = ComposeAddressEncoding.encode(ccChips.map(\.asciiAddress))
        case .bcc:
            guard !bccChips.contains(where: {
                $0.asciiAddress.caseInsensitiveCompare(parsed.asciiAddress) == .orderedSame
            }) else { return }
            bccChips.append(parsed)
            bccInput = ""
            draft?.composeBccJSON = ComposeAddressEncoding.encode(bccChips.map(\.asciiAddress))
        }
        resetInitialSourcePreparationIfNeeded()
        scheduleAutosave()
    }

    func removeToChip(at index: Int, context: ModelContext) {
        removeToChip(at: index)
    }

    func removeCcChip(at index: Int, context: ModelContext) {
        removeCcChip(at: index)
    }

    func removeBccChip(at index: Int, context: ModelContext) {
        removeBccChip(at: index)
    }

    private var primaryRecipientAddress: String? {
        toChips.first?.asciiAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func clearInterviewState(on draft: Draft) {
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        interviewState = nil
    }

    private func refreshRecipientGroundingIfNeeded(
        previousPrimary: String?,
        force: Bool = false
    ) {
        let primary = primaryRecipientAddress
        guard force || primary != previousPrimary, let draft else { return }
        if hasGeneratedDraft {
            clearInterviewState(on: draft)
        } else {
            resetInitialSourcePreparation(on: draft)
        }
    }

    private func resetInitialSourcePreparationIfNeeded() {
        guard let draft else { return }
        if hasGeneratedDraft {
            clearInterviewState(on: draft)
        } else {
            resetInitialSourcePreparation(on: draft)
        }
    }

    private func resetInitialSourcePreparation(on draft: Draft) {
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
        let retained = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
        draft.sourcesJSON = retained.isEmpty ? nil : ComposerSourceCoding.encode(retained)
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        draft.decisionHistoryJSON = nil
        draft.sourcesCuratedAt = nil
        draft.automaticSourceResearchStateRaw = nil
        draft.automaticSourceResearchInputFingerprint = nil
        interviewState = nil
        sources = retained
        draft.stageRaw = DraftStage.drafted
        transitionToWorkflowStep(.decisions)
        draft.clearGenerationBackoff()
        refreshStylePanel()
    }

    private func prepareInitialSources(on draft: Draft) {
        guard fromAccount != nil,
              !toChips.isEmpty,
              draft.composeSubject?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false else {
            return
        }
        let recipientLanguageID = primaryRecipientAddress.flatMap {
            RecipientDraftLanguageResolver.preferredLanguage(
                accountID: draft.composeFromAccountID,
                correspondentAddress: $0,
                context: context
            )
        }
        let globalLanguageIDs = ContentLanguagesStore.modelSupportedIDs(
            from: OhiaSharedDefaults.store.data(forKey: ContentLanguagesStore.defaultsKey)
        )
        draft.languageID = ComposeDraftLanguageDefault.resolve(
            explicitLanguageID: draft.languageID,
            recipientLanguageID: recipientLanguageID,
            accountLanguageIDs: fromAccount?.draftLanguages ?? [],
            globalLanguageIDs: globalLanguageIDs,
            systemLanguageIDs: Locale.preferredLanguages
        )
        // `sourcesJSON` is deliberately left untouched here: `commitCc` /
        // `commitBcc` / `resetInitialSourcePreparation` already keep it
        // trimmed to user-added-only as the user edits chips/subject before
        // this point, which is exactly the right seed for the automatic
        // compile `refreshAutomaticSourcePreview` kicks off below.
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        draft.decisionHistoryJSON = nil
        draft.sourcesCuratedAt = nil
        draft.automaticSourceResearchStateRaw = nil
        draft.automaticSourceResearchInputFingerprint =
            ComposerResearchInputFingerprint.value(
                for: draft,
                brief: draft.composeInstruction ?? ""
            )
        draft.beginAutomaticSourceResearchIfNeeded()
        draft.stageRaw = DraftStage.collectingSources
        draft.clearGenerationBackoff()
        interviewState = nil
        transitionToWorkflowStep(.decisions)
        refreshStylePanel()
        enqueueGenerate()
        refreshAutomaticSourcePreview(for: draft)
    }

    /// Kicks off the automatic-source compile for `draft`'s recipient off
    /// the main actor and applies the result when it lands. This is a
    /// *preview* only — it feeds the force-expanded Sources panel shown
    /// while "Determining relevant sources" runs (`isDeterminingInitialSources`
    /// in `ComposerQuestionsStep`) — and is superseded moments later
    /// regardless by the generative worker's own token-budget-packed
    /// selection, which additionally folds in memory notes and (if enabled)
    /// Messages.
    ///
    /// Runs `ComposeSourceCompiler.correspondenceSources` — SwiftData
    /// fetches plus full message-body file reads — on a detached task
    /// against a fresh `ModelContext` on the same container, so a large
    /// received-mail body no longer blocks the button tap that triggers
    /// this the way it did before automatic sources stopped being
    /// pre-truncated to a fixed character count.
    private func refreshAutomaticSourcePreview(for draft: Draft) {
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()
        guard let primary = primaryRecipientAddress, !primary.isEmpty else { return }
        let container = context.container
        let accountID = draft.composeFromAccountID
        let draftID = draft.id
        let fingerprint = draft.automaticSourceResearchInputFingerprint
        let previewCompiler = automaticSourcePreviewCompiler
        // A plain nested `Task` can't cancel the detached child it awaits —
        // detached tasks don't inherit a parent's cancellation. Holding the
        // detached task explicitly and cancelling it from `onCancel` (the
        // same pairing `FrontPageDataController.loadArticleForFocus` uses)
        // means a rapid second chip edit stops the superseded fetch from
        // ever starting its SwiftData work, rather than merely discarding
        // its result once it lands (`Task.isCancelled` is cooperative — a
        // fetch already past the guard below still runs to completion).
        let compile = Task.detached(priority: .userInitiated) { () -> [ComposerSource] in
            guard !Task.isCancelled else { return [] }
            return previewCompiler(primary, accountID, container)
        }
        sourcePreviewCompileTask = compile
        sourcePreviewTask = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                let candidates = await compile.value
                guard !Task.isCancelled else { return }
                self?.applyAutomaticSourcePreview(candidates, draftID: draftID, fingerprint: fingerprint)
            } onCancel: {
                compile.cancel()
            }
        }
    }

    /// Test seam: awaits the in-flight automatic-source preview compile, if
    /// any. Production code never awaits this — the whole point of
    /// `refreshAutomaticSourcePreview` is that it's fire-and-forget from the
    /// caller's perspective — but tests need a deterministic way to wait for
    /// it instead of sleep-polling `sources`.
    func waitForPendingSourcePreview() async {
        await sourcePreviewTask?.value
    }

    /// Projects a background-compiled candidate preview into this view model,
    /// but only while it's still the answer to the question that was asked.
    /// Re-validates against a *fresh* context rather than trusting this
    /// session's possibly-stale registered `draft` — the generative worker
    /// runs in a separate process, and per `ComposerView
    /// .reloadComposeStateFromStore`'s own documented understanding,
    /// cross-process SwiftData writes don't reliably invalidate an
    /// already-registered model. Without this, a preview compile that's
    /// still in flight when the worker's real pass completes could read a
    /// stale "still pending" flag off `draft` and clobber the worker's
    /// properly packed selection with this cruder, unselected candidate
    /// list. Mirrors `DraftGenerationOrchestrator
    /// .initialComposeResearchIsCurrent`'s identical fresh-refetch pattern
    /// for the worker's own analogous check.
    ///
    /// This deliberately never writes `Draft.sourcesJSON`: once automatic
    /// research is pending, the generative worker exclusively owns source
    /// persistence. Keeping the preview UI-local also prevents a stale app
    /// context save from overwriting the worker's packed result after the
    /// fresh-context guard but before this method returns.
    private func applyAutomaticSourcePreview(
        _ candidates: [ComposerSource],
        draftID: UUID,
        fingerprint: String?
    ) {
        guard let draft, draft.id == draftID else { return }
        guard Self.automaticSourcePreviewIsStillCurrent(
            draftID: draftID,
            fingerprint: fingerprint,
            container: context.container
        ) else { return }
        let userAdded = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
        sources = candidates + userAdded
    }

    /// The fresh-context half of `applyAutomaticSourcePreview`'s guard.
    /// `internal`, not `private`, so it has direct test coverage instead of
    /// only being provable through a timing-dependent integration scenario.
    static func automaticSourcePreviewIsStillCurrent(
        draftID: UUID,
        fingerprint: String?,
        container: ModelContainer
    ) -> Bool {
        let freshContext = ModelContext(container)
        let predicate = #Predicate<Draft> { $0.id == draftID }
        guard let fresh = try? freshContext.fetch(
            FetchDescriptor<Draft>(predicate: predicate)
        ).first else {
            return false
        }
        return fresh.status == .pending
            && fresh.isAutomaticSourceResearchPending
            && fresh.automaticSourceResearchInputFingerprint == fingerprint
    }

    /// Commits any uncommitted text in the address inputs to chips.
    func commitAddressBuffers() {
        if !toInput.trimmingCharacters(in: .whitespaces).isEmpty { commitTo() }
        if !ccInput.trimmingCharacters(in: .whitespaces).isEmpty { commitCc() }
        if !bccInput.trimmingCharacters(in: .whitespaces).isEmpty { commitBcc() }
    }

    /// Synchronously commits the active compose projection for app
    /// termination. The debounce is cancelled before any model mutation, and
    /// the draft plus its provider-sync job are saved as one transaction.
    @discardableResult
    func flushForTermination(
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) throws -> ComposerRecipientCommitResult {
        let hasPendingChanges = hasPendingChangesToSave
        cancelPendingAutosave()
        sourcePreviewTask?.cancel()
        sourcePreviewCompileTask?.cancel()

        let draft: Draft
        do {
            draft = try currentPendingDraft()
        } catch EditorPersistenceFailure.draftNoLongerPending where !hasPendingChanges {
            persistenceError = nil
            return .valid
        } catch ComposerTerminationFlushError.missingComposeDraft where !hasPendingChanges {
            persistenceError = nil
            return .valid
        }
        let hadGeneratedDraft = hasGeneratedDraft
        // Quit is passive navigation, just like leaving a queue selection.
        // Browsing history must not replace the saved live body. Editing a
        // viewed version already adopts it before setting the dirty flag.
        let projectsEditor = viewingVersionIndex == nil && hasEdits
        let editorHTML = projectsEditor ? exportEditorHTML(format: messageFormat) : nil
        if projectsEditor, messageFormat == .richText, editorHTML == nil {
            let error = EditorPersistenceFailure.richTextExportFailed
            recordPersistenceFailure(error)
            throw error
        }
        let recipientProjection = terminationRecipientProjection(for: draft)

        if projectsEditor {
            draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: editorText)
            draft.messageFormatRaw = messageFormat.rawValue
            draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(inlinePhotos)
            draft.bodyHTML = editorHTML
            try ComposerManualEdit.recordSnapshot(on: draft, context: context)
        }

        if recipientProjection.didChangeDraft {
            if hadGeneratedDraft {
                ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
                draft.interviewStateJSON = nil
                draft.decisionResearchOverlayJSON = nil
            } else {
                let retained = ComposerSourceCoding.decode(draft.sourcesJSON).filter(\.isUserAdded)
                draft.sourcesJSON = retained.isEmpty ? nil : ComposerSourceCoding.encode(retained)
                draft.interviewStateJSON = nil
                draft.decisionResearchOverlayJSON = nil
                draft.decisionHistoryJSON = nil
                draft.sourcesCuratedAt = nil
                draft.automaticSourceResearchStateRaw = nil
                draft.automaticSourceResearchInputFingerprint = nil
                draft.stageRaw = DraftStage.drafted
                draft.clearGenerationBackoff()
            }
        }

        do {
            try stageDraftSync(draft, context)
            try saveContext(context)
        } catch {
            // The transaction did not save. Retain dirty headers, photo
            // metadata and staged mutations as well as the editor buffer so
            // cancelling Quit permits a complete retry without losing inputs.
            recordPersistenceFailure(error)
            throw error
        }

        acceptTerminationRecipientProjection(recipientProjection)
        if recipientProjection.didChangeDraft {
            interviewState = nil
            if !hadGeneratedDraft {
                sources = ComposerSourceCoding.decode(draft.sourcesJSON)
                transitionToWorkflowStep(.decisions)
            }
        }
        acceptCurrentEditorAsProjected()
        return recipientProjection.outcome
    }

    private func enqueueGenerate() {
        do {
            try saveEditorNow()
            try JobQueue().enqueue(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                context: context
            )
            try context.save()
        } catch {
            recordPersistenceFailure(error)
            NSLog("[Ohia] compose generate enqueue failed: \(String(reflecting: type(of: error)))")
        }
    }

    // MARK: Internals

    private func commit(
        input: inout String,
        chips: inout [ComposeAddressEncoding.ParsedAddress],
        invalid: inout [String],
        persistTo keyPath: ReferenceWritableKeyPath<Draft, String?>
    ) {
        let result = ComposeAddressEncoding.parseInput(input)
        chips.append(contentsOf: result.valid)
        invalid = result.invalid
        input = ""  // clear committed text; invalid pieces re-render via `invalid`
        draft?[keyPath: keyPath] = ComposeAddressEncoding.encode(chips.map(\.asciiAddress))
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        cancelPendingAutosave()
        guard let draftID = draft?.id, !hasPersistedDiscard else { return }
        let revision = autosaveRevision
        let delay = autosaveDelay
        saveDebounceTask = Task { @MainActor [weak self] in
            do {
                try await delay()
                try Task.checkCancellation()
            } catch is CancellationError {
                // Superseding edits and synchronous boundaries are expected.
                return
            } catch {
                guard let self, self.autosaveRevision == revision else { return }
                self.saveDebounceTask = nil
                self.recordPersistenceFailure(error)
                return
            }
            guard let self,
                  self.autosaveRevision == revision,
                  self.draft?.id == draftID else { return }
            // There is no suspension between the revision check and
            // projection/save: a newer edit cannot be accepted as saved
            // by this task. Old tasks never clear a newer task's handle.
            self.saveDebounceTask = nil
            do {
                try self.saveEditorNow(adoptingViewedVersion: false)
            } catch {
                return // saveEditorNow retains edits and exposes the failure.
            }
            if let draft = self.draft,
               self.needsInitialSourcePreparation,
               self.canAdvanceFromSources {
                self.prepareInitialSources(on: draft)
            }
        }
    }

    private func cancelPendingAutosave() {
        autosaveRevision &+= 1
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
    }

    /// Await the current debounce in focused tests without sleeping or
    /// bypassing its cancellation and draft-identity checks.
    func waitForPendingAutosave() async {
        await saveDebounceTask?.value
    }

    private struct TerminationRecipientProjection {
        let outcome: ComposerRecipientCommitResult
        let didChangeDraft: Bool
        let toChips: [ComposeAddressEncoding.ParsedAddress]
        let ccChips: [ComposeAddressEncoding.ParsedAddress]
        let bccChips: [ComposeAddressEncoding.ParsedAddress]
        let invalidTo: [String]
        let invalidCc: [String]
        let invalidBcc: [String]
        let toInput: String
        let ccInput: String
        let bccInput: String
    }

    private struct TerminationRecipientField {
        let chips: [ComposeAddressEncoding.ParsedAddress]
        let invalid: [String]
        let input: String
    }

    private func terminationRecipientProjection(for draft: Draft) -> TerminationRecipientProjection {
        let to = terminationRecipientField(input: toInput, chips: toChips, invalid: invalidTo)
        let cc = terminationRecipientField(input: ccInput, chips: ccChips, invalid: invalidCc)
        let bcc = terminationRecipientField(input: bccInput, chips: bccChips, invalid: invalidBcc)
        let toJSON = ComposeAddressEncoding.encode(to.chips.map(\.asciiAddress))
        let ccJSON = ComposeAddressEncoding.encode(cc.chips.map(\.asciiAddress))
        let bccJSON = ComposeAddressEncoding.encode(bcc.chips.map(\.asciiAddress))
        let didChangeDraft = draft.composeToJSON != toJSON
            || draft.composeCcJSON != ccJSON
            || draft.composeBccJSON != bccJSON

        if didChangeDraft {
            draft.composeToJSON = toJSON
            draft.composeCcJSON = ccJSON
            draft.composeBccJSON = bccJSON
        }

        return TerminationRecipientProjection(
            outcome: to.invalid.isEmpty && cc.invalid.isEmpty && bcc.invalid.isEmpty
                ? .valid
                : .invalid,
            didChangeDraft: didChangeDraft,
            toChips: to.chips,
            ccChips: cc.chips,
            bccChips: bcc.chips,
            invalidTo: to.invalid,
            invalidCc: cc.invalid,
            invalidBcc: bcc.invalid,
            toInput: to.input,
            ccInput: cc.input,
            bccInput: bcc.input
        )
    }

    private func terminationRecipientField(
        input: String,
        chips: [ComposeAddressEncoding.ParsedAddress],
        invalid: [String]
    ) -> TerminationRecipientField {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminationRecipientField(chips: chips, invalid: invalid, input: input)
        }
        let parsed = ComposeAddressEncoding.parseInput(input)
        var projected = chips
        for address in parsed.valid where !projected.contains(where: {
            $0.asciiAddress.caseInsensitiveCompare(address.asciiAddress) == .orderedSame
        }) {
            projected.append(address)
        }
        return TerminationRecipientField(
            chips: projected,
            invalid: parsed.invalid,
            input: ""
        )
    }

    private func acceptTerminationRecipientProjection(
        _ projection: TerminationRecipientProjection
    ) {
        toChips = projection.toChips
        ccChips = projection.ccChips
        bccChips = projection.bccChips
        invalidTo = projection.invalidTo
        invalidCc = projection.invalidCc
        invalidBcc = projection.invalidBcc
        toInput = projection.toInput
        ccInput = projection.ccInput
        bccInput = projection.bccInput
    }

    func saveEditorNow(
        adoptingViewedVersion: Bool = true,
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) throws {
        cancelPendingAutosave()
        do {
            let draft = try currentPendingDraft()
            if adoptingViewedVersion {
                adoptViewedVersionIfNeeded(on: draft)
            }
            try projectPendingEditorChanges(on: draft)
            try stageDraftSync(draft, context)
            try saveContext(context)
            acceptCurrentEditorAsProjected()
        } catch {
            // A failed save must leave the complete in-memory projection
            // dirty and retryable. In particular, do not accept stale Draft
            // fields as the editor baseline or discard unsaved headers.
            recordPersistenceFailure(error)
            throw error
        }
    }

    private enum EditorPersistenceFailure: LocalizedError {
        case draftNoLongerPending
        case richTextExportFailed

        var errorDescription: String? {
            switch self {
            case .draftNoLongerPending:
                "This draft is no longer available for editing. Your unsaved text remains in the editor."
            case .richTextExportFailed:
                "The formatted draft could not be saved. Your unsaved text remains in the editor."
            }
        }
    }

    private func currentPendingDraft() throws -> Draft {
        guard let draft else { throw ComposerTerminationFlushError.missingComposeDraft }
        guard !hasPersistedDiscard, draft.status == .pending else {
            throw EditorPersistenceFailure.draftNoLongerPending
        }
        // A worker or another window may settle/delete this row during the
        // debounce. Registered SwiftData instances can still be stale then.
        let draftID = draft.id
        let predicate = #Predicate<Draft> { $0.id == draftID }
        let authoritativeContext = ModelContext(context.container)
        guard let authoritative = try authoritativeContext.fetch(
            FetchDescriptor<Draft>(predicate: predicate)
        ).first, authoritative.status == .pending else {
            throw EditorPersistenceFailure.draftNoLongerPending
        }
        return draft
    }

    private func projectPendingEditorChanges(on draft: Draft) throws {
        guard hasUnsavedEditorChanges else { return }
        let html = exportEditorHTML(format: messageFormat)
        guard messageFormat != .richText || html != nil else {
            throw EditorPersistenceFailure.richTextExportFailed
        }
        draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: editorText)
        draft.messageFormatRaw = messageFormat.rawValue
        draft.bodyHTML = html
        try ComposerManualEdit.recordSnapshot(on: draft, context: context)
    }

    private func recordPersistenceFailure(_ error: Error) {
        persistenceError = error.localizedDescription
    }

    private func projectEditor(from draft: Draft) {
        let format = draft.resolvedMessageFormat
        messageFormat = format
        editorText = importEditorContent(
            plainText: draft.replyText,
            html: draft.bodyHTML,
            format: format
        )
        // Rich-slot tail upgrade: a draft whose body the editor has never
        // produced HTML for (worker-generated, or freshly created) carries
        // only the slot's plain-text tail. Upgrade it to the attributed
        // signature once, at mount; the persisted bodyHTML then keeps this
        // projection idempotent across polling reloads.
        if format == .richText,
           draft.bodyHTML?.isEmpty ?? true,
           let slot = resolvedSignatureSlot, slot.isRich,
           let signature = attributedSignature(for: slot) {
            editorText = ComposerRichTextCodec.swappingSignature(
                in: editorText,
                newAttributedSignature: signature
            )
            draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: editorText)
            draft.bodyHTML = exportEditorHTML(format: format)
        }
        projectedReplyText = draft.replyText
        projectedBodyHTML = draft.bodyHTML
        projectedMessageFormat = format
        projectedEditorContent = NSAttributedString(attributedString: editorText)
        hasUnsavedEditorChanges = false
        liveEditorSnapshot = nil
        viewingVersionIndex = nil
    }

    /// Makes the historical version currently visible in the editor the live
    /// compose body at the first mutating action. Merely browsing versions is
    /// read-only; editing, changing controls, revising, regenerating, saving,
    /// or sending adopts the visible body's own style provenance.
    private func adoptViewedVersionIfNeeded(on draft: Draft) {
        guard let index = viewingVersionIndex,
              let version = versions.first(where: { $0.index == index }) else { return }
        draft.styleRegisterID = version.styleRegisterID
        draft.styleControlSnapshot = version.styleControlSnapshot
        draft.generatedSourcesJSON = version.generatedSourcesJSON
        draft.pendingStyleControlSnapshot = nil
        // The adopted version is now what the live body derives from: later
        // edits are measured against it, not against the newest generation.
        draft.baseRevisionID = version.id
        viewingVersionIndex = nil
        liveEditorSnapshot = nil
        liveStylePanel = stylePanel
        hasUnsavedEditorChanges = true
    }

    private func projectVersions(from draft: Draft) {
        let projected = draft.orderedRevisions.map { revision in
            ComposerDraftVersion(
                id: revision.id,
                index: revision.index,
                trigger: revision.triggerRaw,
                instruction: revision.instruction,
                createdAt: revision.createdAt,
                bodyText: revision.bodyText,
                bodyHTML: revision.bodyHTML,
                styleRegisterID: revision.styleRegisterID,
                styleControlSnapshot: revision.styleControlSnapshot,
                generatedSourcesJSON: revision.generatedSourcesJSON,
                baseRevisionID: revision.baseRevisionID
            )
        }
        if projected != versions {
            versions = projected
        }
    }

    private func acceptCurrentEditorAsProjected() {
        guard let draft else { return }
        projectedReplyText = draft.replyText
        projectedBodyHTML = draft.bodyHTML
        projectedMessageFormat = draft.resolvedMessageFormat
        projectedEditorContent = NSAttributedString(attributedString: liveEditorSnapshot ?? editorText)
        hasUnsavedEditorChanges = false
        persistenceError = nil
    }
}

// MARK: - ComposerSourceHost

extension ComposeState: ComposerQuestionRoundsHost {}

extension ComposeState: ComposerDecisionsHost {
    var decisionVersions: [ComposerDecisionVersion] {
        ComposerDecisionHistoryPersistence.decode(draft?.decisionHistoryJSON)?.versions ?? []
    }

    var activeDecisionVersionID: UUID? {
        ComposerDecisionHistoryPersistence.decode(draft?.decisionHistoryJSON)?.activeVersionID
    }

    var hasPendingDecisionSourceChanges: Bool {
        guard let draft else { return false }
        // Before the first draft only: once drafted, open questions stay as
        // they are and a Re-check the author chooses re-plans them.
        if !hasGeneratedDraft,
           interviewState?.asksUnansweredQuestion(
            outsideReadingLanguage: readingLanguageIdentifier
        ) == true {
            return true
        }
        return ComposerDecisionHistoryPersistence.hasPendingSourceChanges(on: draft)
    }

    var hasPendingDecisionInputChanges: Bool {
        let history = ComposerDecisionHistoryPersistence.decode(draft?.decisionHistoryJSON)
        let active = history?.activeVersionID.flatMap { activeID in
            history?.versions.first(where: { $0.id == activeID })
        } ?? history?.versions.last
        guard let active else { return hasPendingDecisionSourceChanges }
        let currentGuidance = draftingInstructionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evaluatedGuidance = (active.draftGuidance ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hasPendingDecisionSourceChanges || currentGuidance != evaluatedGuidance
    }
}

extension ComposeState: ComposerDraftEditingHost {
    var annotations: [SourceAnnotation] { [] }
    var replyQuotePresentation: ComposerReplyQuotePresentation { .notApplicable }
    var includesQuotedOriginal: Bool { false }
    var hasEdits: Bool {
        hasUnsavedEditorChanges || !editorText.isEqual(to: projectedEditorContent)
    }
    var plainEditorText: String { ComposerRichTextCodec.plainBodyProjection(of: editorText) }
    var hasPendingSourceChanges: Bool {
        ComposerRegenerationInputState.hasPendingSourceChanges(
            currentSources: sources,
            generatedSourcesJSON: ComposerRegenerationInputState.displayedGeneratedSourcesJSON(
                liveGeneratedSourcesJSON: draft?.generatedSourcesJSON,
                versions: versions,
                viewingVersionIndex: viewingVersionIndex
            )
        )
    }
    var hasPendingRegenerationInputs: Bool {
        hasPendingSourceChanges || hasPendingStyleRegeneration
    }
    var canSendDraft: Bool {
        !isImportingAttachments && canSend && (
            !plainEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ComposerInlinePhotoCoding.containsPhoto(in: editorText)
        )
    }
    /// New-message compose has no training-signal review step — Send
    /// always sends directly.
    var sendNeedsConfirmationFirst: Bool { false }

    func updateEditorContent(_ content: NSAttributedString) {
        setBody(content)
    }

    func updateMessageFormat(_ format: ComposerMessageFormat) {
        setMessageFormat(format)
    }

    func refreshAnnotationOpacity() {}

    func showVersion(_ version: ComposerDraftVersion) {
        if viewingVersionIndex == nil {
            do {
                try saveEditorNow()
            } catch {
                return
            }
            liveEditorSnapshot = NSAttributedString(attributedString: editorText)
        }
        viewingVersionIndex = version.index
        stylePanel = liveStylePanel.displayingVersion(
            styleRegisterID: version.styleRegisterID,
            styleControlSnapshot: version.styleControlSnapshot
        )
        editorText = importEditorContent(
            plainText: version.bodyText,
            html: version.bodyHTML,
            format: version.bodyHTML == nil ? messageFormat : .richText
        )
    }

    func showLiveDraft() {
        viewingVersionIndex = nil
        stylePanel = liveStylePanel
        if let liveEditorSnapshot {
            editorText = NSAttributedString(attributedString: liveEditorSnapshot)
        } else if let draft {
            editorText = importEditorContent(
                plainText: projectedReplyText,
                html: projectedBodyHTML,
                format: projectedMessageFormat
            )
            draft.replyText = projectedReplyText
            draft.bodyHTML = projectedBodyHTML
            draft.messageFormatRaw = projectedMessageFormat.rawValue
        }
        liveEditorSnapshot = nil
    }
}

extension ComposeState: ComposerRecipientHost {
    var recipientMutationsEnabled: Bool { !isAwaitingModel }
}

extension ComposeState: ComposerSourceHost {
    /// Compose-from-scratch has no inbound message or thread, so the Add
    /// popover offers no thread-sibling or attachment candidates.
    var supportsMessageCandidates: Bool { false }
    var sourceContextUsage: ComposerWriterWindowUsage? {
        // Left-out marks belong to the current count; while the edited list
        // is being measured they wait for it.
        guard draft?.sourceContextTokenCount != nil else { return nil }
        return ComposerWriterWindowUsage.decode(draft?.sourceContextFitJSON)
    }
    var sourceMutationsEnabled: Bool {
        guard let draft else { return false }
        guard !draft.isAutomaticSourceResearchPending else { return false }
        if draft.resolvedStage == DraftStage.evaluatingSources {
            return draft.generationFailureCount != nil
        }
        if draft.resolvedStage == DraftStage.generating {
            return false
        }
        return !isAwaitingModel
    }

    func backingDraft(in context: ModelContext) -> Draft? {
        // Resolve in the section's context (shared with this view model) so the
        // section's save persists, then `reloadFromStore` re-projects.
        guard let id = draft?.id else { return nil }
        let predicate = #Predicate<Draft> { $0.id == id }
        return try? context.fetch(FetchDescriptor<Draft>(predicate: predicate)).first
    }

    func candidateMessage(in context: ModelContext) -> Message? { nil }

    func correspondentAddress(in context: ModelContext) -> String? { primaryRecipientAddress }

    func reloadAfterSourceMutation(in context: ModelContext) {
        reloadFromStore()
    }
}
