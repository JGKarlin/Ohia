import Foundation

/// Pure tokenizer that splits a paragraph into a flowable sequence of
/// text and `[N]` citation tokens for inline rendering.
///
/// The output preserves visual order. Latin runs are split on whitespace
/// so each word + its trailing whitespace becomes one wrap-friendly token;
/// CJK / Hangul / fullwidth characters become single-character tokens
/// because they have no inter-word whitespace and must be allowed to wrap
/// per character. Markers `[N]` whose rank falls outside `1...sourceCount`
/// are kept as literal text so the user sees what didn't resolve instead
/// of a silent gap.
public enum InlineCitationToken: Equatable, Sendable {
    case text(String)
    case citation(Int)
}

public enum InlineCitationParser {
    private static let pattern = try! NSRegularExpression(pattern: "\\[(-?\\d+)\\]")

    public static func parse(_ paragraph: String, sourceCount: Int) -> [InlineCitationToken] {
        guard !paragraph.isEmpty else { return [] }
        let runs = splitMarkers(paragraph, sourceCount: sourceCount)
        var tokens: [InlineCitationToken] = []
        for run in runs {
            switch run {
            case .citation(let n):
                tokens.append(.citation(n))
            case .text(let s):
                tokens.append(contentsOf: tokenizeText(s))
            }
        }
        return tokens
    }

    private enum RawRun {
        case text(String)
        case citation(Int)
    }

    private static func splitMarkers(_ paragraph: String, sourceCount: Int) -> [RawRun] {
        let ns = paragraph as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var cursor = 0
        var runs: [RawRun] = []
        pattern.enumerateMatches(in: paragraph, range: fullRange) { match, _, _ in
            guard let match else { return }
            let r = match.range
            if r.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                runs.append(.text(chunk))
            }
            let nString = ns.substring(with: match.range(at: 1))
            if let n = Int(nString), sourceCount > 0, n >= 1, n <= sourceCount {
                runs.append(.citation(n))
            } else {
                runs.append(.text(ns.substring(with: r)))
            }
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            runs.append(.text(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))))
        }
        return runs
    }

    private static func tokenizeText(_ s: String) -> [InlineCitationToken] {
        guard !s.isEmpty else { return [] }
        var out: [InlineCitationToken] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                out.append(.text(current))
                current = ""
            }
        }

        // Glue whitespace onto the preceding text token (Latin word or CJK
        // char). Keeps spaces from starting their own line at wrap points
        // and reflects what the eye reads as one breakable unit.
        func attachWhitespaceToPrevious(_ ch: Character) {
            if !current.isEmpty {
                current.append(ch)
                flush()
            } else if let last = out.last, case .text(let lastText) = last {
                out[out.count - 1] = .text(lastText + String(ch))
            } else {
                current.append(ch)
                flush()
            }
        }

        for ch in s {
            if ch.isInlineCJKBreakable {
                flush()
                out.append(.text(String(ch)))
            } else if ch.isWhitespace || ch.isNewline {
                attachWhitespaceToPrevious(ch)
            } else {
                current.append(ch)
            }
        }
        flush()
        return out
    }
}

extension Character {
    fileprivate var isInlineCJKBreakable: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3040...0x309F).contains(v)   // Hiragana
            || (0x30A0...0x30FF).contains(v)   // Katakana
            || (0x3400...0x4DBF).contains(v)   // CJK Extension A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
            || (0xAC00...0xD7AF).contains(v)   // Hangul Syllables
            || (0xFF00...0xFFEF).contains(v)   // Halfwidth and Fullwidth Forms
            || (0x3000...0x303F).contains(v)   // CJK Symbols and Punctuation
    }
}
