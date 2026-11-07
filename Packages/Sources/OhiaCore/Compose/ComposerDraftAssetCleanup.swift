import Foundation

/// Idempotent cleanup for files whose lifetime is owned by one Composer draft.
/// Signature assets are intentionally excluded because their slot lifecycle is
/// independent of a draft.
public enum ComposerDraftAssetCleanup {
    public static func deleteAll(
        ownerID: UUID,
        attachmentStore: ComposerAttachmentStore = ComposerAttachmentStore(),
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore()
    ) {
        attachmentStore.deleteAttachments(ownerID: ownerID)
        inlinePhotoStore.deletePhotos(ownerID: ownerID)
    }
}
