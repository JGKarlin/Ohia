import Foundation
import OhiaCore

public enum AttachmentEvidenceModality: String, Sendable, Codable, Equatable, CaseIterable {
    case filename
    case visualSummary
    case attachmentSummary
    case labels
    case objects
    case salientDetails
    case searchTerms
    case ocr
    case extractedText
    case captureMetadata

    public var displayLabel: String {
        switch self {
        case .filename:
            return "attachment filename"
        case .visualSummary:
            return "visual summary"
        case .attachmentSummary:
            return "attachment summary"
        case .labels:
            return "Vision labels"
        case .objects:
            return "Vision objects"
        case .salientDetails:
            return "visible details"
        case .searchTerms:
            return "visual search terms"
        case .ocr:
            return "attachment OCR"
        case .extractedText:
            return "attachment text"
        case .captureMetadata:
            return "capture metadata"
        }
    }

    public var searchPrefix: String {
        switch self {
        case .filename:
            return "ATTACHMENT_FILENAME"
        case .visualSummary:
            return "VISUAL_SUMMARY"
        case .attachmentSummary:
            return "READER_ATTACHMENT_SUMMARY"
        case .labels:
            return "VISION_LABELS"
        case .objects:
            return "VISION_OBJECTS"
        case .salientDetails:
            return "VISIBLE_DETAILS"
        case .searchTerms:
            return "VISUAL_SEARCH_TERMS"
        case .ocr:
            return "OCR_TEXT"
        case .extractedText:
            return "ATTACHMENT_TEXT"
        case .captureMetadata:
            return "CAPTURE_METADATA"
        }
    }
}

public struct AttachmentEvidenceCard: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let messageId: String?
    public let attachmentId: String?
    public let filename: String
    public let mimeType: String
    public let modality: AttachmentEvidenceModality
    public let evidenceKind: String?
    public let confidence: Float?
    public let text: String
    public let ocrStartLineIndex: Int?
    public let ocrEndLineIndex: Int?
    public let boundingBoxes: [AttachmentEvidencePacket.BoundingBox]

    public init(
        id: String,
        messageId: String?,
        attachmentId: String?,
        filename: String,
        mimeType: String,
        modality: AttachmentEvidenceModality,
        evidenceKind: String?,
        confidence: Float?,
        text: String,
        ocrStartLineIndex: Int? = nil,
        ocrEndLineIndex: Int? = nil,
        boundingBoxes: [AttachmentEvidencePacket.BoundingBox] = []
    ) {
        self.id = id
        self.messageId = AttachmentEvidencePacket.clean(messageId, limit: 96)
        self.attachmentId = AttachmentEvidencePacket.clean(attachmentId, limit: 96)
        let decodedFilename = MIMEHeaderDecoder.decodeEncodedWords(filename)
        self.filename = AttachmentEvidencePacket.clean(decodedFilename, limit: 160) ?? decodedFilename
        self.mimeType = AttachmentEvidencePacket.clean(mimeType, limit: 96) ?? mimeType
        self.modality = modality
        self.evidenceKind = AttachmentEvidencePacket.clean(evidenceKind, limit: 80)
        self.confidence = confidence?.isFinite == true ? confidence : nil
        self.text = AttachmentEvidencePacket.clean(text, limit: 4_000) ?? ""
        self.ocrStartLineIndex = ocrStartLineIndex
        self.ocrEndLineIndex = ocrEndLineIndex
        self.boundingBoxes = Array(boundingBoxes.prefix(4))
    }

    public var isUseful: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var provenanceLabel: String {
        modality.displayLabel
    }

    public var semanticText: String {
        var lines: [String] = [
            "ATTACHMENT_EVIDENCE_CARD: \(filename)",
            "MIME_TYPE: \(mimeType)",
            "MODALITY: \(modality.rawValue)"
        ]
        if let evidenceKind {
            lines.append("VISUAL_KIND: \(evidenceKind)")
        }
        lines.append("\(modality.searchPrefix): \(text)")
        return lines.joined(separator: "\n")
    }

    public var searchText: String {
        "\(modality.searchPrefix): \(text)"
    }
}

public struct AttachmentEvidencePacket: Sendable, Codable, Equatable, Identifiable {
    public struct BoundingBox: Sendable, Codable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = Self.clamped(x)
            self.y = Self.clamped(y)
            self.width = Self.clamped(width)
            self.height = Self.clamped(height)
        }

        init(_ box: VisualAttachmentEvidence.BoundingBox) {
            self.init(x: box.x, y: box.y, width: box.width, height: box.height)
        }

        public var stableDescription: String {
            String(format: "%.3f,%.3f,%.3f,%.3f", x, y, width, height)
        }

        private static func clamped(_ value: Double) -> Double {
            min(1, max(0, value.isFinite ? value : 0))
        }
    }

    public struct Label: Sendable, Codable, Equatable {
        public let identifier: String
        public let confidence: Float

        public init(identifier: String, confidence: Float) {
            self.identifier = identifier
            self.confidence = confidence
        }
    }

    public struct Object: Sendable, Codable, Equatable {
        public let label: String
        public let count: Int
        public let confidence: Float

        public init(label: String, count: Int, confidence: Float) {
            self.label = label
            self.count = max(1, count)
            self.confidence = confidence
        }
    }

    public struct OCRBlock: Sendable, Codable, Equatable {
        public let text: String
        public let confidence: Float
        public let startLineIndex: Int
        public let endLineIndex: Int
        public let boundingBox: BoundingBox?

        public init(
            text: String,
            confidence: Float,
            startLineIndex: Int,
            endLineIndex: Int,
            boundingBox: BoundingBox? = nil
        ) {
            self.text = text
            self.confidence = confidence
            self.startLineIndex = startLineIndex
            self.endLineIndex = max(startLineIndex, endLineIndex)
            self.boundingBox = boundingBox
        }
    }

    public let id: String
    public let messageId: String?
    public let attachmentId: String?
    public let filename: String
    public let mimeType: String
    public let visualSummary: String?
    public let attachmentSummary: String?
    public let contentKind: String?
    public let evidenceKind: String?
    public let salientDetails: [String]
    public let searchTerms: [String]
    public let decodedBarcodes: [String]
    public let labels: [Label]
    public let objects: [Object]
    public let ocrBlocks: [OCRBlock]
    public let ocrText: String?
    public let visualSignalCount: Int?
    public let visualGeneratedAt: Date?
    /// Recorded capture time, place and captions (`AttachmentCaptureMetadata.evidenceText`).
    public let captureMetadata: String?

    public init(
        messageId: String?,
        attachmentId: String?,
        filename: String,
        mimeType: String,
        visualSummary: String?,
        attachmentSummary: String?,
        evidenceKind: String?,
        labels: [Label],
        objects: [Object],
        ocrBlocks: [OCRBlock],
        ocrText: String?,
        visualSignalCount: Int?,
        visualGeneratedAt: Date?,
        contentKind: String? = nil,
        salientDetails: [String] = [],
        searchTerms: [String] = [],
        decodedBarcodes: [String] = [],
        captureMetadata: String? = nil
    ) {
        let normalizedAttachmentId = Self.clean(attachmentId, limit: 96)
        self.attachmentId = normalizedAttachmentId
        self.messageId = Self.clean(messageId, limit: 96)
        let decodedFilename = MIMEHeaderDecoder.decodeEncodedWords(filename)
        self.filename = Self.clean(decodedFilename, limit: 160) ?? decodedFilename
        self.mimeType = Self.clean(mimeType, limit: 96) ?? mimeType
        self.visualSummary = Self.clean(visualSummary, limit: 1_200)
        self.attachmentSummary = AttachmentSummaryPostProcessor.clean(attachmentSummary)
        self.contentKind = Self.clean(contentKind, limit: 80)
        self.evidenceKind = Self.clean(evidenceKind, limit: 80)
        self.salientDetails = Self.normalizedValues(salientDetails, countLimit: 8, characterLimit: 240)
        self.searchTerms = Self.normalizedValues(searchTerms, countLimit: 12, characterLimit: 100)
        self.decodedBarcodes = Array(decodedBarcodes.filter { !$0.isEmpty && $0.count <= 4096 }.prefix(8))
        self.labels = labels
            .filter { !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(12)
            .map { Label(identifier: Self.clean($0.identifier, limit: 80) ?? $0.identifier, confidence: $0.confidence) }
        self.objects = objects
            .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(12)
            .map { Object(label: Self.clean($0.label, limit: 80) ?? $0.label, count: $0.count, confidence: $0.confidence) }
        self.ocrBlocks = ocrBlocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(12)
            .map {
                OCRBlock(
                    text: Self.clean($0.text, limit: 800) ?? $0.text,
                    confidence: $0.confidence,
                    startLineIndex: $0.startLineIndex,
                    endLineIndex: $0.endLineIndex,
                    boundingBox: $0.boundingBox
                )
            }
        self.ocrText = Self.clean(ocrText, limit: 4_000)
        self.visualSignalCount = visualSignalCount
        self.visualGeneratedAt = visualGeneratedAt
        self.captureMetadata = Self.clean(captureMetadata, limit: 1_200)
        self.id = normalizedAttachmentId
            ?? [self.messageId, self.filename].compactMap { $0 }.joined(separator: ":")
    }

    @MainActor
    public init?(attachment: Attachment, messageId: String? = nil) {
        let analysis = Self.decodeVisualAnalysis(attachment.visualEvidenceJSON)
        let decoded = analysis?.legacyEvidence ?? Self.decodeVisualEvidence(
            attachment.visualEvidenceJSON,
            fallbackFilename: attachment.filename,
            fallbackMimeType: attachment.mimeType
        )
        let labels = decoded?.classifications.map {
            Label(identifier: $0.identifier, confidence: $0.confidence)
        } ?? []
        let objects = decoded?.detectedObjects.map {
            Object(label: $0.label, count: $0.count, confidence: $0.confidence)
        } ?? []
        let blocks: [OCRBlock]
        if let decoded, !decoded.ocrBlocks.isEmpty {
            blocks = decoded.ocrBlocks.map {
                OCRBlock(
                    text: $0.text,
                    confidence: $0.confidence,
                    startLineIndex: $0.startLineIndex,
                    endLineIndex: $0.endLineIndex,
                    boundingBox: $0.boundingBox.map(BoundingBox.init)
                )
            }
        } else {
            blocks = decoded?.ocrLines.map {
                OCRBlock(
                    text: $0.text,
                    confidence: $0.confidence,
                    startLineIndex: $0.lineIndex,
                    endLineIndex: $0.lineIndex,
                    boundingBox: $0.boundingBox.map(BoundingBox.init)
                )
            } ?? []
        }

        let summary = attachment.visualSummary ?? analysis?.summary
        let readerSummary = attachment.attachmentSummary
        let ocrText = analysis?.visibleText ?? decoded?.ocrText
        let contentKind = analysis?.contentKind.rawValue
        let evidenceKind = attachment.visualEvidenceKind
            ?? contentKind
            ?? decoded?.evidenceKind.rawValue
        let salientDetails = analysis?.salientDetails ?? []
        let searchTerms = analysis?.searchTerms ?? []
        let decodedBarcodes = analysis?.decodedBarcodes ?? []
        let captureMetadata = AttachmentCaptureMetadata.decode(attachment.captureMetadataJSON)?.evidenceText
        guard Self.clean(summary, limit: 1) != nil
            || Self.clean(captureMetadata, limit: 1) != nil
            || Self.clean(readerSummary, limit: 1) != nil
            || Self.clean(ocrText, limit: 1) != nil
            || !salientDetails.isEmpty
            || !searchTerms.isEmpty
            || !decodedBarcodes.isEmpty
            || !labels.isEmpty
            || !objects.isEmpty
        else {
            return nil
        }

        self.init(
            messageId: messageId ?? attachment.message?.id.uuidString,
            attachmentId: attachment.id.uuidString,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            visualSummary: summary,
            attachmentSummary: readerSummary,
            evidenceKind: evidenceKind,
            labels: labels,
            objects: objects,
            ocrBlocks: blocks,
            ocrText: ocrText,
            visualSignalCount: attachment.visualSignalCount,
            visualGeneratedAt: attachment.visualGeneratedAt,
            contentKind: contentKind,
            salientDetails: salientDetails,
            searchTerms: searchTerms,
            decodedBarcodes: decodedBarcodes,
            captureMetadata: captureMetadata
        )
    }

    public var hasVisualEvidence: Bool {
        visualSummary != nil
            || evidenceKind != nil
            || contentKind != nil
            || !salientDetails.isEmpty
            || !searchTerms.isEmpty
            || !decodedBarcodes.isEmpty
            || !labels.isEmpty
            || !objects.isEmpty
            || !ocrBlocks.isEmpty
            || ocrText != nil
    }

    public var hasReaderSummary: Bool {
        attachmentSummary != nil
    }

    public var hasCaptureMetadata: Bool {
        captureMetadata != nil
    }

    public var labelsLine: String? {
        let values = labels.map(\.identifier)
        guard !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    public var objectsLine: String? {
        let values = objects.map { object in
            let count = object.count > 1 ? " x\(object.count)" : ""
            return "\(object.label)\(count)"
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    public var averageConfidence: Float? {
        let values = labels.map(\.confidence) + objects.map(\.confidence) + ocrBlocks.map(\.confidence)
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Float(finite.count)
    }

    public func evidenceCards(fallbackExtractedText: String?) -> [AttachmentEvidenceCard] {
        var cards: [AttachmentEvidenceCard] = []
        func append(
            modality: AttachmentEvidenceModality,
            text: String?,
            confidence: Float?,
            index: Int = 0,
            startLine: Int? = nil,
            endLine: Int? = nil,
            boundingBox: BoundingBox? = nil
        ) {
            guard let text = Self.clean(text, limit: 4_000) else { return }
            let idParts = [
                attachmentId ?? messageId ?? filename,
                modality.rawValue,
                String(index)
            ]
            let card = AttachmentEvidenceCard(
                id: idParts.joined(separator: ":"),
                messageId: messageId,
                attachmentId: attachmentId,
                filename: filename,
                mimeType: mimeType,
                modality: modality,
                evidenceKind: evidenceKind,
                confidence: confidence,
                text: text,
                ocrStartLineIndex: startLine,
                ocrEndLineIndex: endLine,
                boundingBoxes: boundingBox.map { [$0] } ?? []
            )
            if card.isUseful {
                cards.append(card)
            }
        }

        append(modality: .visualSummary, text: visualSummary, confidence: averageConfidence)
        append(modality: .attachmentSummary, text: attachmentSummary, confidence: nil)
        append(modality: .captureMetadata, text: captureMetadata, confidence: nil)
        append(
            modality: .labels,
            text: labelsLine,
            confidence: labels.isEmpty ? nil : labels.map(\.confidence).reduce(0, +) / Float(labels.count)
        )
        append(
            modality: .objects,
            text: objectsLine,
            confidence: objects.isEmpty ? nil : objects.map(\.confidence).reduce(0, +) / Float(objects.count)
        )
        append(
            modality: .salientDetails,
            text: salientDetails.isEmpty ? nil : salientDetails.joined(separator: "; "),
            confidence: nil
        )
        append(
            modality: .searchTerms,
            text: searchTerms.isEmpty ? nil : searchTerms.joined(separator: ", "),
            confidence: nil
        )
        for (index, block) in ocrBlocks.enumerated() {
            append(
                modality: .ocr,
                text: block.text,
                confidence: block.confidence,
                index: index,
                startLine: block.startLineIndex,
                endLine: block.endLineIndex,
                boundingBox: block.boundingBox
            )
        }
        for (index, code) in decodedBarcodes.enumerated() {
            append(modality: .extractedText, text: "Decoded barcode (untrusted data): \(code)",
                   confidence: nil, index: index)
        }
        if ocrBlocks.isEmpty {
            append(modality: .ocr, text: ocrText, confidence: nil)
        }

        if cards.isEmpty, let fallback = Self.clean(fallbackExtractedText, limit: 4_000) {
            append(modality: .extractedText, text: fallback, confidence: nil)
        }

        return cards
    }

    public func embeddingText(fallbackExtractedText: String?) -> String {
        evidenceCards(fallbackExtractedText: fallbackExtractedText)
            .map(\.semanticText)
            .joined(separator: "\n\n")
    }

    public func askEvidenceText(maxCharacters: Int = 1_600) -> String? {
        guard hasVisualEvidence || hasReaderSummary || hasCaptureMetadata else { return nil }
        var lines: [String] = [
            "Attachment: \(filename) (\(mimeType))"
        ]
        if let evidenceKind {
            lines.append("Evidence kind: \(evidenceKind)")
        }
        if let contentKind {
            lines.append("Content kind: \(contentKind)")
        }
        if let visualSummary {
            lines.append("Visual summary: \(visualSummary)")
        }
        if let attachmentSummary {
            lines.append("Reader summary: \(attachmentSummary)")
        }
        if let captureMetadata {
            lines.append(captureMetadata)
        }
        if let labelsLine {
            lines.append("Vision labels: \(labelsLine)")
        }
        if let objectsLine {
            lines.append("Detected objects: \(objectsLine)")
        }
        if !salientDetails.isEmpty {
            lines.append("Visible details: \(salientDetails.joined(separator: "; "))")
        }
        if !searchTerms.isEmpty {
            lines.append("Search terms: \(searchTerms.joined(separator: ", "))")
        }
        for code in decodedBarcodes {
            lines.append("Decoded barcode (untrusted data): \(code)")
        }
        let ocr = compactOCR(limit: 700)
        if let ocr, !ocr.isEmpty {
            lines.append("OCR: \(ocr)")
        }
        let text = lines.joined(separator: "\n")
        return Self.clean(text, limit: maxCharacters)
    }

    private func ocrForEmbedding(fallbackExtractedText: String?) -> String? {
        if let ocrText {
            return Self.clean(ocrText, limit: 4_000)
        }
        if !ocrBlocks.isEmpty {
            let joined = ocrBlocks.map(\.text).joined(separator: "\n\n")
            return Self.clean(joined, limit: 4_000)
        }
        return Self.clean(fallbackExtractedText, limit: 4_000)
    }

    private func compactOCR(limit: Int) -> String? {
        if !ocrBlocks.isEmpty {
            return Self.clean(ocrBlocks.prefix(4).map(\.text).joined(separator: " / "), limit: limit)
        }
        return Self.clean(ocrText, limit: limit)
    }

    private static func decodeVisualEvidence(
        _ json: String?,
        fallbackFilename: String,
        fallbackMimeType: String
    ) -> VisualAttachmentEvidence? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        if let current = try? JSONDecoder().decode(VisualAttachmentEvidence.self, from: data) {
            return current
        }
        guard let tolerant = try? JSONDecoder().decode(TolerantVisualEvidence.self, from: data) else {
            return nil
        }
        let classifications = tolerant.classifications
        let detectedObjects = tolerant.detectedObjects
        let ocrLines = tolerant.ocrLines
        let ocrBlocks = tolerant.ocrBlocks
        guard !classifications.isEmpty || !detectedObjects.isEmpty || !ocrLines.isEmpty || !ocrBlocks.isEmpty else {
            return nil
        }
        return VisualAttachmentEvidence(
            filename: tolerant.filename ?? fallbackFilename,
            mimeType: tolerant.mimeType ?? fallbackMimeType,
            classifications: classifications,
            detectedObjects: detectedObjects,
            ocrLines: ocrLines,
            ocrBlocks: ocrBlocks,
            imageMetadata: tolerant.imageMetadata ?? VisualAttachmentEvidence.ImageMetadata(),
            evidenceKind: tolerant.evidenceKind.flatMap(VisualAttachmentEvidence.EvidenceKind.init(rawValue:))
        )
    }

    private static func decodeVisualAnalysis(
        _ json: String?
    ) -> VisualAttachmentAnalysisRecord? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(VisualAttachmentAnalysisRecord.self, from: data)
    }

    private static func normalizedValues(
        _ values: [String],
        countLimit: Int,
        characterLimit: Int
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            guard let cleaned = clean(value, limit: characterLimit) else { continue }
            let key = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
            if result.count == countLimit { break }
        }
        return result
    }

    public static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func confidence(_ value: Float) -> String {
        guard value.isFinite else { return "unknown" }
        return String(format: "%.2f", min(1, max(0, value)))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId
        case attachmentId
        case filename
        case mimeType
        case visualSummary
        case attachmentSummary
        case contentKind
        case evidenceKind
        case salientDetails
        case searchTerms
        case decodedBarcodes
        case labels
        case objects
        case ocrBlocks
        case ocrText
        case visualSignalCount
        case visualGeneratedAt
        case captureMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
            attachmentId: try container.decodeIfPresent(String.self, forKey: .attachmentId),
            filename: try container.decode(String.self, forKey: .filename),
            mimeType: try container.decode(String.self, forKey: .mimeType),
            visualSummary: try container.decodeIfPresent(String.self, forKey: .visualSummary),
            attachmentSummary: try container.decodeIfPresent(String.self, forKey: .attachmentSummary),
            evidenceKind: try container.decodeIfPresent(String.self, forKey: .evidenceKind),
            labels: try container.decodeIfPresent([Label].self, forKey: .labels) ?? [],
            objects: try container.decodeIfPresent([Object].self, forKey: .objects) ?? [],
            ocrBlocks: try container.decodeIfPresent([OCRBlock].self, forKey: .ocrBlocks) ?? [],
            ocrText: try container.decodeIfPresent(String.self, forKey: .ocrText),
            visualSignalCount: try container.decodeIfPresent(Int.self, forKey: .visualSignalCount),
            visualGeneratedAt: try container.decodeIfPresent(Date.self, forKey: .visualGeneratedAt),
            contentKind: try container.decodeIfPresent(String.self, forKey: .contentKind),
            salientDetails: try container.decodeIfPresent([String].self, forKey: .salientDetails) ?? [],
            searchTerms: try container.decodeIfPresent([String].self, forKey: .searchTerms) ?? [],
            decodedBarcodes: try container.decodeIfPresent([String].self, forKey: .decodedBarcodes) ?? [],
            captureMetadata: try container.decodeIfPresent(String.self, forKey: .captureMetadata)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(attachmentId, forKey: .attachmentId)
        try container.encode(filename, forKey: .filename)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(visualSummary, forKey: .visualSummary)
        try container.encodeIfPresent(attachmentSummary, forKey: .attachmentSummary)
        try container.encodeIfPresent(contentKind, forKey: .contentKind)
        try container.encodeIfPresent(evidenceKind, forKey: .evidenceKind)
        try container.encode(salientDetails, forKey: .salientDetails)
        try container.encode(searchTerms, forKey: .searchTerms)
        try container.encode(decodedBarcodes, forKey: .decodedBarcodes)
        try container.encode(labels, forKey: .labels)
        try container.encode(objects, forKey: .objects)
        try container.encode(ocrBlocks, forKey: .ocrBlocks)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
        try container.encodeIfPresent(visualSignalCount, forKey: .visualSignalCount)
        try container.encodeIfPresent(visualGeneratedAt, forKey: .visualGeneratedAt)
        try container.encodeIfPresent(captureMetadata, forKey: .captureMetadata)
    }

    private struct TolerantVisualEvidence: Decodable {
        let filename: String?
        let mimeType: String?
        let classifications: [VisualAttachmentEvidence.Label]
        let detectedObjects: [VisualAttachmentEvidence.DetectedObject]
        let ocrLines: [VisualAttachmentEvidence.OCRLine]
        let ocrBlocks: [VisualAttachmentEvidence.OCRBlock]
        let imageMetadata: VisualAttachmentEvidence.ImageMetadata?
        let evidenceKind: String?

        enum CodingKeys: String, CodingKey {
            case filename
            case mimeType
            case classifications
            case detectedObjects
            case ocrLines
            case ocrBlocks
            case imageMetadata
            case evidenceKind
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.filename = try? container.decode(String.self, forKey: .filename)
            self.mimeType = try? container.decode(String.self, forKey: .mimeType)
            self.classifications = (try? container.decode([VisualAttachmentEvidence.Label].self, forKey: .classifications)) ?? []
            self.detectedObjects = (try? container.decode([VisualAttachmentEvidence.DetectedObject].self, forKey: .detectedObjects)) ?? []
            self.ocrLines = (try? container.decode([VisualAttachmentEvidence.OCRLine].self, forKey: .ocrLines)) ?? []
            self.ocrBlocks = (try? container.decode([VisualAttachmentEvidence.OCRBlock].self, forKey: .ocrBlocks)) ?? []
            self.imageMetadata = try? container.decode(VisualAttachmentEvidence.ImageMetadata.self, forKey: .imageMetadata)
            self.evidenceKind = try? container.decode(String.self, forKey: .evidenceKind)
        }
    }
}

public struct AttachmentVectorMetadata: Sendable, Codable, Equatable {
    public let kind: String
    public let attachmentId: String?
    public let filename: String
    public let mimeType: String
    public let modality: String
    public let evidenceKind: String?
    public let confidence: Float?
    public let visualSummary: String?
    public let attachmentSummary: String?
    public let labels: [String]
    public let objects: [String]
    public let ocrStartLineIndex: Int?
    public let ocrEndLineIndex: Int?
    public let boundingBoxes: [AttachmentEvidencePacket.BoundingBox]
    public let cardId: String?
    public let cardIndex: Int?
    public let chunkIndex: Int
    public let chunkCount: Int
    public let sourceLocator: String?
    public let pageNumber: Int?
    public let pageWidth: Double?
    public let pageHeight: Double?
    public let sourceBoundingBox: AttachmentSourceBoundingBox?
    public let blockType: String?
    public let textSource: String?
    public let sectionPath: [String]
    public let slideNumber: Int?
    public let slideTitle: String?
    public let sheetName: String?
    public let cellRange: String?
    public let sourceOrderStart: Int?
    public let sourceOrderEnd: Int?
    public let structuredChunkOrder: Int?

    private enum CodingKeys: String, CodingKey {
        case kind
        case attachmentId
        case filename
        case mimeType
        case modality
        case evidenceKind
        case confidence
        case visualSummary
        case attachmentSummary
        case labels
        case objects
        case ocrStartLineIndex
        case ocrEndLineIndex
        case boundingBoxes
        case cardId
        case cardIndex
        case chunkIndex
        case chunkCount
        case sourceLocator
        case pageNumber
        case pageWidth
        case pageHeight
        case sourceBoundingBox
        case blockType
        case textSource
        case sectionPath
        case slideNumber
        case slideTitle
        case sheetName
        case cellRange
        case sourceOrderStart
        case sourceOrderEnd
        case structuredChunkOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "attachmentEvidence"
        self.attachmentId = try container.decodeIfPresent(String.self, forKey: .attachmentId)
        self.filename = MIMEHeaderDecoder.decodeEncodedWords(
            try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        )
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        self.modality = try container.decodeIfPresent(String.self, forKey: .modality) ?? "extracted-text"
        self.evidenceKind = try container.decodeIfPresent(String.self, forKey: .evidenceKind)
        self.confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        self.visualSummary = try container.decodeIfPresent(String.self, forKey: .visualSummary)
        self.attachmentSummary = AttachmentSummaryPostProcessor.clean(
            try container.decodeIfPresent(String.self, forKey: .attachmentSummary)
        )
        self.labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.objects = try container.decodeIfPresent([String].self, forKey: .objects) ?? []
        self.ocrStartLineIndex = try container.decodeIfPresent(Int.self, forKey: .ocrStartLineIndex)
        self.ocrEndLineIndex = try container.decodeIfPresent(Int.self, forKey: .ocrEndLineIndex)
        self.boundingBoxes = try container.decodeIfPresent(
            [AttachmentEvidencePacket.BoundingBox].self,
            forKey: .boundingBoxes
        ) ?? []
        self.cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
        self.cardIndex = try container.decodeIfPresent(Int.self, forKey: .cardIndex)
        self.chunkIndex = try container.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
        self.chunkCount = max(1, try container.decodeIfPresent(Int.self, forKey: .chunkCount) ?? 1)
        self.sourceLocator = try container.decodeIfPresent(String.self, forKey: .sourceLocator)
        self.pageNumber = try container.decodeIfPresent(Int.self, forKey: .pageNumber)
        self.pageWidth = try container.decodeIfPresent(Double.self, forKey: .pageWidth)
        self.pageHeight = try container.decodeIfPresent(Double.self, forKey: .pageHeight)
        self.sourceBoundingBox = try container.decodeIfPresent(
            AttachmentSourceBoundingBox.self,
            forKey: .sourceBoundingBox
        )
        self.blockType = try container.decodeIfPresent(String.self, forKey: .blockType)
        self.textSource = try container.decodeIfPresent(String.self, forKey: .textSource)
        self.sectionPath = try container.decodeIfPresent([String].self, forKey: .sectionPath) ?? []
        self.slideNumber = try container.decodeIfPresent(Int.self, forKey: .slideNumber)
        self.slideTitle = try container.decodeIfPresent(String.self, forKey: .slideTitle)
        self.sheetName = try container.decodeIfPresent(String.self, forKey: .sheetName)
        self.cellRange = try container.decodeIfPresent(String.self, forKey: .cellRange)
        self.sourceOrderStart = try container.decodeIfPresent(Int.self, forKey: .sourceOrderStart)
        self.sourceOrderEnd = try container.decodeIfPresent(Int.self, forKey: .sourceOrderEnd)
        self.structuredChunkOrder = try container.decodeIfPresent(Int.self, forKey: .structuredChunkOrder)
    }

    public init(
        packet: AttachmentEvidencePacket?,
        attachmentId: String?,
        filename: String,
        mimeType: String,
        chunkIndex: Int,
        chunkCount: Int
    ) {
        self.kind = "attachmentEvidence"
        self.attachmentId = packet?.attachmentId ?? attachmentId
        self.filename = packet?.filename ?? MIMEHeaderDecoder.decodeEncodedWords(filename)
        self.mimeType = packet?.mimeType ?? mimeType
        self.modality = packet?.hasVisualEvidence == true ? "visual-attachment" : "extracted-text"
        self.evidenceKind = packet?.evidenceKind
        self.confidence = packet?.averageConfidence
        self.visualSummary = packet?.visualSummary
        self.attachmentSummary = packet?.attachmentSummary
        self.labels = packet?.labels.map(\.identifier) ?? []
        self.objects = packet?.objects.map(\.label) ?? []
        self.ocrStartLineIndex = nil
        self.ocrEndLineIndex = nil
        self.boundingBoxes = []
        self.cardId = nil
        self.cardIndex = nil
        self.chunkIndex = chunkIndex
        self.chunkCount = max(1, chunkCount)
        self.sourceLocator = nil
        self.pageNumber = nil
        self.pageWidth = nil
        self.pageHeight = nil
        self.sourceBoundingBox = nil
        self.blockType = nil
        self.textSource = nil
        self.sectionPath = []
        self.slideNumber = nil
        self.slideTitle = nil
        self.sheetName = nil
        self.cellRange = nil
        self.sourceOrderStart = nil
        self.sourceOrderEnd = nil
        self.structuredChunkOrder = nil
    }

    public init(
        card: AttachmentEvidenceCard,
        packet: AttachmentEvidencePacket?,
        cardIndex: Int,
        chunkIndex: Int,
        chunkCount: Int,
        ragMetadata: AttachmentRAGMetadata? = nil
    ) {
        self.kind = "attachmentEvidence"
        self.attachmentId = card.attachmentId ?? packet?.attachmentId
        self.filename = card.filename
        self.mimeType = card.mimeType
        self.modality = card.modality.rawValue
        self.evidenceKind = card.evidenceKind ?? packet?.evidenceKind
        self.confidence = card.confidence
        self.visualSummary = card.modality == .visualSummary ? card.text : packet?.visualSummary
        self.attachmentSummary = card.modality == .attachmentSummary ? card.text : packet?.attachmentSummary
        self.labels = packet?.labels.map(\.identifier) ?? []
        self.objects = packet?.objects.map(\.label) ?? []
        self.ocrStartLineIndex = card.ocrStartLineIndex
        self.ocrEndLineIndex = card.ocrEndLineIndex
        self.boundingBoxes = card.boundingBoxes
        self.cardId = card.id
        self.cardIndex = cardIndex
        self.chunkIndex = chunkIndex
        self.chunkCount = max(1, chunkCount)
        self.sourceLocator = ragMetadata?.sourceLocator
        self.pageNumber = ragMetadata?.pageNumber
        self.pageWidth = ragMetadata?.pageWidth
        self.pageHeight = ragMetadata?.pageHeight
        self.sourceBoundingBox = ragMetadata?.boundingBox
        self.blockType = ragMetadata?.blockType
        self.textSource = ragMetadata?.textSource
        self.sectionPath = ragMetadata?.sectionPath ?? []
        self.slideNumber = ragMetadata?.slideNumber
        self.slideTitle = ragMetadata?.slideTitle
        self.sheetName = ragMetadata?.sheetName
        self.cellRange = ragMetadata?.cellRange
        self.sourceOrderStart = ragMetadata?.sourceOrderStart
        self.sourceOrderEnd = ragMetadata?.sourceOrderEnd
        self.structuredChunkOrder = ragMetadata?.chunkOrder
    }

    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
