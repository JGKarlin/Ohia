import Foundation
import Tokenizers

/// Counts tokens the way an embedding model reads text, so documents can be
/// sized to its input window instead of being cut off silently.
public protocol EmbeddingDocumentTokenizing: Sendable {
    /// Largest input, in tokens including the model's special tokens, the
    /// model reads. Anything longer is truncated before inference.
    var maximumInputTokens: Int { get }
    /// Tokens the model adds around every input (for BGE-M3, `<s>` and `</s>`).
    var specialTokenCount: Int { get }
    /// Number of tokens `text` encodes to, excluding special tokens.
    func contentTokenCount(_ text: String) -> Int
}

public extension EmbeddingDocumentTokenizing {
    /// Content tokens one document may hold.
    var contentTokenCapacity: Int {
        max(1, maximumInputTokens - specialTokenCount)
    }
}

/// Counts with an embedding model's own tokenizer, normalized exactly as
/// `CoreMLEmbedder` normalizes text before inference, so counts match what
/// the model sees.
///
/// `CoreMLEmbedder.makeDocumentTokenizer()` builds one over the embedder's
/// own tokenizer and lock: no second copy of the vocabulary is loaded, the
/// counter is released with the embedder when the model is unloaded, and
/// counting never runs concurrently with that embedder's inference, because
/// swift-transformers does not document its tokenizers as thread-safe.
public final class EmbeddingModelTokenizer: EmbeddingDocumentTokenizing, @unchecked Sendable {
    public let maximumInputTokens: Int
    public let specialTokenCount: Int

    private let tokenizer: any Tokenizer
    private let lock: NSLock

    init(tokenizer: any Tokenizer, lock: NSLock = NSLock(), maximumInputTokens: Int) {
        self.tokenizer = tokenizer
        self.lock = lock
        self.maximumInputTokens = maximumInputTokens
        let probe = "a"
        lock.lock()
        let withSpecialTokens = tokenizer.encode(text: probe, addSpecialTokens: true).count
        let withoutSpecialTokens = tokenizer.encode(text: probe, addSpecialTokens: false).count
        lock.unlock()
        self.specialTokenCount = max(0, withSpecialTokens - withoutSpecialTokens)
    }

    public func contentTokenCount(_ text: String) -> Int {
        let normalized = CoreMLEmbedder.normalizedTextForTokenization(text)
        guard normalized.isEmpty == false else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return tokenizer.tokenize(text: normalized).count
    }
}
