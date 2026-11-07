import CryptoKit
import Foundation

public enum DraftRemoteSyncFingerprint {
    public static func value(for draft: Draft) -> String {
        let effectiveReplyRecipients = ReplyRecipientPolicy.effectiveRecipients(for: draft)
        let parts = [
            "kind=\(draft.kind?.rawValue ?? "replyToMessage")",
            "status=\(draft.status.rawValue)",
            "fromAccount=\(draft.composeFromAccountID?.uuidString ?? "")",
            "identity=\(draft.fromIdentityID?.uuidString ?? "")",
            "to=\(draft.composeToJSON ?? "")",
            "cc=\(draft.composeCcJSON ?? "")",
            "bcc=\(draft.composeBccJSON ?? "")",
            "replyTo=\(draft.replyToAddressesJSON ?? "")",
            "replyCc=\(draft.replyCcAddressesJSON ?? "")",
            "replyBcc=\(draft.replyBccAddressesJSON ?? "")",
            "replyMode=\(draft.resolvedReplyRecipientMode.rawValue)",
            "effectiveReplyTo=\(effectiveReplyRecipients.to.joined(separator: ","))",
            "effectiveReplyCc=\(effectiveReplyRecipients.cc.joined(separator: ","))",
            "effectiveReplyBcc=\(effectiveReplyRecipients.bcc.joined(separator: ","))",
            "subject=\(draft.composeSubject ?? "")",
            "body=\(draft.replyText)",
            "format=\(draft.resolvedMessageFormat.rawValue)",
            "html=\(draft.bodyHTML ?? "")",
            "inlinePhotos=\(draft.inlinePhotosJSON ?? "")",
            "attachments=\(draft.deliverablesJSON ?? "")",
            "replyAttachments=\(draft.replyAttachmentPathsJSON ?? "")",
            "message=\(draft.message?.id.uuidString ?? "")",
            "messageSubject=\(draft.message?.subject ?? "")",
            "messageFrom=\(draft.message?.fromAddress ?? "")",
            "messageReplyTo=\(draft.message?.replyToAddressesJSON ?? "")",
            "inReplyTo=\(draft.message?.messageIdHeader ?? "")",
            "references=\(draft.message?.referencesChain ?? "")"
        ]
        let data = Data(parts.joined(separator: "\u{1F}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
