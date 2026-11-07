import AppKit
import SwiftUI

enum FrontPagePlainTextLinkifier {
    static func attributedString(
        from raw: String,
        font: NSFont,
        foregroundColor: NSColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        searchHighlight: SearchMatchHighlight? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.alignment = .natural

        // TextKit treats every bare "\n" as ending a paragraph, so applying
        // `paragraphSpacing` over raw text would give a hard-wrapped signature
        // block (single newlines, no blank line) the same large gap as a real
        // paragraph break. Collapse single newlines to U+2028 (line separator,
        // stays within the paragraph → governed by `lineSpacing` only) and
        // keep only blank-line-delimited breaks as real paragraph separators.
        // All line-ending variants (CRLF, bare CR, and the Unicode line/
        // paragraph/next-line separators) are folded to "\n" first, matching
        // `OriginalMessageText`'s normalization, so every one of them is
        // treated as a real line boundary rather than silently surviving
        // as ordinary text inside a paragraph.
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
        let collapsed = normalizedParagraphBreaks(normalizedNewlines)
        let attributed = NSMutableAttributedString(
            string: collapsed,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraph
            ]
        )
        applyDetectedLinks(to: attributed, in: collapsed)
        return SearchMatchTextHighlighter.highlightedNSAttributedString(
            attributed,
            highlight: searchHighlight
        )
    }

    /// Splits `text` into paragraphs delimited by a blank line, then rejoins
    /// each paragraph's internal hard line breaks with U+2028 (line
    /// separator) instead of "\n" so TextKit keeps them inside the same
    /// paragraph. Only the breaks between paragraphs stay as real "\n"
    /// separators, so `paragraphSpacing` applies once per real gap rather
    /// than after every line.
    private static func normalizedParagraphBreaks(_ text: String) -> String {
        var paragraphs: [[Substring]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if paragraphs[paragraphs.count - 1].isEmpty == false {
                    paragraphs.append([])
                }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        if paragraphs.last?.isEmpty == true {
            paragraphs.removeLast()
        }
        return paragraphs
            .map { $0.joined(separator: "\u{2028}") }
            .joined(separator: "\n")
    }

    static func configureLinkedTextView(
        _ textView: NSTextView,
        delegate: NSTextViewDelegate
    ) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: OhiaColors.nsLinkText,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.delegate = delegate
    }

    static func open(link: Any) -> Bool {
        guard let url = url(from: link),
              shouldOpenOutsideReader(url) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func applyDetectedLinks(to attributed: NSMutableAttributedString, in text: String) {
        guard text.isEmpty == false,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: fullRange) {
            guard match.resultType == .link,
                  match.range.location != NSNotFound,
                  match.range.length > 0,
                  let url = url(from: match, in: text),
                  shouldOpenOutsideReader(url) else {
                continue
            }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static func url(from match: NSTextCheckingResult, in text: String) -> URL? {
        if let url = match.url {
            return normalized(url: url, matchedText: matchedText(for: match, in: text))
        }
        return fallbackURL(from: matchedText(for: match, in: text))
    }

    private static func url(from link: Any) -> URL? {
        if let url = link as? URL {
            return normalized(url: url, matchedText: url.absoluteString)
        }
        if let url = link as? NSURL {
            return normalized(url: url as URL, matchedText: url.absoluteString ?? "")
        }
        if let value = link as? String {
            return fallbackURL(from: value)
        }
        return nil
    }

    private static func normalized(url: URL, matchedText: String) -> URL? {
        if url.scheme?.isEmpty == false { return url }
        return fallbackURL(from: matchedText)
    }

    private static func fallbackURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"' \t\r\n"))
        guard trimmed.isEmpty == false else { return nil }
        if let url = URL(string: trimmed), url.scheme?.isEmpty == false {
            return url
        }
        if trimmed.localizedCaseInsensitiveComparePrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }
        if trimmed.contains("@"), trimmed.contains(" ") == false {
            return URL(string: "mailto:\(trimmed)")
        }
        return nil
    }

    private static func matchedText(for match: NSTextCheckingResult, in text: String) -> String {
        guard let range = Range(match.range, in: text) else { return "" }
        return String(text[range])
    }

    private static func shouldOpenOutsideReader(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel"
    }
}

final class FrontPagePlainTextLinkDelegate: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        FrontPagePlainTextLinkifier.open(link: link)
    }
}

struct FrontPageLinkedPlainTextView: NSViewRepresentable {
    let text: String
    var searchHighlight: SearchMatchHighlight? = nil
    var font: NSFont = .systemFont(ofSize: 14)
    var foregroundColor: NSColor = OhiaColors.nsTextSecondary
    var lineSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0

    func makeNSView(context: Context) -> FrontPageLinkedPlainTextContainerView {
        let view = FrontPageLinkedPlainTextContainerView()
        view.setText(
            text,
            font: font,
            foregroundColor: foregroundColor,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            searchHighlight: searchHighlight
        )
        return view
    }

    func updateNSView(_ nsView: FrontPageLinkedPlainTextContainerView, context: Context) {
        nsView.setText(
            text,
            font: font,
            foregroundColor: foregroundColor,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            searchHighlight: searchHighlight
        )
    }
}

final class FrontPageLinkedPlainTextContainerView: NSView {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let textView: NSTextView
    private let linkDelegate = FrontPagePlainTextLinkDelegate()

    private var lastText: String?
    private var lastSearchHighlight: SearchMatchHighlight?
    private var lastFontName: String?
    private var lastFontSize: CGFloat?
    private var lastForegroundColor: NSColor?
    private var lastLineSpacing: CGFloat?
    private var lastParagraphSpacing: CGFloat?
    private var lastWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1 {
        didSet {
            if abs(oldValue - measuredHeight) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(1, measuredHeight))
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        layoutManager.usesFontLeading = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textContainer.lineFragmentPadding = 0
        textView = NSTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)

        wantsLayer = true
        FrontPagePlainTextLinkifier.configureLinkedTextView(textView, delegate: linkDelegate)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(
        _ raw: String,
        font: NSFont,
        foregroundColor: NSColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        searchHighlight: SearchMatchHighlight? = nil
    ) {
        let styleChanged = font.fontName != lastFontName
            || font.pointSize != lastFontSize
            || foregroundColor != lastForegroundColor
            || lineSpacing != lastLineSpacing
            || paragraphSpacing != lastParagraphSpacing
        guard raw != lastText
                || searchHighlight != lastSearchHighlight
                || styleChanged else { return }
        lastText = raw
        lastSearchHighlight = searchHighlight
        lastFontName = font.fontName
        lastFontSize = font.pointSize
        lastForegroundColor = foregroundColor
        lastLineSpacing = lineSpacing
        lastParagraphSpacing = paragraphSpacing
        textStorage.setAttributedString(
            FrontPagePlainTextLinkifier.attributedString(
                from: raw,
                font: font,
                foregroundColor: foregroundColor,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                searchHighlight: searchHighlight
            )
        )
        lastWidth = -1
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        recomputeIfNeeded()
    }

    private func recomputeIfNeeded() {
        let width = bounds.width
        guard width > 1 else { return }
        if abs(width - lastWidth) > 0.5 {
            lastWidth = width
            textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        measuredHeight = max(1, usedHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: measuredHeight)
    }
}

private extension String {
    func localizedCaseInsensitiveComparePrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}
