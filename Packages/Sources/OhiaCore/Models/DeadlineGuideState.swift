import Foundation
import SwiftData

/// Per-deadline workspace state: agenda disposition, guide step completion,
/// and the guide's last re-distillation stamp. Keyed by the tracker's stable
/// deadline id (thread- or message-scoped) — the same key `DeadlineReminder`
/// uses — so the state survives re-ingestion and snapshot rebuilds.
@Model
public final class DeadlineGuideState {
    /// The `DeadlineEntry.id` this state belongs to (stable across rebuilds).
    @Attribute(.unique) public var entryID: String
    /// JSON-encoded `[String]` of completed step ids. Step ids are the
    /// content-derived `DeadlineActionItem.id` values ("document:form.pdf",
    /// "link:host/path"), so ticks survive guide re-distillation; ids that no
    /// longer match a regenerated step are simply inert.
    public var completedStepIDsJSON: String?
    /// When the guide was last re-distilled because the deadline's file set
    /// changed (a working file added or removed). `nil` until the first change.
    public var guideLastReadAt: Date?
    /// Short human-readable cause for the pane's footer note, e.g.
    /// "recommendation_draft_v2.docx was added".
    public var guideLastReadReason: String?
    /// Keeps this deadline promoted within its agenda section. Optional so
    /// deadline-state rows created before this field existed migrate safely;
    /// the agenda store collapses `nil` to false at its read seam.
    public var isPinned: Bool?
    /// Moves this deadline into the Hidden section. Optional for the same
    /// lightweight-migration reason as `isPinned`; `nil` means visible.
    public var isHidden: Bool?
    public var updatedAt: Date

    public init(
        entryID: String,
        completedStepIDsJSON: String? = nil,
        guideLastReadAt: Date? = nil,
        guideLastReadReason: String? = nil,
        isPinned: Bool = false,
        isHidden: Bool = false,
        updatedAt: Date = .now
    ) {
        self.entryID = entryID
        self.completedStepIDsJSON = completedStepIDsJSON
        self.guideLastReadAt = guideLastReadAt
        self.guideLastReadReason = guideLastReadReason
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.updatedAt = updatedAt
    }
}

public extension DeadlineGuideState {
    /// Decoded completed step ids. Tolerates a corrupt payload by reading empty.
    var completedStepIDs: Set<String> {
        get {
            guard let json = completedStepIDsJSON,
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(ids)
        }
        set {
            let ids = newValue.sorted()
            if ids.isEmpty {
                completedStepIDsJSON = nil
            } else if let data = try? JSONEncoder().encode(ids) {
                completedStepIDsJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}
