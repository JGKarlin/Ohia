import CryptoKit
import Foundation

public enum ComposerResearchInputFingerprint {
    public static func value(for draft: Draft, brief: String) -> String {
        let parts = [
            "brief=\(normalized(brief))",
            "subject=\(normalized(draft.composeSubject))",
            "to=\(draft.composeToJSON ?? "")",
            "cc=\(draft.composeCcJSON ?? "")",
            "bcc=\(draft.composeBccJSON ?? "")",
            "fromAccount=\(draft.composeFromAccountID?.uuidString ?? "")",
            "identity=\(draft.fromIdentityID?.uuidString ?? "")",
        ]
        let data = Data(parts.joined(separator: "\u{1F}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
