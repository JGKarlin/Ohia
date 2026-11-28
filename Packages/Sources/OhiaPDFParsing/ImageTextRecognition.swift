import Foundation
import OSLog

private let textRecognitionLogger = Logger(subsystem: "org.jgkarlin.Ohia", category: "ImageTextRecognition")

/// How one image's text recognition in `OhiaPDFParser.xpc` ended.
public enum TextRecognitionOutcome: Int, Sendable, Equatable {
    /// Vision read the image. The reply's lines may be empty: an image
    /// without text.
    case recognized = 0
    /// The image was empty, larger than `PDFParserLimits.maxInputBytes`, or
    /// declared an image whose decode would need more than
    /// `ImageDecodeBudget.maxDecodedBytes`.
    case invalidRequest = 1
    /// ImageIO could not decode the bytes as an image.
    case undecodable = 2
    /// Vision could not read this image, though it reads others; the
    /// reply's detail holds its error.
    case failed = 3
    /// Text recognition is broken in the service process that ran the
    /// request: Vision's recognition models failed to load there (see
    /// `PDFParserServiceEngine`), and a process stays broken once that
    /// happens. The service answers every later image this way too, and
    /// exits once every open connection has closed or belongs to a caller
    /// that acknowledged this reply (a watcher), or at the drain limit. The
    /// next request then runs in a fresh process.
    case recognizerUnavailable = 4
    /// The recognized lines exceeded `PDFParserLimits.maxOutputBytes`.
    case outputTooLarge = 5
    /// The service did not reply in time (the caller stopped waiting, or the
    /// app's relay answered a worker's request that waited too long), or the
    /// service's watchdog stopped a decode or recognition that overran its
    /// budget, answered it this way and exited. Not sent again at once
    /// (`ImageTextRecognition.recognize`); a later attempt may read the image
    /// (`isTransient`).
    case timedOut = 6
    /// The XPC service could not be reached, dropped the request, or sent a
    /// reply that does not decode.
    case serviceUnavailable = 7
    /// The caller's task was cancelled while it waited. Produced on the
    /// caller's side only; the service never sends it.
    case cancelled = 8
}

extension TextRecognitionOutcome {
    /// The image's text was not read now, but a later attempt, in a fresh
    /// service process, may read it: the service timed out, could not be
    /// reached, or its recognizer was broken. Every other outcome is final
    /// for this image (`.cancelled` aside, which says only that the caller
    /// stopped waiting).
    public var isTransient: Bool {
        switch self {
        case .timedOut, .serviceUnavailable, .recognizerUnavailable:
            return true
        case .recognized, .invalidRequest, .undecodable, .failed, .outputTooLarge, .cancelled:
            return false
        }
    }
}

/// One line of text Vision read, with its top candidate's confidence and
/// its bounding box as Vision reports it: normalized to the upright image,
/// origin at the lower left.
public struct RecognizedTextLine: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, confidence: Float, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TextRecognitionReply: Sendable, Equatable {
    public let outcome: TextRecognitionOutcome
    /// The lines in Vision's order. Empty unless the outcome is `.recognized`.
    public let lines: [RecognizedTextLine]
    /// Vision's error for `.failed` and `.recognizerUnavailable`, at most
    /// `PDFParserLimits.maxStderrBytes` characters; otherwise empty.
    public let detail: String

    public init(outcome: TextRecognitionOutcome, lines: [RecognizedTextLine] = [], detail: String = "") {
        self.outcome = outcome
        self.lines = outcome == .recognized ? lines : []
        self.detail = String(detail.prefix(PDFParserLimits.maxStderrBytes))
    }

    /// The lines as they cross XPC, as JSON. Nil unless the outcome is
    /// `.recognized`.
    public var wireOutput: Data? {
        guard outcome == .recognized else { return nil }
        return try? JSONEncoder().encode(lines)
    }

    /// A reply as it arrives over XPC. An unknown outcome, or recognized
    /// lines that do not decode, are treated as the service being
    /// unavailable.
    public init(wireOutput: Data?, rawOutcome: Int, detail: String?) {
        guard let outcome = TextRecognitionOutcome(rawValue: rawOutcome) else {
            self.init(outcome: .serviceUnavailable)
            return
        }
        guard outcome == .recognized else {
            self.init(outcome: outcome, detail: detail ?? "")
            return
        }
        guard let wireOutput,
              let lines = try? JSONDecoder().decode([RecognizedTextLine].self, from: wireOutput) else {
            self.init(outcome: .serviceUnavailable)
            return
        }
        self.init(outcome: .recognized, lines: lines)
    }
}

/// Text recognition for images from mail and the user's sources. Images,
/// like PDFs, arrive from anyone who can send mail, and a process whose
/// Vision recognizer breaks stays broken, so their text is recognized only
/// inside `OhiaPDFParser.xpc`, reached through `PDFParserRoute`.
public enum ImageTextRecognition {
    /// Recognizes the text in one image: a `PDFParserRoute.Service`'s
    /// `recognizeText`.
    public typealias Recognize = @Sendable (_ image: Data) -> TextRecognitionReply

    /// Recognizes `image` with `recognize`, and sends it once more when the
    /// reply says the service process could not do it: its recognizer was
    /// broken (`PDFParserXPCClient` acknowledges that reply and returns it
    /// once the process has exited), or the service was unreachable, as when
    /// the request reached a process that was exiting. The retry goes out
    /// right away and reaches a fresh service process, which launchd may
    /// take about 10 seconds to start after a young one exited. It is part of
    /// the one request: callers do not count it as another attempt. A second
    /// such reply is returned as it is, for the caller to treat as transient
    /// (`TextRecognitionOutcome.isTransient`). A `.timedOut` reply is never
    /// sent again at once: the image itself may be what overran, and the
    /// service exited over it.
    public static func recognize(_ image: Data, using recognize: Recognize) -> TextRecognitionReply {
        let first = recognize(image)
        guard first.outcome == .recognizerUnavailable || first.outcome == .serviceUnavailable else {
            log(first)
            return first
        }
        textRecognitionLogger.notice(
            "Image text recognition outcome=\(String(describing: first.outcome), privacy: .public); retrying once in a fresh parser service process"
        )
        let second = recognize(image)
        log(second)
        return second
    }

    /// Records why an image's text was not read, so a broken service
    /// (signing, sandbox, crash, Vision's models) is visible.
    private static func log(_ reply: TextRecognitionReply) {
        switch reply.outcome {
        case .recognized, .undecodable, .invalidRequest, .cancelled:
            return
        case .failed, .recognizerUnavailable, .outputTooLarge, .timedOut, .serviceUnavailable:
            textRecognitionLogger.error(
                "Image text recognition failed outcome=\(String(describing: reply.outcome), privacy: .public)"
            )
        }
    }
}
