import Foundation

public struct ModelClassificationCandidates: Codable, Sendable, Equatable {
    public var purposes: [MailPurposeCandidate]
    public var classifierVersion: String

    public init(
        purposes: [MailPurposeCandidate],
        classifierVersion: String = MailClassification.defaultClassifierVersion
    ) {
        self.purposes = purposes
        self.classifierVersion = classifierVersion
    }

    public static let empty = ModelClassificationCandidates(purposes: [])
}

public struct DeterministicMailEvidence: Codable, Sendable, Equatable {
    public var ruleIDs: [String]

    public init(ruleIDs: [String] = []) {
        self.ruleIDs = ruleIDs
    }

    public static let empty = DeterministicMailEvidence()
}

public enum MailClassificationResolver {
    public static let purposeThreshold = 0.65
    public static let purposeMarginThreshold = 0.12
    public static let structuralPurposeThreshold = 0.90
    public static let resolverVersion = "mail-purpose-resolver-v3"

    public static func necessaryPurposeRuleID(for purpose: MailPurpose) -> String? {
        MailClassificationRuleInventory.necessaryPurposeRuleID[purpose]
    }

    /// A model purpose is qualified only by its exact necessary-condition rule.
    /// Sharing this check with ingestion prevents malformed evidence from being
    /// stored as a successful low-confidence interpretation.
    public static func hasNecessaryPurposeEvidence(_ candidate: MailPurposeCandidate) -> Bool {
        guard let ruleID = MailClassificationRuleInventory.necessaryPurposeRuleID[candidate.purpose]
        else { return false }
        return candidate.ruleIDs.contains(ruleID)
    }

    public static func resolve(
        model: ModelClassificationCandidates,
        deterministic: DeterministicMailEvidence = .empty
    ) -> MailClassification {
        let purposeCandidates = mergedPurposeCandidates(model.purposes)
        let deterministicRuleIDs = Set(
            deterministic.ruleIDs.filter(MailClassificationRuleInventory.isCanonical)
        )
        let resolvedPurpose = resolvePurpose(
            candidates: purposeCandidates,
            deterministicRuleIDs: deterministicRuleIDs
        )
        let evidence = buildEvidence(
            purposeCandidates: purposeCandidates,
            deterministicRuleIDs: deterministicRuleIDs
        )

        let status: MailClassificationStatus
        if resolvedPurpose == nil {
            status = .uncertain
        } else if purposeCandidates.isEmpty,
                  deterministicRuleIDs.contains(where: {
                      MailClassificationRuleInventory.purposeByRuleID[$0] != nil
                  }) {
            status = .deterministicFallback
        } else {
            status = .classified
        }

        return MailClassification(
            status: status,
            purpose: resolvedPurpose?.purpose,
            purposeConfidence: resolvedPurpose?.confidence,
            purposeCandidates: Array(
                purposeCandidates.prefix(MailClassificationJSON.maximumPurposeCandidates)
            ),
            evidence: evidence,
            classifierVersion: MailClassificationRuleID.isValid(model.classifierVersion)
                ? model.classifierVersion
                : MailClassification.defaultClassifierVersion,
            resolverVersion: resolverVersion
        )
    }

    private static func resolvePurpose(
        candidates: [MailPurposeCandidate],
        deterministicRuleIDs: Set<String>
    ) -> (purpose: MailPurpose, confidence: Double)? {
        let structurallyQualified = Set(deterministicRuleIDs.compactMap {
            MailClassificationRuleInventory.purposeByRuleID[$0]
        })
        let eligible = candidates.filter(hasNecessaryPurposeEvidence)
        let qualifiedPurposes = structurallyQualified.union(eligible.map(\.purpose))
        // A candidate may only eliminate a competing purpose via supersession
        // once it clears the same resolution threshold applied below — a
        // weak, hedged secondary guess must not veto a strong, otherwise-
        // winning classification just because it cites a purpose that
        // outranks it in the abstract.
        let supersedingPurposes = structurallyQualified.union(
            eligible.filter { $0.confidence >= purposeThreshold }.map(\.purpose)
        )
        let survivingPurposes = qualifiedPurposes.filter { purpose in
            supersedingPurposes.contains { other in
                other != purpose && (purpose == .other
                    || MailClassificationRuleInventory.supersededPurposes[other, default: []]
                        .contains(purpose))
            } == false
        }
        let survivingStructural = structurallyQualified.intersection(survivingPurposes)
        if survivingStructural.isEmpty == false {
            if survivingStructural.count == 1, let purpose = survivingStructural.first {
                return (purpose, structuralPurposeThreshold)
            }
            return nil
        }

        let surviving = eligible.filter { candidate in
            survivingPurposes.contains(candidate.purpose)
        }
        guard let leading = surviving.first,
              leading.confidence >= purposeThreshold else {
            return nil
        }
        guard surviving.count > 1 else {
            return (leading.purpose, leading.confidence)
        }
        let second = surviving[1]
        guard leading.confidence - second.confidence + 1e-12 >= purposeMarginThreshold else {
            return nil
        }
        return (leading.purpose, leading.confidence)
    }

    private static func mergedPurposeCandidates(
        _ candidates: [MailPurposeCandidate]
    ) -> [MailPurposeCandidate] {
        var merged: [MailPurpose: MailPurposeCandidate] = [:]
        for candidate in candidates where isValidConfidence(candidate.confidence) {
            if let existing = merged[candidate.purpose] {
                merged[candidate.purpose] = MailPurposeCandidate(
                    candidate.purpose,
                    confidence: max(existing.confidence, candidate.confidence),
                    ruleIDs: canonicalRuleIDs(existing.ruleIDs + candidate.ruleIDs)
                )
            } else {
                var candidate = candidate
                candidate.ruleIDs = canonicalRuleIDs(candidate.ruleIDs)
                merged[candidate.purpose] = candidate
            }
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return MailClassificationRuleInventory.purposeOrder[lhs.purpose, default: .max]
                < MailClassificationRuleInventory.purposeOrder[rhs.purpose, default: .max]
        }
    }

    private static func buildEvidence(
        purposeCandidates: [MailPurposeCandidate],
        deterministicRuleIDs: Set<String>
    ) -> [MailClassificationEvidence] {
        var evidenceByRuleID: [String: MailClassificationEvidence] = [:]

        for candidate in purposeCandidates {
            guard let necessaryRuleID = MailClassificationRuleInventory
                .necessaryPurposeRuleID[candidate.purpose],
                  candidate.ruleIDs.contains(necessaryRuleID) else {
                continue
            }
            evidenceByRuleID[necessaryRuleID] = MailClassificationEvidence(
                purpose: candidate.purpose,
                ruleID: necessaryRuleID,
                polarity: .supporting,
                strength: candidate.confidence,
                sourceKind: .model
            )
        }

        for ruleID in deterministicRuleIDs {
            guard let purpose = MailClassificationRuleInventory.purposeByRuleID[ruleID] else {
                continue
            }
            evidenceByRuleID[ruleID] = MailClassificationEvidence(
                purpose: purpose,
                ruleID: ruleID,
                polarity: .supporting,
                strength: structuralPurposeThreshold,
                sourceKind: .bodyStructure
            )
        }

        return evidenceByRuleID.values
            .sorted { $0.ruleID < $1.ruleID }
            .prefix(MailClassificationJSON.maximumEvidenceRecords)
            .map { $0 }
    }

    private static func isValidConfidence(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func canonicalRuleIDs(_ ruleIDs: [String]) -> [String] {
        Array(Set(ruleIDs.filter(MailClassificationRuleID.isValid))).sorted()
    }
}

enum MailClassificationRuleInventory {
    static let necessaryPurposeRuleID: [MailPurpose: String] = [
        .correspondence: "purpose.correspondence.exchange",
        .announcement: "purpose.announcement.notice",
        .receipt: "purpose.receipt.completed",
        .promotion: "purpose.promotion.persuasion",
        .newsletter: "purpose.newsletter.recurringEditorial",
        .verificationCode: "purpose.verificationCode.timeBoundCredential",
        .notification: "purpose.notification.stateChange",
        .security: "purpose.security.accountRisk",
        .shipping: "purpose.shipping.logisticsState",
        .travel: "purpose.travel.itineraryState",
        .finance: "purpose.finance.financialObligation",
        .calendar: "purpose.calendar.scheduledEventAction",
        .support: "purpose.support.caseInteraction",
        .legal: "purpose.legal.rightsObligations",
        .socialActivity: "purpose.socialActivity.platformInteraction",
        .other: "purpose.other.noDefinedPurpose",
    ]
    static let purposeByRuleID = Dictionary(uniqueKeysWithValues: necessaryPurposeRuleID.map {
        ($0.value, $0.key)
    })

    /// `notification` is the taxonomy's residual bucket — its own prompt
    /// definition reads "central ... state change with no more specific
    /// purpose." Purposes the guide names as more specific supersede it
    /// deterministically instead of relying on the confidence-margin
    /// heuristic used for genuinely competing specific purposes.
    ///
    /// Deliberately excludes `correspondence`, `announcement`, `newsletter`,
    /// and `promotion`: their own guide bullets defer to notification in
    /// the overlap case ("operational state change is notification",
    /// "machine state-change digests are notification", "account notices
    /// are excluded", "a specialized ... alert ... job supersedes it"), so
    /// asserting the reverse here would contradict the prompt they share.
    static let supersededPurposes: [MailPurpose: Set<MailPurpose>] = [
        .receipt: [.finance, .notification, .correspondence],
        .verificationCode: [.security, .notification, .correspondence],
        .security: [.notification, .correspondence],
        .shipping: [.notification, .correspondence],
        .travel: [.calendar, .notification, .correspondence],
        .finance: [.notification, .correspondence],
        // Coordinating a scheduled event has a specific job even when
        // phrased as a personal exchange; the guide excludes that job
        // from correspondence. Qualification is still required above.
        .calendar: [.correspondence, .notification],
        .support: [.notification, .correspondence],
        .legal: [.notification, .correspondence],
        .socialActivity: [.notification, .correspondence],
        .notification: [.correspondence],
    ]

    static let purposeOrder: [MailPurpose: Int] = [
        .correspondence: 0, .announcement: 1, .receipt: 2, .promotion: 3,
        .newsletter: 4, .verificationCode: 5, .notification: 6, .security: 7,
        .shipping: 8, .travel: 9, .finance: 10, .calendar: 11,
        .support: 12, .legal: 13, .socialActivity: 14, .other: 15,
    ]

    static func isCanonical(_ ruleID: String) -> Bool {
        purposeByRuleID[ruleID] != nil
    }
}
