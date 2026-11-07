import Foundation
import SwiftData

/// What caused a `DraftRevision` to be written. Raw strings (not a Codable
/// enum) so SwiftData lightweight migration and `#Predicate` translation
/// never see a custom enum type — the same pattern as `AccountMemoryDimension`.
public enum DraftRevisionTrigger {
    /// First generation after the user answered (or skipped) the clarifying
    /// questions — the draft's version 1.
    public static let initial = "initial"
    /// Generated from an instruction the user typed into the Composer's
    /// instruction box, applied against the then-current version.
    public static let instruction = "instruction"
    /// Full regeneration requested by the user (fresh pass over the same
    /// context and answers, discarding the current text as the base).
    public static let regenerate = "regenerate"
    /// Snapshot of the user's manual edits, captured when the edited text
    /// becomes the base for a model pass or the final sent version.
    public static let manualEdit = "manualEdit"
    /// Rewritten in a different style register chosen from the Composer's
    /// Style panel (optionally with an accompanying instruction).
    public static let restyle = "restyle"
}

/// One version of a reply draft's body. Every generation pass — initial,
/// instruction revision, regeneration — appends a revision; the Composer's
/// version switcher flips the live `Draft.replyText` / `Draft.bodyHTML`
/// between them. Revisions are immutable once written.
@Model
public final class DraftRevision {
    public var id: UUID

    /// Owning draft. Inverse of `Draft.revisions`; cascade-deleted with it.
    public var draft: Draft?

    /// 1-based position in the draft's history. The Composer displays this
    /// as the version number ("v3").
    public var index: Int

    /// Plain-text body of this version (no signature manipulation — the
    /// text exactly as it stood when the revision was captured).
    public var bodyText: String

    /// Rich-text body as HTML when the version carries user formatting.
    public var bodyHTML: String?

    /// `DraftRevisionTrigger` raw string.
    public var triggerRaw: String

    /// The user instruction that shaped this version, when present. For
    /// `.initial`, this is the first-draft guidance; for
    /// `.instruction`, this is the revision request.
    public var instruction: String?

    /// The `StyleRegister` this version was written in, when the pass that
    /// produced it was register-steered (`initial` with a resolved register,
    /// or `restyle`). Optional for lightweight migration.
    public var styleRegisterID: UUID?

    /// Immutable defaults, effective axes, and user intent for this version.
    public var styleControlSnapshotJSON: String?

    /// Exact source list that shaped this version's generated body. This is
    /// version-scoped because the Composer can regenerate whichever saved
    /// version is currently displayed. Optional for lightweight migration.
    public var generatedSourcesJSON: String?

    /// Hidden reasoning emitted while producing this version. It is never
    /// shown or sent; only Qwen3.8 may replay it for an eligible next turn.
    public var reasoningContent: String?

    /// Exact model and personalization state that produced the reasoning.
    public var reasoningContinuationFingerprint: String?

    /// Exact grounded user turn that produced this version. It is retained
    /// only with hidden reasoning so a preserved-thinking continuation can
    /// replay the real conversation rather than a synthetic summary.
    public var reasoningPrompt: String?

    /// SHA-256 of `reasoningPrompt`, checked before replay.
    public var reasoningContextFingerprint: String?

    /// The exact request, brief and writer task that produced `bodyText`
    /// (`ComposerGenerationBasis` JSON, owned by OhiaML). Nil on manual-edit
    /// revisions and on revisions generated before the basis existed.
    public var generationBasisJSON: String?

    /// Ancestry. For a `manualEdit` revision: the actual revision whose
    /// body the author edited (which may itself be manual). For a generated revision: the revision that
    /// was displayed when the pass was requested (its input), nil for a
    /// first generation. Nil on rows written before ancestry was recorded.
    /// Optional for lightweight migration.
    public var baseRevisionID: UUID?

    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        draft: Draft? = nil,
        index: Int,
        bodyText: String,
        bodyHTML: String? = nil,
        triggerRaw: String,
        instruction: String? = nil,
        styleRegisterID: UUID? = nil,
        styleControlSnapshot: StyleControlSnapshot? = nil,
        generatedSourcesJSON: String? = nil,
        reasoningContent: String? = nil,
        reasoningContinuationFingerprint: String? = nil,
        reasoningPrompt: String? = nil,
        reasoningContextFingerprint: String? = nil,
        generationBasisJSON: String? = nil,
        baseRevisionID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.draft = draft
        self.index = index
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.triggerRaw = triggerRaw
        self.instruction = instruction
        self.styleRegisterID = styleRegisterID
        self.styleControlSnapshotJSON = styleControlSnapshot?.jsonString
        self.generatedSourcesJSON = generatedSourcesJSON
        self.reasoningContent = reasoningContent
        self.reasoningContinuationFingerprint = reasoningContinuationFingerprint
        self.reasoningPrompt = reasoningPrompt
        self.reasoningContextFingerprint = reasoningContextFingerprint
        self.generationBasisJSON = generationBasisJSON
        self.baseRevisionID = baseRevisionID
        self.createdAt = createdAt
    }

    public var styleControlSnapshot: StyleControlSnapshot? {
        get { StyleControlSnapshot.decodeJSON(styleControlSnapshotJSON) }
        set { styleControlSnapshotJSON = newValue?.jsonString }
    }
}
