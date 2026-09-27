import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

enum SpotifyConfig {
    static let clientIDKey = "spotifyClientID"
    static let redirectURI = "musicjournal://callback"
    static let callbackScheme = "musicjournal"
    static let scopes = [
        "user-top-read",
        "user-read-recently-played",
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-private",
        "playlist-modify-public",
    ]
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    static var clientID: String? {
        let id = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespaces)
        return (id?.isEmpty ?? true) ? nil : id
    }
}

enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case notSignedIn
    case cancelled
    case callbackMissingCode(String?)
    case stateMismatch
    case tokenRequestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Spotify Client ID in Settings first."
        case .notSignedIn: "You're signed out of Spotify."
        case .cancelled: "Spotify sign-in was cancelled."
        case .callbackMissingCode(let err): "Spotify didn't return an authorization code\(err.map { " (\($0))" } ?? "")."
        case .stateMismatch: "Spotify sign-in failed a security check. Please try again."
        case .tokenRequestFailed(let status, let body): "Spotify token request failed (\(status)): \(body)"
        }
    }
}

/// RFC 7636 PKCE helpers.
enum PKCE {
    static func makeVerifier(length: Int = 64) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Holds the access token in memory and the refresh token in Keychain.
/// Concurrent callers share a single in-flight refresh.
actor TokenStore {
    private static let refreshAccount = "spotify.refreshToken"

    private var accessToken: String?
    private var expiry: Date = .distantPast
    private var refreshTask: Task<String, Error>?

    var hasRefreshToken: Bool { Keychain.get(Self.refreshAccount) != nil }

    func validAccessToken() async throws -> String {
        if let accessToken, expiry.timeIntervalSinceNow > 60 {
            return accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func store(_ response: TokenResponse) {
        accessToken = response.accessToken
        expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        if let refresh = response.refreshToken {
            Keychain.set(refresh, for: Self.refreshAccount)
        }
    }

    /// Debug aid: makes the next request go through the refresh path.
    func forceExpire() {
        expiry = .distantPast
    }

    func clear() {
        accessToken = nil
        expiry = .distantPast
        Keychain.delete(Self.refreshAccount)
    }

    private func refresh() async throws -> String {
        guard let clientID = SpotifyConfig.clientID else { throw SpotifyAuthError.missingClientID }
        guard let refreshToken = Keychain.get(Self.refreshAccount) else { throw SpotifyAuthError.notSignedIn }
        do {
            let response = try await SpotifyAccounts.requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ])
            store(response)
            return response.accessToken
        } catch SpotifyAuthError.tokenRequestFailed(let status, let body) where status == 400 {
            // invalid_grant: the refresh token was revoked or expired.
            clear()
            throw SpotifyAuthError.tokenRequestFailed(status, body)
        }
    }
}

enum SpotifyAccounts {
    static func requestToken(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: SpotifyConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SpotifyAuthError.tokenRequestFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TokenResponse.self, from: data)
    }
}

/// Interactive sign-in via the system web auth sheet (Authorization Code + PKCE).
@MainActor
final class SpotifyAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(into tokens: TokenStore) async throws {
        guard let clientID = SpotifyConfig.clientID else { throw SpotifyAuthError.missingClientID }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier(length: 16)

        var components = URLComponents(url: SpotifyConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: SpotifyConfig.scopes.joined(separator: " ")),
            .init(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "state", value: state),
        ]

        let callback = try await authenticate(url: components.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.callbackMissingCode(items.first { $0.name == "error" }?.value)
        }

        let response = try await SpotifyAccounts.requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        await tokens.store(response)
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(SpotifyConfig.callbackScheme)
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
