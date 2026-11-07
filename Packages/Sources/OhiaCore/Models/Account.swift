import Foundation
import SwiftData

@Model
public final class Account {
    public var id: UUID
    public var displayName: String
    public var emailAddress: String
    public var imapHost: String?
    public var imapPort: Int?
    public var keychainRef: String?
    public var status: AccountStatus
    public var lastSyncAt: Date?
    public var createdAt: Date
    public var messagesIngested: Int
    public var smtpHost: String?
    public var smtpPort: Int?
    public var smtpSecurity: SMTPSecurity?
    public var smtpUsername: String?
    public var smtpAuthMethod: SMTPAuthMethod?
    public var smtpKeychainRef: String?
    public var needsReauth: Bool = false
    public var pinnedCertSHA256: String? = nil

    /// Index into `AccountColorPalette.all`. nil for accounts created before
    /// per-account coloring landed; the migration applier and the snapshot
    /// loader both treat nil as "Cygnus Cyan" (palette index 0). Constellation
    /// nodes use this account's hue + saturation, modulating brightness by
    /// message age. Optional so SwiftData lightweight migration succeeds for
    /// existing rows.
    public var colorIndex: Int? = nil

    // IMAP additions (2026-04-19)
    public var imapSecurity: IMAPSecurity? = nil
    public var imapAuthMethod: IMAPAuthMethod? = nil
    public var imapUsername: String? = nil
    public var imapKeychainRef: String? = nil
    public var needsImapReauth: Bool = false
    public var foldersLastListedAt: Date? = nil

    /// Set once all required corpus folders have completed their initial IMAP
    /// acquisition. Nil keeps migrated accounts in the initial-import phase.
    /// Optional for SwiftData lightweight migration safety.
    public var initialIMAPImportCompletedAt: Date? = nil

    // First-ingestion history window. nil means "All time" for lightweight
    // migration and for accounts created before this preference existed.
    public var ingestionLowerBoundAt: Date? = nil
    public var ingestionWindowPresetRaw: String? = nil

    // JSON `[String]` of canonical language ids ("en", "ja", …) the user
    // writes in from this account, first entry primary. Seeded at onboarding
    // and editable per account in Settings → Languages; drives the Composer's
    // draft-language menu. nil/empty falls back to the app-global content
    // languages at the read seam. Optional for lightweight migration.
    public var draftLanguagesJSON: String? = nil

    // Per-account server-side cleanup policy for the withheld folders
    // (Junk/Trash). nil maps to `.off` so existing accounts remain
    // non-destructive after lightweight migration.
    public var withheldAutoDeleteScheduleRaw: String? = nil
    public var withheldAutoDeleteLastRunAt: Date? = nil
    public var withheldAutoDeleteLastDeletedCount: Int? = nil
    public var withheldAutoDeleteLastError: String? = nil

    // IMAPFolderState inverse wired in Task 1.3 — forward-declared here so the
    // @Model schema can resolve all relationships in one step.
    @Relationship(deleteRule: .cascade, inverse: \IMAPFolderState.account)
    public var imapFolderStates: [IMAPFolderState] = []

    @Relationship(deleteRule: .cascade, inverse: \Identity.account)
    public var identities: [Identity] = []

    @Relationship(deleteRule: .cascade, inverse: \SignatureSlot.account)
    public var signatureSlots: [SignatureSlot] = []

    /// The slot stamped onto new drafts from this account. Nil means new
    /// drafts start unsigned. Optional for lightweight migration.
    public var defaultSignatureSlotID: UUID? = nil

    /// Returns the single primary identity, or nil if there is no
    /// identities list yet (pre-migration state).
    public var primaryIdentity: Identity? {
        identities.first(where: \.isPrimary)
    }

    /// Flip exactly one identity to primary. Sets all others to false,
    /// the target to true. Caller must `context.save()` afterwards.
    public func setPrimaryIdentity(_ target: Identity) {
        for ident in identities {
            ident.isPrimary = (ident.id == target.id)
        }
    }

    /// Resolve the identity for an outgoing draft.
    /// Priority: (1) the identity whose id matches `draftIdentityID`, (2) the
    /// account's primary identity. Returns nil only if the account has no
    /// identities at all (pre-migration defensive case).
    public func resolveIdentity(for draftIdentityID: UUID?) -> Identity? {
        if let id = draftIdentityID,
           let match = identities.first(where: { $0.id == id }) {
            return match
        }
        return primaryIdentity
    }

    public init(
        displayName: String,
        emailAddress: String
    ) {
        self.id = UUID()
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.status = .idle
        self.createdAt = Date()
        self.messagesIngested = 0
    }
}

public extension Account {
    func acceptsIMAPLiveMessage(receivedAt: Date?) -> Bool {
        HistoryIngestionWindowPolicy.accepts(
            date: receivedAt,
            lowerBound: ingestionLowerBoundAt
        )
    }

    /// A provider message is user-visible as new mail only when it is dated at
    /// or after the account was added to Ohia. Historical acquisition remains
    /// silent even though it uses the same raw RFC 5322 ingestion path.
    func allowsIMAPLiveInboundNotification(dated messageDate: Date?) -> Bool {
        guard let messageDate else { return false }
        return messageDate >= createdAt
    }

    var withheldAutoDeleteSchedule: WithheldAutoDeleteSchedule {
        get {
            guard let raw = withheldAutoDeleteScheduleRaw,
                  let schedule = WithheldAutoDeleteSchedule(rawValue: raw) else {
                return .defaultSchedule
            }
            return schedule
        }
        set {
            withheldAutoDeleteScheduleRaw = newValue == .off ? nil : newValue.rawValue
            if newValue == .off {
                withheldAutoDeleteLastError = nil
            }
        }
    }

    func isWithheldAutoDeleteDue(now: Date = Date()) -> Bool {
        guard imapHost != nil,
              imapKeychainRef != nil,
              !needsImapReauth,
              status != .paused else {
            return false
        }
        return withheldAutoDeleteSchedule.isDue(
            lastRunAt: withheldAutoDeleteLastRunAt,
            now: now
        )
    }

    /// Canonical language ids the user writes in from this account, first
    /// entry primary. Empty when the user has not chosen account languages
    /// yet — callers fall back to the app-global content-language list.
    var draftLanguages: [String] {
        get {
            guard let json = draftLanguagesJSON,
                  let data = json.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return values
        }
        set {
            if newValue.isEmpty {
                draftLanguagesJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                draftLanguagesJSON = String(decoding: data, as: UTF8.self)
            }
        }
    }

    var ownedEmailAddresses: Set<String> {
        var addresses = Set<String>()
        func insert(_ address: String) {
            let normalized = address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalized.isEmpty {
                addresses.insert(normalized)
            }
        }

        insert(emailAddress)
        for identity in identities {
            insert(identity.address)
        }
        return addresses
    }

    func ownsEmailAddress(_ address: String) -> Bool {
        let normalized = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return ownedEmailAddresses.contains(normalized)
    }

    /// Saved signature slots in stable display order.
    var orderedSignatureSlots: [SignatureSlot] {
        signatureSlots.sorted {
            ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt)
        }
    }

    /// The slot new drafts from this account start with, or nil when the
    /// default pointer is unset or stale (slot deleted).
    var defaultSignatureSlot: SignatureSlot? {
        guard let id = defaultSignatureSlotID else { return nil }
        return signatureSlots.first(where: { $0.id == id })
    }
}
