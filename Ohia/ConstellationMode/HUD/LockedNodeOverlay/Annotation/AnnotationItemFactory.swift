import Foundation
import simd
import OhiaCore
import OhiaML

@MainActor
struct AnnotationItemFactory {
    let centerSubject: String
    /// Anchor message's `receivedAt`, used to render the parenthetical relative
    /// time delta on neighbour panes ("2026-04-05 14:34 (+00:30)"). `nil` when
    /// the locked message has no timestamp — in that case the date label
    /// renders without the parenthetical.
    let centerReceivedAt: Date?
    /// Per-message body-summary overrides supplied by the parent. When a key
    /// is present, the value takes precedence over `row.bodySummary` — used
    /// by the lock-time pre-warm pipeline so neighbour popups pick up
    /// freshly-generated summaries before the snapshot rebuilds.
    var summaryOverridesByMessageId: [String: String] = [:]
    /// When set, this factory builds message-moon panes for a focused
    /// People island instead of email-owned attachment/entity/thread panes.
    var personFocus: LockedPersonFocus? = nil
    /// Full correspondent ring scope supplied by the host when in People
    /// focus. When non-empty, `makePeopleItems` enumerates *every*
    /// exchanged message (sent, sent-included, received, and included)
    /// instead of the top-K `context.neighbours` sample — so the chip strip's
    /// counts match what the user sees orbiting the Saturn. Tuples carry
    /// the messageId alongside the row because `MessageFilterRow` itself
    /// does not embed an id (the parent's `messageIndex` keys it).
    var peopleRingRows: [(messageId: String, row: MessageFilterRow)] = []
    /// Distinguishes "the host supplied an empty visible ring scope" from
    /// older callers that don't supply the People ring at all. The former
    /// must render zero ring panes so stale People-ring chips vanish when
    /// filters remove them; the latter keeps the legacy context fallback
    /// used by focused-scene tests.
    var peopleRingRowsAreAuthoritative = false
    let relevanceWriter = AnnotationRelevanceWriter()

    func makeItems(context: LockedNodeContext, renderPacket: ConstellationRenderPacket) -> [AnnotationItem] {
        // In the People solar-system portrait the scene renders the FULL
        // galaxy: a message shared between the focused correspondent and
        // other people carries one star on the focused ring AND one on each
        // co-participant's (background) hub. A plain last-write-wins reduce
        // could therefore anchor a focused-ring annotation to a background
        // hub's star, projecting the dial's satellite 1000+px off the ring
        // (the "leader shoots off-screen" bug). Prefer the star sitting on
        // the focused correspondent's own hub so the dial always attaches to
        // the node the user sees on the ring. Meaning locks (no personFocus)
        // keep the original last-write-wins behavior exactly.
        let focusEmail = personFocus.map { Self.normalizedEmail($0.email) }
        var anchorByMessageId: [String: SIMD3<Float>] = [:]
        var anchorIsFocusHub: [String: Bool] = [:]
        for star in renderPacket.stars {
            let isFocusHub = focusEmail.map { star.peopleHubEmail.map(Self.normalizedEmail) == $0 } ?? false
            if let existingIsFocusHub = anchorIsFocusHub[star.messageId] {
                if existingIsFocusHub { continue }        // never demote a focus-hub anchor
                anchorByMessageId[star.messageId] = star.position  // upgrade to focus, or last-write-wins among non-focus
                anchorIsFocusHub[star.messageId] = isFocusHub
            } else {
                anchorByMessageId[star.messageId] = star.position
                anchorIsFocusHub[star.messageId] = isFocusHub
            }
        }
        return makeItems(
            context: context,
            anchorByMessageId: anchorByMessageId,
            anchorByVectorId: Dictionary(uniqueKeysWithValues: renderPacket.satellites.map { ($0.vectorId, $0.position) })
        )
    }

    func makeItems(
        context: LockedNodeContext,
        anchorByMessageId: [String: SIMD3<Float>],
        anchorByVectorId: [Int64: SIMD3<Float>] = [:]
    ) -> [AnnotationItem] {
        if let personFocus {
            return makePeopleItems(
                context: context,
                personFocus: personFocus,
                anchorByMessageId: anchorByMessageId
            )
        }

        // Body-chunk vectors (collection == .context) are deliberately excluded from the
        // locked-overlay annotation surface. Their text is already shown verbatim in the
        // email card on the right, so a popup or badge for each chunk would be pure
        // redundancy. The chunks remain in the vector store and the rendered scene as
        // background signal for cosine search and citation linking — they just don't
        // get foreground annotation chrome here. Only attachment + entity vectors and
        // thread/neighbour messages bring net-new context to the overlay.
        let attachmentItems = makeAttachmentItems(
            ownChunks: context.ownChunks,
            allAttachments: context.attachments,
            anchorByVectorId: anchorByVectorId,
            centerWorld: context.center.worldPosition
        )
        let entityItems = context.ownChunks.compactMap { entityItem($0, anchorByVectorId: anchorByVectorId) }
        let threadItems = context.thread.compactMap {
            threadItem(
                $0,
                anchorByMessageId: anchorByMessageId,
                centerWorld: context.center.worldPosition
            )
        }
        let threadMessageIds = Set(context.thread.map(\.messageId))
        let neighbourItems = context.neighbours
            .filter { !threadMessageIds.contains($0.messageId) }
            .map { neighbourItem($0, anchorByMessageId: anchorByMessageId) }
        return (attachmentItems + entityItems + threadItems + neighbourItems).sorted {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            return $0.id < $1.id
        }
    }

    private func makePeopleItems(
        context: LockedNodeContext,
        personFocus: LockedPersonFocus,
        anchorByMessageId: [String: SIMD3<Float>]
    ) -> [AnnotationItem] {
        let focusEmail = Self.normalizedEmail(personFocus.email)
        guard !focusEmail.isEmpty else { return [] }

        let neighbourByMessageId = Dictionary(
            uniqueKeysWithValues: context.neighbours.map { ($0.messageId, $0) }
        )
        // Build the ring entry set from the full correspondent scope when
        // the host has supplied it (every received / sent / included email
        // on the orbit). Fall back to context.center + context.neighbours
        // when no scope was passed — preserves behaviour for any callers
        // that don't yet thread the ring through (tests, focused-scene
        // builder).
        let entries: [(messageId: String, row: MessageFilterRow, score: Float, isCenter: Bool)]
        if peopleRingRowsAreAuthoritative || !peopleRingRows.isEmpty {
            let centerId = context.center.messageId
            entries = peopleRingRows.map { pair in
                let score = Float(neighbourByMessageId[pair.messageId]?.bestSimilarity ?? (pair.messageId == centerId ? 1 : 0.5))
                return (pair.messageId, pair.row, score, pair.messageId == centerId)
            }
        } else {
            entries =
                [(context.center.messageId, context.center.row, 1, true)]
                + context.neighbours.map { ($0.messageId, $0.row, $0.bestSimilarity, false) }
        }
        // The message's star must actually sit on the focused correspondent's
        // ring for the dial to have a node to attach to. In the solar-system
        // portrait a message shared with other people can have its
        // focused-ring star left at the world origin, or only be placed on a
        // co-participant's (background) hub — either way the dial's satellite
        // projects to the origin/sun or far off-screen and the leader shoots
        // away with no ring node beneath it. Require the anchor to sit within
        // a generous multiple of the ring's own world radius of the hub;
        // otherwise drop the item, since it has no visible ring node to hover.
        let focusHubWorld = personFocus.worldPosition
        // A generous multiple of the ring's own world radius. When the ring
        // radius is unknown (0 — e.g. focused-scene builders and unit tests
        // that don't thread ring geometry), there is nothing to measure
        // against, so the guard is disabled (no item dropped).
        let offRingLimitSquared: Float = {
            let span = personFocus.outerRingEdgeRadius * 3
            return span > 0 ? span * span : .greatestFiniteMagnitude
        }()
        var seen = Set<String>()
        return entries.compactMap { entry -> AnnotationItem? in
            guard seen.insert(entry.messageId).inserted,
                  let anchor = anchorByMessageId[entry.messageId] else {
                return nil
            }
            let dxHub = anchor.x - focusHubWorld.x
            let dyHub = anchor.y - focusHubWorld.y
            let dzHub = anchor.z - focusHubWorld.z
            guard (dxHub * dxHub + dyHub * dyHub + dzHub * dzHub) <= offRingLimitSquared else {
                return nil
            }
            let kind = Self.peopleKind(
                row: entry.row,
                focusedEmail: focusEmail
            )
            let dateLabel = Self.neighbourDateLabel(for: entry.row.receivedAt, anchor: centerReceivedAt)
            let directionText = Self.peopleDirectionText(
                row: entry.row,
                focusedDisplayName: personFocus.displayName,
                focusedEmail: focusEmail,
                kind: kind
            )
            let detailParts = [dateLabel].filter { !$0.isEmpty && $0 != "—" }
            let summary = summaryOverridesByMessageId[entry.messageId]?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? entry.row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let title = entry.row.subject.isEmpty ? "(no subject)" : entry.row.subject
            let contextReason = ""
            return AnnotationItem(
                id: entry.isCenter ? "people-center:\(entry.messageId)" : "neighbor:\(entry.messageId)",
                kind: kind,
                anchorVectorId: nil,
                anchorMessageId: entry.messageId,
                anchorWorld: anchor,
                title: title,
                detail: detailParts.joined(separator: " · "),
                briefText: directionText,
                extras: [],
                relevance: relevanceWriter.write(kind: kind, title: title, centerSubject: centerSubject),
                badgeText: Self.peopleBadgeText(kind: kind),
                importance: min(1, max(0.48, Double(entry.score))),
                contextReason: contextReason,
                summary: summary,
                directionSymbol: Self.peopleDirectionSymbol(kind: kind),
                radialAffinity: Double(neighbourByMessageId[entry.messageId]?.bestSimilarity ?? entry.score),
                badgeSortDate: entry.row.receivedAt
            )
        }
        .sorted {
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.id < $1.id
        }
    }

    /// Collapses every `.attachment` chunk into one annotation item per
    /// physical attachment. Multi-chunk attachments (PDFs, long docs) used
    /// to spawn `att 01`, `att 02`, … panes around the locked node — one
    /// per ~256-word slice of extracted text. That made the overlay look
    /// like the message had a dozen attachments when it actually had two.
    /// We now anchor each attachment to its strongest chunk's world
    /// position, concatenate the chunk text in chunkIndex order for lazy
    /// summary generation, and badge the pane by file kind (`pdf`, `doc`,
    /// `xls`, etc.) instead of by chunk index.
    private func makeAttachmentItems(
        ownChunks: [LockedNodeContext.OwnChunk],
        allAttachments: [LockedAttachmentSummary],
        anchorByVectorId: [Int64: SIMD3<Float>],
        centerWorld: SIMD3<Float>
    ) -> [AnnotationItem] {
        // Group every attachment chunk by its parent attachment id. Chunks
        // missing an attachment association are dropped — the overlay can't
        // surface them as anything actionable without metadata.
        let attachmentChunks = ownChunks
            .filter { $0.collection == .attachment }
            .filter { $0.attachment != nil }
        let groups = Dictionary(grouping: attachmentChunks) { $0.attachment!.id }

        // Every attachment in the FILES list gets its own pane. Text-bearing
        // attachments (PDFs, docs, …) anchor to their strongest chunk's
        // world position so the leader line points at the corresponding
        // satellite vector in the constellation. Binary-only attachments —
        // images, audio, archives — have no embedding chunks, so they fall
        // back to the locked node's own world position; the orbital layout
        // coordinator distributes them at angular slots around the focal
        // node (clearance is enforced by `focalClearanceRadius`), so the
        // popup never actually overlays the email card.
        //
        // Inline images that the message embeds in its HTML body (`<img
        // src="cid:…">`) are excluded here — the body card already renders
        // them inline, so a second copy in the orbital ring would just be
        // the same picture shown twice. The `isInline` flag is set at
        // ingestion time and is `true` only when the MIME part is
        // `Content-Disposition: inline` *and* its Content-ID is referenced
        // by a `cid:` URL in the body. Attachments with `isInline == nil`
        // (legacy rows pre-dating the field) keep their pane until the next
        // ingestion touch backfills the flag.
        var items: [AnnotationItem] = []
        for attachment in allAttachments where attachment.isInline != true {
            let chunks = (groups[attachment.id] ?? [])
                .sorted { $0.chunkIndex < $1.chunkIndex }
            let strongest = chunks.first
            let anchorWorld = strongest
                .flatMap { anchorByVectorId[$0.vectorId] ?? $0.worldPosition }
                ?? centerWorld
            items.append(makeAttachmentItem(
                attachment: attachment,
                chunks: chunks,
                anchorWorld: anchorWorld,
                anchorVectorId: strongest?.vectorId
            ))
        }
        return items
    }

    private func makeAttachmentItem(
        attachment: LockedAttachmentSummary,
        chunks: [LockedNodeContext.OwnChunk],
        anchorWorld: SIMD3<Float>,
        anchorVectorId: Int64?
    ) -> AnnotationItem {
        let concatenatedText = chunks
            .map { Self.extractAttachmentText(from: $0.textPayload) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let extractionState = Self.extractionState(
            attachment: attachment,
            concatenatedText: concatenatedText
        )
        let kindBadge = Self.attachmentKindBadge(
            mimeType: attachment.mimeType,
            filename: attachment.filename
        )
        let detail = "\(attachment.mimeType) · \(Self.byteString(attachment.sizeBytes))"
        let chunkSuffix = chunks.count > 1 ? " · \(chunks.count) sections" : ""
        let generatedSummary = AttachmentSummaryPostProcessor.clean(attachment.attachmentSummary)
        let extras: [AnnotationItem.Extra] = [
            .init(key: "type", value: attachment.mimeType.isEmpty ? "—" : attachment.mimeType),
            .init(key: "size", value: Self.byteString(attachment.sizeBytes))
        ]
        // Image attachments piggyback on the visual-summary worker output
        // (`Attachment.visualSummary`) instead of going through the lazy
        // text-summary path used for PDFs/docs. The worker writes a Vision
        // + OCR + Foundation Models paragraph onto the row; we surface it
        // verbatim as the collapsed brief, and fall back to a placeholder
        // while the worker hasn't visited yet.
        let attachmentReference = AnnotationItem.AttachmentReference(
            attachmentID: attachment.id,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            extractionState: extractionState,
            documentKind: attachment.detectedDocumentKind,
            structureUnitKind: attachment.extractionStructureUnitKind,
            structureUnitCount: attachment.extractionStructureUnitCount,
            characterCount: attachment.extractionCharacterCount,
            documentTitle: attachment.documentTitle,
            documentAuthor: attachment.documentAuthor,
            concatenatedText: concatenatedText,
            filePath: attachment.filePath
        )
        return AnnotationItem(
            id: "attachment:\(attachment.id.uuidString)",
            kind: .attachment,
            anchorVectorId: anchorVectorId,
            anchorMessageId: nil,
            anchorWorld: anchorWorld,
            title: attachment.filename,
            // Kind badge ("PDF", "DOCX", "IMAGE", …) sits on the header's
            // first line next to ATTACHMENT so the full MIME + size + section
            // count can drop to its own line below — Office MIME types are
            // 60–72 characters and used to ellipsize the size/section count
            // away on narrow popups.
            headerPrimaryDetail: kindBadge.uppercased(),
            detail: detail + chunkSuffix,
            briefText: brief(Self.attachmentBrief(
                attachment: attachment,
                extractionState: extractionState,
                concatenatedText: concatenatedText,
                isImage: attachmentReference.isImage
            )),
            extras: extras,
            relevance: relevanceWriter.write(
                kind: .attachment,
                title: attachment.filename,
                centerSubject: centerSubject
            ),
            badgeText: kindBadge,
            importance: 0.70,
            summary: generatedSummary,
            attachmentReference: attachmentReference
        )
    }

    private func entityItem(
        _ chunk: LockedNodeContext.OwnChunk,
        anchorByVectorId: [Int64: SIMD3<Float>]
    ) -> AnnotationItem? {
        guard chunk.collection == .entity else { return nil }
        let anchorWorld = anchorByVectorId[chunk.vectorId] ?? chunk.worldPosition
        let title = Self.entityDisplayTitle(
            correspondentDisplayName: chunk.correspondent?.displayName,
            entityKind: chunk.entityKind,
            entityKey: chunk.entityKey
        )
        return AnnotationItem(
            id: "entity:\(chunk.entityKey ?? "\(chunk.vectorId)")",
            kind: .entity,
            anchorVectorId: chunk.vectorId,
            anchorMessageId: nil,
            anchorWorld: anchorWorld,
            title: title,
            detail: chunk.entityKind?.rawValue ?? "mention",
            briefText: entityBrief(chunk),
            extras: [
                .init(key: "score", value: chunk.entityScore.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—"),
                .init(key: "vector", value: "\(chunk.vectorId)")
            ],
            relevance: relevanceWriter.write(kind: .entity, title: title, centerSubject: centerSubject),
            badgeText: "mention",
            importance: entityImportance(chunk.entityScore),
            contextReason: "Mentioned in this message."
        )
    }

    nonisolated static func entityDisplayTitle(
        correspondentDisplayName: String?,
        entityKind: EntityKind?,
        entityKey: String?
    ) -> String {
        if let correspondentDisplayName,
           !correspondentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return correspondentDisplayName
        }
        if entityKind == .attachment, let entityKey {
            let rawFilename = entityKey
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? entityKey
            let decoded = MIMEHeaderDecoder.decodeEncodedWords(rawFilename)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty {
                return decoded
            }
        }
        return entityKey ?? entityKind?.rawValue ?? "Mention"
    }

    private func threadItem(
        _ sibling: LockedNodeContext.ThreadSibling,
        anchorByMessageId: [String: SIMD3<Float>],
        centerWorld: SIMD3<Float>
    ) -> AnnotationItem? {
        guard abs(sibling.position) <= 2 else { return nil }
        let anchor = anchorByMessageId[sibling.messageId]
            ?? centerWorld + SIMD3<Float>(Float(sibling.position) * 0.045, 0.12, 0)
        let directionLabel = sibling.isSentByUser ? "sent" : "received"
        let dateLabel = sibling.receivedAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        let kind: AnnotationKind = sibling.isSentByUser ? .reply : .thread
        let override = summaryOverridesByMessageId[sibling.messageId]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let summary = override
            ?? sibling.row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        // Suppress the brief-text teaser entirely — the chevron-expanded
        // pane already renders the full body summary, and surfacing a
        // truncated copy above it just duplicates the same paragraph at
        // the top of the popup.
        let briefText = ""
        let fallbackReason = sibling.position < 0
            ? "Earlier message in the same conversation."
            : "Later message in the same conversation."
        let contextReason = Self.threadRelativeTimeLabel(
            sibling: sibling.receivedAt,
            anchor: centerReceivedAt,
            position: sibling.position
        ).map { "\($0) in the same conversation." } ?? fallbackReason
        return AnnotationItem(
            id: "thread:\(sibling.messageId)",
            kind: kind,
            anchorVectorId: nil,
            anchorMessageId: sibling.messageId,
            anchorWorld: anchor,
            title: sibling.row.subject.isEmpty ? "(no subject)" : sibling.row.subject,
            // Position sits on the header's first line next to the context
            // label; the longer date/direction fragment drops to its own
            // line beneath so the date is always fully visible at narrow
            // popup widths.
            headerPrimaryDetail: signed(sibling.position),
            detail: "\(dateLabel) · \(directionLabel)",
            briefText: briefText,
            // Position/direction are already in the header detail line; the
            // chevron-expanded pane is reserved for the body summary so we
            // don't restate header chrome.
            extras: [],
            relevance: relevanceWriter.write(kind: kind, title: sibling.row.subject, centerSubject: centerSubject),
            badgeText: "\(kind.badgePrefix) \(signed(sibling.position))",
            importance: threadImportance(position: sibling.position),
            contextReason: contextReason,
            summary: summary,
            // Sent → outbound paperplane; received → inbound tray. Same
            // vocabulary as the neighbour pane and the trace toggles.
            directionSymbol: sibling.isSentByUser ? "paperplane.fill" : "tray.and.arrow.down",
            badgeSortDate: sibling.receivedAt ?? sibling.row.receivedAt
        )
    }

    private func neighbourItem(
        _ neighbour: LockedNodeContext.Neighbour,
        anchorByMessageId: [String: SIMD3<Float>]
    ) -> AnnotationItem {
        // Brief = "<from|to> <correspondent> · <date> · <purpose>". Always
        // explicit about direction: when the user sent the message, the
        // brief leads with "to <recipient>"; when they received it, it
        // leads with "from <sender>". The direction symbol in the popup
        // header (paperplane.fill / tray.and.arrow.down) reinforces the
        // same signal at a glance.
        let isSentByUser = neighbour.row.isSentByUser
        let counterparty = Self.counterpartyLabel(row: neighbour.row, isSentByUser: isSentByUser)
        let directionPrefix = isSentByUser ? "to" : "from"
        let directedLabel = counterparty.isEmpty
            ? directionPrefix
            : "\(directionPrefix) \(counterparty)"
        let dateLabel = Self.neighbourDateLabel(for: neighbour.row.receivedAt, anchor: centerReceivedAt)
        let purposeLabel = neighbour.row.purpose?.displayLabel ?? "—"
        let briefParts = [directedLabel, dateLabel, purposeLabel].filter { !$0.isEmpty && $0 != "—" }
        let briefText = briefParts.isEmpty ? directedLabel : briefParts.joined(separator: " · ")
        // Override beats stored row when the lock-time pre-warm has just
        // produced a summary; otherwise fall back to whatever the
        // ingestion pipeline cached on the row.
        let override = summaryOverridesByMessageId[neighbour.messageId]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let summary = override
            ?? neighbour.row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        // Route by relation: sent reply-shaped neighbours get their own
        // label and paperplane affordance, same-correspondent neighbours
        // surface as "from same contact", and cross-correspondent
        // neighbours as "from elsewhere."
        let kind: AnnotationKind = {
            if isSentByUser,
               neighbour.relation == .sameCorrespondent,
               Self.isReplySubject(neighbour.row.subject) {
                return .reply
            }
            return neighbour.relation == .sameCorrespondent ? .threadRelative : .topicRelative
        }()
        let contextReason = neighbour.semanticReason?.relationshipLine ?? ""
        return AnnotationItem(
            id: "neighbor:\(neighbour.messageId)",
            kind: kind,
            anchorVectorId: nil,
            anchorMessageId: neighbour.messageId,
            anchorWorld: anchorByMessageId[neighbour.messageId] ?? neighbour.representativeWorld,
            title: neighbour.row.subject.isEmpty ? "(no subject)" : neighbour.row.subject,
            detail: "affinity \(neighbour.bestSimilarity.formatted(.number.precision(.fractionLength(2)))) · rank \(neighbour.rank)",
            briefText: briefText,
            // Affinity / rank are already shown in the header detail line; the chevron-expanded
            // pane is reserved for the email body summary so we don't duplicate header chrome.
            extras: [],
            // Suppress the boilerplate "why: cosine-neighbour message …"
            // line at the bottom of related-email popups — the explicit
            // "from"/"to" prefix in the brief and the affinity in the
            // header already explain the connection without restating it.
            relevance: nil,
            badgeText: "\(kind.badgePrefix) \(neighbour.bestSimilarity.formatted(.number.precision(.fractionLength(2))))",
            importance: neighbourImportance(similarity: neighbour.bestSimilarity, rank: neighbour.rank),
            contextReason: contextReason,
            summary: summary,
            // Sent → outbound paperplane; received → inbound tray. Same
            // vocabulary the trace toggles already use up in the toolbar.
            directionSymbol: isSentByUser ? "paperplane.fill" : "tray.and.arrow.down",
            radialAffinity: Double(neighbour.bestSimilarity),
            badgeSortDate: neighbour.row.receivedAt
        )
    }

    /// Returns the human-readable counterparty for the neighbour. For
    /// received messages this is the sender (display name preferred over
    /// raw address); for sent messages it's the first to-recipient — with
    /// a "+N" suffix when several people were on the to-line.
    private static func counterpartyLabel(row: MessageFilterRow, isSentByUser: Bool) -> String {
        if isSentByUser {
            // Prefer toDisplayNames (which preserves casing the user typed)
            // and fall back to toAddresses for accounts where ingestion
            // didn't capture a display name. Drop empties before counting.
            let names = row.toDisplayNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let addresses = row.toAddresses
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Pair by index; otherwise fall back to whichever list has the entry.
            let primary: String
            if let firstName = names.first, !firstName.isEmpty {
                primary = firstName
            } else if let firstAddress = addresses.first {
                primary = firstAddress
            } else {
                return ""
            }
            let totalCount = max(names.count, addresses.count)
            if totalCount > 1 {
                return "\(primary) +\(totalCount - 1)"
            }
            return primary
        } else {
            let trimmedName = row.fromName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedName.isEmpty {
                return trimmedName
            }
            return row.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func isReplySubject(_ subject: String) -> Bool {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("re:")
    }

    private static func peopleKind(
        row: MessageFilterRow,
        focusedEmail: String
    ) -> AnnotationKind {
        if row.isSentByUser {
            // Sent: discriminate primary To: vs Cc:/Bcc: included so the
            // chip lines up with the matching Saturn ring tier. The To:
            // line is the authoritative "primary recipient" set; anything
            // else (Cc, Bcc) is included alongside.
            let primaryTo = Set(row.toAddresses.map(normalizedEmail))
            let allRecipients = Set(row.recipientAddresses.map(normalizedEmail))
            if primaryTo.contains(focusedEmail) {
                return .peopleReply
            }
            if allRecipients.contains(focusedEmail) {
                return .peopleReplyShared
            }
            // Defensive: a sent row that doesn't mention the focused
            // correspondent on any recipient list is treated as direct —
            // matches the legacy behaviour and avoids dropping the row
            // from the People ring entirely.
            return .peopleReply
        }
        if normalizedEmail(row.fromAddress) == focusedEmail {
            return .peopleInbound
        }
        return .peopleShared
    }

    private static func peopleDirectionText(
        row: MessageFilterRow,
        focusedDisplayName: String,
        focusedEmail: String,
        kind: AnnotationKind
    ) -> String {
        let focusName = focusedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusLabel = focusName.isEmpty || normalizedEmail(focusName) == focusedEmail
            ? focusedEmail
            : focusName
        switch kind {
        case .peopleInbound:
            return "from \(focusLabel)"
        case .peopleReply:
            return "to \(focusLabel)"
        case .peopleReplyShared:
            // User sent with this person on Cc:/Bcc:. Name the primary
            // To: recipient so the user remembers who the message was
            // actually addressed to, then call out the inclusion.
            let primary = counterpartyLabel(row: row, isSentByUser: true)
            return primary.isEmpty ? "including \(focusLabel)" : "to \(primary) · including \(focusLabel)"
        case .peopleShared:
            let sender = counterpartyLabel(row: row, isSentByUser: false)
            return sender.isEmpty ? "including \(focusLabel)" : "from \(sender) · including \(focusLabel)"
        default:
            return ""
        }
    }

    private static func peopleBadgeText(kind: AnnotationKind) -> String {
        switch kind {
        case .peopleInbound:
            return "received"
        case .peopleReply:
            return "sent"
        case .peopleShared:
            return "cc'd"
        case .peopleReplyShared:
            return "sent·cc'd"
        default:
            return kind.badgePrefix
        }
    }

    private static func peopleDirectionSymbol(kind: AnnotationKind) -> String {
        switch kind {
        case .peopleInbound:
            return "tray.and.arrow.down"
        case .peopleReply:
            return "paperplane.fill"
        case .peopleReplyShared:
            return "paperplane"
        case .peopleShared:
            return "person.2.fill"
        default:
            return kind.symbolName
        }
    }

    private static func normalizedEmail(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("mailto:") {
            value.removeFirst("mailto:".count)
        }
        return value
    }

    private func threadImportance(position: Int) -> Double {
        0.70 - min(0.24, Double(abs(position)) * 0.06)
    }

    private func neighbourImportance(similarity: Float, rank: Int) -> Double {
        min(0.94, max(0.45, Double(similarity))) - min(0.12, Double(max(0, rank - 1)) * 0.01)
    }

    private func entityImportance(_ score: Float?) -> Double {
        guard let score else { return 0.54 }
        return min(0.72, max(0.44, Double(score)))
    }

    private func entityBrief(_ chunk: LockedNodeContext.OwnChunk) -> String {
        if let correspondent = chunk.correspondent {
            return "\(correspondent.email) · familiarity \(correspondent.familiarityScore.formatted(.number.precision(.fractionLength(2))))"
        }
        return brief(Self.extractBodyText(from: chunk.textPayload, metadataJSON: chunk.metadataJSON))
    }

    private func brief(_ text: String) -> String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func padded(_ value: Int) -> String {
        value.formatted(.number.precision(.integerLength(2...)).grouping(.never))
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    // MARK: - Pure helpers

    /// Strips the metadata header that `EmbeddingDocumentBuilder.buildContextDocument` prepends
    /// (`FROM:`, `TO:`, `DATE_BUCKET:`, `SUBJECT:`, `ATTACHMENTS:`, `LANGUAGE:`)
    /// and returns just the `BODY:` content. Falls back to a `bodyChunkText` field in the
    /// metadata JSON if present (Phase 2 chunker will write this), then to the full payload
    /// if neither marker is found (legacy data with no recognisable shape).
    nonisolated static func extractBodyText(from payload: String, metadataJSON: String?) -> String {
        if let metadataJSON, !metadataJSON.isEmpty,
           let data = metadataJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bodyChunkText = json["bodyChunkText"] as? String,
           !bodyChunkText.isEmpty {
            return bodyChunkText
        }
        // Locate "BODY:" line and return everything after it. The body block can span multiple
        // lines (chunks pre-flatten newlines), so emit the rest of the document verbatim.
        if let bodyRange = payload.range(of: "\nBODY: ") {
            return String(payload[bodyRange.upperBound...])
        }
        if let leadingBodyRange = payload.range(of: "BODY: "), leadingBodyRange.lowerBound == payload.startIndex {
            return String(payload[leadingBodyRange.upperBound...])
        }
        return payload
    }

    /// Strips attachment-document scaffolding (`ATTACHMENT:` / `ATTACHMENT_TEXT:`) the way
    /// `EmbeddingDocumentBuilder.buildAttachmentDocument` writes it, so attachment popups
    /// don't display "FROM:/TO:/DATE_BUCKET:/ATTACHMENT:/ATTACHMENT_TEXT:" prefixes either.
    nonisolated static func extractAttachmentText(from payload: String) -> String {
        if let textRange = payload.range(of: "\nATTACHMENT_TEXT: ") {
            return String(payload[textRange.upperBound...])
        }
        if let bodyRange = payload.range(of: "\nBODY: ") {
            return String(payload[bodyRange.upperBound...])
        }
        return payload
    }

    private nonisolated static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let endIndex = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            return String(trimmed[..<trimmed.index(after: endIndex)])
        }
        return trimmed
    }

    /// Maps the attachment's persisted extraction state into the popup buckets
    /// the locked overlay reasons about. Mirrors `LockedAttachmentExtractionStatus`
    /// so the FILES list and the orbital popup agree on whether an attachment is
    /// ready to summarize.
    nonisolated static func extractionState(
        attachment: LockedAttachmentSummary,
        concatenatedText: String
    ) -> AnnotationItem.AttachmentReference.ExtractionState {
        if !concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachment.extractedTextPath != nil {
            return .ready
        }
        return LockedAttachmentExtractionStatus
            .classify(attachment)
            .annotationState
    }

    /// Compact tag rendered in the popup's mini badge. Replaces the old
    /// `att 01 / att 02` chunk-index labels with a file-kind tag derived
    /// from the mime type or filename extension.
    nonisolated static func attachmentKindBadge(mimeType: String, filename: String) -> String {
        let mime = mimeType.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || ext == "pdf" { return "pdf" }
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp", "svg"].contains(ext) {
            return "image"
        }
        if mime.hasPrefix("audio/") || ["mp3", "wav", "aiff", "flac", "m4a", "aac", "ogg"].contains(ext) {
            return "audio"
        }
        if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return "video"
        }
        if ["zip", "tar", "gz", "bz2", "7z", "rar", "xz"].contains(ext)
            || mime.contains("zip") || mime.contains("compressed") {
            return "zip"
        }
        if ext == "ics" || mime.contains("calendar") { return "ics" }
        if ["xls", "xlsx", "ods", "numbers", "csv", "tsv"].contains(ext)
            || mime.contains("spreadsheet") || mime.contains("excel") {
            return "xls"
        }
        if ["ppt", "pptx", "odp", "key"].contains(ext)
            || mime.contains("presentation") || mime.contains("powerpoint") {
            return "deck"
        }
        if ["doc", "docx", "rtf", "odt", "pages", "txt", "md"].contains(ext)
            || mime.contains("msword")
            || mime.contains("officedocument.wordprocessing")
            || mime == "text/plain" || mime == "text/markdown" {
            return "doc"
        }
        if ["json", "xml", "yaml", "yml", "html", "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java", "kt", "sh"].contains(ext)
            || mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text/x-") {
            return "code"
        }
        return "file"
    }

    /// Brief copy shown above the chevron when the popup is collapsed. Always
    /// terse — the full summary lives behind the chevron and is generated
    /// by the attachment-summary backfill worker, with `AttachmentSummaryService`
    /// still available as the on-demand fallback on first expand.
    nonisolated static func attachmentBrief(
        attachment: LockedAttachmentSummary,
        extractionState: AnnotationItem.AttachmentReference.ExtractionState,
        concatenatedText: String,
        isImage: Bool,
        extractionStatus: LockedAttachmentExtractionStatus? = nil
    ) -> String {
        // Image attachments use the visual-summary worker output as their
        // collapsed brief — that's the Vision + OCR + Foundation Models
        // paragraph already written to `Attachment.visualSummary`. When the
        // worker hasn't visited yet, leave the brief empty; the expanded
        // pane shows the same loading affordance used by summary generation
        // while on-demand extraction runs.
        if attachment.remoteURL != nil {
            // Mail Drop: no local bytes to describe; show what the file recorded.
            let status = extractionStatus ?? LockedAttachmentExtractionStatus.classify(attachment)
            return attachment.captureLine ?? status.badge?.help ?? ""
        }
        if isImage {
            if let summary = attachment.visualSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return summary
            }
            let status = extractionStatus ?? LockedAttachmentExtractionStatus.classify(attachment)
            switch status.state {
            case .queued(.visual), .ready:
                return ""
            case .waitingForAppleIntelligence:
                return status.badge?.help
                    ?? "Image descriptions require Apple Intelligence. They will appear when it is available."
            case .unsupported:
                return "This image type is not supported for local description."
            case .missingFile:
                return "The saved image is missing, so it cannot be described."
            case .tooLarge:
                return "This image is over the local description size limit."
            case .empty:
                return "No usable text or visual detail was found in this image."
            case .blocked, .failed, .stalled:
                return status.badge?.help ?? "Image description unavailable."
            case .queued(.document), .encrypted, .mailDrop:
                return status.badge?.help ?? "Image description unavailable."
            }
        }
        switch extractionState {
        case .ready:
            // No prompt copy — the chevron itself is the affordance, and a
            // static "click here" line was just visual chaff in a pane that
            // already carries filename, type, and size.
            return ""
        case .extracting:
            return LockedAttachmentExtractionStatus.classify(attachment).badge?.help
                ?? "Attachment extraction is queued."
        case .waitingForAppleIntelligence:
            return LockedAttachmentExtractionStatus.classify(attachment).badge?.help
                ?? "Image descriptions require Apple Intelligence. They will appear when it is available."
        case .unsupported:
            return "Binary contents — no text-based summary available."
        case .unavailable:
            return LockedAttachmentExtractionStatus.classify(attachment).badge?.help
                ?? "Attachment summary unavailable."
        }
    }

    private nonisolated static func byteString(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            let mb = Double(bytes) / 1_048_576
            return "\(mb.formatted(.number.precision(.fractionLength(1))))mb"
        }
        if bytes >= 1024 {
            return "\(bytes / 1024)kb"
        }
        return "\(bytes)b"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// `yyyy-MM-dd HH:mm` followed by a signed parenthetical delta against
    /// the locked anchor. Examples:
    ///   * `2026-04-05 14:34 (+00:30)` — 30 minutes after the anchor
    ///   * `2026-04-05 14:34 (-2d 03:15)` — 2 days 3h 15m before the anchor
    /// Anchor `nil` (locked message has no timestamp) → date-time only, no
    /// parenthetical. Neighbour `nil` (corrupt row) → "—".
    static func neighbourDateLabel(for date: Date?, anchor: Date?) -> String {
        guard let date else { return "—" }
        let stamp = Self.dateTimeFormatter.string(from: date)
        guard let anchor else { return stamp }
        return "\(stamp) (\(formatDelta(seconds: date.timeIntervalSince(anchor))))"
    }

    /// Human-readable elapsed time between a thread sibling and the locked
    /// anchor, formatted for inline use as the leading clause of the
    /// contextReason sentence:
    ///   * `"3 days later"`
    ///   * `"4 hours 12 minutes earlier"`
    ///   * `"45 minutes later"`
    /// Returns `nil` when either timestamp is missing or the gap is under a
    /// minute — callers fall back to the unquantified "Earlier/Later message
    /// in the same conversation." sentence.
    static func threadRelativeTimeLabel(
        sibling: Date?,
        anchor: Date?,
        position: Int
    ) -> String? {
        guard let sibling, let anchor else { return nil }
        let total = Int(abs(sibling.timeIntervalSince(anchor)).rounded())
        guard total >= 60 else { return nil }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        func pluralize(_ n: Int, _ unit: String) -> String {
            "\(n) \(unit)\(n == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if days > 0 {
            parts.append(pluralize(days, "day"))
            if hours > 0 { parts.append(pluralize(hours, "hour")) }
        } else if hours > 0 {
            parts.append(pluralize(hours, "hour"))
            if minutes > 0 { parts.append(pluralize(minutes, "minute")) }
        } else {
            parts.append(pluralize(minutes, "minute"))
        }
        let phrase = parts.joined(separator: " ")
        let direction = position < 0 ? "earlier" : "later"
        return "\(phrase) \(direction)"
    }

    private static func formatDelta(seconds: TimeInterval) -> String {
        let sign = seconds >= 0 ? "+" : "-"
        let total = Int(abs(seconds.rounded()))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let paddedHours = hours.formatted(.number.precision(.integerLength(2...)).grouping(.never))
        let paddedMinutes = minutes.formatted(.number.precision(.integerLength(2...)).grouping(.never))
        if days > 0 {
            return "\(sign)\(days)d \(paddedHours):\(paddedMinutes)"
        }
        return "\(sign)\(paddedHours):\(paddedMinutes)"
    }
}

private extension String {
    /// Returns `self` if it is non-empty, otherwise `nil`. Used so coalescing
    /// chains skip empty intermediate values.
    var nonEmpty: String? { isEmpty ? nil : self }
}
