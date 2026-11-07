import Foundation
import OhiaCore

/// Pure helper that picks the Drafts folder from a LIST result. Prefers
/// RFC 6154 SPECIAL-USE `\Drafts`; falls back to common provider names.
public enum DraftsFolderResolver {
    private static let nameHeuristics: [String] = [
        "Drafts", "Draft", "Draft Items", "Draft Messages",
        "[Gmail]/Drafts",
    ]

    public static func resolve(folders: [IMAPFolder]) -> String? {
        let selectable = folders.filter { !$0.isNoselect }

        if let flagged = selectable.first(where: { $0.isDrafts }) {
            return flagged.name
        }

        for candidate in nameHeuristics {
            if let hit = selectable.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return hit.name
            }
        }

        return selectable.first {
            IMAPFolderIngestionPolicy.isDraftsFolder(
                folderName: $0.name,
                attributes: Array($0.attributes)
            )
        }?.name
    }
}
