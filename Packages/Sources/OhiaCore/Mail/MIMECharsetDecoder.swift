import Foundation

/// Shared MIME charset decoder for message bodies, RFC 2047 encoded-words, and
/// RFC 2231 parameter values. The policy is strict-first: honor the declared
/// charset through Foundation, then use only closely related aliases/fallbacks
/// for mailer families known to label the same byte stream differently.
public enum MIMECharsetDecoder {
    public static func decode(_ data: Data, charset: String) -> String? {
        let normalized = normalizedCharsetName(charset)
        guard !normalized.isEmpty else {
            return String(data: data, encoding: .ascii)
        }

        let encodings = candidateEncodings(for: normalized)
        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }

        if isISO2022JPCharset(normalized),
           let decoded = decodeISO2022JPTextLossy(data, allowsReplacement: false) {
            return decoded
        }

        return nil
    }

    public static func decodeBestEffortText(_ data: Data, declaredCharset: String?) -> String? {
        if let decoded = decodeUnicodeBOM(data) {
            return decoded
        }

        if let declaredCharset,
           !normalizedCharsetName(declaredCharset).isEmpty,
           let decoded = decode(data, charset: declaredCharset) {
            return decoded
        }
        if let declaredCharset,
           isISO2022JPCharset(normalizedCharsetName(declaredCharset)),
           let decoded = decodeISO2022JPTextLossy(data, allowsReplacement: true) {
            return decoded
        }

        for fallback in ["utf-8", "windows-1252", "iso-8859-1"] {
            if let decoded = decode(data, charset: fallback) {
                return decoded
            }
        }
        return nil
    }

    public static func isKnownCharset(_ name: String) -> Bool {
        !candidateEncodings(for: normalizedCharsetName(name)).isEmpty
    }

    public static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        candidateEncodings(for: normalizedCharsetName(name)).first
    }

    public static func normalizedCharsetName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func candidateEncodings(for normalized: String) -> [String.Encoding] {
        guard !normalized.isEmpty else { return [.ascii] }

        let namedCandidates: [String]
        switch normalized {
        case "utf-8", "utf8":
            return [.utf8]
        case "us-ascii", "ascii":
            return [.ascii]
        case "iso-8859-1", "latin1", "latin-1":
            return [.isoLatin1]
        case "windows-1252", "cp1252":
            return [.windowsCP1252]
        case _ where isISO2022JPCharset(normalized):
            return [.iso2022JP]
        case _ where windowsJapaneseAliases.contains(normalized):
            namedCandidates = prefersWindowsJapaneseFirst(normalized)
                ? ["windows-31j", "shift-jis"]
                : ["shift-jis", "windows-31j"]
        case _ where simplifiedChineseAliases.contains(normalized):
            namedCandidates = simplifiedChineseCandidates(for: normalized)
        case _ where big5Aliases.contains(normalized):
            namedCandidates = normalized == "big5-hkscs" || normalized == "x-big5-hkscs"
                ? ["big5-hkscs", "big5"]
                : ["big5", "big5-hkscs"]
        default:
            namedCandidates = [normalized]
        }

        var seen = Set<UInt>()
        var encodings: [String.Encoding] = []
        for name in namedCandidates {
            guard let encoding = coreFoundationEncoding(forIANAName: name),
                  seen.insert(encoding.rawValue).inserted else {
                continue
            }
            encodings.append(encoding)
        }
        return encodings
    }

    private static func coreFoundationEncoding(forIANAName name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    private static func simplifiedChineseCandidates(for normalized: String) -> [String] {
        switch normalized {
        case "gb18030":
            return ["gb18030"]
        case "gbk", "cp936", "windows-936", "ms936":
            return ["gbk", "gb18030"]
        default:
            return ["gb2312", "gbk", "gb18030"]
        }
    }

    private static func prefersWindowsJapaneseFirst(_ normalized: String) -> Bool {
        switch normalized {
        case "windows-31j", "windows-932", "cp932", "ms-kanji", "mskanji", "x-ms-cp932":
            return true
        default:
            return false
        }
    }

    private static func decodeUnicodeBOM(_ data: Data) -> String? {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// Outlook / Exchange Japanese mail sometimes declares ISO-2022-JP while
    /// embedding Windows/CP932 extension pairs such as JIS `0x7C62` for `髙`.
    /// Foundation then rejects the whole body. Decode valid runs normally and
    /// map those extension pairs through Shift_JIS so one bad display-name
    /// character does not turn an entire readable message into ESC sequences.
    private static func decodeISO2022JPTextLossy(_ data: Data, allowsReplacement: Bool) -> String? {
        let bytes = Array(data)
        guard bytes.contains(0x1B) else { return nil }

        enum Mode {
            case ascii
            case jis0208
            case katakana
        }

        var mode = Mode.ascii
        var index = 0
        var result = ""
        var decodedPairCache: [UInt16: String] = [:]
        var undecodablePairs = Set<UInt16>()
        result.reserveCapacity(bytes.count)

        func appendReplacement() -> Bool {
            guard allowsReplacement else { return false }
            result.append("\u{FFFD}")
            return true
        }

        func appendASCIIByte(_ byte: UInt8) {
            if let scalar = UnicodeScalar(Int(byte)) {
                result.unicodeScalars.append(scalar)
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                guard index + 2 < bytes.count else {
                    guard appendReplacement() else { return nil }
                    index += 1
                    continue
                }
                let first = bytes[index + 1]
                let second = bytes[index + 2]
                if first == 0x24, second == 0x40 || second == 0x42 {
                    mode = .jis0208
                    index += 3
                    continue
                }
                if first == 0x28 {
                    switch second {
                    case 0x42, 0x4A:
                        mode = .ascii
                    case 0x49:
                        mode = .katakana
                    default:
                        mode = .ascii
                    }
                    index += 3
                    continue
                }
                let skipLength = first == 0x24 && second == 0x28 && index + 3 < bytes.count ? 4 : 3
                guard appendReplacement() else { return nil }
                index += skipLength
                continue
            }

            switch mode {
            case .ascii:
                appendASCIIByte(byte)
                index += 1

            case .katakana:
                if (0x21...0x5F).contains(byte),
                   let scalar = UnicodeScalar(0xFF61 + Int(byte - 0x21)) {
                    result.unicodeScalars.append(scalar)
                } else if byte == 0x0D || byte == 0x0A || byte == 0x09 {
                    appendASCIIByte(byte)
                } else {
                    guard appendReplacement() else { return nil }
                }
                index += 1

            case .jis0208:
                if byte == 0x0D || byte == 0x0A || byte == 0x09 {
                    appendASCIIByte(byte)
                    index += 1
                    continue
                }
                guard index + 1 < bytes.count, bytes[index + 1] != 0x1B else {
                    guard appendReplacement() else { return nil }
                    index += 1
                    continue
                }
                let pair = (lead: byte, trail: bytes[index + 1])
                let pairKey = UInt16(pair.lead) << 8 | UInt16(pair.trail)
                if let decoded = decodedPairCache[pairKey] {
                    result.append(decoded)
                } else if undecodablePairs.contains(pairKey) {
                    guard appendReplacement() else { return nil }
                } else if let decoded = decodeJIS0208Pair(pair) ?? decodeCP932ExtensionJISPair(pair) {
                    decodedPairCache[pairKey] = decoded
                    result.append(decoded)
                } else {
                    undecodablePairs.insert(pairKey)
                    guard appendReplacement() else { return nil }
                }
                index += 2
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func decodeJIS0208Pair(_ pair: (lead: UInt8, trail: UInt8)) -> String? {
        guard (0x21...0x7E).contains(pair.lead),
              (0x21...0x7E).contains(pair.trail) else {
            return nil
        }
        let wrapped = Data([0x1B, 0x24, 0x42, pair.lead, pair.trail, 0x1B, 0x28, 0x42])
        return String(data: wrapped, encoding: .iso2022JP)
    }

    private static func decodeCP932ExtensionJISPair(_ pair: (lead: UInt8, trail: UInt8)) -> String? {
        guard (0x21...0x7E).contains(pair.lead),
              (0x21...0x7E).contains(pair.trail) else {
            return nil
        }

        let lead = Int(pair.lead)
        let trail = Int(pair.trail)
        let shiftLead = ((lead + 1) >> 1) + (lead < 0x5F ? 0x70 : 0xB0)
        let shiftTrail = trail + (lead.isMultiple(of: 2) ? 0x7E : (trail < 0x60 ? 0x1F : 0x20))
        guard shiftLead <= 0xFF, shiftTrail <= 0xFF else { return nil }

        let data = Data([UInt8(shiftLead), UInt8(shiftTrail)])
        guard let decoded = String(data: data, encoding: .shiftJIS),
              !decoded.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else {
            return nil
        }
        return decoded
    }

    private static func isISO2022JPCharset(_ normalized: String) -> Bool {
        iso2022JPCharsetAliases.contains(normalized)
    }

    private static let iso2022JPCharsetAliases: Set<String> = [
        "iso-2022-jp",
        "iso2022jp",
        "csiso2022jp",
        "iso-2022-jp-ms",
        "cp50220",
        "cp50221",
        "cp50222",
        "windows-50220",
        "windows-50221",
        "windows-50222"
    ]

    private static let windowsJapaneseAliases: Set<String> = [
        "shift-jis",
        "shiftjis",
        "sjis",
        "x-sjis",
        "windows-31j",
        "windows-932",
        "cp932",
        "ms-kanji",
        "mskanji",
        "x-ms-cp932"
    ]

    private static let simplifiedChineseAliases: Set<String> = [
        "gb2312",
        "gb-2312",
        "csiso58gb231280",
        "gbk",
        "cp936",
        "windows-936",
        "ms936",
        "gb18030"
    ]

    private static let big5Aliases: Set<String> = [
        "big5",
        "csbig5",
        "big5-hkscs",
        "x-big5-hkscs"
    ]
}
