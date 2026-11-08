import Foundation
import OSLog
import WebKit

/// The engine-level privacy and navigation policy for every `WKWebView` that
/// renders received mail.
///
/// `RemoteImageBlocking` rewrites a body's markup for presentation (blocked
/// images keep their box and the "Load remote images" count stays honest),
/// but markup rewriting cannot be a privacy boundary: iframes, meta refresh,
/// media posters, CSS `@import` and `image-set`, preload links, and
/// entity- or CSS-escaped URLs all reach the network without matching a
/// rewrite. The boundary is enforced inside WebKit instead:
///
/// - While remote content is blocked, a content rule list refuses every load
///   whose URL has an authority (`scheme://…`) — any resource type, any
///   frame. `about:` documents and self-contained `data:` resources (inline
///   attachments are already rewritten to `data:` URLs) still render.
/// - Whether or not remote content is allowed, the page may not navigate
///   itself: the only documents a frame may hold are Ohia's own `about:`
///   document (and `data:` subframes). A clicked link with a web, mail, or
///   phone scheme opens outside Ohia; every other navigation is cancelled.
enum EmailWebContentPolicy {
    nonisolated enum NavigationDecision: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    /// WebKit stores compiled lists by identifier; bump the version whenever
    /// `remoteContentRules` changes so a stale compiled list is never reused.
    nonisolated static let ruleListIdentifier = "org.jgkarlin.Ohia.email-remote-content-v1"

    /// WebKit's content-rule regex subset: anchored scheme followed by `://`.
    nonisolated static let remoteContentRules = #"[{"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://"},"action":{"type":"block"}}]"#

    nonisolated static func navigationDecision(
        url: URL?,
        isLinkActivation: Bool,
        targetsMainFrame: Bool
    ) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if isLinkActivation {
            if scheme == "about" { return .allow }  // in-page `#fragment` anchors
            return opensExternally(scheme: scheme) ? .openExternally(url) : .cancel
        }
        if scheme == "about" { return .allow }
        if scheme == "data", !targetsMainFrame { return .allow }
        return .cancel
    }

    static func navigationDecision(for action: WKNavigationAction) -> NavigationDecision {
        navigationDecision(
            url: action.request.url,
            isLinkActivation: action.navigationType == .linkActivated,
            // A nil target frame is a request for a new window.
            targetsMainFrame: action.targetFrame?.isMainFrame ?? true
        )
    }

    nonisolated static func opensExternally(scheme: String) -> Bool {
        switch scheme.lowercased() {
        case "http", "https", "mailto", "tel": true
        default: false
        }
    }
}

/// Compiles the remote-content rule list once per launch (WebKit keeps the
/// compiled form on disk, so later launches only look it up) and hands every
/// email web view the same instance.
@MainActor
final class EmailRemoteContentRuleList {
    static let shared = EmailRemoteContentRuleList()

    private(set) var compiled: WKContentRuleList?
    private var pending: Task<WKContentRuleList, any Error>?
    private let logger = Logger(subsystem: "org.jgkarlin.Ohia", category: "EmailWebContentPolicy")

    enum CompileError: Error { case unavailable }

    func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        if let pending { return try await pending.value }
        let task = Task { @MainActor () throws -> WKContentRuleList in
            let store = WKContentRuleListStore.default()
            if let stored = try? await store?.contentRuleList(
                forIdentifier: EmailWebContentPolicy.ruleListIdentifier
            ) {
                return stored
            }
            guard let store,
                  let list = try await store.compileContentRuleList(
                      forIdentifier: EmailWebContentPolicy.ruleListIdentifier,
                      encodedContentRuleList: EmailWebContentPolicy.remoteContentRules
                  ) else {
                throw CompileError.unavailable
            }
            return list
        }
        pending = task
        do {
            let list = try await task.value
            compiled = list
            pending = nil
            return list
        } catch {
            pending = nil
            logger.error(
                "Remote-content rule list unavailable: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }
}

/// Loads HTML into an email web view only once its remote-content posture is
/// in place, so no body is ever parsed before the rule list that guards it.
/// A newer load supersedes one still waiting on the rule list.
@MainActor
final class EmailWebViewLoader {
    private var generation = 0
    private var installedRuleList: WKContentRuleList?

    /// Shown in place of the body if WebKit cannot provide the rule list;
    /// the body is never rendered without it.
    static let unavailableHTML = """
    <!doctype html><html><head><meta charset="utf-8"></head>\
    <body style="font: -apple-system-body; color: GrayText; padding: 1em;">\
    This message can’t be shown safely right now.</body></html>
    """

    func load(
        _ html: String,
        blocksRemoteContent: Bool,
        baseURL: URL?,
        into webView: WKWebView,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        generation += 1
        let token = generation
        let controller = webView.configuration.userContentController

        guard blocksRemoteContent else {
            if installedRuleList != nil {
                controller.removeAllContentRuleLists()
                installedRuleList = nil
            }
            webView.loadHTMLString(html, baseURL: baseURL)
            completion?(true)
            return
        }

        if let list = installedRuleList ?? EmailRemoteContentRuleList.shared.compiled {
            install(list, in: controller)
            webView.loadHTMLString(html, baseURL: baseURL)
            completion?(true)
            return
        }

        Task { @MainActor [weak self, weak webView] in
            let list = try? await EmailRemoteContentRuleList.shared.ruleList()
            guard let self, let webView, token == self.generation else { return }
            guard let list else {
                webView.loadHTMLString(Self.unavailableHTML, baseURL: baseURL)
                completion?(false)
                return
            }
            self.install(list, in: controller)
            webView.loadHTMLString(html, baseURL: baseURL)
            completion?(true)
        }
    }

    private func install(_ list: WKContentRuleList, in controller: WKUserContentController) {
        guard installedRuleList !== list else { return }
        controller.removeAllContentRuleLists()
        controller.add(list)
        installedRuleList = list
    }
}
