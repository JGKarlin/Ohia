import Foundation

/// Runs the bundled LiteParse helper on one PDF. Used inside
/// `OhiaPDFParser.xpc`, whose sandbox the helper process inherits.
public struct LiteParseHelperRunner: Sendable {
    public struct Command: Sendable, Equatable {
        public let executableURL: URL
        public let baseArguments: [String]

        public init(executableURL: URL, baseArguments: [String] = []) {
            self.executableURL = executableURL
            self.baseArguments = baseArguments
        }
    }

    public let command: Command?
    public let timeout: TimeInterval
    public let maxOutputBytes: Int

    public init(
        command: Command?,
        timeout: TimeInterval = PDFParserLimits.helperTimeout,
        maxOutputBytes: Int = PDFParserLimits.maxOutputBytes
    ) {
        self.command = command
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    /// Node and the LiteParse CLI inside `bundle`'s `Resources/LiteParseHelper`.
    /// Node is launched directly rather than through the `lit` shell wrapper,
    /// so no shell runs inside the parser's sandbox.
    public static func bundledCommand(in bundle: Bundle) -> Command? {
        guard let resources = bundle.resourceURL else { return nil }
        let helper = resources.appendingPathComponent("LiteParseHelper", isDirectory: true)
        let node = helper.appendingPathComponent("node/bin/node")
        let cli = helper.appendingPathComponent("node_modules/@llamaindex/liteparse/dist/cli.js")
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: node.path),
              fileManager.fileExists(atPath: cli.path) else {
            return nil
        }
        return Command(executableURL: node, baseArguments: [cli.path])
    }

    public func parse(_ pdf: Data, maxPages: Int) -> PDFParserReply {
        guard let command else { return PDFParserReply(outcome: .helperUnavailable) }
        guard !pdf.isEmpty, pdf.count <= PDFParserLimits.maxInputBytes else {
            return PDFParserReply(outcome: .invalidRequest)
        }
        let pages = min(max(1, maxPages), PDFParserLimits.maxPages)

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("OhiaLiteParse-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return PDFParserReply(outcome: .launchFailed)
        }
        defer { try? fileManager.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.pdf")
        let outputURL = directory.appendingPathComponent("output.json")
        let stderrURL = directory.appendingPathComponent("stderr.txt")
        guard (try? pdf.write(to: inputURL, options: [.atomic])) != nil,
              fileManager.createFile(atPath: stderrURL.path, contents: nil),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return PDFParserReply(outcome: .launchFailed)
        }
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.baseArguments + [
            "parse",
            inputURL.path,
            "--format",
            "json",
            "--no-ocr",
            "--max-pages",
            "\(pages)",
            "-o",
            outputURL.path,
        ]
        // An explicit environment: nothing inherited (NODE_OPTIONS, NODE_PATH
        // and similar) can change what the helper loads. HOME and TMPDIR are
        // this request's own directory, deleted afterwards, so nothing one
        // parse writes can influence the parse of another sender's PDF.
        process.environment = [
            "HOME": directory.path,
            "TMPDIR": directory.path,
            "LANG": "en_US.UTF-8",
        ]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return PDFParserReply(outcome: .launchFailed)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return PDFParserReply(outcome: .timedOut, stderr: Self.prefix(of: stderrURL))
        }

        let stderr = Self.prefix(of: stderrURL)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return PDFParserReply(
                outcome: .processFailed,
                status: process.terminationStatus,
                stderr: stderr
            )
        }
        switch Self.readRegularFile(at: outputURL, limit: maxOutputBytes) {
        case .contents(let output):
            return PDFParserReply(outcome: .parsed, output: output, stderr: stderr)
        case .tooLarge:
            return PDFParserReply(outcome: .outputTooLarge, stderr: stderr)
        case .unreadable:
            return PDFParserReply(outcome: .processFailed, status: 0, stderr: stderr)
        }
    }

    enum OutputRead: Equatable {
        case contents(Data)
        case tooLarge
        case unreadable
    }

    /// Reads at most `limit` bytes of the helper's output. The helper is
    /// untrusted, so the output must be a regular file opened without
    /// following a symlink: a link to `/dev/zero`, a FIFO, or a file outside
    /// the request directory is refused rather than read.
    static func readRegularFile(at url: URL, limit: Int) -> OutputRead {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return .unreadable
        }
        guard status.st_size <= off_t(limit) else { return .tooLarge }
        do {
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count > limit ? .tooLarge : .contents(data)
        } catch {
            return .unreadable
        }
    }

    private static func prefix(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: PDFParserLimits.maxStderrBytes)) ?? nil
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
