import Foundation
import OhiaIngest
import OhiaML
import OhiaScheduler

enum LockedAttachmentExtractionQueue: Sendable, Equatable {
    case document
    case visual
}

struct LockedAttachmentExtractionStatus: Equatable {
    enum Tone: Equatable {
        case pending
        case waiting
        case terminal
        case failed
    }

    struct Badge: Equatable {
        let label: String
        let tone: Tone
        let help: String
    }

    enum State: Equatable {
        case ready
        case queued(LockedAttachmentExtractionQueue)
        case waitingForAppleIntelligence
        case unsupported
        case missingFile
        case tooLarge
        case encrypted
        case empty
        case blocked(String?)
        case failed(String?)
        case stalled(String?)
        /// An iCloud Mail Drop file: no local bytes, a link until `expiresAt`.
        case mailDrop(expiresAt: Date?, expired: Bool)
    }

    let state: State

    nonisolated var badge: Badge? {
        switch state {
        case .ready:
            return nil
        case .queued(.document):
            return Badge(
                label: "queued",
                tone: .pending,
                help: "Document text extraction is queued."
            )
        case .queued(.visual):
            return Badge(
                label: "queued",
                tone: .pending,
                help: "Preparing an image description. It will refresh when local image analysis finishes."
            )
        case .waitingForAppleIntelligence:
            return Badge(
                label: "waiting ai",
                tone: .waiting,
                help: "Image descriptions require Apple Intelligence. They will appear when it is available."
            )
        case .unsupported:
            return Badge(
                label: "binary",
                tone: .terminal,
                help: "This attachment type is not extractable here, so it is not part of the orientation paragraph."
            )
        case .missingFile:
            return Badge(
                label: "missing",
                tone: .terminal,
                help: "The attachment metadata exists, but the saved binary is missing, so extraction cannot run."
            )
        case .tooLarge:
            return Badge(
                label: "too large",
                tone: .terminal,
                help: "This attachment is over the local extraction size limit."
            )
        case .encrypted:
            return Badge(
                label: "locked",
                tone: .terminal,
                help: "This attachment appears to be encrypted or password-protected."
            )
        case .empty:
            return Badge(
                label: "no text",
                tone: .terminal,
                help: "Extraction ran, but no usable text or visual evidence was found."
            )
        case .blocked(let reason):
            return Badge(
                label: "blocked",
                tone: .failed,
                help: reason.map { "Image description was blocked: \($0)" }
                    ?? "Image description was blocked by the local model."
            )
        case .failed(let reason):
            return Badge(
                label: "failed",
                tone: .failed,
                help: reason.map { "Extraction failed: \($0)" }
                    ?? "Extraction failed."
            )
        case .stalled(let reason):
            return Badge(
                label: "stalled",
                tone: .failed,
                help: reason.map { "Extraction is not retryable from its current metadata: \($0)" }
                    ?? "Extraction is not retryable from its current metadata."
            )
        case .mailDrop(let expiresAt, let expired):
            let day = expiresAt?.formatted(.dateTime.month(.abbreviated).day())
            let fullDate = expiresAt?.formatted(date: .long, time: .omitted)
            if expired {
                return Badge(
                    label: day.map { "Mail Drop · expired \($0)" } ?? "Mail Drop · expired",
                    tone: .terminal,
                    help: fullDate.map { "The sender's iCloud Mail Drop link expired on \($0), so the file can no longer be opened." }
                        ?? "The sender's iCloud Mail Drop link has expired, so the file can no longer be opened."
                )
            }
            return Badge(
                label: day.map { "Mail Drop · expires \($0)" } ?? "Mail Drop",
                tone: .terminal,
                help: fullDate.map { "Stored on iCloud by the sender's Mail Drop. The link opens the file until \($0)." }
                    ?? "Stored on iCloud by the sender's Mail Drop. The link opens the file."
            )
        }
    }

    nonisolated var pendingQueue: LockedAttachmentExtractionQueue? {
        guard case .queued(let queue) = state else { return nil }
        return queue
    }

    nonisolated var annotationState: AnnotationItem.AttachmentReference.ExtractionState {
        switch state {
        case .ready:
            return .ready
        case .queued:
            return .extracting
        case .waitingForAppleIntelligence:
            return .waitingForAppleIntelligence
        case .unsupported, .mailDrop:
            return .unsupported
        case .missingFile, .tooLarge, .encrypted, .empty, .blocked, .failed, .stalled:
            return .unavailable
        }
    }

    nonisolated static func classify(
        _ attachment: LockedAttachmentSummary,
        appleIntelligenceAvailable: Bool = AppleIntelligenceAvailability.current().isAvailable,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: Date = Date()
    ) -> LockedAttachmentExtractionStatus {
        if attachment.remoteURL != nil {
            let expired = attachment.remoteExpiresAt.map { $0 <= now } ?? false
            return LockedAttachmentExtractionStatus(
                state: .mailDrop(expiresAt: attachment.remoteExpiresAt, expired: expired)
            )
        }
        if hasExtractedPayload(attachment) {
            return LockedAttachmentExtractionStatus(state: .ready)
        }

        let kind = DocumentKind.detect(
            mimeType: attachment.mimeType,
            filename: attachment.filename
        )

        if kind == .image {
            return classifyImage(
                attachment,
                appleIntelligenceAvailable: appleIntelligenceAvailable,
                fileExists: fileExists
            )
        }

        return classifyDocumentOrBinary(
            attachment,
            kind: kind,
            fileExists: fileExists
        )
    }

    private nonisolated static func classifyImage(
        _ attachment: LockedAttachmentSummary,
        appleIntelligenceAvailable: Bool,
        fileExists: (String) -> Bool
    ) -> LockedAttachmentExtractionStatus {
        if let status = attachment.visualExtractionStatus.flatMap(VisualAttachmentExtractionStatus.init(rawValue:)) {
            return statusForVisualTerminalStatus(status, reason: attachment.visualExtractionFailureReason)
        }

        if let method = attachment.visualExtractionMethod,
           method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return LockedAttachmentExtractionStatus(
                state: .stalled("Visual extraction method is set without a terminal status.")
            )
        }

        if attachmentMissingFromDisk(attachment, fileExists: fileExists) {
            return LockedAttachmentExtractionStatus(state: .missingFile)
        }

        if attachment.sizeBytes > VisualAttachmentExtractionWorker.maxAttemptedImageBytes {
            return LockedAttachmentExtractionStatus(state: .tooLarge)
        }

        if !appleIntelligenceAvailable {
            return LockedAttachmentExtractionStatus(state: .waitingForAppleIntelligence)
        }

        return LockedAttachmentExtractionStatus(state: .queued(.visual))
    }

    private nonisolated static func classifyDocumentOrBinary(
        _ attachment: LockedAttachmentSummary,
        kind: DocumentKind,
        fileExists: (String) -> Bool
    ) -> LockedAttachmentExtractionStatus {
        if let status = attachment.extractionStatus.flatMap(AttachmentExtractionStatus.init(rawValue:)) {
            return statusForDocumentTerminalStatus(status, reason: attachment.extractionFailureReason)
        }

        guard kind.isDocument else {
            return LockedAttachmentExtractionStatus(state: .unsupported)
        }

        if let method = attachment.extractionMethod,
           method == AttachmentExtractionWorker.unsupportedMarker {
            return LockedAttachmentExtractionStatus(state: .queued(.document))
        }

        if attachmentMissingFromDisk(attachment, fileExists: fileExists) {
            return LockedAttachmentExtractionStatus(state: .missingFile)
        }

        if attachment.sizeBytes > AttachmentExtractionWorker.maxAttemptedAttachmentBytes {
            return LockedAttachmentExtractionStatus(state: .tooLarge)
        }

        if let method = attachment.extractionMethod,
           method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return LockedAttachmentExtractionStatus(
                state: .stalled("Document extraction method is set without a terminal status.")
            )
        }

        return LockedAttachmentExtractionStatus(state: .queued(.document))
    }

    private nonisolated static func statusForDocumentTerminalStatus(
        _ status: AttachmentExtractionStatus,
        reason: String?
    ) -> LockedAttachmentExtractionStatus {
        switch status {
        case .completed:
            return LockedAttachmentExtractionStatus(state: .ready)
        case .unsupportedType:
            return LockedAttachmentExtractionStatus(state: .unsupported)
        case .parseFailed:
            return failureOrMissing(reason: reason)
        case .encryptedOrPasswordProtected:
            return LockedAttachmentExtractionStatus(state: .encrypted)
        case .tooLarge:
            return LockedAttachmentExtractionStatus(state: .tooLarge)
        case .emptyText:
            return LockedAttachmentExtractionStatus(state: .empty)
        }
    }

    private nonisolated static func statusForVisualTerminalStatus(
        _ status: VisualAttachmentExtractionStatus,
        reason: String?
    ) -> LockedAttachmentExtractionStatus {
        switch status {
        case .completed:
            return LockedAttachmentExtractionStatus(state: .ready)
        case .unsupportedType:
            return LockedAttachmentExtractionStatus(state: .unsupported)
        case .unavailable:
            return LockedAttachmentExtractionStatus(state: .waitingForAppleIntelligence)
        case .parseFailed:
            return failureOrMissing(reason: reason)
        case .guardrailViolation:
            return LockedAttachmentExtractionStatus(state: .blocked(reason))
        case .tooLarge:
            return LockedAttachmentExtractionStatus(state: .tooLarge)
        case .emptyEvidence:
            return LockedAttachmentExtractionStatus(state: .empty)
        }
    }

    private nonisolated static func failureOrMissing(reason: String?) -> LockedAttachmentExtractionStatus {
        if reason?.localizedCaseInsensitiveContains("missing") == true {
            return LockedAttachmentExtractionStatus(state: .missingFile)
        }
        return LockedAttachmentExtractionStatus(state: .failed(reason))
    }

    private nonisolated static func hasExtractedPayload(_ attachment: LockedAttachmentSummary) -> Bool {
        if let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return true
        }
        if let summary = attachment.visualSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return true
        }
        return false
    }

    private nonisolated static func attachmentMissingFromDisk(
        _ attachment: LockedAttachmentSummary,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard let path = attachment.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return true
        }
        return !fileExists(path)
    }
}
