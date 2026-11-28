import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OSLog
import OhiaPDFParsing
import Vision

private let recognizerLogger = Logger(subsystem: "org.jgkarlin.Ohia.PDFParser", category: "Engine")

/// The only code in Ohia that recognizes text in an image. It is linked into
/// `OhiaPDFParser.xpc` alone (see `PDFParserServiceEngine`), so an untrusted
/// image reaches Vision's text recognition, and the ImageIO decode that feeds
/// it, only in the service. (The app and the workers still decode images
/// with ImageIO for thumbnails and for Vision's classification and
/// detection, which are not text recognition.)
enum ImageTextRecognizer {
    /// The first image in `data`, decoded with ImageIO. ImageIO on macOS 27
    /// also opens a PDF, so only the raster types it declares are decoded
    /// (`ImageDecodeBudget.rasterTypes`): a PDF named like an image is
    /// undecodable here, and PDFs reach PDFKit only through the parse and
    /// render requests. (NSImage is not used: it would open a PDF too.)
    /// `ImageDecodeBudget` reads the header first: an image whose whole
    /// decode would need more than `maxDecodedBytes` is refused, and one
    /// that would take more than `recognitionBytes` is decoded straight to
    /// a smaller copy that takes that much at its own depth, so a small file
    /// that declares a huge or deep image never expands into gigabytes. The
    /// copy keeps the aspect ratio: a long screenshot keeps its width, and
    /// its text, legible. The image comes back upright (ImageIO applies its
    /// EXIF orientation) and at 8 bits per channel.
    static func decode(
        _ data: Data,
        maxDecodedBytes: Int = ImageDecodeBudget.maxDecodedBytes,
        recognitionBytes: Int = PDFParserLimits.imageRecognitionBytes
    ) -> ImageDecodeBudget.Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .undecodable }
        return ImageDecodeBudget.thumbnail(of: source, maxBytes: recognitionBytes, maxDecodedBytes: maxDecodedBytes)
    }

    /// Every line Vision reads in the upright image, in Vision's order.
    /// Vision picks the recognition model for each image
    /// (`automaticallyDetectsLanguage`): a fixed language list reads only
    /// scripts its first language's model covers, so text in any other script
    /// would be lost. Language correction stays on (Vision's default).
    /// Throws Vision's error, whether `perform` throws it or the request's
    /// completion reports it, and `RecognitionError.noResults` when the
    /// request ends without results: a request that did not run is never an
    /// image without text.
    static func recognize(_ image: CGImage) throws -> [RecognizedTextLine] {
        let completion = RequestCompletion()
        let request = VNRecognizeTextRequest { _, error in completion.record(error) }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        if let error = completion.error { throw error }
        guard let observations = request.results else { throw RecognitionError.noResults }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedTextLine(
                text: candidate.string,
                confidence: candidate.confidence,
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.width),
                height: Double(box.height)
            )
        }
    }

    enum RecognitionError: Error, LocalizedError {
        case noResults

        var errorDescription: String? { "Vision's text recognition ended without results" }
    }

    // MARK: Broken recognizer

    enum Failure: Equatable {
        /// The error is about this image; the recognizer works.
        case image
        /// The recognizer is broken in this process.
        case brokenRecognizer
    }

    /// What a Vision error means. An error Vision raises for a malformed
    /// image (`isImageProblem`) is the image's, with no further check. For
    /// any other error, TextRecognition's E5RT error (`isBrokenRecognizer`)
    /// included, `recognizerWorks` reads a built-in image with known text
    /// (`probe`): if that fails too, the recognizer is broken, however it
    /// reported it; if it reads the probe, the error is this image's. The
    /// E5RT error is matched by domain and code, which every
    /// `CRImageReaderError.e5rtError` shares whatever its E5RT status, so
    /// it too is confirmed before the service retires: an image that raised
    /// it while the probe still reads is logged at fault level, as it would
    /// mean an E5RT failure that depends on the image.
    static func failure(of error: any Error, recognizerWorks: () -> Bool) -> Failure {
        let isKnownBreakage = isBrokenRecognizer(error)
        if !isKnownBreakage, isImageProblem(error) { return .image }
        guard recognizerWorks() else { return .brokenRecognizer }
        if isKnownBreakage {
            let nsError = error as NSError
            recognizerLogger.fault(
                "TextRecognition's E5RT error for one image while the probe image still reads errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public); treating it as the image's"
            )
        }
        return .image
    }

    /// The domain and code under which a Swift error from Apple's private
    /// TextRecognition framework, `CRImageReaderError.e5rtError(_:_:)`,
    /// reaches Vision's callers.
    static let brokenRecognizerErrorDomain = "TextRecognition.CRImageReaderError"
    static let brokenRecognizerErrorCode = 1

    /// True for the failure seen to leave a process unable to recognize text
    /// for its lifetime. When a process's first recognition meets heavy ML
    /// load, preparing Vision's recognition networks can fail: E5RT reports
    /// `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options
    /// call failed (Code: 13)`, and every recognition in that process from
    /// then on, CPU-only ones too, throws
    /// `CRImageReaderError.e5rtError(_, 13)` at once. A fresh process
    /// recognizes the same images. Vision passes the error on unwrapped today;
    /// the underlying-error chain is searched too, should it ever wrap it.
    static func isBrokenRecognizer(_ error: any Error) -> Bool {
        errorChain(error).contains { $0.domain == brokenRecognizerErrorDomain && $0.code == brokenRecognizerErrorCode }
    }

    /// True for the errors Vision raises for an image it cannot take:
    /// `VNError.invalidImage` and `VNError.invalidFormat`. The recognizer is
    /// not in question, so no probe runs.
    static func isImageProblem(_ error: any Error) -> Bool {
        let imageCodes = [VNErrorCode.invalidImage.rawValue, VNErrorCode.invalidFormat.rawValue]
        return errorChain(error).contains { $0.domain == VNErrorDomain && imageCodes.contains($0.code) }
    }

    private static func errorChain(_ error: any Error) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let candidate = current, chain.count < 8 {
            chain.append(candidate)
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// The text drawn in `probeImage`.
    static let probeText = "Invoice 4096"

    /// Whether `recognize` reads `probeImage`'s text: a working recognizer
    /// does, a broken one throws or reads nothing.
    static func probe(using recognize: (CGImage) throws -> [RecognizedTextLine]) -> Bool {
        guard let image = probeImage, let lines = try? recognize(image) else { return false }
        let read = lines.map(\.text).joined(separator: " ").lowercased().filter { !$0.isWhitespace }
        return read.contains(probeText.lowercased().filter { !$0.isWhitespace })
    }

    /// Black text on white, drawn once with Core Text.
    static let probeImage: CGImage? = {
        let width = 480
        let height = 120
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.system, 56, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let text = NSAttributedString(string: probeText, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 32, y: 36)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }()
}

/// The error a Vision request's completion handler reported, if any.
private final class RequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: (any Error)?

    var error: (any Error)? { lock.withLock { recorded } }

    func record(_ error: (any Error)?) {
        guard let error else { return }
        lock.withLock { recorded = error }
    }
}
