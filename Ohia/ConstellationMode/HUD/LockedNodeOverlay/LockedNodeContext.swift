import Foundation
import simd
import OhiaCore
import OhiaIngest
import OhiaML

struct LockedAttachmentSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    /// On-disk location of the attachment payload. `nil` when the attachment
    /// metadata is present but the binary was not preserved (legacy ingestion).
    let filePath: String?
    /// On-disk location of the extracted text. `nil` while extraction is still
    /// pending (text-bearing attachments waiting on the `extractAttachments`
    /// worker) or when the attachment was non-text-bearing in the first place.
    let extractedTextPath: String?
    /// `Attachment.extractionMethod` — set to a method name on success or to
    /// `AttachmentExtractionWorker.unsupportedMarker` ("unsupported") for
    /// legacy terminal rows.
    let extractionMethod: String?
    /// Structured document extraction status and failure reason, when the
    /// document worker has visited this row.
    let extractionStatus: String?
    let extractionFailureReason: String?
    /// Structured image/OCR extraction status and failure reason, when the
    /// visual worker has visited this row.
    let visualExtractionStatus: String?
    let visualExtractionMethod: String?
    let visualExtractionFailureReason: String?
    /// Vision-derived paragraph describing an image attachment, produced by
    /// `VisualAttachmentExtractionWorker` from `VNClassifyImageRequest` +
    /// `VNRecognizeTextRequest` + Apple Foundation Models. `nil` when the
    /// attachment isn't image-like, or when the visual extraction worker
    /// hasn't visited it yet. Used by the locked-overlay attachment pane to
    /// show "what's in this image" in the collapsed brief.
    let visualSummary: String?
    let visualEvidenceKind: String?
    let visualOCRLineCount: Int?
    let visualOCRCharacterCount: Int?
    let visualClassificationCount: Int?
    let visualObjectCount: Int?
    /// Original (pre-downscale) pixel dimensions of an image attachment as
    /// recorded by `VisualAttachmentExtractionWorker`. `nil` for non-images
    /// or rows the visual worker hasn't visited. Surfaced in the FILES row as
    /// the "W×H" card-catalog fact.
    let visualImagePixelWidth: Int?
    let visualImagePixelHeight: Int?
    /// `Attachment.detectedDocumentKind` — the `DocumentKind` raw value the
    /// extractor assigned (`docx`, `pdf`, `pptx`, …). Carried so the lazy
    /// attachment-summary path can give the model the same type-specific
    /// framing the background backfill worker does. `nil` before extraction.
    let detectedDocumentKind: String?
    /// `Attachment.extractionStructureUnitKind` — `page` / `slide` / `sheet` /
    /// `section`. Paired with `extractionStructureUnitCount`.
    let extractionStructureUnitKind: String?
    /// Structural unit count from document extraction — PDF pages, deck
    /// slides, spreadsheet sheets, or Word sections depending on type. The
    /// FILES row interprets the unit noun from the attachment kind.
    let extractionStructureUnitCount: Int?
    /// Document-embedded title/author (OOXML core properties). Carried into the
    /// lazy summary path as a cross-check hint. `nil` when absent.
    let documentTitle: String?
    let documentAuthor: String?
    /// Extracted plain-text character count, used to estimate a word count
    /// for the FILES-row card-catalog fact on text-bearing documents.
    let extractionCharacterCount: Int?
    /// Three-sentence generated paragraph for the expanded attachment pane.
    /// Filled by the background attachment-summary backfill worker or by the
    /// on-demand chevron path, then persisted on `Attachment`.
    let attachmentSummary: String?
    /// Normalized RFC 2045 Content-ID (angle brackets stripped). `nil` for
    /// MIME parts without the header and for rows ingested before the field
    /// was tracked. Used by the annotation factory's inline-image filter.
    let contentId: String?
    /// `true` when this attachment is an inline image already embedded in
    /// the message's HTML body via a `cid:` reference — the locked-node
    /// overlay drops these from the FILES list so the same image isn't
    /// shown twice. `nil` for rows that pre-date the distinction; those
    /// backfill on the next ingestion touch.
    let isInline: Bool?
    /// iCloud Mail Drop download link for a file the sender uploaded instead
    /// of attaching; `filePath` is `nil` for these rows.
    var remoteURL: String? = nil
    var remoteExpiresAt: Date? = nil
    /// Capture fact for photos and videos: `Oct 6, 2026, 6:50 AM · Serengeti
    /// National Park, Tanzania` (wall-clock time where it was recorded).
    var captureLine: String? = nil
}

extension LockedAttachmentSummary {
    /// Builds a value snapshot from a SwiftData `Attachment`. This synchronous
    /// initializer does not hop executors: callers must fetch and consume the
    /// model in the same context isolation domain. Shared by
    /// `LockedNodeContextLoader` and `FrontPageDataController` so their mappings
    /// cannot drift. Carries `isInline` through unchanged — callers decide
    /// whether to keep inline cid: images.
    nonisolated
    init(attachment: Attachment) {
        self.init(
            id: attachment.id,
            filename: MIMEHeaderDecoder.decodeEncodedWords(attachment.filename),
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            filePath: attachment.filePath,
            extractedTextPath: attachment.extractedTextPath,
            extractionMethod: attachment.extractionMethod,
            extractionStatus: attachment.extractionStatus,
            extractionFailureReason: attachment.extractionFailureReason,
            visualExtractionStatus: attachment.visualExtractionStatus,
            visualExtractionMethod: attachment.visualExtractionMethod,
            visualExtractionFailureReason: attachment.visualExtractionFailureReason,
            visualSummary: attachment.visualSummary,
            visualEvidenceKind: attachment.visualEvidenceKind,
            visualOCRLineCount: attachment.visualOCRLineCount,
            visualOCRCharacterCount: attachment.visualOCRCharacterCount,
            visualClassificationCount: attachment.visualClassificationCount,
            visualObjectCount: attachment.visualObjectCount,
            visualImagePixelWidth: attachment.visualOriginalImageWidth ?? attachment.visualImageWidth,
            visualImagePixelHeight: attachment.visualOriginalImageHeight ?? attachment.visualImageHeight,
            detectedDocumentKind: attachment.detectedDocumentKind,
            extractionStructureUnitKind: attachment.extractionStructureUnitKind,
            extractionStructureUnitCount: attachment.extractionStructureUnitCount,
            documentTitle: attachment.documentTitle,
            documentAuthor: attachment.documentAuthor,
            extractionCharacterCount: attachment.extractionCharacterCount,
            attachmentSummary: attachment.attachmentSummary,
            contentId: attachment.contentId,
            isInline: attachment.isInline,
            remoteURL: attachment.remoteURL,
            remoteExpiresAt: attachment.remoteExpiresAt,
            captureLine: AttachmentCaptureMetadata
                .decode(attachment.captureMetadataJSON)?
                .readerLine(locale: .autoupdatingCurrent)
        )
    }
}

extension LockedAttachmentSummary {
    /// The Mail Drop link, while iCloud still serves it.
    nonisolated func liveRemoteURL(now: Date = Date()) -> URL? {
        guard let remoteURL, let url = URL(string: remoteURL),
              MailDropReference.isTrustedDownloadURL(url) else { return nil }
        if let remoteExpiresAt, remoteExpiresAt <= now { return nil }
        return url
    }
}

struct LockedCorrespondentSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let displayName: String
    let email: String
    let organization: String?
    let familiarityScore: Double
}

struct LockedPersonFocus: Sendable, Equatable {
    let email: String
    let displayName: String
    let worldPosition: SIMD3<Float>
    let messageIds: Set<String>
    /// Unit-length normal of the hub's ring plane in world space. Used by
    /// the People-lens dial wedge to sample the outermost ring's screen
    /// projection so the inner-arc leader traces the actual elliptical
    /// outline of the ring at the current camera pose, not a flat circle.
    let ringNormal: SIMD3<Float>
    /// World-space radius of the **outer edge** of the outermost ring
    /// band — the outermost ring's mid-line radius plus its half-width
    /// thickness. Combined with `ringNormal` and `worldPosition`, this
    /// fully describes the visible outer fringe of the Saturn rings as
    /// a 3D circle the dial wedge can sample and project to screen each
    /// frame so the inner-arc leader hugs the ring's actual outer edge
    /// rather than its center line.
    let outerRingEdgeRadius: Float

    init(
        email: String,
        displayName: String,
        worldPosition: SIMD3<Float>,
        messageIds: Set<String>,
        ringNormal: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        outerRingEdgeRadius: Float = 0
    ) {
        self.email = email
        self.displayName = displayName
        self.worldPosition = worldPosition
        self.messageIds = messageIds
        self.ringNormal = ringNormal
        self.outerRingEdgeRadius = outerRingEdgeRadius
    }
}

@MainActor
struct LockedNodeContext {
    struct Center {
        let messageId: String
        let vectorId: Int64
        let row: MessageFilterRow
        let worldPosition: SIMD3<Float>
        let bodyContent: LockReadoutBodyContent?
    }

    struct OwnChunk: Identifiable {
        var id: Int64 { vectorId }

        let vectorId: Int64
        let collection: VectorCollection
        let chunkIndex: Int
        let textPayload: String
        let metadataJSON: String
        let entityKind: EntityKind?
        let entityKey: String?
        let entityScore: Float?
        let worldPosition: SIMD3<Float>
        let attachment: LockedAttachmentSummary?
        let correspondent: LockedCorrespondentSummary?
    }

    struct ThreadSibling: Identifiable {
        var id: String { messageId }

        let messageId: String
        let row: MessageFilterRow
        let position: Int
        let receivedAt: Date?
        let isSentByUser: Bool
    }

    struct Neighbour: Identifiable {
        var id: String { messageId }

        /// How the neighbour relates to the locked email. Drives which
        /// annotation kind the factory emits for the pane.
        enum Relation: Sendable, Equatable {
            /// At least one non-user counterparty on the neighbour matches
            /// the locked email's counterparty set — sender for received
            /// mail, recipients for sent mail. Strong "same relationship
            /// widening" signal.
            case sameCorrespondent
            /// No correspondent overlap with the locked email. Pure
            /// topical similarity from a different sender / recipient
            /// circle.
            case differentCorrespondent
        }

        let messageId: String
        let row: MessageFilterRow
        let bestSimilarity: Float
        let rank: Int
        let matchedChunkSummary: String?
        let representativeWorld: SIMD3<Float>
        let relation: Relation
        let semanticReason: SemanticEdgeReason?

        init(
            messageId: String,
            row: MessageFilterRow,
            bestSimilarity: Float,
            rank: Int,
            matchedChunkSummary: String?,
            representativeWorld: SIMD3<Float>,
            relation: Relation,
            semanticReason: SemanticEdgeReason? = nil
        ) {
            self.messageId = messageId
            self.row = row
            self.bestSimilarity = bestSimilarity
            self.rank = rank
            self.matchedChunkSummary = matchedChunkSummary
            self.representativeWorld = representativeWorld
            self.relation = relation
            self.semanticReason = semanticReason
        }
    }

    let center: Center
    let ownChunks: [OwnChunk]
    let thread: [ThreadSibling]
    let neighbours: [Neighbour]
    let surveyTelemetry: SurveyTelemetry
    /// Every attachment row attached to the locked message — including those
    /// that did not produce embedded chunks (binary-only attachments, or text-
    /// bearing attachments still awaiting the `extractAttachments` worker).
    /// The CONTEXT pane's FILES list iterates this directly so attachments are
    /// always visible regardless of extraction state.
    /// `var` so capture-metadata arrivals can refresh rows in place without
    /// resetting the lock (see `LockedNodeOverlay.observeExtractionCompletions`).
    var attachments: [LockedAttachmentSummary]
}

enum LockedNodeContextError: Error, Equatable {
    case centerNotFound
}
