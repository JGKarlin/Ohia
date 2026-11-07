import Foundation

/// Versions of the training prompt a `TrainingPair` was built with. A pair
/// trains only at the current version; older pairs are rebuilt in place by
/// the pair-preparation job before they can be used again.
public enum TrainingPromptFormat {
    /// The sent-reply format every adapter before 15 September 2026 learned:
    /// a correspondent/thread/incoming skeleton with the reply as completion.
    public static let legacySentReply = 7
    /// The Composer writer task: the runtime writer input (verbatim
    /// author-history instructions, role-labelled passages, presentation)
    /// with the text the author actually sent as completion. Format 8 used
    /// the released v9 renderer; v10's author-history renderer is format 9.
    /// Format 10 uses v11's prepared, attributed reply-content selection.
    /// Format 11 uses v12's raw evidence writer and per-message measured style.
    /// Format 12 uses v13's complete contextual correspondence task.
    /// Format 13 learns contextual composition with author-only missing decisions.
    /// Format 14 verifies reconstructed meaning and includes every accepted-send decision.
    /// Format 15 verifies empty reconstructions with the same semantic gate and preserves literal links.
    /// Format 16 carries contextual interpretation and evidence into the final writer handoff.
    /// Format 17 gives grounded conversational content and author decisions explicit roles in the reply.
    /// Format 18 links resolved requests to exact source passages and preserves original author instructions once.
    /// Format 19 distinguishes private drafting constraints and verifies complete authored paragraph notes.
    /// Format 20 supplies correspondent identities to meaning verification, retrying earlier preparation failures.
    /// Format 21 reconstructs terse note fragments, judges copying by coverage, and re-prepares every sent
    /// email — earlier failures and style-only standalone mail included — under that reconstruction.
    /// Format 22 keeps only author-added points as reconstructed instructions (thread-stated points
    /// become verified quotations), removes nested and flattened quoted history and resends from
    /// completions, and re-prepares every sent email under that reconstruction.
    public static let writerTask = 22
    public static let current = writerTask
    /// The complete writer sequence (prompt plus completion), in tokens, the
    /// writer task trains and drafts within.
    public static let writerSequenceTokens = 4_096
}
