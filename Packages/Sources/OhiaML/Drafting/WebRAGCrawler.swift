import CryptoKit
import Darwin
import Foundation
import OhiaIngest
import SwiftSoup

public struct WebRAGConfig: Sendable, Equatable {
    public var maxDepth: Int
    public var pageLimit: Int
    public var sameDomainOnly: Bool
    public var allowedPathPrefixes: [String]
    public var excludeLowValuePages: Bool
    public var useReadabilityExtraction: Bool
    public var preserveCleanedHTML: Bool
    public var maxHTMLBytes: Int
    public var maxChunkCharacters: Int
    public var requestTimeoutSeconds: TimeInterval
    public var maxCrawlDurationSeconds: TimeInterval?
    public var userAgent: String

    public init(
        maxDepth: Int = 0,
        pageLimit: Int = 1,
        sameDomainOnly: Bool = true,
        allowedPathPrefixes: [String] = [],
        excludeLowValuePages: Bool = true,
        useReadabilityExtraction: Bool = true,
        preserveCleanedHTML: Bool = false,
        maxHTMLBytes: Int = 4 * 1024 * 1024,
        maxChunkCharacters: Int = 1_800,
        requestTimeoutSeconds: TimeInterval = 20,
        maxCrawlDurationSeconds: TimeInterval? = nil,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605 Ohia"
    ) {
        self.maxDepth = max(0, min(maxDepth, 1))
        self.pageLimit = max(1, pageLimit)
        self.sameDomainOnly = sameDomainOnly
        self.allowedPathPrefixes = allowedPathPrefixes
        self.excludeLowValuePages = excludeLowValuePages
        self.useReadabilityExtraction = useReadabilityExtraction
        self.preserveCleanedHTML = preserveCleanedHTML
        self.maxHTMLBytes = max(256 * 1024, maxHTMLBytes)
        self.maxChunkCharacters = max(600, maxChunkCharacters)
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.maxCrawlDurationSeconds = maxCrawlDurationSeconds.map { max(1, $0) }
        self.userAgent = userAgent
    }

    public static let composerManualSinglePage = WebRAGConfig(
        maxDepth: 0,
        pageLimit: 1
    )

    public static let composerManualLinkedPages = WebRAGConfig(
        maxDepth: 1,
        pageLimit: 25
    )

    public static let composerAutomaticDetectedPages = WebRAGConfig(
        maxDepth: 1,
        pageLimit: 25,
        requestTimeoutSeconds: 5,
        maxCrawlDurationSeconds: 15
    )

    /// Search results already identify the relevant page. Fetch just that
    /// page when the provider returned only a snippet; never fan a search hit
    /// into a 25-page site crawl.
    public static let composerAutomaticResearchPage = WebRAGConfig(
        maxDepth: 0,
        pageLimit: 1,
        requestTimeoutSeconds: 5,
        maxCrawlDurationSeconds: 8
    )
}

public struct WebRAGHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int?
    public let contentType: String?
    public let responseURL: URL?

    public init(
        data: Data,
        statusCode: Int? = nil,
        contentType: String? = nil,
        responseURL: URL? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
        self.responseURL = responseURL
    }
}

enum WebRAGAutomaticNetworkPolicy {
    static func allows(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: false) else {
            return false
        }

        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isPotentiallyPublicHostname(host) else { return false }

        return await Task.detached(priority: .utility) {
            guard let addresses = resolvedAddresses(for: host), addresses.isEmpty == false else {
                return false
            }
            return addresses.allSatisfy(isPublicInternetAddress)
        }.value
    }

    static func isPublicInternetIPAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { raw in
                isPublicIPv4(Array(raw))
            }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { raw in
                isPublicIPv6(Array(raw))
            }
        }
        return false
    }

    private static func isPotentiallyPublicHostname(_ host: String) -> Bool {
        guard host.isEmpty == false else { return false }
        if isPublicInternetIPAddress(host) {
            return true
        }
        if isIPAddress(host) {
            return false
        }
        if host.contains(".") == false {
            return false
        }
        let blockedSuffixes = [
            "localhost", "local", "localdomain", "internal", "intranet",
            "home", "home.arpa", "lan",
        ]
        return blockedSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        } == false
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private static func resolvedAddresses(for host: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let head else {
            return nil
        }
        defer { freeaddrinfo(head) }

        var addresses: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            guard let socketAddress = current.pointee.ai_addr else {
                cursor = current.pointee.ai_next
                continue
            }
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                var address = UnsafeRawPointer(socketAddress)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee.sin_addr
                addresses.append(withUnsafeBytes(of: &address) { Array($0) })
            case AF_INET6:
                var address = UnsafeRawPointer(socketAddress)
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee.sin6_addr
                addresses.append(withUnsafeBytes(of: &address) { Array($0) })
            default:
                break
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    private static func isPublicInternetAddress(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4: isPublicIPv4(bytes)
        case 16: isPublicIPv6(bytes)
        default: false
        }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        switch first {
        case 0, 10, 127:
            return false
        case 100 where (64...127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16...31).contains(second):
            return false
        case 192 where second == 168
            || (second == 0 && (bytes[2] == 0 || bytes[2] == 2))
            || (second == 88 && bytes[2] == 99):
            return false
        case 198 where second == 18 || second == 19 || (second == 51 && bytes[2] == 100):
            return false
        case 203 where second == 0 && bytes[2] == 113:
            return false
        case 224...255:
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] == 0xfc || bytes[0] == 0xfd || bytes[0] == 0xfe || bytes[0] == 0xff {
            return false
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        if bytes[0] == 0x01, bytes[1] == 0x00, bytes.dropFirst(2).prefix(6).allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x01,
           bytes[2] <= 0x01 || (bytes[2] == 0x0d && bytes[3] == 0xb8) {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return false
        }
        if bytes[0] == 0x3f, (bytes[1] & 0xf0) == 0xf0 {
            return false
        }
        return true
    }
}

final class WebRAGNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct WebRAGDocument: Codable, Sendable, Equatable {
    public let startURL: String
    public let crawlTimestamp: Date
    public let pages: [WebRAGPage]
    public let chunks: [WebRAGChunk]

    public var title: String {
        pages.first?.pageTitle ?? URL(string: startURL)?.host ?? startURL
    }

    public init(
        startURL: String,
        crawlTimestamp: Date,
        pages: [WebRAGPage],
        chunks: [WebRAGChunk]
    ) {
        self.startURL = startURL
        self.crawlTimestamp = crawlTimestamp
        self.pages = pages
        self.chunks = chunks
    }
}

public struct WebRAGPage: Codable, Sendable, Equatable {
    public let sourceURL: String
    public let canonicalURL: String
    public let pageTitle: String
    public let crawlDepth: Int
    public let anchorTextFromParent: String?
    public let crawlTimestamp: Date
    public let contentHash: String
    public let markdown: String
    public let cleanedHTML: String?
}

public struct WebRAGChunk: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let markdown: String
    public let metadata: WebRAGChunkMetadata

    public init(
        id: UUID = UUID(),
        markdown: String,
        metadata: WebRAGChunkMetadata
    ) {
        self.id = id
        self.markdown = markdown
        self.metadata = metadata
    }
}

public struct WebRAGChunkMetadata: Codable, Sendable, Equatable {
    public let sourceURL: String
    public let canonicalURL: String
    public let pageTitle: String
    public let headingPath: [String]
    public let crawlDepth: Int
    public let anchorTextFromParent: String?
    public let crawlTimestamp: Date
    public let contentHash: String
    public let chunkIndex: Int
}

public enum WebRAGCrawlerError: LocalizedError, Sendable {
    case invalidURL
    case noPages
    case fetchFailed(String)
    case unsupportedContent(String)
    case httpStatus(Int)
    case emptyContent
    case disallowedURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a web address. Use an http(s) URL."
        case .noPages:
            return "No readable pages were found."
        case .fetchFailed(let message):
            return message
        case .unsupportedContent(let contentType):
            return "That link isn't a web page (\(contentType)). Paste a link to an article or page."
        case .httpStatus(let code):
            return "The site returned HTTP \(code)."
        case .emptyContent:
            return "No readable text was found on that page."
        case .disallowedURL(let url):
            return "That page redirects outside the allowed website (\(url))."
        }
    }
}

public struct WebRAGCrawler: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> WebRAGHTTPResponse
    /// The text of a fetched PDF, or nil when it has none or cannot be read.
    public typealias PDFText = @Sendable (Data) -> String?

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let pdfText: PDFText

    public init(
        fetch: @escaping Fetch = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return WebRAGHTTPResponse(
                data: data,
                statusCode: http?.statusCode,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                responseURL: response.url
            )
        },
        now: @escaping @Sendable () -> Date = Date.init,
        pdfText: @escaping PDFText = Self.extractPDFText
    ) {
        self.fetch = fetch
        self.now = now
        self.pdfText = pdfText
    }

    /// Reads a fetched PDF in the sandboxed PDF parser service, like any
    /// attachment; it is never opened in this process.
    public static let extractPDFText: PDFText = { data in
        AttachmentExtractor.extract(
            data: data,
            mimeType: "application/pdf",
            filename: "document.pdf",
            policy: .full
        )?.text
    }

    static func automaticPublicInternet(
        fetch: @escaping Fetch = Self.fetchAutomaticPublicInternetPage,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> Self {
        Self(
            fetch: { request in
                guard let url = request.url,
                      await WebRAGAutomaticNetworkPolicy.allows(url) else {
                    throw WebRAGCrawlerError.disallowedURL(
                        request.url?.absoluteString ?? "unknown URL"
                    )
                }
                return try await fetch(request)
            },
            now: now
        )
    }

    private static func fetchAutomaticPublicInternetPage(
        _ request: URLRequest
    ) async throws -> WebRAGHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let delegate = WebRAGNoRedirectDelegate()
        let (data, response) = try await session.data(for: request, delegate: delegate)
        let http = response as? HTTPURLResponse
        return WebRAGHTTPResponse(
            data: data,
            statusCode: http?.statusCode,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            responseURL: response.url
        )
    }

    public func crawl(
        input: String,
        config: WebRAGConfig = .composerManualSinglePage
    ) async throws -> WebRAGDocument {
        guard let start = Self.normalizedURL(input) else {
            throw WebRAGCrawlerError.invalidURL
        }

        let crawlTimestamp = now()
        let crawlDeadline = config.maxCrawlDurationSeconds.map {
            crawlTimestamp.addingTimeInterval($0)
        }
        var queue = [PendingURL(url: start, depth: 0, anchorText: nil)]
        var seenURLs = Set<String>()
        var seenCanonicalURLs = Set<String>()
        var seenContentHashes = Set<String>()
        var pages: [WebRAGPage] = []
        var chunks: [WebRAGChunk] = []

        while queue.isEmpty == false && pages.count < config.pageLimit {
            try Task.checkCancellation()
            if let crawlDeadline, now() >= crawlDeadline {
                break
            }
            let pending = queue.removeFirst()
            guard pending.depth <= config.maxDepth else { continue }
            guard Self.isAllowedURL(
                pending.url,
                startURL: start,
                config: config
            ) else { continue }

            let urlKey = Self.normalizedURLString(pending.url)
            guard seenURLs.insert(urlKey).inserted else { continue }

            let parsed: ParsedPage
            do {
                parsed = try await fetchAndParse(
                    pending: pending,
                    startURL: start,
                    crawlTimestamp: crawlTimestamp,
                    config: config
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WebRAGCrawlerError {
                if pending.depth == 0 {
                    throw error
                }
                continue
            } catch {
                if pending.depth == 0 {
                    throw error
                }
                continue
            }

            let canonicalKey = parsed.page.canonicalURL
            guard seenCanonicalURLs.insert(canonicalKey).inserted else { continue }
            guard seenContentHashes.insert(parsed.page.contentHash).inserted else { continue }

            let baseChunkIndex = chunks.count
            chunks.append(contentsOf: parsed.chunks.enumerated().map { offset, chunk in
                var metadata = chunk.metadata
                metadata = WebRAGChunkMetadata(
                    sourceURL: metadata.sourceURL,
                    canonicalURL: metadata.canonicalURL,
                    pageTitle: metadata.pageTitle,
                    headingPath: metadata.headingPath,
                    crawlDepth: metadata.crawlDepth,
                    anchorTextFromParent: metadata.anchorTextFromParent,
                    crawlTimestamp: metadata.crawlTimestamp,
                    contentHash: metadata.contentHash,
                    chunkIndex: baseChunkIndex + offset
                )
                return WebRAGChunk(markdown: chunk.markdown, metadata: metadata)
            })
            pages.append(parsed.page)

            guard pending.depth == 0, config.maxDepth >= 1 else { continue }
            for link in parsed.links {
                guard pages.count + queue.count < config.pageLimit else { break }
                guard Self.isAllowedURL(link.url, startURL: start, config: config) else { continue }
                let normalized = Self.normalizedURLString(link.url)
                guard seenURLs.contains(normalized) == false else { continue }
                queue.append(PendingURL(url: link.url, depth: 1, anchorText: link.anchorText))
            }
        }

        guard pages.isEmpty == false, chunks.isEmpty == false else {
            throw WebRAGCrawlerError.noPages
        }

        return WebRAGDocument(
            startURL: Self.normalizedURLString(start),
            crawlTimestamp: crawlTimestamp,
            pages: pages,
            chunks: chunks
        )
    }

    public static func normalizedURL(_ raw: String, baseURL: URL? = nil) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let rawURL: URL?
        if let baseURL {
            rawURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        } else {
            let lowered = trimmed.lowercased()
            let withScheme = (lowered.hasPrefix("http://") || lowered.hasPrefix("https://"))
                ? trimmed
                : "https://\(trimmed)"
            rawURL = URL(string: withScheme)
        }

        guard let url = rawURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host.isEmpty == false else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        components?.host = host
        components?.fragment = nil

        if let items = components?.queryItems {
            let kept = items.filter { item in
                isTrackingQueryName(item.name) == false
            }
            components?.queryItems = kept.isEmpty ? nil : kept.sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        }

        guard let normalized = components?.url else { return nil }
        return normalized.standardized
    }

    public static func normalizedURLString(_ url: URL) -> String {
        guard let normalized = normalizedURL(url.absoluteString) else {
            return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]>\n\t "))
        }
        return normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]>\n\t "))
    }

    public static func isLowValueURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { $0.name.lowercased() })
        let lowValueSegments = [
            "login", "signin", "sign-in", "signup", "sign-up", "auth",
            "search", "tag", "tags", "archive", "archives", "feed", "feeds",
            "rss", "atom", "pagination", "wp-login"
        ]
        let pathSegments = path.split(separator: "/").map(String.init)
        if pathSegments.contains(where: { lowValueSegments.contains($0) }) {
            return true
        }
        if isPaginationPath(pathSegments) {
            return true
        }
        if path.hasSuffix(".rss") || path.hasSuffix(".xml") || path.hasSuffix(".atom") {
            return true
        }
        if queryNames.contains("q")
            || queryNames.contains("s")
            || queryNames.contains("search")
            || queryNames.contains("paged") {
            return true
        }
        return false
    }

    // MARK: - Fetch + parse

    private func fetchAndParse(
        pending: PendingURL,
        startURL: URL,
        crawlTimestamp: Date,
        config: WebRAGConfig
    ) async throws -> ParsedPage {
        var request = URLRequest(url: pending.url, timeoutInterval: config.requestTimeoutSeconds)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")

        let response: WebRAGHTTPResponse
        do {
            response = try await fetch(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw WebRAGCrawlerError.fetchFailed(error.localizedDescription)
        }

        if let statusCode = response.statusCode, !(200..<400).contains(statusCode) {
            throw WebRAGCrawlerError.httpStatus(statusCode)
        }
        let finalURL = Self.normalizedURL(
            response.responseURL?.absoluteString ?? pending.url.absoluteString
        ) ?? pending.url
        guard Self.isAllowedURL(finalURL, startURL: startURL, config: config) else {
            throw WebRAGCrawlerError.disallowedURL(Self.normalizedURLString(finalURL))
        }
        // Drive downloads may use application/octet-stream. Recognize the
        // actual PDF signature, and never try to parse truncated PDF bytes.
        if response.contentType?.lowercased().contains("application/pdf") == true
            || response.data.starts(with: Data("%PDF-".utf8)) {
            guard response.data.count <= config.maxHTMLBytes else {
                throw WebRAGCrawlerError.unsupportedContent("PDF exceeds the document size limit")
            }
            guard let text = pdfText(response.data)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { throw WebRAGCrawlerError.emptyContent }
            try Task.checkCancellation()
            let title = pending.anchorText ?? finalURL.lastPathComponent
            let page = WebRAGPage(sourceURL: Self.normalizedURLString(finalURL),
                canonicalURL: Self.normalizedURLString(finalURL), pageTitle: title,
                crawlDepth: pending.depth, anchorTextFromParent: pending.anchorText,
                crawlTimestamp: crawlTimestamp, contentHash: Self.sha256(text), markdown: text, cleanedHTML: nil)
            return ParsedPage(page: page, chunks: chunksFromSections(
                [MarkdownSection(headingPath: [title], markdown: text)], page: page, config: config), links: [])
        }
        if let contentType = response.contentType?.lowercased(),
           contentType.isEmpty == false,
           !(contentType.contains("html") || contentType.contains("xml") || contentType.hasPrefix("text/")) {
            let label = contentType.split(separator: ";").first.map(String.init) ?? contentType
            throw WebRAGCrawlerError.unsupportedContent(label)
        }

        let boundedData = Data(response.data.prefix(config.maxHTMLBytes))
        let html = String(data: boundedData, encoding: .utf8)
            ?? String(data: boundedData, encoding: .isoLatin1)
            ?? ""
        guard html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw WebRAGCrawlerError.emptyContent
        }

        let document = try SwiftSoup.parse(html, finalURL.absoluteString)
        let canonicalURL = Self.canonicalURL(
            in: document,
            fallback: finalURL,
            startURL: startURL,
            config: config
        )
        let discoveredLinks = pending.depth == 0
            ? try linksFromDocument(document, baseURL: finalURL)
            : []
        try clean(document)
        let contentElement = try selectedContentElement(in: document, config: config)
        let cleanedHTML = config.preserveCleanedHTML ? try contentElement.html() : nil
        let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        let pageTitle = title.isEmpty ? (canonicalURL.host ?? finalURL.host ?? finalURL.absoluteString) : title
        let sections = try markdownSections(from: contentElement, pageTitle: pageTitle)
        let markdown = sections.map(\.markdown).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard markdown.isEmpty == false else {
            throw WebRAGCrawlerError.emptyContent
        }

        let contentHash = Self.sha256(markdown)
        let page = WebRAGPage(
            sourceURL: Self.normalizedURLString(finalURL),
            canonicalURL: Self.normalizedURLString(canonicalURL),
            pageTitle: pageTitle,
            crawlDepth: pending.depth,
            anchorTextFromParent: pending.anchorText,
            crawlTimestamp: crawlTimestamp,
            contentHash: contentHash,
            markdown: markdown,
            cleanedHTML: cleanedHTML
        )
        let chunks = chunksFromSections(
            sections,
            page: page,
            config: config
        )
        guard chunks.isEmpty == false else {
            throw WebRAGCrawlerError.emptyContent
        }
        return ParsedPage(page: page, chunks: chunks, links: discoveredLinks)
    }

    private static func canonicalURL(
        in document: Document,
        fallback: URL,
        startURL: URL,
        config: WebRAGConfig
    ) -> URL {
        if let link = try? document.select("link[rel~=(?i)canonical]").first(),
           let href = try? link.attr("href"),
           let normalized = normalizedURL(href, baseURL: fallback) {
            guard isAllowedURL(normalized, startURL: startURL, config: config) else {
                return fallback
            }
            return normalized
        }
        return fallback
    }

    private func clean(_ document: Document) throws {
        let selectors = [
            "script", "style", "noscript", "template", "svg", "canvas", "iframe",
            "form", "nav", "header", "footer", "aside",
            "[role=navigation]", "[role=banner]", "[role=contentinfo]", "[role=complementary]",
            "[aria-label*=cookie]", "[id*=cookie]", "[class*=cookie]",
            "[id*=consent]", "[class*=consent]",
            "[id*=advert]", "[class*=advert]", "[id*=ad-]", "[class*=ad-]",
            "[id*=promo]", "[class*=promo]", "[id*=sidebar]", "[class*=sidebar]",
            "[id*=newsletter]", "[class*=newsletter]", "[id*=subscribe]", "[class*=subscribe]",
            "[class*=breadcrumb]", "[id*=breadcrumb]"
        ]
        for selector in selectors {
            for element in try document.select(selector).array() {
                try element.remove()
            }
        }
    }

    private func selectedContentElement(
        in document: Document,
        config: WebRAGConfig
    ) throws -> Element {
        if config.useReadabilityExtraction {
            for selector in ["article", "main", "[role=main]", "#content", ".content", ".post", ".entry-content"] {
                if let candidate = try document.select(selector).array()
                    .max(by: { lhs, rhs in
                        ((try? lhs.text().count) ?? 0) < ((try? rhs.text().count) ?? 0)
                    }),
                   ((try? candidate.text().count) ?? 0) >= 200 {
                    return candidate
                }
            }
        }
        guard let body = document.body() else {
            throw WebRAGCrawlerError.emptyContent
        }
        return body
    }

    private func linksFromDocument(_ document: Document, baseURL: URL) throws -> [DiscoveredLink] {
        var seen = Set<String>()
        var links: [DiscoveredLink] = []
        // Public Drive folder entries are data-id elements, not anchors.
        // Only PDF entries become document reads; do not crawl arbitrary UI actions.
        if baseURL.host?.lowercased() == "drive.google.com", baseURL.path.contains("/folders/") {
            for item in try document.select("[data-id][data-tooltip]").array() {
                let title = try item.attr("data-tooltip")
                let id = try item.attr("data-id")
                guard title.lowercased().contains(".pdf"), !id.isEmpty,
                      id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                          || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                      let url = URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download"),
                      seen.insert(Self.normalizedURLString(url)).inserted else { continue }
                links.append(DiscoveredLink(url: url, anchorText: title))
            }
        }
        for element in try document.select("a[href]").array() {
            let rawHref = try element.attr("href")
            guard let url = Self.normalizedURL(rawHref, baseURL: baseURL) else { continue }
            let anchor = try element.text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalizedURLString(url)
            guard seen.insert(key).inserted else { continue }
            guard anchor.isEmpty == false || isMeaningfulPath(url) else { continue }
            links.append(DiscoveredLink(url: url, anchorText: anchor.isEmpty ? nil : anchor))
        }
        return links
    }

    private static func isAllowedURL(
        _ url: URL,
        startURL: URL,
        config: WebRAGConfig
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if config.excludeLowValuePages && isLowValueURL(url) {
            return false
        }
        if config.sameDomainOnly {
            let driveDocumentDownload = normalizedHost(startURL) == "drive.google.com"
                && normalizedHost(url) == "drive.usercontent.google.com"
                && url.scheme == "https" && url.path == "/download"
            guard normalizedHost(url) == normalizedHost(startURL) || driveDocumentDownload else { return false }
        }
        if config.allowedPathPrefixes.isEmpty == false {
            let path = url.path.isEmpty ? "/" : url.path
            guard config.allowedPathPrefixes.contains(where: { prefix in
                path.hasPrefix(prefix)
            }) else { return false }
        }
        return true
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), host.isEmpty == false else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    private static func isTrackingQueryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_")
            || ["fbclid", "gclid", "dclid", "mc_cid", "mc_eid", "igshid", "ref", "ref_src"].contains(lower)
    }

    private static func isPaginationPath(_ pathSegments: [String]) -> Bool {
        for (index, segment) in pathSegments.enumerated() where segment == "page" {
            let nextIndex = index + 1
            guard nextIndex < pathSegments.count else { continue }
            if Int(pathSegments[nextIndex]) != nil {
                return true
            }
        }
        return false
    }

    private func isMeaningfulPath(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/")
        return components.isEmpty == false
    }

    // MARK: - Markdown

    private func markdownSections(
        from root: Element,
        pageTitle: String
    ) throws -> [MarkdownSection] {
        let blocks = try root.select("h1,h2,h3,h4,h5,h6,p,pre,blockquote,table,ul,ol").array()
        var sections: [MarkdownSection] = []
        var currentHeadingPath: [String] = pageTitle.isEmpty ? [] : [pageTitle]
        var currentLines: [String] = []

        func flush() {
            let markdown = currentLines.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard markdown.isEmpty == false else { return }
            sections.append(MarkdownSection(
                headingPath: currentHeadingPath,
                markdown: markdown
            ))
            currentLines.removeAll()
        }

        for block in blocks {
            let tag = block.tagName().lowercased()
            if let level = headingLevel(tag) {
                let heading = try block.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard heading.isEmpty == false else { continue }
                flush()
                let rootTitle = pageTitle.isEmpty ? [] : [pageTitle]
                var path = currentHeadingPath
                if path.isEmpty { path = rootTitle }
                let pathBase = rootTitle.isEmpty ? [] : rootTitle
                let retainedCount = max(pathBase.count, min(path.count, pathBase.count + max(0, level - 1)))
                path = Array(path.prefix(retainedCount))
                path.append(heading)
                currentHeadingPath = path
                currentLines.append(String(repeating: "#", count: level) + " " + heading)
                continue
            }

            let markdown = try markdown(for: block, tag: tag)
            if markdown.isEmpty == false {
                currentLines.append(markdown)
            }
        }

        flush()
        if sections.isEmpty {
            let text = (try? root.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty == false {
                sections.append(MarkdownSection(
                    headingPath: currentHeadingPath,
                    markdown: text
                ))
            }
        }
        return sections
    }

    private func chunksFromSections(
        _ sections: [MarkdownSection],
        page: WebRAGPage,
        config: WebRAGConfig
    ) -> [WebRAGChunk] {
        var chunks: [WebRAGChunk] = []
        for section in sections {
            let split = splitMarkdown(section.markdown, limit: config.maxChunkCharacters)
            for piece in split {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { continue }
                let metadata = WebRAGChunkMetadata(
                    sourceURL: page.sourceURL,
                    canonicalURL: page.canonicalURL,
                    pageTitle: page.pageTitle,
                    headingPath: section.headingPath,
                    crawlDepth: page.crawlDepth,
                    anchorTextFromParent: page.anchorTextFromParent,
                    crawlTimestamp: page.crawlTimestamp,
                    contentHash: page.contentHash,
                    chunkIndex: chunks.count
                )
                chunks.append(WebRAGChunk(markdown: trimmed, metadata: metadata))
            }
        }
        return chunks
    }

    private func markdown(for element: Element, tag: String) throws -> String {
        switch tag {
        case "p":
            return try inlineMarkdown(for: element)
        case "pre":
            let text = preformattedText(for: element)
                .trimmingCharacters(in: .newlines)
            return text.isEmpty ? "" : "```\n\(text)\n```"
        case "blockquote":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return "" }
            return text.components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
        case "ul", "ol":
            return try listMarkdown(for: element, ordered: tag == "ol")
        case "table":
            return try tableMarkdown(for: element)
        default:
            return try inlineMarkdown(for: element)
        }
    }

    private func inlineMarkdown(for element: Element) throws -> String {
        var text = try element.text()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "" }

        var links: [String] = []
        for link in try element.select("a[href]").array() {
            let label = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let href = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.isEmpty == false, href.isEmpty == false else { continue }
            guard text.contains("[\(label)](") == false else { continue }
            links.append("[\(label)](\(href))")
        }
        if links.isEmpty == false {
            text += "\n\nLinks: " + links.joined(separator: ", ")
        }
        return text
    }

    private func listMarkdown(for element: Element, ordered: Bool) throws -> String {
        var lines: [String] = []
        for (index, item) in try element.select("> li").array().enumerated() {
            let text = try item.text()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }
            let marker = ordered ? "\(index + 1)." : "-"
            lines.append("\(marker) \(text)")
        }
        return lines.joined(separator: "\n")
    }

    private func tableMarkdown(for element: Element) throws -> String {
        let rows = try element.select("tr").array()
        var table: [[String]] = []
        for row in rows {
            let cells = try row.select("th,td").array().map { cell in
                try cell.text()
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            if cells.isEmpty == false {
                table.append(cells)
            }
        }
        guard table.isEmpty == false else { return "" }
        let columnCount = table.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }
        let normalized = table.map { row in
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
        let header = normalized[0]
        var lines = [
            "| " + header.joined(separator: " | ") + " |",
            "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        ]
        for row in normalized.dropFirst() {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private func preformattedText(for element: Element) -> String {
        var pieces: [String] = []
        collectWholeText(from: element, into: &pieces)
        return pieces.joined()
    }

    private func collectWholeText(from node: Node, into pieces: inout [String]) {
        if let textNode = node as? TextNode {
            pieces.append(textNode.getWholeText())
            return
        }
        if let dataNode = node as? DataNode {
            pieces.append(dataNode.getWholeData())
            return
        }
        for child in node.getChildNodes() {
            collectWholeText(from: child, into: &pieces)
        }
    }

    private func splitMarkdown(_ markdown: String, limit: Int) -> [String] {
        guard markdown.count > limit else { return [markdown] }
        let paragraphs = markdown.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            for piece in splitOversizedMarkdownBlock(paragraph, limit: limit) {
                let candidate = current.isEmpty ? piece : current + "\n\n" + piece
                if candidate.count <= limit {
                    current = candidate
                } else {
                    if current.isEmpty == false {
                        chunks.append(current)
                    }
                    current = piece
                }
            }
        }
        if current.isEmpty == false {
            chunks.append(current)
        }
        return chunks
    }

    private func splitOversizedMarkdownBlock(_ block: String, limit: Int) -> [String] {
        guard block.count > limit else { return [block] }
        var pieces: [String] = []
        var remaining = block[...]
        while remaining.count > limit {
            let target = remaining.index(remaining.startIndex, offsetBy: limit)
            var split = remaining[..<target].lastIndex(where: { $0.isWhitespace }) ?? target
            if split == remaining.startIndex {
                split = target
            }

            let piece = String(remaining[..<split])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty == false {
                pieces.append(piece)
            }

            remaining = remaining[split...]
            while let first = remaining.first, first.isWhitespace {
                remaining = remaining.dropFirst()
            }
        }

        let final = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty == false {
            pieces.append(final)
        }
        return pieces
    }

    private func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.first == "h", let value = Int(String(tag.suffix(1))) else {
            return nil
        }
        return min(max(value, 1), 6)
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension WebRAGDocument {
    static let composerPromptSnippetCharacterLimit = 8_400

    func composerSourceSnippet(
        characterLimit: Int = WebRAGDocument.composerPromptSnippetCharacterLimit,
        anchorTerms: [String] = []
    ) -> String {
        let terms = AskMemoryTokenizer.tokenize(anchorTerms.joined(separator: " "), maxTokens: 256)
        let ranked = terms.isEmpty ? chunks : chunks.sorted { left, right in
            let lhs = AskMemoryTokenizer.tokenize(left.markdown, maxTokens: 512).intersection(terms).count
            let rhs = AskMemoryTokenizer.tokenize(right.markdown, maxTokens: 512).intersection(terms).count
            return lhs == rhs ? left.metadata.chunkIndex < right.metadata.chunkIndex : lhs > rhs
        }
        var requiredChunkIndexes = Set<Int>()
        var requiredChunks: [WebRAGChunk] = []

        for page in pages {
            guard let chunk = ranked.first(where: { $0.metadata.sourceURL == page.sourceURL }) else {
                continue
            }
            requiredChunks.append(chunk)
            requiredChunkIndexes.insert(chunk.metadata.chunkIndex)
        }

        let selected = requiredChunks + ranked.filter {
            requiredChunkIndexes.contains($0.metadata.chunkIndex) == false
        }

        var blocks: [String] = []
        var used = 0
        let separator = "\n\n---\n\n"

        let requiredSeparatorBudget = max(0, requiredChunks.count - 1) * separator.count
        let requiredCharacterBudget = max(1, characterLimit - requiredSeparatorBudget)
        let fairRequiredLimit = max(1, requiredCharacterBudget / max(1, requiredChunks.count))

        for chunk in selected {
            let separatorCount = blocks.isEmpty ? 0 : separator.count
            let remaining = characterLimit - used - separatorCount
            guard remaining > 0 else { break }
            let blockLimit = requiredChunkIndexes.contains(chunk.metadata.chunkIndex)
                ? min(remaining, fairRequiredLimit)
                : remaining
            guard let block = Self.snippetBlock(for: chunk, limit: blockLimit)
                ?? Self.snippetBlock(for: chunk, limit: remaining) else { break }
            blocks.append(block)
            used += separatorCount + block.count
        }
        return blocks.joined(separator: separator)
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func snippetBlock(for chunk: WebRAGChunk, limit: Int) -> String? {
        let metadata = chunk.metadata
        let heading = metadata.headingPath.isEmpty
            ? "(root)"
            : metadata.headingPath.joined(separator: " > ")
        let anchor = metadata.anchorTextFromParent.map { "\nanchor_text_from_parent: \($0)" } ?? ""
        let prefix = """
        source_url: \(metadata.sourceURL)
        canonical_url: \(metadata.canonicalURL)
        page_title: \(metadata.pageTitle)
        heading_path: \(heading)
        crawl_depth: \(metadata.crawlDepth)\(anchor)
        crawl_timestamp: \(timestampString(metadata.crawlTimestamp))
        content_hash: \(metadata.contentHash)
        chunk_index: \(metadata.chunkIndex)

        """
        guard limit > prefix.count else { return nil }
        let remainingMarkdown = limit - prefix.count
        let markdown = String(chunk.markdown.prefix(remainingMarkdown))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard markdown.isEmpty == false else { return nil }
        return prefix + markdown
    }
}

public extension ComposerSource {
    static func website(
        from document: WebRAGDocument,
        isUserAdded: Bool
    ) -> ComposerSource {
        ComposerSource(
            kind: .website,
            label: document.title,
            snippet: document.composerSourceSnippet(),
            filePath: document.startURL,
            isUserAdded: isUserAdded
        )
    }
}

enum WebRAGComposerSourceExpander {
    static func expandAutomaticWebsiteSources(
        _ sources: [ComposerSource],
        config: WebRAGConfig = .composerAutomaticDetectedPages,
        crawler: WebRAGCrawler = .automaticPublicInternet(),
        anchorTerms: [String] = []
    ) async throws -> [ComposerSource] {
        let unexpandedAutomaticWebsiteIndexes: Set<Int> = Set(
            sources.enumerated().compactMap { index, source -> Int? in
                guard source.kind == .website,
                      source.isUserAdded == false,
                      source.provenance?.webContentExtracted != true else {
                    return nil
                }
                return index
            }
        )
        guard unexpandedAutomaticWebsiteIndexes.isEmpty == false else { return sources }

        let candidates = sources.enumerated().filter { index, source in
            unexpandedAutomaticWebsiteIndexes.contains(index)
                && crawlInput(for: source) != nil
        }
        guard candidates.isEmpty == false else {
            return sources.enumerated().compactMap { index, source in
                unexpandedAutomaticWebsiteIndexes.contains(index) ? nil : source
            }
        }

        var expandedByIndex: [Int: ComposerSource] = [:]
        try await withThrowingTaskGroup(of: (Int, ComposerSource?).self) { group in
            for (index, source) in candidates {
                guard let input = crawlInput(for: source) else { continue }
                group.addTask {
                    do {
                        let sourceConfig = source.provenance == nil
                            ? config
                            : WebRAGConfig.composerAutomaticResearchPage
                        let document = try await crawler.crawl(input: input, config: sourceConfig)
                        return (index, source.expandedWithWebRAGDocument(document, fallbackURL: input, anchorTerms: anchorTerms))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, nil)
                    }
                }
            }

            for try await (index, source) in group {
                if let source {
                    expandedByIndex[index] = source
                }
            }
        }

        return sources.enumerated().compactMap { index, source in
            guard unexpandedAutomaticWebsiteIndexes.contains(index) else {
                return source
            }
            return expandedByIndex[index]
        }
    }

    private static func crawlInput(for source: ComposerSource) -> String? {
        if let filePath = source.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           filePath.isEmpty == false {
            return filePath
        }
        for line in source.snippet.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("URL:") else { continue }
            let url = trimmed.dropFirst("URL:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : url
        }
        return nil
    }
}

private extension ComposerSource {
    func expandedWithWebRAGDocument(_ document: WebRAGDocument, fallbackURL: String, anchorTerms: [String]) -> ComposerSource {
        let crawled = ComposerSource.website(from: document, isUserAdded: false)
        let extractedProvenance = provenance.map { value in
            ComposerSourceProvenance(
                provider: value.provider,
                toolName: value.toolName,
                researchQuestion: value.researchQuestion,
                query: value.query,
                sourceURL: value.sourceURL ?? crawled.filePath ?? fallbackURL,
                retrievedAt: value.retrievedAt,
                publishedAt: value.publishedAt,
                webContentExtracted: true
            )
        } ?? ComposerSourceProvenance(
            provider: "WebRAG",
            toolName: "crawl",
            researchQuestion: "Extract the webpage linked by the incoming message.",
            query: fallbackURL,
            sourceURL: crawled.filePath ?? fallbackURL,
            retrievedAt: document.crawlTimestamp,
            webContentExtracted: true
        )
        return ComposerSource(
            id: id,
            kind: .website,
            label: crawled.label,
            snippet: document.composerSourceSnippet(anchorTerms: anchorTerms),
            messageID: messageID,
            filePath: crawled.filePath ?? fallbackURL,
            isUserAdded: false,
            addedAt: addedAt,
            provenance: extractedProvenance
        )
    }
}

private struct PendingURL {
    let url: URL
    let depth: Int
    let anchorText: String?
}

private struct DiscoveredLink {
    let url: URL
    let anchorText: String?
}

private struct ParsedPage {
    let page: WebRAGPage
    let chunks: [WebRAGChunk]
    let links: [DiscoveredLink]
}

private struct MarkdownSection {
    let headingPath: [String]
    let markdown: String
}
