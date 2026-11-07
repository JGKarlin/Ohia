// Ohia/Settings/Signatures/SignatureHTMLPreviewView.swift
// Send-fidelity signature preview: the same sandboxed WKWebView posture as
// the mail reader (non-persistent store, JavaScript off), fed
// self-contained HTML whose ohia-sig:// tokens were already resolved to
// data: URLs. Nothing remote can load — the CSP is the sandbox itself.

import SwiftUI
import WebKit

struct SignatureHTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        // Always the light canvas, in either habitat. This is a rendering of
        // an artifact that ships into someone else's mail client, not Ohia
        // chrome — §18's registers govern the card around it, not the paper
        // inside it. A signature is authored for a light background (the
        // prompt says so, and the built-in template hard-codes #222222), and
        // every colour it carries is inline, so a dark canvas never reached
        // the text: it just put charcoal on #1f1f20 and made the name
        // vanish. Worse, a "send preview" that themes itself stops
        // predicting what the recipient sees, which is the one job it has.
        let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        body { margin: 12px; font: 13px -apple-system, sans-serif; color: #222222; background-color: #ffffff; }
        img { max-width: 100%; }
        </style></head><body>\(html)</body></html>
        """
        // Reloading an identical document per view evaluation would churn
        // WebKit (and flicker) — skip when nothing changed.
        guard document != coordinator.lastLoadedDocument else { return }
        coordinator.lastLoadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    /// Links stay inert inside the preview: any user-initiated navigation
    /// is cancelled (the preview is a rendering, not a browser).
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedDocument: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
