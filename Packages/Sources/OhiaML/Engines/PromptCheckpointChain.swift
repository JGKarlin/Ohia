import Foundation
import OhiaCore

/// The model-free decisions of the prompt checkpoint chain: how a
/// checkpointed prompt is framed for the model, which checkpoint boundaries
/// can hold a saved state, where a call resumes and which states it builds.
enum PromptCheckpointChain {
    /// Shorter boundaries save too little prefill to be worth a saved state.
    static let minimumBoundaryTokens = 32

    /// The end of one checkpoint, as the framed text from the start of the
    /// prompt through it.
    struct Boundary: Equatable, Sendable {
        let leadingText: String
        /// The pool a state saved here lives in.
        let reuse: PrefixCachedPrompt.Checkpoint.Reuse
    }

    struct Plan: Equatable, Sendable {
        /// Boundaries that can hold a saved state, as indices into the given
        /// boundaries, in order.
        let usable: [Int]
        /// The usable boundary whose saved state the call resumes from; nil
        /// starts from token 0.
        let start: Int?
        /// Usable boundaries deeper than `start`, built and saved this call,
        /// in order.
        let build: [Int]
    }

    /// The pieces as the model reads them: the turn header joins the first
    /// piece (the first checkpoint, or the suffix when there are none) and
    /// the footer joins the suffix, so `checkpoints.joined() + suffix` is
    /// exactly the text the plain path frames.
    static func framedPieces(
        of prompt: PrefixCachedPrompt,
        wrapper: QwenChatTemplate.TurnWrapper?
    ) -> (checkpoints: [String], suffix: String) {
        let header = wrapper?.header ?? ""
        let footer = wrapper?.footer ?? ""
        var checkpoints = prompt.checkpoints.map(\.text)
        guard !checkpoints.isEmpty else {
            return ([], header + prompt.suffix + footer)
        }
        checkpoints[0] = header + checkpoints[0]
        return (checkpoints, prompt.suffix + footer)
    }

    /// The framed full prompt and one boundary per checkpoint. A saved state
    /// depends on all the text before it, so once an `.item` checkpoint
    /// appears every later boundary is per-item too and lives in that pool.
    static func framed(
        _ prompt: PrefixCachedPrompt,
        wrapper: QwenChatTemplate.TurnWrapper?
    ) -> (boundaries: [Boundary], fullText: String) {
        let pieces = framedPieces(of: prompt, wrapper: wrapper)
        var leadingText = ""
        var reuse = PrefixCachedPrompt.Checkpoint.Reuse.instructions
        var boundaries: [Boundary] = []
        for (piece, checkpoint) in zip(pieces.checkpoints, prompt.checkpoints) {
            leadingText += piece
            if checkpoint.reuse == .item {
                reuse = .item
            }
            boundaries.append(Boundary(leadingText: leadingText, reuse: reuse))
        }
        return (boundaries, leadingText + pieces.suffix)
    }

    /// A boundary is usable when it covers at least `minimumBoundaryTokens`,
    /// leaves at least one token to generate from, and lies strictly deeper
    /// than the previous usable boundary.
    static func usableBoundaries(tokenCounts: [Int], fullTokenCount: Int) -> [Int] {
        var usable: [Int] = []
        for (index, count) in tokenCounts.enumerated() {
            let previous = usable.last.map { tokenCounts[$0] } ?? 0
            guard count >= minimumBoundaryTokens,
                  count < fullTokenCount,
                  count > previous else { continue }
            usable.append(index)
        }
        return usable
    }

    /// Resume from the deepest usable boundary in `saved`, then build and
    /// save every deeper usable boundary.
    static func plan(tokenCounts: [Int], fullTokenCount: Int, saved: Set<Int>) -> Plan {
        let usable = usableBoundaries(tokenCounts: tokenCounts, fullTokenCount: fullTokenCount)
        guard let start = usable.last(where: { saved.contains($0) }) else {
            return Plan(usable: usable, start: nil, build: usable)
        }
        return Plan(
            usable: usable,
            start: start,
            build: Array(usable.drop(while: { $0 != start }).dropFirst())
        )
    }
}
