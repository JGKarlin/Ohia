import Foundation
import OhiaCore

public struct SensitivityEvidence: Sendable, Equatable {
    public let claimText: String
    public let evidenceTexts: [String]
    public let triageSignalKind: SignalKind?
    public let purpose: MailPurpose?
    public let senderAddress: String

    public init(
        claimText: String,
        evidenceTexts: [String],
        triageSignalKind: SignalKind?,
        purpose: MailPurpose?,
        senderAddress: String
    ) {
        self.claimText = claimText
        self.evidenceTexts = evidenceTexts
        self.triageSignalKind = triageSignalKind
        self.purpose = purpose
        self.senderAddress = senderAddress
    }
}

/// Evidence-native sensitivity classification for produced account-memory
/// claims. Sensitive claims require stronger evidence and remain excluded
/// from Draft and Ask until the user explicitly confirms them.
public struct SensitivityGate: Sendable {
    public init() {}

    public func evaluate(_ evidence: SensitivityEvidence) -> SensitivityVerdict {
        var maxRisk: SensitivityRisk = .none
        var reasons: [SensitivityReason] = []

        let piiTexts = [evidence.claimText] + evidence.evidenceTexts
        if piiTexts.contains(where: Self.containsPIIPattern) {
            maxRisk = .high
            reasons.append(.piiPattern)
        }

        if let signal = evidence.triageSignalKind {
            let mapped = sensitivityRisk(forSignalKind: signal)
            if mapped.rank > maxRisk.rank {
                maxRisk = mapped
            }
            if mapped != .none {
                reasons.append(.triageSignal(signal))
            }
        }

        if let purpose = evidence.purpose {
            let mapped = sensitivityRisk(forPurpose: purpose)
            if mapped.rank > maxRisk.rank {
                maxRisk = mapped
            }
            if mapped != .none {
                reasons.append(.purpose(purpose))
            }
        }

        if let domain = Self.senderDomain(from: evidence.senderAddress) {
            if Self.matchesRegulatedDomain(domain, in: Self.legalDomains) {
                if SensitivityRisk.elevated.rank > maxRisk.rank { maxRisk = .elevated }
                reasons.append(.senderDomain(domain, .legal))
            }
            if Self.matchesRegulatedDomain(domain, in: Self.financialDomains) {
                if SensitivityRisk.elevated.rank > maxRisk.rank { maxRisk = .elevated }
                reasons.append(.senderDomain(domain, .financial))
            }
        }

        return SensitivityVerdict(risk: maxRisk, reasons: reasons)
    }

    // MARK: - Mappings

    private func sensitivityRisk(forSignalKind kind: SignalKind) -> SensitivityRisk {
        switch kind {
        case .legalDeadline, .verificationCode:       return .high
        case .financialAlert:                         return .elevated
        case .securityAlert:                          return .elevated
        case .accountChange:                          return .low
        case .calendarChange, .shippingMilestone,
             .bookingConfirmation, .deliveryConfirmation, .other:
            return .none
        }
    }

    private func sensitivityRisk(forPurpose purpose: MailPurpose) -> SensitivityRisk {
        switch purpose {
        case .legal, .finance, .security:
            return .elevated
        case .correspondence, .announcement, .receipt, .promotion, .newsletter,
             .verificationCode, .notification, .shipping, .travel, .calendar,
             .support, .socialActivity, .other:
            return .none
        }
    }

    private static let legalDomains: Set<String> = [
        "law", "legal", "lawfirm.com", "counsel.com"
    ]
    private static let financialDomains: Set<String> = [
        "bank", "wellsfargo.com", "chase.com", "bofa.com", "americanexpress.com"
    ]

    private static func senderDomain(from address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let suffix = address[address.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let domain = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }
        return domain.isEmpty ? nil : String(domain)
    }

    private static func matchesRegulatedDomain(
        _ candidate: String,
        in regulatedDomains: Set<String>
    ) -> Bool {
        regulatedDomains.contains { regulated in
            candidate == regulated || candidate.hasSuffix("." + regulated)
        }
    }

    /// Heuristic PII detector — credit card-like sequences, SSN-like
    /// sequences, bare email addresses inside the claim text itself. This
    /// is intentionally crude; the LLM pass refines it.
    private static func containsPIIPattern(_ text: String) -> Bool {
        let creditCard = #"\b(?:\d[ -]?){13,19}\b"#
        let ssn = #"\b\d{3}-\d{2}-\d{4}\b"#
        let email = #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
        for pattern in [creditCard, ssn, email] {
            if (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }
}

public struct SensitivityVerdict: Sendable, Equatable {
    public let risk: SensitivityRisk
    public let reasons: [SensitivityReason]
    public let requiresExplicitConfirmation: Bool
    public let minSupportingMessageCount: Int
    public let minDistinctParticipantCount: Int
    public let conflictPenaltyMultiplier: Double
    public let redactClaimPreview: Bool

    public init(
        risk: SensitivityRisk,
        reasons: [SensitivityReason],
        requiresExplicitConfirmation: Bool,
        minSupportingMessageCount: Int,
        minDistinctParticipantCount: Int,
        conflictPenaltyMultiplier: Double,
        redactClaimPreview: Bool
    ) {
        self.risk = risk
        self.reasons = reasons
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
        self.minSupportingMessageCount = minSupportingMessageCount
        self.minDistinctParticipantCount = minDistinctParticipantCount
        self.conflictPenaltyMultiplier = conflictPenaltyMultiplier
        self.redactClaimPreview = redactClaimPreview
    }

    public init(risk: SensitivityRisk, reasons: [SensitivityReason] = []) {
        self.init(
            risk: risk,
            reasons: reasons,
            requiresExplicitConfirmation: risk.rank >= SensitivityRisk.elevated.rank,
            minSupportingMessageCount: risk == .high ? 3 : (risk == .elevated ? 2 : 1),
            minDistinctParticipantCount: risk == .high ? 3 : (risk == .elevated ? 2 : 1),
            conflictPenaltyMultiplier: risk.conflictPenaltyMultiplier,
            redactClaimPreview: risk == .high
        )
    }

    public static let clean = SensitivityVerdict(risk: .none)
}

public enum SensitivityReason: Sendable, Equatable {
    case triageSignal(SignalKind)
    case purpose(MailPurpose)
    case senderDomain(String, SenderDomainKind)
    case piiPattern
}

public enum SenderDomainKind: String, Sendable, Equatable {
    case legal
    case financial
}

public extension SensitivityRisk {
    var rank: Int {
        switch self {
        case .none:     return 0
        case .low:      return 1
        case .elevated: return 2
        case .high:     return 3
        }
    }

    /// Multiplier applied to `conflictPenalty` in `ClaimWeightingEngine`
    /// so sensitive contradictions sort to the top of Open Loops.
    var conflictPenaltyMultiplier: Double {
        switch self {
        case .none:     return 1.0
        case .low:      return 1.1
        case .elevated: return 1.4
        case .high:     return 1.8
        }
    }
}
