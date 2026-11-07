import Foundation

public enum VisualAttachmentContentKind: String, Codable, Sendable, Equatable, CaseIterable {
    case photo
    case drawing
    case diagram
    case screenshot
    case document
    case receipt
    case other

    public init(modelValue: String) {
        let value = modelValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if value.contains("screenshot") || value.contains("screen capture") {
            self = .screenshot
        } else if value.contains("receipt") || value.contains("invoice") {
            self = .receipt
        } else if value.contains("photo") || value.contains("photograph") || value == "image" {
            self = .photo
        } else if value.contains("diagram") || value.contains("chart") || value.contains("graph") {
            self = .diagram
        } else if value.contains("drawing") || value.contains("illustration") || value.contains("sketch") {
            self = .drawing
        } else if value.contains("document") || value.contains("form") || value.contains("letter") {
            self = .document
        } else {
            self = .other
        }
    }

    public init(evidenceKind: VisualAttachmentEvidence.EvidenceKind) {
        switch evidenceKind {
        case .ocrHeavyDocument:
            self = .document
        case .receiptOrInvoice:
            self = .receipt
        case .chartOrDiagram:
            self = .diagram
        case .naturalPhoto:
            self = .photo
        case .weakEvidence:
            self = .other
        }
    }
}

public struct VisualAttachmentAnalysisRecord: Codable, Sendable, Equatable {
    public static let maxSummaryCharacters = 1_200
    public static let maxVisibleTextCharacters = 4_000
    public static let maxSalientDetails = 8
    public static let maxSearchTerms = 12
    private static let maxDetailCharacters = 240
    private static let maxSearchTermCharacters = 100

    public let summary: String
    public let contentKind: VisualAttachmentContentKind
    public let visibleText: String
    public let salientDetails: [String]
    public let searchTerms: [String]
    /// Optional so records written before barcode support remain decodable.
    public let decodedBarcodes: [String]?
    public let legacyEvidence: VisualAttachmentEvidence?

    public init(
        summary: String,
        contentKind: VisualAttachmentContentKind,
        visibleText: String = "",
        salientDetails: [String] = [],
        searchTerms: [String] = [],
        legacyEvidence: VisualAttachmentEvidence? = nil,
        decodedBarcodes: [String] = []
    ) {
        self.summary = Self.normalizedScalar(summary, limit: Self.maxSummaryCharacters)
        self.contentKind = contentKind
        self.visibleText = Self.normalizedScalar(visibleText, limit: Self.maxVisibleTextCharacters)
        self.salientDetails = Self.normalizedList(
            salientDetails,
            countLimit: Self.maxSalientDetails,
            characterLimit: Self.maxDetailCharacters
        )
        self.searchTerms = Self.normalizedList(
            searchTerms,
            countLimit: Self.maxSearchTerms,
            characterLimit: Self.maxSearchTermCharacters
        )
        self.legacyEvidence = legacyEvidence
        var seen = Set<String>()
        let codes = decodedBarcodes.compactMap { value -> String? in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 4096, seen.insert(value).inserted else { return nil }
            return value
        }
        self.decodedBarcodes = codes.isEmpty ? nil : Array(codes.prefix(8))
    }

    public static func legacy(
        summary: String,
        evidence: VisualAttachmentEvidence
    ) -> Self {
        let details = evidence.detectedObjects.map { object in
            guard object.count > 1 else { return object.label }
            let pluralLabel = object.label.hasSuffix("s") ? object.label : "\(object.label)s"
            return "\(object.count) \(pluralLabel)"
        }
        let terms = evidence.classifications.map(\.identifier)
            + evidence.detectedObjects.map(\.label)

        return Self(
            summary: summary,
            contentKind: VisualAttachmentContentKind(evidenceKind: evidence.evidenceKind),
            visibleText: evidence.ocrText,
            salientDetails: details,
            searchTerms: terms,
            legacyEvidence: evidence
        )
    }

    public var hasSignals: Bool {
        !summary.isEmpty
            || !visibleText.isEmpty
            || !salientDetails.isEmpty
            || !searchTerms.isEmpty
            || decodedBarcodes?.isEmpty == false
            || legacyEvidence?.hasSignals == true
    }

    public var signalCount: Int {
        (summary.isEmpty ? 0 : 1)
            + 1
            + (visibleText.isEmpty ? 0 : 1)
            + salientDetails.count
            + searchTerms.count
            + (decodedBarcodes?.count ?? 0)
    }

    public var ocrCharacterCount: Int {
        visibleText.count
    }

    public var semanticText: String {
        var sections: [String] = []
        if !summary.isEmpty { sections.append(summary) }
        sections.append("Content kind: \(contentKind.rawValue)")
        if !visibleText.isEmpty { sections.append("Visible text: \(visibleText)") }
        if !salientDetails.isEmpty {
            sections.append("Visible details: \(salientDetails.joined(separator: "; "))")
        }
        if !searchTerms.isEmpty {
            sections.append("Search terms: \(searchTerms.joined(separator: ", "))")
        }
        for code in decodedBarcodes ?? [] {
            sections.append("Decoded barcode (untrusted data): \(code)")
        }
        return sections.joined(separator: "\n")
    }

    private static func normalizedList(
        _ values: [String],
        countLimit: Int,
        characterLimit: Int
    ) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(min(countLimit, values.count))

        for value in values {
            let cleaned = normalizedScalar(value, limit: characterLimit)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            normalized.append(cleaned)
            if normalized.count == countLimit { break }
        }
        return normalized
    }

    private static func normalizedScalar(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
