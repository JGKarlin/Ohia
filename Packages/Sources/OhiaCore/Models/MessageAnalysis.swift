import Foundation
import SwiftData

@Model
public final class MessageAnalysis {
    public var id: UUID
    public var message: Message?
    public var analysisVersion: String
    public var extractedAt: Date
    public var dimensionsJSON: String
    public var evidenceJSON: String?
    /// LLM-generated proportional summary of the email body.
    /// Nil until hover-on-demand or automatic new-mail summarization produces one.
    public var bodySummary: String?
    /// Versioned identity of the target language and selected translation context
    /// used to generate `bodySummary`. Nil means the stored summary predates the
    /// identity contract and must not be reused by a prepared request.
    public var bodySummaryInputFingerprint: String?
    /// Unused optional schema storage retained solely so inferred-schema
    /// migration can reopen stores created before structured classification.
    /// New ingestion must leave this nil; it is not a compatibility read or
    /// write path.
    public var bodySummaryCategory: String?
    /// Canonical `MailClassification` JSON. Nil means classification remains
    /// pending; valid classified, uncertain, and deterministic-fallback
    /// documents are complete.
    public var mailClassificationJSON: String?
    /// Canonical JSON array of independent user-authored `custom.*` category
    /// keys. Model-derived classification invalidation must preserve it.
    public var customCategoryKeysJSON: String?
    /// Structured `TriageVerdict` JSON produced by the LLM-driven
    /// interpretation stage. Carries the two-axis attention
    /// classification (`isActionable` / `requiresConfirmation`) plus
    /// optional structured action and acknowledgement payloads. Optional
    /// for lightweight migration of existing stores; nil when the message
    /// has not yet been interpreted.
    public var triageVerdictJSON: String?
    /// Structured `DiscourseMemory` JSON produced by the Conversation
    /// Memory lens extractor. Carries discourse moves, IBIS roles, claim /
    /// decision / precedent / tacit-rule candidates, contradiction /
    /// supersession signals, scope hints, evidence spans, and uncertainty.
    /// Optional for lightweight migration of existing stores; nil when the
    /// message has not yet been through the discourse extraction pass.
    /// Persisted by the on-demand `DiscourseExtractor`; seeded synchronously
    /// by `SeedFromMetadata` before the LLM pass runs so the workspace can
    /// render baseline memory immediately on cold cache.
    public var discourseMemoryJSON: String?
    /// Time when the structured mail interpretation was
    /// persisted. This is separate from `summarizedAt`; summaries are now
    /// generated on demand for UI detail surfaces.
    public var interpretedAt: Date?
    public var summarizedAt: Date?

    public init(message: Message, analysisVersion: String, dimensionsJSON: String) {
        self.id = UUID()
        self.message = message
        self.analysisVersion = analysisVersion
        self.extractedAt = Date()
        self.dimensionsJSON = dimensionsJSON
    }
}
