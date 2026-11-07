import SwiftUI
import AppKit
import OhiaCore

/// Light/dark normalization envelope applied to `AccountColorPalette`
/// entries before they're rendered as a UI accent. The same envelope
/// drives `AnnotationKind.accent`, `LockedNodeOverlay.lockAccentColor`,
/// and `LockedOverlayProjectionColors.accent(for:)` so the locked
/// overlay's seven evidence accents and the focal-message accent all
/// adapt to mode consistently.
///
/// Dark mode keeps brightness at full and saturation conservative (the
/// dark toolbar background `#050508` lifts color naturally). Light
/// mode drops brightness to 0.78 — so colors read as darker, weightier
/// hues against the `#f6f6f6` toolbar instead of washing out — and
/// raises the saturation floor to 0.60 to compensate, since a
/// brightness-reduced low-saturation HSV reads as flat grey.
struct PaletteAccentEnvelope {
    let brightness: Double
    let saturationFloor: Double
    let saturationCeiling: Double

    static let dark = PaletteAccentEnvelope(
        brightness: 1.0,
        saturationFloor: 0.45,
        saturationCeiling: 0.85
    )

    static let light = PaletteAccentEnvelope(
        brightness: 0.78,
        saturationFloor: 0.60,
        saturationCeiling: 0.95
    )

    /// Pick the envelope matching the appearance the system is rendering
    /// in. Called from inside an `NSColor(name:dynamicProvider:)` closure.
    static func current(for appearance: NSAppearance) -> PaletteAccentEnvelope {
        let isDark = appearance.bestMatch(from: [
            .darkAqua,
            .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark
        ]) != nil
        return isDark ? .dark : .light
    }

    /// Resolve an `AccountColor` through this envelope into an sRGB triple.
    /// Used by both `AnnotationKind` and `LockedNodeOverlay` so every
    /// space-palette accent in the locked overlay routes through one
    /// conversion path — no chance of two callers picking the same
    /// palette entry but rendering slightly different hues.
    func sRGB(for accountColor: AccountColor) -> SIMD4<Float> {
        let clamped = max(saturationFloor, min(accountColor.saturation, saturationCeiling))
        let normalized = AccountColor(
            id: accountColor.id,
            name: accountColor.name,
            hue: accountColor.hue,
            saturation: clamped
        )
        return AccountColorPalette.rgb(for: normalized, brightness: brightness)
    }
}

enum AnnotationKind: String, Sendable, CaseIterable {
    /// The locked email itself — first chip, first Tab stop. Not an
    /// annotation in the AnnotationItem sense; the lock card is its
    /// "popup". Modeled as a kind so it shares the chip strip / tab-loop /
    /// accent-color machinery with the evidence panes.
    case mainEmail
    /// The focused correspondent itself in a People-layer lock. Like
    /// `.mainEmail`, this is a focal index entry rather than an
    /// `AnnotationItem`; the rendered Metal hub is the visible object.
    case correspondent
    case bodyChunk
    case attachment
    case entity
    case thread
    /// A message sent by the user as a reply in the locked thread.
    case reply
    /// People-layer moon: a message directly from the focused correspondent
    /// (focused person is the sender; user is the recipient). Rendered on
    /// the `.receivedDirect` Saturn ring.
    case peopleInbound
    /// People-layer moon: a message the user sent to the focused
    /// correspondent on the To: line (direct outbound). Rendered on the
    /// `.sentDirect` Saturn ring.
    case peopleReply
    /// People-layer moon: a third-party message where someone else wrote
    /// to the user and the focused correspondent was Cc'd alongside.
    /// Rendered on the `.included` Saturn ring (outermost).
    case peopleShared
    /// People-layer moon: a message the user sent where the focused
    /// correspondent was on Cc:/Bcc: alongside someone else who was the
    /// primary To: recipient. Rendered on the `.sentIncluded` Saturn
    /// ring (second from center).
    case peopleReplyShared
    /// Cosine-similar message **from the same correspondent** as the locked
    /// email. Reveals "this is part of an ongoing relationship/topic with
    /// the same person."
    case threadRelative
    /// Cosine-similar message from a **different correspondent**. Reveals
    /// "other people have written about this same topic" — genuinely new
    /// context the locked thread doesn't already carry.
    case topicRelative

    var typeTag: String {
        switch self {
        case .mainEmail: return "main"
        case .correspondent: return "person"
        case .bodyChunk: return "body"
        case .attachment: return "attach"
        case .entity: return "entity"
        case .thread: return "thread"
        case .reply: return "reply"
        case .peopleInbound: return "people-in"
        case .peopleReply: return "people-out"
        case .peopleShared: return "people-shared"
        case .peopleReplyShared: return "people-out-shared"
        case .threadRelative: return "thread-rel"
        case .topicRelative: return "topic-rel"
        }
    }

    var contextLabel: String {
        switch self {
        case .mainEmail: return "this email"
        case .correspondent: return "correspondent"
        case .bodyChunk: return "body passage"
        case .attachment: return "attachment"
        case .entity: return "mention"
        case .thread: return "thread message"
        case .reply: return "reply"
        case .peopleInbound: return "received"
        case .peopleReply: return "sent"
        case .peopleShared: return "cc'd"
        case .peopleReplyShared: return "sent · cc'd"
        case .threadRelative: return "from same person"
        case .topicRelative: return "from elsewhere"
        }
    }

    nonisolated var priority: Int {
        switch self {
        // Lowest fallback priority so any taxonomy-ordered surface still
        // leads with the locked email.
        case .mainEmail: return -1
        case .correspondent: return -2
        case .bodyChunk: return 0
        case .attachment: return 1
        case .entity: return 2
        case .thread: return 3
        case .reply: return 4
        case .peopleReply: return 3
        case .peopleReplyShared: return 4
        case .peopleInbound: return 5
        case .peopleShared: return 6
        case .threadRelative: return 5
        case .topicRelative: return 6
        }
    }

    /// Index into `AccountColorPalette` that the evidence kind borrows
    /// its accent from. `nil` for `.mainEmail` (which renders the
    /// per-account color of the locked email through
    /// `LockedNodeOverlay.lockAccentColor`).
    ///
    /// The whole annotation surface lives in the space-color palette
    /// universe so the locked overlay reads as one visual register.
    /// Kind colors are sampled from the same 12-entry palette accounts
    /// use; the seven kinds below cover seven distinct palette entries,
    /// preserving each evidence kind's semantic intent (cool blue for
    /// structural body, green for files, orange for mentions, indigo for
    /// conversation, gold for outbound replies, pink for same-person-
    /// different-thread, violet for cross-correspondent).
    var paletteIndex: Int? {
        switch self {
        case .mainEmail: return nil
        case .correspondent: return nil
        case .bodyChunk: return 1     // Vega Blue
        case .attachment: return 10   // Ohia Green
        case .entity: return 7        // Arcturus Orange
        case .thread: return 2        // Pleiades Indigo
        case .reply: return 8         // Capella Gold
        // People-kind palette entries are only used when the lock accent
        // override is unavailable (preview / test). Live chips & popups
        // route through the per-account lock accent shaded by the
        // matching `PersonRingInstance.Tier`, so the chip color matches
        // its ring. See `LockedPanesIndex.accent(for:)`.
        case .peopleInbound: return 10 // Ohia Green (fallback)
        case .peopleReply: return 8    // Capella Gold (fallback)
        case .peopleShared: return 3   // Trapezium Violet (fallback)
        case .peopleReplyShared: return 4 // Cygnus Cyan (fallback)
        case .threadRelative: return 5 // Eagle Pink
        case .topicRelative: return 3  // Trapezium Violet
        }
    }

    var accent: Color {
        // `.mainEmail` falls through to a static pink only as a safety
        // net. Live focal-message chrome routes through
        // `LockedNodeOverlay.lockAccentColor` (per-account hue), and
        // `AnnotationPopup` / `AnnotationMinBadge` never instantiate
        // `.mainEmail`, so this branch is effectively dead code.
        guard let index = paletteIndex else {
            return OhiaColors.accentPink
        }
        return AnnotationKind.swiftUIColor(forPaletteIndex: index)
    }

    /// Mode-aware accent for a palette entry. The returned `Color` wraps
    /// a dynamic `NSColor` whose closure re-evaluates the
    /// `PaletteAccentEnvelope` at draw time, so switching between Light
    /// and Dark in Settings → General re-resolves the hue without the
    /// view needing to invalidate. Same sRGB-direct path the AppKit
    /// twin (`LockedOverlayProjectionColors.accent(for:)`) uses, so
    /// SwiftUI chips and CGContext leader lines land on the exact
    /// same hue with zero color-space drift on wide-gamut displays.
    static func swiftUIColor(forPaletteIndex index: Int) -> Color {
        Color(nsColor: nsColor(forPaletteIndex: index))
    }

    /// AppKit twin of `swiftUIColor(forPaletteIndex:)`. Same envelope,
    /// same sRGB triple — see that helper for the rationale.
    static func nsColor(forPaletteIndex index: Int) -> NSColor {
        let palette = AccountColorPalette.color(forIndex: index)
        return NSColor(name: nil) { appearance in
            let env = PaletteAccentEnvelope.current(for: appearance)
            let rgb = env.sRGB(for: palette)
            return NSColor(
                srgbRed: CGFloat(rgb.x),
                green: CGFloat(rgb.y),
                blue: CGFloat(rgb.z),
                alpha: 1.0
            )
        }
    }

    var badgePrefix: String {
        switch self {
        case .mainEmail: return "main"
        case .correspondent: return "person"
        case .bodyChunk: return "body"
        case .attachment: return "att"
        case .entity: return "mention"
        case .thread: return "thread"
        case .reply: return "reply"
        case .peopleInbound: return "received"
        case .peopleReply: return "sent"
        case .peopleShared: return "cc'd"
        case .peopleReplyShared: return "sent·cc'd"
        case .threadRelative: return "same"
        case .topicRelative: return "topic"
        }
    }

    /// SF Symbol used in the kind-chip TOC at the top of the CONTEXT
    /// pane. Each kind picks an icon that visually disambiguates it from
    /// the others in a 14pt slot.
    var symbolName: String {
        switch self {
        // Open envelope — the message itself, currently being read.
        case .mainEmail: return "envelope.open"
        case .correspondent: return "person.crop.circle.fill"
        case .bodyChunk: return "text.alignleft"
        case .attachment: return "paperclip"
        case .entity: return "tag"
        case .thread: return "bubble.left.and.bubble.right"
        case .reply: return "paperplane.fill"
        case .peopleInbound: return "tray.and.arrow.down"
        case .peopleReply: return "paperplane.fill"
        case .peopleShared: return "person.2.fill"
        // Outbound + included: outline paperplane (vs the filled
        // `peopleReply` variant) reads as "sent, but this person was
        // alongside someone else" — same direction as `.peopleReply`,
        // weighted lighter for the peripheral relationship.
        case .peopleReplyShared: return "paperplane"
        // Same-correspondent: a single profile silhouette — "this is the
        // same person continuing".
        case .threadRelative: return "person.crop.circle"
        // Cross-correspondent: a network glyph — "different sources, same
        // topic".
        case .topicRelative: return "circle.hexagongrid"
        }
    }

    /// Short plural label used in chip counts.
    /// "5 attachments", "3 from same person", etc.
    var pluralLabel: String {
        switch self {
        case .mainEmail: return "this email"
        case .correspondent: return "correspondent"
        case .bodyChunk: return "body passages"
        case .attachment: return "attachments"
        case .entity: return "mentions"
        case .thread: return "thread messages"
        case .reply: return "replies"
        case .peopleInbound: return "received"
        case .peopleReply: return "sent"
        case .peopleShared: return "cc'd"
        case .peopleReplyShared: return "sent · cc'd"
        case .threadRelative: return "from same person"
        case .topicRelative: return "from elsewhere"
        }
    }

    /// Long-form, one-sentence description. Used only for the chip's
    /// VoiceOver `accessibilityLabel`, where a full sentence reads well.
    /// The *visible* hover tooltip uses the terser ``tabTooltip`` instead —
    /// `.help()` renders in a single small rect and wraps a full sentence
    /// into an awkward multi-line block.
    var description: String {
        switch self {
        case .mainEmail:
            return "The locked email itself. Press space to show or hide its body text."
        case .correspondent:
            return "The focused correspondent planet in this People-layer slice."
        case .bodyChunk:
            return "Embedded passages of this email's body."
        case .attachment:
            return "Files attached to this email."
        case .entity:
            return "People, documents, and topics this email mentions."
        case .thread:
            return "Sibling messages in the same conversation."
        case .reply:
            return "Replies you sent."
        case .peopleInbound:
            return "Messages sent by the focused correspondent."
        case .peopleReply:
            return "Messages you sent to the focused correspondent."
        case .peopleShared:
            return "Messages from other people that include the focused correspondent."
        case .peopleReplyShared:
            return "Messages you sent that included the focused correspondent alongside someone else."
        case .threadRelative:
            return "Semantically similar messages from the same correspondent."
        case .topicRelative:
            return "Semantically similar messages from different correspondents."
        }
    }

    /// Terse (≤6-word) phrase shown in the chip's visible `.help()` hover
    /// tooltip. Names what the chip represents in one short line that
    /// `.help()` renders without wrapping — the count and click behaviour
    /// are intentionally omitted, since the chip already shows its count and
    /// cycling on click is self-evident. The full sentence lives in
    /// ``description`` for the accessibility label.
    var tabTooltip: String {
        switch self {
        case .mainEmail: return "The locked email itself"
        case .correspondent: return "The focused correspondent"
        case .bodyChunk: return "Passages of this email's body"
        case .attachment: return "Files on this email"
        case .entity: return "People and topics mentioned"
        case .thread: return "Others in this conversation"
        case .reply: return "Replies you sent"
        case .peopleInbound: return "Sent by this contact"
        case .peopleReply: return "Your replies to them"
        case .peopleShared: return "Others' mail that Cc's them"
        case .peopleReplyShared: return "Your sends that Cc'd them"
        case .threadRelative: return "Similar mail from this person"
        case .topicRelative: return "Similar mail from others"
        }
    }

    /// The 4 People-lens ring tiers the kind maps onto. Chip rendering
    /// uses this to shade the per-account lock accent the same way
    /// `PeopleGraphBuilder` shades the corresponding ring band, so chips
    /// and rings stay in lockstep. `nil` for kinds that don't render on a
    /// ring (every non-People kind).
    var personRingTier: PersonRingInstance.Tier? {
        switch self {
        case .peopleInbound: return .receivedDirect
        case .peopleReply: return .sentDirect
        case .peopleShared: return .included
        case .peopleReplyShared: return .sentIncluded
        default: return nil
        }
    }

    /// People focus ring/chip traversal order. Mirrors
    /// `PersonRingInstance.Tier.insideOutOrder` so keyboard Tab order,
    /// chip order, and visible Saturn ring order stay aligned.
    nonisolated static var peopleRingTraversalOrder: [AnnotationKind] {
        PersonRingInstance.Tier.insideOutOrder.map { tier in
            switch tier {
            case .receivedDirect: return .peopleInbound
            case .included: return .peopleShared
            case .sentDirect: return .peopleReply
            case .sentIncluded: return .peopleReplyShared
            }
        }
    }

    /// SwiftUI accent for a People chip. Under the Twilight schema
    /// each tier carries a fixed sRGB triple (peach → dusty rose →
    /// slate-blue → midnight slate) — the chip uses the same triple as the
    /// matching Saturn ring band, so chip and ring are identical
    /// regardless of which account the planet belongs to. The
    /// `lockAccent` parameter is retained on the signature for callers
    /// (kept opt-in for non-People kinds via the focal-pane override
    /// path in `LockedPanesIndex.accent(for:)`), but does not influence
    /// People-kind chips under this schema.
    func peopleChipAccent(lockAccent: Color?) -> Color {
        guard let tier = personRingTier else {
            return accent
        }
        _ = lockAccent
        let rgb = tier.tierColor
        return Color(
            .sRGB,
            red: Double(rgb.x),
            green: Double(rgb.y),
            blue: Double(rgb.z),
            opacity: Double(tier.ringAlpha)
        )
    }
}
