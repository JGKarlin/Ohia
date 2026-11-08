import AppKit
import Foundation
import OhiaCore
import SwiftData
import SwiftUI
import WebKit

nonisolated enum FocusedEmailPrintLens: String, Sendable, Equatable {
    case frontPage
    case meaning
    case people
    case timeline
    case projects
}

nonisolated enum FocusedEmailPrintScope: Sendable, Equatable {
    case message
    case thread
}

nonisolated struct FocusedEmailPrintSelection: Sendable, Equatable {
    let lens: FocusedEmailPrintLens
    let anchorMessageID: UUID
    let scope: FocusedEmailPrintScope
    let contextTitle: String?
}

enum FocusedEmailPrintSelectionPolicy {
    nonisolated static func resolve(
        activeFrame: FrameKey,
        metalMessageID: UUID?,
        peopleSelectedMessageID: UUID?,
        frontPageMessageID: UUID?,
        timelineMessageID: UUID?,
        projectsMessageID: UUID?,
        projectsDeadlineMessageID: UUID?,
        projectsContextTitle: String?
    ) -> FocusedEmailPrintSelection? {
        switch activeFrame.spatialLens {
        case .frontPage:
            return frontPageMessageID.map {
                FocusedEmailPrintSelection(
                    lens: .frontPage,
                    anchorMessageID: $0,
                    scope: .thread,
                    contextTitle: nil
                )
            }
        case .meaning:
            return metalMessageID.map {
                FocusedEmailPrintSelection(
                    lens: .meaning,
                    anchorMessageID: $0,
                    scope: .message,
                    contextTitle: nil
                )
            }
        case .people:
            return peopleSelectedMessageID.map {
                FocusedEmailPrintSelection(
                    lens: .people,
                    anchorMessageID: $0,
                    scope: .message,
                    contextTitle: nil
                )
            }
        case .timeline:
            return timelineMessageID.map {
                FocusedEmailPrintSelection(
                    lens: .timeline,
                    anchorMessageID: $0,
                    scope: .message,
                    contextTitle: nil
                )
            }
        case .projects:
            if let projectsDeadlineMessageID {
                return FocusedEmailPrintSelection(
                    lens: .projects,
                    anchorMessageID: projectsDeadlineMessageID,
                    scope: .thread,
                    contextTitle: projectsContextTitle
                )
            }
            return projectsMessageID.map {
                FocusedEmailPrintSelection(
                    lens: .projects,
                    anchorMessageID: $0,
                    scope: .message,
                    contextTitle: projectsContextTitle
                )
            }
        default:
            return nil
        }
    }
}

nonisolated struct FocusedEmailPrintAddress: Sendable, Equatable {
    let name: String?
    let address: String

    nonisolated var displayText: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? address : "\(trimmedName) <\(address)>"
    }
}

nonisolated enum FocusedEmailPrintBody: Sendable, Equatable {
    case plainText(String)
    case html(String, loadsRemoteImages: Bool)
    case unavailable
}

nonisolated struct FocusedEmailPrintMessage: Sendable, Equatable {
    let id: UUID
    let subject: String
    let date: Date
    let from: FocusedEmailPrintAddress
    let to: [FocusedEmailPrintAddress]
    let cc: [FocusedEmailPrintAddress]
    let bcc: [FocusedEmailPrintAddress]
    let body: FocusedEmailPrintBody
}

nonisolated struct FocusedEmailPrintDocument: Sendable, Equatable {
    let lens: FocusedEmailPrintLens
    let title: String
    let contextTitle: String?
    let messages: [FocusedEmailPrintMessage]
}

enum FocusedEmailPrintHTMLRenderer {
    /// Remote content stays blocked inside WebKit unless every HTML body in
    /// the print job comes from a sender the user trusts.
    static func blocksRemoteContent(_ document: FocusedEmailPrintDocument) -> Bool {
        document.messages.contains { message in
            if case .html(_, let loadsRemoteImages) = message.body {
                return !loadsRemoteImages
            }
            return false
        }
    }

    static func render(_ document: FocusedEmailPrintDocument) -> String {
        var renderedMessages: [String] = []
        for message in document.messages {
            renderedMessages.append(messageHTML(message))
        }
        let messages = renderedMessages.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(document.title))</title>
          <style>\(stylesheet)</style>
        </head>
        <body data-lens="\(document.lens.rawValue)">
          <main class="print-document">
            \(mastheadHTML(for: document))
            <section class="message-stack">
              \(messages)
            </section>
          </main>
        </body>
        </html>
        """
    }

    private static func mastheadHTML(for document: FocusedEmailPrintDocument) -> String {
        let marker: String
        let eyebrow: String
        switch document.lens {
        case .frontPage:
            marker = "THE FRONT PAGE"
            eyebrow = "Focused thread"
        case .meaning:
            marker = "MEANING DOSSIER"
            eyebrow = "Focused email"
        case .people:
            marker = "CORRESPONDENT RING"
            eyebrow = "Selected ring email"
        case .timeline:
            marker = "TIMELINE PLAYHEAD"
            eyebrow = "Focused moment"
        case .projects:
            marker = "PROJECT DOSSIER"
            eyebrow = document.messages.count > 1 ? "Deadline thread" : "Focused project email"
        }
        let context = document.contextTitle.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "<p class=\"context-title\">\(escape(trimmed))</p>"
        } ?? ""
        return """
        <header class="document-header">
          <div class="lens-mark" aria-hidden="true"></div>
          <p class="lens-title">\(marker)</p>
          <p class="eyebrow">\(eyebrow)</p>
          <h1>\(escape(document.title))</h1>
          \(context)
          <p class="document-count">\(document.messages.count) \(document.messages.count == 1 ? "email" : "emails")</p>
        </header>
        """
    }

    private static func messageHTML(_ message: FocusedEmailPrintMessage) -> String {
        var headers: [(String, String)] = [
            ("From", addressList([message.from])),
            ("To", addressList(message.to))
        ]
        if message.cc.isEmpty == false {
            headers.append(("Cc", addressList(message.cc)))
        }
        if message.bcc.isEmpty == false {
            headers.append(("Bcc", addressList(message.bcc)))
        }
        headers.append(contentsOf: [
            ("Subject", escape(message.subject)),
            ("Date", escape(dateFormatter.string(from: message.date)))
        ])
        let headerHTML = headers.map { label, value in
            "<dt>\(label)</dt><dd>\(value)</dd>"
        }.joined(separator: "\n")

        return """
        <article class="email-message">
          <div class="message-node" aria-hidden="true"></div>
          <dl class="email-headers">
            \(headerHTML)
          </dl>
          <div class="email-body">\(bodyHTML(message.body))</div>
        </article>
        """
    }

    private static func addressList(_ addresses: [FocusedEmailPrintAddress]) -> String {
        addresses.isEmpty
            ? "<span class=\"empty-header\">None</span>"
            : addresses.map { escape($0.displayText) }.joined(separator: ", ")
    }

    private static func bodyHTML(_ body: FocusedEmailPrintBody) -> String {
        switch body {
        case .plainText(let text):
            return "<div class=\"plain-body\">\(escape(text))</div>"
        case .html(let html, let loadsRemoteImages):
            let privateHTML = loadsRemoteImages
                ? RemoteImageBlocking.upgradingInsecureImageURLs(in: html)
                : RemoteImageBlocking.block(in: html, placeholderHex: "E8E3D5").html
            return "<div class=\"sender-html\">\(safeHTMLFragment(privateHTML))</div>"
        case .unavailable:
            return "<p class=\"unavailable-body\">The email body could not be loaded.</p>"
        }
    }

    private static func safeHTMLFragment(_ html: String) -> String {
        var result = html
        for pattern in [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<iframe\b[^>]*>.*?</iframe>"#,
            #"(?is)<object\b[^>]*>.*?</object>"#,
            #"(?is)<embed\b[^>]*>"#,
            #"(?is)<form\b[^>]*>.*?</form>"#,
            #"(?is)<video\b[^>]*>.*?</video>"#,
            #"(?is)<audio\b[^>]*>.*?</audio>"#,
            #"(?is)</?(?:video|audio)\b[^>]*>"#,
            #"(?is)<(?:source|track|meta|link|base)\b[^>]*>"#
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        if let regex = try? NSRegularExpression(pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#),
           let match = regex.firstMatch(
               in: result,
               range: NSRange(result.startIndex..<result.endIndex, in: result)
           ),
           match.numberOfRanges > 1,
           let bodyRange = Range(match.range(at: 1), in: result) {
            return String(result[bodyRange])
        }
        return result
            .replacingOccurrences(
                of: #"(?is)<!doctype[^>]*>|</?html\b[^>]*>|<head\b[^>]*>.*?</head>|</?body\b[^>]*>"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private static let stylesheet = """
    @page { margin: 0.56in; }
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: #fff; color: #171a17; }
    body { --accent: #397552; --accent-soft: #eaf1eb; --ink-soft: #5c665f; --line: #cfd7d0; }
    .print-document { max-width: 8.1in; margin: 0 auto; }
    .document-header { position: relative; padding: 0 0 18pt; border-bottom: 2pt solid var(--accent); break-after: avoid; }
    .lens-title, .eyebrow, .document-count, .context-title { margin: 0; }
    .lens-title { color: var(--accent); font-size: 10pt; font-weight: 800; letter-spacing: .14em; }
    .eyebrow { margin-top: 4pt; color: var(--ink-soft); font-size: 8.5pt; letter-spacing: .08em; text-transform: uppercase; }
    h1 { margin: 8pt 0 0; font: 700 25pt/1.08 Georgia, "Times New Roman", serif; }
    .context-title { margin-top: 7pt; color: var(--accent); font: 600 11pt/1.3 -apple-system, sans-serif; }
    .document-count { position: absolute; right: 0; top: 0; color: var(--ink-soft); font-size: 8.5pt; }
    .message-stack { margin-top: 18pt; }
    .email-message { position: relative; margin: 0 0 20pt; padding: 14pt 15pt 16pt; border: .75pt solid var(--line); border-radius: 8pt; break-inside: auto; }
    .email-message + .email-message { break-before: auto; }
    .email-headers { display: grid; grid-template-columns: 54pt 1fr; gap: 3pt 9pt; margin: 0 0 14pt; padding: 0 0 11pt; border-bottom: .6pt solid var(--line); font-size: 9pt; line-height: 1.35; break-inside: avoid; }
    .email-headers dt { color: var(--ink-soft); font-weight: 700; }
    .email-headers dd { margin: 0; overflow-wrap: anywhere; }
    .empty-header { color: #8b938e; font-style: italic; }
    .email-body { font: 10.5pt/1.52 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; overflow-wrap: anywhere; }
    .plain-body { white-space: pre-wrap; }
    .sender-html img { max-width: 100% !important; height: auto; }
    .sender-html table { max-width: 100% !important; border-collapse: collapse; }
    .sender-html pre { white-space: pre-wrap; }
    .unavailable-body { color: var(--ink-soft); font-style: italic; }
    .message-node { display: none; }
    body[data-lens="frontPage"] { --accent: #1f3f2c; --accent-soft: #edf1ec; }
    body[data-lens="frontPage"] .document-header { text-align: center; border-top: 4pt double var(--accent); border-bottom: 4pt double var(--accent); padding-top: 10pt; }
    body[data-lens="frontPage"] .lens-title { font: 700 15pt/1 Georgia, serif; letter-spacing: .18em; }
    body[data-lens="frontPage"] .eyebrow { font-family: Georgia, serif; }
    body[data-lens="frontPage"] .email-message { border-width: 0 0 .75pt; border-radius: 0; padding-left: 0; padding-right: 0; }
    body[data-lens="meaning"] { --accent: #426f56; --accent-soft: #ebf2ed; }
    body[data-lens="meaning"] .document-header { padding-left: 24pt; }
    body[data-lens="meaning"] .lens-mark { position: absolute; left: 0; top: 1pt; width: 13pt; height: 13pt; border: 1.5pt solid var(--accent); border-radius: 50%; box-shadow: 10pt 9pt 0 -5pt var(--accent), 2pt 22pt 0 -4pt var(--accent); }
    body[data-lens="meaning"] .email-message { background: linear-gradient(135deg, var(--accent-soft), #fff 42%); }
    body[data-lens="people"] { --accent: #7f5730; --accent-soft: #f4eee6; }
    body[data-lens="people"] .document-header { padding-left: 39pt; }
    body[data-lens="people"] .lens-mark { position: absolute; left: 0; top: 1pt; width: 29pt; height: 29pt; border: 1.2pt solid var(--accent); border-radius: 50%; box-shadow: inset 0 0 0 6pt #fff, inset 0 0 0 7.2pt var(--accent); }
    body[data-lens="people"] .email-message { border-left: 4pt solid var(--accent); }
    body[data-lens="timeline"] { --accent: #9b7016; --accent-soft: #f8f2df; }
    body[data-lens="timeline"] .message-stack { padding-left: 22pt; border-left: 1.5pt solid var(--accent); }
    body[data-lens="timeline"] .message-node { display: block; position: absolute; left: -29.1pt; top: 19pt; width: 11pt; height: 11pt; background: #fff; border: 2pt solid var(--accent); border-radius: 50%; }
    body[data-lens="timeline"] .email-message { background: linear-gradient(90deg, var(--accent-soft), #fff 24%); }
    body[data-lens="projects"] { --accent: #355e78; --accent-soft: #e9f0f4; }
    body[data-lens="projects"] .document-header { margin-top: 8pt; padding: 14pt 16pt 18pt; border: 1pt solid var(--accent); border-top-width: 5pt; background: var(--accent-soft); }
    body[data-lens="projects"] .email-message { border-radius: 2pt; border-left: 5pt solid var(--accent); }
    @media print { a { color: inherit; text-decoration: underline; } }
    """
}

enum FocusedEmailPrintDocumentLoader {
    enum LoadingError: LocalizedError {
        case messageNotFound

        var errorDescription: String? {
            switch self {
            case .messageNotFound:
                return "The focused email is no longer available."
            }
        }
    }

    nonisolated private struct Source: Sendable {
        let id: UUID
        let subject: String
        let date: Date
        let from: FocusedEmailPrintAddress
        let to: [FocusedEmailPrintAddress]
        let cc: [FocusedEmailPrintAddress]
        let bcc: [FocusedEmailPrintAddress]
        let htmlPath: String?
        let textPath: String?
        let rawPath: String?
        let loadsRemoteImages: Bool
    }

    @MainActor
    static func load(
        selection: FocusedEmailPrintSelection,
        modelContext: ModelContext
    ) async throws -> FocusedEmailPrintDocument {
        let sources = try gatherSources(selection: selection, modelContext: modelContext)
        guard let anchor = sources.first(where: { $0.id == selection.anchorMessageID }) else {
            throw LoadingError.messageNotFound
        }

        let stripsQuotedHistory = selection.lens == .frontPage && sources.count > 1
        var messages: [FocusedEmailPrintMessage] = []
        messages.reserveCapacity(sources.count)
        for source in sources {
            let body = await Task.detached(priority: .userInitiated) {
                loadBody(source: source, stripsQuotedHistory: stripsQuotedHistory)
            }.value
            messages.append(
                FocusedEmailPrintMessage(
                    id: source.id,
                    subject: source.subject,
                    date: source.date,
                    from: source.from,
                    to: source.to,
                    cc: source.cc,
                    bcc: source.bcc,
                    body: body
                )
            )
        }

        let trimmedContextTitle = selection.contextTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contextTitle = trimmedContextTitle?.isEmpty == false ? trimmedContextTitle : nil
        return FocusedEmailPrintDocument(
            lens: selection.lens,
            title: contextTitle ?? anchor.subject,
            contextTitle: contextTitle == nil ? nil : anchor.subject,
            messages: messages
        )
    }

    @MainActor
    private static func gatherSources(
        selection: FocusedEmailPrintSelection,
        modelContext: ModelContext
    ) throws -> [Source] {
        let anchorMessageID = selection.anchorMessageID
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == anchorMessageID }
        )
        descriptor.fetchLimit = 1
        guard let anchor = try modelContext.fetch(descriptor).first else {
            throw LoadingError.messageNotFound
        }

        let candidates: [Message]
        switch selection.scope {
        case .message:
            candidates = [anchor]
        case .thread:
            if selection.lens == .frontPage {
                let visibleThread = FrontPageDataController.threadContext(
                    for: selection.anchorMessageID,
                    modelContext: modelContext
                )
                let messageIDs = Set(visibleThread.messages.map(\.id) + [anchor.id])
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { messageIDs.contains($0.id) }
                )
                candidates = try modelContext.fetch(descriptor)
            } else {
                candidates = anchor.thread?.messages ?? [anchor]
            }
        }
        var unique: [UUID: Message] = [:]
        for message in candidates + [anchor] {
            unique[message.id] = message
        }
        let ordered = unique.values.sorted { lhs, rhs in
            let lhsDate = messageDate(lhs)
            let rhsDate = messageDate(rhs)
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return ordered.map { message in
            Source(
                id: message.id,
                subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
                date: messageDate(message),
                from: FocusedEmailPrintAddress(
                    name: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
                    address: message.fromAddress
                ),
                to: addresses(in: message, role: .to),
                cc: addresses(in: message, role: .cc),
                bcc: addresses(in: message, role: .bcc),
                htmlPath: message.bodyHtmlPath,
                textPath: message.bodyTextPath,
                rawPath: message.rawPath,
                loadsRemoteImages: RemoteImageSenderAllowlist.shared.isAllowed(message.fromAddress)
            )
        }
    }

    @MainActor
    private static func addresses(
        in message: Message,
        role: ParticipantRole
    ) -> [FocusedEmailPrintAddress] {
        message.participants.enumerated()
            .filter { $0.element.role == role && $0.element.participant != nil }
            .sorted { lhs, rhs in
                let lhsPosition = lhs.element.headerPosition ?? lhs.offset
                let rhsPosition = rhs.element.headerPosition ?? rhs.offset
                if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
                return lhs.offset < rhs.offset
            }
            .compactMap { item in
                guard let participant = item.element.participant else { return nil }
                return FocusedEmailPrintAddress(
                    name: participant.displayName.map(MIMEHeaderDecoder.decodeEncodedWords),
                    address: participant.emailAddress
                )
            }
    }

    @MainActor
    private static func messageDate(_ message: Message) -> Date {
        message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }

    nonisolated private static func loadBody(
        source: Source,
        stripsQuotedHistory: Bool
    ) -> FocusedEmailPrintBody {
        switch LockReadoutBodyLoader.load(
            htmlPath: source.htmlPath,
            textPath: source.textPath,
            rawPath: source.rawPath
        ) {
        case .loaded(let loadedSource):
            let content = LockReadoutBodyContent(source: loadedSource)
            if let html = content.htmlDocument?.html {
                return .html(
                    stripsQuotedHistory ? frontPageFocusedMessageHTML(html) : html,
                    loadsRemoteImages: source.loadsRemoteImages
                )
            }
            if stripsQuotedHistory {
                let ownText = OriginalMessageText.cleanedForDisplay(from: content.plainText)?.text ?? ""
                return .plainText(ownText)
            }
            return .plainText(content.plainText)
        case .missing, .failed:
            return .unavailable
        }
    }
}

struct FocusedEmailPrintCommandTarget {
    let perform: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var focusedEmailPrintCommandTarget: FocusedEmailPrintCommandTarget?
}

@MainActor
enum FocusedEmailPrintCoordinator {
    static func print(
        selection: FocusedEmailPrintSelection,
        modelContext: ModelContext
    ) async {
        do {
            let document = try await FocusedEmailPrintDocumentLoader.load(
                selection: selection,
                modelContext: modelContext
            )
            let html = FocusedEmailPrintHTMLRenderer.render(document)
            let host = FocusedEmailPrintWebViewHost()
            try await host.load(
                html: html,
                blocksRemoteContent: FocusedEmailPrintHTMLRenderer.blocksRemoteContent(document)
            )
            host.runPrintOperation(jobTitle: "Ohia — \(document.title)")
        } catch {
            presentError(error)
        }
    }

    static func runPageLayout() {
        _ = NSPageLayout().runModal(with: NSPrintInfo.shared)
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Print Focused Email"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum FocusedEmailPrintError: LocalizedError {
    /// WebKit could not provide the rule list that keeps remote content off
    /// the network, so the email was not rendered.
    case unsafeContent

    var errorDescription: String? {
        switch self {
        case .unsafeContent:
            "The email couldn’t be prepared for printing without loading remote content. Try again."
        }
    }
}

@MainActor
private final class FocusedEmailPrintWebViewHost: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let loader = EmailWebViewLoader()
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 816, height: 1_056),
            configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String, blocksRemoteContent: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            loader.load(
                html,
                blocksRemoteContent: blocksRemoteContent,
                baseURL: nil,
                into: webView
            ) { [weak self] rendered in
                guard !rendered else { return }
                self?.finishLoading(with: .failure(FocusedEmailPrintError.unsafeContent))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A print job never follows links or lets the page navigate itself.
        switch EmailWebContentPolicy.navigationDecision(for: navigationAction) {
        case .allow:
            decisionHandler(.allow)
        case .cancel, .openExternally:
            decisionHandler(.cancel)
        }
    }

    func runPrintOperation(jobTitle: String) {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(with: .success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: .failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: .failure(error))
    }

    private func finishLoading(with result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
