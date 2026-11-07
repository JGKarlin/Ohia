import Foundation
import OhiaCore
import OhiaIngest

/// One file the account owner is preparing for a deadline — dropped onto the
/// guide pane's FILES section and copied into the deadline's own folder.
struct DeadlineWorkFile: Identifiable, Equatable, Sendable {
    /// Stable per (deadline, filename).
    let id: String
    let entryID: String
    let filename: String
    let url: URL
    let addedAt: Date
    let sizeBytes: Int
}

/// Stores the files a user is working with per deadline. The filesystem is the
/// source of truth: one folder per deadline entry id under
/// `Application Support/Ohia/deadline_work_files/`, holding the copied files
/// plus a hidden `.extracted/` cache of their extracted text (parsed once via
/// `AttachmentExtractor.extractText(..., policy: .full)` — the same full
/// extraction ingestion applies to message attachments, PDFs and OCR
/// included).
///
/// Folder lifecycle: a deadline's folder is created on the first drop and
/// removed when its last file is removed. A deadline that leaves tracking
/// while still holding files keeps its folder — the files are the user's own
/// working copies, and there is no reliable departure signal to hook a purge
/// to (deletion events carry vector ids, not entry ids).
///
/// Deadline entry ids ("thread-<uuid>" / "msg-<uuid>") are filesystem-safe;
/// `folderName(for:)` still sanitizes defensively so a future id shape cannot
/// escape the base directory.
struct DeadlineWorkFileStore: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
            ?? OhiaStorageRoot.required().deadlineAssets
    }

    private static let extractedSubdirectory = ".extracted"
    /// Cap the text handed to the distillation/readout prompts; the builders
    /// re-cap per prompt, this bounds the sidecar file itself.
    static let maxExtractedCharacters = 12_000

    // MARK: - Listing

    /// The deadline's working files, oldest first (the order they were added —
    /// `addedToDirectoryDate` is the drop time; a copied file keeps its source
    /// creation date, which would misreport).
    func files(entryID: String) -> [DeadlineWorkFile] {
        let folder = folderURL(entryID: entryID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [
                .addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .compactMap { url -> DeadlineWorkFile? in
                guard let values = try? url.resourceValues(
                    forKeys: [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]
                ), values.isRegularFile == true else {
                    return nil
                }
                let filename = url.lastPathComponent
                return DeadlineWorkFile(
                    id: "\(entryID)|\(filename)",
                    entryID: entryID,
                    filename: filename,
                    url: url,
                    addedAt: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast,
                    sizeBytes: values.fileSize ?? 0
                )
            }
            .sorted { ($0.addedAt, $0.filename) < ($1.addedAt, $1.filename) }
    }

    // MARK: - Mutation

    /// Copies the dropped files into the deadline's folder. Symlinks are
    /// resolved to their targets; directories, dotfiles (they would be
    /// invisible to `files(entryID:)`), and unreadable sources are skipped. A
    /// name collision gets a " 2"-style suffix rather than overwriting.
    /// Returns the stored files; failures on individual files are skipped
    /// (the caller re-lists).
    @discardableResult
    func add(fileURLs: [URL], entryID: String) -> [DeadlineWorkFile] {
        let folder = folderURL(entryID: entryID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [DeadlineWorkFile] = []
        for dropped in fileURLs {
            guard dropped.isFileURL else { continue }
            let source = dropped.resolvingSymlinksInPath()
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            guard source.lastPathComponent.hasPrefix(".") == false else { continue }
            let destination = availableDestination(for: source.lastPathComponent, in: folder)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                continue
            }
            let destinationValues = try? destination.resourceValues(
                forKeys: [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey]
            )
            added.append(
                DeadlineWorkFile(
                    id: "\(entryID)|\(destination.lastPathComponent)",
                    entryID: entryID,
                    filename: destination.lastPathComponent,
                    url: destination,
                    addedAt: destinationValues?.addedToDirectoryDate ?? destinationValues?.creationDate ?? .now,
                    sizeBytes: destinationValues?.fileSize ?? 0
                )
            )
        }
        return added
    }

    /// Removes one working file and its extracted-text sidecar.
    @discardableResult
    func remove(_ file: DeadlineWorkFile) -> Bool {
        if FileManager.default.fileExists(atPath: file.url.path) {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                return false
            }
        }
        try? FileManager.default.removeItem(at: sidecarURL(for: file))
        // Drop the folder once it is empty so abandoned deadlines leave nothing.
        let folder = folderURL(entryID: file.entryID)
        if files(entryID: file.entryID).isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
        return true
    }

    // MARK: - Extraction

    /// Files above this size are not parsed — a working file this large is
    /// not a form or a draft, and the prompts cap far below it anyway.
    static let maxExtractionBytes = 24_000_000

    /// The file's extracted text, parsing once with the full ingestion
    /// extraction (PDFKit, OOXML, RTF, plain text, Vision OCR for images) and
    /// caching the result in the folder's hidden `.extracted/` sidecar. Runs
    /// the parse off the calling executor. Returns `nil` when the file's type
    /// or content yields no text; that outcome is cached too — image OCR is
    /// expensive, and re-attempting it on every pane visit would burn CPU for
    /// the same answer. Removing and re-adding the file retries.
    func extractedText(for file: DeadlineWorkFile) async -> String? {
        let sidecar = sidecarURL(for: file)
        if let cached = try? String(contentsOf: sidecar, encoding: .utf8) {
            return cached.isEmpty ? nil : cached
        }
        let fileURL = file.url
        let filename = file.filename
        let text = await Task.detached(priority: .utility) { () -> String? in
            guard let sizeValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = sizeValues.fileSize,
                  size <= Self.maxExtractionBytes else {
                return nil
            }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
            let extracted = try? AttachmentExtractor.extractText(
                data: data,
                mimeType: "application/octet-stream",
                filename: filename,
                policy: .full
            )
            guard let extracted, extracted.isEmpty == false else { return nil }
            return String(extracted.prefix(Self.maxExtractedCharacters))
        }.value
        let folder = sidecar.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (text ?? "").write(to: sidecar, atomically: true, encoding: .utf8)
        return text
    }

    // MARK: - Paths

    func folderURL(entryID: String) -> URL {
        baseDirectory.appendingPathComponent(Self.folderName(for: entryID), isDirectory: true)
    }

    private func sidecarURL(for file: DeadlineWorkFile) -> URL {
        folderURL(entryID: file.entryID)
            .appendingPathComponent(Self.extractedSubdirectory, isDirectory: true)
            .appendingPathComponent(file.filename + ".txt")
    }

    /// Entry ids are already "thread-<uuid>" / "msg-<uuid>"; keep alphanumerics,
    /// hyphens, underscores, and dots, and fold anything else to "_" so no id
    /// shape can traverse out of the base directory. A name that folds to
    /// nothing but dots ("." / ".." / "...") would still traverse — those
    /// collapse to "unknown".
    static func folderName(for entryID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let folded = String(entryID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        guard folded.isEmpty == false,
              folded.contains(where: { $0 != "." }) else {
            return "unknown"
        }
        return folded
    }

    private func availableDestination(for filename: String, in folder: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
