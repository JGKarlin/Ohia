import Foundation

/// The rendering family a saved signature belongs to. Plain-text slots
/// carry only `plainText`; both HTML formats carry canonical HTML whose
/// `<img>` sources use the `ohia-sig://` token scheme (see
/// `SignatureImageToken`).
public enum SignatureFormat: String, Codable, Sendable, CaseIterable {
    case plainText
    case html
    case htmlWithImages

    public var displayName: String {
        switch self {
        case .plainText:      "Plain Text"
        case .html:           "HTML"
        case .htmlWithImages: "HTML + Image"
        }
    }
}

/// How much contact information a generated signature exposes. Tiers are
/// strictly additive and rank by `SignatureFieldKind.tier`, the single
/// source of truth the prompt builder, the privacy scrub, and the template
/// composer all share.
public enum SignatureTier: String, Codable, Sendable, CaseIterable {
    case minimal
    case standard
    case detailed

    public var displayName: String {
        switch self {
        case .minimal:  "Minimal"
        case .standard: "Standard"
        case .detailed: "Detailed"
        }
    }

    /// Additive rank: a tier admits every kind ranked at or below it.
    var rank: Int {
        switch self {
        case .minimal:  0
        case .standard: 1
        case .detailed: 2
        }
    }

    public func allows(_ kind: SignatureFieldKind) -> Bool {
        kind.tier.rank <= rank
    }
}

/// One labeled line of the signature's contact block: a label (a preset
/// kind, or `.custom` with user-typed text) and the user-vetted value. Row
/// order is the order the prompt states the facts in, which is what steers
/// the generated layout's fact sequence.
public struct SignatureContactLine: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: SignatureFieldKind
    /// User-typed label; meaningful only for `.custom`.
    public var customLabel: String?
    public var value: String

    public init(
        id: UUID = UUID(),
        kind: SignatureFieldKind,
        customLabel: String? = nil,
        value: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.customLabel = customLabel
        self.value = value
    }

    /// The label shown in the form and stated in the prompt. A `.custom`
    /// row with no typed label yet falls back to the generic name so the
    /// prompt never emits a bare colon.
    public var displayLabel: String {
        guard kind == .custom else { return kind.displayName }
        let trimmed = (customLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    /// The trimmed value, or nil when the row is empty (empty rows never
    /// reach the prompt).
    public var trimmedValue: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Individual values for the privacy scrub: each phone number in a
    /// comma-separated row is checked separately so a partial leak is still
    /// caught.
    public var scrubValues: [String] {
        guard let trimmedValue else { return [] }
        guard kind.holdsMultipleValues else { return [trimmedValue] }
        // Comma is what the field's placeholder asks for, but "·" is the
        // separator this app used to join multiple numbers, so a value
        // carried over in that shape must still split — an unsplit run
        // makes the scrub compare one concatenated digit stream and miss a
        // model that rendered a single number.
        return trimmedValue
            .components(separatedBy: CharacterSet(charactersIn: ",·"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every link this row's value justifies — one per value for
    /// multi-value phone rows, so each number gets its own `tel:` target.
    public var linkTargets: [String] {
        scrubValues.compactMap { kind.linkTarget(for: $0) }
    }
}

/// User-vetted contact details driving generation: an ordered, editable
/// list of labeled lines. Name is pinned first and never deleted; every
/// other row can be removed, reordered, or added from the label catalog.
///
/// Values come only from the user-vetted contact form — never directly
/// from Contacts.
public struct SignatureContactFields: Codable, Sendable, Equatable {
    public private(set) var lines: [SignatureContactLine]

    public init(lines: [SignatureContactLine] = [SignatureContactLine(kind: .name)]) {
        self.lines = lines
        normalize()
    }

    /// Convenience for the me-card fallback and tests: builds the default
    /// row order, dropping kinds with no value (Name always survives).
    public init(values: [(SignatureFieldKind, String?)]) {
        self.lines = values.compactMap { kind, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return SignatureContactLine(kind: kind, value: value)
        }
        normalize()
    }

    /// Name first, always present. Everything else keeps user order.
    private mutating func normalize() {
        if let index = lines.firstIndex(where: { $0.kind == .name }) {
            let name = lines.remove(at: index)
            lines.insert(name, at: 0)
        } else {
            lines.insert(SignatureContactLine(kind: .name), at: 0)
        }
    }

    // MARK: - Reading

    /// Rows with a non-empty value, in user order.
    public var populatedLines: [SignatureContactLine] {
        lines.filter { $0.trimmedValue != nil }
    }

    /// Populated rows this tier admits, in user order.
    public func lines(allowedIn tier: SignatureTier) -> [SignatureContactLine] {
        populatedLines.filter { tier.allows($0.kind) }
    }

    /// Populated rows this tier excludes — the prompt names their labels as
    /// forbidden and the parser scrubs their values from the output.
    public func lines(forbiddenIn tier: SignatureTier) -> [SignatureContactLine] {
        populatedLines.filter { !tier.allows($0.kind) }
    }

    /// Every string that must not survive in this tier's output: the raw
    /// values *and* the links they derive.
    ///
    /// The links matter as much as the values. A handle is stated as
    /// "@amorgan" but its profile URL is ".../amorgan" — the `@` is
    /// stripped — so scrubbing the raw value alone never matches the href,
    /// and a link whose visible text reads "Profile" hides the value
    /// entirely from a rendered-text check. Both halves are forbidden
    /// together or a tier-forbidden account ships as a working link.
    public func forbiddenValues(in tier: SignatureTier) -> [String] {
        lines(forbiddenIn: tier).flatMap { $0.scrubValues + $0.linkTargets }
    }

    /// Every URL a vetted value justifies *that this tier admits* — the
    /// allowlist the sanitizer's `LinkPolicy` enforces. `tel:` and
    /// `mailto:` are permitted by the policy itself, so only http(s)
    /// targets matter here.
    ///
    /// Tier-scoped deliberately: an unscoped allowlist would let a minimal
    /// signature keep a link to a field the minimal tier forbids, which is
    /// exactly the leak the scrub exists to prevent.
    public func allowedLinkURLs(in tier: SignatureTier) -> [String] {
        lines(allowedIn: tier).flatMap(\.linkTargets).filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://")
        }
    }

    /// Every link target this tier admits, in any scheme — what the prompt
    /// tells the model it may point at.
    public func allowedLinkTargets(in tier: SignatureTier) -> [String] {
        lines(allowedIn: tier).flatMap(\.linkTargets)
    }

    public func line(for kind: SignatureFieldKind) -> SignatureContactLine? {
        lines.first { $0.kind == kind }
    }

    /// The non-empty value for a kind; nil when absent or blank.
    public func value(for kind: SignatureFieldKind) -> String? {
        line(for: kind)?.trimmedValue
    }

    /// Kinds the add-line pulldown still offers: everything not already in
    /// use, plus the repeatable ones.
    public var availableKinds: [SignatureFieldKind] {
        let used = Set(lines.map(\.kind))
        return SignatureFieldKind.allCases.filter {
            $0.isRepeatable || !used.contains($0)
        }
    }

    // MARK: - Editing

    public mutating func setValue(_ value: String, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].value = value
    }

    /// Sets the value of the row for `kind`, adding the row if absent.
    /// Convenience for callers that key by label rather than by row id;
    /// `.custom` is rejected because it names no single row.
    public mutating func setValue(_ value: String, for kind: SignatureFieldKind) {
        guard kind != .custom else { return }
        if let index = lines.firstIndex(where: { $0.kind == kind }) {
            lines[index].value = value
        } else {
            lines.append(SignatureContactLine(kind: kind, value: value))
        }
    }

    public mutating func setCustomLabel(_ label: String, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }),
              lines[index].kind == .custom else { return }
        lines[index].customLabel = label
    }

    /// Appends a row for `kind`. A non-repeatable kind already in use is a
    /// no-op — the pulldown hides it, and this keeps that invariant true
    /// even if a caller asks twice.
    @discardableResult
    public mutating func addLine(kind: SignatureFieldKind, customLabel: String? = nil) -> UUID? {
        guard kind.isRepeatable || !lines.contains(where: { $0.kind == kind }) else {
            return nil
        }
        let line = SignatureContactLine(kind: kind, customLabel: customLabel)
        lines.append(line)
        return line.id
    }

    /// Removes a row. Name is never removable.
    public mutating func removeLine(id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }),
              lines[index].kind.isDeletable else { return }
        lines.remove(at: index)
    }

    /// Moves a row to `destination` (a `ForEach.onMove`-style index into
    /// the pre-move array). Name stays pinned at index 0: it cannot be
    /// moved, and nothing can be inserted above it.
    public mutating func moveLine(id: UUID, toOffset destination: Int) {
        guard let source = lines.firstIndex(where: { $0.id == id }),
              lines[source].kind != .name else { return }
        let clamped = min(max(destination, 1), lines.count)
        guard clamped != source, clamped != source + 1 else { return }
        let line = lines.remove(at: source)
        lines.insert(line, at: clamped > source ? clamped - 1 : clamped)
    }
}

/// What kind of picture the user supplied; steers layout during generation.
/// Detected by `SignatureImageClassifier` (OhiaML), always user-overridable.
public enum SignatureImageType: String, Codable, Sendable, CaseIterable {
    case headshot
    case logo
    case banner

    public var displayName: String {
        switch self {
        case .headshot: "Headshot"
        case .logo:     "Logo"
        case .banner:   "Banner"
        }
    }

    /// Deterministic display size stamped onto `<img>` tags so send-side
    /// rendering never depends on the model emitting sane dimensions.
    /// Height-only for logos preserves aspect; width-only for banners.
    public var stampedWidth: Int? {
        switch self {
        case .headshot: 72
        case .logo:     nil
        case .banner:   480
        }
    }

    public var stampedHeight: Int? {
        switch self {
        case .headshot: 72
        case .logo:     40
        case .banner:   nil
        }
    }
}

/// One image file owned by a signature slot, stored on disk at
/// `Application Support/Ohia/Signatures/<ownerID>/<id>.<fileExtension>`.
public struct SignatureImageAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fileExtension: String
    public var mimeType: String
    public var imageTypeRaw: String

    public init(
        id: UUID = UUID(),
        fileExtension: String,
        mimeType: String,
        imageType: SignatureImageType
    ) {
        self.id = id
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.imageTypeRaw = imageType.rawValue
    }

    public var imageType: SignatureImageType {
        SignatureImageType(rawValue: imageTypeRaw) ?? .logo
    }

    public var fileName: String { "\(id.uuidString.lowercased()).\(fileExtension)" }

    /// The MIME Content-ID (without angle brackets) for this asset. Derived
    /// from the asset id so retried sends stay byte-identical.
    public var contentID: String { "sig-\(id.uuidString.lowercased())@ohia" }
}

/// The `ohia-sig://<ownerID>/<imageID>` token URL used as the canonical
/// `<img src>` in stored signature HTML. `ownerID` is the slot id (or the
/// design-session id before a slot exists). Send, preview, and editor each
/// translate tokens deterministically — the token itself never ships.
public enum SignatureImageToken {
    public static let scheme = "ohia-sig"

    public static func url(ownerID: UUID, assetID: UUID) -> String {
        "\(scheme)://\(ownerID.uuidString.lowercased())/\(assetID.uuidString.lowercased())"
    }

    /// Parses a token URL back into its ids. Returns nil for any other URL.
    public static func parse(_ string: String) -> (ownerID: UUID, assetID: UUID)? {
        let lower = string.lowercased()
        let prefix = "\(scheme)://"
        guard lower.hasPrefix(prefix) else { return nil }
        let parts = lower.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 2,
              let owner = UUID(uuidString: String(parts[0])),
              let asset = UUID(uuidString: String(parts[1])) else { return nil }
        return (owner, asset)
    }
}

/// Codable envelope for `SignatureSlot.imagesJSON`.
public enum SignatureImageAssetCoding {
    public static func encode(_ assets: [SignatureImageAsset]) -> String? {
        guard !assets.isEmpty,
              let data = try? JSONEncoder().encode(assets) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String?) -> [SignatureImageAsset] {
        guard let json, let data = json.data(using: .utf8),
              let assets = try? JSONDecoder().decode([SignatureImageAsset].self, from: data) else {
            return []
        }
        return assets
    }
}
