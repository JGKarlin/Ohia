import Foundation
import OhiaCore

struct BodySpanIndex: Equatable {
    struct SourceChunk: Sendable, Equatable {
        let vectorId: Int64
        let collection: VectorCollection
        let textPayload: String
        let metadataJSON: String

        init(vectorId: Int64, collection: VectorCollection, textPayload: String, metadataJSON: String) {
            self.vectorId = vectorId
            self.collection = collection
            self.textPayload = textPayload
            self.metadataJSON = metadataJSON
        }
    }

    struct Span: Equatable {
        let vectorId: Int64
        let range: Range<String.Index>
    }

    let spans: [Span]

    var spansByVectorId: [Int64: Range<String.Index>] {
        Dictionary(uniqueKeysWithValues: spans.map { ($0.vectorId, $0.range) })
    }

    static func build(bodyText: String, chunks: [SourceChunk]) -> BodySpanIndex {
        let spans = chunks.compactMap { chunk -> Span? in
            guard chunk.collection == .context else { return nil }
            let metadata = ChunkMetadata(json: chunk.metadataJSON)
            if let range = metadata.validRange(in: bodyText) {
                return Span(vectorId: chunk.vectorId, range: range)
            }
            let fallbackNeedle = metadata.bodyChunkText
                ?? legacyBodyChunk(from: chunk.textPayload)
                ?? chunk.textPayload
            guard let range = uniqueRange(of: fallbackNeedle, in: bodyText) else { return nil }
            return Span(vectorId: chunk.vectorId, range: range)
        }
        .sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            if $0.range.upperBound != $1.range.upperBound {
                return $0.range.upperBound < $1.range.upperBound
            }
            return $0.vectorId < $1.vectorId
        }
        return BodySpanIndex(spans: spans)
    }

    private static func uniqueRange(of needle: String, in bodyText: String) -> Range<String.Index>? {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let first = bodyText.range(of: trimmed) else { return nil }
        let remainder = bodyText[first.upperBound...]
        guard remainder.range(of: trimmed) == nil else { return nil }
        return first
    }

    private static func legacyBodyChunk(from payload: String) -> String? {
        guard let bodyMarker = payload.range(of: "BODY:") else { return nil }
        let body = payload[bodyMarker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private struct ChunkMetadata {
        let bodyRangeStart: Int?
        let bodyRangeEnd: Int?
        let bodyChunkText: String?

        init(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                bodyRangeStart = nil
                bodyRangeEnd = nil
                bodyChunkText = nil
                return
            }
            bodyRangeStart = object["bodyRangeStart"] as? Int
            bodyRangeEnd = object["bodyRangeEnd"] as? Int
            bodyChunkText = object["bodyChunkText"] as? String
        }

        func validRange(in bodyText: String) -> Range<String.Index>? {
            guard let bodyRangeStart,
                  let bodyRangeEnd,
                  bodyRangeStart >= 0,
                  bodyRangeEnd > bodyRangeStart,
                  bodyRangeEnd <= bodyText.utf16.count,
                  let lower = stringIndex(utf16Offset: bodyRangeStart, in: bodyText),
                  let upper = stringIndex(utf16Offset: bodyRangeEnd, in: bodyText),
                  lower < upper else {
                return nil
            }
            return lower..<upper
        }

        private func stringIndex(utf16Offset: Int, in text: String) -> String.Index? {
            guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
            let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
            return utf16Index.samePosition(in: text)
        }
    }
}
