// Ohia/Settings/SMTPConfigForm/SMTPConfigFormState.swift
import SwiftUI
import Observation
import SwiftData
import OhiaCore
import OhiaMail
import OhiaIngest

/// Observable viewmodel for the shared SMTP configuration form.
/// Two consumers: the onboarding SMTP step, and the Accounts-tab
/// "Configure Outgoing…" disclosure. Knows nothing about its presenter —
/// it just manages field state and exposes `save(...)`,
/// `verifyAndContinue(...)`, and `runTest(...)`.
@Observable
@MainActor
final class SMTPConfigFormState {
    // Inputs
    var emailAddress: String
    var host: String = ""
    var portText: String = ""
    var security: SMTPSecurity = .starttls
    var username: String = ""
    var authMethod: SMTPAuthMethod = .password
    var password: String = ""
    var providerDisplayName: String? = nil
    var imapHostHint: String? = nil
    var imapPortHint: Int? = nil
    var imapUsernameHint: String? = nil
    var imapSecurityHint: IMAPSecurity? = nil

    // Feedback
    enum TestStatus: Equatable {
        case idle
        case running
        case success
        case failure(String)
        case certUntrusted(info: CertificateInfo)
    }
    var testStatus: TestStatus = .idle
    var signInStatus: TestStatus = .idle

    enum VerificationStage: Equatable {
        case oauthSignIn
        case smtp
        case imap
        case saving
    }

    struct VerificationFingerprint: Hashable {
        fileprivate let accountID: UUID
        fileprivate let emailAddress: String
        fileprivate let host: String
        fileprivate let portText: String
        fileprivate let security: String
        fileprivate let username: String
        fileprivate let authMethod: String
        fileprivate let password: String
        fileprivate let imapHost: String?
        fileprivate let imapPort: Int?
        fileprivate let imapUsername: String?
        fileprivate let imapSecurity: String?
    }

    private(set) var verificationStage: VerificationStage?
    private var activeAttemptID: UUID?
    private var activeFingerprint: VerificationFingerprint?
    @ObservationIgnored private var verificationOAuthTokens: Tokens?

    var isVerifying: Bool { activeAttemptID != nil }

    var verificationProgressText: String {
        switch verificationStage {
        case .oauthSignIn:
            return "Signing in"
        case .smtp:
            return "Checking SMTP authentication"
        case .imap:
            return "Checking IMAP authentication"
        case .saving:
            return "Saving verified mail settings"
        case .none:
            return "Checking mail authentication"
        }
    }

    /// Factory that produces a configured `SMTPTransport` per Test Connection
    /// attempt. Defaults to an `SMTPStreamTransport` with the account's pin
    /// forwarded. Tests swap this for a stub that throws a known `SMTPError`.
    var transportFactory: () -> SMTPTransport = {
        SMTPStreamTransport()
    }

    /// Narrow external-operation seams. Production uses the existing OAuth,
    /// Keychain, SMTP, and IMAP implementations; state tests replace only the
    /// network and persistence boundaries.
    @ObservationIgnored
    var oauthTokenAcquisition: @MainActor (OAuthProvider) async throws -> Tokens = {
        try await OAuthCoordinator.signIn(provider: $0)
    }

    @ObservationIgnored
    var oauthTokenPersistence: @MainActor (Tokens, Account) async throws -> Void = {
        try await OAuthTokenStore().store(tokens: $0, for: $1)
    }

    @ObservationIgnored
    var credentialPersistence: @MainActor (SMTPConfigFormState, Account) throws -> Void = {
        try $0.save(to: $1)
    }

    @ObservationIgnored
    var smtpVerification: @MainActor (SMTPConfigFormState, Account) async throws -> Void = {
        try await $0.verifySMTPAuthentication(for: $1)
    }

    @ObservationIgnored
    var imapConfiguration: @MainActor (
        SMTPConfigFormState,
        Account,
        Tokens?
    ) async throws -> IMAPConnectionConfiguration = {
        try await $0.makeVerificationIMAPConfiguration(
            for: $1,
            acquiredOAuthTokens: $2
        )
    }

    @ObservationIgnored
    var imapVerification: @MainActor (IMAPConnectionConfiguration) async throws -> Void = {
        try await IMAPConnectionVerifier.verify(configuration: $0)
    }

    /// Captured at the start of `runTest` so the cert-untrusted branch can
    /// forward it to `inspectPeerCertificate` if needed.
    fileprivate var accountPinnedCertSHA256: String? = nil

    private func makeTransport() -> SMTPTransport {
        let t = transportFactory()
        if let stream = t as? SMTPStreamTransport {
            stream.pinnedCertSHA256 = self.accountPinnedCertSHA256
        }
        return t
    }

    /// Effective port as Int (0 if blank or invalid).
    var port: Int { Int(portText) ?? 0 }

    /// Whether this build carries an OAuth client ID for the provider.
    @ObservationIgnored
    var oauthClientConfigured: (MailProvider.OAuthProviderID) -> Bool = {
        OAuthProvider.forID($0).isConfigured
    }

    /// Which OAuth provider (if any) matches the current `emailAddress` and
    /// can sign in from this build. Drives the provider-first branching in
    /// `SMTPConfigFormView`; nil routes to the password form.
    var oauthProviderID: MailProvider.OAuthProviderID? {
        guard let id = providerOAuthID, oauthClientConfigured(id) else {
            return nil
        }
        return id
    }

    /// The OAuth provider the address belongs to, whether or not this build
    /// can sign in to it.
    private var providerOAuthID: MailProvider.OAuthProviderID? {
        guard let provider = currentProvider,
              case .oauth2(let id) = provider.authHint else {
            return nil
        }
        return id
    }

    /// Guidance under the password field when the address belongs to an
    /// OAuth provider this build cannot sign in to.
    var passwordSignInNote: String? {
        guard oauthProviderID == nil, let id = providerOAuthID else { return nil }
        return Self.passwordSignInNote(for: id)
    }

    static func passwordSignInNote(for id: MailProvider.OAuthProviderID) -> String {
        switch id {
        case .gmail:
            "Gmail needs an app password: turn on 2-Step Verification, then create one at myaccount.google.com/apppasswords."
        case .microsoft:
            "Microsoft accounts need Microsoft sign-in, which this build of Ohia doesn't include yet."
        }
    }

    private var currentProvider: MailProvider? {
        MailProviderRegistry.lookup(
            email: emailAddress,
            smtpHost: host,
            imapHost: imapHostHint
        )
    }

    init(emailAddress: String) {
        self.emailAddress = emailAddress
    }

    /// Hydrate from an existing Account (Settings path).
    func hydrate(from account: Account) {
        self.emailAddress = account.emailAddress
        self.host = account.smtpHost ?? ""
        self.portText = account.smtpPort.map(String.init) ?? ""
        self.security = account.smtpSecurity ?? .starttls
        self.username = account.smtpUsername ?? account.emailAddress
        self.authMethod = account.smtpAuthMethod ?? .password
        self.imapHostHint = account.imapHost
        self.imapPortHint = account.imapPort
        self.imapUsernameHint = account.imapUsername
        self.imapSecurityHint = account.imapSecurity
    }

    /// Apply provider auto-config. Called on first appear and whenever
    /// `emailAddress` changes (onboarding pre-fill, Accounts-tab edit).
    /// Does NOT overwrite fields the user already edited — only fills
    /// blanks.
    func applyProviderDefaults() {
        // An account set up with OAuth in a build that carried a client ID can
        // only verify with a password in a build that carries none.
        if authMethod == .oauth2, oauthProviderID == nil {
            authMethod = .password
        }
        guard let provider = currentProvider else {
            providerDisplayName = nil
            return
        }
        providerDisplayName = provider.displayName
        if host.isEmpty { host = provider.smtpHost }
        if portText.isEmpty { portText = String(provider.smtpPort) }
        // Security defaults match provider only when user hasn't picked.
        if oauthProviderID != nil {
            authMethod = .oauth2
        }
        if username.isEmpty { username = emailAddress }
        if security == .starttls {  // default — switch to provider's if different
            security = provider.security
        }
    }

    /// Apply Mail.app piggyback values. Used only by onboarding, and only
    /// when Mail.app returned something. Never overwrites user edits.
    func applyMailAppHints(_ info: MailAppSMTPReader.Info) {
        let hostWasEmpty = host.isEmpty
        if host.isEmpty { host = info.host }
        if username.isEmpty { username = info.username }
        if portText.isEmpty { portText = String(info.port) }
        // Gate on `hostWasEmpty` (pre-mutation) so we only apply the hint
        // when the user hadn't started filling the form.
        if hostWasEmpty {
            security = securityForImportedEndpoint(info.usesSSL ? .tls : .starttls)
        }
    }

    func applyInitialPassword(_ initialPassword: String) {
        guard password.isEmpty else { return }
        let trimmed = initialPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            password = initialPassword
        }
    }

    func applyDiscoveryHints(_ discovered: DiscoveredAccount) {
        imapHostHint = discovered.imapHost
        imapPortHint = discovered.imapPort
        imapUsernameHint = discovered.imapUsername
        imapSecurityHint = discovered.imapSecurity

        if host.isEmpty, let smtpHost = discovered.smtpHost {
            host = smtpHost
        }
        if portText.isEmpty, let smtpPort = discovered.smtpPort {
            portText = String(smtpPort)
        }
        if username.isEmpty {
            username = discovered.smtpUsername
                ?? discovered.imapUsername
                ?? discovered.emailAddress
        }
        if security == .starttls, let smtpSecurity = discovered.smtpSecurity {
            security = securityForImportedEndpoint(smtpSecurity)
        }
    }

    private func securityForImportedEndpoint(_ hint: SMTPSecurity) -> SMTPSecurity {
        // Mail.app's encryption flag also covers STARTTLS. A known provider's
        // exact submission endpoint determines the mode (iCloud uses 587 +
        // STARTTLS); retain the hint for custom servers and nonstandard ports.
        let defaults = currentProvider
        let resolvedHost = host.isEmpty ? defaults?.smtpHost : host
        let resolvedPort = portText.isEmpty ? defaults?.smtpPort : port
        guard let provider = MailProviderRegistry.lookupByHost(resolvedHost),
              provider.smtpPort == resolvedPort else {
            return hint
        }
        return provider.security
    }

    /// Persist form values onto an Account and (for password auth) into
    /// Keychain. Returns the saved account. Throws on Keychain failure.
    ///
    /// Plan-2: the same credential path also populates the account's
    /// IMAP fields + imapKeychainRef. For Gmail/Microsoft OAuth the
    /// single OAuth token covers both protocols (mail.google.com /
    /// IMAP.AccessAsUser.All scopes). For password providers the same
    /// app-specific password is stored under com.ohia.imap alongside
    /// the com.ohia.smtp entry.
    func save(to account: Account) throws {
        account.smtpHost = host
        account.smtpPort = port > 0 ? port : nil
        account.smtpSecurity = security
        account.smtpUsername = username.isEmpty ? emailAddress : username
        account.smtpAuthMethod = authMethod

        if authMethod == .password {
            let creds = SMTPCredentials()
            try creds.storePassword(password, for: account)
        }
        // OAuth path stores tokens through the combined verification flow.
        // We only flip authMethod here; token acquisition provisions the ref.
        account.needsReauth = false

        // Plan-2 IMAP wiring. Populate IMAP fields from the provider
        // registry when known, otherwise preserve manually-entered incoming
        // server hints and mirror the credential there.
        if let provider = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: host,
            imapHost: account.imapHost ?? imapHostHint
        ) {
            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.imapSecurity = provider.imapSecurity
            account.imapUsername = account.smtpUsername ?? account.emailAddress
            account.imapAuthMethod = {
                switch authMethod {
                case .password:
                    return .password
                case .oauth2:
                    return .oauth2
                }
            }()

            switch authMethod {
            case .password:
                // Store the same app-specific password under com.ohia.imap
                // service. IMAPCredentials.storePassword allocates the ref
                // if nil.
                let imapCreds = IMAPCredentials()
                try imapCreds.storePassword(password, for: account)
            case .oauth2:
                // Gmail: mail.google.com scope covers both protocols.
                // Microsoft: Plan-1 scope widening covers IMAP too.
                // Reuse the existing SMTP keychain ref for IMAP — same token.
                account.imapKeychainRef = account.smtpKeychainRef
            }
            account.needsImapReauth = false
        } else if let manualIMAPHost = account.imapHost ?? imapHostHint,
                  let manualIMAPPort = account.imapPort ?? imapPortHint {
            account.imapHost = manualIMAPHost
            account.imapPort = manualIMAPPort
            account.imapSecurity = account.imapSecurity ?? imapSecurityHint ?? .tls
            account.imapUsername = account.imapUsername
                ?? imapUsernameHint
                ?? account.smtpUsername
                ?? account.emailAddress
            account.imapAuthMethod = .password
            if authMethod == .password {
                let imapCreds = IMAPCredentials()
                try imapCreds.storePassword(password, for: account)
            }
            account.needsImapReauth = false
        }
    }

    func verificationFingerprint(for account: Account) -> VerificationFingerprint {
        VerificationFingerprint(
            accountID: account.id,
            emailAddress: emailAddress,
            host: host,
            portText: portText,
            security: security.rawValue,
            username: username,
            authMethod: authMethod.rawValue,
            password: password,
            imapHost: imapHostHint,
            imapPort: imapPortHint,
            imapUsername: imapUsernameHint,
            imapSecurity: imapSecurityHint?.rawValue
        )
    }

    /// Called from the view's single `.task(id:)` observer. Changing any
    /// account, form, or authentication input invalidates the current attempt;
    /// late network completions are rejected by the same fingerprint guard.
    func observeVerificationFingerprint(_ fingerprint: VerificationFingerprint) {
        guard let activeFingerprint, activeFingerprint != fingerprint else { return }
        invalidateActiveVerification()
    }

    func cancelVerification() {
        invalidateActiveVerification()
    }

    /// Saves credentials, verifies SMTP and IMAP authentication, persists the
    /// model context, and continues only if the whole attempt is still current.
    /// OAuth acquisition is performed when no stored token exists or a fresh
    /// authorization was explicitly requested by the provider button.
    func verifyAndContinue(
        account: Account,
        acquireFreshOAuth: Bool = false,
        persistModel: @MainActor () throws -> Void,
        onContinue: @MainActor (IMAPConnectionConfiguration) -> Void
    ) async {
        let fingerprint = verificationFingerprint(for: account)
        if activeAttemptID != nil {
            guard activeFingerprint != fingerprint else { return }
            invalidateActiveVerification()
        }

        let attemptID = UUID()
        activeAttemptID = attemptID
        activeFingerprint = fingerprint
        verificationOAuthTokens = nil
        testStatus = .running

        do {
            var acquiredOAuthTokens: Tokens?
            if authMethod == .oauth2,
               acquireFreshOAuth || account.smtpKeychainRef == nil {
                verificationStage = .oauthSignIn
                signInStatus = .running
                acquiredOAuthTokens = try await acquireOAuthTokens()
                verificationOAuthTokens = acquiredOAuthTokens
                try ensureCurrent(
                    attemptID: attemptID,
                    fingerprint: fingerprint,
                    account: account
                )
            }

            verificationStage = .smtp
            try await smtpVerification(self, account)
            try ensureCurrent(
                attemptID: attemptID,
                fingerprint: fingerprint,
                account: account
            )

            verificationStage = .imap
            let configuration = try await imapConfiguration(
                self,
                account,
                acquiredOAuthTokens
            )
            try ensureCurrent(
                attemptID: attemptID,
                fingerprint: fingerprint,
                account: account
            )
            try await imapVerification(configuration)
            try ensureCurrent(
                attemptID: attemptID,
                fingerprint: fingerprint,
                account: account
            )

            verificationStage = .saving
            if acquiredOAuthTokens != nil, account.smtpKeychainRef == nil {
                account.smtpKeychainRef = "smtp-oauth-\(account.id.uuidString)"
            }
            try credentialPersistence(self, account)
            if let acquiredOAuthTokens {
                try await oauthTokenPersistence(acquiredOAuthTokens, account)
            }
            try persistModel()
            try ensureCurrent(
                attemptID: attemptID,
                fingerprint: fingerprint,
                account: account
            )

            testStatus = .success
            if authMethod == .oauth2 {
                signInStatus = .success
            }
            finishAttempt(attemptID)
            onContinue(configuration)
        } catch is CancellationError {
            finishCancellation(attemptID)
        } catch OAuthCoordinatorError.userCancelled {
            finishCancellation(attemptID)
        } catch let error as SMTPVerificationControlError {
            if case .certificatePresented = error {
                finishAttempt(attemptID, preservingStatus: true)
            }
        } catch {
            guard activeAttemptID == attemptID else { return }
            let message = failureMessage(for: error)
            if verificationStage == .oauthSignIn {
                testStatus = .idle
                signInStatus = .failure(message)
            } else {
                testStatus = .failure(message)
            }
            finishAttempt(attemptID, preservingStatus: true)
        }
    }

    private func acquireOAuthTokens() async throws -> Tokens {
        guard let provider = currentProvider,
              case .oauth2(let providerID) = provider.authHint else {
            throw VerificationSetupError.oauthProviderUnavailable
        }
        let oauthProvider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft

        let tokens = try await oauthTokenAcquisition(oauthProvider)
        try Task.checkCancellation()
        return tokens
    }

    /// Builds the candidate IMAP connection entirely from form inputs and
    /// transient credentials. The live Account and its Keychain entries stay
    /// untouched until both SMTP and IMAP authentication have succeeded.
    private func makeVerificationIMAPConfiguration(
        for account: Account,
        acquiredOAuthTokens: Tokens?
    ) async throws -> IMAPConnectionConfiguration {
        let provider = currentProvider
        guard let imapHost = (provider?.imapHost ?? imapHostHint ?? account.imapHost)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              imapHost.isEmpty == false,
              let imapPort = provider?.imapPort ?? imapPortHint ?? account.imapPort,
              let imapSecurity = provider?.imapSecurity ?? imapSecurityHint ?? account.imapSecurity else {
            throw IMAPConnectionConfiguration.Error.missingServerConfiguration
        }

        let imapUsername = imapUsernameHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUsername = if let imapUsername, imapUsername.isEmpty == false {
            imapUsername
        } else if username.isEmpty == false {
            username
        } else {
            emailAddress
        }

        let auth: SentAppender.Auth
        switch authMethod {
        case .password:
            auth = .password(username: resolvedUsername, password: password)
        case .oauth2:
            guard let provider,
                  case .oauth2(let providerID) = provider.authHint else {
                throw VerificationSetupError.oauthProviderUnavailable
            }
            if let acquiredOAuthTokens {
                let token = acquiredOAuthTokens.accessToken
                auth = .xoauth2(
                    username: resolvedUsername,
                    initialToken: token,
                    refresh: { token }
                )
            } else {
                guard let keychainRef = account.smtpKeychainRef ?? account.imapKeychainRef else {
                    throw VerificationSetupError.oauthSignInRequired
                }
                let store = OAuthTokenStore()
                let token = try await store.imapAccessTokenByKeychainRef(
                    keychainRef,
                    provider: providerID,
                    forceRefresh: false
                )
                try Task.checkCancellation()
                auth = .xoauth2(
                    username: resolvedUsername,
                    initialToken: token,
                    refresh: {
                        try await store.imapAccessTokenByKeychainRef(
                            keychainRef,
                            provider: providerID,
                            forceRefresh: true
                        )
                    }
                )
            }
        }

        return IMAPConnectionConfiguration(
            host: imapHost,
            port: imapPort,
            security: imapSecurity,
            pinnedCertSHA256: account.pinnedCertSHA256,
            auth: auth
        )
    }

    /// Runs `SMTPClient.verifyAuth` against the configured server with the
    /// current credentials in the form. For password auth we use the typed
    /// password directly (not Keychain); for OAuth we pull a fresh access
    /// token via OAuthTokenStore. Updates `testStatus`.
    func runTest(for account: Account) async {
        testStatus = .running
        do {
            try await smtpVerification(self, account)
            testStatus = .success
        } catch is CancellationError {
            testStatus = .idle
        } catch SMTPVerificationControlError.certificatePresented {
            // The certificate sheet is driven by the status set while
            // inspecting the peer certificate.
        } catch {
            testStatus = .failure(Self.smtpFailureMessage(for: error))
        }
    }

    private func verifySMTPAuthentication(for account: Account) async throws {
        guard port > 0, !host.isEmpty else {
            throw VerificationSetupError.missingSMTPServer
        }

        let auth: SMTPClient.Auth
        switch authMethod {
        case .password:
            auth = .password(
                username: username.isEmpty ? emailAddress : username,
                password: password
            )
        case .oauth2:
            guard let provider = currentProvider,
                  case .oauth2(let providerID) = provider.authHint else {
                throw VerificationSetupError.oauthProviderUnavailable
            }
            let user = username.isEmpty ? emailAddress : username
            if let verificationOAuthTokens {
                let token = verificationOAuthTokens.accessToken
                auth = .xoauth2(
                    username: user,
                    initialToken: token,
                    refresh: { token }
                )
            } else {
                guard let ref = account.smtpKeychainRef else {
                    throw VerificationSetupError.oauthSignInRequired
                }
                let oauthProvider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft
                let store = OAuthTokenStore()
                let token = try await store.refreshByKeychainRef(
                    ref,
                    provider: oauthProvider,
                    forceRefresh: false
                )
                try Task.checkCancellation()
                auth = .xoauth2(
                    username: user,
                    initialToken: token,
                    refresh: {
                        try await store.refreshByKeychainRef(ref, provider: oauthProvider)
                    }
                )
            }
        }

        accountPinnedCertSHA256 = account.pinnedCertSHA256
        let client = SMTPClient(
            transport: makeTransport(),
            hostname: SMTPClient.ehloHostname(forAddress: emailAddress)
        )
        let endpoint: (host: String, port: Int, security: SMTPSecurity)
        if MailProviderRegistry.lookupByHost(host)?.authHint == .oauth2(.gmail) {
            endpoint = ("smtp.gmail.com", 465, .tls)
        } else {
            endpoint = (host, port, security)
        }
        let verifyResult: Result<Void, Error>
        do {
            try Task.checkCancellation()
            try await client.verifyAuth(
                host: endpoint.host,
                port: endpoint.port,
                security: endpoint.security,
                auth: auth
            )
            try Task.checkCancellation()
            verifyResult = .success(())
        } catch {
            if error is CancellationError { throw error }
            verifyResult = .failure(error)
        }

        switch SMTPCertTrustClassifier.classify(verifyResult) {
        case .success:
            return

        case .regularFailure:
            if case .failure(let err) = verifyResult {
                throw err
            } else {
                throw VerificationSetupError.smtpUnknown
            }

        case .certUntrusted:
            // The inspector currently only supports implicit TLS (initialTLS=true).
            // For STARTTLS errors, fall back to the generic failure path.
            guard endpoint.security == .tls else {
                if case .failure(let err) = verifyResult {
                    throw err
                } else {
                    throw VerificationSetupError.smtpUnknown
                }
            }
            let stream = MailLineStream()
            stream.connectTimeout = 15
            do {
                let info = try await stream.inspectPeerCertificate(
                    host: endpoint.host,
                    port: endpoint.port,
                    initialTLS: true
                )
                testStatus = .certUntrusted(info: info)
                throw SMTPVerificationControlError.certificatePresented
            } catch {
                if error is SMTPVerificationControlError { throw error }
                throw VerificationSetupError.certificateInspectionFailed
            }
        }
    }

    private func ensureCurrent(
        attemptID: UUID,
        fingerprint: VerificationFingerprint,
        account: Account
    ) throws {
        try Task.checkCancellation()
        guard activeAttemptID == attemptID,
              activeFingerprint == fingerprint,
              verificationFingerprint(for: account) == fingerprint else {
            if activeAttemptID == attemptID {
                invalidateActiveVerification()
            }
            throw CancellationError()
        }
    }

    private func invalidateActiveVerification() {
        activeAttemptID = nil
        activeFingerprint = nil
        verificationStage = nil
        verificationOAuthTokens = nil
        if testStatus == .running { testStatus = .idle }
        if signInStatus == .running { signInStatus = .idle }
    }

    private func finishAttempt(_ attemptID: UUID, preservingStatus: Bool = false) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        activeFingerprint = nil
        verificationStage = nil
        verificationOAuthTokens = nil
        if preservingStatus == false, testStatus == .running {
            testStatus = .idle
        }
        if signInStatus == .running {
            signInStatus = .idle
        }
    }

    private func finishCancellation(_ attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        testStatus = .idle
        if signInStatus == .running { signInStatus = .idle }
        finishAttempt(attemptID)
    }

    private enum SMTPVerificationControlError: Error {
        case certificatePresented
    }

    private enum VerificationSetupError: Error {
        case missingSMTPServer
        case oauthProviderUnavailable
        case oauthSignInRequired
        case smtpUnknown
        case certificateInspectionFailed
    }

    private func failureMessage(for error: Swift.Error) -> String {
        switch verificationStage {
        case .oauthSignIn:
            return Self.oauthFailureMessage(for: error)
        case .smtp:
            return Self.smtpFailureMessage(for: error)
        case .imap:
            return Self.imapFailureMessage(for: error)
        case .saving:
            return "Could not save verified mail settings. Try again."
        case .none:
            return "Mail authentication could not be verified. Try again."
        }
    }

    private static func oauthFailureMessage(for error: Swift.Error) -> String {
        switch error {
        case VerificationSetupError.oauthProviderUnavailable:
            return "This account does not support provider sign-in."
        case VerificationSetupError.oauthSignInRequired:
            return "Sign in to this account first."
        default:
            return "Sign-in failed. Try again or use a provider app password."
        }
    }

    private static func smtpFailureMessage(for error: Swift.Error) -> String {
        switch error {
        case VerificationSetupError.missingSMTPServer:
            return "SMTP host and port are required."
        case VerificationSetupError.oauthProviderUnavailable:
            return "SMTP OAuth provider not recognized."
        case VerificationSetupError.oauthSignInRequired:
            return "SMTP sign-in is required."
        case VerificationSetupError.certificateInspectionFailed:
            return "SMTP certificate could not be inspected. Check the server settings."
        case SMTPError.authFailed(let response):
            // Only surface protocol status codes, never arbitrary response text
            // that could echo an AUTH payload or account credentials.
            let fields = response.split(whereSeparator: \.isWhitespace)
            let codes = fields.prefix(2).filter { field in
                let parts = field.split(separator: ".", omittingEmptySubsequences: false)
                if parts.count == 1 {
                    return field.count == 3 && field.allSatisfy { $0 >= "0" && $0 <= "9" }
                }
                return parts.count == 3 && parts[0].count == 1
                    && parts.allSatisfy { part in
                        (1...3).contains(part.count) && part.allSatisfy { $0 >= "0" && $0 <= "9" }
                    }
            }.joined(separator: " ")
            let status = codes.isEmpty ? "" : " (\(codes))"
            return "SMTP authentication failed\(status). The outgoing server rejected sign-in."
        case SMTPError.transportFailed:
            return "SMTP secure connection failed. Check the outgoing server, port, and security setting."
        case SMTPError.transient:
            return "SMTP connection was interrupted or temporarily refused. Try again."
        case SMTPError.permanent:
            return "SMTP server refused the connection. Check the outgoing server settings."
        case SMTPError.protocolViolation:
            return "SMTP server returned an unexpected response. Check the outgoing server host and port."
        default:
            return "SMTP verification failed. Check the outgoing server and try again."
        }
    }

    private static func imapFailureMessage(for error: Swift.Error) -> String {
        guard let error = error as? IMAPConnectionVerificationError else {
            if error is IMAPConnectionConfiguration.Error
                || error is IMAPAuthResolver.ResolveError
                || error is OAuthTokenStoreError {
                return "IMAP settings or credentials are incomplete. Check the incoming server and sign-in."
            }
            return "IMAP verification failed. Check the incoming server and try again."
        }

        switch error {
        case .transient:
            return "IMAP connection failed. Check your network and try again."
        case .actionRequired(let reason):
            switch reason {
            case .authFailed, .reauthRequired:
                return "IMAP authentication failed. Check the incoming server and credentials."
            case .certMismatch, .tlsError:
                return "IMAP secure connection failed. Check the incoming server certificate and settings."
            case .protocolViolation:
                return "IMAP server verification failed. Check the incoming server host and port."
            }
        }
    }
}
