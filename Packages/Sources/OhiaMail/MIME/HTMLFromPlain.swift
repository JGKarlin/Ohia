import Foundation

public enum HTMLFromPlain {
    public static func convert(_ plain: String) -> String {
        let paragraphs = plain.components(separatedBy: "\n\n").map { para in
            "<p>" + linkify(escape(para)).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }.joined(separator: "\n")
        return "<html><body style=\"font: 15px -apple-system, system-ui, sans-serif; color: #222;\">"
            + paragraphs
            + "</body></html>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func linkify(_ s: String) -> String {
        let pattern = #"(https?://[^\s<>"']+|mailto:[^\s<>"']+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
        var out = s
        for m in matches {
            var range = m.range
            var url = ns.substring(with: range)
            while let last = url.last, ".,;:!?)".contains(last) {
                url = String(url.dropLast())
                range = NSRange(location: range.location, length: range.length - 1)
            }
            let replacement = "<a href=\"" + url + "\">" + url + "</a>"
            let outNS = out as NSString
            out = outNS.replacingCharacters(in: range, with: replacement)
        }
        return out
    }
}
