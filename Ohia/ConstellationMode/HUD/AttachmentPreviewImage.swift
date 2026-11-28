import AppKit
import Foundation
import OhiaPDFParsing

/// The image an attachment preview draws, for every surface that shows one:
/// the Front Page card, annotation popups, the Projects files pane and hover
/// popup, and the Timeline reader.
///
/// The file is read off the main actor and drawn from its bytes only when
/// `ImageDecodeBudget.admitsDrawing` admits them: an SVG, or a raster image
/// whose decode fits the budget, since a small file can declare gigabytes of
/// pixels. `NSImage(data:)` picks the image representation from those same
/// bytes. `NSImage(contentsOfFile:)` would pick it from the attachment's
/// filename, which the sender chose: an image with a PDF inside, named
/// `.pdf`, would reach the PDF parser, and an SVG named `.png` would draw
/// nothing.
enum AttachmentPreviewImage {
    /// The image in the file at `path`; nil when the file cannot be read,
    /// is not admitted, does not draw, or the task was cancelled meanwhile.
    @MainActor
    static func load(path: String) async -> NSImage? {
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  ImageDecodeBudget.admitsDrawing(data) else { return nil }
            return data
        }.value
        guard let data, !Task.isCancelled else { return nil }
        return NSImage(data: data)
    }
}
