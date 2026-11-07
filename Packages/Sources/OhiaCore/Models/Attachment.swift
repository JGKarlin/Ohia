import Foundation
import SwiftData

@Model
public final class Attachment {
    public var id: UUID
    public var message: Message?
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    public var filePath: String?
    public var extractedTextPath: String?
    public var embeddingTextPath: String?
    public var extractionMetadataPath: String?
    public var ragDocumentPath: String?
    public var extractionMethod: String?
    public var detectedDocumentKind: String?
    public var extractionStatus: String?
    public var extractionFailureReason: String?
    public var extractionParserVersion: String?
    public var extractionCharacterCount: Int?
    public var extractionStructureUnitKind: String?
    public var extractionStructureUnitCount: Int?
    /// Document-embedded title (OOXML `dc:title` / PDF title attribute), when the
    /// source file carried one. Often blank or stale (template metadata), so the
    /// attachment-summary prompt treats it as a cross-check hint and prefers the
    /// title discernible in the extracted text. `nil` when absent or for kinds
    /// without embedded metadata (plain text, images).
    public var documentTitle: String?
    /// Document-embedded author (OOXML `dc:creator` / PDF author attribute), when
    /// present. Same caveat as `documentTitle` — frequently a template author
    /// ("Microsoft Office User") so it is a hint, not authoritative.
    public var documentAuthor: String?
    public var extractionAttemptCount: Int?
    public var extractionLastAttemptedAt: Date?
    public var extractionNextRetryAt: Date?
    public var extractionRetryPolicyVersion: String?
    public var extractionRetryReason: String?
    public var visualExtractionStatus: String?
    public var visualExtractionMethod: String?
    public var visualExtractionFailureReason: String?
    public var visualExtractionParserVersion: String?
    public var visualEvidenceJSON: String?
    public var visualSummary: String?
    public var visualGeneratedAt: Date?
    public var visualSignalCount: Int?
    public var visualEvidenceKind: String?
    public var visualImageWidth: Int?
    public var visualImageHeight: Int?
    public var visualImagePixelCount: Int?
    public var visualOriginalImageWidth: Int?
    public var visualOriginalImageHeight: Int?
    public var visualOriginalImagePixelCount: Int?
    public var visualWasDownsampled: Bool?
    public var visualMimeExtensionMismatch: Bool?
    public var visualOCRLineCount: Int?
    public var visualOCRBlockCount: Int?
    public var visualOCRCharacterCount: Int?
    public var visualClassificationCount: Int?
    public var visualObjectCount: Int?
    /// Three-sentence reader-facing paragraph for the locked-node attachment
    /// pane. Generated after text or visual evidence extraction completes,
    /// and reused by on-demand expansion when present.
    public var attachmentSummary: String?
    public var attachmentSummaryGeneratedAt: Date?
    public var attachmentSummaryFingerprint: String?
    public var attachmentSummaryAttemptedAt: Date?
    public var attachmentSummaryFailureReason: String?
    /// RFC 2045 `Content-ID` header value with surrounding angle brackets stripped.
    /// Populated by `IngestionOrchestrator` from `ParsedAttachment.contentId` when
    /// the MIME part carried the header. Used to detect inline image references
    /// (`<img src="cid:...">`) in the HTML body so the same image isn't shown
    /// both inline and as a separate attachment thumbnail.
    public var contentId: String?
    /// True when the source MIME part is `Content-Disposition: inline` AND its
    /// `contentId` is referenced by a `cid:` URL in the message's HTML body.
    /// Computed at ingestion time and persisted so the locked-node overlay can
    /// drop these from the FILES list without re-parsing the body at render time.
    /// `nil` for rows ingested before this distinction was tracked; those backfill
    /// on the next ingestion touch via `repairExistingMessageArtifacts`.
    public var isInline: Bool?
    /// iCloud Mail Drop download link for a file the sender's Mail app
    /// uploaded instead of attaching (`Remote-Attachment-Url` header). The
    /// row has no `filePath`; the bytes stay on iCloud until `remoteExpiresAt`.
    public var remoteURL: String?
    public var remoteExpiresAt: Date?
    /// Encoded `AttachmentCaptureMetadata` (capture time, place, captions)
    /// read from photo EXIF/IPTC/XMP or video QuickTime metadata.
    public var captureMetadataJSON: String?
    /// Reader version plus place-name language the stored metadata was built
    /// with; a mismatch makes the capture-metadata worker visit the row again.
    public var captureMetadataVersion: String?
    public var captureMetadataAttemptCount: Int?
    /// Earliest retry after a transient failure (offline, MapKit throttling,
    /// unreachable Mail Drop link).
    public var captureMetadataNextAttemptAt: Date?
    public var embeddingStatus: ProcessingStatus

    public init(filename: String, mimeType: String, sizeBytes: Int) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.embeddingStatus = .pending
    }
}

public extension Attachment {
    func clearAttachmentSummary() {
        attachmentSummary = nil
        attachmentSummaryGeneratedAt = nil
        attachmentSummaryFingerprint = nil
        attachmentSummaryAttemptedAt = nil
        attachmentSummaryFailureReason = nil
    }
}
