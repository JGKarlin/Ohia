import Foundation

/// The pulldown grouping a label appears under when adding a line. Purely
/// presentational — the tier rank each kind carries is what gates content.
public enum SignatureFieldCategory: String, Codable, Sendable, CaseIterable {
    case identity
    case contact
    case social
    case professional
    case other

    public var displayName: String {
        switch self {
        case .identity:     "Identity"
        case .contact:      "Contact"
        case .social:       "Social"
        case .professional: "Professional"
        case .other:        "Other"
        }
    }
}

/// The label a signature line carries. Every kind declares its own tier
/// rank, so adding a label to this enum is the only step needed to make it
/// available everywhere: the pulldown, the prompt, the privacy scrub, and
/// the deterministic template all read from here.
///
/// `.custom` is the one kind that repeats and whose label is user-typed;
/// every other kind appears at most once in a `SignatureContactFields`.
public enum SignatureFieldKind: String, Codable, Sendable, CaseIterable {
    // Identity — minimal and up.
    case name
    case title
    case organization

    // Contact channels — standard and up.
    case email
    case phone
    case mobile
    case office
    case fax
    case website

    // Social — detailed only.
    case x
    case instagram
    case linkedIn
    case bluesky
    case mastodon
    case github
    case youtube
    case facebook
    case threads
    case tiktok
    case whatsapp
    case signal
    case telegram
    case wechat
    case line
    case discord

    // Professional — detailed only.
    case license
    case credentials
    case pronouns
    case orcid
    case schedulingLink
    case department
    case lab
    case officeHours
    case assistant

    // Other — detailed only.
    case postalAddress
    case custom

    public var displayName: String {
        switch self {
        case .name:           "Name"
        case .title:          "Title"
        case .organization:   "Organization"
        case .email:          "Email"
        case .phone:          "Phone"
        case .mobile:         "Mobile"
        case .office:         "Office"
        case .fax:            "Fax"
        case .website:        "Website"
        case .x:              "X"
        case .instagram:      "Instagram"
        case .linkedIn:       "LinkedIn"
        case .bluesky:        "Bluesky"
        case .mastodon:       "Mastodon"
        case .github:         "GitHub"
        case .youtube:        "YouTube"
        case .facebook:       "Facebook"
        case .threads:        "Threads"
        case .tiktok:         "TikTok"
        case .whatsapp:       "WhatsApp"
        case .signal:         "Signal"
        case .telegram:       "Telegram"
        case .wechat:         "WeChat"
        case .line:           "LINE"
        case .discord:        "Discord"
        case .license:        "License"
        case .credentials:    "Credentials"
        case .pronouns:       "Pronouns"
        case .orcid:          "ORCID"
        case .schedulingLink: "Scheduling link"
        case .department:     "Department"
        case .lab:            "Lab"
        case .officeHours:    "Office hours"
        case .assistant:      "Assistant"
        case .postalAddress:  "Business address"
        case .custom:         "Custom label"
        }
    }

    public var category: SignatureFieldCategory {
        switch self {
        case .name, .title, .organization:
            .identity
        case .email, .phone, .mobile, .office, .fax, .website:
            .contact
        case .x, .instagram, .linkedIn, .bluesky, .mastodon, .github, .youtube,
             .facebook, .threads, .tiktok, .whatsapp, .signal, .telegram,
             .wechat, .line, .discord:
            .social
        case .license, .credentials, .pronouns, .orcid, .schedulingLink,
             .department, .lab, .officeHours, .assistant:
            .professional
        // The postal address reads as a contact route but ranks as detailed
        // material, and filing it under Contact would contradict the form's
        // own caption ("contact routes from Standard"). Category and tier
        // agree here instead.
        case .postalAddress, .custom:
            .other
        }
    }

    /// The least-exposing tier this label may appear in; tiers are additive,
    /// so a `.standard` kind also appears in `.detailed`. This is the single
    /// source of truth behind both the prompt's field lists and the output
    /// parser's privacy scrub.
    public var tier: SignatureTier {
        switch self {
        case .name, .title, .organization:
            .minimal
        case .email, .phone, .mobile, .office, .fax, .website:
            .standard
        default:
            .detailed
        }
    }

    /// Only `.custom` may appear more than once — every other label names a
    /// single fact, and the add-line pulldown hides kinds already in use.
    public var isRepeatable: Bool { self == .custom }

    /// Name anchors every signature and is the one row the form will not
    /// delete (`SignatureContactFields` also pins it first).
    public var isDeletable: Bool { self != .name }

    /// True for labels whose value is a comma-separated list of numbers the
    /// privacy scrub must check individually — a partial leak of one number
    /// out of three still has to be caught.
    public var holdsMultipleValues: Bool {
        switch self {
        case .phone, .mobile, .office, .fax: true
        default:                             false
        }
    }

    /// Every kind offered in the add-line pulldown, grouped for display.
    public static func kinds(in category: SignatureFieldCategory) -> [SignatureFieldKind] {
        allCases.filter { $0.category == category }
    }

    // MARK: - Links

    /// The URL this label's value should link to, or nil when the label has
    /// no link semantics (a license number, a pronoun, an address) or the
    /// platform exposes no stable profile URL (Signal, WeChat, LINE,
    /// Discord). A value the user already typed as an absolute http(s) URL
    /// is always honored verbatim, whatever the label.
    ///
    /// Every non-nil result is fed to `SignatureHTMLSanitizer.LinkPolicy`,
    /// so a link the model invents that is not derivable from a vetted value
    /// cannot survive sanitization.
    public func linkTarget(for rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return value
        }

        switch self {
        case .email:
            return value.contains("@") ? "mailto:\(value)" : nil
        case .phone, .mobile, .office, .fax:
            let dialable = Self.dialableDigits(value)
            return dialable.isEmpty ? nil : "tel:\(dialable)"
        case .whatsapp:
            let digits = value.filter(\.isNumber)
            return digits.isEmpty ? nil : "https://wa.me/\(digits)"
        case .website, .schedulingLink:
            return Self.looksLikeHost(value) ? "https://\(value)" : nil
        case .orcid:
            let id = value.hasPrefix("orcid.org/")
                ? String(value.dropFirst("orcid.org/".count))
                : value
            return id.contains("-") ? "https://orcid.org/\(id)" : nil
        case .mastodon:
            // Fediverse handles are "@user@server" — the profile lives on
            // the user's own server, so the host comes from the handle.
            let parts = value.dropFirst(value.hasPrefix("@") ? 1 : 0)
                .split(separator: "@", omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return "https://\(parts[1])/@\(parts[0])"
        case .x:
            return Self.profileURL(host: "x.com", handle: value)
        case .instagram:
            return Self.profileURL(host: "instagram.com", handle: value)
        case .linkedIn:
            return Self.profileURL(host: "linkedin.com", path: "in/", handle: value)
        case .bluesky:
            return Self.profileURL(host: "bsky.app", path: "profile/", handle: value)
        case .github:
            return Self.profileURL(host: "github.com", handle: value)
        case .youtube:
            return Self.profileURL(host: "youtube.com", path: "@", handle: value)
        case .facebook:
            return Self.profileURL(host: "facebook.com", handle: value)
        case .threads:
            return Self.profileURL(host: "threads.net", path: "@", handle: value)
        case .tiktok:
            return Self.profileURL(host: "tiktok.com", path: "@", handle: value)
        case .telegram:
            return Self.profileURL(host: "t.me", handle: value)
        case .signal, .wechat, .discord, .line:
            // No stable public profile URL — these render as text.
            return nil
        case .name, .title, .organization, .postalAddress, .license,
             .credentials, .pronouns, .department, .lab, .officeHours,
             .assistant, .custom:
            return nil
        }
    }

    /// `tel:` targets keep a leading `+` and digits only — spaces, dashes,
    /// and parentheses are not dialable.
    static func dialableDigits(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        return value.hasPrefix("+") ? "+\(digits)" : digits
    }

    private static func profileURL(
        host: String,
        path: String = "",
        handle rawHandle: String
    ) -> String? {
        var handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        while handle.hasPrefix("@") { handle.removeFirst() }
        // A pasted "x.com/amorgan" is a host-shaped value, not a handle.
        if let slash = handle.firstIndex(of: "/"), handle.lowercased().hasPrefix(host) {
            handle = String(handle[handle.index(after: slash)...])
        }
        guard !handle.isEmpty,
              !handle.contains(" "),
              !handle.contains("/") else { return nil }
        return "https://\(host)/\(path)\(handle)"
    }

    /// A bare host ("example.org", "amorgan.org/cv") the user typed without
    /// a scheme. Rejects values with spaces or no dot — those are prose.
    private static func looksLikeHost(_ value: String) -> Bool {
        guard !value.contains(" "), value.contains(".") else { return false }
        let host = value.split(separator: "/").first.map(String.init) ?? value
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
