import Foundation
import OhiaCore

public struct AskMemorySnippet: Sendable, Equatable, Hashable {
    public let title: String
    public let text: String
    public let source: String
    public let score: Double
    public let statusRaw: String?
    public let kindRaw: String?
    public let formationBasisRaw: String?
    public let usePolicyRaw: String?
    public let futureUseText: String?

    public init(
        title: String,
        text: String,
        source: String,
        score: Double,
        statusRaw: String? = nil,
        kindRaw: String? = nil,
        formationBasisRaw: String? = nil,
        usePolicyRaw: String? = nil,
        futureUseText: String? = nil
    ) {
        self.title = title
        self.text = text
        self.source = source
        self.score = score
        self.statusRaw = statusRaw
        self.kindRaw = kindRaw
        self.formationBasisRaw = formationBasisRaw
        self.usePolicyRaw = usePolicyRaw
        self.futureUseText = futureUseText
    }
}

public struct AskMemoryContext: Sendable, Equatable, Hashable {
    public let snippets: [AskMemorySnippet]

    public init(snippets: [AskMemorySnippet]) {
        self.snippets = snippets
    }

    public static let empty = AskMemoryContext(snippets: [])

    public var isEmpty: Bool {
        snippets.isEmpty
    }

    public var uiSummary: String? {
        guard !snippets.isEmpty else { return nil }
        let unit = snippets.count == 1 ? "memory note" : "memory notes"
        return "used \(snippets.count) \(unit)"
    }

    public func promptNotes(maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        var remaining = maxCharacters
        var lines: [String] = []
        for (index, snippet) in snippets.enumerated() where remaining > 0 {
            let body = Self.promptSafeInlineText(snippet.text)
            let title = Self.promptSafeInlineText(snippet.title)
            let source = Self.promptSafeInlineText(snippet.source)
            let policy = snippet.usePolicyRaw.map { " | policy \(Self.promptSafeInlineText($0))" } ?? ""
            var line = "MEMORY-\(index + 1) | \(title) | \(body)\(policy) | source \(source)"
            if line.count > remaining {
                line = String(line.prefix(remaining))
            }
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            lines.append(line)
            remaining -= line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    private static func promptSafeInlineText(_ text: String) -> String {
        var output = text
        for token in [
            GenerationStopPolicy.askEndMarker,
            GenerationStopPolicy.summaryEndMarker,
            GenerationStopPolicy.contextOrientationEndMarker,
            "/no_think",
            "<think>",
            "</think>",
            "<thinking>",
            "</thinking>",
            "<|im_start|>",
            "<|im_end|>",
            "<|endoftext|>",
            "</s>"
        ] {
            output = output.replacingOccurrences(of: token, with: " ")
        }
        output = replacing(pattern: #"\[(\d+)\]"#, in: output, with: "(memory-ref $1)")
        output = replacing(
            pattern: #"(?i)\b(final answer|system|assistant|user|answer|response)\s*[:：]"#,
            in: output,
            with: "$1 label:"
        )
        return output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(
        pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

public struct AskMemoryLimit: Sendable, Equatable, Hashable {
    public let maxSnippets: Int
    public let maxCharacters: Int

    public init(maxSnippets: Int = 6, maxCharacters: Int = 2_400) {
        self.maxSnippets = maxSnippets
        self.maxCharacters = maxCharacters
    }

    public static let `default` = AskMemoryLimit()
}

public protocol AskMemoryProvider: Sendable {
    func context(
        for query: String,
        filter: FilterSpec,
        limit: AskMemoryLimit
    ) throws -> AskMemoryContext
}

extension AskMemoryProvider {
    public func context(
        for query: String,
        filter: FilterSpec
    ) throws -> AskMemoryContext {
        try context(for: query, filter: filter, limit: .default)
    }
}

public struct MarkdownAskMemoryProvider: AskMemoryProvider {
    public struct Configuration: Sendable, Equatable, Hashable {
        public let perSnippetCharacterLimit: Int
        public let minimumScore: Double

        public init(
            perSnippetCharacterLimit: Int = 520,
            minimumScore: Double = 1
        ) {
            self.perSnippetCharacterLimit = perSnippetCharacterLimit
            self.minimumScore = minimumScore
        }

        public static let `default` = Configuration()
    }

    private struct Candidate: Sendable {
        let title: String
        let text: String
        let source: String
        let category: String
        let lineNumber: Int
        let sourcePriority: Int
    }

    public let urls: [URL]
    public let configuration: Configuration

    public init(
        urls: [URL],
        configuration: Configuration = .default
    ) {
        self.urls = urls
        self.configuration = configuration
    }

    public static func defaultProvider(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MarkdownAskMemoryProvider? {
        let configuredPaths = environment["OHIA_ASK_MEMORY_PATHS"]?
            .split(separator: ":")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
        let configuredURLs = configuredPaths.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        let fallbackURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("memories", isDirectory: true)
            .appendingPathComponent("MEMORY.md")
        let candidates = configuredURLs.isEmpty ? [fallbackURL] : configuredURLs
        let readable = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !readable.isEmpty else { return nil }
        return MarkdownAskMemoryProvider(urls: readable)
    }

    public func context(
        for query: String,
        filter: FilterSpec,
        limit: AskMemoryLimit = .default
    ) throws -> AskMemoryContext {
        guard limit.maxSnippets > 0, limit.maxCharacters > 0 else {
            return .empty
        }
        let terms = Self.queryTerms(for: query, filter: filter)
        guard !terms.isEmpty else { return .empty }

        let candidates = urls.enumerated().flatMap { index, url -> [Candidate] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return Self.candidates(
                from: text,
                sourceName: url.lastPathComponent,
                sourcePriority: index
            )
        }
        guard !candidates.isEmpty else { return .empty }

        let scored = candidates.compactMap { candidate -> (candidate: Candidate, score: Double)? in
            guard !Self.shouldExclude(candidate.text) else { return nil }
            let score = Self.score(candidate: candidate, terms: terms, rawQuery: query)
            guard score >= configuration.minimumScore else { return nil }
            return (candidate, score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidate.sourcePriority != $1.candidate.sourcePriority {
                return $0.candidate.sourcePriority < $1.candidate.sourcePriority
            }
            return $0.candidate.lineNumber < $1.candidate.lineNumber
        }

        var snippets: [AskMemorySnippet] = []
        var remaining = limit.maxCharacters
        for item in scored where snippets.count < limit.maxSnippets && remaining > 0 {
            let text = Self.trimmed(
                item.candidate.text,
                limit: min(configuration.perSnippetCharacterLimit, remaining)
            )
            guard !text.isEmpty else { continue }
            let source = "\(item.candidate.source):\(item.candidate.lineNumber)"
            let snippet = AskMemorySnippet(
                title: item.candidate.title,
                text: text,
                source: source,
                score: item.score
            )
            let estimatedLine = "- \(snippet.title): \(snippet.text) (\(snippet.source))"
            snippets.append(snippet)
            remaining -= estimatedLine.count + 1
        }
        return AskMemoryContext(snippets: snippets)
    }

    private static func candidates(
        from markdown: String,
        sourceName: String,
        sourcePriority: Int
    ) -> [Candidate] {
        var headings: [Int: String] = [:]
        var results: [Candidate] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, subsequence) in lines.enumerated() {
            let lineNumber = offset + 1
            let raw = String(subsequence)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let heading = parseHeading(trimmed) {
                headings = headings.filter { $0.key < heading.level }
                headings[heading.level] = heading.title
                continue
            }

            guard let candidateText = candidateText(from: trimmed) else { continue }
            let title = title(from: headings)
            let category = headings
                .sorted { $0.key < $1.key }
                .last?
                .value ?? ""
            results.append(
                Candidate(
                    title: title,
                    text: candidateText,
                    source: sourceName,
                    category: category,
                    lineNumber: lineNumber,
                    sourcePriority: sourcePriority
                )
            )
        }
        return results
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        var level = 0
        for scalar in line.unicodeScalars {
            guard scalar == "#" else { break }
            level += 1
        }
        guard level > 0, line.dropFirst(level).first == " " else { return nil }
        let title = line.dropFirst(level)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : (level, title)
    }

    private static func candidateText(from line: String) -> String? {
        if line.hasPrefix("- ") {
            let text = String(line.dropFirst(2))
            guard !text.hasPrefix("rollout_summaries/") else { return nil }
            return text
        }
        for prefix in ["description:", "task:", "keywords:"] {
            guard line.hasPrefix(prefix) else { continue }
            return line
        }
        return nil
    }

    private static func title(from headings: [Int: String]) -> String {
        let parts = headings
            .sorted { $0.key < $1.key }
            .map(\.value)
            .suffix(2)
        return parts.isEmpty ? "Memory" : parts.joined(separator: " / ")
    }

    private static func queryTerms(for query: String, filter: FilterSpec) -> Set<String> {
        var terms = Set(tokenize(query))
        for collection in filter.collections where collection != .context {
            terms.insert(collection.rawValue.lowercased())
        }
        for sender in filter.senderEmails {
            terms.formUnion(tokenize(sender))
        }
        for keyword in filter.keywords ?? [] {
            terms.formUnion(tokenize(keyword))
        }
        return terms.subtracting(stopWords)
    }

    private static func score(candidate: Candidate, terms: Set<String>, rawQuery: String) -> Double {
        let searchText = "\(candidate.title) \(candidate.category) \(candidate.text)".lowercased()
        var score = 0.0
        for term in terms where searchText.contains(term) {
            score += term.count >= 8 ? 2.0 : 1.0
            if candidate.text.lowercased().contains("`\(term)`") {
                score += 1.5
            }
        }
        let normalizedQuery = rawQuery
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.count >= 8, searchText.contains(normalizedQuery) {
            score += 4.0
        }
        guard score > 0 else { return 0 }
        let lowerCategory = candidate.category.lowercased()
        if lowerCategory.contains("reusable knowledge") {
            score += 1.5
        } else if lowerCategory.contains("user preferences") {
            score += 1.0
        } else if lowerCategory.contains("failures") {
            score += 0.75
        } else if lowerCategory.contains("keywords") {
            score += 0.25
        }
        return score
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func shouldExclude(_ text: String) -> Bool {
        let lower = text.lowercased()
        for sensitive in sensitiveTerms where lower.contains(sensitive) {
            return true
        }
        return false
    }

    private static func trimmed(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sensitiveTerms: Set<String> = [
        "api key",
        "api_key",
        "bearer token",
        "client secret",
        "oauth secret",
        "password",
        "private key",
        "secret token"
    ]

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "answer", "anything", "are",
        "ask", "can", "could", "does", "for", "from", "have", "how",
        "into", "model", "our", "please", "should", "that", "the",
        "their", "then", "there", "this", "what", "when", "where", "which",
        "with", "would", "you", "your"
    ]
}
