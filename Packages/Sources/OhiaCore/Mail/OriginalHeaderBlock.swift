import Foundation

/// The header block a mail client writes above an embedded original message
/// ("From: … / Sent: … / To: … / Subject: …"), in the languages clients
/// localize it into. Outlook writes it in its interface language ("发件人:",
/// "差出人：", "Von:", "De :"), so an English-only reading leaves the original
/// under the reply and attributes its text to the reply's sender.
///
/// A block starts at a From line followed within six lines by another field
/// of the same language, so prose that opens lines with a short word a header
/// uses ("De: Paris", "A: Lyon") never reads as a header. A rule of
/// underscores directly above the block (Outlook's separator) is part of it.
public enum OriginalHeaderBlock: Sendable {
    public enum Field: Sendable, Equatable { case from, sent, to, cc, subject }

    private struct Language {
        let from: Set<String>
        let sent: Set<String>
        let to: Set<String>
        let cc: Set<String>
        let subject: Set<String>

        func field(named name: String) -> Field? {
            if from.contains(name) { return .from }
            if sent.contains(name) { return .sent }
            if to.contains(name) { return .to }
            if cc.contains(name) || name == "cc" || name == "bcc" { return .cc }
            if subject.contains(name) { return .subject }
            return nil
        }
    }

    /// Field names per language, compared case-insensitively with diacritics
    /// kept ("À" is French for To; "A" is Italian). "Cc"/"Bcc" are shared.
    private static let languages: [Language] = [
        // English
        Language(from: ["from"], sent: ["sent", "date"], to: ["to"], cc: ["bcc", "reply-to"], subject: ["subject"]),
        // Chinese (simplified)
        Language(from: ["发件人"], sent: ["发送时间", "发送日期", "日期", "时间"], to: ["收件人"], cc: ["抄送"], subject: ["主题"]),
        // Chinese (traditional)
        Language(from: ["寄件者", "寄件人"], sent: ["寄件日期", "傳送時間", "傳送日期", "日期", "時間"], to: ["收件者", "收件人"],
                 cc: ["副本", "抄送"], subject: ["主旨", "主題"]),
        // Japanese
        Language(from: ["差出人", "送信者"], sent: ["送信日時", "送信日", "日付", "日時"], to: ["宛先"], cc: [], subject: ["件名"]),
        // Korean
        Language(from: ["보낸 사람", "보낸사람"], sent: ["보낸 날짜", "보낸날짜", "날짜"], to: ["받는 사람", "받는사람"],
                 cc: ["참조"], subject: ["제목"]),
        // German
        Language(from: ["von"], sent: ["gesendet", "datum"], to: ["an"], cc: ["kopie"], subject: ["betreff"]),
        // French
        Language(from: ["de"], sent: ["envoyé", "envoye", "date"], to: ["à"], cc: [], subject: ["objet"]),
        // Spanish
        Language(from: ["de"], sent: ["enviado", "enviado el", "fecha"], to: ["para"], cc: [], subject: ["asunto"]),
        // Italian
        Language(from: ["da"], sent: ["inviato", "data"], to: ["a"], cc: [], subject: ["oggetto"]),
        // Portuguese
        Language(from: ["de"], sent: ["enviada", "enviada em", "enviado", "enviado em", "data"], to: ["para"], cc: [],
                 subject: ["assunto"]),
        // Dutch
        Language(from: ["van"], sent: ["verzonden", "datum"], to: ["aan"], cc: [], subject: ["onderwerp"]),
        // Russian
        Language(from: ["от"], sent: ["отправлено", "дата"], to: ["кому"], cc: ["копия"], subject: ["тема"]),
        // Swedish
        Language(from: ["från"], sent: ["skickat", "datum"], to: ["till"], cc: ["kopia"], subject: ["ämne"]),
        // Danish and Norwegian
        Language(from: ["fra"], sent: ["sendt", "dato"], to: ["til"], cc: ["kopi"], subject: ["emne"]),
        // Polish
        Language(from: ["od"], sent: ["wysłano", "data"], to: ["do"], cc: ["dw"], subject: ["temat"]),
        // Turkish
        Language(from: ["kimden", "gönderen"], sent: ["gönderildi", "tarih"], to: ["kime"], cc: ["bilgi"], subject: ["konu"]),
    ]

    /// The longest field name read: a colon later in the line is prose.
    private static let maximumNameLength = 12
    private static let lookahead = 6

    /// The field name before the line's first colon (ASCII or full-width),
    /// lowercased, with bold markers and a French space before the colon
    /// removed, and the value after it. Nil when the line has no short name
    /// before a colon.
    static func nameAndValue(_ line: String) -> (name: String, value: String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("*") { text.removeFirst() }
        guard let colon = text.prefix(maximumNameLength + 3).firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = text[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*")))
        guard !name.isEmpty, name.count <= maximumNameLength else { return nil }
        var value = text[text.index(after: colon)...]
        while value.first == "*" { value.removeFirst() }
        return (name.lowercased(), value.trimmingCharacters(in: .whitespaces))
    }

    static func fieldName(_ line: String) -> String? { nameAndValue(line)?.name }

    /// The header field `line` carries, in any language, with its value.
    public static func field(_ line: String) -> (field: Field, value: String)? {
        guard let parsed = nameAndValue(line) else { return nil }
        for language in languages {
            if let field = language.field(named: parsed.name) { return (field, parsed.value) }
        }
        return nil
    }

    /// Whether `line` is a header field of any language (a From line or one
    /// of the fields that follow it), read outside a block. A one- or
    /// two-letter Latin name ("A:", "De:", "Do:") is a header only inside a
    /// block `starts` found: on its own it is as likely an inline "A: yes".
    /// Chinese, Japanese and Korean names ("件名", "宛先") are never words.
    public static func isHeaderLine(_ line: String) -> Bool {
        guard let parsed = nameAndValue(line) else { return false }
        if parsed.name.count <= 2, parsed.name.allSatisfy(\.isASCII), parsed.name != "to", parsed.name != "cc" {
            return false
        }
        return languages.contains { $0.field(named: parsed.name) != nil }
    }

    /// Whether the line at `index` starts an embedded original's header block.
    public static func starts(lines: [String], at index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        if isSeparatorRule(lines[index]) {
            // Outlook's rule sits directly above the block.
            guard let next = lines.indices.dropFirst(index + 1).first(where: {
                !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }), next <= index + 2 else { return false }
            return fromLineStartsBlock(lines: lines, index: next)
        }
        return fromLineStartsBlock(lines: lines, index: index)
    }

    /// A short Latin From name ("De", "Da", "Od", "Von") also opens prose
    /// ("De: Madrid / Para: Barcelona"), so it needs two more fields of its
    /// language; a real header block has at least three.
    private static func fromLineStartsBlock(lines: [String], index: Int) -> Bool {
        guard let name = fieldName(lines[index]) else { return false }
        let candidates = languages.filter { $0.from.contains(name) }
        guard !candidates.isEmpty else { return false }
        let required = name.count <= 3 && name.allSatisfy(\.isASCII) ? 2 : 1
        let following = lines.dropFirst(index + 1).prefix(lookahead).compactMap(fieldName)
        return candidates.contains { language in
            following.filter { language.field(named: $0).map { $0 != .from } ?? false }.count >= required
        }
    }

    /// A line of at least ten underscores and nothing else.
    public static func isSeparatorRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 10 && trimmed.allSatisfy { $0 == "_" }
    }
}
