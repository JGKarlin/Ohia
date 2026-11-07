import Foundation
import OhiaCore

public enum AttachmentExtractionRetryPolicy {
    public static let version = "attachment-extraction-retry-v1"
    public static let maxRetryAttempts = 3

    private static let retryDelays: [TimeInterval] = [
        5 * 60,
        30 * 60
    ]

    public static func recordAttempt(
        attachment: Attachment,
        result: AttachmentExtractionResult,
        attemptedAt: Date = Date()
    ) {
        let currentCount = attachment.extractionRetryPolicyVersion == version
            ? max(0, attachment.extractionAttemptCount ?? 0)
            : 0
        let nextCount = currentCount + 1
        attachment.extractionAttemptCount = nextCount
        attachment.extractionLastAttemptedAt = attemptedAt
        attachment.extractionRetryPolicyVersion = version

        guard shouldRetry(result: result),
              nextCount < maxRetryAttempts else {
            attachment.extractionNextRetryAt = nil
            attachment.extractionRetryReason = nil
            return
        }

        attachment.extractionNextRetryAt = attemptedAt.addingTimeInterval(delay(afterAttempt: nextCount))
        attachment.extractionRetryReason = result.failureReason ?? result.status.rawValue
    }

    public static func isRetryCandidate(
        attachment: Attachment,
        now: Date = Date()
    ) -> Bool {
        guard attachment.extractedTextPath == nil else { return false }
        guard attachment.extractionRetryPolicyVersion == version else { return false }
        guard max(0, attachment.extractionAttemptCount ?? 0) < maxRetryAttempts else {
            return false
        }
        guard let nextRetryAt = attachment.extractionNextRetryAt,
              nextRetryAt <= now else {
            return false
        }
        guard let status = attachment.extractionStatus,
              status == AttachmentExtractionStatus.parseFailed.rawValue else {
            return false
        }
        return DocumentKind
            .detect(mimeType: attachment.mimeType, filename: attachment.filename)
            .isTextBearing
    }

    public static func shouldRetry(result: AttachmentExtractionResult) -> Bool {
        result.status == .parseFailed
    }

    private static func delay(afterAttempt attempt: Int) -> TimeInterval {
        let index = max(0, min(retryDelays.count - 1, attempt - 1))
        return retryDelays[index]
    }
}
