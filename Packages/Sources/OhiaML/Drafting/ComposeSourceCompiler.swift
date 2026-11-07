import Foundation
import SwiftData
import OhiaCore

/// Compiles the automatic evidence set for a brand-new outbound email
/// (a `.userCompose` draft) before the model writes it. The reply pipeline's
/// `ComposerSourceCompiler` keys everything off the *incoming* message; a
/// compose has no incoming message, so this keys off the chosen **recipient**:
/// the user's past replies to that address, recent messages received from
/// them, and the recipient/account memory dossiers.
///
/// Deliberately embedding-free — it runs inside the generative worker's
/// `.generateDraft` intake, where the BGE model is never loaded. Everything
/// here comes from SwiftData fetches and canonical body-text files.
///
/// `@MainActor` overall because `memorySources` calls into the
/// `@MainActor`-pinned memory-dreaming lookup (`AccountMemoryDraftSelector`).
/// `correspondenceSources` below is the one deliberately `nonisolated`
/// exception: received mail and past replies are the two kinds whose
/// snippets now come from full, uncapped body-text file reads (no fixed
/// character truncation), so `ComposeState`'s foreground seed path runs
/// that specific compile on a detached task instead of blocking the button
/// tap that triggers it.
@MainActor
public enum ComposeSourceCompiler {

    public struct Limits: Sendable {
        public var pastReplies = 3
        public var receivedFromRecipient = 2
        public var memoryNotes = 5
        /// An outer relevance/cost ceiling on how far back a Messages
        /// transcript reaches — not a prompt-size control. `ComposerContextPacker`
        /// is the actual size arbiter; these two exist only because pulling in
        /// someone's entire multi-year chat history regardless of budget is
        /// never useful and would slow the chat.db query for no benefit.
        /// Matches `SourceMessagesPickerSheet`'s own Stepper ceiling.
        public var messages = 200
        public var messagesMaxAgeDays = 365
        /// Newest-first scan ceiling for the sent-mail fetch backing the
        /// past-replies lookup — bounds the work on 100k-message stores.
        public var sentScanLimit = 400

        public init() {}
        public static let `default` = Limits()
    }

    /// Returns automatic sources for a compose to `recipientAddress`,
    /// newest-relevant first within each kind. Never throws — a missing body
    /// file or no prior correspondence just yields fewer sources.
    public static func compile(
        accountID: UUID?,
        recipientAddress: String,
        context: ModelContext,
        limits: Limits = .default,
        messagesEnabled: Bool = ComposerSourceProviderPreference.isEnabled(.messages),
        embedder: (any EmbeddingProvider)? = nil,
        messagesProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        draftID: UUID
    ) async -> [ComposerSource] {
        let recipient = recipientAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !recipient.isEmpty else {
            return memorySources(accountID: accountID, recipientAddress: "", context: context, limits: limits, embedder: embedder)
        }

        var sources: [ComposerSource] = []
        sources.append(contentsOf: receivedSources(
            recipient: recipient,
            accountID: accountID,
            context: context,
            limits: limits
        ))
        sources.append(contentsOf: pastReplySources(
            recipient: recipient,
            accountID: accountID,
            context: context,
            limits: limits
        ))
        sources.append(contentsOf: memorySources(accountID: accountID, recipientAddress: recipient, context: context, limits: limits, embedder: embedder))
        if messagesEnabled {
            sources.append(contentsOf: await messagesSources(
                recipient: recipient,
                limits: limits,
                provider: messagesProvider,
                draftID: draftID
            ))
        }
        return sources
    }

    /// Merges a fresh automatic compilation into an existing persisted list,
    /// preserving every user-added source and the user's ordering of them.
    public static func mergingAutomaticSources(
        into existing: [ComposerSource],
        accountID: UUID?,
        recipientAddress: String,
        context: ModelContext,
        limits: Limits = .default,
        messagesEnabled: Bool = ComposerSourceProviderPreference.isEnabled(.messages),
        embedder: (any EmbeddingProvider)? = nil,
        messagesProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        draftID: UUID
    ) async -> [ComposerSource] {
        let userAdded = existing.filter(\.isUserAdded)
        return await compile(
            accountID: accountID,
            recipientAddress: recipientAddress,
            context: context,
            limits: limits,
            messagesEnabled: messagesEnabled,
            embedder: embedder,
            messagesProvider: messagesProvider,
            draftID: draftID
        ) + userAdded
    }

    /// The disk-I/O-bound half of `compile`: received mail and past
    /// replies, the two kinds whose snippets are full (uncapped) message
    /// bodies read from disk via `bodySnippet`. `nonisolated` — unlike
    /// `compile` itself — specifically so `ComposeState` can run this on a
    /// detached task against a background `ModelContext` instead of
    /// blocking a button tap on file I/O. Excludes memory notes (their
    /// lookup is `@MainActor`-pinned) and Messages (its broker/XPC work is
    /// separately gated by the caller); both are folded back in by
    /// the authoritative `compile` pass that always follows.
    public nonisolated static func correspondenceSources(
        recipientAddress: String,
        accountID: UUID?,
        context: ModelContext,
        limits: Limits = .default
    ) -> [ComposerSource] {
        let recipient = recipientAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !recipient.isEmpty else { return [] }
        return receivedSources(recipient: recipient, accountID: accountID, context: context, limits: limits)
            + pastReplySources(recipient: recipient, accountID: accountID, context: context, limits: limits)
    }

    // MARK: - Recent messages received from the recipient

    private nonisolated static func receivedSources(
        recipient: String,
        accountID: UUID?,
        context: ModelContext,
        limits: Limits
    ) -> [ComposerSource] {
        // `fromAddress` is lowercased at ingestion, so an equality predicate
        // is case-safe and lets SQLite bound the fetch instead of scanning
        // the whole store.
        let predicate: Predicate<Message>
        if let accountID {
            predicate = #Predicate<Message> { msg in
                msg.fromAddress == recipient
                    && msg.isSentByUser == false
                    && msg.accountID == accountID
                    && msg.trashedAt == nil
            }
        } else {
            predicate = #Predicate<Message> { msg in
                msg.fromAddress == recipient && msg.isSentByUser == false && msg.trashedAt == nil
            }
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\Message.receivedAt, order: .reverse),
                SortDescriptor(\Message.ingestedAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limits.receivedFromRecipient
        let received = (try? context.fetch(descriptor)) ?? []
        return received.compactMap { msg in
            guard let snippet = bodySnippet(of: msg) else { return nil }
            return ComposerSource(
                kind: .thread,
                label: "\(msg.fromName ?? msg.fromAddress) wrote · \(subjectLabel(msg)) · \(dateLabel(for: msg))",
                snippet: snippet,
                messageID: msg.id
            )
        }
    }

    // MARK: - The user's past replies to this recipient

    private nonisolated static func pastReplySources(
        recipient: String,
        accountID: UUID?,
        context: ModelContext,
        limits: Limits
    ) -> [ComposerSource] {
        let predicate: Predicate<Message>
        if let accountID {
            predicate = #Predicate<Message> { msg in
                msg.isSentByUser == true && msg.accountID == accountID && msg.trashedAt == nil
            }
        } else {
            predicate = #Predicate<Message> { msg in
                msg.isSentByUser == true && msg.trashedAt == nil
            }
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\Message.sentAt, order: .reverse),
                SortDescriptor(\Message.ingestedAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limits.sentScanLimit
        let sent = (try? context.fetch(descriptor)) ?? []

        var replies: [ComposerSource] = []
        for candidate in sent {
            guard replies.count < limits.pastReplies else { break }
            guard isAddressed(candidate, to: recipient) else { continue }
            guard let snippet = bodySnippet(of: candidate) else { continue }
            replies.append(ComposerSource(
                kind: .pastReply,
                label: "you → \(recipient) · \(subjectLabel(candidate)) · \(dateLabel(for: candidate))",
                snippet: snippet,
                messageID: candidate.id
            ))
        }
        return replies
    }

    private nonisolated static func isAddressed(_ sent: Message, to recipient: String) -> Bool {
        sent.participants.contains { link in
            guard link.role == .to || link.role == .cc else { return false }
            return link.participant?.emailAddress.lowercased() == recipient
        }
    }

    /// Counts how many of the user's sent messages were addressed to the
    /// recipient — the per-correspondent training basis surfaced in the
    /// Composer's personalization strip for a compose. Bounded scan, same
    /// address match as `pastReplySources`.
    public static func recipientReplyCount(
        recipientAddress: String,
        context: ModelContext,
        scanLimit: Int = 3000
    ) -> Int {
        let recipient = recipientAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !recipient.isEmpty else { return 0 }

        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                msg.isSentByUser == true && msg.trashedAt == nil
            },
            sortBy: [
                SortDescriptor(\Message.sentAt, order: .reverse),
                SortDescriptor(\Message.ingestedAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = scanLimit
        let sent = (try? context.fetch(descriptor)) ?? []
        return sent.reduce(0) { count, candidate in
            isAddressed(candidate, to: recipient) ? count + 1 : count
        }
    }

    // MARK: - Messages

    /// Resolves `recipient` through Contacts to a 1:1 Messages chat and, if
    /// one exists, compiles its recent transcript as a single source. Silent
    /// when Full Disk Access or Contacts access is unavailable, the
    /// recipient doesn't resolve to a contact, or no matching chat has an
    /// eligible message in the window.
    ///
    /// The transcript is handed to `ComposerContextPacker` at its full
    /// (relevance-window-bounded) length, not pre-cut to a fixed character
    /// count — see the matching note on the reply path's `messagesSources`
    /// in `ComposerSourceCompiler.swift`.
    private static func messagesSources(
        recipient: String,
        limits: Limits,
        provider: any MessagesTranscriptProviding,
        draftID: UUID
    ) async -> [ComposerSource] {
        guard limits.messages > 0 else { return [] }
        let request = AutomaticMessagesRequest(
            context: .compose(draftID: draftID),
            correspondentAddress: recipient,
            limit: limits.messages,
            maxAge: TimeInterval(limits.messagesMaxAgeDays) * 24 * 60 * 60
        )
        return await provider.transcript(for: request)
            .composerSource()
            .map { [$0] } ?? []
    }

    // MARK: - Memory notes

    private static func memorySources(
        accountID: UUID?,
        recipientAddress: String,
        context: ModelContext,
        limits: Limits,
        embedder: (any EmbeddingProvider)? = nil
    ) -> [ComposerSource] {
        AccountMemoryDraftSelector.memoryNotesForCompose(
            accountID: accountID,
            recipientAddress: recipientAddress,
            context: context,
            embedder: embedder
        )
        .prefix(limits.memoryNotes)
        .map { note in
            // The interview's known-context digest renders memory through the
            // shared helper so its reliability tags read identically to the
            // draft prompts. The label stays the dimension label the Composer
            // UI shows; only the prompt-facing snippet carries the tags.
            ComposerSource(kind: .memory, label: note.dimensionLabel, snippet: MemoryNoteRendering.line(for: note),
                memoryUsePolicy: note.usePolicyRaw)
        }
    }

    // MARK: - Correspondent profile lookup (for the prompt header)

    /// Resolves the recipient's display name + correspondent profile, when the
    /// address is known from prior correspondence. Returns the raw address as
    /// the name when no `Correspondent` row exists yet.
    public static func recipientNameAndProfile(
        recipientAddress: String,
        context: ModelContext
    ) -> (name: String, profile: CorrespondentProfile?) {
        let recipient = recipientAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !recipient.isEmpty else { return (recipientAddress, nil) }

        var descriptor = FetchDescriptor<Correspondent>(
            predicate: #Predicate<Correspondent> { $0.primaryEmail == recipient }
        )
        descriptor.fetchLimit = 1
        guard let row = (try? context.fetch(descriptor))?.first else {
            return (recipientAddress, nil)
        }
        let name = row.primaryName.isEmpty ? recipientAddress : row.primaryName
        let profile: CorrespondentProfile?
        if let json = row.profileJSON, let data = json.data(using: .utf8) {
            profile = try? JSONDecoder().decode(CorrespondentProfile.self, from: data)
        } else {
            profile = nil
        }
        return (name, profile)
    }

    // MARK: - Helpers

    /// Strips quoted history/signature boilerplate via the same
    /// `OriginalMessageText` cleaning the reply path's `selectedBodySnippet`
    /// applies, then hands the full cleaned body to `ComposerContextPacker`
    /// uncut — removing the old fixed-character cap without this cleaning
    /// step would let raw quoted-reply chains flood the token budget instead
    /// of fixing it. Unlike `selectedBodySnippet`, this doesn't also run the
    /// result through `ComposerPassageSelector` for anchor-relevant excerpt
    /// selection — a compose-from-scratch recipient lookup has no anchor
    /// terms at this call site (no incoming message to derive them from).
    /// The packer still applies its own anchor-term clipping later if the
    /// source doesn't fit, using the brief/subject/recipient-derived terms
    /// `QuestionGroundingContextPacking.compose` computes.
    private nonisolated static func bodySnippet(of message: Message) -> String? {
        guard let path = message.bodyTextPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let cleaned = OriginalMessageText.cleaned(from: text) else {
            return nil
        }
        let snippet = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    private nonisolated static func subjectLabel(_ message: Message) -> String {
        message.subject.isEmpty ? "(no subject)" : message.subject
    }

    /// A fresh formatter per call, deliberately not a shared `static let`:
    /// `receivedSources`/`pastReplySources` are `nonisolated` so
    /// `correspondenceSources` can run them from a detached task, and
    /// `DateFormatter` isn't `Sendable` — a shared instance would be mutable
    /// state reachable from both that task and the `@MainActor` `compile`
    /// path at once. Called at most a handful of times per compile, so the
    /// construction cost is immaterial.
    private nonisolated static func dateLabel(for message: Message) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = message.receivedAt ?? message.sentAt ?? message.ingestedAt
        return formatter.string(from: date)
    }
}
