import Foundation

// MARK: - MessageMetadata

public struct MessageMetadata: Sendable {
    public let from: String
    public let to: String
    public let dateBucket: String
    public let subject: String
    public let attachments: [String]
    public let language: String?

    public init(
        from: String,
        to: String,
        dateBucket: String,
        subject: String,
        attachments: [String],
        language: String?
    ) {
        self.from = from
        self.to = to
        self.dateBucket = dateBucket
        self.subject = subject
        self.attachments = attachments
        self.language = language
    }
}

// MARK: - EmbeddingDocumentBuilder

public enum EmbeddingDocumentBuilder: Sendable {

    // MARK: - Public Methods

    /// Builds the document fed to the embedder for a body chunk: the body text alone,
    /// no metadata header, no `BODY:` marker. Stripping the FROM/TO/DATE_BUCKET/SUBJECT/
    /// ATTACHMENTS/LANGUAGE preamble (which is structurally identical across
    /// every message) eliminates the noise floor that pumped pairwise cosine into the
    /// 0.7–0.8 range for unrelated content. The summary vector (`buildSummaryDocument`)
    /// keeps the metadata-rich form because it is the email's representative.
    ///
    /// `metadata` is accepted but unused so callers stay structurally aligned with the
    /// summary/attachment paths, which still consume it.
    public static func buildContextDocument(metadata: MessageMetadata, bodyChunk: String) -> String {
        _ = metadata
        return bodyChunk
    }

    /// Builds a summary document: metadata header + body preview (no "BODY:" key).
    public static func buildSummaryDocument(
        metadata: MessageMetadata,
        bodyPreview: String,
        messageEvidenceDigest: String? = nil
    ) -> String {
        var parts = metadataHeader(metadata)
        parts.append("BODY_PREVIEW: \(bodyPreview)")
        if let messageEvidenceDigest,
           !messageEvidenceDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("")
            parts.append(messageEvidenceDigest)
        }
        return parts.joined(separator: "\n")
    }

    /// Builds a style exemplar document from recipient info and sent text.
    public static func buildStyleExemplar(recipientInfo: String, sentText: String) -> String {
        [
            "STYLE_CONTEXT: \(recipientInfo)",
            "SENT_TEXT: \(sentText)"
        ].joined(separator: "\n")
    }

    /// Builds an attachment document: metadata header + attachment filename + extracted text chunk.
    public static func buildAttachmentDocument(
        metadata: MessageMetadata,
        filename: String,
        extractedTextChunk: String
    ) -> String {
        attachmentDocumentHeader(metadata: metadata, filename: filename) + extractedTextChunk
    }

    /// Everything in an attachment document before its text chunk, so callers
    /// can measure it and size the chunk to the room left.
    public static func attachmentDocumentHeader(metadata: MessageMetadata, filename: String) -> String {
        var parts = metadataHeader(metadata)
        parts.append("ATTACHMENT: \(filename)")
        parts.append("ATTACHMENT_TEXT: ")
        return parts.joined(separator: "\n")
    }

    /// Everything in a style exemplar before the sent text.
    public static func styleExemplarHeader(recipientInfo: String) -> String {
        buildStyleExemplar(recipientInfo: recipientInfo, sentText: "")
    }

    /// Returns a date bucket string in the form "YYYY-MM, QN, weekday|weekend".
    public static func dateBucket(from date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .weekday], from: date)

        let year = components.year ?? 0
        let month = components.month ?? 1

        let monthString = String(format: "%04d-%02d", year, month)

        let quarter: Int
        switch month {
        case 1...3:  quarter = 1
        case 4...6:  quarter = 2
        case 7...9:  quarter = 3
        default:     quarter = 4
        }

        // weekday: 1 = Sunday, 7 = Saturday in Gregorian calendar
        let weekday = components.weekday ?? 1
        let dayType = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"

        return "\(monthString), Q\(quarter), \(dayType)"
    }

    // MARK: - Private Helpers

    private static func metadataHeader(_ metadata: MessageMetadata) -> [String] {
        var lines: [String] = []
        lines.append("FROM: \(metadata.from)")
        lines.append("TO: \(metadata.to)")
        lines.append("DATE_BUCKET: \(metadata.dateBucket)")
        lines.append("SUBJECT: \(metadata.subject)")

        if !metadata.attachments.isEmpty {
            lines.append("ATTACHMENTS: \(metadata.attachments.joined(separator: ", "))")
        }

        if let language = metadata.language {
            lines.append("LANGUAGE: \(language)")
        }

        return lines
    }
}
