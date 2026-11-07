import Foundation

public struct MailboxSpamFeedbackEvidence: Sendable, Equatable {
    public let accountID: UUID?
    public let senderAddress: String?
    public let senderDomain: String?
    public let listId: String?
    public let subjectFingerprint: String?

    public init(
        accountID: UUID?,
        senderAddress: String?,
        subject: String?,
        listId: String?
    ) {
        let normalizedSender = Self.normalizedEmail(senderAddress)
        self.accountID = accountID
        self.senderAddress = normalizedSender
        self.senderDomain = Self.senderDomain(from: normalizedSender)
        self.listId = Self.normalizedToken(listId)
        self.subjectFingerprint = Self.subjectFingerprint(subject)
    }

    public init(
        accountID: UUID?,
        normalizedSenderAddress: String?,
        senderDomain: String?,
        listId: String?,
        subjectFingerprint: String?
    ) {
        self.accountID = accountID
        self.senderAddress = Self.normalizedEmail(normalizedSenderAddress)
        self.senderDomain = Self.normalizedDomain(senderDomain)
        self.listId = Self.normalizedToken(listId)
        self.subjectFingerprint = Self.normalizedToken(subjectFingerprint)
    }

    public var hasSignals: Bool {
        senderAddress != nil || senderDomain != nil || listId != nil || subjectFingerprint != nil
    }

    public static func normalizedEmail(_ value: String?) -> String? {
        guard var candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }

        if let lower = candidate.firstIndex(of: "<"),
           let upper = candidate[lower...].firstIndex(of: ">"),
           lower < upper {
            candidate = String(candidate[candidate.index(after: lower)..<upper])
        } else if candidate.contains("@") {
            let separators = CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
                .subtracting(CharacterSet(charactersIn: "@._+-"))
            if let token = candidate
                .components(separatedBy: separators)
                .first(where: { $0.contains("@") }) {
                candidate = token
            }
        }

        candidate = candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<> "))
            .lowercased()
        if candidate.hasPrefix("mailto:") {
            candidate.removeFirst("mailto:".count)
        }
        guard candidate.contains("@") else { return nil }
        return candidate
    }

    public static func senderDomain(from email: String?) -> String? {
        guard let email,
              let at = email.lastIndex(of: "@"),
              at < email.index(before: email.endIndex) else {
            return nil
        }
        return normalizedDomain(String(email[email.index(after: at)...]))
    }

    public static func normalizedDomain(_ value: String?) -> String? {
        guard let domain = normalizedToken(value) else { return nil }
        return domain.contains(".") ? domain : nil
    }

    public static func normalizedToken(_ value: String?) -> String? {
        guard let cleaned = value?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t<>\"'"))
            .lowercased(),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    public static func subjectFingerprint(_ subject: String?) -> String? {
        guard var raw = subject?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }

        // Strip leading reply/forward markers. These Latin markers ("re:", "fwd:")
        // are prepended across locales — Japanese and other non-English clients use
        // them too — so this remains language-agnostic.
        let prefixes = ["re", "fw", "fwd"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where raw.hasPrefix(prefix + ":") {
                raw = raw.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        let tokens = subjectTokens(raw).prefix(8)
        let fingerprint = tokens.joined(separator: " ")
        return fingerprint.isEmpty ? nil : String(fingerprint.prefix(96))
    }

    /// English stop-words dropped from Latin-script subject tokens. Applied only to
    /// pure-ASCII words (see `subjectTokens`) so it never discriminates against
    /// non-English scripts.
    private static let latinStopWords: Set<String> = [
        "about", "after", "and", "are", "for", "from", "have", "into",
        "notice", "please", "that", "the", "this", "update", "with",
        "your"
    ]

    /// Language-agnostic tokenizer for the subject fingerprint.
    ///
    /// - Space-delimited scripts (Latin, Cyrillic, Greek, digits) yield word tokens
    ///   of length ≥ 3, with the English stop-word list applied to ASCII words only.
    /// - CJK and other space-less scripts (Han, Kana, Hangul) yield character
    ///   bigrams, so a Japanese / Chinese / Korean subject produces a discriminative
    ///   key instead of collapsing to one giant token — or, for a short subject,
    ///   being dropped entirely by the length filter.
    static func subjectTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var wordScalars = String.UnicodeScalarView()
        var cjkScalars: [Unicode.Scalar] = []

        func flushWord() {
            guard !wordScalars.isEmpty else { return }
            let word = String(wordScalars)
            wordScalars = String.UnicodeScalarView()
            guard word.count >= 3 else { return }
            // Stop-word filtering is English-specific, so gate it on ASCII words;
            // non-Latin words of the same spelling are never silently dropped.
            if word.allSatisfy(\.isASCII), latinStopWords.contains(word) { return }
            tokens.append(word)
        }

        func flushCJK() {
            guard !cjkScalars.isEmpty else { return }
            if cjkScalars.count == 1 {
                var single = ""
                single.unicodeScalars.append(cjkScalars[0])
                tokens.append(single)
            } else {
                for index in 0..<(cjkScalars.count - 1) {
                    var bigram = ""
                    bigram.unicodeScalars.append(cjkScalars[index])
                    bigram.unicodeScalars.append(cjkScalars[index + 1])
                    tokens.append(bigram)
                }
            }
            cjkScalars = []
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if isCJKScalar(scalar) {
                    flushWord()
                    cjkScalars.append(scalar)
                } else {
                    flushCJK()
                    wordScalars.append(scalar)
                }
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return tokens
    }

    /// True for CJK ideographs, Japanese kana, and Hangul — scripts written without
    /// spaces, which `subjectTokens` shingles into bigrams rather than whitespace
    /// words.
    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005...0x3007,    // 々 〆 〇 (ideographic iteration / closing / zero)
             0x3041...0x3096,    // Hiragana
             0x309D...0x309F,    // Hiragana iteration marks ゝ ゞ ゟ
             0x30A1...0x30FA,    // Katakana letters
             0x30FC...0x30FF,    // Katakana marks ー ヽ ヾ ヿ (excludes ・ U+30FB)
             0x31F0...0x31FF,    // Katakana Phonetic Extensions
             0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0xFF66...0xFF9D,    // Halfwidth Katakana (incl. ｰ U+FF70)
             0xAC00...0xD7A3,    // Hangul Syllables
             0x20000...0x2A6DF,  // CJK Unified Ideographs Extension B
             0x2A700...0x2EBEF:  // CJK Unified Ideographs Extensions C–F
            return true
        default:
            return false
        }
    }
}

public enum MailboxSpamFeedbackKind: Sendable, Equatable {
    case spam
    case ham
}

public struct MailboxSpamFeedbackSignal: Sendable, Equatable {
    public let kind: MailboxSpamFeedbackKind
    public let accountID: UUID
    public let evidence: MailboxSpamFeedbackEvidence
    public let createdAt: Date

    public init?(
        kind: MailboxSpamFeedbackKind,
        accountID: UUID,
        evidence: MailboxSpamFeedbackEvidence,
        createdAt: Date = Date()
    ) {
        guard evidence.hasSignals else { return nil }
        self.kind = kind
        self.accountID = accountID
        self.evidence = evidence
        self.createdAt = createdAt
    }

    public init?(_ mutation: MailboxMutation) {
        let kind: MailboxSpamFeedbackKind
        switch mutation.kind {
        case .moveToJunk:
            kind = .spam
        case .moveToInbox:
            let role = mutation.feedbackSourceRoleRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "junk" || IMAPFolderIngestionPolicy.matchesJunkLeafName(mutation.imapFolderPath) else {
                return nil
            }
            kind = .ham
        default:
            // Deliberately no signal for `.moveToTrash` / `.delete`: trashing is an
            // everyday cleanup gesture (read mail, done threads), not a spam verdict,
            // so treating it as spam would inject false positives. The only spam
            // signal is the explicit "mark as junk" gesture (see
            // `MailboxMutationDispatcher.markAsSpam`, which captures evidence on both
            // its server-move and local-fallback paths); the only ham signal is a
            // Junk→Inbox rescue. Do not broaden this switch without that rationale.
            return nil
        }

        let evidence = MailboxSpamFeedbackEvidence(
            accountID: mutation.accountID,
            normalizedSenderAddress: mutation.feedbackSenderAddress,
            senderDomain: mutation.feedbackSenderDomain,
            listId: mutation.feedbackListId,
            subjectFingerprint: mutation.feedbackSubjectFingerprint
        )
        self.init(
            kind: kind,
            accountID: mutation.accountID,
            evidence: evidence,
            createdAt: mutation.createdAt
        )
    }
}

public struct MailboxSpamFeedbackScore: Sendable, Equatable {
    public let adjustment: Double
    public let spamWeight: Double
    public let hamWeight: Double
    public let matchedSpamSignals: Int
    public let matchedHamSignals: Int

    public var hasEvidence: Bool {
        matchedSpamSignals > 0 || matchedHamSignals > 0
    }

    // A subject fingerprint alone never produces a match (see `matchWeight`), so
    // every counted signal is sender/List-Id backed — the adjustment thresholds
    // are therefore confident on their own.
    public var favorsSpam: Bool {
        adjustment > 0.05
    }

    public var favorsHam: Bool {
        adjustment < -0.05
    }
}

public enum MailboxSpamFeedbackScorer {
    private static let maxAdjustment = 8.0
    private static let hamMultiplier = 1.25
    /// Recency half-lives: a signal's contribution halves for every half-life of
    /// age. Ham decays slower than spam because a client cannot stop a provider
    /// from re-quarantining a rescued sender — the only lever we hold is to keep
    /// trusting that sender for longer, so a rescue stays influential well past
    /// when an equally-old junking would have faded.
    private static let spamRecencyHalfLife: TimeInterval = 120 * 86_400   // 120 days
    private static let hamRecencyHalfLife: TimeInterval = 365 * 86_400    // 1 year
    private static let broadConsumerDomains: Set<String> = [
        "aol.com", "gmail.com", "hotmail.com", "icloud.com", "live.com",
        "me.com", "msn.com", "outlook.com", "proton.me", "protonmail.com",
        "yahoo.com"
    ]

    public static func score(
        evidence: MailboxSpamFeedbackEvidence,
        against signals: [MailboxSpamFeedbackSignal],
        now: Date = Date()
    ) -> MailboxSpamFeedbackScore {
        guard evidence.hasSignals else {
            return MailboxSpamFeedbackScore(
                adjustment: 0,
                spamWeight: 0,
                hamWeight: 0,
                matchedSpamSignals: 0,
                matchedHamSignals: 0
            )
        }

        var spamWeight = 0.0
        var hamWeight = 0.0
        var matchedSpamSignals = 0
        var matchedHamSignals = 0

        for signal in signals where signal.accountID == evidence.accountID {
            let weight = matchWeight(row: evidence, signal: signal.evidence)
            guard weight > 0 else { continue }
            let halfLife = signal.kind == .ham ? hamRecencyHalfLife : spamRecencyHalfLife
            let decayed = weight * recencyFactor(
                age: now.timeIntervalSince(signal.createdAt),
                halfLife: halfLife
            )
            switch signal.kind {
            case .spam:
                spamWeight += decayed
                matchedSpamSignals += 1
            case .ham:
                hamWeight += decayed * hamMultiplier
                matchedHamSignals += 1
            }
        }

        let rawAdjustment = spamWeight - hamWeight
        let adjustment = min(max(rawAdjustment, -maxAdjustment), maxAdjustment)
        return MailboxSpamFeedbackScore(
            adjustment: adjustment,
            spamWeight: spamWeight,
            hamWeight: hamWeight,
            matchedSpamSignals: matchedSpamSignals,
            matchedHamSignals: matchedHamSignals
        )
    }

    /// Exponential recency decay: the weight halves for every `halfLife` of age.
    /// Future-dated signals (clock skew) and non-positive half-lives return 1.0.
    private static func recencyFactor(age: TimeInterval, halfLife: TimeInterval) -> Double {
        guard age > 0, halfLife > 0 else { return 1.0 }
        return pow(2.0, -age / halfLife)
    }

    /// The weight a single stored signal contributes to a candidate row.
    ///
    /// A subject-fingerprint or sender-domain agreement only *reinforces* a strong
    /// (sender-address / List-Id) match — on its own neither is evidence. Generic
    /// subjects ("invoice", "payment reminder") and shared consumer domains collide
    /// across unrelated mail, so a non-strong signal would fabricate feedback;
    /// therefore a signal with no sender/List-Id agreement contributes nothing.
    private static func matchWeight(
        row: MailboxSpamFeedbackEvidence,
        signal: MailboxSpamFeedbackEvidence
    ) -> Double {
        var weight = 0.0
        var isStrong = false

        if let sender = row.senderAddress,
           sender == signal.senderAddress {
            weight += 4.0
            isStrong = true
        }

        if let listId = row.listId,
           listId == signal.listId {
            weight += 3.5
            isStrong = true
        }

        guard isStrong else { return 0 }

        if let subject = row.subjectFingerprint,
           subject == signal.subjectFingerprint {
            weight += 1.25
        }

        if let domain = row.senderDomain,
           domain == signal.senderDomain,
           !broadConsumerDomains.contains(domain) {
            weight += 0.75
        }

        return weight
    }
}

public extension MailboxMutation {
    func applySpamFeedbackEvidence(
        _ evidence: MailboxSpamFeedbackEvidence?,
        sourceRoleRaw: String? = nil,
        providerSpamScore: Double? = nil
    ) {
        guard let evidence, evidence.hasSignals else { return }
        feedbackSourceRoleRaw = sourceRoleRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        feedbackSenderAddress = evidence.senderAddress
        feedbackSenderDomain = evidence.senderDomain
        feedbackListId = evidence.listId
        feedbackSubjectFingerprint = evidence.subjectFingerprint
        feedbackProviderSpamScore = providerSpamScore
    }
}
