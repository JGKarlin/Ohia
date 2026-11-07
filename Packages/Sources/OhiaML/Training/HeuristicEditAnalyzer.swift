// HeuristicEditAnalyzer.swift
// Real implementation of EditAnalyzing. Detects five signal types:
//
//   .contentAdded / .contentRemoved / .rewrite
//     Line-level diff between the original and edited draft, with rewrite
//     detected as a paired removal + addition.
//
//   .toneShift
//     DraftingStyleAnalyzer runs on the authored text from both versions; a
//     signal is emitted when the dominant tone changes or formality moves by
//     ≥ 0.15.
//
//   .sourceOverride
//     Citation claims that were present in the original but have been
//     removed from the edited draft — the user rejected a sourced claim.
//
// Stateless; safe to share across threads.

import Foundation
import OhiaCore

public final class HeuristicEditAnalyzer: EditAnalyzing, Sendable {

    public init() {}

    public func analyze(
        originalDraft: String,
        editedDraft: String,
        correspondentEmail: String,
        citations: [Citation],
        languageID: String?
    ) -> [TrainingSignal] {
        guard originalDraft != editedDraft else { return [] }

        var signals: [TrainingSignal] = []

        signals.append(contentsOf: diffSignals(
            originalDraft: originalDraft,
            editedDraft: editedDraft,
            correspondentEmail: correspondentEmail
        ))

        if let toneSignal = toneShiftSignal(
            originalDraft: originalDraft,
            editedDraft: editedDraft,
            correspondentEmail: correspondentEmail,
            languageID: languageID
        ) {
            signals.append(toneSignal)
        }

        signals.append(contentsOf: sourceOverrideSignals(
            originalDraft: originalDraft,
            editedDraft: editedDraft,
            correspondentEmail: correspondentEmail,
            citations: citations
        ))

        return signals
    }

    // MARK: - Line diff

    private func diffSignals(
        originalDraft: String,
        editedDraft: String,
        correspondentEmail: String
    ) -> [TrainingSignal] {
        let originalLines = originalDraft
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let editedLines = editedDraft
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let originalSet = Set(originalLines)
        let editedSet = Set(editedLines)

        let addedLines = editedLines.filter { !originalSet.contains($0) }
        let removedLines = originalLines.filter { !editedSet.contains($0) }

        var signals: [TrainingSignal] = []
        let rewriteCount = min(addedLines.count, removedLines.count)

        for i in 0..<rewriteCount {
            signals.append(TrainingSignal(
                type: .rewrite,
                description: "rewrote: \"\(removedLines[i].prefix(40))\" → \"\(addedLines[i].prefix(40))\"",
                originalSpan: removedLines[i],
                editedSpan: addedLines[i],
                correspondentEmail: correspondentEmail,
                weight: 1.0
            ))
        }

        for i in rewriteCount..<addedLines.count {
            signals.append(TrainingSignal(
                type: .contentAdded,
                description: "added: \"\(addedLines[i].prefix(50))\"",
                originalSpan: nil,
                editedSpan: addedLines[i],
                correspondentEmail: correspondentEmail,
                weight: 1.0
            ))
        }

        for i in rewriteCount..<removedLines.count {
            signals.append(TrainingSignal(
                type: .contentRemoved,
                description: "removed: \"\(removedLines[i].prefix(50))\"",
                originalSpan: removedLines[i],
                editedSpan: nil,
                correspondentEmail: correspondentEmail,
                weight: 1.0
            ))
        }

        return signals
    }

    // MARK: - Tone shift

    /// Compares the tone/formality of the original and edited authored text.
    /// Emits a single signal describing the shift, with weight scaled by the
    /// formality delta.
    private func toneShiftSignal(
        originalDraft: String,
        editedDraft: String,
        correspondentEmail: String,
        languageID: String?
    ) -> TrainingSignal? {
        let originalAnalysis = DraftingStyleAnalyzer.analyze(
            authoredText: AuthoredReplyText.extract(from: originalDraft),
            languageID: languageID
        )
        let editedAnalysis = DraftingStyleAnalyzer.analyze(
            authoredText: AuthoredReplyText.extract(from: editedDraft),
            languageID: languageID
        )

        let originalTone = originalAnalysis?.dominantTone
        let editedTone = editedAnalysis?.dominantTone
        let formalityDelta: Double
        if let originalAnalysis, let editedAnalysis {
            formalityDelta = editedAnalysis.formality.value - originalAnalysis.formality.value
        } else {
            formalityDelta = 0
        }

        let toneChanged = originalTone != editedTone

        // Trigger on tone label change OR meaningful formality shift.
        guard toneChanged || abs(formalityDelta) >= 0.15 else { return nil }

        let description: String
        if toneChanged {
            let from = originalTone?.rawValue ?? "none"
            let to = editedTone?.rawValue ?? "none"
            description = "tone shifted: \(from) → \(to) (formality \(formatDelta(formalityDelta)))"
        } else {
            let direction = formalityDelta > 0 ? "more formal" : "more casual"
            description = "tone shifted \(direction) (formality \(formatDelta(formalityDelta)))"
        }

        // Stronger formality shifts carry more weight, capped at 1.2.
        let weight = min(1.2, 0.6 + abs(formalityDelta) * 2.0)

        return TrainingSignal(
            type: .toneShift,
            description: description,
            originalSpan: originalTone?.rawValue,
            editedSpan: editedTone?.rawValue,
            correspondentEmail: correspondentEmail,
            weight: weight
        )
    }

    private func formatDelta(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", value))"
    }

    // MARK: - Source override

    /// For each citation, check whether its claim appeared in the original
    /// draft but is now absent from the edited draft. That's the user
    /// rejecting a sourced claim — a strong training signal.
    private func sourceOverrideSignals(
        originalDraft: String,
        editedDraft: String,
        correspondentEmail: String,
        citations: [Citation]
    ) -> [TrainingSignal] {
        citations.compactMap { citation -> TrainingSignal? in
            let claim = citation.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !claim.isEmpty else { return nil }

            let wasPresent = originalDraft.contains(claim)
            let stillPresent = editedDraft.contains(claim)
            guard wasPresent && !stillPresent else { return nil }

            let preview = String(claim.prefix(60))
            return TrainingSignal(
                type: .sourceOverride,
                description: "removed sourced claim: \"\(preview)\"",
                originalSpan: claim,
                editedSpan: nil,
                correspondentEmail: correspondentEmail,
                weight: 1.3
            )
        }
    }
}
