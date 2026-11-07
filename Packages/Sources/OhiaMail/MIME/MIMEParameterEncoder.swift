import Foundation

public enum MIMEParameterEncoder {
    // The longer attachment disposition prefix is 33 octets. These limits
    // keep simple/fallback lines at 78 octets and folded segments below it.
    private static let maximumSimpleFallbackLength = 34
    private static let maximumContinuedFallbackLength = 33
    private static let maximumExtendedSegmentLength = 48

    public static func filenameParameters(_ filename: String) -> String {
        var cleaned = ""
        for scalar in filename.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            cleaned.unicodeScalars.append(scalar)
        }

        let ascii = asciiFallback(cleaned)
        let fallback = ascii.isEmpty ? "attachment" : ascii
        let escapedFallback = escapeQuoted(fallback)
        let encodedTokens = percentEncodedTokens(cleaned)
        let encodedValue = encodedTokens.joined()
        let requiresContinuations =
            escapedFallback.utf8.count > maximumSimpleFallbackLength
            || encodedValue.utf8.count > maximumExtendedSegmentLength

        if requiresContinuations {
            let compatibilityFallback = escapedPrefix(
                fallback,
                maximumLength: maximumContinuedFallbackLength
            )
            var result = "filename=\"\(compatibilityFallback)\""
            for (index, segment) in continuationSegments(encodedTokens).enumerated() {
                let name = index == 0 ? "filename*0*=UTF-8''" : "filename*\(index)*="
                result += ";\r\n \(name)\(segment)"
            }
            return result
        }

        var result = "filename=\"\(escapedFallback)\""

        if cleaned.unicodeScalars.contains(where: { $0.isASCII == false }) {
            result += "; filename*=UTF-8''\(encodedValue)"
        }

        return result
    }

    private static func asciiFallback(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        return result
    }

    private static func escapeQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapedPrefix(_ value: String, maximumLength: Int) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let escaped: String
            switch scalar {
            case "\\":
                escaped = "\\\\"
            case "\"":
                escaped = "\\\""
            default:
                escaped = String(scalar)
            }

            guard result.utf8.count + escaped.utf8.count <= maximumLength else {
                break
            }
            result += escaped
        }
        return result
    }

    private static func percentEncodedTokens(_ value: String) -> [String] {
        value.utf8.map { byte in
            isAttrChar(byte) ? String(Unicode.Scalar(byte)) : String(format: "%%%02X", byte)
        }
    }

    private static func continuationSegments(_ tokens: [String]) -> [String] {
        var segments: [String] = []
        var current = ""

        for token in tokens {
            if current.utf8.count + token.utf8.count > maximumExtendedSegmentLength {
                segments.append(current)
                current = token
            } else {
                current += token
            }
        }

        if current.isEmpty == false {
            segments.append(current)
        }
        return segments
    }

    private static func isAttrChar(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"),
             UInt8(ascii: "&"), UInt8(ascii: "+"), UInt8(ascii: "-"),
             UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
             UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }
}
