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
- **GitHub, to check for and download updates.** Ohia asks `github.com` for its update feed once a day and when you choose Check for Updates in the Ohia menu. GitHub serves the feed, and any new version, from `release-assets.githubusercontent.com`. The request carries Ohia's name and version number and the Sparkle updater's version in its User-Agent header, for example `Ohia/0.11.0 Sparkle/2.10.1`, and nothing else from Ohia: no account, no mail, no identifier and no system profile, because Sparkle's system profiling is off in Ohia. GitHub sees your IP address, as any website does, and handles it under the [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). By default Ohia checks automatically and installs a downloaded update when you quit; if Ohia stays open for a week with an update waiting, it shows a notice. To turn this off, open Settings › General, find the Updates card and switch off "Check for updates automatically"; "Download and install updates automatically" controls only the installing. Builds made from source have no updater and make no update requests.
- **Apple services:** MapKit, when Ohia turns a photo's location into a place name, and macOS speech recognition for dictation, which can send audio to Apple depending on your Mac's settings.

Ohia does not sell, rent or share your data with anyone, and does not use it for advertising, lending or any purpose other than the features above.

## Where your data is kept and how it is protected

- Mail, the search index, model adapters, memories and settings are stored in `~/Library/Group Containers/group.org.jgkarlin.Ohia/` on your Mac.
- Passwords and sign-in tokens are kept in your macOS login keychain.
- Connections to mail providers use TLS, and Ohia never sends mail unencrypted to another machine.
- PDFs are opened, and the text in images is read, only in a sandboxed service with no network access and no access to Ohia's data.
- Ohia does not add encryption of its own beyond what macOS provides. Turn on FileVault to encrypt your disk.

## Retention and deletion

Your data stays on your Mac until you delete it. Ohia never changes your mailbox except when you act, for example to send, file, flag or delete a message.

- **Reset:** Settings › Developer › Reset Ohia removes accounts, credentials, messages and all other local state. Ohia quits and does the removal the next time it opens, before anything else; it keeps downloaded public models that pass verification. Your mailboxes are not changed.
- **Remove completely:** choose Uninstall Ohia in the Ohia menu, or open Uninstall Ohia from the Ohia disk image. Before anything else, macOS asks whether Uninstall Ohia may access data from other apps; it needs that to remove Ohia's containers, and asks macOS to reset that permission when it is done. A window lists what will be removed and asks you to confirm once. It then quits Ohia and removes:
  - the Ohia app, from `/Applications` and `~/Applications`, and the copy it was started from when that is a genuine Ohia;
  - the shared group container with your mail, index, models and adapters, which Ohia empties itself during its cleanup, because macOS lets only Ohia open it;
  - Ohia's data and the data of its four helper services: their containers, their scripts folders, preferences, web storage, caches and saved window state, and the older `Application Support/Ohia` folder and the store files earlier development builds left beside it (`Ohia.store`, `Ohia.store-shm`, `Ohia.store-wal`, `Ohia.store.compatibility.json`, `Ohia.sqlite` and `Ohia.vectors.sqlite`), all in your Library folder;
  - the saved passwords and sign-ins that Ohia keeps in your login keychain (the services `com.ohia.oauth`, `com.ohia.smtp`, `com.ohia.imap`, `ohia-mcp-server-env`, `ohia-mcp-hosted-oauth` and `ohia-mcp-firecrawl-oauth`);
  - the "Ohia" calendar and its events, which Ohia deletes itself just before it quits;
  - the privacy permissions you granted to Ohia, reset with `tccutil`.

  It removes only these exact paths and never searches your Library for matches. macOS keeps an empty folder for each container, holding only its own bookkeeping file. If Ohia can't run its cleanup, for example because only an older copy is left, the uninstaller removes the passwords it can reach and lists the group container and anything else it could not remove, with what to do about each. If Ohia can't empty its folder, the report may suggest turning on Full Disk Access for Uninstall Ohia in System Settings › Privacy & Security › Full Disk Access, so the uninstaller can empty it itself; you can turn that off again in the same place afterwards. The uninstaller resets only its permission to access data from other apps, not Full Disk Access. If a removal needs administrator rights, such as an app installed by another administrator, it asks once for your password through the standard macOS prompt, and it lists anything it could not remove. It does not change your mailboxes, Mail, Messages, Notes, Contacts or other calendars. Other copies of Ohia on your Mac, for example on other drives or in build folders, are listed and left in place. The uninstaller runs only on your Mac and sends nothing to the developer or anyone else.
- **Builds made from source:** the same Uninstall Ohia command is in that build's Ohia menu. You can also remove Ohia by hand. First choose Settings › Developer › Reset Ohia; Ohia schedules the reset and quits. Open Ohia again: before anything else, it deletes its data, its saved passwords and its settings, and tells you about any saved password it could not delete. Quit Ohia at the welcome screen. Then delete the app and the other folders above, and any Ohia items left in Keychain Access. The shared group container is still there, with the public models Reset kept and the data Ohia created again when it opened; macOS lets only Ohia, or an app with Full Disk Access, open that folder, so remove the whole folder with such an app.
- **Revoke Microsoft access:** remove Ohia from your Microsoft account's app permissions at [account.live.com/consent/Manage](https://account.live.com/consent/Manage), or, for work and school accounts, at [myapps.microsoft.com](https://myapps.microsoft.com).

## Changes

Changes to this policy are published in this file, and its history is visible in the repository.

## Contact

Questions about this policy can be raised as an issue at [github.com/JGKarlin/Ohia/issues](https://github.com/JGKarlin/Ohia/issues).

Last updated: November 26, 2026
