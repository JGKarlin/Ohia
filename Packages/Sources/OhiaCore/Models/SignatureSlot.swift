import Foundation
import SwiftData

/// A saved, account-scoped email signature. Slots are the only signature
/// system: `Identity.legacySignature` exists solely so the boot migration
/// can seed initial slots from pre-slot installs.
///
/// `plainText` is always populated and is authoritative for the
/// `text/plain` MIME alternative and for `SignatureSwapper` body
/// mechanics. `html` is canonical for the two HTML formats and is stored
/// post Cocoa round-trip (import → export once at save) so hand-edits in
/// the rich editor are idempotent. Image `<img src>` values in `html` use
/// the `ohia-sig://` token scheme; the files live under
/// `Application Support/Ohia/Signatures/<slot-id>/`.
@Model
public final class SignatureSlot {
    public var id: UUID
    public var account: Account?
    public var name: String
    public var formatRaw: String?
    public var plainText: String
    public var html: String?
    /// JSON `[SignatureImageAsset]`; nil when the slot owns no images.
    public var imagesJSON: String?
    /// Provenance: which detail tier generated this slot, when it came out
    /// of the design studio. Nil for migrated or hand-made slots.
    public var tierRaw: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        format: SignatureFormat,
        plainText: String,
        html: String? = nil,
        images: [SignatureImageAsset] = [],
        tier: SignatureTier? = nil,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.formatRaw = format.rawValue
        self.plainText = plainText
        self.html = html
        self.imagesJSON = SignatureImageAssetCoding.encode(images)
        self.tierRaw = tier?.rawValue
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var format: SignatureFormat {
        get {
            guard let raw = formatRaw,
                  let format = SignatureFormat(rawValue: raw) else { return .plainText }
            return format
        }
        set { formatRaw = newValue.rawValue }
    }

    public var tier: SignatureTier? {
        get { tierRaw.flatMap(SignatureTier.init(rawValue:)) }
        set { tierRaw = newValue?.rawValue }
    }

    public var images: [SignatureImageAsset] {
        get { SignatureImageAssetCoding.decode(imagesJSON) }
        set { imagesJSON = SignatureImageAssetCoding.encode(newValue) }
    }

    /// True when drafts using this slot need the rich (HTML) apply path.
    public var isRich: Bool {
        format != .plainText && html?.isEmpty == false
    }
}
