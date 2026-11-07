import Foundation
import OhiaCore
import OhiaMail

enum ComposerMessageBodyHTML {
    /// Resolves the MIME HTML alternative for a draft. Rich drafts always get
    /// an HTML part, even when their generated body has not been manually
    /// formatted yet. Plain drafts deliberately return nil.
    ///
    /// When the editor has produced no HTML (a worker-generated draft the
    /// user never opened) and the draft's resolved signature slot is rich,
    /// the slot still reaches the wire: the plain body above the RFC 3676
    /// marker converts via `HTMLFromPlain` and the slot's canonical fragment
    /// is spliced in as the signature tail before `</body>`.
    static func resolve(for draft: Draft, slot: SignatureSlot?) -> String? {
        guard draft.resolvedMessageFormat == .richText else { return nil }
        if let html = draft.bodyHTML?.trimmingCharacters(in: .whitespacesAndNewlines),
           !html.isEmpty {
            return draft.bodyHTML
        }
        guard let slot, slot.isRich, let fragment = slot.html else {
            return HTMLFromPlain.convert(draft.replyText)
        }

        let body = draft.replyText
        let head: String
        if let range = body.range(of: SignatureSwapper.marker, options: .backwards) {
            head = String(body[..<range.lowerBound])
        } else {
            head = body
        }
        let doc = HTMLFromPlain.convert(head)
        // The visible "-- " separator line mirrors the plain alternative's
        // marker so both MIME alternatives read the same.
        let tail = "<p>-- </p>\n" + fragment + "\n"
        if let closing = doc.range(of: "</body>", options: [.backwards, .caseInsensitive]) {
            return doc.replacingCharacters(in: closing, with: tail + "</body>")
        }
        return doc + tail
    }
}
