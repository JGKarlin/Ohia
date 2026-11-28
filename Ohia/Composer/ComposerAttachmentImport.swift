import Foundation
import SwiftData
import OhiaCore

typealias ComposerDraftSyncStager = @MainActor (Draft?, ModelContext) throws -> Void
typealias ComposerContextSaver = @MainActor (ModelContext) throws -> Void

@MainActor
enum ComposerPersistence {
    static func save(_ context: ModelContext) throws {
        try context.save()
    }
}

/// Identifies one in-flight draft-asset import for a specific draft.
/// The owner id is captured before copying begins and must still match a live
/// pending draft when the copied paths are committed.
struct ComposerAttachmentImport: Hashable, Sendable {
    let id: UUID
    let ownerID: UUID

    init(id: UUID = UUID(), ownerID: UUID) {
        self.id = id
        self.ownerID = ownerID
    }
}

/// Composer-surface registry that keeps attachment and inline-photo imports
/// gated even when selection moves away from the state/session that started
/// them. Full tokens are retained so finishing one of several imports for the
/// same owner cannot accidentally unblock sending.
struct ComposerAttachmentImportRegistry: Sendable {
    private var activeImports: Set<ComposerAttachmentImport> = []

    mutating func register(_ attachmentImport: ComposerAttachmentImport) {
        activeImports.insert(attachmentImport)
    }

    mutating func unregister(_ attachmentImport: ComposerAttachmentImport) {
        activeImports.remove(attachmentImport)
    }

    func blocksSending(ownerID: UUID) -> Bool {
        activeImports.contains { $0.ownerID == ownerID }
    }
}
