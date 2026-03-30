import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import OSLog

struct OAuthConfiguration {
    let clientId: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let redirectScheme: String
    let redirectURI: String
    let scopes: String
}

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

final class OAuthManager: NSObject {
    static let shared = OAuthManager()

    private let keychain = KeychainHelper.shared
    private let tokensKey = "livelox.tokens"
    private let userInfoKey = "livelox.userinfo"
    private var currentSession: ASWebAuthenticationSession?

    /// In-flight refresh task — shared so concurrent callers await the same request
    /// instead of each firing their own, which would exhaust single-use refresh tokens.
    private var refreshTask: Task<String, Error>?

    private override init() {}

    /// `true` when stored tokens exist (i.e. the user has connected Livelox).
    /// Actual token freshness is handled lazily inside `accessToken()`.
    var isAuthorized: Bool { hasTokens }

    /// `true` if OAuth tokens are present in the Keychain.
    var hasTokens: Bool { loadTokens() != nil }

    func authorize() async throws {
        guard let config = configuration() else {
            throw AppError.oauthConfigurationMissing
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = codeChallenge(for: codeVerifier)

        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components?.url else {
            throw AppError.oauthConfigurationMissing
        }

        let callbackURL = try await startAuthenticationSession(authURL: authURL, callbackScheme: config.redirectScheme)
        guard let code = extractCode(from: callbackURL) else {
            throw AppError.oauthCallbackInvalid
        }

        let tokens = try await exchangeCodeForTokens(code: code, verifier: codeVerifier, config: config)
        saveTokens(tokens)
        AppLogger.auth.info("OAuth tokens saved")
    }

    func accessToken() async throws -> String {
        if let tokens = loadTokens(), tokens.expiresAt > Date() {
            return tokens.accessToken
        }
        // If a refresh is already in-flight, await the same task instead of
        // firing a second request (which would exhaust single-use refresh tokens).
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            return try await self.refreshAccessTokenIfNeeded()
        }
        refreshTask = task
        return try await task.value
    }

    /// Removes all stored tokens and cached user info. After this call `isAuthorized` is false.
    func logout() {
        keychain.delete(key: tokensKey)
        UserDefaults.standard.removeObject(forKey: userInfoKey)
        refreshTask?.cancel()
        refreshTask = nil
        AppLogger.auth.info("Logged out — tokens and user info cleared")
    }

    func cachedUserInfo() -> LiveloxUserInfo? {
        guard let data = UserDefaults.standard.data(forKey: userInfoKey) else {
            return nil
        }
        return try? JSONDecoder().decode(LiveloxUserInfo.self, from: data)
    }

    func fetchUserInfo() async throws -> LiveloxUserInfo {
        let token = try await accessToken()
        guard let url = URL(string: AppConfiguration.shared.liveloxUserInfoURL) else {
            throw AppError.userInfoFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            AppLogger.auth.error("User info request failed")
            throw AppError.userInfoFailed
        }

        if let rawString = String(data: data, encoding: .utf8) {
            AppLogger.auth.debug("User info response: \(rawString, privacy: .private)")
        }

        let userInfo = try parseUserInfo(from: data)
        AppLogger.auth.info("User info loaded: \(userInfo.name)")
        saveUserInfo(userInfo)
        return userInfo
    }

    private func refreshAccessTokenIfNeeded() async throws -> String {
        guard let config = configuration() else {
            throw AppError.oauthConfigurationMissing
        }
        guard let tokens = loadTokens() else {
            throw AppError.tokenRefreshFailed
        }

        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(tokens.refreshToken)",
            "client_id=\(config.clientId)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, httpResp): (Data, URLResponse)
        do {
            (data, httpResp) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError
            where urlError.code == .notConnectedToInternet
               || urlError.code == .timedOut
               || urlError.code == .networkConnectionLost {
            // Network is down — tokens are still valid, just can't reach the server right now.
            AppLogger.auth.warning("Token refresh skipped — no network: \(urlError.localizedDescription)")
            throw AppError.networkUnavailable
        }
        guard let statusCode = (httpResp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            // The refresh token is no longer valid — clear credentials so the UI
            // immediately shows "Not connected" and the user knows to reconnect.
            AppLogger.auth.error("Token refresh rejected by server (HTTP \((httpResp as? HTTPURLResponse)?.statusCode ?? -1)) — clearing tokens")
            logout()
            throw AppError.tokenRefreshFailed
        }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        let newTokens = OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            expiresAt: expiresAt
        )
        saveTokens(newTokens)
        return newTokens.accessToken
    }

    private func exchangeCodeForTokens(code: String, verifier: String, config: OAuthConfiguration) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(config.redirectURI)",
            "client_id=\(config.clientId)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            AppLogger.auth.error("Token exchange rejected by server")
            throw AppError.tokenRefreshFailed
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? "",
            expiresAt: expiresAt
        )
    }

    private func startAuthenticationSession(authURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AppError.oauthCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let url else {
                    continuation.resume(throwing: AppError.oauthConfigurationMissing)
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
            currentSession = session
        }
    }

    private func extractCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    private func saveTokens(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            return
        }
        keychain.save(data: data, key: tokensKey)
    }

    private func loadTokens() -> OAuthTokens? {
        guard let data = keychain.load(key: tokensKey) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    private func saveUserInfo(_ info: LiveloxUserInfo) {
        guard let data = try? JSONEncoder().encode(info) else {
            return
        }
        UserDefaults.standard.set(data, forKey: userInfoKey)
    }

    private func parseUserInfo(from data: Data) throws -> LiveloxUserInfo {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AppError.userInfoFailed
        }

        let raw = dictionary.normalizedStringValues()

        let id = raw.firstValue(forKeys: ["personId", "sub", "id", "userId", "userid"]) ?? "unknown"
        let firstName = raw.firstValue(forKeys: ["firstName", "first_name"])
        let lastName = raw.firstValue(forKeys: ["lastName", "last_name"])
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let resolvedName = name.isEmpty
            ? (raw.firstValue(forKeys: ["name", "preferred_username", "username", "user_name", "email", "sub"]) ?? "Unknown")
            : name
        let email = raw.firstValue(forKeys: ["email"])

        return LiveloxUserInfo(id: id, name: resolvedName, email: email, raw: raw)
    }

    private func configuration() -> OAuthConfiguration? {
        let config = AppConfiguration.shared
        guard let authURL = URL(string: config.liveloxAuthURL),
              let tokenURL = URL(string: config.liveloxTokenURL) else {
            return nil
        }
        return OAuthConfiguration(
            clientId: config.liveloxClientId,
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL,
            redirectScheme: config.liveloxRedirectScheme,
            redirectURI: config.liveloxRedirectURI,
            scopes: config.liveloxScopes
        )
    }

    private func generateCodeVerifier() -> String {
        let data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return base64URLString(from: data)
    }

    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return base64URLString(from: Data(digest))
    }

    private func base64URLString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return windowScene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

struct LiveloxUserInfo: Codable {
    let id: String
    let name: String
    let email: String?
    let raw: [String: String]

    var displayName: String {
        if let email, !email.isEmpty {
            return "\(name) (\(email))"
        }
        return name
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
