import CryptoKit
import Foundation

/// Integrity boundary for the exact grounded user turn paired with preserved
/// reasoning. Updated Composer context belongs in the next user turn; the
/// historical turn must remain byte-for-byte the one the model answered.
public enum DraftReasoningContextFingerprint {
    public static func value(for prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
