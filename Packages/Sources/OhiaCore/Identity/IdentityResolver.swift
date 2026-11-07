import Foundation

/// Resolves the default reply-From identity for an inbound message.
/// Replies start from the account's primary authenticated identity rather
/// than promoting a receiving alias from the inbound To/Cc headers into the
/// sender identity. A user can still choose another configured identity in
/// the Composer. Returns nil only when the account has no identities at all
/// (a pre-migration defensive case that should not occur in production).
public enum IdentityResolver {

    @MainActor
    public static func resolveReplyIdentity(message: Message) -> Identity? {
        guard let account = message.account else { return nil }
        let identities = account.identities
        guard !identities.isEmpty else { return nil }
        return identities.first(where: \.isPrimary) ?? identities.first
    }
}
