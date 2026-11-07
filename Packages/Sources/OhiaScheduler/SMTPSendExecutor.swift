import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Production `SendExecuting` — resolves an `OutboxItem` into an SMTP send.
///
/// Flow:
///   1. Read SMTP configuration + auth method off the linked `Account`.
///   2. Build a `MessageBuilder.Envelope` from the complete bodies frozen on
///      the outbox item by `SendDispatcher`.
///   3. Select auth: a request-scoped password from the app broker, or
///      an OAuth2 access token with a refresh-by-keychain-ref closure for the
///      XOAUTH2 retry path.
///   4. Drive `SMTPClient.sendOne(...)`.
///
/// `@unchecked Sendable` because the stored collaborators are thread-safe
/// reference/value types. The method itself is `@MainActor`, matching the protocol —
/// the heavy SMTP I/O hops into `SMTPClient`'s actor executor naturally.
public final class SMTPSendExecutor: SendExecuting, @unchecked Sendable {
    public typealias TransportFactory = @Sendable () -> SMTPTransport

    private let transportFactory: TransportFactory
    private let credentials: SMTPCredentials
    private let passwordResolver: any MailPasswordResolving
    private let oauthStore: OAuthTokenStore

    public init(
        transportFactory: @escaping TransportFactory = { SMTPStreamTransport() },
        credentials: SMTPCredentials = SMTPCredentials(),
        passwordResolver: any MailPasswordResolving = UnavailableMailCredentialResolver(),
        oauthStore: OAuthTokenStore = OAuthTokenStore(
            brokerClient: OAuthTokenBrokerClient(
                requester: UnavailableMailCredentialResolver()
            )
        )
    ) {
        self.transportFactory = transportFactory
        self.credentials = credentials
        self.passwordResolver = passwordResolver
        self.oauthStore = oauthStore
    }

    @MainActor
    public func send(item: OutboxItem) async throws {
        try await send(item: item) { _ in }
    }

    @MainActor
    public func send(
        item: OutboxItem,
        onAccepted: @MainActor @Sendable (AcceptedSend) -> Void
    ) async throws {
        guard let account = item.account else {
            throw SMTPError.permanent("outbox item has no account")
        }
        guard let host = account.smtpHost,
              let port = account.smtpPort,
              let security = account.smtpSecurity,
              let authMethod = account.smtpAuthMethod else {
            throw SMTPError.permanent("account has no SMTP configuration")
        }
        var effectiveHost = host
        var effectivePort = port
        var effectiveSecurity = security
        if MailProviderRegistry.lookupByHost(host)?.authHint == .oauth2(.gmail) {
            // MailLineStream's in-place STARTTLS upgrade currently stalls
            // before emitting a ClientHello. Gmail supports implicit TLS on
            // port 465, which uses the already-proven initial-TLS path.
            effectiveHost = "smtp.gmail.com"
            effectivePort = 465
            effectiveSecurity = .tls
            account.smtpHost = effectiveHost
            account.smtpPort = effectivePort
            account.smtpSecurity = effectiveSecurity
        } else if let provider = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: host,
            imapHost: account.imapHost
        ),
           provider.smtpPort == port,
           provider.smtpHost.caseInsensitiveCompare(host) == .orderedSame {
            effectiveSecurity = provider.security
            account.smtpSecurity = provider.security
        }

        let envelope = try buildEnvelope(item: item, account: account)
        let payload = try MessageBuilder.build(envelope: envelope)
        var localIngestionEnvelope = envelope
        localIngestionEnvelope.includeBccHeader = !envelope.bcc.isEmpty
        let localIngestionPayload = envelope.bcc.isEmpty
            ? payload
            : try MessageBuilder.build(envelope: localIngestionEnvelope)

        let auth: SMTPClient.Auth
        switch authMethod {
        case .password:
            let keychainReference = try credentials.keychainReference(for: account)
            let username = account.smtpUsername ?? account.emailAddress
            let password = try await passwordResolver.password(
                kind: .smtpPassword,
                keychainReference: keychainReference
            )
            auth = .password(
                username: username,
                password: password
            )
        case .oauth2:
            guard let providerID = resolveOAuthProvider(for: account) else {
                throw SMTPError.permanent("no OAuth provider configured for account domain")
            }
            let provider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft

            // Capture only Sendable values so the non-Sendable SwiftData
            // `Account` never crosses the actor hop.
            let tokenStore = oauthStore
            guard let keychainRef = account.smtpKeychainRef else {
                throw OAuthTokenStoreError.missingKeychainRef
            }
            let username = account.smtpUsername ?? account.emailAddress

            let initialToken = try await oauthStore.refreshByKeychainRef(
                keychainRef, provider: provider, forceRefresh: false
            )

            auth = .xoauth2(
                username: username,
                initialToken: initialToken,
                refresh: {
                    try await tokenStore.refreshByKeychainRef(keychainRef, provider: provider)
                }
            )
        }

        let client = SMTPClient(
            transport: transportFactory(),
            hostname: SMTPClient.ehloHostname(forAddress: account.emailAddress)
        )
        try await client.sendOne(
            host: effectiveHost, port: effectivePort, security: effectiveSecurity,
            auth: auth,
            envelope: envelope,
            payload: payload,
            onAccepted: {
                await onAccepted(AcceptedSend(
                    rawMessage: payload,
                    localIngestionRawMessage: localIngestionPayload
                ))
            }
        )

        // Best-effort: file the message in the IMAP Sent folder. Swallows
        // all errors; SMTP already succeeded, so the user's send is done.
        await appendToSentBestEffort(account: account, payload: payload)
    }

    // MARK: - Envelope construction

    @MainActor
    func buildEnvelope(item: OutboxItem, account: Account) throws -> MessageBuilder.Envelope {
        let decoder = JSONDecoder()

        func parseAddresses(_ json: String?) throws -> [EmailAddress] {
            guard let json = json, let data = json.data(using: .utf8) else { return [] }
            let strs = (try? decoder.decode([String].self, from: data)) ?? []
            return try strs.map {
                let address = try MailAddressParser.parseOne($0)
                guard address.displayName?.isEmpty != false,
                      let context = item.modelContext else {
                    return address
                }

                let normalizedAddress = address.asciiAddress.lowercased()
                var descriptor = FetchDescriptor<Participant>(
                    predicate: #Predicate { $0.emailAddress == normalizedAddress }
                )
                descriptor.fetchLimit = 1
                guard let displayName = try? context.fetch(descriptor).first?.displayName else {
                    return address
                }
                let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return address }
                return address.withDisplayName(trimmedName)
            }
        }

        let toAddresses = try parseAddresses(item.toAddressesJSON)
        let ccAddresses = try parseAddresses(item.ccAddressesJSON)
        let bccAddresses = try parseAddresses(item.bccAddressesJSON)

        let attachmentPaths: [String]
        if let json = item.attachmentPathsJSON, let data = json.data(using: .utf8) {
            attachmentPaths = (try? decoder.decode([String].self, from: data)) ?? []
        } else {
            attachmentPaths = []
        }

        // Parse the stamped identity address, then override the display phrase
        // with the stamped `fromDisplayName`. If no display name was stamped,
        // fall back to whatever the parser found in `fromAddress` (Postel's law
        // — robust to callers that encode "Name <addr>" into fromAddress).
        let parsedFrom = try MailAddressParser.parseOne(item.fromAddress)
        let from = parsedFrom.withDisplayName(item.fromDisplayName ?? parsedFrom.displayName)

        // Parse stamped Reply-To if present. Malformed input is logged and
        // dropped rather than throwing — the SMTP send has already succeeded
        // headers-wise; a malformed Reply-To is a config-editor bug that
        // should be visible in logs without blocking the user's mail.
        let replyTo: EmailAddress? = item.replyToAddress.flatMap { raw in
            do {
                return try MailAddressParser.parseOne(raw)
            } catch {
                print("[Ohia] SMTPSendExecutor: dropping malformed reply-to address errorKind=\(String(reflecting: type(of: error)))")
                return nil
            }
        }
        let plainBody = item.plainBody
        let htmlBody = item.htmlBody

        // Inline images stamped at enqueue (signature images referenced by
        // cid: in htmlBody). Meaningless without an HTML alternative.
        let inlineImages: [MessageBuilder.InlineImage] = htmlBody == nil
            ? []
            : OutboxInlineImage.decode(item.inlineImagesJSON).map {
                MessageBuilder.InlineImage(
                    path: $0.path, contentID: $0.contentID, mimeType: $0.mimeType
                )
            }

        return MessageBuilder.Envelope(
            from: from,
            replyTo: replyTo,
            to: toAddresses, cc: ccAddresses, bcc: bccAddresses,
            subject: item.subject, messageID: item.messageIDHeader,
            inReplyTo: item.inReplyTo, referencesChain: item.referencesChain,
            plainBody: plainBody, htmlBody: htmlBody,
            attachments: attachmentPaths,
            inlineImages: inlineImages,
            date: item.createdAt
        )
    }

    @MainActor
    private func resolveOAuthProvider(for account: Account) -> MailProvider.OAuthProviderID? {
        guard let provider = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: account.smtpHost,
            imapHost: account.imapHost
        ) else { return nil }
        if case .oauth2(let id) = provider.authHint { return id }
        return nil
    }
}

// MARK: - Post-send IMAP APPEND (best effort)

extension SMTPSendExecutor {
    /// After a successful SMTP send, APPEND the outgoing message to the
    /// account's IMAP Sent folder. Best-effort: any error is logged and
    /// swallowed so the outbox item still completes as `.sent`.
    ///
    /// Early-returns when the account has no IMAP configuration (SMTP-only
    /// accounts). Skips on Gmail (X-GM-EXT-1) to avoid duplicates — Gmail
    /// auto-files SMTP sends into `[Gmail]/Sent Mail` server-side.
    ///
    /// The sent-mail confirmation sound is *not* gated on this: it fires on SMTP
    /// acceptance in `send(item:)`, so an APPEND skip/failure never silences it.
    @MainActor
    func appendToSentBestEffort(account: Account, payload: Data) async {
        guard let host = account.imapHost,
              let port = account.imapPort,
              let security = account.imapSecurity,
              let authMethod = account.imapAuthMethod else {
            return
        }

        do {
            let auth = try await resolveIMAPAppendAuth(account: account, method: authMethod)
            let result = try await SentAppender.appendToSent(
                host: host, port: port, security: security,
                auth: auth,
                pinnedCertSHA256: account.pinnedCertSHA256,
                payload: payload, date: Date()
            )
            switch result {
            case .appended:
                print("[Ohia] IMAP APPEND succeeded")
            case .skippedGmail:
                // Gmail auto-files SMTP sends into [Gmail]/Sent Mail server-side.
                break
            case .skippedNoSentFolder:
                print("[Ohia] IMAP APPEND skipped — no Sent folder detected")
            }
        } catch {
            print("[Ohia] IMAP APPEND failed (non-fatal) errorKind=\(String(reflecting: type(of: error)))")
        }
    }

    @MainActor
    private func resolveIMAPAppendAuth(
        account: Account,
        method: IMAPAuthMethod
    ) async throws -> SentAppender.Auth {
        switch method {
        case .password:
            let keychainReference = try IMAPCredentials().keychainReference(for: account)
            let username = account.imapUsername ?? account.emailAddress
            let password = try await passwordResolver.password(
                kind: .imapPassword,
                keychainReference: keychainReference
            )
            return .password(
                username: username,
                password: password
            )
        case .oauth2:
            guard let providerID = resolveOAuthProvider(for: account) else {
                throw OAuthTokenStoreError.missingKeychainRef
            }
            let provider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft
            guard let ref = account.imapKeychainRef else {
                throw OAuthTokenStoreError.missingKeychainRef
            }
            let tokenStore = oauthStore
            let initialToken = try await oauthStore.refreshByKeychainRef(
                ref, provider: provider, forceRefresh: false
            )
            return .xoauth2(
                username: account.imapUsername ?? account.emailAddress,
                initialToken: initialToken,
                refresh: { try await tokenStore.refreshByKeychainRef(ref, provider: provider) }
            )
        }
    }
}
