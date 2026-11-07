# Changelog

All notable changes to Ohia are recorded here. Versions follow [semantic versioning](https://semver.org), and each one is published as a tagged release on GitHub with a notarized disk image.

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

[0.9.0]: https://github.com/JGKarlin/Ohia/releases/tag/v0.9.0
