import AppKit
import SwiftUI
import WebKit

struct LockedEmailHTMLView: View {
    enum VerticalScrollOwnership: Hashable {
        case webView
        case host
    }

    let document: LockReadoutHTMLDocument
    /// When true, the page is re-themed to sit on Ohia's canvas: a
    /// canvas-matching background is injected so the body blends with the view
    /// instead of floating as a white box. In dark mode, bright-email foreground
    /// colours are also rescued before load: inline/CSS blacks and low-contrast
    /// greys are remapped through Ohia text tokens while bright neutral fills
    /// are pulled onto Ohia chrome tokens. Already-readable or accent colours
    /// are left alone. The Front Page reader, the Timeline pane, and the
    /// locked-node overlay (Meaning / People lenses, including Focus mode) all
    /// opt in; the Projects lens renders cleaned plain text rather than this
    /// HTML view, so the re-theme never applies there.
    var blendsWithCanvas: Bool = false
    /// When false (the default for received mail), remote `http(s)` image and
    /// resource references are neutralized before load so nothing hits the
    /// network — the privacy-preserving default. Hosts flip this to true once
    /// the sender is trusted (the per-sender allowlist), and the body reloads
    /// with the originals intact.
    var loadsRemoteImages: Bool = false
    var searchHighlight: SearchMatchHighlight? = nil
    /// The normal locked-card and Timeline presentations let WebKit own the
    /// body scroll. A host such as the Front Page's story-and-replies reader
    /// can instead request the document's measured height and own the single
    /// surrounding vertical scroll.
    var verticalScrollOwnership: VerticalScrollOwnership = .webView

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readingTextSize) private var readingTextSize
    @State private var hostScrollLayout = HostScrollLayout()

    private struct HostScrollLayout: Equatable {
        var height: CGFloat = 1
        var usesBoundedInternalScroll = false
    }

    struct ReloadKey: Equatable {
        let document: LockReadoutHTMLDocument
        let blendsWithCanvas: Bool
        let loadsRemoteImages: Bool
        let searchHighlight: SearchMatchHighlight?
        let colorScheme: ColorScheme
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            document: document,
            blendsWithCanvas: blendsWithCanvas,
            loadsRemoteImages: loadsRemoteImages,
            searchHighlight: searchHighlight,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        let backgroundHex = Self.webViewBackgroundHex(
            blendsWithCanvas: blendsWithCanvas,
            scheme: colorScheme
        )
        DarkCanvasEmailWebView(
            html: displayHTML,
            blocksRemoteContent: !loadsRemoteImages,
            reloadKey: reloadKey,
            backgroundHex: backgroundHex,
            cssColorScheme: colorScheme == .dark ? "dark" : "light",
            backgroundColor: Self.webViewBackgroundColor(hex: backgroundHex),
            pageZoom: readingTextSize.scale,
            reportsContentHeight: verticalScrollOwnership == .host,
            forwardsVerticalScrollToHost: verticalScrollOwnership == .host
                && hostScrollLayout.usesBoundedInternalScroll == false,
            onContentHeightChange: updateHostScrollLayout
        )
            .id(verticalScrollOwnership)
            .frame(height: verticalScrollOwnership == .host ? hostScrollLayout.height : nil)
            .accessibilityLabel("HTML email body")
    }

    fileprivate static let aboutBlankURL = URL(string: "about:blank")!

    private var displayHTML: String {
        // Block remote resources by default (privacy): neutralize remote
        // image/CSS refs to in-place placeholders. Trusted senders skip
        // this and load the originals.
        let sourceHTML = loadsRemoteImages
            // Trusted sender: load images, upgrading cleartext http URLs
            // to https so ATS-blocked images render securely.
            ? RemoteImageBlocking.upgradingInsecureImageURLs(in: document.html)
            : RemoteImageBlocking.block(
                in: document.html,
                placeholderHex: Self.hex(OhiaColors.iconPillBackground, scheme: colorScheme)
            ).html
        // Strip `target` attributes from anchors so link clicks route through
        // the navigation delegate instead of opening a detached browsing context.
        let highlightedHTML = SearchMatchTextHighlighter.highlightedHTMLTextNodes(
            in: sourceHTML,
            highlight: searchHighlight
        )
        return Self.htmlForDisplay(
            highlightedHTML,
            canvasCSS: blendsWithCanvas ? Self.canvasCSS(for: colorScheme) : nil,
            canvasColorScheme: blendsWithCanvas ? colorScheme : nil,
            highlightCSS: searchHighlight == nil ? nil : Self.searchHighlightCSS(for: colorScheme),
            hostScrollsVertically: verticalScrollOwnership == .host
        )
    }

    private func updateHostScrollLayout(
        _ height: CGFloat,
        usesBoundedInternalScroll: Bool
    ) {
        guard verticalScrollOwnership == .host,
              height.isFinite,
              height > 0 else {
            return
        }
        let next = HostScrollLayout(
            height: height,
            usesBoundedInternalScroll: usesBoundedInternalScroll
        )
        guard abs(hostScrollLayout.height - next.height) > 0.5
                || hostScrollLayout.usesBoundedInternalScroll != next.usesBoundedInternalScroll else {
            return
        }
        hostScrollLayout = next
    }

    private static let anchorTargetRegex: NSRegularExpression = {
        // Matches a `target` attribute on any tag — quoted or bare value.
        // Conservative: only the attribute string itself is removed; the
        // surrounding anchor and its href stay intact.
        try! NSRegularExpression(
            pattern: #"(?i)\s+target\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        )
    }()

    static func htmlForDisplay(
        _ html: String,
        canvasCSS: String? = nil,
        canvasColorScheme: ColorScheme? = nil,
        highlightCSS: String? = nil,
        hostScrollsVertically: Bool = false
    ) -> String {
        var displayHTML = stripAnchorTargets(in: html)
        if let canvasColorScheme {
            displayHTML = rescueCanvasColors(in: displayHTML, scheme: canvasColorScheme)
        }
        return injectDisplayHeadHTML(
            into: displayHTML,
            cssBlocks: [
                highlightCSS,
                canvasCSS,
                hostScrollsVertically ? hostVerticalScrollCSS : nil,
            ].compactMap(\.self)
        )
    }

    /// WebKit posts the full document height whenever HTML, inline media, or
    /// responsive layout changes. The page's own JavaScript remains disabled;
    /// this trusted script is installed as a `WKUserScript` by the native host.
    static let contentHeightReporterJavaScript = """
    (() => {
        const handler = window.webkit?.messageHandlers?.ohiaContentHeight;
        if (!handler) { return; }

        const maximumExpandedHeight = 32000;
        const boundedViewportHeight = 1200;
        const boundedScrollClass = 'ohia-bounded-scroll';
        let pendingReport = null;
        let lastPayloadKey = '';

        const reportHeight = () => {
            pendingReport = null;
            const root = document.documentElement;
            const body = document.body;
            const height = Math.ceil(Math.max(
                document.documentElement ? document.documentElement.scrollHeight : 0,
                root ? root.getBoundingClientRect().height : 0,
                body ? body.scrollHeight : 0,
                body ? body.getBoundingClientRect().height : 0
            ));
            if (height <= 0) { return; }

            const bounded = height > maximumExpandedHeight;
            if (root) { root.classList.toggle(boundedScrollClass, bounded); }
            const reportedHeight = bounded ? boundedViewportHeight : height;
            const payloadKey = `${reportedHeight}:${bounded}`;
            if (payloadKey === lastPayloadKey) { return; }
            lastPayloadKey = payloadKey;
            handler.postMessage({ height: reportedHeight, bounded });
        };

        const scheduleReport = () => {
            if (pendingReport !== null) { return; }
            pendingReport = window.setTimeout(reportHeight, 120);
        };

        const installObserver = () => {
            const observer = new ResizeObserver(scheduleReport);
            if (document.documentElement) { observer.observe(document.documentElement); }
            if (document.body) { observer.observe(document.body); }
            scheduleReport();
        };

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', installObserver, { once: true });
        } else {
            installObserver();
        }
        window.addEventListener('load', scheduleReport, { once: true });
    })();
    """

    fileprivate static let contentHeightMessageName = "ohiaContentHeight"

    /// In host-scroll mode the WebView expands to the reported document height,
    /// so its own vertical overflow must stay inert. Width still constrains
    /// media; removing the viewport-height cap prevents the initial 1-pt host
    /// frame from collapsing images before the first measurement arrives.
    private static let hostVerticalScrollCSS = """
    html, body {
        height: auto !important;
        min-height: 0 !important;
        overflow-y: hidden !important;
    }
    html.ohia-bounded-scroll,
    html.ohia-bounded-scroll body {
        overflow-y: auto !important;
    }
    img, video, canvas, svg {
        max-height: none !important;
    }
    """

    /// Re-theme CSS so the page blends with Ohia's canvas. `background` is
    /// forced to the canvas colour so the page never paints a white box; `body`
    /// receives the mode-aware default text colour for unstyled descendants;
    /// links adopt the active accent.
    private static func canvasCSS(for scheme: ColorScheme) -> String {
        let bg = hex(OhiaColors.spaceBackground, scheme: scheme)
        let fg = hex(OhiaColors.textPrimary, scheme: scheme)
        let link = hex(OhiaColors.chipActiveForeground, scheme: scheme)
        let colorScheme = scheme == .dark ? "dark" : "light"
        return """
        html { color-scheme: \(colorScheme); }
        html, body { background: \(bg) !important; }
        body { color: \(fg) !important; }
        body, p, div, span, td, th, li, blockquote, h1, h2, h3, h4, h5, h6 { color: \(fg); }
        a { color: \(link) !important; }
        """
    }

    private static func searchHighlightCSS(for scheme: ColorScheme) -> String {
        let fill = rgba(OhiaColors.ohiaYellow, alpha: 0.38, scheme: scheme)
        let ring = rgba(OhiaColors.chipActiveForeground, alpha: 0.78, scheme: scheme)
        return """
        mark.ohia-search-hit {
            background: \(fill) !important;
            color: inherit !important;
            border-radius: 2px;
            box-shadow: 0 0 0 1px \(ring);
            padding: 0 1px;
        }
        """
    }

    private static let cssForegroundColorRegex = makeRegex(
        #"(?i)(^|[;{"']\s*)((?:color|-webkit-text-fill-color)\s*:\s*)(#[0-9a-f]{3,8}|rgba?\([^;}"']*\)|[a-z]+)(\s*!important)?"#
    )

    private static let cssBackgroundColorRegex = makeRegex(
        #"(?i)(^|[;{"']\s*)((?:background-color|background)\s*:\s*)(#[0-9a-f]{3,8}|rgba?\([^;}"']*\)|[a-z]+)(\s*!important)?"#
    )

    private static let htmlTextColorAttributeRegex = makeRegex(
        #"(?i)(\s(?:color|text)\s*=\s*)(["']?)(#[0-9a-f]{3,8}|rgba?\([^"'>]*\)|[a-z]+)(\2)"#
    )

    private static let htmlBackgroundColorAttributeRegex = makeRegex(
        #"(?i)(\sbgcolor\s*=\s*)(["']?)(#[0-9a-f]{3,8}|rgba?\([^"'>]*\)|[a-z]+)(\2)"#
    )

    /// Front Page removes bright-message white backgrounds in dark mode. This
    /// pass fixes the other half of that move by lifting foreground colours
    /// that only worked on light fills, then moderating bright inline fills
    /// themselves. It targets CSS/HTML colour declarations only, so photos and
    /// remote artwork keep their original appearance.
    private static func rescueCanvasColors(in html: String, scheme: ColorScheme) -> String {
        guard scheme == .dark else { return html }
        let palette = CanvasColorPalette(
            background: CSSRGBAColor.parse(hex(OhiaColors.spaceBackground, scheme: scheme)) ?? .black,
            primary: hex(OhiaColors.textPrimary, scheme: scheme),
            secondary: hex(OhiaColors.textSecondary, scheme: scheme),
            brightFillReplacement: hex(OhiaColors.iconPillBackground, scheme: scheme)
        )
        let cssFixed = replaceCSSForegroundColors(in: html, palette: palette)
        let textAttributeFixed = replaceHTMLTextColorAttributes(in: cssFixed, palette: palette)
        let backgroundFixed = replaceCSSBackgroundColors(in: textAttributeFixed, palette: palette)
        return replaceHTMLBackgroundColorAttributes(in: backgroundFixed, palette: palette)
    }

    private static func replaceCSSForegroundColors(
        in html: String,
        palette: CanvasColorPalette
    ) -> String {
        replaceCSSColors(in: html, regex: cssForegroundColorRegex) { value in
            optimizedCanvasForegroundHex(forCSSValue: value, palette: palette)
        }
    }

    private static func replaceHTMLTextColorAttributes(
        in html: String,
        palette: CanvasColorPalette
    ) -> String {
        replaceHTMLColorAttributes(in: html, regex: htmlTextColorAttributeRegex) { value in
            optimizedCanvasForegroundHex(forCSSValue: value, palette: palette)
        }
    }

    private static func replaceCSSBackgroundColors(
        in html: String,
        palette: CanvasColorPalette
    ) -> String {
        replaceCSSColors(in: html, regex: cssBackgroundColorRegex) { value in
            optimizedCanvasBackgroundHex(forCSSValue: value, palette: palette)
        }
    }

    private static func replaceHTMLBackgroundColorAttributes(
        in html: String,
        palette: CanvasColorPalette
    ) -> String {
        replaceHTMLColorAttributes(in: html, regex: htmlBackgroundColorAttributeRegex) { value in
            optimizedCanvasBackgroundHex(forCSSValue: value, palette: palette)
        }
    }

    private static func replaceCSSColors(
        in html: String,
        regex: NSRegularExpression?,
        replacementFor: (String) -> String?
    ) -> String {
        guard let regex else { return html }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard matches.isEmpty == false else { return html }

        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 5,
                  let matchRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 3), in: html) else {
                continue
            }
            let value = String(html[valueRange])
            guard let replacement = replacementFor(value) else { continue }
            let prefix = substring(in: html, range: match.range(at: 1))
            let property = substring(in: html, range: match.range(at: 2))
            let important = substring(in: html, range: match.range(at: 4))
            result.replaceSubrange(matchRange, with: "\(prefix)\(property)\(replacement)\(important)")
        }
        return result
    }

    private static func replaceHTMLColorAttributes(
        in html: String,
        regex: NSRegularExpression?,
        replacementFor: (String) -> String?
    ) -> String {
        guard let regex else { return html }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard matches.isEmpty == false else { return html }

        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 5,
                  let matchRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 3), in: html) else {
                continue
            }
            let value = String(html[valueRange])
            guard let replacement = replacementFor(value) else { continue }
            let prefix = substring(in: html, range: match.range(at: 1))
            let quote = substring(in: html, range: match.range(at: 2))
            let closingQuote = substring(in: html, range: match.range(at: 4))
            result.replaceSubrange(matchRange, with: "\(prefix)\(quote)\(replacement)\(closingQuote)")
        }
        return result
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func optimizedCanvasForegroundHex(
        forCSSValue value: String,
        palette: CanvasColorPalette
    ) -> String? {
        guard let color = CSSRGBAColor.parse(value), color.alpha > 0.04 else { return nil }
        let composited = color.composited(over: palette.background)
        guard composited.contrastRatio(against: palette.background) < 4.5 else { return nil }
        return composited.relativeLuminance < 0.10 ? palette.primary : palette.secondary
    }

    private static func optimizedCanvasBackgroundHex(
        forCSSValue value: String,
        palette: CanvasColorPalette
    ) -> String? {
        guard let color = CSSRGBAColor.parse(value), color.alpha > 0.04 else { return nil }
        let composited = color.composited(over: palette.background)
        guard composited.relativeLuminance > 0.22, composited.saturation < 0.18 else { return nil }
        return palette.brightFillReplacement
    }

    private static func substring(in string: String, range: NSRange) -> String {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: string) else {
            return ""
        }
        return String(string[swiftRange])
    }

    private struct CanvasColorPalette {
        let background: CSSRGBAColor
        let primary: String
        let secondary: String
        let brightFillReplacement: String
    }

    private struct CSSRGBAColor {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        static let black = CSSRGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

        var relativeLuminance: Double {
            0.2126 * Self.linearized(red)
                + 0.7152 * Self.linearized(green)
                + 0.0722 * Self.linearized(blue)
        }

        var saturation: Double {
            let maxChannel = max(red, green, blue)
            guard maxChannel > 0 else { return 0 }
            return (maxChannel - min(red, green, blue)) / maxChannel
        }

        func composited(over background: CSSRGBAColor) -> CSSRGBAColor {
            guard alpha < 1 else { return self }
            let inverseAlpha = 1 - alpha
            return CSSRGBAColor(
                red: red * alpha + background.red * inverseAlpha,
                green: green * alpha + background.green * inverseAlpha,
                blue: blue * alpha + background.blue * inverseAlpha,
                alpha: 1
            )
        }

        func contrastRatio(against other: CSSRGBAColor) -> Double {
            let first = relativeLuminance
            let second = other.relativeLuminance
            let lighter = max(first, second)
            let darker = min(first, second)
            return (lighter + 0.05) / (darker + 0.05)
        }

        static func parse(_ rawValue: String) -> CSSRGBAColor? {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("#") {
                return parseHex(value)
            }
            if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
                return parseRGBFunction(value)
            }
            return namedColors[value]
        }

        private static func parseHex(_ value: String) -> CSSRGBAColor? {
            let hex = String(value.dropFirst())
            func byte(_ string: String) -> Double? {
                guard let number = UInt8(string, radix: 16) else { return nil }
                return Double(number) / 255
            }

            switch hex.count {
            case 3, 4:
                let parts = hex.map { String(repeating: String($0), count: 2) }
                guard let red = byte(parts[0]),
                      let green = byte(parts[1]),
                      let blue = byte(parts[2]) else {
                    return nil
                }
                let alpha = parts.count == 4 ? (byte(parts[3]) ?? 1) : 1
                return CSSRGBAColor(red: red, green: green, blue: blue, alpha: alpha)
            case 6, 8:
                let chars = Array(hex)
                guard let red = byte(String(chars[0...1])),
                      let green = byte(String(chars[2...3])),
                      let blue = byte(String(chars[4...5])) else {
                    return nil
                }
                let alpha = chars.count == 8 ? (byte(String(chars[6...7])) ?? 1) : 1
                return CSSRGBAColor(red: red, green: green, blue: blue, alpha: alpha)
            default:
                return nil
            }
        }

        private static func parseRGBFunction(_ value: String) -> CSSRGBAColor? {
            guard let open = value.firstIndex(of: "("),
                  let close = value.lastIndex(of: ")"),
                  open < close else {
                return nil
            }
            let body = value[value.index(after: open)..<close]
                .replacingOccurrences(of: "/", with: " ")
            let parts = body.split { character in
                character == "," || character.isWhitespace
            }
            guard parts.count >= 3,
                  let red = parseRGBComponent(parts[0]),
                  let green = parseRGBComponent(parts[1]),
                  let blue = parseRGBComponent(parts[2]) else {
                return nil
            }
            let alpha = parts.count >= 4 ? (parseAlphaComponent(parts[3]) ?? 1) : 1
            return CSSRGBAColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        private static func parseRGBComponent(_ raw: Substring) -> Double? {
            let text = String(raw)
            if text.hasSuffix("%") {
                guard let value = Double(text.dropLast()) else { return nil }
                return clamped(value / 100)
            }
            guard let value = Double(text) else { return nil }
            return clamped(value / 255)
        }

        private static func parseAlphaComponent(_ raw: Substring) -> Double? {
            let text = String(raw)
            if text.hasSuffix("%") {
                guard let value = Double(text.dropLast()) else { return nil }
                return clamped(value / 100)
            }
            guard let value = Double(text) else { return nil }
            return clamped(value)
        }

        private static func clamped(_ value: Double) -> Double {
            min(1, max(0, value))
        }

        private static func linearized(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }

        private static let namedColors: [String: CSSRGBAColor] = [
            "black": CSSRGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
            "blue": CSSRGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
            "brown": CSSRGBAColor(red: 0.647, green: 0.165, blue: 0.165, alpha: 1),
            "darkblue": CSSRGBAColor(red: 0, green: 0, blue: 0.545, alpha: 1),
            "darkgray": CSSRGBAColor(red: 0.663, green: 0.663, blue: 0.663, alpha: 1),
            "darkgreen": CSSRGBAColor(red: 0, green: 0.392, blue: 0, alpha: 1),
            "darkgrey": CSSRGBAColor(red: 0.663, green: 0.663, blue: 0.663, alpha: 1),
            "darkslategray": CSSRGBAColor(red: 0.184, green: 0.310, blue: 0.310, alpha: 1),
            "darkslategrey": CSSRGBAColor(red: 0.184, green: 0.310, blue: 0.310, alpha: 1),
            "dimgray": CSSRGBAColor(red: 0.412, green: 0.412, blue: 0.412, alpha: 1),
            "dimgrey": CSSRGBAColor(red: 0.412, green: 0.412, blue: 0.412, alpha: 1),
            "gainsboro": CSSRGBAColor(red: 0.863, green: 0.863, blue: 0.863, alpha: 1),
            "gray": CSSRGBAColor(red: 0.502, green: 0.502, blue: 0.502, alpha: 1),
            "green": CSSRGBAColor(red: 0, green: 0.502, blue: 0, alpha: 1),
            "grey": CSSRGBAColor(red: 0.502, green: 0.502, blue: 0.502, alpha: 1),
            "lightgray": CSSRGBAColor(red: 0.827, green: 0.827, blue: 0.827, alpha: 1),
            "lightgrey": CSSRGBAColor(red: 0.827, green: 0.827, blue: 0.827, alpha: 1),
            "maroon": CSSRGBAColor(red: 0.502, green: 0, blue: 0, alpha: 1),
            "navy": CSSRGBAColor(red: 0, green: 0, blue: 0.502, alpha: 1),
            "purple": CSSRGBAColor(red: 0.502, green: 0, blue: 0.502, alpha: 1),
            "red": CSSRGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            "silver": CSSRGBAColor(red: 0.753, green: 0.753, blue: 0.753, alpha: 1),
            "transparent": CSSRGBAColor(red: 0, green: 0, blue: 0, alpha: 0),
            "white": CSSRGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
            "whitesmoke": CSSRGBAColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1)
        ]
    }

    /// Resolves a (possibly dynamic) `OhiaColors` token to an sRGB hex string
    /// for the given appearance, so the injected CSS stays mode-correct without
    /// hard-coding RGB. Routes through `OhiaColors` per the style guide.
    private static func hex(_ color: Color, scheme: ColorScheme) -> String {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            ?? NSApp.effectiveAppearance
        var result = "#000000"
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = NSColor(color).usingColorSpace(.sRGB) {
                result = String(
                    format: "#%02X%02X%02X",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded())
                )
            }
        }
        return result
    }

    private static func rgba(_ color: Color, alpha: Double, scheme: ColorScheme) -> String {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            ?? NSApp.effectiveAppearance
        var result = "rgba(0, 0, 0, \(alpha))"
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = NSColor(color).usingColorSpace(.sRGB) {
                result = String(
                    format: "rgba(%d, %d, %d, %.3f)",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded()),
                    alpha
                )
            }
        }
        return result
    }

    static func webViewBackgroundHex(blendsWithCanvas: Bool, scheme: ColorScheme) -> String {
        if blendsWithCanvas || scheme == .dark {
            return hex(OhiaColors.spaceBackground, scheme: scheme)
        }
        return hex(Color(nsColor: .textBackgroundColor), scheme: scheme)
    }

    private static func webViewBackgroundColor(hex: String) -> NSColor {
        return CSSRGBAColor.parse(hex).map { color in
            NSColor(
                calibratedRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        } ?? NSColor(OhiaColors.spaceBackground)
    }

    private static func stripAnchorTargets(in html: String) -> String {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return anchorTargetRegex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: ""
        )
    }

    private static let displayHeadHTML = """
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :where(html) {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
    }
    html, body {
        margin: 0 !important;
        padding: 0 !important;
        max-width: 100% !important;
        overflow-x: hidden !important;
    }
    body {
        box-sizing: border-box !important;
        word-break: break-word;
        overflow-wrap: anywhere;
    }
    *, *::before, *::after {
        box-sizing: border-box !important;
    }
    img, video, canvas, svg {
        display: block;
        max-width: 100% !important;
        max-height: 100vh !important;
        height: auto !important;
        object-fit: contain;
    }
    table {
        max-width: 100% !important;
    }
    pre {
        white-space: pre-wrap !important;
    }
    </style>
    """

    private static func injectDisplayHeadHTML(into html: String, cssBlocks: [String]) -> String {
        let head = displayHeadHTML + cssBlocks
            .map { "\n<style>\n\($0)\n</style>" }
            .joined()
        if let headClose = html.range(of: "</head>", options: .caseInsensitive) {
            var result = html
            result.insert(contentsOf: head, at: headClose.lowerBound)
            return result
        }

        if let htmlOpen = html.range(
            of: #"<html\b[^>]*>"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            var result = html
            result.insert(contentsOf: "<head>\(head)</head>", at: htmlOpen.upperBound)
            return result
        }

        return """
        <!doctype html>
        <html>
        <head>
        \(head)
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}

private struct DarkCanvasEmailWebView: NSViewRepresentable {
    let html: String
    /// Remote-content posture enforced inside WebKit (`EmailWebContentPolicy`).
    let blocksRemoteContent: Bool
    let reloadKey: LockedEmailHTMLView.ReloadKey
    let backgroundHex: String
    let cssColorScheme: String
    let backgroundColor: NSColor
    let pageZoom: CGFloat
    let reportsContentHeight: Bool
    let forwardsVerticalScrollToHost: Bool
    let onContentHeightChange: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if reportsContentHeight {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: LockedEmailHTMLView.contentHeightReporterJavaScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
            configuration.userContentController.add(
                context.coordinator,
                name: LockedEmailHTMLView.contentHeightMessageName
            )
        }

        let webView = DarkCanvasWKWebView(frame: .zero, configuration: configuration)
        webView.forwardsVerticalScrollToHost = forwardsVerticalScrollToHost
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.wantsLayer = true
        webView.pageZoom = pageZoom
        applyBackground(to: webView)
        webView.loadHTMLString(
            Self.placeholderHTML(
                backgroundHex: backgroundHex,
                cssColorScheme: cssColorScheme
            ),
            baseURL: LockedEmailHTMLView.aboutBlankURL
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        (webView as? DarkCanvasWKWebView)?.forwardsVerticalScrollToHost = forwardsVerticalScrollToHost
        applyBackground(to: webView)
        if abs(webView.pageZoom - pageZoom) > 0.001 {
            webView.pageZoom = pageZoom
            context.coordinator.publishLastMeasuredHeight()
        }
        guard context.coordinator.loadedKey != reloadKey else { return }
        context.coordinator.loadedKey = reloadKey
        // Always an `about:blank` base: cid: images are inlined as data: URLs
        // and remote images are absolute, so a file:// base is never needed.
        context.coordinator.loader.load(
            html,
            blocksRemoteContent: blocksRemoteContent,
            baseURL: LockedEmailHTMLView.aboutBlankURL,
            into: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: LockedEmailHTMLView.contentHeightMessageName
        )
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.layer?.backgroundColor = backgroundColor.cgColor
    }

    private static func placeholderHTML(
        backgroundHex: String,
        cssColorScheme: String
    ) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <style>
        html, body {
            margin: 0;
            min-height: 100%;
            background: \(backgroundHex);
            color-scheme: \(cssColorScheme);
        }
        </style>
        </head>
        <body></body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: DarkCanvasEmailWebView
        var loadedKey: LockedEmailHTMLView.ReloadKey?
        let loader = EmailWebViewLoader()
        private var lastMeasuredCSSHeight: CGFloat?
        private var lastMeasurementUsedBoundedInternalScroll = false

        init(parent: DarkCanvasEmailWebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == LockedEmailHTMLView.contentHeightMessageName,
                  let payload = message.body as? [String: Any],
                  let number = payload["height"] as? NSNumber else {
                return
            }
            publishMeasuredHeight(
                CGFloat(truncating: number),
                usesBoundedInternalScroll: payload["bounded"] as? Bool ?? false
            )
        }

        func publishLastMeasuredHeight() {
            guard let lastMeasuredCSSHeight else { return }
            publishMeasuredHeight(
                lastMeasuredCSSHeight,
                usesBoundedInternalScroll: lastMeasurementUsedBoundedInternalScroll
            )
        }

        private func publishMeasuredHeight(
            _ cssHeight: CGFloat,
            usesBoundedInternalScroll: Bool
        ) {
            guard cssHeight.isFinite, cssHeight > 0 else { return }
            lastMeasuredCSSHeight = cssHeight
            lastMeasurementUsedBoundedInternalScroll = usesBoundedInternalScroll
            parent.onContentHeightChange(
                ceil(cssHeight * parent.pageZoom),
                usesBoundedInternalScroll
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            switch EmailWebContentPolicy.navigationDecision(for: navigationAction) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }
}

/// A content-sized WebView has no vertical range of its own. Route wheel
/// events to the nearest enclosing SwiftUI `ScrollView` so scrolling remains
/// continuous when the pointer is over rich HTML, while preserving normal
/// WebKit handling in every internally-scrolling presentation.
private final class DarkCanvasWKWebView: WKWebView {
    var forwardsVerticalScrollToHost = false

    override func scrollWheel(with event: NSEvent) {
        guard forwardsVerticalScrollToHost,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              let hostScrollView = enclosingHostScrollView else {
            super.scrollWheel(with: event)
            return
        }
        hostScrollView.scrollWheel(with: event)
    }

    private var enclosingHostScrollView: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }
}
