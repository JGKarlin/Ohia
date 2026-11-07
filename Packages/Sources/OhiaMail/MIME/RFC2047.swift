import Foundation

public enum RFC2047 {
    /// Encode a header word. ASCII-safe strings return unchanged; otherwise Q-encoded UTF-8
    /// split into encoded-words of at most 75 characters, each holding a whole number of
    /// characters.
    public static func encodeWord(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII && $0 != "=" && $0 != "?" && $0 != "_" }) {
            return s
        }
        let prefix = "=?UTF-8?Q?"
        let suffix = "?="
        // RFC 2047 §2: an encoded-word may not exceed 75 characters including
        // the charset/encoding prefix and the `?=` terminator.
        let chunkMax = 75 - prefix.count - suffix.count

        // RFC 2047 §5: "Each 'encoded-word' MUST represent an integral number of
        // characters. A multi-octet character may not be split across adjacent
        // 'encoded-word's." The unit of chunking is therefore one scalar's worth
        // of encoded output — never a raw byte, and never a bare `=XX` escape.
        // Splitting mid-character strands continuation bytes on both sides of the
        // boundary, and every conforming decoder then rejects both words: the
        // recipient sees the raw `=?UTF-8?Q?…?=` source instead of the subject.
        var chunks: [String] = []
        var current = ""
        for scalar in s.unicodeScalars {
            // A scalar is at most 4 UTF-8 bytes → 12 encoded characters, so a
            // piece always fits inside chunkMax and can never be stranded.
            let piece = qpEncode(Array(String(scalar).utf8))
            if current.count + piece.count > chunkMax {
                chunks.append(prefix + current + suffix)
                current = piece
            } else {
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(prefix + current + suffix) }
        return chunks.joined(separator: " ")
    }

    /// Encode a display-name "phrase" for From/To headers. Quote if it contains specials.
    public static func encodePhrase(_ s: String) -> String {
        // A period is not an atom character in a display-name phrase
        // (RFC 5322 §§3.2.3, 3.2.5). An initial such as "G." must be inside
        // a quoted-string; unquoted periods are receive-only obsolete syntax.
        let needsQuote = s.contains(where: { "().,:;<>@[\\]\"".contains($0) })
        let encoded = encodeWord(s)
        if needsQuote && encoded == s {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return encoded
    }

    // MARK: - Private

    private static func qpEncode(_ bytes: [UInt8]) -> String {
        var out = ""
        for b in bytes {
            if (b >= 0x21 && b <= 0x7E) && b != 0x3D && b != 0x3F && b != 0x5F && b != 0x20 {
                out.append(Character(UnicodeScalar(b)))
            } else if b == 0x20 {
                out.append("_")
            } else {
                out.append(String(format: "=%02X", b))
            }
        }
        return out
    }
}
