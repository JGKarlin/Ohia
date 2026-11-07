import Foundation
import SwiftData

/// User verdict on a Conversation Memory object — claim, issue, decision,
/// precedent, or tacit rule. Persists across sessions even when extraction
/// recomputes the underlying object, so a confirm/reject decision survives
/// prompt-version bumps and slightly different supporting evidence.
///
/// Identity uses a composite `targetKey` (see `ConversationCurationKey`) that
/// hashes normalized text + kind + scope + extraction version + supporting-
/// message fingerprint. The non-hashed component fields are stored alongside
/// so a future key-policy revision can re-derive the digest without losing
/// curation history.
///
/// Modeled on `ProjectLensAction`. Read/write through
/// `ConversationCurationActionWriter`; in-memory snapshots fold the rows via
/// `ConversationCurationApplier`.
@Model
public final class ConversationCurationAction {
    public var id: UUID
    /// Stable digest of the composite key components below. Hex string.
    public var targetKey: String
    /// One of: `claim`, `issue`, `decision`, `precedent`, `tacitRule`.
    public var targetKindRaw: String
    /// Lowercased, whitespace-collapsed, punctuation-stripped claim text.
    /// Stored verbatim so the curation-key fallback ladder can re-match
    /// under a different supporting-message fingerprint.
    public var normalizedClaimText: String
    /// Stable hash of project / team / classification / time-bucket scope.
    public var scopeFingerprint: String
    /// Matches `DiscourseMemory.extractionVersion` at write time.
    public var extractionVersion: String
    /// Sorted SHA-256 of top-K supporting `Message.contentHash`. Empty
    /// string when no supporting messages were available at write time
    /// (e.g. seeded-only memory before LLM extraction).
    public var supportingFingerprint: String
    /// One of: `confirm`, `reject`, `weaken`, `merge`, `split`, `pin`,
    /// `markStale`, `markObsolete`.
    public var actionRawValue: String
    /// When this row represents a merge, the surviving claim's `targetKey`.
    public var mergedIntoKey: String?
    /// When this row represents a split, the CSV of new child target keys.
    public var splitChildrenKeysCSV: String?
    /// Optional user-authored note attached to the verdict.
    public var noteText: String?
    public var appliedAt: Date
    public var revokedAt: Date?

    public init(
        id: UUID = UUID(),
        targetKey: String,
        targetKindRaw: String,
        normalizedClaimText: String,
        scopeFingerprint: String,
        extractionVersion: String,
        supportingFingerprint: String,
        actionRawValue: String,
        mergedIntoKey: String? = nil,
        splitChildrenKeysCSV: String? = nil,
        noteText: String? = nil,
        appliedAt: Date = .now,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.targetKey = targetKey
        self.targetKindRaw = targetKindRaw
        self.normalizedClaimText = normalizedClaimText
        self.scopeFingerprint = scopeFingerprint
        self.extractionVersion = extractionVersion
        self.supportingFingerprint = supportingFingerprint
        self.actionRawValue = actionRawValue
        self.mergedIntoKey = mergedIntoKey
        self.splitChildrenKeysCSV = splitChildrenKeysCSV
        self.noteText = noteText
        self.appliedAt = appliedAt
        self.revokedAt = revokedAt
    }
}

public extension ConversationCurationAction {
    enum TargetKind: String, Sendable, Codable, CaseIterable {
        case claim
        case issue
        case decision
        case precedent
        case tacitRule
    }

    enum ActionValue: String, Sendable, Codable, CaseIterable {
        case confirm
        case reject
        case weaken
        case merge
        case split
        case pin
        case markStale
        case markObsolete
    }

    var targetKind: TargetKind? {
        TargetKind(rawValue: targetKindRaw)
    }

    var actionValue: ActionValue? {
        ActionValue(rawValue: actionRawValue)
    }

    var isActive: Bool {
        revokedAt == nil
    }
}
