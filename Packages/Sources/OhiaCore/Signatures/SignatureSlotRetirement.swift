import Foundation
import SwiftData

/// Deletes a signature slot without breaking mail that references it.
///
/// Two referents matter:
/// - **Queued outbox mail** carries absolute paths into the slot's asset
///   directory (`OutboxItem.inlineImagesJSON`). Deleting the files would
///   doom the send to unrecoverable retries, so deletion is *blocked*
///   while any queued/sending/failed item references the slot's images —
///   the user delivers or cancels that mail first.
/// - **Live drafts** stamped with the slot are re-stamped to unsigned
///   (nil), and any dead `ohia-sig://` tokens are stripped from their
///   stored HTML, keeping the text/plain and text/html alternatives
///   consistent (the plain tail keeps its now-ordinary signature text).
@MainActor
public enum SignatureSlotRetirement {

    public enum Outcome: Equatable {
        case deleted
        /// Deletion refused: this many not-yet-sent outbox items embed the
        /// slot's images.
        case blockedByQueuedMail(itemCount: Int)
    }

    public static func retire(
        slot: SignatureSlot,
        account: Account,
        context: ModelContext,
        store: SignatureAssetStore = SignatureAssetStore()
    ) throws -> Outcome {
        let blockingItems = try queuedItemCount(referencing: slot, context: context)
        if blockingItems > 0 {
            return .blockedByQueuedMail(itemCount: blockingItems)
        }

        // Re-stamp referencing drafts to unsigned and strip dead tokens.
        // SwiftData #Predicate cannot express optional-UUID equality on all
        // paths reliably — fetch then filter, per the repo pattern.
        let slotID = slot.id
        let drafts = try context.fetch(FetchDescriptor<Draft>())
        for draft in drafts where draft.signatureSlotID == slotID {
            draft.signatureSlotID = nil
            if let html = draft.bodyHTML, html.contains(SignatureImageToken.scheme) {
                draft.bodyHTML = SignatureInlineImageEncoder.strippingImageTags(
                    html: html, ownerID: slotID
                )
            }
        }

        if account.defaultSignatureSlotID == slotID {
            account.defaultSignatureSlotID = nil
        }
        store.deleteAssets(ownerID: slotID)
        context.delete(slot)
        try context.save()
        return .deleted
    }

    /// Not-yet-sent outbox items whose inline-image manifest references any
    /// of the slot's assets. `sent` and `cancelled` items never read their
    /// manifest again; everything else can still hit the files.
    private static func queuedItemCount(
        referencing slot: SignatureSlot,
        context: ModelContext
    ) throws -> Int {
        let contentIDs = Set(slot.images.map(\.contentID))
        guard !contentIDs.isEmpty else { return 0 }
        let items = try context.fetch(FetchDescriptor<OutboxItem>())
        return items.count { item in
            switch item.status {
            case .sent, .cancelled:
                return false
            case .queued, .sending, .failed:
                let manifest = OutboxInlineImage.decode(item.inlineImagesJSON)
                return manifest.contains { contentIDs.contains($0.contentID) }
            }
        }
    }
}
