import Foundation

/// A prompt laid out stable-first so an engine can reuse the model state of
/// its leading text. `prompt` (every checkpoint's text in order, then
/// `suffix`) is exactly what the model reads; the split only marks where the
/// engine may save its state and later resume from it instead of re-reading
/// that text. Callers split at boundaries whose leading text recurs: a lane's
/// static instructions, then one email's context, then the per-call part.
public struct PrefixCachedPrompt: Codable, Sendable, Equatable {
    public struct Checkpoint: Codable, Sendable, Equatable {
        /// How widely a saved state is reused, which decides the memory pool it lives in.
        public enum Reuse: String, Codable, Sendable {
            /// Text that recurs across many items: a lane's static instructions.
            case instructions
            /// Text about one email or thread, reused by later calls about it.
            case item
        }

        public let text: String
        public let reuse: Reuse

        public init(_ text: String, reuse: Reuse) {
            self.text = text
            self.reuse = reuse
        }
    }

    public let cacheKey: String
    /// Leading pieces, in order; the engine may save its state at the end of each.
    public let checkpoints: [Checkpoint]
    public let suffix: String

    /// Checkpoints with empty text mark no new state and are dropped.
    public init(cacheKey: String, checkpoints: [Checkpoint], suffix: String) {
        self.cacheKey = cacheKey
        self.checkpoints = checkpoints.filter { !$0.text.isEmpty }
        self.suffix = suffix
    }

    /// One `.instructions` checkpoint; an empty prefix means no checkpoint.
    public init(cacheKey: String, prefix: String, suffix: String) {
        self.init(
            cacheKey: cacheKey,
            checkpoints: [Checkpoint(prefix, reuse: .instructions)],
            suffix: suffix
        )
    }

    /// Whole prompt; no checkpoints.
    public init(cacheKey: String, prompt: String) {
        self.init(cacheKey: cacheKey, checkpoints: [], suffix: prompt)
    }

    /// The checkpoints' texts joined.
    public var prefix: String {
        checkpoints.map(\.text).joined()
    }

    /// `prefix + suffix`: exactly what the model reads.
    public var prompt: String {
        prefix + suffix
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey, checkpoints, suffix
    }

    /// Decodes through the memberwise init so a decoded value holds the same
    /// invariant as a constructed one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cacheKey: try container.decode(String.self, forKey: .cacheKey),
            checkpoints: try container.decode([Checkpoint].self, forKey: .checkpoints),
            suffix: try container.decode(String.self, forKey: .suffix)
        )
    }
}
