import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class IMAPFlagSyncCoordinator {
    private struct MutationKey: Hashable {
        let folder: String
        let uid: UInt32
    }

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func apply(event: IMAPFlagSnapshotEvent, accountID: UUID) throws -> Int {
        guard !event.snapshots.isEmpty else { return 0 }

        let serverSeenByUID = Dictionary(
            event.snapshots.map { ($0.uid, $0.isSeen) },
            uniquingKeysWith: { _, latest in latest }
        )
        let activeLocalMutations = try activeLocalMutationKeys(accountID: accountID)

        let folder = event.folder
        // Only the reported messages: a recent-arrival refresh after every
        // flag push must not read a 100k-message folder. Chunks of 100: past
        // that SwiftData's IN list misses UIDs at or above 2^31 (UInt32 is
        // stored as a signed bit pattern).
        let uids = Array(serverSeenByUID.keys).sorted()
        var fetched: [Message] = []
        for start in stride(from: 0, to: uids.count, by: 100) {
            let chunk = Array(uids[start..<min(start + 100, uids.count)])
            fetched += try modelContext.fetch(FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.imapFolderPath == folder && chunk.contains(message.imapUID)
                }
            ))
        }
        let messages = fetched.filter { message in
            (message.accountID == accountID || message.account?.id == accountID)
                && message.imapUID > 0
        }
        var changed = 0

        for message in messages {
            guard let serverSeen = serverSeenByUID[message.imapUID] else { continue }
            let key = MutationKey(folder: event.folder, uid: message.imapUID)
            guard !activeLocalMutations.contains(key) else { continue }

            let target = message.isSentByUser ? true : serverSeen
            guard message.isRead != target else { continue }
            message.applyReadState(target)
            changed += 1
        }

        if changed > 0 {
            try modelContext.save()
        }
        return changed
    }

    private func activeLocalMutationKeys(accountID: UUID) throws -> Set<MutationKey> {
        let descriptor = FetchDescriptor<MailboxMutation>(
            predicate: #Predicate<MailboxMutation> { row in
                row.accountID == accountID
            }
        )
        let rows = try modelContext.fetch(descriptor)
        var keys = Set<MutationKey>()
        for row in rows {
            guard row.status == .queued || row.status == .running else { continue }
            switch row.kind {
            case .setSeen, .clearSeen, .delete, .moveToTrash, .moveToJunk, .moveToInbox:
                keys.insert(MutationKey(folder: row.imapFolderPath, uid: row.imapUID))
            case .setFlagged, .clearFlagged:
                continue
            }
        }
        return keys
    }
}
