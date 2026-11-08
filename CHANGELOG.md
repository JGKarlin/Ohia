# Changelog

All notable changes to Ohia are recorded here. Versions follow [semantic versioning](https://semver.org), and each one is published as a tagged release on GitHub with a notarized disk image.

## [0.10.0] - 2026-11-08

### Added

- Microsoft sign-in for Outlook.com, Hotmail and Microsoft 365 accounts. Work and school accounts may need their IT department's approval.

### Security

- Received mail can no longer reach the network unless you trust its sender: message views and printing block remote loads, pages cannot navigate themselves, and links open outside Ohia.
- SMTP never sends unencrypted to another machine.
- PDFs are opened only inside a sandboxed service with no network access and no access to Ohia's data, for LiteParse parsing, the PDFKit fallback and page rendering for image analysis.
- Embedding and reranking model downloads are pinned to fixed Hugging Face commits.
- Release builds no longer contain file paths from the build Mac.

### Fixed

- Text in images is read in every language Vision supports; before, only Latin and Cyrillic text was read.
- Messages and attachments are embedded in full, measured with BGE-M3's own tokenizer; Japanese and Chinese text no longer loses everything after its first 512 tokens. Existing mail is re-embedded in the background after updating.
- The Composer picks relevant passages from long Japanese and Chinese mail instead of only its opening.
- Composer drafts keep priority over background indexing.
- Resetting Ohia no longer crashes when the keychain refuses to delete an item.

### Known limitations

- Google sign-in is not included yet; Gmail accounts connect with an app password.
- Apple silicon and macOS 26.4 or later only.

## [0.9.0] - 2026-11-07

First public release.

### Included

- IMAP ingestion into a local store, and SMTP sending through an outbox with retries.
- Semantic search over a local vector index built with BGE-M3 (Core ML), with bge-reranker-v2-m3 reranking.
- Per-message interpretation with a local Qwen model on MLX: classification, reply and confirmation triage, deadlines, labels and summaries.
- Continuous LoRA fine-tuning on your sent mail, and the Composer for grounded reply drafts.
- The Metal-rendered spatial interface, with views for people, time, projects and deadlines.
- Local document parsing for attachments through a bundled LiteParse helper.

### Known limitations

- Accounts connect with an app password over IMAP and SMTP. Signing in with Google or Microsoft accounts is not included, so Microsoft accounts (Outlook.com, Hotmail, Microsoft 365) cannot connect in this release.
- Apple silicon and macOS 26.4 or later only.

[0.10.0]: https://github.com/JGKarlin/Ohia/releases/tag/v0.10.0
[0.9.0]: https://github.com/JGKarlin/Ohia/releases/tag/v0.9.0
