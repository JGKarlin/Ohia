import CryptoKit
import Foundation
import OhiaCore

/// What makes the content the writer always keeps too long for its window,
/// so the author is told the cause they can act on.
public enum ComposerWriterWindowOverflow: String, Codable, Sendable, Equatable {
    /// The incoming email itself, with nothing else: nothing can be removed.
    case incomingMessage
    /// Sources the author added, or that settled a question (all listed in
    /// Sources).
    case sources
    /// Saved memory for the conversation.
    case memory
    /// The author's instructions and answers.
    case instructions
    /// The current draft a revision rewrites.
    case currentDraft
}

public enum ComposerContentError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidBrief(String)
    case invalidAudit(String)
    case incomplete(String)
    case rejected(String)
    case budgetExceeded
    /// The parts of the writer prompt that are never left out (the incoming
    /// message, instructions, sources the author added, memory and sources
    /// behind settled questions) leave the writer less
    /// than its minimum completion; the payload names the largest cause.
    /// Terminal: the same request cannot fit on retry.
    case writerWindowExceeded(ComposerWriterWindowOverflow)
    /// The incoming email has text but none of its own (only quoted or
    /// forwarded mail), so the writer would reply to nothing. Terminal.
    case incomingHasNoOriginalText
    case deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason), .invalidBrief(let reason), .invalidAudit(let reason),
             .incomplete(let reason), .rejected(let reason): reason
        case .budgetExceeded: "The required draft content exceeds the model's complete-sequence budget."
        case .writerWindowExceeded(let cause):
            switch cause {
            case .incomingMessage:
                "This email is too long for the local drafting model to read in full, so it cannot draft a reply. Please write this reply yourself."
            case .sources:
                "The sources this draft must keep, the ones you added and the ones your answers rely on, leave the drafting model no room to write. Remove one of them in Sources."
            case .memory:
                "Saved memories for this conversation leave the drafting model no room to write. Delete the ones you do not need in Settings, Memories."
            case .instructions:
                "Your instructions and answers leave the drafting model no room to write. Shorten them."
            case .currentDraft:
                "Your edits to this draft leave the drafting model no room to write. Shorten them, or send the draft as you edited it."
            }
        case .incomingHasNoOriginalText:
            "This email has no text of its own, only quoted or forwarded mail, so there is nothing for the drafting model to reply to. Please write this reply yourself."
        case .deadlineExceeded: "Draft generation exceeded its time budget. Your text and instructions are preserved."
        }
    }

    /// The failure class without any user or model text, safe for release logs.
    public var kind: String {
        switch self {
        case .invalidRequest: "invalidRequest"
        case .invalidBrief: "invalidBrief"
        case .invalidAudit: "invalidAudit"
        case .incomplete: "incomplete"
        case .rejected: "rejected"
        case .budgetExceeded: "budgetExceeded"
        case .writerWindowExceeded: "writerWindowExceeded"
        case .incomingHasNoOriginalText: "incomingHasNoOriginalText"
        case .deadlineExceeded: "deadlineExceeded"
        }
    }
}

public struct ComposerRequirement: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        case interviewAnswer, draftGuidance, revisionInstruction, manualEdit
        /// A neutral content unit reconstructed from a historical sent email
        /// for training. Never an instruction the user typed.
        case reconstructed
    }
    public var id: String
    public var origin: Origin
    public var sequence: Int
    public var originalText: String
    public var questionText: String?
}

/// Who a piece of evidence belongs to. The application decides this from
/// account identities and message direction; no model infers it. The author's
/// own earlier messages are history the current instructions override, never
/// a source of the author's current position.
public enum ComposerEvidenceRole: String, Codable, Sendable, Equatable {
    case incoming
    case correspondent
    case authorPrior
    case external

    public var displayLabel: String {
        switch self {
        case .incoming: "incoming message"
        case .correspondent: "correspondent's earlier message"
        case .authorPrior: "author's earlier message"
        case .external: "external source"
        }
    }
}

public struct ComposerEvidence: Codable, Sendable, Equatable {
    public var source: ComposerSource
    public var role: ComposerEvidenceRole
    public var authorAddress: String?
    public var authorDisplayName: String?
    public var authoredAt: Date?
    public var exactText: String
    public var contentDigest: String
    /// Who the stored email behind a source went to (To and Cc, lowercased):
    /// the check reads whether the author already told these recipients
    /// something. Nil for a source with no stored email, and in requests
    /// saved before it was recorded.
    public var recipientAddresses: [String]?

    public init(source: ComposerSource, role: ComposerEvidenceRole, authorAddress: String?,
                authorDisplayName: String? = nil, authoredAt: Date?, exactText: String,
                recipientAddresses: [String]? = nil) {
        self.source = source
        self.role = role
        self.authorAddress = authorAddress
        self.authorDisplayName = authorDisplayName
        self.authoredAt = authoredAt
        self.exactText = exactText
        self.contentDigest = ComposerContentCoding.digest(Data(exactText.utf8))
        self.recipientAddresses = recipientAddresses
    }

    /// The text the pipeline indexes into passages: mechanically attached
    /// history, signature blocks, salutations and sign-offs carry no content
    /// and would only be noise for selection and checking.
    public var passageText: String {
        switch source.kind {
        case .thread, .email, .pastReply, .retrieved, .messages:
            let cleaned = ComposerBoilerplate.strip(exactText)
            return cleaned.isEmpty ? exactText : cleaned
        default:
            return exactText
        }
    }

    public var isSelectableEvidence: Bool {
        source.kind != .memory || source.memoryUsePolicy == AccountMemoryUsePolicy.assertableKnowledge
    }

    /// Compiled conversations keep a representative message ID for navigation,
    /// but its sender does not own every message in the combined excerpt.
    /// The compiler's explicit speaker/date headings govern those passages.
    func attribution(authorName: String) -> (role: String, speaker: String?) {
        let firstLine = exactText.split(separator: "\n", omittingEmptySubsequences: true).first
        if role != .incoming,
           [.thread, .retrieved, .pastReply, .email].contains(source.kind),
           firstLine?.range(of: " wrote · ") != nil {
            return ("earlier conversation; use each message's speaker and date heading; you wrote identifies the reply author", nil)
        }
        return (role.displayLabel, role == .authorPrior ? authorName : authorDisplayName ?? authorAddress)
    }
}

public struct ComposerManualEdit: Codable, Sendable, Equatable {
    public var baseRevisionID: UUID?
    public var original: String
    public var replacement: String
    public var occurrence: Int
    /// Order in the same frozen authority history as ComposerRequirement.sequence.
    /// Unknown ordering cannot justify superseding either decision.
    public var sequence: Int? = nil
    /// Character offset in the captured base, including for zero-width insertions.
    public var baseCharacterOffset: Int? = nil
    /// Surrounding sentences locate the change; only original/replacement are
    /// user edits. Unchanged context must never acquire instruction authority.
    public var contextBefore: String? = nil
    public var contextAfter: String? = nil
    /// Character offset of `replacement` within `contextAfter`, so the
    /// replacement is read at the spot the author changed and not at an
    /// earlier copy of the same characters ("ed" inside "requested").
    public var contextAfterOffset: Int? = nil
    /// The immutable author-edit snapshot, separate from the body it changed.
    /// Generated rewrites retain this identity and time; they do not turn the
    /// edit into a new decision or erase it from the next generation request.
    public var authoredRevisionID: UUID? = nil
    public var authoredAt: Date? = nil
}

/// The same original-author decision inventory is rendered for preparation,
/// writing and checking. Context locates a manual change; it is not itself an
/// instruction. Unknown chronology cannot justify replacing another decision.
struct ComposerAuthorDecision: Encodable, Sendable {
    struct Change: Encodable, Sendable {
        var removed: String
        var replacement: String
        var contextBefore: String?
        var replacementInContext: String
    }
    var id: String
    var sequence: Int?
    var instruction: String?
    var question: String?
    var manualChange: Change?
}

public struct ComposerContentInput: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case reply, compose }
    public var mode: Mode
    public var identityAddress: String
    public var authorDisplayName: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var languageID: String
    public var subject: String
    public var anchor: ComposerEvidence?
    public var requirements: [ComposerRequirement]
    public var unknowns: [String]
    public var evidence: [ComposerEvidence]
    public var manualEdits: [ComposerManualEdit]
    /// Learned drafting rules (distilled from the user's edits and answers).
    /// Writing directions, never content to express or check.
    public var rules: [String]
    /// What the current reply plan read as asked of the author (exact,
    /// app-quoted): every request of the email being answered that it found,
    /// and the earlier passages it found answering them. The check reads
    /// saying one of those again as answering it, not as repetition; the
    /// writer never sees them, and a redraw reads only whether the plan
    /// found any (`ComposerWriterPrompt.retrying`). Nil when no current plan
    /// read the email: the check then judges no sentence a repetition of the
    /// author's mail.
    public var replyPlanTexts: [String]?
    /// What each sentence of the email being answered asks of the author, as
    /// the current reply plan read it (`ComposerIncomingReading`). A redraw
    /// reads whether it asks anything; nil when it was not read.
    public var incomingReading: ComposerIncomingReading?

    public init(mode: Mode, identityAddress: String, authorDisplayName: String?, to: [String], cc: [String],
                bcc: [String], languageID: String, subject: String, anchor: ComposerEvidence?,
                requirements: [ComposerRequirement], unknowns: [String], evidence: [ComposerEvidence],
                manualEdits: [ComposerManualEdit], rules: [String] = [], replyPlanTexts: [String]? = nil,
                incomingReading: ComposerIncomingReading? = nil) {
        self.mode = mode
        self.identityAddress = identityAddress
        self.authorDisplayName = authorDisplayName
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.languageID = languageID
        self.subject = subject
        self.anchor = anchor
        self.requirements = requirements
        self.unknowns = unknowns
        self.evidence = evidence
        self.manualEdits = manualEdits
        self.rules = rules
        self.replyPlanTexts = replyPlanTexts
        self.incomingReading = incomingReading
    }

    private enum CodingKeys: String, CodingKey {
        case mode, identityAddress, authorDisplayName, to, cc, bcc, languageID, subject, anchor
        case requirements, unknowns, evidence, manualEdits, rules, replyPlanTexts, incomingReading
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        identityAddress = try container.decode(String.self, forKey: .identityAddress)
        authorDisplayName = try container.decodeIfPresent(String.self, forKey: .authorDisplayName)
        to = try container.decode([String].self, forKey: .to)
        cc = try container.decode([String].self, forKey: .cc)
        bcc = try container.decode([String].self, forKey: .bcc)
        languageID = try container.decode(String.self, forKey: .languageID)
        subject = try container.decode(String.self, forKey: .subject)
        anchor = try container.decodeIfPresent(ComposerEvidence.self, forKey: .anchor)
        requirements = try container.decode([ComposerRequirement].self, forKey: .requirements)
        unknowns = try container.decode([String].self, forKey: .unknowns)
        evidence = try container.decode([ComposerEvidence].self, forKey: .evidence)
        manualEdits = try container.decode([ComposerManualEdit].self, forKey: .manualEdits)
        // Bases written before the writer stopped receiving source findings
        // carry a `preparedReplyContext` key; it is ignored.
        rules = try container.decodeIfPresent([String].self, forKey: .rules) ?? []
        replyPlanTexts = try container.decodeIfPresent([String].self, forKey: .replyPlanTexts)
        incomingReading = try container.decodeIfPresent(ComposerIncomingReading.self, forKey: .incomingReading)
    }

    public var allEvidence: [ComposerEvidence] { (anchor.map { [$0] } ?? []) + evidence }

    var authorHistory: [ComposerAuthorDecision] {
        let typed = requirements.map {
            ComposerAuthorDecision(id: $0.id, sequence: $0.sequence,
                instruction: $0.originalText, question: $0.questionText)
        }
        let manual = manualEdits.enumerated().map { index, edit in
            ComposerAuthorDecision(id: "M\(index + 1)", sequence: edit.sequence,
                manualChange: .init(removed: edit.original, replacement: edit.replacement,
                    contextBefore: edit.contextBefore, replacementInContext: edit.anchoredReplacement))
        }
        return (typed + manual).sorted {
            let left = $0.sequence ?? .max, right = $1.sequence ?? .max
            return left == right ? $0.id < $1.id : left < right
        }
    }

    func isLaterAuthorDecision(_ replacingID: String, than replacedID: String) -> Bool {
        let history = authorHistory
        guard let replacing = history.first(where: { $0.id == replacingID })?.sequence,
              let replaced = history.first(where: { $0.id == replacedID })?.sequence else { return false }
        return replacing > replaced
    }

    /// How the writer and the check name the author.
    public var authorName: String {
        if let authorDisplayName, !authorDisplayName.isEmpty { return authorDisplayName }
        return identityAddress.isEmpty ? "the author" : identityAddress
    }

    public func validate() throws {
        guard !languageID.isEmpty,
              Set(requirements.map(\.id)).count == requirements.count,
              Set(authorHistory.map(\.id)).count == authorHistory.count,
              requirements.allSatisfy({ !$0.id.isEmpty && !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(allEvidence.map { $0.source.id }).count == allEvidence.count,
              allEvidence.allSatisfy({ !$0.exactText.isEmpty && $0.contentDigest == ComposerContentCoding.digest(Data($0.exactText.utf8)) }) else {
            throw ComposerContentError.invalidRequest("The drafting request has missing or inconsistent source and instruction provenance.")
        }
    }
}

public struct ComposerPresentationInput: Codable, Sendable, Equatable {
    public var registerID: UUID?
    public var registerName: String?
    public var registerRevision: Int?
    public var controls: StyleControlSnapshot?
    /// The Length the draft had when a pending slider decision moved it: a
    /// rewrite for a longer Length must come back longer, for a shorter one
    /// shorter.
    public var previousLengthPoint: Int? = nil

    public var lengthPoint: Int? {
        controls?.effectiveAxes.map { Self.lengthPoint($0.detail) }
    }

    static func lengthPoint(_ detail: Double) -> Int { Int((detail * 9).rounded()) + 1 }
}

/// Value snapshot: no SwiftData object or editor reference crosses generation awaits.
public struct ComposerGenerationRequest: Codable, Sendable, Equatable {
    public var content: ComposerContentInput
    public var presentation: ComposerPresentationInput
    public var currentBody: String?
    /// The generated revision the editor text derived from when this request
    /// was compiled: the base its manual edits are measured against and the
    /// pass's input. It never identifies the pass's output; the revision that
    /// carries a basis is that output, and `Draft.baseRevisionID` records
    /// which revision the live body derives from.
    public var displayedRevisionID: UUID?
    public var requestID: UUID
    /// Sentences of earlier answers the author kept that the email being
    /// answered shows done (a request the sender has since carried out), as
    /// the done check read them: owed no more. Nil before that check, or
    /// when it could not be read: then every part is owed.
    public var doneEarlierRequests: [String]? = nil

    public var contentIdentity: String { get throws { try ComposerContentIdentity.value(for: content) } }
    public var presentationIdentity: String { get throws { try ComposerPresentationIdentity.value(for: presentation) } }
}

/// Exactly what produced a generated body: the frozen request, the brief the
/// writer saw and the writer task version. Persisted with the revision that
/// carries the body, copied onto the outbox item when the user sends, and
/// reused (after content-identity validation) when only presentation changes.
public struct ComposerGenerationBasis: Codable, Sendable, Equatable {
    public var request: ComposerGenerationRequest
    public var brief: ComposerContentBrief
    public var writerTask: String
    public var personalization: GenerationPersonalization?
    public var diagnostics: GenerationDiagnostics?
    public var trainingReconstructionVersion: Int?
    /// What the draft check found and what the repair did. Absent in bases
    /// written before drafts were checked.
    public var check: ComposerDraftCheckRecord?

    public init(request: ComposerGenerationRequest, brief: ComposerContentBrief, writerTask: String,
                personalization: GenerationPersonalization? = nil, diagnostics: GenerationDiagnostics? = nil,
                trainingReconstructionVersion: Int? = nil, check: ComposerDraftCheckRecord? = nil) {
        self.request = request
        self.brief = brief
        self.writerTask = writerTask
        self.personalization = personalization
        self.diagnostics = diagnostics
        self.trainingReconstructionVersion = trainingReconstructionVersion
        self.check = check
    }

    public var json: String {
        get throws { try ComposerContentCoding.string(self) }
    }

    /// A stored basis that no longer decodes is a cache miss, never an error:
    /// the request that needs it is prepared afresh.
    public static func decode(_ json: String?) -> ComposerGenerationBasis? {
        guard let json else { return nil }
        return try? ComposerContentCoding.decode(ComposerGenerationBasis.self, from: json)
    }
}

public enum ComposerContentIdentity {
    public static func value(for input: ComposerContentInput) throws -> String {
        // Selection timestamps are UI bookkeeping, not evidence revisions. All
        // exact text, authorship, source provenance and ordered requirements remain.
        var normalized = input
        // Output language is presentation: translating a reply reuses its
        // evidence, answers and intent rather than re-interviewing the author.
        normalized.languageID = ""
        // The reply plan's texts steer only the check's reading of a
        // restatement and a redraw's note; the brief never reads them.
        normalized.replyPlanTexts = nil
        // The reading of the email is the plan's, like its texts.
        normalized.incomingReading = nil
        normalized.evidence = input.evidence.map(normalize)
        normalized.anchor = input.anchor.map(normalize)
        return ComposerContentCoding.digest(try ComposerContentCoding.encode(normalized))
    }

    private static func normalize(_ item: ComposerEvidence) -> ComposerEvidence {
        var result = item
        // A stored email's recipients are fixed by the email the source
        // already names, so they add nothing to its identity.
        result.recipientAddresses = nil
        let source = item.source
        result.source = ComposerSource(id: source.id, kind: source.kind, label: source.label,
            snippet: source.snippet, messageID: source.messageID, filePath: source.filePath,
            transcriptMessageCount: source.transcriptMessageCount, isUserAdded: source.isUserAdded,
            addedAt: Date(timeIntervalSince1970: 0), provenance: source.provenance,
            memoryUsePolicy: source.memoryUsePolicy, authoredByUser: source.authoredByUser,
            authoredAt: source.authoredAt)
        return result
    }
}

/// Text folding used wherever the pipeline asks "does this text contain that
/// fragment": case, all whitespace (including ideographic space), width and
/// typographic quotes are ignored so a model's copy of a fragment still matches.
public enum ComposerContentText {
    public static func folded(_ text: String) -> String {
        let width = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        var result = ""
        result.reserveCapacity(width.count)
        for character in width.lowercased() {
            if character.isWhitespace || character.isNewline { continue }
            switch character {
            case "‘", "’", "‚", "`", "´": result.append("'")
            case "“", "”", "„": result.append("\"")
            case "–", "—", "‐", "‑": result.append("-")
            default: result.append(character)
            }
        }
        return result
    }

    public static func contains(_ text: String, fragment: String) -> Bool {
        let needle = folded(fragment)
        guard !needle.isEmpty else { return false }
        return folded(text).contains(needle)
    }

    /// The same folding with word boundaries kept: every whitespace run
    /// becomes one space, so a common span can be read word by word.
    public static func foldedKeepingSpaces(_ text: String) -> String {
        let width = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        var result = ""
        result.reserveCapacity(width.count)
        var pendingSpace = false
        for character in width.lowercased() {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace { result.append(" "); pendingSpace = false }
            switch character {
            case "‘", "’", "‚", "`", "´": result.append("'")
            case "“", "”", "„": result.append("\"")
            case "–", "—", "‐", "‑": result.append("-")
            default: result.append(character)
            }
        }
        return result
    }

    /// Non-overlapping folded occurrences of `fragment` in `text`.
    public static func occurrences(of fragment: String, in text: String) -> Int {
        let needle = folded(fragment)
        guard !needle.isEmpty else { return 0 }
        return folded(text).components(separatedBy: needle).count - 1
    }
}

/// Removes the parts of a message that carry no content for drafting: quoted
/// history, signature blocks, an opening salutation line and a closing
/// sign-off with the lines after it. Everything between is returned verbatim.
public enum ComposerBoilerplate {
    /// A salutation is a greeting plus at most four name words and closing
    /// punctuation, or a Japanese addressee ending in an honorific. A first
    /// line that continues into a sentence ("Hi Marc, would May 10 work?")
    /// carries content and is kept.
    private static let salutation = try! NSRegularExpression(
        pattern: #"^\s*(hi|hello|hey|dear|good (morning|afternoon|evening))\b(\s*[^\s\n?!.。,、，]+){0,4}\s*[,:!、，：]?\s*$|^[^\n、。,.!?！？]{1,40}(先生|様|さん|殿|各位)\s*[、,:：]?\s*$"#,
        options: [.caseInsensitive])
    private static let signoff = try! NSRegularExpression(
        pattern: #"^\s*(best( wishes| regards)?|(kind|warm|warmest) regards|regards|thanks( again| so much)?|thank you( again| very much)?|many thanks|cheers|sincerely( yours)?|yours( sincerely| truly| faithfully)?|all the best|take care|talk soon|with (best|kind|warm) (wishes|regards)|((まずは|以上)?[、,，]?\s*(取り急ぎ[、,，]?\s*)?)?((何卒|どうぞ|引き続き|今後とも)\s*)*(よろしく|宜しく)お願い(いたし|致し|申し上げ|し)ます|以上|敬具|草々|失礼(いた)?します|(まずは|以上)?[、,，]?\s*取り急ぎ[、,，]?\s*の?((((ご|御|お)?(連絡|報告|返信|返事|返答|挨拶|案内|礼|知らせ|一報)((と|かたがた)(ご|御|お)?(連絡|報告|礼|挨拶))?|用件のみ|要件のみ|メール|書面)(まで|(にて|で)失礼(いた|致)?します))|(お|御)礼申し上げます)(。\s*((何卒|どうぞ|引き続き|今後とも)\s*)*(よろしく|宜しく)お願い(いたし|致し|申し上げ|し)ます)?|(まずは[、,，]?\s*)?略儀ながら[、,，]?\s*(メール|書中|書面)(にて|で)失礼(いた|致)?します|(まずは[、,，]?\s*)?(略儀ながら[、,，]?\s*)?(メール|書中|書面)(にて|で)(ご|御|お)?(挨拶|礼)申し上げます)\s*[,.!。、，．！]?\s*$"#,
        options: [.caseInsensitive])

    /// `readingNames`: a name line with initials or a title after the
    /// sign-off ("Alex R. Morgan", "Dr. J. Smith") is the signature, not
    /// prose. Drafts and their check read names so; training keeps the
    /// reading its stored reconstructions were made with.
    public static func strip(_ raw: String, readingNames: Bool = false) -> String {
        let authored = AuthoredReplyText.extract(from: raw)
        var lines = authored.components(separatedBy: .newlines)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           matches(salutation, lines[first]) {
            lines.removeSubrange(0...first)
        }
        return stripTail(lines.joined(separator: "\n"), readingNames: readingNames)
    }

    /// A greeting line: a salutation, or the addressee's name alone ending
    /// in a comma ("Leo,", "田中様、"), at most four capitalized or
    /// unspaced-script words.
    /// Salutations in the app's other languages, as a line of their own
    /// with up to four words after them («Olá, Sam,», "Sehr geehrte Frau
    /// Weber,", "안녕하세요, 샘 리.", "Привет, Сэм!"), and a name with a
    /// Chinese or Korean title ("李老师，", "샘 님,").
    /// The salutation words of the app's other languages.
    private static let worldSalutationWords = #"(?i:olá|oi|prezad[oa]s?|bom dia|boa (tarde|noite)|hola|estimad[oa]s?|querid[oa]s?|buen[oa]s (días|tardes|noches)|ciao|gentil(e|issim[oa])|car[oa]|buongiorno|buonasera|salve|egregi[oa]|bonjour|bonsoir|salut|cher|chère|madame|monsieur|hallo|liebe[rs]?|sehr geehrte[rs]?|guten (tag|morgen|abend)|moin|здравствуйте|привет|добрый (день|вечер)|доброе утро|уважаем\p{L}*|дорог\p{L}*|안녕하세요|您好|你好|尊敬的)"#
    /// A greeting line: the salutation and up to four words after it,
    /// ending on a greeting's punctuation («Hola a todos,», "Sehr geehrte
    /// Damen und Herren,", "Здравствуйте, коллеги!") or on names alone
    /// ("안녕하세요, 샘 리.", "Привет, Сэм!"); a clause after it is content
    /// ("Hola, sí puedo el martes.", "Moin, Termin Montag.", "Oil prices
    /// rose."). Or a name with a Chinese or Korean title ("李老师，", "샘 님,",
    /// "김민수 교수님,").
    private static let worldSalutation = try! NSRegularExpression(
        // The salutation and up to four words, ending on a comma or colon
        // («Hola a todos,», "Sehr geehrte Damen und Herren,").
        pattern: #"^\s*"# + worldSalutationWords + #"(?=$|[\s,，、!！.。:：])[,，、!！]?(?>\s*[^\s\n?!.。,、，！？:：]+){0,4}\s*[,:、，：]\s*$"#
            // One word and "!" ("Здравствуйте, коллеги!", "Hallo zusammen!"), or the salutation alone.
            + #"|^\s*"# + worldSalutationWords + #"(?=$|[\s,，、!！.。:：])[,，、]?(?>\s*[^\s\n?!.。,、，！？:：]+)?\s*[!！]?\s*$"#
            // Names only, with an optional stop ("Hallo, Sam.", "안녕하세요, 샘 리.", "您好，李明。").
            + #"|^\s*"# + worldSalutationWords + #"(?=$|[\s,，、!！.。:：])[,，、!！]?(?>\s*(?:\p{Lu}\.|\p{Lu}[\p{L}\p{M}'’\-]*|[\p{Han}\p{Hangul}\p{Katakana}ー・]{1,4}(?![\p{Han}\p{Hangul}\p{Katakana}ー・]))){1,4}\s*[!！.。]?\s*$"#
            + #"|^[^\n、。,.!?！？，；;]{1,12}(先生|女士|老师|老師|博士|教授|님|씨)\s*[、,:：，!！]?\s*$"#
            // A name with a Chinese title of office, a name's length: "王主任：".
            + #"|^[^\n、。,.!?！？，；;\s]{1,4}(主任|经理|經理|院长|院長|领导|領導|专家|專家)\s*[、,:：，!！]?\s*$"#
            // "尊敬的李主任：", "亲爱的同学们：": a Chinese salutation word and
            // a name or title alone.
            + #"|^\s*(?:尊敬的|亲爱的|親愛的)[\p{Han}·・]{1,8}\s*[,:、，：!！]?\s*$"#)
    /// Closings in the app's other languages, as a line of their own.
    private static let worldClosing = try! NSRegularExpression(
        pattern: #"^\s*(cordialement|bien (à vous|cordialement)|salutations( distinguées)?|merci( beaucoup| bien)?|à bientôt|amicalement|à plus tard|bonne (journée|soirée)|(viele|beste|liebe|herzliche|freundliche) grüße|mit (freundlichen|besten|herzlichen) grüßen|gruß|grüße|danke( schön| sehr)?|saludos( cordiales)?|un (saludo|abrazo)( cordial)?|atentamente|cordialmente|gracias|cordiali saluti|(distinti )?saluti|grazie( mille)?|a presto|un caro saluto|atenciosamente|abraços|um abraço|cumprimentos|obrigad[oa]|saudações|с уважением|спасибо|всего доброго|с наилучшими пожеланиями|до свидания|祝好|此致|敬礼|顺祝商祺|祝顺利|谢谢|謝謝|감사합니다|감사드립니다|드림|올림|안녕히 계세요)[,.!。、！，]?\s*$"#,
        options: [.caseInsensitive])

    /// A closing line in the app's languages other than English and
    /// Japanese («Atenciosamente,», "祝好，"); `strip` reads those two, and
    /// what follows a closing there.
    public static func isClosingLine(_ line: String) -> Bool {
        matches(worldClosing, line.trimmingCharacters(in: .whitespaces))
    }

    /// A sign-off line in any app language ("Best,", "よろしくお願いいたします。",
    /// «Atenciosamente,»).
    static func isSignOff(_ line: String) -> Bool {
        matches(signoff, line) || isClosingLine(line)
    }

    /// A line that is a salutation word and what may follow it ("Hi Sam,",
    /// "你好！"), never a line of capitalized words alone (a closing such as
    /// "Viele Grüße," is one too).
    static func isSalutation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return matches(salutation, trimmed) || matches(worldSalutation, trimmed)
    }

    public static func isGreeting(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if matches(salutation, trimmed) || matches(worldSalutation, trimmed) { return true }
        guard let last = trimmed.last, ",、，:：".contains(last) else { return false }
        let words = trimmed.dropLast().split(whereSeparator: \.isWhitespace)
        // A name and a colon opens a letter only in a script written without
        // spaces, a name's length ("白子旭："); "Agenda:" and "请确认以下事项："
        // open a list.
        if ":：".contains(last), words.count != 1 || words[0].count > 5
            || !words[0].allSatisfy(ComposerDraftEvidence.isUnspacedLetter) { return false }
        return (1...4).contains(words.count) && !trimmed.dropLast().contains(where: { ".!?。！？,、:：".contains($0) })
            && words.allSatisfy { $0.first?.isUppercase == true || $0.first.map(ComposerDraftEvidence.isUnspacedLetter) == true }
    }

    /// The name a greeting gives: its words without the greeting word, or
    /// in an unspaced script without the honorific.
    static func greetingName(_ greeting: String) -> [String] {
        let words = greeting.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !["hi", "hello", "hey", "dear", "good", "morning", "afternoon", "evening", "dr", "prof", "mr", "ms", "mrs"].contains($0) }
        return words.map { word in
            var name = word
            for honorific in ["先生", "さま", "様", "さん", "殿", "各位", "님"] where name.hasSuffix(honorific) && name.count > honorific.count {
                name = String(name.dropLast(honorific.count))
            }
            return name
        }.filter { $0.count >= 2 }
    }

    /// A revision keeps the greeting and sign-off of the draft it revises
    /// when it writes none of its own: the author kept them there. A
    /// greeting stands on its own line before a blank one; a body that
    /// names them in its first line ("Hi Leo, thanks…", "田中様、お世話に…")
    /// has its own. A closing is added only when the body ends on a
    /// sentence, not when it ends on a closing or a name of its own.
    public static func keepingFrame(_ body: String, of current: String) -> String {
        // A postscript closes the body after its sign-off: set apart while the
        // frame is matched, and put back last. The draft's own postscript is
        // what it says now; the current one's is not carried over.
        let (ownBody, postscriptBlock) = splittingPostscript(body)
        let framed = keepingFrameWithoutPostscript(ownBody, of: current)
        return postscriptBlock.map { framed + "\n\n" + $0 } ?? framed
    }

    private static func keepingFrameWithoutPostscript(_ body: String, of current: String) -> String {
        var result = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = splittingPostscript(AuthoredReplyText.extract(from: current)).body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentLines = currentText.components(separatedBy: .newlines)
        func nonEmpty(_ lines: [String]) -> [String] {
            lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        // The body's own greeting stands on a line of its own ("Unfortunately,"
        // opening a sentence is none).
        let resultLines = result.components(separatedBy: .newlines)
        let openingIndex = resultLines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let greets = openingIndex.map { index in
            ownsGreeting(resultLines, at: index)
        } ?? false
        if let first = currentLines.first?.trimmingCharacters(in: .whitespaces), isGreeting(first),
           currentLines.count > 1, currentLines[1].trimmingCharacters(in: .whitespaces).isEmpty,
           let opening = nonEmpty(resultLines).first, !greets {
            let name = greetingName(first)
            let lowered = opening.lowercased()
            if name.isEmpty || !name.contains(where: lowered.contains) {
                result = first + "\n\n" + result
            }
        }
        let currentContent = stripTail(currentText, readingNames: true)
        if currentText.hasPrefix(currentContent), stripTail(result, readingNames: true) == result,
           let ending = nonEmpty(result.components(separatedBy: .newlines)).last,
           let last = ending.last, ".。!！?？".contains(last), !isBareName(ending),
           !["よろしく", "宜しく", "以上", "敬具", "草々"].contains(where: ending.contains) {
            let closing = String(currentText.dropFirst(currentContent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !closing.isEmpty { result += "\n\n" + closing }
        }
        return result
    }

    /// Whether the line at `index` greets: a salutation ("Dear Sam,", "田中様"),
    /// however the body follows it, or a line only of names before a blank
    /// line ("Leo,"; "Unfortunately," opening a sentence is none).
    static func ownsGreeting(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if isSalutation(line) { return true }
        return isGreeting(line) && (index + 1 == lines.count || lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A rewrite of what the draft says, framed as the author's draft is:
    /// its own greeting and sign-off give way to the draft's ("Dear
    /// Professor Whitfield," never replaces the author's "Hi Rowan,"), where
    /// the draft has them; otherwise as `keepingFrame`.
    public static func replacingFrame(_ body: String, of current: String) -> String {
        let (ownBody, postscriptBlock) = splittingPostscript(body)
        var result = ownBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = splittingPostscript(AuthoredReplyText.extract(from: current)).body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentLines = currentText.components(separatedBy: .newlines)
        if let first = currentLines.first?.trimmingCharacters(in: .whitespaces), isGreeting(first),
           currentLines.count > 1, currentLines[1].trimmingCharacters(in: .whitespaces).isEmpty {
            var lines = result.components(separatedBy: .newlines)
            // A greeting on a line of its own ("Unfortunately," opening a
            // sentence is not one).
            if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               ownsGreeting(lines, at: index) {
                lines.remove(at: index)
                result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let currentContent = stripTail(currentText, readingNames: true)
        var closing: String?
        if currentText.hasPrefix(currentContent), currentContent.count < currentText.count {
            let stripped = stripTail(result, readingNames: true)
            if !stripped.isEmpty, stripped != result {
                result = stripped
                closing = String(currentText.dropFirst(currentContent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var framed = keepingFrame(result, of: current)
        // The sign-off taken from it is the author's, however it ends (a
        // list, a link, "以上").
        if let closing, !closing.isEmpty, !framed.hasSuffix(closing) { framed += "\n\n" + closing }
        if let postscriptBlock { framed += "\n\n" + postscriptBlock }
        return framed
    }

    /// A text and the postscript that ends it ("PS: …", 「追伸：…」 to the
    /// end), when one follows the text's first line.
    static func splittingPostscript(_ text: String) -> (body: String, postscript: String?) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let start = lines.indices.first(where: { $0 > first && matches(postscript, lines[$0]) }) else { return (text, nil) }
        let block = lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (lines[..<start].joined(separator: "\n"), block)
    }

    /// Removes a closing sign-off and everything after it.
    static func stripTail(_ text: String, readingNames: Bool = false) -> String {
        var lines = text.components(separatedBy: .newlines)
        // A sign-off closes the message: the name and any signature lines
        // that follow are not content. A sign-off followed by prose (a long
        // line, or a line with a sentence boundary inside it) is not a closing.
        let contentLines = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        if let last = contentLines.last(where: { matches(signoff, lines[$0]) }) {
            let trailing = contentLines.filter { $0 > last }
            // A signature is a line or two after a closing that ends in a
            // comma ("Best regards," then "Alex R. Morgan"); after "Thanks!"
            // a list of initialled names is content.
            let signature = readingNames && trailing.count <= 2
                && lines[last].trimmingCharacters(in: .whitespaces).hasSuffix(",")
            // Read as a draft, the signature starts at the first line shaped
            // as one: a name, a contact line, the line under a closing ending
            // in a comma, or words with neither a sentence's end nor its
            // words (「モーガン・アレックス（北山大学）」). Below it is the
            // signature ("Professor of History."); above it a sentence, a list
            // item or a line leading into one is content ("Thanks!" then
            // "Tuesday works for me."; "Here are my comments:"). A postscript
            // is content wherever it stands ("PS: …", 「追伸：…」).
            let commaClosing = lines[last].trimmingCharacters(in: .whitespaces).hasSuffix(",")
            func ended(_ line: String) -> Bool { line.last.map { "。.!?！？:：".contains($0) } ?? false }
            func lowercaseWords(_ line: String) -> Bool {
                line.split(whereSeparator: \.isWhitespace).dropFirst().contains { $0.first?.isLowercase == true }
            }
            let signatureStart = trailing.first { index in
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if isNameLine(line) || isUnspacedName(line) || isContactLine(line) { return true }
                if index == trailing.first, commaClosing, !ended(line) { return true }
                return !ended(line) && !matches(listMarker, line) && !lowercaseWords(line)
                    && !line.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
            }
            let sentence = { (index: Int) -> Bool in
                guard readingNames else { return false }
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if matches(postscript, line) { return true }
                guard signatureStart.map({ index < $0 }) ?? true, line.contains(where: \.isLetter) else { return false }
                return matches(listMarker, line) || (ended(line) && (lowercaseWords(line) || line.unicodeScalars.contains {
                    (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value)
                }))
            }
            // The name at the head of the signature holds initials ("Alex R.
            // Morgan" reads as prose).
            let named = { (index: Int) -> Bool in
                isNameLine(lines[index]) && (signature || (readingNames && index == signatureStart))
            }
            if trailing.count <= 12, trailing.allSatisfy({ (!isProse(lines[$0]) && !sentence($0)) || (named($0) && !sentence($0)) }) {
                lines.removeSubrange(last..<lines.count)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let postscript = try! NSRegularExpression(
        pattern: #"^(?i:p\.?\s?p?\.?\s?s\.?)[\s:：\-—–].*$|^(追伸|二伸|附言|附記|추신).*$"#)

    /// The draft as the publication check reads it: sign-off and signature
    /// removed, and a bare trailing name line (a signature the writer added
    /// despite instructions) dropped. The salutation stays: it is where an
    /// addressee is named, and the check classes it as courtesy.
    public static func stripForChecking(_ draft: String) -> String {
        var lines = stripTail(AuthoredReplyText.extract(from: draft), readingNames: true).components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        // At most one bare name line goes: short, no sentence-final
        // punctuation, at most four words, and not a list item. Trailing list
        // items are content and stay.
        if lines.count > 1, let last = lines.last?.trimmingCharacters(in: .whitespaces), isBareName(last) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*([-*•・◦▪‣]|\d{1,2}[.)．、]|[a-z][.)])\s*\S.*$"#)

    /// A signature's contact line: an address, a phone number or a link.
    static func isContactLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A phone number: a label, or a "+", space or bracket among seven
        // or more digits ("2026-10-18" is a date).
        return trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$|^(tel|phone|mobile|fax|電話|手机)\.?\s*[:：]?\s*\+?[\d\s().\-]{7,}$|^\+[\d\s().\-]{7,}$|^(?=.*[\s()])[\d\s().\-]{9,}$|^(https?://|www\.)\S+$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a line is the author's name: whole parts of their display
    /// name ("Alex" for "Alex R. Morgan", "モーガン" for "アレックス・モーガン"),
    /// or a name they signed their earlier email with (`signedAs`: "佐藤"),
    /// written as a name: "May." ends a sentence, "J." is an initial.
    static func namesAuthor(_ line: String, author: String, signedAs: Set<String> = []) -> Bool {
        if signedAs.contains(ComposerContentText.folded(line)) { return true }
        func words(_ text: String) -> [String] {
            text.precomposedStringWithCompatibilityMapping.lowercased()
                .split { $0.isWhitespace || $0.isPunctuation || $0 == "・" }.map(String.init)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, "!?。！？".contains(last) { return false }
        if trimmed.hasSuffix("."), trimmed.split(whereSeparator: \.isWhitespace).last?.count != 2 { return false }
        let said = words(trimmed), name = Set(words(author))
        guard !said.isEmpty, !name.isEmpty else { return false }
        return said.allSatisfy(name.contains)
    }

    /// The names the author signed earlier emails with, folded: the lines
    /// under their sign-off that are names ("Alex", "佐藤").
    static func signatureNames(_ emails: [String]) -> Set<String> {
        var names = Set<String>()
        for email in emails {
            let text = AuthoredReplyText.extract(from: email).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = stripTail(text, readingNames: true)
            guard content.count < text.count, text.hasPrefix(content) else { continue }
            for line in text.dropFirst(content.count).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !matches(signoff, trimmed) else { continue }
                if isNameLine(trimmed) || isUnspacedName(trimmed) { names.insert(ComposerContentText.folded(trimmed)) }
            }
        }
        return names
    }

    /// A name in an unspaced script or Hangul, alone on its line ("알렉스",
    /// "アレックス・モーガン", "李明").
    static func isUnspacedName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard (1...12).contains(trimmed.count), trimmed.split(separator: " ").count <= 2 else { return false }
        return trimmed.allSatisfy { $0 == " " || $0 == "・" || ComposerDraftEvidence.isUnspacedLetter($0)
            || $0.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) } }
    }

    static func isBareName(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 24, !matches(listMarker, line) else { return false }
        let unpunctuated = line.last.map { !"。！？!?.,、:：;".contains($0) } ?? false
        return unpunctuated && line.split(whereSeparator: \.isWhitespace).count <= 4
    }

    /// A line that is only a name: up to five capitalized words, initials or
    /// titles ("Alex R. Morgan", "Dr. J. Smith"). "P.S. …", "N.B. …" and any
    /// line with a lowercase word are prose.
    static func isNameLine(_ line: String) -> Bool {
        let words = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 5,
              !["p.s.", "ps.", "p.p.s.", "pps.", "n.b.", "nb."].contains(words[0].lowercased()) else { return false }
        return words.allSatisfy { word in
            word.range(of: #"^(?:\p{Lu}[\p{L}'’\-]*\.?|(?:\p{Lu}\p{Ll}?\.)+),?$"#, options: .regularExpression) != nil
        }
    }

    private static func isProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 120 { return true }
        let inner = trimmed.dropLast()
        return inner.contains(". ") || inner.contains("。") || inner.contains("! ") || inner.contains("? ")
    }

    private static func matches(_ expression: NSRegularExpression, _ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return expression.firstMatch(in: trimmed, options: [], range: range)?.range == range
    }
}

public enum ComposerPresentationIdentity {
    public static func value(for input: ComposerPresentationInput) throws -> String {
        struct Identity: Encodable {
            let registerID: UUID?
            let name: String?
            let revision: Int?
            let axes: StyleAxisValues?
            let intent: StyleControlIntent?
        }
        return ComposerContentCoding.digest(try ComposerContentCoding.encode(Identity(
            registerID: input.registerID, name: input.registerName,
            revision: input.registerRevision, axes: input.controls?.effectiveAxes,
            intent: input.controls?.intent)))
    }
}

public enum ComposerContentCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero)))
        }
        return try encoder.encode(value)
    }

    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(text.utf8))
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeModelObject<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        if lines.count >= 3,
           lines.first == "```json" || lines.first == "```",
           lines.last == "```" {
            // A single whole-response Markdown wrapper changes presentation,
            // not the structured answer. Decode its entire payload strictly:
            // never extract a substring, ignore prose, or repair a fenced
            // payload whose JSON is incomplete. Persisted data stays strict.
            return try decode(type, from: lines.dropFirst().dropLast().joined(separator: "\n"))
        }
        do { return try decode(type, from: text) }
        catch {
            // An EOS-completed model response can omit the outer object's final
            // delimiter after all its values have closed. Permit exactly that
            // framing completion. Never close strings/arrays, drop partial
            // members, supply fields or apply this to persisted contracts.
            guard trimmed.hasPrefix("{"), let value = try? decode(type, from: trimmed + "}") else { throw error }
            return value
        }
    }
}
