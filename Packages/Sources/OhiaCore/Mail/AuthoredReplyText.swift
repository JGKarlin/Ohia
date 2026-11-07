import Foundation

/// Canonical style/training text extracted from a sent or edited email body.
/// Search and display keep their own representations; this seam deliberately
/// removes only mechanically attached history/signature material.
public enum AuthoredReplyText: Sendable {
    public static func extract(from raw: String) -> String {
        extract(from: raw, repliedTo: nil)
    }

    /// `repliedTo` is the text of the message the reply answered, when known:
    /// it lets a flattened quote below an attribution be recognized as history.
    public static func extract(from raw: String, repliedTo original: String?) -> String {
        let withoutHistory = QuotedHistoryTail.authoredText(from: raw, repliedTo: original)
        let withoutSignature = SignatureSwapper.swap(in: withoutHistory, newSignature: nil)
        return withoutSignature.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the replied-to text could change `extract` for `raw`.
    public static func needsRepliedToText(_ raw: String) -> Bool {
        QuotedHistoryTail.needsRepliedToText(raw)
    }
}
