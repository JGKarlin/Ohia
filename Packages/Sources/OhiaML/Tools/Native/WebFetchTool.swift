import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class WebFetchTool: AgentTool, @unchecked Sendable {
    public let name = "web_fetch"
    public let toolDescription = "Fetch content from URLs referenced in emails"

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let urls = extractURLs(from: query)
        guard !urls.isEmpty else {
            return ToolResult(findings: [Finding(text: "No URLs found in query", confidence: 0.0)])
        }

        var findings: [Finding] = []
        for url in urls.prefix(3) {
            let resultBox = FetchResultBox()
            let sem = DispatchSemaphore(value: 0)

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                defer { sem.signal() }
                if let error {
                    resultBox.store(.failure(error))
                } else if let data {
                    #if canImport(AppKit)
                    if let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
                        resultBox.store(.success(attr.string))
                    } else {
                        resultBox.store(.success(String(data: data, encoding: .utf8) ?? "(binary content)"))
                    }
                    #else
                    resultBox.store(.success(String(data: data, encoding: .utf8) ?? "(binary content)"))
                    #endif
                }
            }
            task.resume()
            if sem.wait(timeout: .now() + 10) == .timedOut {
                task.cancel()
                findings.append(Finding(text: "Failed to fetch \(url.absoluteString): request timed out", confidence: 0.1))
                continue
            }

            switch resultBox.load() {
            case .failure(let error):
                findings.append(Finding(text: "Failed to fetch \(url.absoluteString): \(error.localizedDescription)", confidence: 0.1))
            case .success(let result) where !result.isEmpty:
                findings.append(Finding(text: "Content from \(url.absoluteString):\n\(String(result.prefix(2000)))", confidence: 0.8))
            case .success, nil:
                break
            }
        }
        return ToolResult(findings: findings)
    }

    public func extractURLs(from text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let matches = detector?.matches(in: text, range: range) else { return [] }
        return matches.compactMap { $0.url }
    }
}

private final class FetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?

    func store(_ value: Result<String, Error>) {
        lock.withLock {
            result = value
        }
    }

    func load() -> Result<String, Error>? {
        lock.withLock {
            result
        }
    }
}
