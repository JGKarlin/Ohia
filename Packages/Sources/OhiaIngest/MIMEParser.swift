import Foundation
import OhiaCore

/// RFC 5322 header and multipart MIME body parser.
///
/// Handles plain text emails, multipart/alternative, multipart/mixed,
/// nested multipart, base64 and quoted-printable transfer encodings,
/// header continuation lines, and both CRLF and LF line endings.
public enum MIMEParser {

    // MARK: - Public entry point

    /// Parses raw RFC 5322 email data into a structured `ParsedEmail`.
    public static func parse(data: Data) throws -> ParsedEmail {
        let (headerData, bodyData) = splitHeadersAndBody(data: data)
        let headers = parseHeaders(headerData)

        var textBody: String?
        var htmlBody: String?
        var attachments: [ParsedAttachment] = []

        let contentTypeValue = headers.first {
            $0.name.lowercased() == "content-type"
        }?.value ?? "text/plain"

        if let boundary = extractBoundary(from: contentTypeValue) {
            // Multipart message — split and process each part.
            let parts = splitMultipart(data: bodyData, boundary: boundary)
            processMultipartParts(
                parts,
                contentType: contentTypeValue,
                textBody: &textBody,
                htmlBody: &htmlBody,
                attachments: &attachments
            )
        } else {
            // Simple single-part message.
            let encoding = headers.first {
                $0.name.lowercased() == "content-transfer-encoding"
            }?.value
            let ct = contentTypeValue.lowercased()
            if canonicalMediaType(ct) == "text/calendar" {
                let disposition = headers.first {
                    $0.name.lowercased() == "content-disposition"
                }?.value ?? ""
                let filename = extractFilename(
                    from: contentTypeValue,
                    disposition: disposition
                ) ?? "invite.ics"
                let dispositionToken = disposition
                    .components(separatedBy: ";")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let contentID = headers.first {
                    $0.name.lowercased() == "content-id"
                }?.value
                attachments.append(
                    ParsedAttachment(
                        filename: filename,
                        mimeType: "text/calendar",
                        data: decodeBody(bodyData, encoding: encoding),
                        contentId: contentID,
                        dispositionIsInline: dispositionToken == "inline"
                    )
                )
            } else if ct.hasPrefix("text/html") {
                htmlBody = decodeTextBody(
                    bodyData,
                    contentType: contentTypeValue,
                    transferEncoding: encoding
                )
            } else if textBodyRole(for: contentTypeValue) != .nonBody {
                textBody = decodeTextBody(
                    bodyData,
                    contentType: contentTypeValue,
                    transferEncoding: encoding
                )
            }
        }

        return ParsedEmail(
            headers: headers,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: uniquelyNamedAttachments(attachments),
            rawData: data
        )
    }

    /// MIME permits separate parts to reuse the same display filename, but
    /// the canonical attachment store uses that filename as its path. Give
    /// colliding parts stable source-order suffixes so later parts cannot
    /// overwrite earlier bytes or any of their derived artifacts.
    private static func uniquelyNamedAttachments(
        _ attachments: [ParsedAttachment]
    ) -> [ParsedAttachment] {
        var usedStoragePaths: Set<String> = []

        return attachments.map { attachment in
            var candidate = attachment.filename
            var ordinal = 2
            while storagePathCollisionKeys(candidate).isDisjoint(with: usedStoragePaths) == false {
                candidate = filename(attachment.filename, appendingOrdinal: ordinal)
                ordinal += 1
            }
            usedStoragePaths.formUnion(storagePathCollisionKeys(candidate))
            guard candidate != attachment.filename else { return attachment }
            return ParsedAttachment(
                filename: candidate,
                mimeType: attachment.mimeType,
                data: attachment.data,
                contentId: attachment.contentId,
                dispositionIsInline: attachment.dispositionIsInline
            )
        }
    }

    private static func storagePathCollisionKeys(_ filename: String) -> Set<String> {
        let safeFilename = CanonicalStore.sanitizeAttachmentFilename(filename)
        return Set([
            safeFilename,
            safeFilename + ".txt",
            safeFilename + ".embedding.txt",
            safeFilename + ".ir.json",
            safeFilename + ".rag.json"
        ].map(storageCollisionKey))
    }

    private static func storageCollisionKey(_ filename: String) -> String {
        CanonicalStore.sanitizeAttachmentFilename(filename)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func filename(_ filename: String, appendingOrdinal ordinal: Int) -> String {
        let safeFilename = CanonicalStore.sanitizeAttachmentFilename(filename) as NSString
        let pathExtension = safeFilename.pathExtension
        let stem = safeFilename.deletingPathExtension
        guard pathExtension.isEmpty == false else {
            return "\(stem) (\(ordinal))"
        }
        return "\(stem) (\(ordinal)).\(pathExtension)"
    }

    /// Parses only the RFC 5322 header block from raw message data. Use this
    /// for lightweight metadata repair paths that must avoid decoding bodies or
    /// attachments.
    public static func parseHeaderFields(data: Data) -> [Header] {
        let headerData = splitHeadersAndBody(data: data).headers
        return parseHeaders(headerData)
    }

    // MARK: - Header parsing

    /// Parses RFC 5322 headers, handling continuation lines (lines starting with whitespace).
    static func parseHeaders(_ headerData: Data) -> [Header] {
        guard let text = String(data: headerData, encoding: .utf8) else { return [] }

        // Normalize line endings to LF.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var unfoldedLines: [String] = []

        for line in lines {
            let lineStr = String(line)
            if lineStr.isEmpty { break }

            // Continuation line: starts with space or tab.
            if let first = lineStr.first, (first == " " || first == "\t") {
                if !unfoldedLines.isEmpty {
                    // Fold into the previous logical header, replacing leading whitespace with a single space.
                    unfoldedLines[unfoldedLines.count - 1] += " " + lineStr.drop(while: { $0 == " " || $0 == "\t" })
                }
            } else {
                unfoldedLines.append(lineStr)
            }
        }

        var headers: [Header] = []
        for line in unfoldedLines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex])
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append(Header(name: name, value: value))
        }

        return headers
    }

    // MARK: - Header / body splitting

    /// Splits raw email data at the first blank line (CRLFCRLF or LFLF).
    static func splitHeadersAndBody(data: Data) -> (headers: Data, body: Data) {
        let bytes = Array(data)
        let count = bytes.count

        var i = 0
        while i < count {
            // Check for CRLFCRLF
            if i + 3 < count,
               bytes[i] == 0x0D, bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                let headerData = Data(bytes[0..<i])
                let bodyStart = i + 4
                let bodyData = bodyStart < count ? Data(bytes[bodyStart...]) : Data()
                return (headerData, bodyData)
            }
            // Check for LFLF
            if i + 1 < count,
               bytes[i] == 0x0A, bytes[i + 1] == 0x0A {
                let headerData = Data(bytes[0..<i])
                let bodyStart = i + 2
                let bodyData = bodyStart < count ? Data(bytes[bodyStart...]) : Data()
                return (headerData, bodyData)
            }
            i += 1
        }

        // No blank line found — treat entire data as headers.
        return (data, Data())
    }

    // MARK: - Multipart handling

    /// Extracts the boundary parameter from a Content-Type header value.
    static func extractBoundary(from contentType: String) -> String? {
        extractParameter(named: "boundary", from: contentType)
    }

    /// Splits a multipart body at MIME boundaries, returning parsed MIMEParts.
    static func splitMultipart(data: Data, boundary: String) -> [MIMEPart] {
        guard let delimiterData = ("--" + boundary).data(using: .utf8),
              !delimiterData.isEmpty else {
            return []
        }
        let bytes = Array(data)
        let delimiter = Array(delimiterData)
        var parts: [MIMEPart] = []
        var searchStart = 0
        var partStart: Int?

        while let marker = findMultipartBoundary(
            in: bytes,
            delimiter: delimiter,
            startingAt: searchStart
        ) {
            defer { searchStart = marker.afterLine }

            if let start = partStart {
                let end = trimmedMultipartPartEnd(in: bytes, before: marker.start)
                if end >= start {
                    let partData = Data(bytes[start..<end])
                    let (headerData, partBodyData) = splitHeadersAndBody(data: partData)
                    let headers = parseHeaders(headerData)

                    // Check for nested multipart.
                    let ct = headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
                    if let nestedBoundary = extractBoundary(from: ct) {
                        let subparts = splitMultipart(data: partBodyData, boundary: nestedBoundary)
                        parts.append(MIMEPart(headers: headers, body: partBodyData, subparts: subparts))
                    } else {
                        parts.append(MIMEPart(headers: headers, body: partBodyData, subparts: []))
                    }
                }
            }

            if marker.isClosing {
                break
            }
            partStart = marker.afterLine
        }

        return parts
    }

    private struct MultipartBoundaryMarker {
        let start: Int
        let afterLine: Int
        let isClosing: Bool
    }

    private static func findMultipartBoundary(
        in bytes: [UInt8],
        delimiter: [UInt8],
        startingAt start: Int
    ) -> MultipartBoundaryMarker? {
        guard !delimiter.isEmpty, bytes.count >= delimiter.count else { return nil }

        var i = max(0, start)
        let maxStart = bytes.count - delimiter.count

        while i <= maxStart {
            if (i == 0 || bytes[i - 1] == 0x0A),
               matches(bytes, delimiter, at: i) {
                let suffixStart = i + delimiter.count
                let isClosing = suffixStart + 1 < bytes.count
                    && bytes[suffixStart] == 0x2D
                    && bytes[suffixStart + 1] == 0x2D
                let lineProbe = isClosing ? suffixStart + 2 : suffixStart

                if isClosing || isBoundaryLineSuffix(bytes, at: suffixStart) {
                    return MultipartBoundaryMarker(
                        start: i,
                        afterLine: indexAfterCurrentLine(in: bytes, startingAt: lineProbe),
                        isClosing: isClosing
                    )
                }
            }
            i += 1
        }

        return nil
    }

    private static func matches(_ bytes: [UInt8], _ pattern: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func isBoundaryLineSuffix(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return true }
        switch bytes[index] {
        case 0x0D, 0x0A, 0x20, 0x09:
            return true
        default:
            return false
        }
    }

    private static func indexAfterCurrentLine(in bytes: [UInt8], startingAt start: Int) -> Int {
        var i = max(0, start)
        while i < bytes.count {
            let byte = bytes[i]
            i += 1
            if byte == 0x0A {
                return i
            }
        }
        return bytes.count
    }

    private static func trimmedMultipartPartEnd(in bytes: [UInt8], before boundaryStart: Int) -> Int {
        var end = min(max(0, boundaryStart), bytes.count)
        if end > 0, bytes[end - 1] == 0x0A {
            end -= 1
        }
        if end > 0, bytes[end - 1] == 0x0D {
            end -= 1
        }
        return end
    }

    // MARK: - Part processing

    /// Recursively processes a MIME part, populating text body, HTML body, and attachments.
    static func processPart(
        _ part: MIMEPart,
        textBody: inout String?,
        htmlBody: inout String?,
        attachments: inout [ParsedAttachment]
    ) {
        // If this part has subparts, recurse into them.
        if !part.subparts.isEmpty {
            processMultipartParts(
                part.subparts,
                contentType: part.contentType ?? "",
                textBody: &textBody,
                htmlBody: &htmlBody,
                attachments: &attachments
            )
            return
        }

        let ct = (part.contentType ?? "text/plain").lowercased()
        let disposition = part.contentDisposition ?? ""
        let encoding = part.contentTransferEncoding

        // Check if this is an attachment.
        let filename = extractFilename(
            from: part.contentType ?? "",
            disposition: disposition
        )

        // Calendar invitations are frequently inline `text/calendar` parts
        // without a filename. Preserve them as source attachments so meeting
        // reconciliation can parse the authoritative VEVENT instead of
        // guessing from the prose body.
        let isCalendarInvitation = canonicalMediaType(ct) == "text/calendar"
        let isAttachment = disposition.lowercased().contains("attachment")
            || filename != nil
            || isCalendarInvitation

        if isAttachment,
           let name = filename ?? (isCalendarInvitation ? "invite.ics" : "untitled") as String? {
            let decoded = decodeBody(part.body, encoding: encoding)
            let mimeType = ct.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"
            let contentId = part.headers.first {
                $0.name.lowercased() == "content-id"
            }?.value
            // The disposition token sits at the start of the header, before
            // any `;`-delimited parameters: `Content-Disposition: inline;
            // filename="foo.png"`. Matching the bare token avoids a false
            // positive when a filename parameter happens to contain the
            // word "inline" or "attachment".
            let dispositionToken = disposition
                .components(separatedBy: ";")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            // A part is "inline-shaped" if either:
            //   1. `Content-Disposition: inline` is explicit, OR
            //   2. The part has a Content-ID and no `Content-Disposition`
            //      header was supplied at all — this is the dominant pattern
            //      for inline images in Apple Mail, Outlook, and Gmail in
            //      `multipart/related` parts. Without this branch we'd miss
            //      the most common real-world case and the locked-overlay
            //      filter would never fire on Apple Mail messages.
            // Explicit `attachment` always wins, even when a Content-ID is
            // present — it means the sender deliberately attached the file.
            let dispositionIsInline = dispositionToken == "inline"
                || (dispositionToken.isEmpty && contentId != nil)
            attachments.append(ParsedAttachment(
                filename: name,
                mimeType: mimeType,
                data: decoded,
                contentId: contentId,
                dispositionIsInline: dispositionIsInline
            ))
        } else if ct.hasPrefix("text/html") {
            htmlBody = decodeTextBody(
                part.body,
                contentType: part.contentType ?? "text/html",
                transferEncoding: encoding
            )
        } else {
            switch textBodyRole(for: part.contentType ?? "text/plain") {
            case .plain:
                textBody = decodeTextBody(
                    part.body,
                    contentType: part.contentType ?? "text/plain",
                    transferEncoding: encoding
                )
            case .fallback:
                if textBody == nil {
                    textBody = decodeTextBody(
                        part.body,
                        contentType: part.contentType ?? "text/plain",
                        transferEncoding: encoding
                    )
                }
            case .nonBody:
                break
            }
        }
    }

    private static func processMultipartParts(
        _ parts: [MIMEPart],
        contentType: String,
        textBody: inout String?,
        htmlBody: inout String?,
        attachments: inout [ParsedAttachment]
    ) {
        guard canonicalMediaType(contentType) == "multipart/mixed" else {
            for part in parts {
                processPart(
                    part,
                    textBody: &textBody,
                    htmlBody: &htmlBody,
                    attachments: &attachments
                )
            }
            return
        }

        for part in parts {
            var partTextBody: String?
            var partHTMLBody: String?
            var partAttachments: [ParsedAttachment] = []
            processPart(
                part,
                textBody: &partTextBody,
                htmlBody: &partHTMLBody,
                attachments: &partAttachments
            )

            textBody = appendingPlainText(partTextBody, to: textBody)
            htmlBody = appendingHTML(partHTMLBody, to: htmlBody)
            attachments.append(contentsOf: partAttachments)
        }
    }

    private static func appendingPlainText(_ additional: String?, to existing: String?) -> String? {
        guard let additional, !additional.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return additional }
        return existing + "\n" + additional
    }

    private static func appendingHTML(_ additional: String?, to existing: String?) -> String? {
        guard let additional, !additional.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return additional }

        let fragment: Substring
        if let openingBody = additional.range(
            of: #"<body\b[^>]*>"#,
            options: [.caseInsensitive, .regularExpression]
        ) {
            let bodyRemainder = additional[openingBody.upperBound...]
            if let closingBody = bodyRemainder.range(
                of: "</body>",
                options: [.caseInsensitive, .backwards]
            ) {
                fragment = bodyRemainder[..<closingBody.lowerBound]
            } else {
                fragment = bodyRemainder
            }
        } else {
            fragment = additional[...]
        }

        guard let closingBody = existing.range(
            of: "</body>",
            options: [.caseInsensitive, .backwards]
        ) else {
            return existing + "\n" + fragment
        }

        let prefix = String(existing.prefix(upTo: closingBody.lowerBound))
        let suffix = String(existing.suffix(from: closingBody.lowerBound))
        return prefix + fragment + suffix
    }

    private enum TextBodyRole: Equatable {
        case plain
        case fallback
        case nonBody
    }

    private static func textBodyRole(for contentType: String) -> TextBodyRole {
        let mediaType = canonicalMediaType(contentType)
        switch mediaType {
        case "text/plain":
            return .plain
        case "text/enriched", "text/richtext", "text/markdown":
            return .fallback
        default:
            return .nonBody
        }
    }

    private static func canonicalMediaType(_ contentType: String) -> String {
        contentType
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    // MARK: - Content decoding

    static func decodeTextBody(
        _ data: Data,
        contentType: String,
        transferEncoding: String?
    ) -> String? {
        let decoded = decodeBody(data, encoding: transferEncoding)
        let declaredCharset = extractParameter(named: "charset", from: contentType)
        if let text = MIMECharsetDecoder.decodeBestEffortText(decoded, declaredCharset: declaredCharset) {
            return text
        }

        return String(decoding: decoded, as: UTF8.self)
    }

    /// Decodes a body according to the Content-Transfer-Encoding header.
    static func decodeBody(_ data: Data, encoding: String?) -> Data {
        guard let encoding = encoding?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return data
        }

        switch encoding {
        case "base64":
            // Strip whitespace and decode.
            guard let text = String(data: data, encoding: .utf8) else { return data }
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Data(base64Encoded: cleaned) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    /// Decodes quoted-printable encoded data per RFC 2045.
    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var result = Data()
        let bytes = Array(data)
        var i = 0

        while i < bytes.count {
            if bytes[i] == 0x3D { // "="
                // Soft line break: =\r\n or =\n
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    i += 3
                    continue
                }
                // Hex-encoded byte.
                if i + 2 < bytes.count,
                   let high = hexNibble(bytes[i + 1]),
                   let low = hexNibble(bytes[i + 2]) {
                    result.append((high << 4) | low)
                    i += 3
                    continue
                }
                // Malformed — pass through the "=" byte and let following bytes
                // be handled normally.
                result.append(0x3D)
                i += 1
            } else {
                result.append(bytes[i])
                i += 1
            }
        }

        return result
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }

    // MARK: - Parameter extraction

    /// Extracts a filename from Content-Type and Content-Disposition headers,
    /// decoding the non-ASCII forms real mail uses. Filenames with non-ASCII
    /// characters arrive either as an RFC 2231 extended / continued parameter
    /// (`filename*=UTF-8''%E6%B5%B7…`, `filename*0*=…; filename*1*=…`) or as an
    /// RFC 2047 encoded-word inside a plain `filename=` value
    /// (`filename="=?UTF-8?B?…?="`, non-standard but widely emitted by real
    /// mailers — the form seen in Apple Mail / Outlook Japanese attachments).
    /// Both decode here, at the ingestion seam, so every stored
    /// `Attachment.filename` is already human-readable. Language-agnostic:
    /// charsets resolve through the shared MIME charset decoder, with no UTF-8-
    /// or English-only shortcut.
    static func extractFilename(from contentType: String, disposition: String) -> String? {
        // Content-Disposition filename wins, then Content-Type name.
        if let name = decodedParameterValue(named: "filename", from: disposition) {
            return name
        }
        if let name = decodedParameterValue(named: "name", from: contentType) {
            return name
        }
        return nil
    }

    /// Resolves a header parameter to a display-ready string, preferring an
    /// RFC 2231 extended / continued value and otherwise RFC 2047-decoding a
    /// plain value. Returns `nil` only when the parameter is wholly absent.
    static func decodedParameterValue(named name: String, from headerValue: String) -> String? {
        let base = name.lowercased()
        let params = parseHeaderParameters(headerValue)
        if let assembled = assembleRFC2231Value(base: base, params: params) {
            return assembled
        }
        if let raw = params.first(where: { $0.key == base })?.value {
            return MIMEHeaderDecoder.decodeEncodedWords(raw)
        }
        return nil
    }

    /// Splits a header value into its `;`-delimited parameters as
    /// `(lowercased key, unquoted value)` pairs, respecting double-quoted
    /// values. Segments with no `=` (the leading type / disposition token) are
    /// skipped. Keys keep their RFC 2231 `*` / `*N*` suffixes so the assembler
    /// can recognize extended and continued parameters.
    private static func parseHeaderParameters(_ headerValue: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for segment in splitTopLevel(headerValue, on: ";") {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { continue }
            let value = segment[segment.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pairs.append((key, value.hasPrefix("\"") ? unquoteHeaderString(value) : value))
        }
        return pairs
    }

    /// Unwraps a double-quoted header value: drops the surrounding quotes and
    /// unescapes RFC 5322 quoted-pairs (`\<char>` → `<char>`), stopping at the
    /// first unescaped closing quote. So `"report \"v2\".pdf"` → `report "v2".pdf`.
    private static func unquoteHeaderString(_ quoted: String) -> String {
        var result = ""
        var escaped = false
        for character in quoted.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Splits `string` on `separator`, ignoring separators inside a
    /// double-quoted run (so a `;` inside a quoted filename does not split it).
    /// A backslash inside quotes escapes the next character, so an escaped quote
    /// (`\"`) does not prematurely end the quoted run.
    private static func splitTopLevel(_ string: String, on separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in string {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == separator && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    /// Assembles an RFC 2231 extended / continued parameter, or `nil` when no
    /// `base*` parameter is present. Handles the single extended form
    /// (`base*=charset'lang'pct`), numbered continuations (`base*0*`, `base*1`,
    /// …), and segments that mix percent-encoded and literal text. The charset
    /// rides on the first percent-encoded segment; the reassembled octets are
    /// decoded through the shared MIME charset decoder.
    private static func assembleRFC2231Value(base: String, params: [(key: String, value: String)]) -> String? {
        var segments: [(index: Int, encoded: Bool, raw: String)] = []
        for (key, value) in params {
            if key == base + "*" {
                // Single extended form — one percent-encoded segment.
                segments.append((index: 0, encoded: true, raw: value))
                continue
            }
            guard key.hasPrefix(base + "*") else { continue }
            let suffix = String(key.dropFirst(base.count + 1))
            let encoded = suffix.hasSuffix("*")
            let digits = encoded ? String(suffix.dropLast()) : suffix
            guard let index = Int(digits) else { continue }
            segments.append((index: index, encoded: encoded, raw: value))
        }
        guard !segments.isEmpty else { return nil }
        segments.sort { $0.index < $1.index }

        var charset = "UTF-8"
        var data = Data()
        let firstIndex = segments[0].index
        for segment in segments {
            var text = segment.raw
            if segment.index == firstIndex && segment.encoded {
                // The `charset'lang'` prefix appears only on the first encoded
                // segment; strip it and capture the charset for every segment.
                // Only strip when the leading token is genuinely a charset (or
                // empty, i.e. the us-ascii default) — otherwise a literal name
                // that merely contains an apostrophe (`O'Brien's report.pdf`,
                // sent as a bare `filename*=`) would be mangled. With no valid
                // prefix the text falls through `percentDecodedData`, which
                // passes non-`%` bytes verbatim, preserving the literal name.
                let parts = text.components(separatedBy: "'")
                if parts.count >= 3, parts[0].isEmpty || MIMECharsetDecoder.isKnownCharset(parts[0]) {
                    if !parts[0].isEmpty { charset = parts[0] }
                    text = parts[2...].joined(separator: "'")
                }
            }
            if segment.encoded {
                data.append(percentDecodedData(text))
            } else {
                data.append(Data(text.utf8))
            }
        }

        if let decoded = MIMECharsetDecoder.decode(data, charset: charset) {
            return decoded
        }
        // Best-effort fallback rather than dropping the name.
        return String(data: data, encoding: .utf8) ?? segments.map(\.raw).joined()
    }

    /// Percent-decodes RFC 2231 octets (`%XX`) into raw bytes. Non-`%` ASCII
    /// passes through unchanged; any stray non-ASCII scalar contributes its
    /// UTF-8 bytes so nothing is lost on malformed input.
    private static func percentDecodedData(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%", index + 2 < scalars.count,
               let high = hexNibble(scalars[index + 1]),
               let low = hexNibble(scalars[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else if scalar.isASCII {
                bytes.append(UInt8(scalar.value))
                index += 1
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                index += 1
            }
        }
        return Data(bytes)
    }

    private static func hexNibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - Unicode.Scalar("0").value)
        case "a"..."f": return UInt8(scalar.value - Unicode.Scalar("a").value + 10)
        case "A"..."F": return UInt8(scalar.value - Unicode.Scalar("A").value + 10)
        default: return nil
        }
    }

    /// Extracts a named parameter value from a header value string.
    /// E.g. extractParameter(named: "boundary", from: "multipart/mixed; boundary=\"abc\"") -> "abc"
    static func extractParameter(named name: String, from headerValue: String) -> String? {
        let lowered = headerValue.lowercased()
        let searchKey = name.lowercased() + "="

        guard let range = lowered.range(of: searchKey) else { return nil }

        let valueStart = headerValue[range.upperBound...]
        let trimmed = valueStart.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("\"") {
            // Quoted value — find the closing quote.
            let afterQuote = trimmed.dropFirst()
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                return String(afterQuote[afterQuote.startIndex..<endQuote])
            }
            return String(afterQuote)
        } else {
            // Unquoted value — ends at semicolon, whitespace, or end of string.
            let end = trimmed.firstIndex(where: { $0 == ";" || $0 == " " || $0 == "\t" })
                ?? trimmed.endIndex
            return String(trimmed[trimmed.startIndex..<end])
        }
    }
}
