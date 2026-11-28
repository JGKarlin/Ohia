import Foundation
import OhiaCore

extension DocumentKind {
    var isCheapInlineText: Bool {
        switch self {
        case .plainText, .html, .markdown, .csv, .tsv:
            return true
        default:
            return false
        }
    }

    public var defaultMethod: AttachmentExtractionMethod? {
        switch self {
        case .plainText, .markdown:
            return .utf8Decode
        case .csv, .tsv:
            return .delimitedTable
        case .html:
            return .nsAttributedStringHTML
        case .rtf:
            return .nsAttributedStringRTF
        case .pdf:
            return .liteParsePDF
        case .docx, .xlsx, .pptx:
            return .swiftOOXML
        case .legacyWord, .legacySpreadsheet, .legacyPresentation:
            return .nsAttributedStringOffice
        case .image:
            return .visionOCR
        case .unsupported:
            return nil
        }
    }
}
