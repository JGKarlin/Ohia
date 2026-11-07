import Foundation
import OhiaIngest

enum LockReadoutBodyLoader {
    private struct Candidate {
        let path: String
        let format: LockReadoutBodyFormat
    }

    nonisolated static func load(
        htmlPath: String?,
        textPath: String?,
        rawPath: String? = nil
    ) -> LockReadoutBodyLoadResult {
        let candidates = bodyCandidates(htmlPath: htmlPath, textPath: textPath)

        var emptySource: LockReadoutBodySource?
        for candidate in candidates {
            let candidateURL = URL(fileURLWithPath: candidate.path)
            guard let data = try? Data(contentsOf: candidateURL),
                  let text = decodeEmailText(from: data) else {
                continue
            }
            let format = resolvedFormat(for: text, preferred: candidate.format)
            let baseURL = format == .html ? candidateURL.deletingLastPathComponent() : nil
            let inlineAttachments = format == .html
                ? inlineAttachments(forHTML: text, messageDirectory: baseURL)
                : [:]
            let source = LockReadoutBodySource(
                text: text,
                format: format,
                baseURL: baseURL,
                inlineAttachments: inlineAttachments
            )
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySource = emptySource ?? source
                continue
            }
            return .loaded(source)
        }

        if let rawSource = rawMessageBodySource(rawPath: rawPath) {
            return .loaded(rawSource)
        }

        if let emptySource {
            return .loaded(emptySource)
        }
        return candidates.isEmpty ? .missing : .failed
    }

    nonisolated private static func inlineAttachments(
        forHTML html: String,
        messageDirectory: URL?
    ) -> [String: LockReadoutInlineAttachment] {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil,
              let messageDirectory else {
            return [:]
        }

        let rawURL = messageDirectory.appendingPathComponent("raw.eml")
        guard let rawData = try? Data(contentsOf: rawURL),
              let parsed = try? MIMEParser.parse(data: rawData) else {
            return [:]
        }

        var attachmentsByContentID: [String: LockReadoutInlineAttachment] = [:]
        for attachment in parsed.attachments {
            guard let contentId = attachment.contentId else { continue }
            let normalizedID = LockReadoutInlineAttachment.normalizedContentID(contentId)
            guard normalizedID.isEmpty == false else { continue }
            attachmentsByContentID[normalizedID] = LockReadoutInlineAttachment(
                contentId: normalizedID,
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }
        return attachmentsByContentID
    }

    nonisolated static func decodeEmailText(from data: Data) -> String? {
        let declaredEncoding = declaredEncoding(in: data)
        let utf8Decoded = String(data: data, encoding: .utf8)

        if let declaredEncoding,
           declaredEncoding != .utf8,
           let declaredDecoded = String(data: data, encoding: declaredEncoding) {
            if let utf8Decoded {
                return preferredDecodedText(utf8: utf8Decoded, declared: declaredDecoded)
            }
            return declaredDecoded
        }

        if let utf8Decoded {
            return utf8Decoded
        }

        var encodings = declaredEncoding.map { [$0] } ?? []
        encodings.append(contentsOf: [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .iso2022JP,
            .shiftJIS,
            .japaneseEUC,
            .isoLatin1,
            .windowsCP1252
        ])

        var seen: Set<String.Encoding> = []
        for encoding in encodings where seen.insert(encoding).inserted {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }

        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func preferredDecodedText(utf8: String, declared: String) -> String {
        // Canonical body artifacts are written as UTF-8. Some HTML keeps the
        // source message's older meta charset, but a few real non-UTF-8 byte
        // sequences are also syntactically valid UTF-8. Compare the decoded
        // text rather than trusting either signal blindly.
        let utf8Score = decodedTextQualityScore(utf8)
        let declaredScore = decodedTextQualityScore(declared)
        return declaredScore > utf8Score + 2 ? declared : utf8
    }

    nonisolated private static func decodedTextQualityScore(_ text: String) -> Int {
        var score = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                score += 1
            case 0x00..<0x20, 0x7F...0x9F, 0xFFFD:
                score -= 12
            case 0x20...0x7E:
                score += 1
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF:
                score += 4
            case 0xFF66...0xFF9F:
                score += 2
            default:
                score += 0
            }
        }

        let mojibakeMarkers = ["ã", "ä", "å", "æ", "ç", "繧", "繝", "縺", "譚", "莠", "螟", "蟄", "謨"]
        for marker in mojibakeMarkers where text.contains(marker) {
            score -= 10
        }
        return score
    }

    nonisolated private static func bodyCandidates(htmlPath: String?, textPath: String?) -> [Candidate] {
        [
            htmlPath.map { Candidate(path: $0, format: .html) },
            textPath.map { Candidate(path: $0, format: .plainText) }
        ]
        .compactMap { candidate in
            guard let candidate,
                  candidate.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return candidate
        }
    }

    nonisolated private static func rawMessageBodySource(rawPath: String?) -> LockReadoutBodySource? {
        guard let rawPath,
              rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let rawURL = URL(fileURLWithPath: rawPath)
        guard let rawData = try? Data(contentsOf: rawURL),
              let parsed = try? MIMEParser.parse(data: rawData) else {
            return nil
        }

        let baseURL = rawURL.deletingLastPathComponent()
        if let htmlBody = nonEmptyBody(parsed.htmlBody) {
            return LockReadoutBodySource(
                text: htmlBody,
                format: .html,
                baseURL: baseURL,
                inlineAttachments: inlineAttachments(forHTML: htmlBody, messageDirectory: baseURL)
            )
        }
        if let textBody = nonEmptyBody(parsed.textBody ?? parsed.summarizableBodyText) {
            return LockReadoutBodySource(
                text: textBody,
                format: likelyContainsHTML(textBody) ? .html : .plainText,
                baseURL: baseURL
            )
        }
        return LockReadoutBodySource(text: "", format: .plainText, baseURL: baseURL)
    }

    nonisolated private static func resolvedFormat(
        for text: String,
        preferred: LockReadoutBodyFormat
    ) -> LockReadoutBodyFormat {
        switch preferred {
        case .html:
            return .html
        case .plainText:
            return likelyContainsHTML(text) ? .html : .plainText
        }
    }

    nonisolated private static func likelyContainsHTML(_ text: String) -> Bool {
        let sample = String(text.prefix(4096)).lowercased()
        return sample.contains("<!doctype html")
            || sample.contains("<html")
            || sample.contains("<body")
            || sample.range(
                of: #"<(p|br|div|span|table|a|strong|em|blockquote)\b"#,
                options: .regularExpression
            ) != nil
    }

    nonisolated private static func nonEmptyBody(_ value: String?) -> String? {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return value
    }

    nonisolated private static func declaredEncoding(in data: Data) -> String.Encoding? {
        let sampleData = Data(data.prefix(4096))
        guard let sample = String(data: sampleData, encoding: .ascii)
                ?? String(data: sampleData, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(
                pattern: #"(?i)charset\s*=\s*["']?([A-Za-z0-9._-]+)"#
              ) else {
            return nil
        }
        let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        guard let match = regex.firstMatch(in: sample, range: range),
              match.numberOfRanges > 1,
              let charsetRange = Range(match.range(at: 1), in: sample) else {
            return nil
        }
        return encoding(named: String(sample[charsetRange]))
    }

    nonisolated private static func encoding(named name: String) -> String.Encoding? {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacing("_", with: "-")

        switch normalized {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16":
            return .utf16
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-16be":
            return .utf16BigEndian
        case "shift-jis", "shift-jisx0213", "sjis", "cp932", "windows-31j":
            return .shiftJIS
        case "euc-jp", "eucjp":
            return .japaneseEUC
        case "iso-2022-jp":
            return .iso2022JP
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}
