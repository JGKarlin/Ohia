import Foundation
import OhiaCore
import OhiaMail

/// Human-readable and technical signal strings for withheld (Junk/Trash) rows.
/// Ledger rows use `ledgerLine`; detail view uses `inspector` for the full breakdown.
enum WithheldSignals {

    // MARK: - Ledger (one friendly line)

    /// Feedback/rescue-first summary for a ledger row — plain language, one idea.
    ///
    /// Ranked by explicit user feedback first, then rescue relevance: a message
    /// similar to mail the user restored or marked as spam is stronger evidence
    /// than provider headers. Corpus-derived signals (known contact, subscribed
    /// list) follow; header-derived signals (mailing list, spam, sender
    /// verification) come after. The row already shows the message age top-right,
    /// so trash rows never repeat it as a "deleted N ago" line; only Junk carries
    /// a default ("Marked as junk") since for Trash the "why it's here" is
    /// self-evident from scope.
    ///
    /// - Parameters:
    ///   - knownSenderAddresses: lowercased addresses of corpus correspondents.
    ///   - subscribedListKeys: account-scoped subscription keys, one per
    ///     currently-subscribed list, built via ``subscriptionKey(accountID:listId:)``.
    ///     `MailingList` identities never cross accounts, so the match is keyed
    ///     by `(accountID, listId)` — a list subscribed on one account never
    ///     tags a withheld row in another account.
    /// Account-scoped key for a subscribed list. `listId` must already be
    /// lowercased (the canonical `MailingList.listId` form).
    static func subscriptionKey(accountID: UUID, listId: String) -> String {
        "\(accountID.uuidString)|\(listId)"
    }

    static func ledgerLine(
        for row: WithheldRow,
        knownSenderAddresses: Set<String> = [],
        subscribedListKeys: Set<String> = [],
        spamFeedbackScore: MailboxSpamFeedbackScore? = nil,
        effectiveSpamScore: Double? = nil,
        revealsSpamScore: Bool = false
    ) -> String? {
        let line: String?
        let sender = row.senderAddress.lowercased()
        if let feedback = spamFeedbackScore, feedback.favorsHam {
            line = "Similar restored before"
        } else if let feedback = spamFeedbackScore, feedback.favorsSpam {
            line = "Similar marked spam before"
        } else if !sender.isEmpty, knownSenderAddresses.contains(sender) {
            line = "From a known contact"
        } else if let listId = row.listId?.lowercased() {
            if subscribedListKeys.contains(subscriptionKey(accountID: row.accountID, listId: listId)) {
                line = "Subscribed list"
            } else {
                line = "Mailing list"
            }
        } else if let spam = spamScoreLabel(row.spamScore) {
            line = spam
        } else if let auth = authSummary(row.authResults) {
            line = auth
        } else if row.folder == .junk {
            line = "Marked as junk"
        } else {
            line = nil
        }

        guard revealsSpamScore else { return line }
        return appendSpamScore(
            to: line,
            providerScore: row.spamScore,
            feedbackScore: spamFeedbackScore,
            effectiveScore: effectiveSpamScore
        )
    }

    // MARK: - Detail inspector (technical breakdown)

    /// Full decomposed signal set for the contested-inscription detail pane.
    static func inspector(for row: WithheldRow) -> [String] {
        var signals = authVerdicts(row.authResults)
        if let score = row.spamScore {
            signals.append(String(format: "X-Spam: %.1f", score))
        }
        if row.listId != nil {
            signals.append("Mailing list")
        }
        return signals
    }

    // MARK: - Step 1 — auth summary

    static func authSummary(_ authResults: String?) -> String? {
        let spf = mechanismResult("spf", in: authResults)
        let dkim = mechanismResult("dkim", in: authResults)
        let dmarc = mechanismResult("dmarc", in: authResults)

        if spf == "fail" || spf == "softfail" { return "Unverified sender" }
        if dkim == "fail" || dkim == "softfail" { return "Unverified sender" }
        if dmarc == "fail" || dmarc == "softfail" { return "Unverified sender" }

        if spf == "pass", dkim == "pass" { return "Sender verified" }
        if spf == "pass" || dkim == "pass" { return "Sender verified" }
        return nil
    }

    /// SPF/DKIM/DMARC verdicts parsed from the raw Authentication-Results value.
    static func authVerdicts(_ authResults: String?) -> [String] {
        guard let raw = authResults?.lowercased() else { return [] }
        var out: [String] = []
        for mech in ["spf", "dkim", "dmarc"] {
            guard let result = mechanismResult(mech, in: raw) else { continue }
            out.append("\(mech.uppercased()): \(result)")
        }
        return out
    }

    // MARK: - Step 2 — spam buckets

    static func spamScoreLabel(_ score: Double?) -> String? {
        guard let score else { return nil }
        if score >= 7 { return "Very likely spam" }
        if score >= 4 { return "Borderline spam score" }
        return "Low spam score"
    }

    static func spamScoreValue(_ score: Double?) -> String {
        guard let score else { return "No spam score" }
        return String(format: "X-Spam: %.1f", score)
    }

    private static func appendSpamScore(
        to line: String?,
        providerScore: Double?,
        feedbackScore: MailboxSpamFeedbackScore?,
        effectiveScore: Double?
    ) -> String? {
        guard let spamScore = spamScoreExpression(
            providerScore: providerScore,
            feedbackScore: feedbackScore,
            effectiveScore: effectiveScore
        ) else {
            return line
        }
        guard let line, !line.isEmpty else { return spamScore }
        return "\(line) · \(spamScore)"
    }

    private static func spamScoreExpression(
        providerScore: Double?,
        feedbackScore: MailboxSpamFeedbackScore?,
        effectiveScore: Double?
    ) -> String? {
        let adjustment = feedbackScore?.adjustment ?? 0
        if abs(adjustment) > 0.05 {
            let local = String(format: "%+.1f", adjustment)
            if let providerScore {
                let effective = effectiveScore ?? providerScore + adjustment
                return String(format: "X-Spam: %.1f · local %@ -> %.1f", providerScore, local, effective)
            }
            return "Local spam weight: \(local)"
        }
        guard let providerScore else { return nil }
        return String(format: "X-Spam: %.1f", providerScore)
    }

    // MARK: - Parsing

    private static func mechanismResult(_ mech: String, in authResults: String?) -> String? {
        guard let raw = authResults?.lowercased(),
              let range = raw.range(of: mech + "=") else { return nil }
        let token = raw[range.upperBound...].prefix { $0.isLetter }
        return token.isEmpty ? nil : String(token)
    }
}
