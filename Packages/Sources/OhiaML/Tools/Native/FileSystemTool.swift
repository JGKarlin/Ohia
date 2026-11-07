import Foundation

public final class FileSystemTool: AgentTool, @unchecked Sendable {
    public let name = "file_system"
    public let toolDescription = "Find local documents by filename or content"

    private let searchDirectories: [URL]

    public init(searchDirectories: [URL]? = nil) {
        self.searchDirectories = searchDirectories ?? Self.defaultDirectories()
    }

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let queryLower = query.lowercased()
        var findings: [Finding] = []
        var deliverables: [Deliverable] = []

        for directory in searchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard rv?.isRegularFile == true else { continue }

                let filename = fileURL.lastPathComponent.lowercased()
                if filename.contains(queryLower) || queryLower.split(separator: " ").allSatisfy({ filename.contains($0) }) {
                    let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = attrs?.fileSize ?? 0
                    let modified = attrs?.contentModificationDate
                    let dateStr = modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown"

                    findings.append(Finding(
                        text: "Found: \(fileURL.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), modified: \(dateStr))",
                        confidence: 0.8
                    ))
                    deliverables.append(Deliverable(
                        filename: fileURL.lastPathComponent,
                        filePath: fileURL.path,
                        sourceMessageId: "local_file"
                    ))
                }
            }
        }
        return ToolResult(findings: findings, deliverables: deliverables)
    }

    private static func defaultDirectories() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let d = fm.urls(for: .documentDirectory, in: .userDomainMask).first { dirs.append(d) }
        if let d = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first { dirs.append(d) }
        if let d = fm.urls(for: .desktopDirectory, in: .userDomainMask).first { dirs.append(d) }
        return dirs
    }
}
