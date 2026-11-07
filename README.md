# Ohia

Ohia is an experimental email client for macOS that runs open-weight language models entirely on your Mac. It reads your mail over IMAP, builds a semantic index of everything you have received and sent, interprets each message with a local model, learns your writing voice from your sent mail, and drafts replies grounded in the conversation. Messages are shown in a Metal-rendered spatial view where each one is a node placed by meaning.

Ohia is research software. Version 0.9.0 is the first public release, and the app will keep changing.

## Why Ohia exists

Ohia is a working test of a question: how far can open-weight models running on consumer hardware go on tasks that usually depend on cloud AI services? It examines three of them, applied to a real mailbox of tens of thousands of messages:

- **Semantic search.** Finding mail by meaning across languages, beyond keyword matches.
- **Categorization.** Reading each message for what it asks of you: whether it needs a reply or a confirmation, its deadlines, topics, and a summary, each with a confidence score.
- **Context-rich generation.** Drafting replies that draw on the thread, related correspondence and attachments, written in the user's own voice through continuous fine-tuning on their sent mail.

Everything runs on the Mac, and no mail is sent to a cloud AI service. Ohia is also meant to show what that costs: which tasks small local models handle well, where they fall short, and how much memory, storage and time the work takes.

## Origins

Ohia is named after the ʻōhiʻa lehua, a tree native to Hawaiʻi. The name continues a lineage of Unix mail programs named after trees, Elm and Pine among them, and the ʻōhiʻa's star-shaped blossom suggested the app's picture of messages as points of light in a semantic space.

Ohia was created by [Jason Karlin](https://github.com/JGKarlin). He conceived, designed and directed the project and reviewed its development. Most of the implementation was written with AI coding agents, chiefly Anthropic's Claude Code and OpenAI's Codex, working under his direction. That is stated here because it bears on the project's subject: Ohia is both a study of what AI models can do with personal email and a product of AI-assisted software development.

## What it does

- **Mail over IMAP and SMTP.** Ohia downloads your mail over IMAP and keeps it in a local store. Reading and analysis never change your mailbox; Ohia writes to it only when you act: sending, saving drafts, filing, flagging or deleting. Outgoing mail goes through an outbox with retries.
- **Semantic index.** Every message is embedded with [BGE-M3](https://huggingface.co/BAAI/bge-m3), a multilingual embedding model, running under Core ML, and stored in a local vector index. Results are reranked with [bge-reranker-v2-m3](https://huggingface.co/BAAI/bge-reranker-v2-m3).
- **Interpretation.** A local [Qwen](https://huggingface.co/Qwen) model, run with [MLX](https://github.com/ml-explore/mlx-swift), classifies each message, decides whether it needs a reply or a confirmation, extracts deadlines and labels, and writes a summary.
- **Your writing voice.** Ohia continuously fine-tunes LoRA adapters on your sent mail, so drafts take on your phrasing.
- **Composer.** For a reply, Ohia gathers the relevant thread, past correspondence and attachments, asks you the questions it needs answered, and then drafts.
- **Spatial interface.** Messages are nodes in a Metal-rendered scene arranged by meaning, with views organized around people, time, projects and deadlines.
- **Other sources.** Attachments (PDFs and other documents) are parsed locally. Calendar, Contacts and Messages can be added as context with your permission. Where Apple Intelligence is available, some helper tasks can use Apple's on-device models. External tools can be connected through the Model Context Protocol.

## Requirements

- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- macOS 26.4 or later. Ohia is developed and tested on macOS 27.
- Memory: 16 GB or more is recommended. Ohia recommends a model based on your Mac's memory, and you can choose a lighter one:

  | Unified memory | Model | Download |
  | --- | --- | --- |
  | 8 GB | Qwen3.5 2B (4-bit) | 1.8 GB |
  | 16 GB | Qwen3.5 4B (4-bit) | 3.1 GB |
  | 24 GB | Qwen3.5 9B (4-bit) | 6.0 GB |
  | 48 GB | Qwen3.8 27B (4-bit) | 16.1 GB |
  | 96 GB | Qwen3.8 27B (8-bit) | 29.5 GB |
  | 128 GB | Qwen3.8 27B (BF16) | 54.8 GB |

- Storage: room for the model above, about 3.5 GB for the embedding and reranking models, and the local index of your mail.

## Install

1. Download `Ohia-0.9.0.dmg` from the [latest release](https://github.com/JGKarlin/Ohia/releases/latest).
2. Open it and drag Ohia to Applications. The app is signed with a Developer ID and notarized by Apple.
3. On first launch, Ohia walks you through choosing a model and connecting an account. It then downloads the models from Hugging Face, which can take a while.

Each release lists the SHA-256 checksum of the disk image, so you can check a download with `shasum -a 256 Ohia-0.9.0.dmg`.

## Connecting mail

Version 0.9.0 connects to mail accounts with a password over IMAP and SMTP.

- **iCloud Mail:** create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security, then App-Specific Passwords).
- **Gmail:** turn on 2-Step Verification, then create an app password at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords). Make sure IMAP access is enabled in Gmail's settings.
- **Fastmail and most other providers:** use an app password from your provider's security settings.
- **Microsoft accounts (Outlook.com, Hotmail, Microsoft 365):** not supported in this release. Microsoft requires its own sign-in for mail apps, and 0.9.0 does not include it.

Signing in with Google or Microsoft accounts directly is planned for a later release, once Google has verified the app's Gmail access.

## Your data

- Mail, the index, model adapters and settings are stored in `~/Library/Group Containers/group.org.jgkarlin.Ohia/`. Passwords and tokens are kept in your login keychain.
- Ohia connects to the network for your mail provider, for model downloads from Hugging Face, and for any external tools you connect. Mail content is processed on your Mac.
- Ohia does not add encryption of its own beyond what macOS provides. Turn on FileVault to encrypt the disk.
- To remove Ohia completely, quit it, delete the app, delete the folder above, and delete the Ohia items from Keychain Access.

## Building from source

You need Xcode 27.1 or later on an Apple silicon Mac.

```bash
git clone https://github.com/JGKarlin/Ohia.git
cd Ohia
tools/fetch-liteparse-node.sh   # downloads and verifies the Node.js runtime for document parsing
open Ohia.xcodeproj
```

The project is set up for its author's Apple developer team, and its identifiers share the prefix `org.jgkarlin`: the bundle identifier, the XPC worker identifiers, the app group `group.org.jgkarlin.Ohia`, and log subsystems. To build and run under your own team:

1. Replace `org.jgkarlin` with a reverse-DNS prefix of your own everywhere in the project. Searching for `org.jgkarlin` finds every occurrence, including the app group in `Ohia/Ohia.entitlements`, `Ohia/OhiaGenerativeWorker.entitlements`, `Ohia/OhiaRetrievalWorker.entitlements` and `Packages/Sources/OhiaCore/Storage/OhiaStorageRoot.swift`.
2. In the Ohia target's Signing & Capabilities, choose your team and register the new app group.
3. Build and run the Ohia scheme.

The notification sounds in the released app are licensed for use in the app only and are not part of this repository, so builds from source run without sounds.

Optional:

- **Google or Microsoft sign-in:** register your own OAuth client and put its client ID in `Ohia/Configuration.plist` (`OHIA_GOOGLE_OAUTH_CLIENT_ID`, `OHIA_MS_OAUTH_CLIENT_ID`). With a client ID present, the sign-in buttons return.
- **Bundled embedding models:** `tools/fetch-bundled-bge.sh` downloads the embedding and reranking models into `BundledModels/` so they ship inside the app instead of downloading at first launch. It needs the Hugging Face CLI (`brew install huggingface-cli`).
- **Fresh start:** `tools/reset-ohia.sh` clears Ohia's local data so the next launch behaves like a new install. Check the script before you run it.

The code is organized as an Xcode app (`Ohia/`) on top of five Swift packages in `Packages/Sources`: `OhiaCore` (data model and storage), `OhiaIngest` (parsing and ingestion), `OhiaML` (models, retrieval, drafting and training), `OhiaMail` (IMAP, SMTP and accounts) and `OhiaScheduler` (background work). Model work runs in XPC services built from the same packages.

## Versions and releases

Ohia uses [semantic versioning](https://semver.org). Each release is tagged `vMAJOR.MINOR.PATCH`, described in [CHANGELOG.md](CHANGELOG.md), and published on the [releases page](https://github.com/JGKarlin/Ohia/releases) with a notarized disk image and its checksum.

Development happens in a separate repository. Each release arrives here as a single commit containing the full source of that version, so this repository's history is the list of releases.

## Contributing

Bug reports, questions and ideas are welcome in [Issues](https://github.com/JGKarlin/Ohia/issues). Because this repository is replaced by a snapshot at each release, pull requests can't be merged directly. Changes proposed in one are applied in the development repository by hand and credited in the changelog.

## License

Ohia is licensed under the [Apache License, Version 2.0](LICENSE). It includes third-party software under its own licenses, listed in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

The models Ohia downloads are not part of this repository and have their own licenses: the Qwen models are Apache-2.0, BGE-M3 is MIT, and bge-reranker-v2-m3 is Apache-2.0.
