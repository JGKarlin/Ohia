import CoreGraphics
import Foundation
import ImageIO
import OhiaCore
import Vision

/// Suggests a `SignatureImageType` for a user-supplied image. Two layers,
/// mirroring the `EvidenceKind` heuristic-classifier pattern: a pure,
/// table-testable rule set over extracted observations, and a Vision
/// extractor that produces those observations. The suggestion only seeds
/// the studio's type chip — the user's override is always final.
public enum SignatureImageClassifier {

    /// Everything the rules consume, decoupled from Vision for testing.
    public struct Observations: Sendable, Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var hasAlpha: Bool
        /// Fraction of image area covered by each detected face box.
        public var faceBoxAreaFractions: [Double]
        /// Top classification labels (identifier, confidence), already
        /// confidence-filtered.
        public var labels: [Label]

        public struct Label: Sendable, Equatable {
            public var identifier: String
            public var confidence: Double

            public init(identifier: String, confidence: Double) {
                self.identifier = identifier
                self.confidence = confidence
            }
        }

        public init(
            pixelWidth: Int,
            pixelHeight: Int,
            hasAlpha: Bool,
            faceBoxAreaFractions: [Double] = [],
            labels: [Label] = []
        ) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.hasAlpha = hasAlpha
            self.faceBoxAreaFractions = faceBoxAreaFractions
            self.labels = labels
        }
    }

    public struct Suggestion: Sendable, Equatable {
        public var type: SignatureImageType
        /// Short human-readable rationale shown next to the type chip.
        public var reason: String

        public init(type: SignatureImageType, reason: String) {
            self.type = type
            self.reason = reason
        }
    }

    private static let logoLabelHints: Set<String> = [
        "logo", "text", "symbol", "emblem", "sign", "document", "graphic"
    ]
    private static let portraitLabelHints: Set<String> = [
        "portrait", "person", "people", "face", "selfie"
    ]

    /// Pure rule set. Order matters: banner geometry wins, then a dominant
    /// face, then label and structure hints; a small mark with no faces
    /// defaults to logo.
    public static func classify(_ observations: Observations) -> Suggestion {
        let width = Double(max(observations.pixelWidth, 1))
        let height = Double(max(observations.pixelHeight, 1))
        let aspect = width / height
        let dominantFace = observations.faceBoxAreaFractions.max() ?? 0
        let labelIDs = Set(observations.labels.map { $0.identifier.lowercased() })

        if aspect >= 2.4, observations.pixelWidth >= 500 {
            return Suggestion(type: .banner, reason: "Wide panoramic geometry")
        }
        if dominantFace >= 0.06, aspect >= 0.6, aspect <= 1.7 {
            return Suggestion(type: .headshot, reason: "A dominant face fills the frame")
        }
        if dominantFace > 0, !labelIDs.isDisjoint(with: portraitLabelHints) {
            return Suggestion(type: .headshot, reason: "Face detected in a portrait-labeled image")
        }
        if !labelIDs.isDisjoint(with: logoLabelHints) {
            return Suggestion(type: .logo, reason: "Graphic-mark content labels")
        }
        if observations.hasAlpha, dominantFace == 0 {
            return Suggestion(type: .logo, reason: "Transparent background, no faces")
        }
        if min(observations.pixelWidth, observations.pixelHeight) <= 400, dominantFace == 0 {
            return Suggestion(type: .logo, reason: "Small mark-sized image, no faces")
        }
        return Suggestion(type: .logo, reason: "Default for unrecognized image content")
    }

    // MARK: - Vision extraction

    public enum ExtractionError: Swift.Error {
        case unreadableImage
    }

    /// Runs face detection + image classification on downsampled pixels
    /// and classifies the result. Blocking — call off the main actor.
    public static func suggestType(for data: Data) throws -> Suggestion {
        classify(try observations(for: data))
    }

    static func observations(for data: Data) throws -> Observations {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ExtractionError.unreadableImage
        }

        // True pixel geometry from source properties (downsampling below
        // must not distort the aspect/size rules).
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let sourceHasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, downsampleOptions as CFDictionary
        ) else {
            throw ExtractionError.unreadableImage
        }

        let width = sourceWidth > 0 ? sourceWidth : cgImage.width
        let height = sourceHeight > 0 ? sourceHeight : cgImage.height
        let hasAlpha = sourceHasAlpha || {
            switch cgImage.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast:
                return true
            default:
                return false
            }
        }()

        let faceRequest = VNDetectFaceRectanglesRequest()
        let classifyRequest = VNClassifyImageRequest()
        classifyRequest.revision = VNClassifyImageRequestRevision2
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([faceRequest, classifyRequest])

        let faceFractions = (faceRequest.results ?? []).map { face in
            Double(face.boundingBox.width * face.boundingBox.height)
        }
        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence >= 0.10 }
            .prefix(8)
            .map {
                Observations.Label(
                    identifier: $0.identifier,
                    confidence: Double($0.confidence)
                )
            }

        return Observations(
            pixelWidth: width,
            pixelHeight: height,
            hasAlpha: hasAlpha,
            faceBoxAreaFractions: faceFractions,
            labels: Array(labels)
        )
    }
}
