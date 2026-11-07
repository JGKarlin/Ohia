import Foundation
import OhiaCore

enum TriageVerdictPolicy {
    enum DeliveryPriority: Sendable {
        case direct
        case copied
        case low
        case unknown
    }

    /// Header and recipient facts used by triage. These are deterministic
    /// inputs, not generated categories and are never persisted as taxonomy.
    struct DeliveryFacts: Sendable {
        var priority: DeliveryPriority
        var isMailingListOrBulk: Bool
        var isAutomated: Bool

        static let unknown = DeliveryFacts(
            priority: .unknown,
            isMailingListOrBulk: false,
            isAutomated: false
        )
    }

    static func normalizedForAttention(
        _ verdict: TriageVerdict,
        purpose: MailPurpose?,
        senderAddress: String,
        senderName: String?,
        subject: String,
        bodyText: String? = nil,
        deliveryFacts: DeliveryFacts = .unknown
    ) -> TriageVerdict {
        if isGmailReactionOnlyAcknowledgement(bodyText) {
            return noAttentionVerdict(from: verdict)
        }

        let sourceText = sourceEvidenceText(subject: subject, bodyText: bodyText)
        if (verdict.isActionable || verdict.requiresConfirmation),
           isLowPriorityDelivery(
               purpose: purpose,
               deliveryFacts: deliveryFacts
           ),
           !containsDirectReplyCue(sourceText) {
            return noAttentionVerdict(from: verdict)
        }

        if isConversationalAcknowledgementOnly(bodyText, senderName: senderName) {
            let acknowledgement = verdict.requiresConfirmation
                ? (verdict.acknowledgement ?? acknowledgementForDemotedAction(
                    verdict,
                    purpose: purpose,
                    subject: subject
                ))
                : nil
            return TriageVerdict(
                isActionable: false,
                requiresConfirmation: verdict.requiresConfirmation,
                confidence: verdict.confidence,
                action: nil,
                acknowledgement: acknowledgement,
                extractionVersion: verdict.extractionVersion
            )
        }

        guard verdict.isActionable,
              shouldDemoteReplyObligation(
                verdict,
                purpose: purpose,
                senderAddress: senderAddress,
                senderName: senderName,
                subject: subject,
                bodyText: bodyText,
                deliveryFacts: deliveryFacts
              ) else {
            return verdict
        }

        let synthesizedAcknowledgement = acknowledgementForDemotedAction(
            verdict,
            purpose: purpose,
            subject: subject
        )
        let acknowledgement = verdict.acknowledgement ?? synthesizedAcknowledgement
        return TriageVerdict(
            isActionable: false,
            requiresConfirmation: verdict.requiresConfirmation || acknowledgement != nil,
            confidence: verdict.confidence,
            action: nil,
            acknowledgement: acknowledgement,
            extractionVersion: verdict.extractionVersion
        )
    }

    private static func shouldDemoteReplyObligation(
        _ verdict: TriageVerdict,
        purpose: MailPurpose?,
        senderAddress: String,
        senderName: String?,
        subject: String,
        bodyText: String?,
        deliveryFacts: DeliveryFacts
    ) -> Bool {
        guard let action = verdict.action else {
            return false
        }
        if action.directedAt == .thirdParty {
            return true
        }

        let text = attentionEvidenceText(
            verdict,
            senderAddress: senderAddress,
            senderName: senderName,
            subject: subject,
            bodyText: bodyText
        )
        if containsDirectReplyCue(text) {
            return false
        }
        if isLowPriorityDelivery(
            purpose: purpose,
            deliveryFacts: deliveryFacts
        ) {
            return true
        }
        if deliveryFacts.priority == .copied, action.directedAt != .user {
            return true
        }
        if isWeakUnevidencedOtherAction(verdict) {
            return true
        }
        if isBroadcastConfirmation(verdict) {
            return true
        }
        if isPromotionalOrNewsletterCTA(purpose: purpose, text: text) {
            return true
        }
        if deliveryFacts.isAutomated,
           isSelfServiceOrInstitutionalAction(purpose: purpose, text: text) {
            return true
        }
        if isSelfServiceOrInstitutionalAction(purpose: purpose, text: text) {
            switch action.kind {
            case .review, .makeDecision, .other:
                return true
            case .reply, .provideInformation, .scheduleMeeting, .signOff:
                return false
            }
        }
        return false
    }

    private static func noAttentionVerdict(from verdict: TriageVerdict) -> TriageVerdict {
        TriageVerdict(
            isActionable: false,
            requiresConfirmation: false,
            confidence: verdict.confidence,
            action: nil,
            acknowledgement: nil,
            extractionVersion: verdict.extractionVersion
        )
    }

    private static func attentionEvidenceText(
        _ verdict: TriageVerdict,
        senderAddress: String,
        senderName: String?,
        subject: String,
        bodyText: String?
    ) -> String {
        combinedText(
            senderAddress,
            senderName,
            subject,
            verdict.action?.summary,
            verdict.action?.decisionInputs.joined(separator: " "),
            verdict.acknowledgement?.summary,
            verdict.acknowledgement?.materialFacts.joined(separator: " "),
            bodyText.flatMap { OriginalMessageText.cleaned(from: $0, characterLimit: 1_200) }
        )
    }

    private static func sourceEvidenceText(subject: String, bodyText: String?) -> String {
        combinedText(
            subject,
            bodyText.flatMap { OriginalMessageText.cleaned(from: $0, characterLimit: 1_200) }
        )
    }

    private static func isLowPriorityDelivery(
        purpose: MailPurpose?,
        deliveryFacts: DeliveryFacts
    ) -> Bool {
        switch deliveryFacts.priority {
        case .low:
            return true
        case .direct:
            return false
        case .copied, .unknown:
            break
        }
        return purpose == .newsletter
            || deliveryFacts.isMailingListOrBulk
    }

    private static func isGmailReactionOnlyAcknowledgement(_ bodyText: String?) -> Bool {
        guard let bodyText else { return false }
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isGmailReactionJSON(trimmed) {
            return true
        }
        let originalText = OriginalMessageText.cleaned(from: trimmed, characterLimit: 1_000) ?? trimmed
        if originalText.localizedCaseInsensitiveContains("emojireactionemail") {
            return true
        }
        guard originalText.count <= 500 else { return false }
        let lines = originalText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count <= 3,
              let firstLine = lines.first?.lowercased(),
              firstLine.hasSuffix("reacted via gmail") else {
            return false
        }
        let reactionPayload = lines.dropFirst().joined()
        guard !reactionPayload.isEmpty else { return true }
        return reactionPayload.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.alphanumerics.contains(scalar)
                || isUnicodeVariationSelector(scalar)
        }
    }

    private static func isGmailReactionJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["emoji"] is String else {
            return false
        }
        let allowedKeys: Set<String> = ["emoji", "version"]
        return object.keys.allSatisfy { allowedKeys.contains($0) }
    }

    private static func isWeakUnevidencedOtherAction(_ verdict: TriageVerdict) -> Bool {
        guard verdict.confidence <= 0.55,
              let action = verdict.action,
              action.kind == .other,
              action.deadline == nil else {
            return false
        }
        return action.evidenceSpans.isEmpty
    }

    private static func isConversationalAcknowledgementOnly(
        _ bodyText: String?,
        senderName: String?
    ) -> Bool {
        guard let bodyText,
              let cleaned = OriginalMessageText.cleaned(from: bodyText, characterLimit: 800) else {
            return false
        }
        var lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 8 else {
            return false
        }

        while let first = lines.first, isGreetingLine(first) {
            lines.removeFirst()
        }
        while let last = lines.last,
              isSignatureOrClosingLine(last, senderName: senderName) {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            return true
        }

        let core = lines.joined(separator: " ")
        guard core.count <= 160,
              !core.contains("?") else {
            return false
        }
        let normalized = normalizedPhrase(core)
        guard !normalized.isEmpty,
              !containsAny(normalized, [
                "can you",
                "could you",
                "would you",
                "please send",
                "please provide",
                "please review",
                "let me know",
                "let us know"
              ]) else {
            return false
        }

        return isAcknowledgementPhrase(normalized)
            || isGreetingPrefixedAcknowledgementPhrase(normalized)
    }

    private static func isAcknowledgementPhrase(_ normalized: String) -> Bool {
        let acknowledgementPhrases: Set<String> = [
            "ack",
            "acknowledged",
            "agreed",
            "all good",
            "all set",
            "confirmed",
            "cool",
            "done",
            "fine by me",
            "good",
            "got it",
            "great",
            "great thanks",
            "looks good",
            "nice",
            "noted",
            "ok",
            "okay",
            "perfect",
            "received",
            "sounds good",
            "sounds good thanks",
            "sounds good to me",
            "sounds great",
            "sounds perfect",
            "sure",
            "thank you",
            "thanks",
            "thanks sounds good",
            "that sounds good",
            "that works",
            "that works for me",
            "understood",
            "will do",
            "works for me",
            "yes"
        ]
        return acknowledgementPhrases.contains(normalized)
    }

    private static func isGreetingPrefixedAcknowledgementPhrase(_ normalized: String) -> Bool {
        let words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first,
              ["hi", "hello", "hey", "dear"].contains(first),
              words.count >= 2 else {
            return false
        }
        let maxDroppedNameWords = min(3, words.count - 1)
        for droppedNameWords in 0...maxDroppedNameWords {
            let startIndex = 1 + droppedNameWords
            guard startIndex < words.count else {
                continue
            }
            let remainder = words[startIndex...].joined(separator: " ")
            if isAcknowledgementPhrase(remainder) {
                return true
            }
        }
        return false
    }

    private static func isGreetingLine(_ line: String) -> Bool {
        let normalized = normalizedPhrase(line)
        let words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first,
              ["hi", "hello", "hey", "dear"].contains(first),
              words.count <= 3 else {
            return false
        }
        let wordSet = Set(words)
        if !wordSet.isDisjoint(with: [
            "can",
            "could",
            "would",
            "please",
            "send",
            "provide",
            "review",
            "choose",
            "confirm"
        ]) {
            return false
        }
        return !containsAny(normalized, [
            "let me know",
            "let us know"
        ])
    }

    private static func isSignatureOrClosingLine(_ line: String, senderName: String?) -> Bool {
        let normalized = normalizedPhrase(line)
        let closings: Set<String> = [
            "best",
            "best regards",
            "cheers",
            "kind regards",
            "regards",
            "sent from my iphone",
            "sincerely",
            "thank you",
            "thanks"
        ]
        if closings.contains(normalized) {
            return true
        }
        guard let senderName else {
            return false
        }
        let sender = normalizedPhrase(senderName)
        guard !sender.isEmpty else {
            return false
        }
        let senderParts = sender.split(separator: " ").map(String.init)
        return normalized == sender
            || senderParts.first == normalized
            || senderParts.last == normalized
    }

    private static func acknowledgementForDemotedAction(
        _ verdict: TriageVerdict,
        purpose: MailPurpose?,
        subject: String
    ) -> AcknowledgementSpec? {
        if let acknowledgement = verdict.acknowledgement {
            return acknowledgement
        }

        let text = combinedText(subject, verdict.action?.summary)
        let signalKind: SignalKind
        if containsAny(text, ["invoice", "payment due", "balance due", "overdue", "amount due", "statement"]) {
            signalKind = .financialAlert
        } else if purpose == .travel
            || containsAny(text, ["booking", "reservation", "itinerary", "trip confirmed", "confirmed trip"]) {
            signalKind = .bookingConfirmation
        } else if containsAny(text, ["app store", "submission", "account", "profile", "settings", "plan changed"]) {
            signalKind = .accountChange
        } else if purpose == .security {
            signalKind = .securityAlert
        } else if purpose == .shipping {
            signalKind = .shippingMilestone
        } else if purpose == .calendar {
            signalKind = .calendarChange
        } else if purpose == .verificationCode {
            signalKind = .verificationCode
        } else {
            return nil
        }

        let summary = verdict.action?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let acknowledgementSummary = (summary?.isEmpty == false ? summary : fallback)
            ?? fallback
        guard acknowledgementSummary.isEmpty == false else {
            return nil
        }
        return AcknowledgementSpec(
            summary: acknowledgementSummary,
            signalKind: signalKind,
            materialFacts: [fallback].filter { !$0.isEmpty }
        )
    }

    private static func isBroadcastConfirmation(_ verdict: TriageVerdict) -> Bool {
        guard verdict.requiresConfirmation,
              let acknowledgement = verdict.acknowledgement else {
            return false
        }
        switch acknowledgement.signalKind {
        case .bookingConfirmation, .deliveryConfirmation, .shippingMilestone:
            return true
        default:
            return false
        }
    }

    private static func isPromotionalOrNewsletterCTA(
        purpose: MailPurpose?,
        text: String
    ) -> Bool {
        switch purpose {
        case .promotion, .newsletter:
            return true
        default:
            break
        }
        return containsAny(text, [
            "open house",
            "join us",
            "attend",
            "book a free consultation",
            "free consultation",
            "subscribe",
            "shop now",
            "read more",
            "claim the offer",
            "discount",
            "limited time",
            "limited-time",
            "sale"
        ])
    }

    private static func isSelfServiceOrInstitutionalAction(
        purpose: MailPurpose?,
        text: String
    ) -> Bool {
        switch purpose {
        case .receipt, .promotion, .newsletter, .verificationCode, .notification,
             .security, .shipping, .travel, .finance, .calendar:
            break
        case .correspondence, .announcement, .support, .legal,
             .socialActivity, .other, .none:
            return false
        }
        return containsAny(text, [
            "review your itinerary",
            "review the itinerary",
            "review your reservation",
            "review the reservation",
            "review your trip",
            "confirm your travel",
            "confirm your trip",
            "confirm your flight",
            "manage your booking",
            "manage your reservation",
            "modify or cancel",
            "change or cancel",
            "view or modify",
            "pay the invoice",
            "pay invoice",
            "payment due",
            "balance due",
            "overdue invoice",
            "resolve issues",
            "resolve submission",
            "submission issue",
            "app review",
            "app store connect",
            "log in",
            "sign in",
            "visit the portal",
            "open the app",
            "download",
            "attend the open house",
            "book a consultation"
        ])
    }

    private static func containsDirectReplyCue(_ text: String) -> Bool {
        if containsAny(text, [
            "do not reply",
            "don't reply",
            "please do not reply",
            "not monitored"
        ]) {
            return false
        }
        return containsAny(text, [
            "please reply",
            "reply with",
            "reply to",
            "reply by",
            "respond with",
            "please respond",
            "respond by",
            "respond to this",
            "could you send",
            "can you send",
            "please send",
            "send your",
            "could you choose",
            "can you choose",
            "please choose",
            "please provide",
            "provide your",
            "please approve",
            "please review and reply",
            "please review and send",
            "please confirm whether",
            "please email",
            "email me",
            "email us",
            "report back",
            "write back",
            "let me know",
            "let us know",
            "send me",
            "send us",
            "confirm receipt",
            "return the signed",
            "sign and return"
        ])
    }

    private static func combinedText(_ parts: String?...) -> String {
        parts.compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func isUnicodeVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value)
            || (0xE0100...0xE01EF).contains(scalar.value)
    }

    private static func normalizedPhrase(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
