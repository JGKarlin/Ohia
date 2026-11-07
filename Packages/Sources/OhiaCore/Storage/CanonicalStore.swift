import Foundation

public struct CanonicalStore: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    public func messageDirectory(messageId: String) -> URL {
        baseDirectory.appendingPathComponent(messageId)
    }

    public func saveRawMessage(messageId: String, data: Data) throws {
        let dir = messageDirectory(messageId: messageId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("raw.eml"))
    }

    public func loadRawMessage(messageId: String) throws -> Data {
        try Data(contentsOf: messageDirectory(messageId: messageId).appendingPathComponent("raw.eml"))
    }

    public func saveBodyText(messageId: String, text: String) throws {
        let dir = messageDirectory(messageId: messageId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("body.txt"), atomically: true, encoding: .utf8)
    }

    public func loadBodyText(messageId: String) throws -> String {
        try String(contentsOf: messageDirectory(messageId: messageId).appendingPathComponent("body.txt"), encoding: .utf8)
    }

    public func readBody(messageId: String) throws -> String {
        try loadBodyText(messageId: messageId)
    }

    public func saveBodyHTML(messageId: String, html: String) throws {
        let dir = messageDirectory(messageId: messageId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let normalizedHTML = Self.htmlWithUTF8CharsetMetadata(html)
        try normalizedHTML.write(to: dir.appendingPathComponent("body.html"), atomically: true, encoding: .utf8)
    }

    private static func htmlWithUTF8CharsetMetadata(_ html: String) -> String {
        let pattern = #"(?i)(<meta\b[^>]*\bcharset\s*=\s*)(["']?)[^"';/\s>]+(\2)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "$1$2utf-8$3"
        )
    }

    public func saveAttachment(messageId: String, filename: String, data: Data) throws {
        let dir = messageDirectory(messageId: messageId).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(Self.sanitizeAttachmentFilename(filename)))
    }

    public func saveAttachmentText(messageId: String, filename: String, text: String) throws {
        let dir = messageDirectory(messageId: messageId).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeAttachmentFilename(filename) + ".txt"
        try text.write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
    }

    public func saveAttachmentEmbeddingText(messageId: String, filename: String, text: String) throws {
        let dir = messageDirectory(messageId: messageId).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeAttachmentFilename(filename) + ".embedding.txt"
        try text.write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
    }

    public func saveAttachmentExtractionMetadata(messageId: String, filename: String, json: String) throws {
        let dir = messageDirectory(messageId: messageId).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeAttachmentFilename(filename) + ".ir.json"
        try json.write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
    }

    public func saveAttachmentRAGDocument(messageId: String, filename: String, json: String) throws {
        let dir = messageDirectory(messageId: messageId).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeAttachmentFilename(filename) + ".rag.json"
        try json.write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
    }

    public func attachmentPath(messageId: String, filename: String) -> URL {
        messageDirectory(messageId: messageId)
            .appendingPathComponent("attachments")
            .appendingPathComponent(Self.sanitizeAttachmentFilename(filename))
    }

    public func attachmentEmbeddingTextPath(messageId: String, filename: String) -> URL {
        messageDirectory(messageId: messageId)
            .appendingPathComponent("attachments")
            .appendingPathComponent(Self.sanitizeAttachmentFilename(filename) + ".embedding.txt")
    }

    public func attachmentExtractionMetadataPath(messageId: String, filename: String) -> URL {
        messageDirectory(messageId: messageId)
            .appendingPathComponent("attachments")
            .appendingPathComponent(Self.sanitizeAttachmentFilename(filename) + ".ir.json")
    }

    public func attachmentRAGDocumentPath(messageId: String, filename: String) -> URL {
        messageDirectory(messageId: messageId)
            .appendingPathComponent("attachments")
            .appendingPathComponent(Self.sanitizeAttachmentFilename(filename) + ".rag.json")
    }

    /// Make `filename` safe to use as a single path component. Replaces `/`
    /// (which `URL.appendingPathComponent` would interpret as a directory
    /// boundary, producing NSCocoaErrorDomain Code=4 / POSIX ENOENT when the
    /// implied parent directory doesn't exist) and `\` (Windows-mounted-share
    /// hygiene) with `_`. Empty input falls back to `untitled` so the rest of
    /// the pipeline always has something to point at.
    public static func sanitizeAttachmentFilename(_ filename: String) -> String {
        var sanitized = filename.replacingOccurrences(of: "/", with: "_")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "_")
        return sanitized.isEmpty ? "untitled" : sanitized
    }

    /// Remove the complete artifact directory for a message. Idempotent so a
    /// retry after partial cleanup can call it again safely.
    public func deleteAllArtifacts(messageId: String) throws {
        let dir = messageDirectory(messageId: messageId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
