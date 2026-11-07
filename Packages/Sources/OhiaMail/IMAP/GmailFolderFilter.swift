import Foundation
import OhiaCore

public enum GmailFolderFilter {
    /// Filters raw LIST output into the set of folders worth syncing.
    ///
    /// - Skip any folder with `\Noselect`.
    /// - Skip Trash/Junk folders for every provider; those messages should not
    ///   enter or remain in the local semantic corpus.
    /// - On Gmail (`capabilities.xGmExt1 == true`): keep `INBOX`, the folder
    ///   flagged `\All`, and Drafts. Other labels are views of All Mail;
    ///   fetching them would double-ingest via content-hash dedup. Drafts are
    ///   separate Composer queue input, not semantic corpus messages.
    /// - Otherwise: keep every remaining syncable folder.
    public static func foldersToSync(
        listing: [IMAPFolder],
        capabilities: IMAPCapability
    ) -> [IMAPFolder] {
        let selectable = listing.filter { folder in
            IMAPFolderIngestionPolicy.isSyncEligible(
                folderName: folder.name,
                attributes: Array(folder.attributes)
            )
        }

        if capabilities.xGmExt1 {
            return selectable.filter { folder in
                folder.name.uppercased() == "INBOX"
                    || folder.isAll
                    || IMAPFolderIngestionPolicy.isDraftsFolder(
                        folderName: folder.name,
                        attributes: Array(folder.attributes)
                    )
            }
        }

        return selectable
    }

    /// Filters raw LIST output into folders that contribute message corpus
    /// content, and drives the onboarding history estimate + the visible
    /// "importing" percentage (`ActivityStripIMAPCorpusProjection
    /// .requiredUIDWork`). Drafts remain in the sync set for Composer draft
    /// sync but are excluded from both — they're not semantic corpus
    /// messages, and folding their independently-timed backfill into the
    /// percentage would make it unstable (see that call site's doc
    /// comment). Drafts (and every other synced folder) still gates the
    /// *completion marker* (`Account.initialIMAPImportCompletedAt`) via the
    /// wider `foldersToSync` set — see `IMAPSession.refreshTrackedFolders`.
    public static func foldersForCorpus(
        listing: [IMAPFolder],
        capabilities: IMAPCapability
    ) -> [IMAPFolder] {
        let corpusEligible = foldersToSync(listing: listing, capabilities: capabilities).filter { folder in
            IMAPFolderIngestionPolicy.isCorpusEligible(
                folderName: folder.name,
                attributes: Array(folder.attributes)
            )
        }

        guard capabilities.xGmExt1 else { return corpusEligible }

        let allMail = corpusEligible.filter(\.isAll)
        if !allMail.isEmpty {
            return allMail
        }
        return corpusEligible.filter { $0.name.uppercased() == "INBOX" }
    }
}
