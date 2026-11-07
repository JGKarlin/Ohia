// Packages/Sources/OhiaMail/IMAP/SentFolderResolver.swift
import Foundation

/// Pure helper that picks the Sent folder from a LIST result. Prefers
/// RFC 6154 SPECIAL-USE `\Sent`; falls back to case-insensitive name
/// matching for common Sent-folder names across providers. `\Noselect`
/// folders are skipped regardless of their name or attributes.
public enum SentFolderResolver {
    private static let nameHeuristics: [String] = [
        "Sent", "Sent Items", "Sent Mail", "Sent Messages",
        "[Gmail]/Sent Mail",
    ]

    public static func resolve(folders: [IMAPFolder]) -> String? {
        let selectable = folders.filter { !$0.isNoselect }

        if let flagged = selectable.first(where: { $0.isSent }) {
            return flagged.name
        }

        for candidate in nameHeuristics {
            if let hit = selectable.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return hit.name
            }
        }

        return nil
    }
}
