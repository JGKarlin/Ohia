// MIMEHeaderDecoder.swift
// RFC 2047 "encoded-word" decoder for email headers. Subject lines and
// display-name phrases that contain non-ASCII characters arrive on the
// wire in this format:
//
//     =?<charset>?<B|Q>?<encoded-bytes>?=
//
// where charset is any IANA name (UTF-8, ISO-2022-JP, Shift_JIS, GB2312,
// KOI8-R, Windows-1251, …), and the bytes are either base64 (B) or
// quoted-printable (Q). Unrendered, these strings are unreadable; the
// hover popup, lock readout, and any other surface that displays
// header-derived text needs them decoded back to human-readable strings.
//
// The decoder is deliberately language-agnostic: charset bytes go through
// `MIMECharsetDecoder`, which uses Foundation's charset table plus narrow
// mailer-family fallbacks for common aliases. There are no English- or
// UTF-8-only shortcuts. Malformed or unknown encoded-words are passed through
// unchanged rather than dropped — the policy is "show what we have" over
// "lose information silently."
//
// Whitespace between two adjacent encoded-words is collapsed (RFC 2047
// §6.2). Mixed encoded-and-plain-text segments are preserved verbatim
// in their plain-text portions.

import Foundation

public enum MIMEHeaderDecoder {

    /// Decode every RFC 2047 encoded-word inside `input` and return the
    /// reconstructed string. Strings that contain no encoded-words are
    /// returned unchanged.
    public static func decodeEncodedWords(_ input: String) -> String {
        // Regex matches `=?CHARSET?ENC?TEXT?=` where CHARSET / ENC / TEXT
        // each contain only characters legal for an encoded-word body
        // (no whitespace, no `?`). Greedy matching is fine because `?=`
        // is the unambiguous terminator.
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        var previousMatchWasEncoded = false

        for match in matches {
            let between = ns.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            // Per RFC 2047 §6.2: whitespace separating two consecutive
            // encoded-words is invisible. Otherwise, append the gap
            // verbatim — it might be intentional plain text.
            if previousMatchWasEncoded, between.allSatisfy(\.isWhitespaceOrNewline) {
                // skip
            } else {
                result.append(between)
            }

            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let encodedText = ns.substring(with: match.range(at: 3))

            if let decoded = decodeWord(charset: charset, encoding: encoding, text: encodedText) {
                result.append(decoded)
                previousMatchWasEncoded = true
            } else {
                // Pass the raw word through — the user sees garbled text
                // but at least no information is dropped.
                result.append(ns.substring(with: match.range))
                previousMatchWasEncoded = false
            }

            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(ns.substring(from: cursor))
        }
        return result
    }

    // MARK: - Word decoding

    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        let bytes: Data?
        switch encoding {
        case "B":
            // Tolerate missing or extra `=` padding at the end — some
            // mailers emit non-canonical base64.
            let padded = padBase64(text)
            bytes = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
        case "Q":
            bytes = qDecode(text)
        default:
            return nil
        }
        guard let bytes else { return nil }
        return MIMECharsetDecoder.decode(bytes, charset: charset)
    }

    /// Quoted-printable decode for the Q variant of encoded-words.
    /// Differences from generic QP: `_` represents 0x20 (space), and the
    /// encoded text is byte-oriented — the resulting bytes are then
    /// interpreted using the encoded-word's declared charset.
    private static func qDecode(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "_":
                bytes.append(0x20)
            case "=":
                guard let h1 = iterator.next(), let h2 = iterator.next(),
                      let value = UInt8(String(h1) + String(h2), radix: 16) else {
                    return nil
                }
                bytes.append(value)
            default:
                guard scalar.isASCII, let v = scalar.asciiValue else { return nil }
                bytes.append(v)
            }
        }
        return Data(bytes)
    }

    private static func padBase64(_ text: String) -> String {
        // base64 strings whose length is not a multiple of 4 must be
        // padded with `=` to decode cleanly via Foundation.
        let stripped = text.replacingOccurrences(of: "=", with: "")
        let pad = (4 - stripped.count % 4) % 4
        return stripped + String(repeating: "=", count: pad)
    }

}

private extension Character {
    var isWhitespaceOrNewline: Bool {
        isWhitespace || isNewline
    }
}

private extension Unicode.Scalar {
    var asciiValue: UInt8? {
        guard isASCII else { return nil }
        return UInt8(value)
    }
}
