import Foundation

/// Resolves which saved signature applies to a draft.
///
/// Precedence: the draft's stamped `signatureSlotID` when that slot still
/// exists on the account → the account's default slot when the stamp is
/// stale (slot deleted) → nil (unsigned). A nil stamp means the user chose
/// "No Signature" (or the draft predates slots) and resolves to nil —
/// creation seams stamp the account default explicitly, so nil is always
/// an intentional absence, never "not yet decided".
public enum SignatureSlotResolver {

    public static func slot(for draft: Draft, account: Account?) -> SignatureSlot? {
        guard let account else { return nil }
        guard let stamped = draft.signatureSlotID else { return nil }
        if let match = account.signatureSlots.first(where: { $0.id == stamped }) {
            return match
        }
        return account.defaultSignatureSlot
    }

    /// The plain-text signature body for `SignatureSwapper` mechanics, or
    /// nil when the draft is unsigned. Never returns an empty string.
    public static func plainTextSignature(for draft: Draft, account: Account?) -> String? {
        guard let slot = slot(for: draft, account: account) else { return nil }
        let text = slot.plainText
        return text.isEmpty ? nil : text
    }
}
