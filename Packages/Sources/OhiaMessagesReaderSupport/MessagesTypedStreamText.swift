import Foundation

/// Best-effort plain-text extraction from Messages' undocumented
/// `attributedBody` typedstream archive. It never throws and returns `nil`
/// when the archive contains no recognizable message text.
public enum MessagesTypedStreamText {
    private static let startPattern: (UInt8, UInt8) = (0x01, 0x2B)
    private static let endPattern: (UInt8, UInt8) = (0x86, 0x84)
    private static let attachmentPlaceholder: Character = "\u{FFFC}"
    private static let appMessagePlaceholder: Character = "\u{FFFD}"

    public static func extractPlainText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        var segments: [String] = []
        var cursor = 0
        while let run = nextRun(in: bytes, from: cursor) {
            cursor = run.nextCursor
            let cleaned = substitutingPlaceholders(run.text)
            guard isLikelyContent(cleaned) else { continue }
            segments.append(cleaned)
        }
        guard !segments.isEmpty else { return nil }
        let joined = segments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private struct Run {
        let text: String
        let nextCursor: Int
    }

    private static func nextRun(in bytes: [UInt8], from start: Int) -> Run? {
        guard let startIndex = index(of: startPattern, in: bytes, from: start) else {
            return nil
        }
        let contentStart = startIndex + 2
        guard let endIndex = index(of: endPattern, in: bytes, from: contentStart) else {
            return nil
        }
        let (decoded, dropCount) = decode(bytes[contentStart..<endIndex])
        return Run(
            text: String(decoded.dropFirst(dropCount)),
            nextCursor: endIndex + 2
        )
    }

    private static func index(
        of pattern: (UInt8, UInt8),
        in bytes: [UInt8],
        from start: Int
    ) -> Int? {
        guard start >= 0, bytes.count >= 2 else { return nil }
        var index = start
        let limit = bytes.count - 2
        while index <= limit {
            if bytes[index] == pattern.0, bytes[index + 1] == pattern.1 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func decode(_ slice: ArraySlice<UInt8>) -> (String, Int) {
        if let valid = String(bytes: slice, encoding: .utf8) {
            return (valid, 1)
        }
        return (String(decoding: slice, as: UTF8.self), 3)
    }

    private static let nonContentExact: Set<String> = [
        "streamtyped", "NSObject", "NSString", "NSMutableString",
        "NSAttributedString", "NSMutableAttributedString", "NSDictionary",
        "NSMutableDictionary", "NSArray", "NSMutableArray", "NSNumber",
        "NSValue", "NSData", "NSMutableData", "NSURL", "NSUUID", "NSDate",
        "NSColor", "NSFont", "NSParagraphStyle",
    ]
    private static let nonContentPrefixes = ["__kIM", "__kIC"]

    private static func isLikelyContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !nonContentExact.contains(trimmed) else { return false }
        guard !nonContentPrefixes.contains(where: trimmed.hasPrefix) else { return false }
        return trimmed.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func substitutingPlaceholders(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case attachmentPlaceholder:
                result += "[attachment]"
            case appMessagePlaceholder:
                result += "[app message]"
            default:
                result.append(character)
            }
        }
        return result
    }
}
