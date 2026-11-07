import Foundation
import NaturalLanguage

enum ComposerReplySourceMode: Sendable, Equatable {
    case minimal
    case grounded
}

enum ComposerReplySourcePolicy {
    static let maximumMinimalBodyCharacters = 800

    private static let questionWordPattern = #"\b(what|when|where|which|who|how)\b"#
    private static let requestPatterns = [
        #"\b(can|could|would|will)\s+you\b"#,
        #"\bplease\b"#,
        #"\blet\s+(me|us)\s+know\b"#,
        #"\b(do|are)\s+you\b"#,
        questionWordPattern,
        #"(?:^|[.!?]\s+)(?:please\s+)?(?:confirm|send|provide|share|review|return|submit|complete|sign|attach|forward|reply|respond|advise|schedule|arrange|check|verify)\b"#,
        #"\bit\s+would\s+(?:help|be\s+helpful)\s+if\s+you\b"#
    ]

    private static let closedLoopPatterns = [
        #"\bconfirm\w*\b"#,
        #"\bagree\w*\b"#,
        #"\bwork(?:s|ed)?\s+for\s+me\b"#,
        #"\bwill\s+work\b"#,
        #"\bavailable\b"#,
        #"\breceiv\w*\b"#,
        #"\bnoted\b"#,
        #"\bthank\w*\b"#,
        #"\bsorry\b"#,
        #"\bapolog\w*\b"#
    ]

    private static let completeClosedLoopSentencePatterns = [
        #"^(?:thanks|thank you|all noted|noted|received|agreed|confirmed|yes|no|sounds good)$"#,
        #"^sorry(?:\s+for\s+(?:the\s+delay|missing\s+the\s+(?:in-person\s+)?meeting))?$"#,
        #"^(?:i|we)\s+apologize(?:\s+for\s+(?:the\s+delay|missing\s+the\s+(?:in-person\s+)?meeting))?$"#,
        #"^the\s+\d{1,2}(?:st|nd|rd|th)(?:\s+or\s+\d{1,2}(?:st|nd|rd|th))*\s+of\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+work(?:s|ed)?\s+for\s+me$"#,
        #"^(?:(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}(?:st|nd|rd|th)?|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:january|february|march|april|may|june|july|august|september|october|november|december)|that|this|it)\s+work(?:s|ed)?\s+for\s+me$"#,
        #"^(?:i\s+am|we\s+are)\s+available(?:\s+(?:on|after|before|from)\s+(?:(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}(?:st|nd|rd|th)?|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\d{1,2}(?::\d{2})?(?:\s+(?:jst|utc|gmt))?))?$"#,
        #"^(?:i|we)\s+will\s+be\s+in\s+[\p{L}][\p{L}'’\-]{0,79},\s+so\s+anything\s+after\s+\d{1,2}:\d{2}(?:\s+(?:jst|utc|gmt))?\s+will\s+work\s+for\s+me$"#,
        #"^(?:i|we)\s+(?:agree|confirm|(?:have\s+)?received)$"#
    ]

    /// Japanese requests. A bare "お願い" is the closing "よろしくお願いいたします";
    /// asking for something puts an object before it ("ご確認をお願いします").
    private static let japaneseRequestPatterns = [
        "ください", "下さい", "(?:いただ|頂)け(?:ます|ません|ない|れば|たら)", "願えます", "お願いでき", "でしょうか",
        "ますか", "ませんか", "教えて", "してほしい", "して欲しい", "[をのでに]お願い",
        "ご(?:検討|返信|回答)(?:ください|下さい|のほど|を|いただけ|頂け)", "よろしかった(?:でしょうか|ですか)",
        "(?:いただ|頂)けると(?:幸い|助か|ありがた|嬉し|うれし)", "ご(?:確認|対応|連絡|手配)のほど(?!ありがと|有難|有り難)"
    ]

    /// Japanese closed-loop cues and the complete sentences a closed-loop
    /// note is made of: thanks, acknowledgment, receipt, apology.
    private static let japaneseClosedLoopCues = [
        "ありがと", "承知", "了解", "かしこまり", "拝受", "受け取り", "受領", "確認いたしました", "確認しました",
        "拝見", "お礼", "御礼", "申し訳", "失礼"
    ]
    private static let japaneseClosedLoopSentencePatterns = [
        #"^(?:(?:ご連絡|ご確認|ご丁寧な?ご連絡|ご丁寧に|ご返信|早速の?ご返信|お知らせ|ご対応|お心遣い|ご報告|ご共有)(?:を)?(?:いただき|頂き|くださり|下さり)?)?(?:誠に|本当に|大変)?ありがとうござい(?:ます|ました)$"#,
        #"^(?:承知|了解|拝承)(?:いた|致)?しました$"#,
        #"^かしこまりました$"#,
        // Receipt may name what arrived, a noun ("資料を拝受しました").
        #"^(?:[\p{Han}\p{Katakana}ー・]{1,12}を)?(?:拝受|受領|確認|拝見)(?:いた|致)?しました$"#,
        #"^(?:[\p{Han}\p{Katakana}ー・]{1,12}を)?受け取りました$"#,
        #"^(?:取り急ぎ)?(?:お礼|御礼)(?:まで|申し上げます)$"#,
        #"^(?:大変)?(?:失礼|お手数をおかけ)(?:いた|致)?しました$"#,
        #"^(?:大変)?申し訳(?:ございません|ありません)(?:でした)?$"#
    ]
    /// The envelope of a Japanese note: greetings, self-introduction and the
    /// closing, none of which asks or tells anything.
    private static let japaneseEnvelopeSentencePatterns = [
        #"^(?:いつも)?お世話になっております$"#,
        #"^お疲れ様です$"#,
        #"^[\p{Han}\p{Katakana}ー・]{1,12}です$"#,
        #"^(?:どうぞ)?(?:引き続き|今後とも)?(?:どうぞ)?よろしくお願い(?:いた|申し上げ|致)?(?:します|ます)$"#,
        #"^以上(?:です|、?よろしくお願いします)?$"#
    ]
    /// A Japanese salutation line ("森先生", "田中様、") and a bare name
    /// signature line ("田中", "アレックス・モーガン").
    private static let japaneseSalutationPattern =
        #"^[^\n、。,.!?！？]{1,40}(?:先生|様|さん|殿|各位)\s*[、,:：]?$"#
    private static let japaneseSignatureNamePattern = #"^[\p{Han}\p{Katakana}ー・\s]{2,16}$"#

    private static let salutationPrefixPattern =
        #"^\s*(?:(?:Hi|Hello|Dear)|Good\s+(?:morning|afternoon|evening))(?:\s+(?:(?:Dr|Prof|Professor|Mr|Ms|Mrs)\.?\s+)?[\p{Lu}][\p{L}'’\-]{0,39})?[,!]\s*"#

    private static let signoffNamePattern =
        #"^[\p{Lu}][\p{Ll}]{1,39}$"#

    private static let recognizedSignoffs = [
        "all best,",
        "best,",
        "best regards,",
        "kind regards,",
        "regards,",
        "sincerely,",
        "thanks,",
        "thank you,"
    ]

    private static let unsafeSignoffTokens: Set<String> = [
        "accept", "access", "acknowledge", "add", "advise", "answer", "approve",
        "archive", "arrange", "asap", "attach", "bcc", "book", "buy", "call", "cancel",
        "cc",
        "change", "check", "choose", "click", "complete", "confirm",
        "contact", "decide", "decline", "delete", "document", "download",
        "docusign", "draft", "edit", "email", "fill", "finalize", "find", "fix",
        "follow", "forward", "give", "grant", "help", "join", "let",
        "locate", "make", "meet", "offer", "open", "pay", "prepare", "rsvp",
        "print", "provide", "read", "remind", "reply", "report", "respond",
        "return", "review", "schedule", "select", "send", "share", "sign",
        "submit", "tell", "update", "upload", "use", "verify", "visit",
        "vote", "write", "zelle", "venmo", "dm"
    ]

    static func mode(
        cleanedBody: String?,
        correspondentName: String? = nil,
        hasAttachments: Bool,
        triageVerdict: TriageVerdict?
    ) -> ComposerReplySourceMode {
        guard let cleanedBody else { return .grounded }
        let body = cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
        if containsJapanese(body) {
            return japaneseMode(body: body, hasAttachments: hasAttachments, triageVerdict: triageVerdict)
        }
        guard !body.isEmpty,
              body.count <= maximumMinimalBodyCharacters,
              !hasAttachments,
              !containsURL(body),
              !body.contains("?"),
              !containsRequestCue(normalizedBody),
              let triageVerdict,
              !triageVerdict.isActionable,
              !triageVerdict.requiresConfirmation,
              triageVerdict.action == nil,
              containsClosedLoopCue(normalizedBody),
              hasOnlyCompleteClosedLoopSentences(
                body,
                correspondentName: correspondentName
              ) else {
            return .grounded
        }
        return .minimal
    }

    /// Standing offers that ask nothing: "please feel free to…", "let me
    /// know if you have any questions", "何かございましたらご連絡ください".
    /// The rest of a clause, up to its punctuation, a dash or bracket, or a
    /// word that joins another clause ("and/or" joins none).
    private static let clauseStops = #"(?:but|and|or|so|otherwise|however|though|although|instead|then|plus|as\s+well\s+as|along\s+with|together\s+with)"#
    private static let clauseTail = #"(?:(?!\b"# + clauseStops + #"\b(?!/)|\s[-–—]\s|[–—(])[^.!?,;\n])*"#
    /// What answers an offer of further help: an invitation to say so.
    private static let invitedToSay = #"(?:\s*,\s*(?:please\s+|kindly\s+|just\s+)?(?:do\s+)?(?:let\s+(?:me|us)\s+know|tell\s+(?:me|us)|say\s+so|ask|get\s+in\s+touch|reach\s+out)\b"#
        + #"(?:(?!\b"# + clauseStops + #"\b(?!/))[^.!?,;\n])*)?"#

    /// What an ask joined to an offer may share with it.
    private enum Joined { case nothing, ask, action }

    /// A standing offer: its form, and what an ask joined to it shares ("let
    /// me know …, and when you'd like to meet" shares "let me know"; "please
    /// find attached …, and sign it" the "please").
    private struct Offer {
        let pattern: String
        var joined: Joined = .nothing
    }

    private static let courtesyOffers: [Offer] = [
        Offer(pattern: #"please\s+(?:do\s+)?feel\s+free[^.!?]*"#),
        // Up to its clause: "…and let me know what you think" asks.
        Offer(pattern: #"(?:please|kindly)\s+(?:find|see)\s+(?:attached|enclosed|below|the\s+attached)"# + clauseTail, joined: .action),
        Offer(pattern: #"(?:please|kindly)\s+(?:note|be\s+(?:advised|informed|aware))\s+that[^.!?]*"#),
        Offer(pattern: #"please\s+accept\s+(?:my|our)\s+(?:sincere\s+|deepest\s+)?(?:apologies|thanks|gratitude|condolences)[^.!?]*"#),
        Offer(pattern: #"(?:please\s+)?(?:do\s+)?let\s+(?:me|us)\s+know\s+if\s+(?:you\s+have|there\s+are)\s+any\s+(?:further\s+|other\s+)?(?:questions|concerns)"# + clauseTail,
              joined: .ask),
        Offer(pattern: #"if\s+you\s+have\s+any\s+(?:further\s+|other\s+)?(?:questions|concerns)[^.!?]*"#),
        // An offer to help further, and leave not to bother: nothing to
        // decide. Each ends with its own clause, so an ask joined to it
        // ("…, but please send your slides by Friday") is still read.
        Offer(pattern: #"(?:please\s+)?(?:do\s+)?let\s+(?:me|us)\s+know\s+if\s+(?:there\s+is|there's|there’s)\s+anything\s+(?:else\s+)?(?:i|we)\s+(?:can|could)\b"# + clauseTail,
              joined: .ask),
        // "Let me know if you need anything else", "…if anything more is needed".
        Offer(pattern: #"(?:please\s+|just\s+)?(?:do\s+)?let\s+(?:me|us)\s+know\s+if\s+(?:you\s+(?:need|want|require)\s+anything(?:\s+(?:else|more))?|anything\s+(?:else|more)\s+is\s+(?:needed|required))\b"# + clauseTail,
              joined: .ask),
        // Opening its clause ("wondering if there is anything I could do"
        // asks), with what invites them to say so ("…, please let me know").
        Offer(pattern: #"(?:^|(?<=[.!?;,:]\s)|(?<=again\s)|(?<=also\s))if\s+(?:there\s+is|there's|there’s)\s+anything\s+(?:else\s+)?(?:i|we)\s+(?:can|could)\b"# + clauseTail + invitedToSay,
              joined: .ask),
        Offer(pattern: #"(?:please\s+)?(?:do\s+not|don't|don’t)\s+hesitate\s+to\s+(?:contact|reach|email|ask|write)\b"# + clauseTail),
        Offer(pattern: #"(?:please\s+)?(?:do\s+not|don't|don’t)\s+feel\s+(?:obligated|obliged|pressured|that\s+you\s+have\s+to)\b"# + clauseTail),
        Offer(pattern: #"(?:there\s+is\s+)?no\s+need\s+to\s+(?:reply|respond|answer|write\s+back)\b"# + clauseTail),
        // "No need to reply", its own words only: "…ですが出欠だけお知らせ
        // ください" asks.
        Offer(pattern: #"(?:ご返信|お返事|ご返事)(?:は|には)?(?:不要|及びません|結構です|お気遣いなく)(?:です|でございます|となります)?"#),
        Offer(pattern: #"お気になさらず[^。！、\n]*"#),
        // "Anything else, let me know", to whom, how or when it may say
        // ("私まで", "メールで", "改めて") and however the verb is put ("ご連絡を
        // お願いいたします", "教えていただけると助かります", "言ってくださいね");
        // never with what else the sentence asks for (an object or topic,
        // "と合わせて", "と一緒に", "だけ", "日程も"), before or after the
        // verb, which is read.
        Offer(pattern: #"(?:何か|ご不明(?:な)?点(?:等|など)?が?|ご質問(?:等|など)?が?|(?:他|ほか)に(?:必要な|ご入用の)?(?:もの|こと|点)(?:が|は)?)(?:ございましたら|ありましたら|あれば)"#
            + #"(?:(?!を|"# + japaneseJoined + #")[^。！\n]){0,40}?"#
            + #"(?:ご連絡|ご一報|連絡|お知らせ|お申し付け|お申しつけ|お声がけ|お声掛け|ご相談|相談|お問い合わせ|お問合せ|問い合わせ|お尋ね|ご質問|ご返信|返信|お電話|おっしゃって|仰って|言って|教えて)"#
            + #"(?:(?!を(?!お願い)|"# + japaneseJoined + #")[^。！\n])*"#),
        Offer(pattern: #"(?:どうぞ|引き続き|今後とも)?(?:どうぞ)?よろしくお願い[^。！]*"#),
    ]
    /// What, inside a Japanese offer, joins another ask to it: a topic
    /// ("出欠は"), "と合わせて", "と一緒に", "だけ", "も" ("日程も"; not
    /// "もしくは", "へも"), whose verb the offer's would be.
    private static let japaneseJoined = #"(?<!もしく)(?<!また)は|合わせ|あわせ|併せ|と共に|とともに|一緒に|だけ|(?<![でへに])も(?!し)"#
    private static let courtesyOfferExpressions = courtesyOffers.map {
        (expression: try! NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive]), joined: $0.joined)
    }
    /// A request's verbs, as what joins an offer asks ("…and RSVP by Friday").
    /// …used as a verb: with what it takes after it ("RSVP by Friday", "fill
    /// out the form", "sign it"), not as a noun ("schedule conflicts",
    /// "check-in details").
    private static let requestVerbs = #"(?:(?:send|share|confirm|return|sign|provide|tell|advise|forward|submit|complete|book|reply|respond|review|approve|choose|indicate|give|bring|rsvp|pay|fill|register|update|accept|upload|check|schedule|add|arrange|prepare)\s+(?:it|them|me|us|this|that|these|those|the|your|a|an|my|our|by|in|out|up|back|to|on|before)\b|let\s+(?:me|us)\s+know\s+(?!if\b))"#
    /// What, joined to an offer's "let me know", still shares it and asks: a
    /// question word or "whether" ("and when you'd like to meet"), "and if"
    /// ("and if you can attend"), their own thing to give ("as well as your
    /// availability"), or a request's verb. Anything else joined to it ("or would like to discuss further",
    /// "or if you'd like to chat", "and if not, enjoy the break", ", which I'm
    /// happy to answer", "and congratulations again", "and I'll
    /// send it") is the offer's or a clause of its own.
    private static let joinedAsk = try! NSRegularExpression(pattern: #"^\s*(?:,?\s*(?:and|or|&|plus|as\s+well\s+as|along\s+with|together\s+with)\s+(?:also\s+)?(?:please\s+)?(?:(?:what|when|where|which|who|whom|whose|how|why|whether)\b|your\s+\w|"# + requestVerbs + #")|,?\s*and\s+if\s+(?!not\b|so\b|there\s+is|there's|there’s|you\s+need|you\s+have\s+any))"#,
        options: [.caseInsensitive])
    /// What, joined to "please find attached", shares its "please": a
    /// request's verb only ("and sign it by Friday", not "and your badge").
    private static let joinedAction = try! NSRegularExpression(pattern: #"^\s*,?\s*(?:and|&)\s+(?:also\s+)?(?:please\s+)?"# + requestVerbs,
        options: [.caseInsensitive])

    /// One passage's English requests, read by what each form asks for.
    /// A question word asks where it opens a sentence the way a question
    /// does ("When is the deadline", "Which date works", "How about Tuesday"),
    /// never in a statement's clause ("When I finished my MA", "a case
    /// through which", "my co-author, who was", "What is clear is").
    /// Gratitude asks only in the conditional and for an answer ("I'd be
    /// grateful for any advice", "I would appreciate your feedback",
    /// "…appreciate it if you could look"), never for patience or
    /// understanding. "Kindly", "tell me" and "any … appreciated" ask only
    /// with what they ask for.
    private static let requestObject = #"(?:advice|feedback|help|thoughts?|input|guidance|comments?|suggestions?|pointers?|insights?|views?|recommendations?|reply|response|answer|confirmation|information)"#
    private static let passageRequestPatterns = requestPatterns.filter { $0 != questionWordPattern } + [
        #"(?:^|[.!?:;]\s+)(?:what|when|where|who|how)(?:\s+(?:long|many|much|often|soon))?\s+(?:is|are|was|were|do|does|did|can|could|would|will|should|shall|may|might|works?|suits?|about)\b(?![^.!?,;]*\b(?:is|was)\b)"#,
        #"(?:^|[.!?:;]\s+)which\s+\w+\s+(?:works?|suits?|would|should|do|does|is)\b"#,
        #",\s+(?:what|when|where|how)\s+(?:is|are|do|does|can|could|would|will|should)\b(?![^.!?,;]*\b(?:is|was)\b)"#,
        #"\bkindly\s+(?:advise|confirm|send|provide|share|reply|respond|review|return|submit|complete|sign|check|verify|let\s+(?:me|us)\s+know|inform\s+(?:me|us)|tell\s+(?:me|us)|(?:ask|request)\s+(?:that\s+)?you)\b"#,
        #"(?:^|[.!?]\s+)(?:please\s+)?tell\s+(?:me|us)\b"#,
        #"\bi\s+need\s+to\s+know\b"#,
        #"\bi(?:\s+would|['’]d)\s+(?:like|love)\s+to\s+know\b"#,
        #"\blook\s+forward\s+to\s+your\s+(?:reply|response|answer|thoughts|advice|views)\s+(?:on|about|regarding)\b"#,
        #"\b(?:was|were|am|are)\s+wondering\s+(?:if|whether)\b"#,
        #"\bwondered\s+(?:if|whether)\b"#,
        #"\bwonder(?:ing)?\s+(?:if|whether)\b[^.!?]*\byou\b"#,
        #"\b(?:ask|inquire|enquire)\s+(?:if|whether)\b"#,
        #"\b(?:would|['’]d)\s+(?:(?:be|sincerely|really|greatly|truly|very|so|most|extremely|deeply|incredibly|much|immensely)\s+){0,3}(?:grateful|appreciate)\s+(?:(?:it\s+)?if\s+you\s+(?:could|would|can|might)\s+\w+|anything\b|(?:(?:for|to\s+(?:hear|receive|have))\s+)?(?:any|your|some)\s+(?:\w+\s+){0,2}"# + requestObject + #"\b)"#,
        #"\bany\s+(?:\w+\s+)?"# + requestObject + #"\b[^.!?]{0,40}\b(?:appreciated|welcome)\b"#,
        #"\bit\s+would\s+be\s+(?:great|helpful|wonderful|nice|good)\s+if\s+you\b"#,
        #"\binvit(?:e|ing)\s+you\s+to\b"#,
        #"\bwould\s+love\s+(?:the\s+(?:opportunity|chance)\s+)?to\b[^.!?]*\b(?:you|your)\b"#,
        #"\b(?:writing|like|wish)\s+to\s+(?:request|ask|inquire|enquire)\b"#,
        #"\byour\s+(?:\w+\s+)?"# + requestObject + #"\s+would\s+be\s+(?:\w+\s+){0,2}(?:appreciated|welcome)\b"#,
        #"\blook\s+forward\s+to\s+(?:hearing|receiving|reading|getting)\s+(?:your|any)\s+(?:\w+\s+)?"# + requestObject + #"\b"#
    ]

    /// Whether a short ask refers back to what was just said ("Is that all
    /// right?", "それでも宜しいですか？").
    static func matchesBackReference(_ text: String) -> Bool {
        matchesAny([#"\b(?:that|this|it)\b"#, #"(?:それ|これ|その|この|そう)"#], in: text.lowercased(), failureValue: false)
    }

    /// Whether a request is answered by a decision, yes or no, in a form
    /// whose Yes says what the author decided: "Could you supervise my
    /// thesis?", "Will you join the panel?", "We would like to invite you
    /// to…", "ご確認いただけますでしょうか". A request for information, a
    /// choice between alternatives or one holding a question word is answered
    /// in the author's words (a bare "Yes" to "let me know your availability"
    /// would leave the writer to invent it), and so is a request in a
    /// language without rules here.
    static func isYesNoAsk(_ text: String) -> Bool {
        let prose = text.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).lowercased()
        if containsJapanese(prose) {
            let asksYesNo = matchesAny([#"(?:でしょうか|ますか|ませんか|ですか(?!ら)|いただけますか|いただけませんか)"#], in: prose, failureValue: false)
            let open = matchesAny([#"(?:いつ(?!も)|何(?!卒|か|とぞ)|なに|なん|どこ|どちら|どれ|どの|どなた|どんな|誰|だれ|どう(?!ぞ|も)|いかが|如何|いくつ|いくら|幾ら|なぜ)"#,
                                   #"(?:知らせ|教え|送っ|送り|共有|ご連絡|日程|日時|候補|ご都合)"#, #"か、"#],
                                  in: prose, failureValue: true)
            return asksYesNo && !open
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard recognizer.dominantLanguage == .english else { return false }
        let decides = matchesAny([
            #"\b(?:can|could|would|will|may|might|shall|should|do|does|did|are|is|was|were|have|has)\s+(?:i|you|we|it|this|that|there|the|these|those|my|your|our|he|she|they)\b"#,
            #"\binvit(?:e|ing)\s+you\s+to\b"#,
            #"\bwould\s+love\s+(?:the\s+(?:opportunity|chance)\s+)?to\b[^.!?]*\b(?:you|your)\b"#,
            #"\b(?:wonder(?:ed|ing)?|ask|inquire|enquire)\s+(?:if|whether)\s+you\b"#,
            #"\blet\s+(?:me|us)\s+know\s+(?:if|whether)\b"#,
            #"\bwriting\s+to\s+(?:request|ask)\b"#
        ], in: prose, failureValue: false)
        let open = matchesAny([
            #"\b(?:what|when|where|which|who|whom|whose|how|why)\b"#,
            #"\bor\b"#,
            #"\byou\s+(?:please\s+)?(?:send|share|provide|tell|give|suggest|recommend|advise|list|explain|describe|clarify|forward)\b"#,
            #"\blet\s+(?:me|us)\s+know\s+(?!(?:if|whether)\b)"#
        ], in: prose, failureValue: true)
        return decides && !open
    }

    /// Whether a passage of the incoming email asks the author something: a
    /// question mark, or an English or Japanese request outside a standing
    /// offer.
    static func isRequest(_ text: String) -> Bool {
        // A link's query string is not a question.
        let prose = text.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        if prose.contains("?") || prose.contains("？") { return true }
        guard let rest = outsideOffers(prose) else { return true }
        return matchesAny(passageRequestPatterns, in: rest.trimmingCharacters(in: .whitespaces), failureValue: false)
            || matchesAny(japaneseRequestPatterns, in: rest, failureValue: false)
    }

    /// A passage, lowercased, with its standing offers taken out; nil when
    /// an offer shares its verb with an ask joined to it.
    private static func outsideOffers(_ prose: String) -> String? {
        var normalized = prose.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).lowercased()
        for (expression, joined) in courtesyOfferExpressions {
            let whole = NSRange(normalized.startIndex..., in: normalized)
            // An offer that shares its verb with an ask joined to it
            // ("let me know if you need anything else and when you'd like
            // to meet") asks.
            let join: NSRegularExpression? = switch joined {
            case .nothing: nil
            case .ask: joinedAsk
            case .action: joinedAction
            }
            if let join {
                for match in expression.matches(in: normalized, range: whole) {
                    let after = NSRange(location: match.range.upperBound, length: whole.upperBound - match.range.upperBound)
                    if join.firstMatch(in: normalized, options: [.anchored], range: after) != nil { return nil }
                }
            }
            normalized = expression.stringByReplacingMatches(in: normalized, range: whole, withTemplate: " ")
        }
        return normalized
    }

    /// Japanese when kana make up a real share of the letters: a katakana
    /// name inside an English note does not make it Japanese.
    static func containsJapanese(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }
        return !kana.isEmpty && kana.count * 5 >= letters.count
    }

    /// The same rule for a Japanese note: short, informational by triage, no
    /// question, link or attachment, no request, and every sentence either a
    /// closed loop (thanks, acknowledgment, receipt, apology) or its envelope.
    private static func japaneseMode(body: String, hasAttachments: Bool,
                                     triageVerdict: TriageVerdict?) -> ComposerReplySourceMode {
        guard !body.isEmpty,
              body.count <= maximumMinimalBodyCharacters,
              !hasAttachments,
              !containsURL(body),
              !body.contains("?"), !body.contains("？"),
              let triageVerdict,
              !triageVerdict.isActionable,
              !triageVerdict.requiresConfirmation,
              triageVerdict.action == nil else { return .grounded }
        var lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first, matchesAny([japaneseSalutationPattern], in: first, failureValue: false) {
            lines.removeFirst()
        }
        if lines.count > 1, let last = lines.last,
           matchesAny([japaneseSignatureNamePattern], in: last, failureValue: false) {
            lines.removeLast()
        }
        let sentences = lines.joined(separator: "\n")
            .split { $0.isNewline || "。！!".contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty,
              !matchesAny(japaneseRequestPatterns, in: sentences.joined(separator: "\n"), failureValue: true) else {
            return .grounded
        }
        var closesLoop = false
        for sentence in sentences {
            if matchesAny(japaneseEnvelopeSentencePatterns, in: sentence, failureValue: false) { continue }
            guard japaneseClosedLoopCues.contains(where: sentence.contains),
                  matchesAny(japaneseClosedLoopSentencePatterns, in: sentence, failureValue: false) else {
                return .grounded
            }
            closesLoop = true
        }
        return closesLoop ? .minimal : .grounded
    }

    private static func containsURL(_ body: String) -> Bool {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return true
        }
        let range = NSRange(body.startIndex..., in: body)
        return detector.matches(in: body, options: [], range: range).contains { result in
            result.resultType == .link
        }
    }

    private static func containsRequestCue(_ body: String) -> Bool {
        matchesAny(requestPatterns, in: body, failureValue: true)
    }

    private static func containsClosedLoopCue(_ body: String) -> Bool {
        matchesAny(closedLoopPatterns, in: body, failureValue: false)
    }

    private static func hasOnlyCompleteClosedLoopSentences(
        _ body: String,
        correspondentName: String?
    ) -> Bool {
        guard let bodyWithoutSalutation = strippingOptionalSalutation(from: body) else {
            return false
        }
        guard let substantiveBody = strippingOptionalSignoff(
            from: bodyWithoutSalutation,
            correspondentName: correspondentName
        ) else {
            return false
        }
        let clauses = substantiveBody
            .split { character in
                character.isNewline || character == "." || character == "!" || character == "?"
            }
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .lowercased()
            }
            .filter { !$0.isEmpty }

        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { clause in
            containsClosedLoopCue(clause)
                && matchesAny(completeClosedLoopSentencePatterns, in: clause, failureValue: false)
        }
    }

    private static func strippingOptionalSalutation(from body: String) -> String? {
        var lines = body.components(separatedBy: .newlines)
        guard let firstContentIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return body
        }
        let firstLine = lines[firstContentIndex]
        guard let expression = try? NSRegularExpression(
            pattern: salutationPrefixPattern,
            options: []
        ) else {
            return nil
        }
        let firstLineRange = NSRange(firstLine.startIndex..., in: firstLine)
        guard let match = expression.firstMatch(
            in: firstLine,
            options: [],
            range: firstLineRange
        ) else {
            return body
        }
        guard let salutationRange = Range(match.range, in: firstLine) else {
            return nil
        }
        lines[firstContentIndex] = String(firstLine[salutationRange.upperBound...])
        return lines.joined(separator: "\n")
    }

    private static func strippingOptionalSignoff(
        from body: String,
        correspondentName: String?
    ) -> String? {
        var lines = body.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        guard let nameIndex = lines.indices.last else { return body }
        let name = lines[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(
            pattern: signoffNamePattern,
            options: []
        ) else {
            return nil
        }
        let nameRange = NSRange(name.startIndex..., in: name)
        guard expression.firstMatch(in: name, options: [], range: nameRange)?.range == nameRange else {
            return body
        }
        guard signoffName(name, matches: correspondentName) else {
            return body
        }
        guard let signoffIndex = lines.indices
            .filter({ $0 < nameIndex })
            .last(where: {
                !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
            return body
        }
        let signoff = lines[signoffIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard recognizedSignoffs.contains(signoff) else {
            return body
        }
        lines.removeSubrange(signoffIndex...)
        return lines.joined(separator: "\n")
    }

    private static func signoffName(
        _ signoffName: String,
        matches correspondentName: String?
    ) -> Bool {
        guard let correspondentName else { return false }
        let signoffTokens = nameTokens(signoffName)
        let correspondentTokens = nameTokens(correspondentName)
        return !signoffTokens.isEmpty
            && signoffTokens.isSubset(of: correspondentTokens)
            && signoffTokens.isDisjoint(with: unsafeSignoffTokens)
            && isPersonalName(signoffName)
    }

    private static func nameTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
        )
    }

    /// Whether a sign-off reads as a person's name ("Grace", "Taylor
    /// Grace Lin"), not a sender that is a command ("Send Report", "RSVP
    /// ASAP"). Read by the system's name recognition, as written: a lone
    /// word's word class is a guess that changes with the language data a
    /// Mac happens to hold ("gracia" is a Spanish noun).
    private static func isPersonalName(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = candidate
        let range = candidate.startIndex..<candidate.endIndex
        tagger.setLanguage(.english, range: range)
        var sawToken = false
        var allNames = true
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, _ in
            sawToken = true
            // A name as the system knows it: a person's, or one it takes for
            // a place or organization (Kim, Hana, Morgan); never a word.
            guard tag == .personalName || tag == .placeName || tag == .organizationName else {
                allNames = false
                return false
            }
            return true
        }
        return sawToken && allNames
    }

    private static func matchesAny(
        _ patterns: [String],
        in body: String,
        failureValue: Bool
    ) -> Bool {
        let range = NSRange(body.startIndex..., in: body)
        var expressions: [NSRegularExpression] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return failureValue
            }
            expressions.append(expression)
        }
        return expressions.contains {
            $0.firstMatch(in: body, options: [], range: range) != nil
        }
    }
}
