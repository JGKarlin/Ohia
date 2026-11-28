import Foundation

/// What an attachment is by its declared MIME type and filename, which
/// decides the extraction that reads it: text extraction for documents
/// (`isDocument`), visual extraction for images, none for `unsupported`.
/// `Attachment` stores it when the row is created (`declaredDocumentKind`),
/// so the extraction workers' store predicates compare a column.
public enum DocumentKind: String, Codable, CaseIterable, Sendable, Equatable {
    case plainText
    case html
    case markdown
    case csv
    case tsv
    case rtf
    case pdf
    case docx
    case xlsx
    case pptx
    case legacyWord
    case legacySpreadsheet
    case legacyPresentation
    case image
    case unsupported

    public static func detect(mimeType rawMimeType: String, filename: String) -> DocumentKind {
        let mimeType = normalizedMIMEType(rawMimeType)
        let ext = (filename as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf": return .pdf
        case "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return .image
        case "html", "htm", "xhtml": return .html
        case "md", "markdown": return .markdown
        case "csv": return .csv
        case "tsv": return .tsv
        case "rtf": return .rtf
        case "txt", "text", "log": return .plainText
        case "docx", "docm": return .docx
        case "xlsx", "xlsm": return .xlsx
        case "pptx", "pptm": return .pptx
        case "doc": return .legacyWord
        case "xls": return .legacySpreadsheet
        case "ppt": return .legacyPresentation
        default:
            break
        }

        if mimeType.hasPrefix("image/") { return .image }

        switch mimeType {
        case "application/pdf":
            return .pdf
        case "text/html", "application/xhtml+xml":
            return .html
        case "text/markdown", "text/x-markdown":
            return .markdown
        case "text/csv", "application/csv":
            return .csv
        case "text/tab-separated-values":
            return .tsv
        case "application/rtf", "text/rtf", "application/x-rtf":
            return .rtf
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             "application/vnd.ms-word.document.macroenabled.12":
            return .docx
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             "application/vnd.ms-excel.sheet.macroenabled.12":
            return .xlsx
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation",
             "application/vnd.ms-powerpoint.presentation.macroenabled.12":
            return .pptx
        case "application/msword":
            return .legacyWord
        case "application/vnd.ms-excel":
            return .legacySpreadsheet
        case "application/vnd.ms-powerpoint":
            return .legacyPresentation
        default:
            if mimeType.hasPrefix("text/") {
                return .plainText
            }
            return .unsupported
        }
    }

    public var isTextBearing: Bool {
        self != .unsupported
    }

    public var isDocument: Bool {
        switch self {
        case .image, .unsupported:
            return false
        default:
            return true
        }
    }

    public static func normalizedMIMEType(_ value: String) -> String {
        value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
