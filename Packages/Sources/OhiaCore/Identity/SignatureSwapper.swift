import Foundation

/// Pure logic for keeping an identity's plaintext signature in sync
/// with a draft body, using the RFC 3676 §4.3 signature separator
/// `\n-- \n` as the canonical marker.
///
/// Behavior matches Mail.app: switching to a signed identity always
/// surfaces the sig; switching to an unsigned identity removes one if
/// present. A user who deletes a sig and then switches identities will
/// have to delete again — accepted friction in exchange for predictable
/// behavior.
public enum SignatureSwapper {

    /// The canonical marker (newline + two dashes + space + newline).
    public static let marker = "\n-- \n"

    /// Swap / append / delete the signature tail of `body`.
    ///
    /// - Parameters:
    ///   - body: the current draft text.
    ///   - newSignature: the signature to install, or nil to remove any
    ///     existing signature.
    /// - Returns: the transformed body.
    public static func swap(in body: String, newSignature: String?) -> String {
        if let range = body.range(of: marker, options: .backwards) {
            // Marker found — delete from marker start to end.
            let head = String(body[..<range.lowerBound])
            guard let newSig = newSignature else {
                return head
            }
            return head + marker + newSig
        } else {
            // Marker absent.
            guard let newSig = newSignature else {
                return body
            }
            return body + "\n" + marker + newSig
        }
    }
}
