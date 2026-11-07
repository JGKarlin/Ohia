import Foundation
import OhiaCore

public struct MessageEvidenceBundle: Sendable, Codable, Equatable {
    public struct AttachmentItem: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public let attachmentId: String?
        public let filename: String
        public let mimeType: String
        public let contentId: String?
        public let isInline: Bool
        public let cards: [AttachmentEvidenceCard]

        public init(
            attachmentId: String?,
            filename: String,
            mimeType: String,
            contentId: String?,
            isInline: Bool,
            cards: [AttachmentEvidenceCard]
        ) {
            self.attachmentId = AttachmentEvidencePacket.clean(attachmentId, limit: 96)
            self.filename = AttachmentEvidencePacket.clean(filename, limit: 160) ?? filename
            self.mimeType = AttachmentEvidencePacket.clean(mimeType, limit: 96) ?? mimeType
            self.contentId = AttachmentEvidencePacket.clean(contentId, limit: 160)
            self.isInline = isInline
            self.cards = cards.filter(\.isUseful)
            self.id = self.attachmentId ?? self.filename
        }
    }

    public let messageId: String
    public let subject: String
    public let bodyExcerpt: String
    public let bodyAttachmentCues: [String]
    public let attachments: [AttachmentItem]

    public init(
        messageId: String,
        subject: String,
        bodyText: String,
        attachments: [AttachmentItem]
    ) {
        self.messageId = AttachmentEvidencePacket.clean(messageId, limit: 96) ?? messageId
        self.subject = AttachmentEvidencePacket.clean(subject, limit: 180) ?? subject
        self.bodyExcerpt = Self.bodyExcerpt(bodyText)
        self.attachments = attachments
        self.bodyAttachmentCues = Self.bodyAttachmentCues(
            bodyText: bodyText,
            attachments: attachments
        )
    }

    public var hasUsefulEvidence: Bool {
        !bodyAttachmentCues.isEmpty || attachments.contains { !$0.cards.isEmpty }
    }

    public func digest(maxCharacters: Int = 2_400) -> String? {
        guard hasUsefulEvidence else { return nil }
        var lines: [String] = [
            "MESSAGE_EVIDENCE_BUNDLE",
            "SUBJECT: \(subject)"
        ]

        if !bodyExcerpt.isEmpty {
            lines.append("BODY_CLAIMS:")
            lines.append("- \(bodyExcerpt)")
        }

        if !bodyAttachmentCues.isEmpty {
            lines.append("BODY_ATTACHMENT_CUES:")
            lines.append(contentsOf: bodyAttachmentCues.prefix(6).map { "- \($0)" })
        }

        let attachmentHints = attachments.prefix(8).map { item in
            let inline = item.isInline ? "inline CID" : "attached file"
            return "- \(item.filename) (\(item.mimeType), \(inline))"
        }
        if !attachmentHints.isEmpty {
            lines.append("ATTACHMENT_FILENAMES:")
            lines.append(contentsOf: attachmentHints)
        }

        let cards = attachments.flatMap { attachment in
            attachment.cards.prefix(8).map { (attachment, $0) }
        }
        if !cards.isEmpty {
            lines.append("ATTACHMENT_VISUAL_OR_TEXT_CLAIMS:")
            for (attachment, card) in cards.prefix(14) {
                let lineRange: String
                if let start = card.ocrStartLineIndex, let end = card.ocrEndLineIndex {
                    lineRange = " lines \(start)-\(end)"
                } else {
                    lineRange = ""
                }
                lines.append("- \(attachment.filename) [\(card.provenanceLabel)\(lineRange)]: \(AttachmentEvidencePacket.clean(card.text, limit: 360) ?? "")")
            }
        }

        let digest = lines.joined(separator: "\n")
        return AttachmentEvidencePacket.clean(digest, limit: maxCharacters)
    }

    public func cards(for modalities: Set<AttachmentEvidenceModality>) -> [AttachmentEvidenceCard] {
        attachments.flatMap(\.cards).filter { modalities.contains($0.modality) }
    }

    @MainActor
    public static func build(
        message: Message,
        bodyText: String,
        fallbackTextByAttachmentId: [String: String] = [:]
    ) -> MessageEvidenceBundle? {
        let messageId = message.id.uuidString
        let items = message.attachments.compactMap { attachment -> AttachmentItem? in
            let attachmentId = attachment.id.uuidString
            let fallback = fallbackTextByAttachmentId[attachmentId]
            let packet = AttachmentEvidencePacket(attachment: attachment, messageId: messageId)
            let cards = packet?.evidenceCards(fallbackExtractedText: fallback) ?? fallback.flatMap { text in
                let card = AttachmentEvidenceCard(
                    id: "\(attachmentId):\(AttachmentEvidenceModality.extractedText.rawValue):0",
                    messageId: messageId,
                    attachmentId: attachmentId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    modality: .extractedText,
                    evidenceKind: nil,
                    confidence: nil,
                    text: text
                )
                return card.isUseful ? [card] : nil
            } ?? []
            guard !cards.isEmpty || attachment.contentId != nil || attachment.isInline == true else {
                return nil
            }
            return AttachmentItem(
                attachmentId: attachmentId,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                contentId: attachment.contentId,
                isInline: attachment.isInline == true,
                cards: cards
            )
        }
        let bundle = MessageEvidenceBundle(
            messageId: messageId,
            subject: message.subject,
            bodyText: bodyText,
            attachments: items
        )
        return bundle.hasUsefulEvidence ? bundle : nil
    }

    private static func bodyExcerpt(_ bodyText: String) -> String {
        let cleaned = bodyText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentEvidencePacket.clean(cleaned, limit: 520) ?? ""
    }

    private static func bodyAttachmentCues(
        bodyText: String,
        attachments: [AttachmentItem]
    ) -> [String] {
        let body = bodyText.lowercased()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return inlineCues(attachments)
        }
        let tokens = bodyTokens(body)

        var cues: [String] = []
        let attachmentTerms = [
            "attached", "attachment", "enclosed", "screenshot", "image", "photo",
            "receipt", "invoice", "scan", "diagram", "pdf", "file"
        ]
        for term in attachmentTerms where tokens.contains(term) {
            cues.append("Body mentions \(term).")
            if cues.count >= 4 { break }
        }

        for attachment in attachments {
            let filename = attachment.filename.lowercased()
            let stem = (attachment.filename as NSString).deletingPathExtension.lowercased()
            if bodyContainsName(body, tokens: tokens, name: filename) {
                cues.append("Body mentions attachment filename \(attachment.filename).")
            } else if stem.count >= 4, bodyContainsName(body, tokens: tokens, name: stem) {
                cues.append("Body mentions attachment name \(stem).")
            }
        }

        cues.append(contentsOf: inlineCues(attachments))
        var seen = Set<String>()
        return cues.filter { seen.insert($0).inserted }
    }

    private static func bodyTokens(_ body: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        return Set(body.components(separatedBy: separators).filter { !$0.isEmpty })
    }

    private static func bodyContainsName(_ body: String, tokens: Set<String>, name: String) -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if isSimpleBodyToken(cleaned) {
            return tokens.contains(cleaned)
        }
        return bodyContainsDelimited(body, needle: cleaned)
    }

    private static func isSimpleBodyToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func bodyContainsDelimited(_ body: String, needle: String) -> Bool {
        var searchStart = body.startIndex
        while let range = body.range(of: needle, range: searchStart..<body.endIndex) {
            let beforeIsBoundary = range.lowerBound == body.startIndex
                || isBodyBoundary(body[body.index(before: range.lowerBound)])
            let afterIsBoundary = range.upperBound == body.endIndex
                || isBodyBoundary(body[range.upperBound])
            if beforeIsBoundary && afterIsBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isBodyBoundary(_ character: Character) -> Bool {
        !character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func inlineCues(_ attachments: [AttachmentItem]) -> [String] {
        attachments.compactMap { attachment in
            guard attachment.isInline else { return nil }
            if let contentId = attachment.contentId {
                return "Attachment \(attachment.filename) is inline via CID \(contentId)."
            }
            return "Attachment \(attachment.filename) is inline via CID."
        }
    }
}
