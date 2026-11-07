import Foundation
import SwiftData

/// A send-as identity attached to an `Account`. SMTP authentication
/// still happens against the account's credentials; identities only
/// change the outgoing `From` / `Reply-To` headers and the MAIL FROM
/// envelope sender.
@Model
public final class Identity {
    public var id: UUID
    public var account: Account?
    public var address: String          // RFC 5322 addr-spec, lowercased on init
    public var displayName: String?     // phrase shown in From header
    public var replyTo: String?         // optional Reply-To address
    /// Pre-slot plaintext signature. Dead storage: signatures live in
    /// account-scoped `SignatureSlot`s; the only permitted reader is
    /// `SignatureSlotMigrationApplier`, which seeds slots from this column
    /// and nils it. Never read at draft time.
    @Attribute(originalName: "signature")
    public var legacySignature: String?
    public var isPrimary: Bool
    public var createdAt: Date

    public init(
        address: String,
        displayName: String? = nil,
        replyTo: String? = nil,
        isPrimary: Bool = false
    ) {
        self.id = UUID()
        self.address = address.lowercased()
        self.displayName = displayName
        self.replyTo = replyTo
        self.isPrimary = isPrimary
        self.createdAt = Date()
    }
}
