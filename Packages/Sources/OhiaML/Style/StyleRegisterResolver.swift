// StyleRegisterResolver.swift
// The single style-resolution function shared by drafting, the Composer's
// Style pane, and reconstruction. Styles span accounts and are scoped by
// output language.

import Foundation
import SwiftData
import OhiaCore

/// Which rule chose a draft's starting style.
public enum StyleResolutionReason: String, Sendable, Equatable {
    /// The style the author last chose for this correspondent.
    case lastChoice
    /// The style most of the author's email to this correspondent is in.
    case correspondence
    /// The author's most-used style in the language.
    case habit
}

public struct StyleResolution {
    public let register: StyleRegister
    public let reason: StyleResolutionReason
}

public enum StyleRegisterResolver {

    /// The style a draft starts in, strongest evidence first. The language
    /// is a **hard filter** over the whole chain: a style never steers a
    /// draft in a language it wasn't discovered in. Only an unknown language
    /// leaves the chain unfiltered.
    ///
    /// 1. **Choice** — the style the author last chose, with its sliders
    ///    unchanged, when writing to this correspondent in this language.
    /// 2. **Correspondence** — the style most of the author's sent email to
    ///    this correspondent in this language belongs to (latest wins a tie).
    /// 3. **Habit** — the author's most-used discovered style in the language.
    /// 4. Nil — no style exists for the language yet.
    @MainActor
    public static func resolve(
        correspondentAddress: String?,
        language: String?,
        context: ModelContext
    ) -> StyleRegister? {
        resolution(correspondentAddress: correspondentAddress, language: language, context: context)?.register
    }

    /// `resolve` with the rule that chose the style.
    @MainActor
    public static func resolution(
        correspondentAddress: String?,
        language: String?,
        context: ModelContext
    ) -> StyleResolution? {
        let registers = activeRegisters(context: context).filter { covers($0, language: language) }
        guard !registers.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: registers.map { ($0.id, $0) })
        let languageID = DraftLanguage.familyID(for: language)

        if let address = normalizedAddress(correspondentAddress) {
            if let chosen = lastChosenStyle(correspondent: address, language: languageID, among: byID, context: context) {
                return StyleResolution(register: chosen, reason: .lastChoice)
            }
            var descriptor = FetchDescriptor<TrainingPair>(predicate: #Predicate<TrainingPair> {
                $0.styleEvidenceCorrespondentAddress == address && $0.styleRegisterID != nil
            })
            descriptor.propertiesToFetch = [\.styleRegisterID, \.createdAt]
            let pairs = (try? context.fetch(descriptor)) ?? []
            var tallies: [UUID: (count: Int, latest: Date)] = [:]
            for pair in pairs {
                guard let id = pair.styleRegisterID, byID[id] != nil else { continue }
                let current = tallies[id] ?? (0, .distantPast)
                tallies[id] = (current.count + 1, max(current.latest, pair.createdAt))
            }
            if let best = tallies.max(by: { lhs, rhs in
                lhs.value.count == rhs.value.count ? lhs.value.latest < rhs.value.latest : lhs.value.count < rhs.value.count
            }), let register = byID[best.key] {
                return StyleResolution(register: register, reason: .correspondence)
            }
        }
        return registers.filter { !$0.isUserSavedStyle }.max {
            $0.exemplarCount == $1.exemplarCount ? $0.registerKey > $1.registerKey : $0.exemplarCount < $1.exemplarCount
        }.map { StyleResolution(register: $0, reason: .habit) }
    }

    /// The style of the most recent accepted send to `correspondent` whose
    /// recorded choice named an active style and kept the sliders that style
    /// had when it was chosen. A style's centroid drifts as discovery reruns;
    /// the choice was of the style, not of its axes at that moment.
    @MainActor
    private static func lastChosenStyle(correspondent: String, language: String?,
                                        among registers: [UUID: StyleRegister],
                                        context: ModelContext) -> StyleRegister? {
        var descriptor = FetchDescriptor<StylePreferenceEvent>(
            predicate: #Predicate<StylePreferenceEvent> { $0.correspondentAddress == correspondent },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        for event in (try? context.fetch(descriptor)) ?? [] {
            guard language == nil || DraftLanguage.familyID(for: event.languageID) == language,
                  let snapshot = event.styleControlSnapshot,
                  let id = snapshot.registerID,
                  let register = registers[id],
                  let defaults = snapshot.baseAxes,
                  let effective = snapshot.effectiveAxes,
                  !effective.differs(from: defaults, tolerance: 0.0001) else { continue }
            return register
        }
        return nil
    }

    /// The style for replying to `incomingMessage`. `language` is the output
    /// language: the draft's selection, else the message's resolved language.
    @MainActor
    public static func resolve(
        forIncoming incomingMessage: Message,
        language: String? = nil,
        context: ModelContext
    ) -> StyleRegister? {
        resolution(forIncoming: incomingMessage, language: language, context: context)?.register
    }

    @MainActor
    public static func resolution(
        forIncoming incomingMessage: Message,
        language: String? = nil,
        context: ModelContext
    ) -> StyleResolution? {
        resolution(
            correspondentAddress: incomingMessage.fromAddress,
            language: DraftLanguage.familyID(for: language) ?? DraftLanguage.resolvedID(for: incomingMessage),
            context: context
        )
    }

    /// The style for composing a new email to `recipientAddress`.
    @MainActor
    public static func resolve(
        forComposeRecipient recipientAddress: String,
        language: String? = nil,
        context: ModelContext
    ) -> StyleRegister? {
        resolution(forComposeRecipient: recipientAddress, language: language, context: context)?.register
    }

    @MainActor
    public static func resolution(
        forComposeRecipient recipientAddress: String,
        language: String? = nil,
        context: ModelContext
    ) -> StyleResolution? {
        resolution(correspondentAddress: recipientAddress, language: DraftLanguage.familyID(for: language), context: context)
    }

    /// An explicit selection, only while it is active and covers the draft's
    /// language; a stamped choice never survives a language switch it can't serve.
    @MainActor
    public static func register(withID id: UUID, language: String?, context: ModelContext) -> StyleRegister? {
        let descriptor = FetchDescriptor<StyleRegister>(
            predicate: #Predicate<StyleRegister> { $0.id == id && $0.isActive }
        )
        guard let register = (try? context.fetch(descriptor))?.first,
              covers(register, language: language) else {
            return nil
        }
        return register
    }

    /// Whether a style may steer a draft in `language`. True for an unknown
    /// language (nothing to scope by); otherwise the style must cover it.
    public static func covers(_ register: StyleRegister, language: String?) -> Bool {
        let token = StyleLanguageToken.normalize(DraftLanguage.familyID(for: language))
        guard token != StyleLanguageToken.unknown else { return true }
        return register.languages.contains(token)
    }

    /// Message ids (UUID strings, the `.style` vector key space) of the
    /// user's sent mail written in `language` — the language-pure fallback
    /// pool for style-exemplar retrieval. Mail *known* to be another language
    /// is excluded; mail with no detected language stays eligible. Nil when
    /// the draft language is unknown.
    @MainActor
    public static func sentMessageIDs(inLanguage language: String?, context: ModelContext) -> Set<String>? {
        guard let token = DraftLanguage.familyID(for: language) else { return nil }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.isSentByUser == true }
        )
        // Called per pack build / compose generation — fetch only the two
        // columns the filter needs, not full 100k-scale message objects.
        descriptor.propertiesToFetch = [\.id, \.languageDetected]
        let sent = (try? context.fetch(descriptor)) ?? []
        return Set(sent.compactMap { message in
            let family = DraftLanguage.familyID(for: message.languageDetected)
            return (family == nil || family == token) ? message.id.uuidString : nil
        })
    }

    /// Every active style, most-used first — the pulldown inventory before
    /// language scoping.
    @MainActor
    public static func activeRegisters(context: ModelContext) -> [StyleRegister] {
        let descriptor = FetchDescriptor<StyleRegister>(predicate: #Predicate<StyleRegister> { $0.isActive })
        return ((try? context.fetch(descriptor)) ?? []).sorted(by: inventoryOrder)
    }

    /// Every style, including retired and user-deleted rows. The Composer
    /// uses this only to preserve historical draft provenance; resolution
    /// and the pulldown remain active-only.
    @MainActor
    public static func allRegisters(context: ModelContext) -> [StyleRegister] {
        ((try? context.fetch(FetchDescriptor<StyleRegister>())) ?? []).sorted(by: inventoryOrder)
    }

    private static func inventoryOrder(_ lhs: StyleRegister, _ rhs: StyleRegister) -> Bool {
        if lhs.exemplarCount != rhs.exemplarCount { return lhs.exemplarCount > rhs.exemplarCount }
        return lhs.registerKey < rhs.registerKey
    }

    /// Message ids (UUID strings, the `.style` vector key space) of trained
    /// sent emails belonging to the style — the exemplar restriction set for
    /// style retrieval.
    @MainActor
    public static func memberMessageIDs(forRegisterID id: UUID, context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<TrainingPair>(
            predicate: #Predicate<TrainingPair> { $0.styleRegisterID == id }
        )
        let pairs = (try? context.fetch(descriptor)) ?? []
        return Set(pairs.compactMap { pair -> String? in
            if let evidence = pair.evidence, evidence.disposition != .loraEligible { return nil }
            return pair.message?.id.uuidString
        })
    }

    /// Sendable prompt/UI snapshot of a style.
    public static func note(from register: StyleRegister) -> StyleRegisterNote {
        StyleRegisterNote(
            id: register.id,
            name: register.name,
            summary: register.summary,
            axes: register.styleAxes,
            revision: register.revision
        )
    }

    private static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Canonical token stored in `StyleRegister.languages`.
public enum StyleLanguageToken {
    public static let unknown = "unknown"

    /// Lowercased, whitespace-trimmed token; `unknown` for nil/empty.
    public static func normalize(_ raw: String?) -> String {
        guard let raw else { return unknown }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? unknown : cleaned
    }
}
