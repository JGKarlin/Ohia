import Foundation
import CryptoKit

public enum Deduplicator {
    public static func contentHash(
        messageId: String?,
        date: String?,
        from: String,
        bodySnippet: String
    ) -> String {
        var input = ""
        if let mid = messageId { input += mid }
        if let d = date { input += d }
        input += from.lowercased()
        input += String(bodySnippet.prefix(500))

        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
