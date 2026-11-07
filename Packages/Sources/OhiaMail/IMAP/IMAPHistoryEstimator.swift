import Foundation

public struct IMAPHistoryEstimate: Sendable, Equatable {
    public enum Accuracy: Sendable, Equatable {
        case exact
        case approximate
    }

    public let lowerBound: Date?
    public let displayedMessageCount: Int
    public let accuracy: Accuracy
    public let folderWork: [IMAPFolderWorkEstimate]
    public let capturedAt: Date

    public init(
        lowerBound: Date?,
        displayedMessageCount: Int,
        accuracy: Accuracy,
        folderWork: [IMAPFolderWorkEstimate],
        capturedAt: Date
    ) {
        self.lowerBound = lowerBound
        self.displayedMessageCount = displayedMessageCount
        self.accuracy = accuracy
        self.folderWork = folderWork
        self.capturedAt = capturedAt
    }
}

public struct IMAPFolderWorkEstimate: Sendable, Equatable {
    public let folderName: String
    public let attributes: [String]
    public let uidValidity: UInt32
    public let uidNext: UInt32
    public let candidateUIDCount: Int

    public init(
        folderName: String,
        attributes: [String],
        uidValidity: UInt32,
        uidNext: UInt32,
        candidateUIDCount: Int
    ) {
        self.folderName = folderName
        self.attributes = attributes
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.candidateUIDCount = candidateUIDCount
    }
}

public enum IMAPHistoryEstimationError: Error, Sendable, Equatable {
    case actionRequired(IMAPSessionHaltReason)
    case countUnavailable(String)
    case timedOut
}

public struct IMAPHistoryEstimator: Sendable {
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private let makeClient: IMAPClientFactory

    public init(timeout: Duration = .seconds(15)) {
        self.init(timeout: timeout, now: Date.init, makeClient: { IMAPClient() })
    }

    init(
        timeout: Duration = .seconds(15),
        now: @escaping @Sendable () -> Date,
        makeClient: @escaping IMAPClientFactory
    ) {
        self.timeout = timeout
        self.now = now
        self.makeClient = makeClient
    }

    public func estimate(
        configuration: IMAPConnectionConfiguration,
        lowerBound: Date?
    ) async throws -> IMAPHistoryEstimate {
        let client = makeClient()

        do {
            let estimate = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: IMAPHistoryEstimate.self) { group in
                    group.addTask {
                        try await performEstimate(
                            configuration: configuration,
                            lowerBound: lowerBound,
                            client: client
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        await client.close()
                        throw IMAPHistoryEstimationError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw IMAPHistoryEstimationError.countUnavailable("history estimate produced no result")
                    }
                    return first
                }
            } onCancel: {
                Task { await client.close() }
            }

            await client.logout()
            await client.close()
            return estimate
        } catch {
            await client.close()
            if IMAPConnectionErrorClassifier.isCancellation(error) {
                throw CancellationError()
            }
            if let estimationError = error as? IMAPHistoryEstimationError {
                throw estimationError
            }
            if let reason = IMAPConnectionErrorClassifier.actionRequiredReason(error) {
                throw IMAPHistoryEstimationError.actionRequired(reason)
            }
            throw IMAPHistoryEstimationError.countUnavailable(
                IMAPConnectionErrorClassifier.diagnostic(error)
            )
        }
    }

    private func performEstimate(
        configuration: IMAPConnectionConfiguration,
        lowerBound: Date?,
        client: any IMAPClienting
    ) async throws -> IMAPHistoryEstimate {
        try Task.checkCancellation()
        try await client.connect(
            host: configuration.host,
            port: configuration.port,
            security: configuration.security,
            pinnedCertSHA256: configuration.pinnedCertSHA256
        )
        try await configuration.authenticate(client)
        let capabilities = try await client.capability()
        let listing = try await client.list()
        let corpusFolders = GmailFolderFilter.foldersForCorpus(
            listing: listing,
            capabilities: capabilities
        )
        let hasGmailAllMail = capabilities.xGmExt1 && corpusFolders.contains(where: \.isAll)

        var displayedCount = 0
        var work: [IMAPFolderWorkEstimate] = []

        for folder in corpusFolders {
            try Task.checkCancellation()
            let metadata = try await client.examineWithMetadata(mailbox: folder.name)
            let state = metadata.select
            let range = Self.searchRange(uidNext: state.uidNext)
            let candidateUIDs: [UInt32]
            if let range {
                if let lowerBound {
                    candidateUIDs = try await client.uidSearch(range: range, since: lowerBound)
                } else {
                    candidateUIDs = try await client.uidSearch(range: range)
                }
            } else {
                candidateUIDs = []
            }

            displayedCount = try Self.addingCount(candidateUIDs.count, to: displayedCount)
            work.append(IMAPFolderWorkEstimate(
                folderName: folder.name,
                attributes: folder.attributes.sorted(),
                uidValidity: state.uidValidity,
                uidNext: state.uidNext,
                candidateUIDCount: candidateUIDs.count
            ))

            if hasGmailAllMail, folder.isAll, let range {
                let draftUIDs: [UInt32]
                do {
                    draftUIDs = try await client.uidSearch(
                        range: range,
                        since: lowerBound,
                        gmailLabel: "\\Drafts"
                    )
                } catch {
                    if IMAPConnectionErrorClassifier.isCancellation(error) {
                        throw CancellationError()
                    }
                    throw IMAPHistoryEstimationError.countUnavailable(
                        "X-GM-LABELS Drafts count failed: \(IMAPConnectionErrorClassifier.diagnostic(error))"
                    )
                }
                displayedCount = max(0, displayedCount - draftUIDs.count)
            }
        }

        return IMAPHistoryEstimate(
            lowerBound: lowerBound,
            displayedMessageCount: displayedCount,
            accuracy: hasGmailAllMail ? .exact : .approximate,
            folderWork: work,
            capturedAt: now()
        )
    }

    private static func searchRange(uidNext: UInt32) -> ClosedRange<UInt32>? {
        guard uidNext > 1 else { return nil }
        return 1...(uidNext - 1)
    }

    private static func addingCount(_ value: Int, to total: Int) throws -> Int {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard overflow == false else {
            throw IMAPHistoryEstimationError.countUnavailable("message count exceeded supported range")
        }
        return sum
    }
}
