import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

public enum OAuthCoordinatorError: Swift.Error {
    case stateMismatch
    case missingCode
    case missingClientID
    case userCancelled
    case openBrowserFailed
    case providerReturnedError(String)
}

public enum OAuthCoordinator {

    // MARK: - PKCE

    public static func pkce() -> (verifier: String, challenge: String) {
        let verifier = randomVerifier()
        let challenge = sha256Base64URLNoPad(verifier)
        return (verifier, challenge)
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLNoPad(Data(bytes))
    }

    private static func sha256Base64URLNoPad(_ s: String) -> String {
        let hash = SHA256.hash(data: Data(s.utf8))
        return base64URLNoPad(Data(hash))
    }

    private static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - URL builders

    public static func authorizeURL(
        provider: OAuthProvider,
        clientID: String,
        state: String,
        codeChallenge: String,
        redirectURI: String
    ) -> URL {
        var comps = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: provider.scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        // Google-only: access_type=offline forces refresh_token on first consent.
        if provider.id == .gmail {
            items.append(.init(name: "access_type", value: "offline"))
            items.append(.init(name: "prompt", value: "consent"))
        }
        comps.queryItems = items
        return comps.url!
    }

    // MARK: - Token exchange

    public static func exchange(
        code: String,
        verifier: String,
        provider: OAuthProvider,
        clientID: String,
        redirectURI: String,
        http: HTTPClient
    ) async throws -> Tokens {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
        ]
        let data = try await http.post(url: provider.tokenURL, formBody: body)
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let scope: String?
        }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        return Tokens(
            accessToken: parsed.access_token,
            refreshToken: parsed.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(parsed.expires_in)),
            scope: parsed.scope ?? provider.scope
        )
    }

    // MARK: - Full sign-in (browser-redirect flow)
    //
    // macOS sign-in opens the user's default browser via `NSWorkspace`,
    // then waits for the OAuth provider to redirect to a custom URL
    // scheme registered in Info.plist (`CFBundleURLTypes`). The host app
    // wires SwiftUI's `.onOpenURL` to `handleIncomingURL(_:)`, which
    // matches the redirect against the pending continuation by the
    // opaque `state` parameter and resumes it with the callback URL.
    //
    // This is the Apple-recommended pattern for unsandboxed macOS apps;
    // the earlier `ASWebAuthenticationSession` approach did not reliably
    // intercept the redirect on this configuration (the auth URL was
    // handed off to the default browser, whose redirect was never seen
    // by the session callback).

    #if canImport(AppKit)
    @MainActor
    public static func signIn(
        provider: OAuthProvider,
        redirectURI: String? = nil,
        http: HTTPClient = URLSessionHTTPClient()
    ) async throws -> Tokens {
        guard let clientID = provider.clientID else {
            throw OAuthCoordinatorError.missingClientID
        }
        let resolvedRedirect = redirectURI ?? provider.redirectURI(for: clientID)
        let (verifier, challenge) = pkce()
        let state = UUID().uuidString
        let url = authorizeURL(
            provider: provider,
            clientID: clientID,
            state: state,
            codeChallenge: challenge,
            redirectURI: resolvedRedirect
        )

        let callbackURL = try await awaitRedirect(state: state, authorizeURL: url)

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        if let oauthError = params["error"] {
            let desc = params["error_description"] ?? oauthError
            throw OAuthCoordinatorError.providerReturnedError(desc)
        }
        guard params["state"] == state else {
            throw OAuthCoordinatorError.stateMismatch
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthCoordinatorError.missingCode
        }

        return try await exchange(
            code: code,
            verifier: verifier,
            provider: provider,
            clientID: clientID,
            redirectURI: resolvedRedirect,
            http: http
        )
    }

    /// In-flight sign-in requests, keyed by OAuth `state` nonce. Populated
    /// by `awaitRedirect` and drained by `handleIncomingURL` when macOS
    /// delivers the redirect URL to the app via CFBundleURLTypes.
    @MainActor
    private static var pendingRequests: [String: CheckedContinuation<URL, Error>] = [:]

    @MainActor
    private static func awaitRedirect(
        state: String,
        authorizeURL: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            pendingRequests[state] = cont
            let opened = NSWorkspace.shared.open(authorizeURL)
            if !opened {
                pendingRequests[state] = nil
                cont.resume(throwing: OAuthCoordinatorError.openBrowserFailed)
            }
        }
    }

    /// Called by the host app from `.onOpenURL` when macOS delivers a
    /// redirect URL that matches one of Ohia's registered URL schemes.
    /// Matches the URL to a pending sign-in by the `state` query param
    /// and resumes the awaiting continuation. URLs with no matching
    /// pending request are ignored (logged only).
    @MainActor
    public static func handleIncomingURL(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value else {
            return
        }
        guard let cont = pendingRequests.removeValue(forKey: state) else {
            return
        }
        cont.resume(returning: url)
    }
    #endif
}
