import Foundation

struct ComposerRetrievalPayload {
    let from: String?
    let subject: String?
    let title: String?
    let body: String

    static func parse(_ payload: String) -> ComposerRetrievalPayload {
        var from: String?
        var subject: String?
        var title: String?
        var bodyLines: [String] = []
        var bodyStarted = false

        for subsequence in payload.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(subsequence)
            if bodyStarted {
                bodyLines.append(line)
                continue
            }

            if let value = value(in: line, prefix: "FROM:") {
                from = value
            } else if let value = value(in: line, prefix: "SUBJECT:") {
                subject = value
            } else if let value = value(in: line, prefix: "ATTACHMENT_EVIDENCE_CARD:") {
                title = value
            } else if let value = bodyValue(in: line) {
                bodyLines.append(value)
                bodyStarted = true
            }
        }

        let body = bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ComposerRetrievalPayload(
            from: from,
            subject: subject,
            title: title,
            body: body
        )
    }

    private static func value(in line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bodyValue(in line: String) -> String? {
        for prefix in ["BODY:", "BODY_PREVIEW:", "ATTACHMENT_TEXT:", "SUMMARY:"] {
            if let value = value(in: line, prefix: prefix) {
                return value
            }
        }
        return nil
    }
}
