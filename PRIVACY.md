# Privacy Policy

Ohia is a macOS email app that runs on your Mac. This policy explains what data Ohia reads, where it is kept, what leaves your Mac and how to delete it. It applies to the Ohia app published at [github.com/JGKarlin/Ohia](https://github.com/JGKarlin/Ohia).

Ohia has no server of its own. The developer does not receive, collect or store your mail, your account details or information about how you use the app. There are no analytics, no telemetry, no crash reporting to the developer and no advertising.

## Data Ohia accesses

- **Your email.** When you connect an account, Ohia downloads your messages, attachments and folder structure over IMAP, and sends mail you write over SMTP.
- **Account credentials.** App passwords, and the sign-in tokens issued when you sign in with Microsoft. Microsoft sign-in asks only for permission to read mail over IMAP (`IMAP.AccessAsUser.All`), send mail over SMTP (`SMTP.Send`) and stay signed in (`offline_access`).
- **Optional sources, only with your permission:** Calendar, Contacts, Reminders and Messages through Apple's frameworks, files and notes you add, and external tools you connect through the Model Context Protocol (MCP).

## How Ohia uses it

Your data is used only to provide Ohia's features to you: storing and showing your mail, searching it, summarizing and classifying messages, extracting deadlines, translating, and drafting replies.

All of this runs on your Mac. Ohia's language, embedding and reranking models run locally, as do Apple's on-device models where Apple Intelligence is available. Ohia trains a personal adapter on your sent mail so drafts sound like you. That adapter is stored with your data, is used only for you and is never shared. Your mail is not used to train any shared or general-purpose model.

## What leaves your Mac

Ohia connects to the network only for the following:

- **Your mail provider**, to download and send mail, and to Microsoft's sign-in service if you sign in with Microsoft.
- **Hugging Face**, to download the models at setup. Nothing about you or your mail is sent.
- **External tools you connect** (MCP servers such as Slack, Notion or GitHub) and **web pages** fetched for research while drafting. These receive the requests Ohia makes to them, under their own privacy policies.
- **Remote images in a message**, only when you choose to load them for that sender.
- **Apple services:** MapKit, when Ohia turns a photo's location into a place name, and macOS speech recognition for dictation, which can send audio to Apple depending on your Mac's settings.

Ohia does not sell, rent or share your data with anyone, and does not use it for advertising, lending or any purpose other than the features above.

## Where your data is kept and how it is protected

- Mail, the search index, model adapters, memories and settings are stored in `~/Library/Group Containers/group.org.jgkarlin.Ohia/` on your Mac.
- Passwords and sign-in tokens are kept in your macOS login keychain.
- Connections to mail providers use TLS, and Ohia never sends mail unencrypted to another machine.
- PDFs are opened only in a sandboxed service with no network access and no access to Ohia's data.
- Ohia does not add encryption of its own beyond what macOS provides. Turn on FileVault to encrypt your disk.

## Retention and deletion

Your data stays on your Mac until you delete it. Ohia never changes your mailbox except when you act, for example to send, file, flag or delete a message.

- **Reset:** Settings › Developer › Reset Ohia removes accounts, credentials, messages and all other local state. Your mailboxes are not changed.
- **Remove completely:** quit Ohia, delete the app, delete the folder above, and delete the Ohia items in Keychain Access.
- **Revoke Microsoft access:** remove Ohia from your Microsoft account's app permissions at [account.live.com/consent/Manage](https://account.live.com/consent/Manage), or, for work and school accounts, at [myapps.microsoft.com](https://myapps.microsoft.com).

## Changes

Changes to this policy are published in this file, and its history is visible in the repository.

## Contact

Questions about this policy can be raised as an issue at [github.com/JGKarlin/Ohia/issues](https://github.com/JGKarlin/Ohia/issues).

Last updated: November 11, 2026
