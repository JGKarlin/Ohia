import Foundation
import SwiftUI
import OhiaCore

/// Coarse-grain attachment classification for the Timeline multitrack
/// attachment subtracks and the "isolate by attachment kind" affordance.
/// Derived from `Attachment.mimeType` + `detectedDocumentKind`. Order of
/// declaration is the order subtracks render top-to-bottom.
public enum TimelineAttachmentKind: String, CaseIterable, Sendable, Hashable, Codable {
    case pdf
    case spreadsheet
    case presentation
    case document
    case image
    case archive
    case audio
    case video
    case code
    case other

    /// Symbol used in the multitrack subtrack glyphs and the chip overlay.
    public var symbolName: String {
        switch self {
        case .pdf:          return "doc.richtext"
        case .spreadsheet:  return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .document:     return "doc.text"
        case .image:        return "photo"
        case .archive:      return "archivebox"
        case .audio:        return "waveform"
        case .video:        return "film"
        case .code:         return "chevron.left.forwardslash.chevron.right"
        case .other:        return "paperclip"
        }
    }

    /// Universal tint applied wherever the kind is surfaced — Timeline
    /// multitrack attachment chips, locked-node attachment file rows,
    /// and any future surface should route through this single
    /// mapping so a PDF reads the same orange in every lens. The
    /// pairing follows Apple's analog where one exists (Pages blue,
    /// Numbers green, Keynote pink, Photos purple), with neutrals
    /// for kinds that don't carry a strong native-app association.
    public var tint: Color {
        switch self {
        case .pdf:          return OhiaColors.accentOrange
        case .spreadsheet:  return OhiaColors.accentGreen
        case .presentation: return OhiaColors.accentPink
        case .document:     return OhiaColors.accentBlue
        case .image:        return OhiaColors.accentPurple
        case .audio:        return OhiaColors.accentBlueGlow
        case .video:        return OhiaColors.accentTeal
        case .code:         return OhiaColors.textPrimary
        case .archive:      return OhiaColors.textSecondary
        case .other:        return OhiaColors.textTertiary
        }
    }

    /// Short label for filter chips and hover tooltips.
    public var label: String {
        switch self {
        case .pdf:          return "PDF"
        case .spreadsheet:  return "Spreadsheet"
        case .presentation: return "Slides"
        case .document:     return "Document"
        case .image:        return "Image"
        case .archive:      return "Archive"
        case .audio:        return "Audio"
        case .video:        return "Video"
        case .code:         return "Code"
        case .other:        return "Attachment"
        }
    }

    public static func classify(mimeType: String?, fileName: String? = nil) -> TimelineAttachmentKind {
        let mime = (mimeType ?? "").lowercased()
        let ext = (fileName as NSString?)?.pathExtension.lowercased() ?? ""

        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if mime.contains("spreadsheet") || mime == "text/csv"
            || ["xls", "xlsx", "csv", "numbers", "ods"].contains(ext) { return .spreadsheet }
        if mime.contains("presentation")
            || ["ppt", "pptx", "key", "odp"].contains(ext) { return .presentation }
        if mime.contains("word") || mime == "text/plain" || mime == "text/rtf"
            || mime == "application/rtf" || mime.contains("opendocument.text")
            || ["doc", "docx", "rtf", "txt", "pages", "odt", "md"].contains(ext) { return .document }
        if mime == "application/zip" || mime.contains("compressed")
            || ["zip", "tar", "gz", "7z", "rar", "bz2", "xz"].contains(ext) { return .archive }
        if mime.hasPrefix("text/") && ext.isEmpty == false { return .code }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "cpp",
            "h", "hpp", "m", "mm", "rb", "java", "kt", "sh", "json", "yaml",
            "yml", "xml", "html", "css"].contains(ext) { return .code }
        return .other
    }
}
