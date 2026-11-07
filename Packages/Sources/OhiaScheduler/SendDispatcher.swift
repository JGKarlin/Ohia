import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class SendDispatcher {
    private let context: ModelContext
    private let jobQueue: JobQueue
    private let userDefaults: UserDefaults

    public init(context: ModelContext, jobQueue: JobQueue, userDefaults: UserDefaults = .standard) {
        self.context = context
        self.jobQueue = jobQueue
        self.userDefaults = userDefaults
    }

    public enum Error: Swift.Error, Equatable {
        case noAccount
        case noIdentity
        case noRecipient
        case invalidAddress(String)
        case quotedOriginalUnavailable
        case alreadyQueued
        case pendingStyleDecision
    }

    public enum RejectKind: Sendable {
        case noReply
        case regenerate(feedback: String)
    }

    /// Convert a confirmed draft into a queued OutboxItem and enqueue a
    /// .sendOutbox job. Threading headers are preserved when available;
    /// missing incoming Message-ID degrades to a non-threaded send rather
    /// than rejection. Returns the new OutboxItem's id so a caller can track
    /// this specific send through to its later confirmation.
    @discardableResult
    public func enqueueSend(
        draft: Draft,
        account: Account,
        identity: Identity,
        approvedTrainingSignalsJSON: String? = nil
    ) throws -> UUID {
        guard let msg = draft.message else { throw Error.noRecipient }
        guard draft.status == .pending else { throw Error.alreadyQueued }
        guard !draft.hasPendingStyleControlDecision else { throw Error.pendingStyleDecision }
        guard !identity.address.isEmpty else { throw Error.noIdentity }

        let defaults = ReplyRecipientPolicy.defaultRecipients(
            for: msg,
            mode: draft.resolvedReplyRecipientMode
        )
        let toArray: [String]
        let toJSON: String
        if let override = draft.replyToAddressesJSON {
            toArray = try decodeAddressJSON(override)
            toJSON = override
        } else {
            toArray = defaults.to
            toJSON = ComposeAddressEncoding.encodePreservingEmpty(toArray)
        }
        guard !toArray.isEmpty else { throw Error.noRecipient }
        try validateAddressList(toArray)

        let ccArray = try draft.replyCcAddressesJSON.map(decodeAddressJSON) ?? defaults.cc
        let bccArray = try draft.replyBccAddressesJSON.map(decodeAddressJSON) ?? defaults.bcc
        try validateAddressList(ccArray)
        try validateAddressList(bccArray)
        let ccJSON = ComposeAddressEncoding.encode(ccArray)
        let bccJSON = ComposeAddressEncoding.encode(bccArray)

        let subject = msg.subject.hasPrefix("Re: ") ? msg.subject : "Re: \(msg.subject)"

        let refs: String? = {
            var parts: [String] = []
            if let chain = msg.referencesChain, !chain.isEmpty { parts.append(chain) }
            if let mid = msg.messageIdHeader { parts.append(mid) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()

        let outgoingID = MessageBuilder.generateMessageID(fromAddress: identity.address)

        // Rich-text drafts carry an HTML alternative through the outbox.
        // Plain drafts deliberately keep it nil so MessageBuilder emits a
        // genuine text/plain message.
        let slot = SignatureSlotResolver.slot(for: draft, account: account)
        let htmlBody = ComposerMessageBodyHTML.resolve(for: draft, slot: slot)
        draft.bodyHTML = htmlBody
        let send = resolveSendHTML(htmlBody: htmlBody, slot: slot, draft: draft)
        let finalizedBody = try finalizedReplyBody(
            plainBody: draft.replyText,
            htmlBody: send.html,
            draft: draft
        )

        let item = OutboxItem(
            fromAddress: identity.address,
            toAddressesJSON: toJSON,
            ccAddressesJSON: ccJSON,
            bccAddressesJSON: bccJSON,
            subject: subject,
            plainBody: finalizedBody.plain,
            htmlBody: finalizedBody.html,
            inReplyTo: msg.messageIdHeader,
            referencesChain: refs,
            attachmentPathsJSON: draft.replyAttachmentPathsJSON,
            messageIDHeader: outgoingID
        )
        item.inlineImagesJSON = OutboxInlineImage.encode(send.images)
        item.fromDisplayName = identity.displayName
        item.replyToAddress = identity.replyTo
        item.account = account
        item.draft = draft
        item.message = msg
        item.approvedTrainingSignalsJSON = approvedTrainingSignalsJSON
        item.styleControlSnapshot = draft.styleControlSnapshot
        Self.freezeGenerationAncestry(of: draft, onto: item)
        context.insert(item)

        draft.status = .confirmed
        try ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)

        try jobQueue.enqueue(type: .sendOutbox, priority: 1, context: context)

        try context.save()
        return item.id
    }

    private func finalizedReplyBody(
        plainBody: String,
        htmlBody: String?,
        draft: Draft
    ) throws -> (plain: String, html: String?) {
        guard draft.resolvedIncludesQuotedOriginal else {
            return (plainBody, htmlBody)
        }
        guard draft.hasPreparedQuotedOriginal,
              let quotedPlain = draft.quotedReplyPlainText,
              let quotedHTML = draft.quotedReplyHTML else {
            throw Error.quotedOriginalUnavailable
        }

        let quote = QuotedReplyFormatter.PreparedQuote(
            plainText: quotedPlain,
            html: quotedHTML
        )
        return (
            QuotedReplyFormatter.appending(quote, toPlainBody: plainBody),
            htmlBody.map { QuotedReplyFormatter.appending(quote, toHTMLBody: $0) }
        )
    }

    /// Reject a draft. Two paths:
    /// - `.noReply`: the user decided this message doesn't need a reply. Marks
    ///   the draft rejected (which removes it from the Composer queue) and
    ///   sets the message's `requiresReply = false`.
    /// - `.regenerate(feedback)`: the user wants a different draft. Stores the
    ///   feedback on the message, flips the draft back to the `generating`
    ///   stage (status stays `.pending` so the Composer's owed-generation
    ///   pass picks it up), and enqueues a priority-4 `.generateDraft` job
    ///   (higher than the default priority-6 so the user's request is
    ///   serviced sooner).
    public func reject(draft: Draft, kind: RejectKind) throws {
        switch kind {
        case .noReply:
            draft.status = .rejected
            draft.message?.requiresReply = false
            try ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)

        case .regenerate(let feedback):
            draft.message?.regenerationFeedback = feedback
            draft.stageRaw = DraftStage.generating
            try jobQueue.enqueue(type: .generateDraft, priority: 4, context: context)
        }

        try context.save()
    }

    /// Build an `OutboxItem` from a `.userCompose` draft and enqueue a
    /// `.sendOutbox` job. Unlike `enqueueSend`, there's no inbound message,
    /// no thread headers, and no automatic "Re: " subject prefix. Returns the
    /// new OutboxItem's id so a caller can track this specific send through
    /// to its later confirmation.
    @discardableResult
    public func enqueueCompose(draft: Draft, account: Account, identity: Identity) throws -> UUID {
        guard !draft.hasPendingStyleControlDecision else { throw Error.pendingStyleDecision }
        guard !identity.address.isEmpty else { throw Error.noIdentity }

        // Validate To.
        guard let toJSON = draft.composeToJSON else { throw Error.noRecipient }
        let toArray = try decodeAddressJSON(toJSON)
        guard !toArray.isEmpty else { throw Error.noRecipient }

        // Validate every address in To/Cc/Bcc parses. Cc/Bcc are optional —
        // nil means "no Cc/Bcc"; malformed JSON is treated as a hard error
        // rather than silently dropped, so callers can't lose recipients to
        // a corrupt persisted field.
        try validateAddressList(toArray)
        if let cc = draft.composeCcJSON {
            try validateAddressList(decodeAddressJSON(cc))
        }
        if let bcc = draft.composeBccJSON {
            try validateAddressList(decodeAddressJSON(bcc))
        }

        let outgoingID = MessageBuilder.generateMessageID(fromAddress: identity.address)

        let slot = SignatureSlotResolver.slot(for: draft, account: account)
        let htmlBody = ComposerMessageBodyHTML.resolve(for: draft, slot: slot)
        draft.bodyHTML = htmlBody
        let send = resolveSendHTML(htmlBody: htmlBody, slot: slot, draft: draft)

        let item = OutboxItem(
            fromAddress: identity.address,
            toAddressesJSON: toJSON,
            ccAddressesJSON: draft.composeCcJSON,
            bccAddressesJSON: draft.composeBccJSON,
            subject: draft.composeSubject ?? "",
            plainBody: draft.replyText,
            htmlBody: send.html,
            inReplyTo: nil,
            referencesChain: nil,
            attachmentPathsJSON: draft.deliverablesJSON,
            messageIDHeader: outgoingID
        )
        item.inlineImagesJSON = OutboxInlineImage.encode(send.images)
        item.fromDisplayName = identity.displayName
        item.replyToAddress = identity.replyTo
        item.account = account
        item.draft = draft
        item.message = nil
        item.styleControlSnapshot = draft.styleControlSnapshot
        Self.freezeGenerationAncestry(of: draft, onto: item)
        context.insert(item)

        draft.status = .confirmed
        try ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)

        // Persist most-recently-used account so the next blank compose
        // defaults to the same From.
        userDefaults.set(account.id.uuidString, forKey: "ohia.compose.lastUsedAccountID")

        try jobQueue.enqueue(type: .sendOutbox, priority: 1, context: context)
        try context.save()
        return item.id
    }

    /// Freezes, with the outbox item, the generated revision the sent body
    /// derives from and that revision's basis, so later edits to the live
    /// draft cannot rewrite what training learns for this email. The base is
    /// the draft's recorded ancestry (an adopted older version stays the
    /// base), never the newest revision by date. A base generated before
    /// bases were recorded leaves the basis nil and the preparation job
    /// compiles the example from the draft's own decisions.
    private static func freezeGenerationAncestry(of draft: Draft, onto item: OutboxItem) {
        let base = draft.baseGeneratedRevision
        item.baseRevisionID = base?.id
        item.generationBasisJSON = base?.generationBasisJSON
    }

    /// The wire form of the HTML alternative: `ohia-sig://` image tokens
    /// become `cid:` references and the referenced files become the
    /// outbox item's inline-image manifest. The draft keeps the token form
    /// (`draft.bodyHTML`) — `cid:` is send-only vocabulary.
    private func resolveSendHTML(
        htmlBody: String?,
        slot: SignatureSlot?,
        draft: Draft
    ) -> (html: String?, images: [OutboxInlineImage]) {
        let inlinePhotos = ComposerInlinePhotoEncoder.referencedAssets(
            html: htmlBody,
            ownerID: draft.id,
            assets: ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON)
        )
        draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(inlinePhotos)
        guard let htmlBody else { return (nil, []) }
        var rewritten = htmlBody
        var images: [OutboxInlineImage] = []

        if let slot, !slot.images.isEmpty {
            let encoded = SignatureInlineImageEncoder.encodeForSend(
                html: rewritten,
                slot: slot,
                store: SignatureAssetStore()
            )
            rewritten = encoded.html
            images.append(contentsOf: encoded.images)
        }

        if !inlinePhotos.isEmpty {
            let encoded = ComposerInlinePhotoEncoder.encodeForSend(
                html: rewritten,
                ownerID: draft.id,
                assets: inlinePhotos,
                store: ComposerInlinePhotoStore()
            )
            rewritten = encoded.html
            images.append(contentsOf: encoded.images)
        }
        return (rewritten, images)
    }

    private func validateAddressList(_ addrs: [String]) throws {
        for raw in addrs {
            do {
                _ = try MailAddressParser.parseOne(raw)
            } catch {
                throw Error.invalidAddress(raw)
            }
        }
    }

    /// Decode a JSON `[String]` from one of the `compose*JSON` fields.
    /// Malformed JSON throws `.noRecipient` rather than silently returning
    /// `[]` — losing recipients to a corrupt field is worse than failing loud.
    private func decodeAddressJSON(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { throw Error.noRecipient }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw Error.noRecipient
        }
    }
}
