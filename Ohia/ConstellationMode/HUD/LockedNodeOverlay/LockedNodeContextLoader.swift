import Foundation
import SwiftData
import simd
import OhiaCore
import OhiaML

struct LockedNodeContextLoader {
    let vectorId: Int64
    let activeFrame: FrameKey
    let vectorStore: VectorStore
    let vectorNeighborsStore: VectorNeighborsStore
    let vectorFrameLayoutStore: VectorFrameLayoutStore
    let messageIndex: [String: MessageFilterRow]
    let modelContext: ModelContext
    let summaryOverride: String?
    /// Canonical override pushed in from `ConstellationModeView`; `nil`
    /// falls through to the row projection.
    let classificationOverride: MailClassification?
    /// Lowercased user addresses (every Account / Identity address). Used
    /// to classify each neighbour as `sameCorrespondent` vs.
    /// `differentCorrespondent` by ignoring the user's own addresses when
    /// comparing the locked email's correspondent set against each
    /// neighbour's. Without this filter every neighbour would trivially
    /// "share" the user themselves and split-by-correspondent would
    /// collapse to a single bucket.
    let userAddresses: Set<String>
    /// When set, the locked overlay is centered on a People-frame island
    /// rather than only the representative email used to enter the focus
    /// scene. Its message IDs drive the filtered ring/tab population; the
    /// correspondence telemetry still aggregates the full message index so
    /// the bottom pane keeps the all-time relationship totals.
    let personFocus: LockedPersonFocus?

    init(
        vectorId: Int64,
        activeFrame: FrameKey,
        vectorStore: VectorStore,
        vectorNeighborsStore: VectorNeighborsStore,
        vectorFrameLayoutStore: VectorFrameLayoutStore,
        messageIndex: [String: MessageFilterRow],
        modelContext: ModelContext,
        summaryOverride: String?,
        classificationOverride: MailClassification?,
        userAddresses: Set<String>,
        personFocus: LockedPersonFocus? = nil
    ) {
        self.vectorId = vectorId
        self.activeFrame = activeFrame
        self.vectorStore = vectorStore
        self.vectorNeighborsStore = vectorNeighborsStore
        self.vectorFrameLayoutStore = vectorFrameLayoutStore
        self.messageIndex = messageIndex
        self.modelContext = modelContext
        self.summaryOverride = summaryOverride
        self.classificationOverride = classificationOverride
        self.userAddresses = userAddresses
        self.personFocus = personFocus
    }

    @MainActor
    func load() async throws -> LockedNodeContext {
        let payload = try await loadVectorPayload()
        guard let centerRow = messageIndex[payload.centerMessageId] else {
            throw LockedNodeContextError.centerNotFound
        }

        let bodyContent = await loadBodyContent(row: centerRow)
        let swiftData = loadSwiftDataContext(centerMessageId: payload.centerMessageId)
        let attachments = swiftData.attachments
        let correspondentByKey = Dictionary(
            uniqueKeysWithValues: swiftData.correspondents.map { ($0.email.lowercased(), $0) }
        )

        let center = LockedNodeContext.Center(
            messageId: payload.centerMessageId,
            vectorId: vectorId,
            row: centerRow,
            worldPosition: payload.centerWorld,
            bodyContent: bodyContent
        )
        let ownChunks = payload.ownRecords.compactMap { record -> LockedNodeContext.OwnChunk? in
            guard let world = payload.worldByVectorId[record.vectorId] else { return nil }
            let attachment = record.collection == .attachment
                ? Self.attachment(for: record.metadataJSON, in: attachments)
                : nil
            let correspondent = record.entityKind == .correspondent
                ? record.entityKey.flatMap { correspondentByKey[$0.lowercased()] }
                : nil
            return LockedNodeContext.OwnChunk(
                vectorId: record.vectorId,
                collection: record.collection,
                chunkIndex: record.chunkIndex,
                textPayload: record.textPayload,
                metadataJSON: record.metadataJSON,
                entityKind: record.entityKind,
                entityKey: record.entityKey,
                entityScore: record.entityScore,
                worldPosition: world,
                attachment: attachment,
                correspondent: correspondent
            )
        }
        let centerCorrespondents = LockedFrameContextPolicy.correspondentSet(row: centerRow, userAddresses: userAddresses)
        let focusedPersonEmail = personFocus?.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let neighbours = payload.neighbours.compactMap { neighbour -> LockedNodeContext.Neighbour? in
            guard let row = messageIndex[neighbour.messageId],
                  let representativeWorld = payload.worldByVectorId[neighbour.matchedTargetVectorId]
                    ?? payload.representativeWorldByMessageId[neighbour.messageId] else {
                return nil
            }
            let relation: LockedNodeContext.Neighbour.Relation
            if let focusedPersonEmail,
               LockedFrameContextPolicy.peopleParticipantSet(row: row, userAddresses: userAddresses).contains(focusedPersonEmail) {
                relation = .sameCorrespondent
            } else {
                let neighbourCorrespondents = LockedFrameContextPolicy.correspondentSet(row: row, userAddresses: userAddresses)
                relation = centerCorrespondents.isDisjoint(with: neighbourCorrespondents)
                    ? .differentCorrespondent
                    : .sameCorrespondent
            }
            let semanticReason = activeFrame.spatialLens == .meaning
                ? MeaningSemanticEdgeReasoner.reason(between: centerRow, and: row)
                : nil
            return LockedNodeContext.Neighbour(
                messageId: neighbour.messageId,
                row: row,
                bestSimilarity: neighbour.bestSimilarity,
                rank: neighbour.bestRank + 1,
                matchedChunkSummary: payload.summaryByVectorId[neighbour.matchedTargetVectorId],
                representativeWorld: representativeWorld,
                relation: relation,
                semanticReason: semanticReason
            )
        }
        let purpose = (classificationOverride ?? centerRow.mailClassification)?.purpose
        let thread = swiftData.threadSiblings
        let threadReport = makeThreadReport(
            centerRow: centerRow,
            purpose: purpose,
            thread: thread,
            similarMessageIds: payload.similarMessageIds
        )
        let telemetry = SurveyTelemetry(
            contextNeighborCount: neighbours.count,
            threadReport: threadReport
        )

        return LockedNodeContext(
            center: center,
            ownChunks: ownChunks,
            thread: thread,
            neighbours: neighbours,
            surveyTelemetry: telemetry,
            attachments: swiftData.attachments
        )
    }

    private struct VectorPayload: Sendable {
        let centerMessageId: String
        let centerWorld: SIMD3<Float>
        let ownRecords: [VectorRecord]
        let neighbours: [LockedNeighborhoodResolver.NeighbourMessage]
        let worldByVectorId: [Int64: SIMD3<Float>]
        let representativeWorldByMessageId: [String: SIMD3<Float>]
        let summaryByVectorId: [Int64: String]
        let similarMessageIds: Set<String>
    }

    private struct SwiftDataContext {
        let attachments: [LockedAttachmentSummary]
        let correspondents: [LockedCorrespondentSummary]
        let threadSiblings: [LockedNodeContext.ThreadSibling]
    }

    private func loadVectorPayload() async throws -> VectorPayload {
        let vectorId = vectorId
        let activeFrame = activeFrame
        let vectorStore = vectorStore
        let vectorNeighborsStore = vectorNeighborsStore
        let vectorFrameLayoutStore = vectorFrameLayoutStore
        let messageIndex = messageIndex
        let userAddresses = userAddresses
        let personFocus = personFocus
        let hasPersonFocus = personFocus != nil

        return try await Task.detached(priority: .userInitiated) {
            guard let centerRecord = try vectorStore.hydrate(vectorIds: [vectorId]).first,
                  let centerRow = messageIndex[centerRecord.messageId] else {
                throw LockedNodeContextError.centerNotFound
            }

            let ownRecords = try vectorStore.vectorsForMessage(messageId: centerRecord.messageId)
            let ownVectorIds = ownRecords.map(\.vectorId)
            let neighborGroups = try vectorNeighborsStore.neighborsOf(
                vectorIds: ownVectorIds,
                limit: Self.neighbourMessageLimit
            )
            let similarNeighborGroups = try vectorNeighborsStore.neighborsOf(
                vectorIds: ownVectorIds,
                limit: Self.similarMessageEdgeLimit
            )
            let targetIds = Array(
                Set(
                    neighborGroups.values.flatMap { $0.map(\.targetId) }
                        + similarNeighborGroups.values.flatMap { $0.map(\.targetId) }
                )
            )
            let targetRecords = try vectorStore.hydrate(vectorIds: targetIds)

            var messageByVectorId = Dictionary(uniqueKeysWithValues: ownRecords.map { ($0.vectorId, $0.messageId) })
            for record in targetRecords {
                messageByVectorId[record.vectorId] = record.messageId
            }

            let semanticNeighbours = LockedNeighborhoodResolver().resolve(
                anchorMessageId: centerRecord.messageId,
                anchorVectorIds: Set(ownVectorIds),
                neighborsBySource: neighborGroups,
                messageByVectorId: messageByVectorId,
                eligibleMessageIds: Set(messageIndex.keys),
                limit: Self.neighbourMessageLimit
            )
            let neighbours: [LockedNeighborhoodResolver.NeighbourMessage]
            if let personFocus {
                let candidates = LockedFrameContextPolicy.peopleCandidates(
                    focusedEmail: personFocus.email,
                    allowedMessageIds: personFocus.messageIds,
                    centerMessageId: centerRecord.messageId,
                    centerRow: centerRow,
                    messageIndex: messageIndex,
                    userAddresses: userAddresses,
                    limit: nil
                )
                let sourceId = ownVectorIds.first ?? vectorId
                var personNeighbours: [LockedNeighborhoodResolver.NeighbourMessage] = []
                personNeighbours.reserveCapacity(candidates.count)
                for (index, candidate) in candidates.enumerated() {
                    let records = try vectorStore.vectorsForMessage(messageId: candidate.messageId)
                    guard let target = Self.representativeNeighbourRecord(from: records) else {
                        continue
                    }
                    personNeighbours.append(
                        LockedNeighborhoodResolver.NeighbourMessage(
                            messageId: candidate.messageId,
                            bestSimilarity: candidate.score,
                            matchedSourceVectorId: sourceId,
                            matchedTargetVectorId: target.vectorId,
                            bestRank: index
                        )
                    )
                }
                neighbours = personNeighbours
            } else if LockedFrameContextPolicy.usesSemanticNeighbours(for: activeFrame) {
                neighbours = semanticNeighbours
            } else {
                let candidates = LockedFrameContextPolicy.candidates(
                    for: activeFrame,
                    centerMessageId: centerRecord.messageId,
                    centerRow: centerRow,
                    messageIndex: messageIndex,
                    userAddresses: userAddresses,
                    limit: Self.neighbourMessageLimit
                )
                let sourceId = ownVectorIds.first ?? vectorId
                var frameNeighbours: [LockedNeighborhoodResolver.NeighbourMessage] = []
                frameNeighbours.reserveCapacity(candidates.count)
                for (index, candidate) in candidates.enumerated() {
                    let records = try vectorStore.vectorsForMessage(messageId: candidate.messageId)
                    guard let target = Self.representativeNeighbourRecord(from: records) else {
                        continue
                    }
                    frameNeighbours.append(
                        LockedNeighborhoodResolver.NeighbourMessage(
                            messageId: candidate.messageId,
                            bestSimilarity: candidate.score,
                            matchedSourceVectorId: sourceId,
                            matchedTargetVectorId: target.vectorId,
                            bestRank: index
                        )
                    )
                }
                neighbours = frameNeighbours
            }
            let similarMessageIds = Self.similarMessageIds(
                anchorMessageId: centerRecord.messageId,
                anchorVectorIds: Set(ownVectorIds),
                neighborsBySource: similarNeighborGroups,
                messageByVectorId: messageByVectorId,
                eligibleMessageIds: Set(messageIndex.keys)
            )

            var allRecordsByVectorId = Dictionary(uniqueKeysWithValues: ownRecords.map { ($0.vectorId, $0) })
            for messageId in neighbours.map(\.messageId) {
                let records = try vectorStore.vectorsForMessage(messageId: messageId)
                for record in records {
                    allRecordsByVectorId[record.vectorId] = record
                }
            }
            for record in targetRecords {
                allRecordsByVectorId[record.vectorId] = record
            }

            let allRecords = Array(allRecordsByVectorId.values)
            let framePositions = try vectorFrameLayoutStore.positionsForFrame(
                activeFrame,
                vectorIds: allRecords.map(\.vectorId)
            )

            var worldByVectorId: [Int64: SIMD3<Float>] = [:]
            for record in allRecords {
                if let position = framePositions[record.vectorId] {
                    worldByVectorId[record.vectorId] = position
                } else if let world = Self.defaultWorldPosition(for: record) {
                    worldByVectorId[record.vectorId] = world
                }
            }
            guard let centerWorld = personFocus?.worldPosition ?? worldByVectorId[vectorId] else {
                throw LockedNodeContextError.centerNotFound
            }

            var representativeWorldByMessageId: [String: SIMD3<Float>] = [:]
            for record in allRecords.sorted(by: Self.recordSort) {
                guard let world = worldByVectorId[record.vectorId] else { continue }
                representativeWorldByMessageId[record.messageId] = representativeWorldByMessageId[record.messageId] ?? world
            }

            return VectorPayload(
                centerMessageId: centerRecord.messageId,
                centerWorld: centerWorld,
                ownRecords: ownRecords.sorted(by: Self.recordSort),
                neighbours: neighbours,
                worldByVectorId: worldByVectorId,
                representativeWorldByMessageId: representativeWorldByMessageId,
                summaryByVectorId: Dictionary(uniqueKeysWithValues: allRecords.map { ($0.vectorId, Self.briefText(from: $0.textPayload)) }),
                similarMessageIds: similarMessageIds
            )
        }.value
    }

    @MainActor
    private func loadBodyContent(row: MessageFilterRow) async -> LockReadoutBodyContent? {
        let htmlPath = row.bodyHtmlPath
        let textPath = row.bodyTextPath
        let result = await Task.detached(priority: .userInitiated) {
            LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: textPath)
        }.value
        switch result {
        case .loaded(let source):
            return LockReadoutBodyContent(source: source)
        case .missing:
            return LockReadoutBodyContent(source: LockReadoutBodySource(text: "", format: .plainText))
        case .failed:
            return nil
        }
    }

    @MainActor
    private func loadSwiftDataContext(centerMessageId: String) -> SwiftDataContext {
        guard let uuid = UUID(uuidString: centerMessageId),
              let message = try? modelContext.fetch(
                FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
              ).first else {
            return SwiftDataContext(attachments: [], correspondents: [], threadSiblings: [])
        }

        let attachments = message.attachments
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            .map { LockedAttachmentSummary(attachment: $0) }

        let correspondents = (try? modelContext.fetch(FetchDescriptor<Correspondent>()))?
            .map {
                LockedCorrespondentSummary(
                    id: $0.id,
                    displayName: $0.primaryName,
                    email: $0.primaryEmail.lowercased(),
                    organization: $0.organization,
                    familiarityScore: $0.familiarityScore
                )
            } ?? []

        let threadCandidates = threadCandidateMessages(for: message)
        let purpose = (classificationOverride ?? Self.row(from: message).mailClassification)?.purpose
        let resolvedMessageIDs = ProjectLensActionRepository(modelContext: modelContext)
            .actionState(accountScopeKey: "all")
            .resolvedMessageIDs
        let threadSiblings = LockedNodeThreadResolver.threadSiblings(
            for: message,
            candidates: threadCandidates,
            messageIndex: messageIndex,
            resolvedMessageIDs: resolvedMessageIDs,
            allowSubjectFallback: activeFrame.spatialLens == .people
                || purpose?.usesSimilarSeriesThreadReport != true
        )
        return SwiftDataContext(
            attachments: attachments,
            correspondents: correspondents,
            threadSiblings: threadSiblings
        )
    }

    @MainActor
    private func threadCandidateMessages(for message: Message) -> [Message] {
        var byId: [UUID: Message] = [message.id: message]
        for related in message.thread?.messages ?? [] {
            byId[related.id] = related
        }

        let fetched: [Message]
        if let accountID = message.accountID ?? message.account?.id {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.accountID == accountID }
            )
            fetched = (try? modelContext.fetch(descriptor)) ?? []
        } else {
            fetched = (try? modelContext.fetch(FetchDescriptor<Message>())) ?? []
        }

        for candidate in fetched {
            byId[candidate.id] = candidate
        }
        return Array(byId.values)
    }

    /// The attachment an attachment vector was embedded from. Its
    /// `chunkIndex` counts chunks within one attachment, so it cannot index
    /// the message's attachment list; the vector's metadata names the
    /// attachment by id, and by filename for rows written before ids.
    static func attachment(
        for metadataJSON: String,
        in attachments: [LockedAttachmentSummary]
    ) -> LockedAttachmentSummary? {
        if let metadata = try? JSONDecoder().decode(AttachmentVectorMetadata.self, from: Data(metadataJSON.utf8)) {
            if let attachmentId = metadata.attachmentId.flatMap(UUID.init(uuidString:)),
               let match = attachments.first(where: { $0.id == attachmentId }) {
                return match
            }
            let byName = attachments.filter { $0.filename == metadata.filename }
            if byName.count == 1 {
                return byName[0]
            }
        }
        return attachments.count == 1 ? attachments.first : nil
    }

    private func makeThreadReport(
        centerRow: MessageFilterRow,
        purpose: MailPurpose?,
        thread: [LockedNodeContext.ThreadSibling],
        similarMessageIds: Set<String>
    ) -> SurveyTelemetryThreadReport {
        if activeFrame.spatialLens == .people,
           let focusedEmail = personFocus?.email
            ?? Self.primaryPeopleEmail(row: centerRow, userAddresses: userAddresses) {
            return Self.peopleThreadReport(
                focusedEmail: focusedEmail,
                messageIndex: messageIndex
            )
        }

        if purpose?.usesSimilarSeriesThreadReport == true {
            let similarRows = similarMessageIds.compactMap { messageIndex[$0] }
            let dates = ([centerRow.receivedAt] + similarRows.map(\.receivedAt)).compactMap { $0 }
            let similarTotal = centerRow.neighborCount > 0
                ? centerRow.neighborCount + 1
                : similarMessageIds.count + 1
            return .similarSeries(
                totalCount: similarTotal,
                startDate: dates.min(),
                endDate: dates.max()
            )
        }

        let userReplyCount = thread.filter(\.isSentByUser).count
            + (centerRow.isSentByUser ? 1 : 0)
        let messagesFromOthers = max(0, thread.count + 1 - userReplyCount)
        let datedEntries: [(date: Date, isSentByUser: Bool)] = (
            [(centerRow.receivedAt, centerRow.isSentByUser)]
            + thread.map { ($0.receivedAt, $0.isSentByUser) }
        ).compactMap { entry in
            guard let date = entry.0 else { return nil }
            return (date, entry.1)
        }
        let firstMessageAt = datedEntries.map(\.date).min()
        let lastUserReplyAt = datedEntries.filter(\.isSentByUser).map(\.date).max()
        return .conversation(
            messagesFromOthers: messagesFromOthers,
            userReplyCount: userReplyCount,
            firstMessageAt: firstMessageAt,
            lastUserReplyAt: lastUserReplyAt
        )
    }

    /// Aggregates the user's correspondence with `focusedEmail` across the
    /// full message index. People-layer telemetry shows the all-time
    /// reciprocity — thread count, received total, included total, sent total,
    /// and the start...end window — because the lock pane represents the
    /// contact, not the currently-filtered ring nodes.
    static func peopleThreadReport(
        focusedEmail rawFocusedEmail: String,
        messageIndex: [String: MessageFilterRow]
    ) -> SurveyTelemetryThreadReport {
        let focusedEmail = normalizedEmail(rawFocusedEmail)
        guard !focusedEmail.isEmpty else {
            return .people(
                sentCount: 0,
                receivedCount: 0,
                includedCount: 0,
                threadCount: 0,
                firstMessageAt: nil,
                lastMessageAt: nil
            )
        }

        var sentCount = 0
        var receivedCount = 0
        var includedCount = 0
        var threadKeys = Set<String>()
        var firstDate: Date?
        var lastDate: Date?
        for row in messageIndex.values {
            let isRelevant: Bool
            if row.isSentByUser {
                isRelevant = recipientSet(row: row).contains(focusedEmail)
                if isRelevant { sentCount += 1 }
            } else {
                let isSender = normalizedEmail(row.fromAddress) == focusedEmail
                let isIncluded = !isSender && recipientSet(row: row).contains(focusedEmail)
                isRelevant = isSender || isIncluded
                if isSender {
                    receivedCount += 1
                } else if isIncluded {
                    includedCount += 1
                }
            }
            guard isRelevant else { continue }
            threadKeys.insert(normalizedSubjectKey(row.subject))
            if let date = row.receivedAt {
                if firstDate == nil || date < firstDate! { firstDate = date }
                if lastDate == nil || date > lastDate! { lastDate = date }
            }
        }
        return .people(
            sentCount: sentCount,
            receivedCount: receivedCount,
            includedCount: includedCount,
            threadCount: threadKeys.count,
            firstMessageAt: firstDate,
            lastMessageAt: lastDate
        )
    }

    /// Strips repeated reply / forward prefixes so two messages that
    /// continue the same conversation collapse into one thread key. This
    /// is a heuristic — `MessageFilterRow` doesn't carry a stored
    /// `threadId` — but it matches what mail clients already do visually.
    private static func normalizedSubjectKey(_ subject: String) -> String {
        var current = subject.lowercased()
        while true {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("re:") {
                current = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("fwd:") {
                current = String(trimmed.dropFirst(4))
            } else if trimmed.hasPrefix("fw:") {
                current = String(trimmed.dropFirst(3))
            } else {
                return trimmed
            }
        }
    }

    private static func primaryPeopleEmail(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> String? {
        let users = Set(userAddresses.map(normalizedEmail).filter { !$0.isEmpty })
        if row.isSentByUser {
            for rawAddress in row.recipientAddresses {
                let email = normalizedEmail(rawAddress)
                if !email.isEmpty, !users.contains(email) {
                    return email
                }
            }
            return nil
        }
        let sender = normalizedEmail(row.fromAddress)
        return sender.isEmpty || users.contains(sender) ? nil : sender
    }

    private static func recipientSet(row: MessageFilterRow) -> Set<String> {
        Set(row.recipientAddresses.map(normalizedEmail).filter { !$0.isEmpty })
    }

    private nonisolated static let neighbourMessageLimit = 12
    private nonisolated static let similarMessageEdgeLimit = 15
    private nonisolated static let similarMessageThreshold: Float = 0.60

    private nonisolated static func similarMessageIds(
        anchorMessageId: String,
        anchorVectorIds: Set<Int64>,
        neighborsBySource: [Int64: [VectorNeighbor]],
        messageByVectorId: [Int64: String],
        eligibleMessageIds: Set<String>?
    ) -> Set<String> {
        var messageIds = Set<String>()
        for sourceId in anchorVectorIds {
            guard let edges = neighborsBySource[sourceId] else { continue }
            for edge in edges where edge.similarity >= Self.similarMessageThreshold {
                guard edge.sourceId == sourceId,
                      let targetMessageId = messageByVectorId[edge.targetId],
                      targetMessageId != anchorMessageId else {
                    continue
                }
                if let eligibleMessageIds, !eligibleMessageIds.contains(targetMessageId) {
                    continue
                }
                messageIds.insert(targetMessageId)
            }
        }
        return messageIds
    }

    private nonisolated static func representativeNeighbourRecord(
        from records: [VectorRecord]
    ) -> VectorRecord? {
        records.sorted(by: recordSort).first
    }

    private nonisolated static func defaultWorldPosition(for record: VectorRecord) -> SIMD3<Float>? {
        guard let x = record.layoutX, let y = record.layoutY, let z = record.layoutZ else { return nil }
        return SIMD3<Float>(x, y, z)
    }

    private nonisolated static func recordSort(_ lhs: VectorRecord, _ rhs: VectorRecord) -> Bool {
        if lhs.messageId != rhs.messageId { return lhs.messageId < rhs.messageId }
        if lhs.collection != rhs.collection {
            return collectionRank(lhs.collection) < collectionRank(rhs.collection)
        }
        if lhs.chunkIndex != rhs.chunkIndex { return lhs.chunkIndex < rhs.chunkIndex }
        return lhs.vectorId < rhs.vectorId
    }

    private nonisolated static func collectionRank(_ collection: VectorCollection) -> Int {
        switch collection {
        case .context: return 0
        case .attachment: return 1
        case .entity: return 2
        case .style: return 3
        }
    }

    private nonisolated static func briefText(from payload: String) -> String {
        let normalized = payload
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > 120 else { return normalized }
        return String(normalized.prefix(120))
    }

    private nonisolated static func messageTimelineDate(for message: Message, includeIngestedFallback: Bool) -> Date? {
        let preferred = message.isSentByUser
            ? (message.sentAt ?? message.receivedAt)
            : (message.receivedAt ?? message.sentAt)
        if let preferred {
            return preferred
        }
        return includeIngestedFallback ? message.ingestedAt : nil
    }

    @MainActor
    private static func row(from message: Message) -> MessageFilterRow {
        let recipients = recipientRows(from: message)
        return MessageFilterRow(
            accountId: message.accountID ?? message.account?.id,
            threadId: message.thread?.id,
            messageType: messageType(for: message),
            embeddingStatus: message.embeddingStatus,
            isRead: false,
            isReplied: message.repliedAt != nil,
            isSentByUser: message.isSentByUser,
            flagged: message.flaggedOrFalse,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: recipients.toAddresses,
            toNames: recipients.toNames,
            toDisplayNames: recipients.toDisplayNames,
            ccAddresses: recipients.ccAddresses,
            ccNames: recipients.ccNames,
            ccDisplayNames: recipients.ccDisplayNames,
            bccAddresses: recipients.bccAddresses,
            bccNames: recipients.bccNames,
            bccDisplayNames: recipients.bccDisplayNames,
            recipientAddresses: recipients.recipientAddresses,
            subject: message.subject,
            receivedAt: messageTimelineDate(for: message, includeIngestedFallback: false),
            ingestedAt: message.ingestedAt,
            liveDetectedAt: message.liveDetectedAt,
            bodyTextPath: message.bodyTextPath,
            bodyHtmlPath: message.bodyHtmlPath,
            bodySummary: message.analysis?.bodySummary,
            bodySummaryInputFingerprint: message.analysis?.bodySummaryInputFingerprint,
            mailClassificationJSON: message.analysis?.mailClassificationJSON,
            customCategoryKeys: Set(CustomCategoryKeysJSON.decode(message.analysis?.customCategoryKeysJSON))
        )
    }

    private struct RecipientRows {
        let toAddresses: [String]
        let toNames: [String]
        let toDisplayNames: [String]
        let ccAddresses: [String]
        let ccNames: [String]
        let ccDisplayNames: [String]
        let bccAddresses: [String]
        let bccNames: [String]
        let bccDisplayNames: [String]
        let recipientAddresses: [String]
    }

    @MainActor
    private static func recipientRows(from message: Message) -> RecipientRows {
        var toAddresses: [String] = []
        var toNames: [String] = []
        var toDisplayNames: [String] = []
        var ccAddresses: [String] = []
        var ccNames: [String] = []
        var ccDisplayNames: [String] = []
        var bccAddresses: [String] = []
        var bccNames: [String] = []
        var bccDisplayNames: [String] = []
        var recipientAddresses: [String] = []
        for link in message.participants {
            guard link.role != .from,
                  let participant = link.participant else {
                continue
            }
            let email = normalizedEmail(participant.emailAddress)
            guard !email.isEmpty else { continue }
            recipientAddresses.append(email)
            let displayName = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch link.role {
            case .from:
                continue
            case .to:
                toAddresses.append(email)
                toDisplayNames.append(displayName)
                toNames.append(displayName.lowercased())
            case .cc:
                ccAddresses.append(email)
                ccDisplayNames.append(displayName)
                ccNames.append(displayName.lowercased())
            case .bcc:
                bccAddresses.append(email)
                bccDisplayNames.append(displayName)
                bccNames.append(displayName.lowercased())
            }
        }
        return RecipientRows(
            toAddresses: toAddresses,
            toNames: toNames,
            toDisplayNames: toDisplayNames,
            ccAddresses: ccAddresses,
            ccNames: ccNames,
            ccDisplayNames: ccDisplayNames,
            bccAddresses: bccAddresses,
            bccNames: bccNames,
            bccDisplayNames: bccDisplayNames,
            recipientAddresses: recipientAddresses
        )
    }

    private static func messageType(for message: Message) -> MessageType {
        guard !message.isLiveInboundTriageEligible,
              !message.isSentByUser,
              message.messageType == .actionable || message.messageType == .confirmation else {
            return message.messageType
        }
        return .report
    }

    private nonisolated static func normalizedEmail(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("mailto:") {
            value.removeFirst("mailto:".count)
        }
        return value
    }
}

@MainActor
struct LockedNodeThreadResolver {
    /// Batch threading for a list of messages — used by the Timeline
    /// data controller to assign each message a thread UUID without
    /// needing the (unpopulated) `MessageThread` SwiftData relationship.
    /// Returns a mapping `message UUID → synthetic thread UUID` whose
    /// equality semantics mean "two messages with the same returned
    /// value are in the same thread."
    ///
    /// Algorithm:
    ///   - Build `Message-ID` → `[messageID]` and `Referenced-ID` →
    ///     `[messageID]` indexes from the input set.
    ///   - Union-find: any pair of messages whose header graphs touch
    ///     (one's Message-ID appears in another's References /
    ///     In-Reply-To, or two messages reference the same parent)
    ///     get unioned.
    ///   - Subject-overlap fallback: messages whose normalized
    ///     subject matches and whose participant sets overlap get
    ///     unioned even if the header chain is broken — this catches
    ///     the common case of replies whose envelope headers were
    ///     mangled by some intermediary mail server.
    ///   - Single-message components are returned as orphans (no
    ///     entry in the mapping). The Timeline layout engine
    ///     interprets a missing thread ID as an orphan chapter.
    ///
    /// Determinism: the union-find root for a component is the
    /// component's lexicographically-lowest message UUID — every
    /// call with the same input produces the same thread IDs.
    static func groupIntoThreads(_ messages: [Message]) -> [UUID: UUID] {
        guard messages.count > 1 else { return [:] }

        var byMessageIDHeader: [String: [UUID]] = [:]
        var byReferenced: [String: [UUID]] = [:]
        for message in messages {
            for token in messageIDTokens(from: message.messageIdHeader) {
                byMessageIDHeader[token, default: []].append(message.id)
            }
            for token in referencedMessageIDTokens(for: message) {
                byReferenced[token, default: []].append(message.id)
            }
        }

        // Union-find with path compression. `parent[id]` points to the
        // current best-known representative for that message's
        // component; `find` walks to the root and flattens the path.
        var parent: [UUID: UUID] = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.id) })

        func find(_ id: UUID) -> UUID {
            var current = id
            while parent[current]! != current { current = parent[current]! }
            let root = current
            var node = id
            while parent[node]! != root {
                let next = parent[node]!
                parent[node] = root
                node = next
            }
            return root
        }

        func union(_ lhs: UUID, _ rhs: UUID) {
            let rootL = find(lhs)
            let rootR = find(rhs)
            guard rootL != rootR else { return }
            // Keep the smaller UUID as the root so callers get stable
            // thread IDs across runs.
            if rootL.uuidString < rootR.uuidString {
                parent[rootR] = rootL
            } else {
                parent[rootL] = rootR
            }
        }

        for message in messages {
            // Children: messages that reference this one's Message-ID.
            for token in messageIDTokens(from: message.messageIdHeader) {
                for childId in byReferenced[token] ?? [] {
                    union(message.id, childId)
                }
            }
            // Parents + siblings: messages this one references, and
            // messages that share a referenced parent.
            for token in referencedMessageIDTokens(for: message) {
                for parentId in byMessageIDHeader[token] ?? [] {
                    union(message.id, parentId)
                }
                for siblingId in byReferenced[token] ?? [] {
                    union(message.id, siblingId)
                }
            }
        }

        // Subject-overlap fallback. Bucket by normalized subject and
        // union any two messages in the same bucket whose participant
        // sets overlap (or whose senders match).
        var subjectBuckets: [String: [Message]] = [:]
        for message in messages {
            let normalized = normalizedSubject(message.subject)
            guard !normalized.isEmpty, normalized.count >= 3 else { continue }
            subjectBuckets[normalized, default: []].append(message)
        }
        for (_, bucket) in subjectBuckets where bucket.count > 1 {
            for i in 0..<bucket.count {
                let center = bucket[i]
                let centerParticipants = participantEmails(
                    for: center,
                    excluding: center.account?.emailAddress
                )
                for j in (i + 1)..<bucket.count {
                    let candidate = bucket[j]
                    if hasParticipantOverlap(
                        candidate,
                        centerParticipants: centerParticipants,
                        center: center
                    ) {
                        union(center.id, candidate.id)
                    }
                }
            }
        }

        // Count members per root so single-message components can be
        // returned as orphans rather than as one-message threads.
        var rootCounts: [UUID: Int] = [:]
        for message in messages {
            rootCounts[find(message.id), default: 0] += 1
        }

        var result: [UUID: UUID] = [:]
        for message in messages {
            let root = find(message.id)
            if rootCounts[root, default: 0] > 1 {
                result[message.id] = root
            }
        }
        return result
    }

    static func threadSiblings(
        for center: Message,
        candidates: [Message],
        messageIndex: [String: MessageFilterRow],
        resolvedMessageIDs: Set<UUID> = [],
        allowSubjectFallback: Bool = true
    ) -> [LockedNodeContext.ThreadSibling] {
        let messages = relatedMessages(
            to: center,
            candidates: candidates,
            allowSubjectFallback: allowSubjectFallback
        )
        guard messages.count > 1 else { return [] }

        let sorted = messages.sorted(by: messageChronology)
        guard let centerIndex = sorted.firstIndex(where: { $0.id == center.id }) else { return [] }

        return sorted.enumerated().compactMap { index, sibling in
            guard sibling.id != center.id else { return nil }
            let messageId = sibling.id.uuidString
            let row = messageIndex[messageId] ?? Self.row(
                from: sibling,
                isResolved: resolvedMessageIDs.contains(sibling.id)
            )
            return LockedNodeContext.ThreadSibling(
                messageId: messageId,
                row: row,
                position: index - centerIndex,
                receivedAt: messageTimelineDate(for: sibling, includeIngestedFallback: false),
                isSentByUser: sibling.isSentByUser
            )
        }
    }

    private static func relatedMessages(
        to center: Message,
        candidates: [Message],
        allowSubjectFallback: Bool
    ) -> [Message] {
        var byId: [UUID: Message] = [center.id: center]
        for candidate in candidates {
            byId[candidate.id] = candidate
        }
        for candidate in center.thread?.messages ?? [] {
            byId[candidate.id] = candidate
        }

        let allMessages = Array(byId.values)
        var byMessageIDHeader: [String: [Message]] = [:]
        var byReferencedMessageID: [String: [Message]] = [:]
        for message in allMessages {
            for token in messageIDTokens(from: message.messageIdHeader) {
                byMessageIDHeader[token, default: []].append(message)
            }
            for token in referencedMessageIDTokens(for: message) {
                byReferencedMessageID[token, default: []].append(message)
            }
        }

        var relatedIds = Set<UUID>()
        var queue: [Message] = []
        func enqueue(_ message: Message) {
            guard relatedIds.insert(message.id).inserted else { return }
            queue.append(message)
        }
        func drainQueue() {
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1

                for token in messageIDTokens(from: current.messageIdHeader) {
                    for child in byReferencedMessageID[token] ?? [] {
                        enqueue(child)
                    }
                }

                for token in referencedMessageIDTokens(for: current) {
                    for parent in byMessageIDHeader[token] ?? [] {
                        enqueue(parent)
                    }
                    for sibling in byReferencedMessageID[token] ?? [] {
                        enqueue(sibling)
                    }
                }
            }
        }

        enqueue(center)
        for candidate in center.thread?.messages ?? [] {
            enqueue(candidate)
        }
        drainQueue()

        if allowSubjectFallback {
            let subjectRoot = normalizedSubject(center.subject)
            let centerParticipants = participantEmails(for: center, excluding: center.account?.emailAddress)
            if !subjectRoot.isEmpty, subjectRoot.count >= 3 {
                for candidate in allMessages
                where candidate.id != center.id
                    && normalizedSubject(candidate.subject) == subjectRoot
                    && hasParticipantOverlap(candidate, centerParticipants: centerParticipants, center: center) {
                    enqueue(candidate)
                }
                drainQueue()
            }
        }

        return relatedIds.compactMap { byId[$0] }
    }

    private static func hasParticipantOverlap(
        _ candidate: Message,
        centerParticipants: Set<String>,
        center: Message
    ) -> Bool {
        let candidateParticipants = participantEmails(for: candidate, excluding: center.account?.emailAddress)
        if !centerParticipants.isEmpty, !candidateParticipants.isEmpty {
            return !centerParticipants.isDisjoint(with: candidateParticipants)
        }

        let centerSender = normalizedEmail(center.fromAddress)
        let candidateSender = normalizedEmail(candidate.fromAddress)
        return !centerSender.isEmpty && centerSender == candidateSender
    }

    private static func participantEmails(for message: Message, excluding excludedEmail: String?) -> Set<String> {
        let excluded = normalizedEmail(excludedEmail ?? "")
        var emails = Set<String>()
        let from = normalizedEmail(message.fromAddress)
        if !from.isEmpty {
            emails.insert(from)
        }
        for participant in message.participants {
            guard let email = participant.participant?.emailAddress else { continue }
            let normalized = normalizedEmail(email)
            if !normalized.isEmpty {
                emails.insert(normalized)
            }
        }
        if !excluded.isEmpty {
            emails.remove(excluded)
        }
        return emails
    }

    private static func referencedMessageIDTokens(for message: Message) -> Set<String> {
        messageIDTokens(from: message.inReplyTo)
            .union(messageIDTokens(from: message.referencesChain))
    }

    private static func messageIDTokens(from value: String?) -> Set<String> {
        guard let value else { return [] }
        let tokens = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { raw -> String? in
                let trimmed = String(raw).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
                )
                return normalizeMessageIDHeader(trimmed)
            }
        return Set(tokens)
    }

    private static func normalizedSubject(_ subject: String) -> String {
        var value = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["re:", "fwd:", "fw:"] where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }
        return value
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func messageChronology(_ lhs: Message, _ rhs: Message) -> Bool {
        let leftDate = messageTimelineDate(for: lhs, includeIngestedFallback: true) ?? lhs.ingestedAt
        let rightDate = messageTimelineDate(for: rhs, includeIngestedFallback: true) ?? rhs.ingestedAt
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func messageTimelineDate(for message: Message, includeIngestedFallback: Bool) -> Date? {
        let preferred = message.isSentByUser
            ? (message.sentAt ?? message.receivedAt)
            : (message.receivedAt ?? message.sentAt)
        if let preferred {
            return preferred
        }
        return includeIngestedFallback ? message.ingestedAt : nil
    }

    private static func row(
        from message: Message,
        isResolved: Bool = false
    ) -> MessageFilterRow {
        let recipients = recipientRows(from: message)
        return MessageFilterRow(
            accountId: message.accountID ?? message.account?.id,
            threadId: message.thread?.id,
            messageType: messageType(for: message),
            embeddingStatus: message.embeddingStatus,
            isRead: false,
            isReplied: message.repliedAt != nil,
            isResolved: isResolved,
            isSentByUser: message.isSentByUser,
            flagged: message.flaggedOrFalse,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: recipients.toAddresses,
            toNames: recipients.toNames,
            toDisplayNames: recipients.toDisplayNames,
            ccAddresses: recipients.ccAddresses,
            ccNames: recipients.ccNames,
            ccDisplayNames: recipients.ccDisplayNames,
            bccAddresses: recipients.bccAddresses,
            bccNames: recipients.bccNames,
            bccDisplayNames: recipients.bccDisplayNames,
            recipientAddresses: recipients.recipientAddresses,
            subject: message.subject,
            receivedAt: messageTimelineDate(for: message, includeIngestedFallback: false),
            ingestedAt: message.ingestedAt,
            liveDetectedAt: message.liveDetectedAt,
            bodyTextPath: message.bodyTextPath,
            bodyHtmlPath: message.bodyHtmlPath,
            bodySummary: message.analysis?.bodySummary,
            bodySummaryInputFingerprint: message.analysis?.bodySummaryInputFingerprint,
            mailClassificationJSON: message.analysis?.mailClassificationJSON,
            customCategoryKeys: Set(CustomCategoryKeysJSON.decode(message.analysis?.customCategoryKeysJSON))
        )
    }

    private struct RecipientRows {
        let toAddresses: [String]
        let toNames: [String]
        let toDisplayNames: [String]
        let ccAddresses: [String]
        let ccNames: [String]
        let ccDisplayNames: [String]
        let bccAddresses: [String]
        let bccNames: [String]
        let bccDisplayNames: [String]
        let recipientAddresses: [String]
    }

    private static func recipientRows(from message: Message) -> RecipientRows {
        var toAddresses: [String] = []
        var toNames: [String] = []
        var toDisplayNames: [String] = []
        var ccAddresses: [String] = []
        var ccNames: [String] = []
        var ccDisplayNames: [String] = []
        var bccAddresses: [String] = []
        var bccNames: [String] = []
        var bccDisplayNames: [String] = []
        var recipientAddresses: [String] = []
        for link in message.participants {
            guard link.role != .from,
                  let participant = link.participant else {
                continue
            }
            let email = normalizedEmail(participant.emailAddress)
            guard !email.isEmpty else { continue }
            recipientAddresses.append(email)
            let displayName = participant.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch link.role {
            case .from:
                continue
            case .to:
                toAddresses.append(email)
                toDisplayNames.append(displayName)
                toNames.append(displayName.lowercased())
            case .cc:
                ccAddresses.append(email)
                ccDisplayNames.append(displayName)
                ccNames.append(displayName.lowercased())
            case .bcc:
                bccAddresses.append(email)
                bccDisplayNames.append(displayName)
                bccNames.append(displayName.lowercased())
            }
        }
        return RecipientRows(
            toAddresses: toAddresses,
            toNames: toNames,
            toDisplayNames: toDisplayNames,
            ccAddresses: ccAddresses,
            ccNames: ccNames,
            ccDisplayNames: ccDisplayNames,
            bccAddresses: bccAddresses,
            bccNames: bccNames,
            bccDisplayNames: bccDisplayNames,
            recipientAddresses: recipientAddresses
        )
    }

    private static func messageType(for message: Message) -> MessageType {
        guard !message.isLiveInboundTriageEligible,
              !message.isSentByUser,
              message.messageType == .actionable || message.messageType == .confirmation else {
            return message.messageType
        }
        return .report
    }
}

private extension MailPurpose {
    var usesSimilarSeriesThreadReport: Bool {
        switch self {
        case .receipt,
             .promotion,
             .newsletter,
             .verificationCode,
             .notification,
             .security,
             .shipping,
             .travel,
             .finance,
             .calendar:
            return true
        case .correspondence,
             .announcement,
             .support,
             .legal,
             .socialActivity,
             .other:
            return false
        }
    }
}
