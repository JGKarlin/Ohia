import Foundation

public enum QuotedPrintable {
    /// Encode `s` as RFC 2045 quoted-printable. Line breaks LF in input, CRLF in output.
    /// Soft line breaks (`=\r\n`) inserted to keep lines ≤ 76 chars. Lines with trailing
    /// whitespace have the whitespace byte escaped (per spec).
    public static func encode(_ s: String) -> String {
        var lines: [String] = []
        for rawLine in s.components(separatedBy: "\n") {
            lines.append(encodeLine(rawLine))
        }
        return lines.joined(separator: "\r\n")
    }

    private static func encodeLine(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var out: [String] = []
        var current = ""
        for (idx, b) in bytes.enumerated() {
            let encoded = encodeByte(b, isTrailingWS: isTrailingWhitespace(bytes: bytes, at: idx))
            if current.count + encoded.count > 75 {
                out.append(current + "=")
                current = ""
            }
            current += encoded
        }
        out.append(current)
        return out.joined(separator: "\r\n")
    }

    private static func encodeByte(_ b: UInt8, isTrailingWS: Bool) -> String {
        let isPrintable = (b >= 0x21 && b <= 0x7E) && b != 0x3D
        if b == 0x20 || b == 0x09 {
            return isTrailingWS ? String(format: "=%02X", b) : String(UnicodeScalar(b))
        }
        return isPrintable ? String(UnicodeScalar(b)) : String(format: "=%02X", b)
    }

    private static func isTrailingWhitespace(bytes: [UInt8], at idx: Int) -> Bool {
        // Whitespace at very end of an input-line (i.e. last byte in the `bytes` array).
        guard bytes[idx] == 0x20 || bytes[idx] == 0x09 else { return false }
        return idx == bytes.count - 1
    }
}
