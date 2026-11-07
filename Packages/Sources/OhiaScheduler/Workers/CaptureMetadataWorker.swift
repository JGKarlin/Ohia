import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaML

/// Reads capture time, place and captions from photo and video attachments
/// (local files and iCloud Mail Drop links), names recorded coordinates
/// through MapKit in the reading language, and persists the result on
/// `Attachment.captureMetadataJSON`. A row is finished when its
/// `captureMetadataVersion` matches the reader version and reading language;
/// transient failures (offline, MapKit throttling, unreachable link) keep the
/// row pending behind `captureMetadataNextAttemptAt`.
public final class CaptureMetadataWorker: @unchecked Sendable {
    public static let attachmentsPerTick = 12
    /// Mail Drop reads are network round trips; keep a tick short so the
    /// shared retrieval lane (embedding, IMAP polling, sending) is not held.
    static let mailDropReadsPerTick = 2
    static let tickTimeBudget: TimeInterval = 20
    /// Upper bound for one row's file read (a Mail Drop header can need a
    /// few range requests); past it the row is retried later.
    static let readTimeout: Duration = .seconds(30)
    static let retryDelays: [TimeInterval] = [60, 300, 1_800, 7_200, 43_200]

    public enum Source: Sendable, Equatable {
        case localImage(URL)
        case localMovie(URL)
        case mailDropImage(URL)
        case mailDropMovie(URL, filename: String, mimeType: String)

        var isRemote: Bool {
            switch self {
            case .mailDropImage, .mailDropMovie: return true
            case .localImage, .localMovie: return false
            }
        }
    }

    public struct ReadResult: Sendable, Equatable {
        public let reading: CaptureMetadataReading?
        public let remoteSizeBytes: Int?

        public init(reading: CaptureMetadataReading?, remoteSizeBytes: Int? = nil) {
            self.reading = reading
            self.remoteSizeBytes = remoteSizeBytes
        }
    }

    public typealias Reader = @Sendable (Source) async throws -> ReadResult
    public typealias PlaceLookup = @Sendable (
        AttachmentCaptureMetadata.Coordinate,
        String
    ) async throws -> AttachmentCaptureMetadata.Place?

    public struct RunOutcome: Sendable, Equatable {
        public let attachmentsVisited: Int
        public let attachmentsChanged: Int
        public let attachmentsDeferred: Int
    }

    private let languageIdentifier: @Sendable () -> String
    private let reader: Reader
    private let placeLookup: PlaceLookup
    private let now: @Sendable () -> Date

    public init(
        languageIdentifier: @escaping @Sendable () -> String = { SummarizationTargetLanguage.ohiaPreferred().identifier },
        reader: @escaping Reader = CaptureMetadataWorker.read,
        placeLookup: @escaping PlaceLookup = { coordinate, language in
            try await PlaceNameResolver.shared.place(for: coordinate, languageIdentifier: language)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.languageIdentifier = languageIdentifier
        self.reader = reader
        self.placeLookup = placeLookup
        self.now = now
    }

    // MARK: Pending work

    @MainActor
    public static func hasPendingWork(
        context: ModelContext,
        languageIdentifier: String = SummarizationTargetLanguage.ohiaPreferred().identifier,
        now: Date = Date()
    ) -> Bool {
        let version = AttachmentCaptureMetadata.versionTag(languageIdentifier: languageIdentifier)
        let rows = (try? context.fetch(candidateDescriptor(version: version))) ?? []
        return rows.contains { isDue($0, now: now) }
    }

    /// Store-side mirror of `CaptureMediaKind.isQueriedMIMEFamily`.
    static func candidateDescriptor(version: String) -> FetchDescriptor<Attachment> {
        FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                // SQL `NULL != value` is not true, so unvisited rows need the explicit nil test.
                (attachment.captureMetadataVersion == nil || attachment.captureMetadataVersion != version)
                    && (attachment.mimeType.starts(with: "image/")
                        || attachment.mimeType.starts(with: "video/")
                        || attachment.mimeType == "application/octet-stream")
            }
        )
    }

    private static func isCandidate(_ attachment: Attachment, version: String) -> Bool {
        attachment.captureMetadataVersion != version && CaptureMediaKind.isQueriedMIMEFamily(attachment.mimeType)
    }

    private static func isDue(_ attachment: Attachment, now: Date) -> Bool {
        if let next = attachment.captureMetadataNextAttemptAt, next > now { return false }
        return true
    }

    static func mediaKind(of attachment: Attachment) -> CaptureMediaKind? {
        CaptureMediaKind.of(mimeType: attachment.mimeType, filename: attachment.filename)
    }

    // MARK: Run

    /// Visits due rows newest mail first. With `messageID` (a job staged by
    /// reply preparation) only that message's attachments are visited.
    @MainActor
    public func runOnce(context: ModelContext, messageID: UUID? = nil) async throws -> RunOutcome {
        let started = now()
        let language = languageIdentifier()
        let version = AttachmentCaptureMetadata.versionTag(languageIdentifier: language)
        let candidates: [Attachment]
        if let messageID {
            var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
            descriptor.fetchLimit = 1
            candidates = (try context.fetch(descriptor).first?.attachments ?? [])
                .filter { Self.isCandidate($0, version: version) && Self.isDue($0, now: started) }
        } else {
            candidates = try context.fetch(Self.candidateDescriptor(version: version))
                .filter { Self.isDue($0, now: started) }
        }

        // `application/octet-stream` rows that are not media by name never
        // need a read; stamp them so later passes skip them.
        for attachment in candidates where Self.mediaKind(of: attachment) == nil {
            attachment.captureMetadataVersion = version
        }
        let due = candidates
            .filter { Self.mediaKind(of: $0) != nil }
            .sorted { Self.mailDate($0) > Self.mailDate($1) }

        var visited = 0
        var changed = 0
        var deferred = 0
        var remoteReads = 0
        var mapKitPausedUntil: Date?
        for attachment in due.prefix(Self.attachmentsPerTick) {
            try Task.checkCancellation()
            if visited > 0, now().timeIntervalSince(started) > Self.tickTimeBudget { break }
            let plan = sourcePlan(for: attachment, version: version, now: started)
            if case .read(let source) = plan, source.isRemote {
                guard remoteReads < Self.mailDropReadsPerTick else { continue }
                remoteReads += 1
            }
            visited += 1
            let outcome = try await process(
                attachment,
                plan: plan,
                language: language,
                version: version,
                now: started,
                mapKitPausedUntil: &mapKitPausedUntil
            )
            switch outcome {
            case .unchanged:
                break
            case .evidenceChanged:
                changed += 1
            case .deferred(let evidenceChanged):
                deferred += 1
                if evidenceChanged { changed += 1 }
            }
            if outcome.evidenceChanged, let message = attachment.message {
                try invalidateDerivedText(for: message, context: context)
            }
            // Persist each row with its invalidation so cancellation between
            // rows never leaves a stamped row whose search or summary is stale.
            try context.save()
        }
        try context.save()
        return RunOutcome(attachmentsVisited: visited, attachmentsChanged: changed, attachmentsDeferred: deferred)
    }

    private static func mailDate(_ attachment: Attachment) -> Date {
        guard let message = attachment.message else { return .distantPast }
        return message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }

    private enum Outcome {
        case unchanged
        case evidenceChanged
        case deferred(evidenceChanged: Bool)

        var evidenceChanged: Bool {
            switch self {
            case .unchanged: return false
            case .evidenceChanged: return true
            case .deferred(let changed): return changed
            }
        }
    }

    @MainActor
    private func process(
        _ attachment: Attachment,
        plan: SourcePlan,
        language: String,
        version: String,
        now currentTime: Date,
        mapKitPausedUntil: inout Date?
    ) async throws -> Outcome {
        let existing = AttachmentCaptureMetadata.decode(attachment.captureMetadataJSON)

        var reading: CaptureMetadataReading?
        var remoteSize: Int?
        switch plan {
        case .read(let source):
            do {
                let result = try await Self.withTimeout(Self.readTimeout) { [reader] in
                    try await reader(source)
                }
                reading = result.reading
                remoteSize = result.remoteSizeBytes
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteMediaFetchError {
                if case .transient = error {
                    scheduleRetry(attachment, at: currentTime)
                    return .deferred(evidenceChanged: false)
                }
                // Expired, removed or unreadable: keep what an earlier visit read.
                reading = existing.map { CaptureMetadataReading(metadata: $0) }
            } catch {
                // AVFoundation can surface cancellation as an ordinary error;
                // never stamp a row because the job itself was cancelled.
                try Task.checkCancellation()
                reading = existing.map { CaptureMetadataReading(metadata: $0) }
            }
        case .reuseStored:
            reading = existing.map { CaptureMetadataReading(metadata: $0) }
        }

        var metadata = reading?.metadata ?? AttachmentCaptureMetadata()
        var placeDeferredUntil: Date?
        if let coordinate = metadata.coordinate {
            if let paused = mapKitPausedUntil {
                metadata.place = existing?.coordinate == coordinate ? existing?.place : nil
                placeDeferredUntil = paused
            } else {
                do {
                    metadata.place = try await placeLookup(coordinate, language)
                } catch is CancellationError {
                    throw CancellationError()
                } catch PlaceNameResolutionError.throttled(let until) {
                    // A rate limit is MapKit's pause, not this row's failure:
                    // wait it out without escalating the row's retry delay.
                    mapKitPausedUntil = until
                    metadata.place = existing?.coordinate == coordinate ? existing?.place : nil
                    placeDeferredUntil = until
                } catch {
                    // Keep a previously named place for the same point while MapKit is unavailable.
                    metadata.place = existing?.coordinate == coordinate ? existing?.place : nil
                    placeDeferredUntil = .distantPast
                }
            }
        } else {
            metadata.place = nil
        }
        if let instant = reading?.unzonedCaptureInstant ?? metadata.unzonedCaptureInstant {
            // Without a recorded zone the instant is shown in the place's
            // zone, or failing that (no place yet) the reader's own; it is
            // re-localized when a deferred place arrives.
            metadata.unzonedCaptureInstant = instant
            let zone = metadata.place?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
            metadata.captureTime = AttachmentCaptureMetadata.CaptureTime(absolute: instant, timeZone: zone)
        }
        metadata.remoteSizeBytes = remoteSize ?? existing?.remoteSizeBytes

        let json = (metadata.hasContent || metadata.remoteSizeBytes != nil) ? try metadata.encodedJSON() : nil
        let evidenceChanged = existing?.evidenceText != (json == nil ? nil : metadata.evidenceText)
        if attachment.captureMetadataJSON != json {
            attachment.captureMetadataJSON = json
        }
        if attachment.remoteURL != nil, let size = metadata.remoteSizeBytes, size > 0, attachment.sizeBytes != size {
            attachment.sizeBytes = size
        }

        if let placeDeferredUntil {
            if placeDeferredUntil == .distantPast {
                scheduleRetry(attachment, at: currentTime)
            } else {
                attachment.captureMetadataAttemptCount = max(attachment.captureMetadataAttemptCount ?? 0, 1)
                attachment.captureMetadataNextAttemptAt = placeDeferredUntil
            }
            return .deferred(evidenceChanged: evidenceChanged)
        }
        attachment.captureMetadataVersion = version
        attachment.captureMetadataAttemptCount = nil
        attachment.captureMetadataNextAttemptAt = nil
        return evidenceChanged ? .evidenceChanged : .unchanged
    }

    private enum SourcePlan {
        case read(Source)
        /// Re-name the stored coordinate without reading the file again: the
        /// link expired, the file is gone, or only the reading language changed.
        case reuseStored
    }

    @MainActor
    private func sourcePlan(for attachment: Attachment, version: String, now currentTime: Date) -> SourcePlan {
        let kind = Self.mediaKind(of: attachment) ?? .image
        // Only the place name depends on the language, so a language change
        // never re-reads the file; a row waiting only on its place name
        // (read succeeded, MapKit deferred) is not read again either.
        if let stored = AttachmentCaptureMetadata.decode(attachment.captureMetadataJSON) {
            let languageOnlyChange = attachment.captureMetadataVersion?
                .hasPrefix(AttachmentCaptureMetadata.readerVersion + "|") == true
            let awaitingPlaceOnly = attachment.captureMetadataVersion == nil
                && stored.coordinate != nil && stored.place == nil
                && (attachment.captureMetadataAttemptCount ?? 0) > 0
            if languageOnlyChange || awaitingPlaceOnly {
                return .reuseStored
            }
        }
        if let remote = attachment.remoteURL {
            guard let url = URL(string: remote), MailDropReference.isTrustedDownloadURL(url) else {
                return .reuseStored
            }
            if let expiry = attachment.remoteExpiresAt, expiry <= currentTime {
                return .reuseStored
            }
            switch kind {
            case .image: return .read(.mailDropImage(url))
            case .movie: return .read(.mailDropMovie(url, filename: attachment.filename, mimeType: attachment.mimeType))
            }
        }
        guard let path = attachment.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return .reuseStored
        }
        let url = URL(fileURLWithPath: path)
        switch kind {
        case .image: return .read(.localImage(url))
        case .movie: return .read(.localMovie(url))
        }
    }

    /// Runs `operation`, or throws `RemoteMediaFetchError.transient` once
    /// `timeout` passes (the operation is cancelled).
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteMediaFetchError.transient("Read timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    @MainActor
    private func scheduleRetry(_ attachment: Attachment, at currentTime: Date) {
        let attempts = (attachment.captureMetadataAttemptCount ?? 0) + 1
        attachment.captureMetadataAttemptCount = attempts
        let delay = Self.retryDelays[min(attempts, Self.retryDelays.count) - 1]
        attachment.captureMetadataNextAttemptAt = currentTime.addingTimeInterval(delay)
    }

    /// Re-embeds the message so search sees the new capture card, and asks
    /// for a fresh body summary on inbound mail so it can mention time and
    /// place. Existing vectors stay until the re-embed replaces them
    /// (`EmbeddingOrchestrator` deletes them when it re-seeds), so the node
    /// stays placed and retrievable meanwhile — this job is not held behind
    /// model backpressure, while `.embed` / `.index` can be. Classification
    /// and triage are untouched: capture metadata cannot change them, and
    /// keeping them makes the rerun summary-only.
    @MainActor
    private func invalidateDerivedText(for message: Message, context: ModelContext) throws {
        message.embeddingStatus = .pending
        message.embeddedAt = nil

        guard !message.isSentByUser, let analysis = message.analysis else { return }
        analysis.bodySummary = nil
        analysis.bodySummaryInputFingerprint = nil
        analysis.summarizedAt = nil
        let messageID = message.id
        let existing = try JobFetch.active(context: context).contains { job in
            job.type == .summarize && job.messageId == messageID
        }
        guard !existing else { return }
        let job = Job(type: .summarize, priority: 4)
        job.messageId = messageID
        context.insert(job)
    }

    // MARK: Default reader

    private static let mailDropLoader = URLSessionRangeLoader.loader(allowing: MailDropReference.isTrustedDownloadURL)

    @Sendable
    public static func read(_ source: Source) async throws -> ReadResult {
        switch source {
        case .localImage(let url):
            let reading = await Task.detached(priority: .utility) {
                CaptureMetadataReader.readImage(at: url)
            }.value
            return ReadResult(reading: reading)
        case .localMovie(let url):
            return ReadResult(reading: try await CaptureMetadataReader.readMovie(at: url))
        case .mailDropImage(let url):
            let result = try await RemoteImageHeaderReader.read(url: url, loader: mailDropLoader)
            return ReadResult(reading: result.reading, remoteSizeBytes: result.totalBytes)
        case .mailDropMovie(let url, let filename, let mimeType):
            let result = try await RemoteMovieHeaderReader.read(
                url: url, filename: filename, mimeType: mimeType, loader: mailDropLoader
            )
            return ReadResult(reading: result.reading, remoteSizeBytes: result.totalBytes)
        }
    }
}
