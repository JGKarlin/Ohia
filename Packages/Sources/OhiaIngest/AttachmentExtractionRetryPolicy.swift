import Foundation
import OhiaCore

/// When an attachment whose extraction failed in a way another attempt could
/// fix is tried again: 5 minutes after the first attempt, 30 minutes after
/// the second, and not after the third. Text extraction keeps its schedule in
/// the `extraction*` fields (`recordAttempt`, `scheduledRetry`,
/// `isRetryCandidate`); visual extraction, whose image text recognition can
/// be temporarily unavailable, uses the same schedule (`schedule`,
/// `scheduledVisualRetry`) for its own fields.
///
/// A text extraction is retried when it failed (`.parseFailed`), or when it
/// completed while text recognition was temporarily unavailable
/// (`AttachmentExtractionResult.textRecognitionUnavailable`): a scanned PDF
/// or an image then has its description, but not the text in its pixels.
/// Such a completed attempt keeps its extracted text while it waits; the
/// retry replaces that text only with an attempt that read some.
public enum AttachmentExtractionRetryPolicy {
    public static let version = "attachment-extraction-retry-v1"
    public static let maxRetryAttempts = 3

    private static let retryDelays: [TimeInterval] = [
        5 * 60,
        30 * 60
    ]

    /// One more attempt, after `previousAttempts`: how many attempts there
    /// have now been, and when to try again. `nextRetryAt` is nil when the
    /// attempt needs no retry or the attempts are spent.
    public static func schedule(
        previousAttempts: Int,
        retryable: Bool,
        attemptedAt: Date
    ) -> (attempts: Int, nextRetryAt: Date?) {
        let attempts = max(0, previousAttempts) + 1
        guard retryable, attempts < maxRetryAttempts else { return (attempts, nil) }
        return (attempts, attemptedAt.addingTimeInterval(delay(afterAttempt: attempts)))
    }

    /// Whether a retry `schedule` set is due at `now`.
    public static func isDue(attempts: Int, nextRetryAt: Date?, now: Date) -> Bool {
        pendingRetry(attempts: attempts, nextRetryAt: nextRetryAt).map { $0 <= now } ?? false
    }

    /// The retry `schedule` set, while attempts remain.
    private static func pendingRetry(attempts: Int, nextRetryAt: Date?) -> Date? {
        max(0, attempts) < maxRetryAttempts ? nextRetryAt : nil
    }

    public static func recordAttempt(
        attachment: Attachment,
        result: AttachmentExtractionResult,
        attemptedAt: Date = Date()
    ) {
        let previous = attachment.extractionRetryPolicyVersion == version
            ? attachment.extractionAttemptCount ?? 0
            : 0
        let next = schedule(previousAttempts: previous, retryable: shouldRetry(result: result), attemptedAt: attemptedAt)
        attachment.extractionAttemptCount = next.attempts
        attachment.extractionLastAttemptedAt = attemptedAt
        attachment.extractionRetryPolicyVersion = version
        attachment.extractionNextRetryAt = next.nextRetryAt
        attachment.extractionRetryReason = next.nextRetryAt == nil
            ? nil
            : result.failureReason ?? result.status.rawValue
    }

    /// Whether the attachment's retry is due (`scheduledRetry`).
    public static func isRetryCandidate(
        attachment: Attachment,
        now: Date = Date()
    ) -> Bool {
        scheduledRetry(of: attachment).map { $0 <= now } ?? false
    }

    /// When the attachment's text extraction is tried again, once that time
    /// has come: after a failed attempt without extracted text, or a
    /// completed one whose text recognition was unavailable, which has its
    /// text. `recordAttempt` schedules a retry for nothing else. Nil when no
    /// retry is scheduled or the attempts are spent.
    public static func scheduledRetry(of attachment: Attachment) -> Date? {
        guard attachment.extractionRetryPolicyVersion == version,
              let nextRetryAt = pendingRetry(
                  attempts: attachment.extractionAttemptCount ?? 0,
                  nextRetryAt: attachment.extractionNextRetryAt
              ) else { return nil }
        switch attachment.extractionStatus {
        case AttachmentExtractionStatus.completed.rawValue:
            break
        case .some:
            guard attachment.extractedTextPath == nil else { return nil }
        case nil:
            return nil
        }
        return attachment.declaredKind.isTextBearing ? nextRetryAt : nil
    }

    /// When an image's visual extraction is tried again for the text in its
    /// pixels, which could not be read for now
    /// (`Attachment.applyVisualExtractionResult`), once that time has come.
    /// Nil when no retry is scheduled, the attempts are spent, or the
    /// attachment is not an image.
    public static func scheduledVisualRetry(of attachment: Attachment) -> Date? {
        guard attachment.declaredKind == .image else { return nil }
        return pendingRetry(
            attempts: attachment.visualExtractionAttemptCount ?? 0,
            nextRetryAt: attachment.visualExtractionNextRetryAt
        )
    }

    public static func shouldRetry(result: AttachmentExtractionResult) -> Bool {
        result.status == .parseFailed || result.textRecognitionUnavailable
    }

    private static func delay(afterAttempt attempt: Int) -> TimeInterval {
        let index = max(0, min(retryDelays.count - 1, attempt - 1))
        return retryDelays[index]
    }
}
