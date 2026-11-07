import CoreGraphics
import Foundation
import simd

struct AnnotationItem: Identifiable, Sendable, Equatable {
    struct Extra: Sendable, Equatable, Identifiable {
        var id: String { key }
        let key: String
        let value: String
    }

    /// Sidecar metadata carried on attachment-kind annotations. The locked
    /// overlay uses this to drive lazy summary generation — it knows which
    /// attachment id to key the cache on, what extracted text to send the
    /// model, and whether the attachment is even text-bearing yet.
    struct AttachmentReference: Sendable, Equatable {
        enum ExtractionState: Sendable, Equatable {
            case ready          // extraction complete; concatenatedText is non-empty
            case extracting     // queued or running on a local extraction dependency
            case waitingForAppleIntelligence
            case unsupported    // worker classified attachment as non-text-bearing
            case unavailable    // extraction reached a terminal non-summary state
        }

        let attachmentID: UUID
        let filename: String
        let mimeType: String
        let sizeBytes: Int
        let extractionState: ExtractionState
        /// Document-summary inputs mirrored from the source `Attachment`, so the
        /// lazy chevron-expand path feeds the model the same type-specific
        /// framing (kind, structure, length, embedded title/author) the
        /// background backfill worker does — keeping the two paths' summary
        /// fingerprints identical. `nil` before extraction populates them.
        let documentKind: String?
        let structureUnitKind: String?
        let structureUnitCount: Int?
        let characterCount: Int?
        let documentTitle: String?
        let documentAuthor: String?
        /// Body of every embedded chunk for this attachment, concatenated in
        /// chunkIndex order with the embedding scaffolding stripped. Empty
        /// when extraction is still pending or when the attachment was
        /// classified as non-text-bearing.
        let concatenatedText: String
        /// On-disk path to the attachment binary. Drives two surfaces in
        /// the popup: an inline preview for image attachments (PNG/JPEG/
        /// HEIC/…) and the bottom-of-pane FILES link any attachment kind
        /// can use to open the file in its default app. `nil` when the
        /// attachment binary wasn't preserved (legacy ingestion).
        let filePath: String?

        /// Single source of truth for "is this attachment image-like."
        /// Both the brief-text builder (image attachments use the visual
        /// summary as the brief) and the popup's expanded preview gate
        /// (image attachments swap the lazy summary for an inline image
        /// preview) read this property, so the rule can't drift between
        /// call sites. Mirrors the worker's mime/extension policy.
        var isImage: Bool {
            let mime = mimeType.lowercased()
            if mime.hasPrefix("image/") { return true }
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
                .contains(ext)
        }
    }

    let id: String
    let kind: AnnotationKind
    let anchorVectorId: Int64?
    let anchorMessageId: String?
    let anchorWorld: SIMD3<Float>
    let title: String
    /// Short fragment rendered inline with the context label on the popup
    /// header's first row (e.g. thread position "+1"). Kept separate from
    /// `detail` so the longer date/direction string can drop to its own
    /// line below without taking the position with it. Empty when the
    /// kind doesn't have a stable primary fragment to surface.
    let headerPrimaryDetail: String
    let detail: String
    let briefText: String
    let extras: [Extra]
    let relevance: String?
    let badgeText: String
    let importance: Double
    let contextReason: String
    /// Multi-sentence body summary surfaced in the expanded popup pane (chevron
    /// open). `nil` when the source has no summary yet — the popup falls back
    /// to the existing extras + relevance content in that case.
    let summary: String?
    /// SF Symbol rendered before the context label in the popup header to
    /// surface message direction at a glance — `paperplane.fill` for emails
    /// the user sent, `tray.and.arrow.down` for emails they received. `nil`
    /// for kinds where direction isn't meaningful (chunk, attachment, entity).
    let directionSymbol: String?
    /// Raw 0...1 affinity used by the screen-space label solver. Higher
    /// affinity should orbit closer to the locked email; `nil` means the
    /// annotation is not expressing semantic relatedness radially.
    let radialAffinity: Double?
    /// Timeline date used by frame-specific badge policies. The People
    /// layer uses this to put the earliest message in each role group at
    /// the front of both the tab order and the visible badge labels.
    let badgeSortDate: Date?
    /// Populated only on attachment-kind items; carries everything the
    /// overlay needs to fire a lazy summary request when the chevron
    /// expands. `nil` for every other kind.
    let attachmentReference: AttachmentReference?

    /// Default collapsed-popup size used when an instance can't be consulted
    /// (layout coordinator falls back to this when working from sizes alone).
    /// Match `popupSize` for an item whose `contextReason` is non-empty so
    /// the worst-case height keeps the same fallback.
    static let popupSize = CGSize(width: 252, height: 156)

    /// Collapsed-popup size for THIS item. Shrinks the height when the
    /// instance won't render a `contextReason` row (currently true for the
    /// neighbour kind), so a related-email popup that just shows
    /// `from/to · date · category` doesn't carry an empty ~28pt slot at
    /// the bottom that the fixed-height fallback would otherwise reserve.
    /// Adds a footer slot for attachments that carry an openable file
    /// path so the bottom-of-pane link has room to render even while the
    /// popup is collapsed. Grows vertically for long `briefText` so the
    /// rendered paragraph fits without truncation — the no-ellipsis rule
    /// means the frame must follow the content, not the other way round.
    var popupSize: CGSize {
        let baseHeight: CGFloat = contextReason.isEmpty ? 128 : 156
        return CGSize(
            width: AnnotationItem.popupSize.width,
            height: baseHeight + fileLinkFooterHeight + headerSecondRowHeight + briefTextExtraHeight
        )
    }

    var expandedSize: CGSize {
        // Attachments always reserve the summary-friendly size — the lazy
        // summary lands behind the chevron, and the popup needs room for
        // it once the request resolves. Reverting to the smaller size
        // would force a layout jump mid-flight as the placeholder swaps
        // for resolved text.
        if summary?.isEmpty == false || kind == .attachment {
            return CGSize(width: 300, height: 310 + fileLinkFooterHeight + headerSecondRowHeight + briefTextExtraHeight)
        }
        return CGSize(width: 276, height: 226 + fileLinkFooterHeight + headerSecondRowHeight + briefTextExtraHeight)
    }

    /// Vertical room above the existing ~3-line briefText budget required to
    /// render a longer paragraph without overflowing the popup frame.
    /// Empirical: italic 11.5 at ~228pt width seats ~38 chars per line with
    /// the 1.5 lineSpacing in `AnnotationPopup.brief`. The base height
    /// already reserves room for the first three lines; this property only
    /// adds the surplus.
    private var briefTextExtraHeight: CGFloat {
        guard !briefText.isEmpty else { return 0 }
        let charsPerLine: CGFloat = 38
        let lineHeight: CGFloat = 16
        let baseLineBudget: CGFloat = 3
        let estimatedLines = (CGFloat(briefText.count) / charsPerLine).rounded(.up)
        let surplus = max(0, estimatedLines - baseLineBudget)
        return surplus * lineHeight
    }

    /// Extra height reserved at the bottom of the popup for the FILES
    /// link row. Zero for kinds that don't carry an openable file path.
    private var fileLinkFooterHeight: CGFloat {
        guard kind == .attachment,
              let path = attachmentReference?.filePath,
              !path.isEmpty else {
            return 0
        }
        return 36
    }

    /// Extra height reserved for the header's second-row detail line.
    /// Thread/reply popups split their header into two rows — primary
    /// fragment ("+1") next to the context label, full `detail` (date ·
    /// direction) on its own line beneath — so the popup needs more
    /// vertical space than the original single-row header consumed.
    /// Attachment popups reserve more because their second-row detail
    /// (full MIME + size + section count) wraps to 2–3 lines for Office
    /// MIME types. Zero for kinds whose detail still rides inline with
    /// the label.
    private var headerSecondRowHeight: CGFloat {
        guard !headerPrimaryDetail.isEmpty, !detail.isEmpty else { return 0 }
        return kind == .attachment ? 54 : 18
    }

    init(
        id: String,
        kind: AnnotationKind,
        anchorVectorId: Int64?,
        anchorMessageId: String?,
        anchorWorld: SIMD3<Float>,
        title: String,
        headerPrimaryDetail: String = "",
        detail: String,
        briefText: String,
        extras: [Extra],
        relevance: String?,
        badgeText: String,
        importance: Double = 0,
        contextReason: String = "",
        summary: String? = nil,
        directionSymbol: String? = nil,
        radialAffinity: Double? = nil,
        badgeSortDate: Date? = nil,
        attachmentReference: AttachmentReference? = nil
    ) {
        self.id = id
        self.kind = kind
        self.anchorVectorId = anchorVectorId
        self.anchorMessageId = anchorMessageId
        self.anchorWorld = anchorWorld
        self.title = title
        self.headerPrimaryDetail = headerPrimaryDetail
        self.detail = detail
        self.briefText = briefText
        self.extras = extras
        self.relevance = relevance
        self.badgeText = badgeText
        self.importance = importance
        self.contextReason = contextReason
        self.summary = summary
        self.directionSymbol = directionSymbol
        self.radialAffinity = radialAffinity
        self.badgeSortDate = badgeSortDate
        self.attachmentReference = attachmentReference
    }
}

struct ScreenAnnotationItem: Identifiable, Equatable {
    var id: String { item.id }
    let item: AnnotationItem
    let anchor: CGPoint
}
