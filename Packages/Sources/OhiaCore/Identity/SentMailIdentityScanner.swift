import Foundation
import SwiftData

public struct IdentityCandidate: Sendable, Hashable {
    public let address: String            // lowercased
    public let displayName: String?       // most frequent fromName seen (if any)
    public let occurrenceCount: Int

    public init(address: String, displayName: String?, occurrenceCount: Int) {
        self.address = address
        self.displayName = displayName
        self.occurrenceCount = occurrenceCount
    }
}

/// Mine distinct `fromAddress` values from messages the user has sent on
/// `account`'s mailbox and return them as identity candidates for the
/// Settings "Suggested aliases" surface. Excludes the account's primary
/// address and any addresses already promoted to `Identity` rows. Caps
/// at top 20, sorted by occurrence count descending.
public enum SentMailIdentityScanner {

    @MainActor
    public static func candidates(
        for account: Account,
        in context: ModelContext
    ) -> [IdentityCandidate] {
        let accountID = account.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { m in
                m.isSentByUser == true && (m.accountID == accountID || m.account?.id == accountID)
            }
        )
        guard let messages = try? context.fetch(descriptor) else { return [] }

        let excluded: Set<String> = {
            var set = Set<String>()
            set.insert(account.emailAddress.lowercased())
            for ident in account.identities {
                set.insert(ident.address)  // Identity.init already lowercased
            }
            return set
        }()

        struct Bucket {
            var count: Int = 0
            var nameCounts: [String: Int] = [:]
        }
        var buckets: [String: Bucket] = [:]

        for m in messages {
            let addr = m.fromAddress.lowercased()
            if excluded.contains(addr) { continue }
            var b = buckets[addr] ?? Bucket()
            b.count += 1
            if let name = m.fromName, !name.isEmpty {
                b.nameCounts[name, default: 0] += 1
            }
            buckets[addr] = b
        }

        let candidates = buckets.map { (addr, bucket) -> IdentityCandidate in
            let topName = bucket.nameCounts
                .max { a, b in
                    if a.value != b.value { return a.value < b.value }
                    return a.key > b.key    // stable tiebreak — prefer lexicographically earlier
                }?
                .key
            return IdentityCandidate(
                address: addr,
                displayName: topName,
                occurrenceCount: bucket.count
            )
        }

        return candidates
            .sorted {
                if $0.occurrenceCount != $1.occurrenceCount {
                    return $0.occurrenceCount > $1.occurrenceCount
                }
                return $0.address < $1.address
            }
            .prefix(20)
            .map { $0 }
    }
}
